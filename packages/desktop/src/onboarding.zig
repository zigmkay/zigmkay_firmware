//! Owned onboarding stages. Repository scripts and callbacks never run here.
const std = @import("std");
const p = @import("project");
pub const importer = @import("keymap-importer");
pub const boards = importer.boards;
pub const catalog = importer.catalog;
const Model = @import("model.zig").Model;
pub const Stage = enum { welcome, source, keyboard, review, created, open };
pub const Result = union(enum) {
    inspected: importer.Captured,
    analyzed: importer.Analysis,
    prepared: importer.Prepared,
    opened: Opened,
    pub fn deinit(self: *Result) void {
        switch (self.*) {
            inline else => |*value| value.deinit(),
        }
        self.* = undefined;
    }
};
pub const Opened = struct {
    arena: std.heap.ArenaAllocator,
    model: ?Model,
    path: []const u8,
    collection: ?[]const u8,
    pub fn deinit(self: *Opened) void {
        if (self.model) |*model| model.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Operation = enum { inspect, analyze, prepare, create, open, add_existing };
pub const Source = struct { directory: []const u8, source_root: []const u8, provenance: importer.Provenance, candidates: []const []const u8 };
pub const Template = enum { firmware_default, qwerty, eurkey, eurmac };
pub const Inputs = struct {
    operation: Operation,
    location: []const u8 = "",
    entry: ?[]const u8 = null,
    source: ?Source = null,
    analysis: ?struct { captured: [32]u8, data: importer.Data } = null,
    selector: []const u8 = "",
    template: Template = .firmware_default,
    name: []const u8 = "My keyboard",
    destination: []const u8 = "",
    collection: ?[]const u8 = null,
    collection_entry: ?p.collection.Entry = null,
    collection_fingerprint: ?[32]u8 = null,
    toolchain: importer.Toolchain,
    prepared: ?struct { snapshot: p.snapshot.Snapshot, selector: []const u8 } = null,
};
pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    inputs: Inputs,
    environment: std.process.Environ.Map,
    captured: [32]u8,
    pub fn init(gpa: std.mem.Allocator, inputs: Inputs, environment: *const std.process.Environ.Map, fingerprint: [32]u8) !Request {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try p.owned_zon.clone(a, inputs);
        const env = try environment.clone(a);
        return .{ .arena = arena, .inputs = owned, .environment = env, .captured = fingerprint };
    }
    pub fn deinit(self: *Request) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn prepare(self: *const Request, gpa: std.mem.Allocator, io: std.Io) !Result {
        const input = self.inputs;
        const source: ?importer.Captured = if (input.source) |value| .{ .arena = undefined, .directory = value.directory, .source_root = value.source_root, .provenance = value.provenance, .candidates = value.candidates } else null;
        switch (input.operation) {
            .inspect => return .{ .inspected = try importer.inspectWithOrigin(gpa, io, input.location, input.entry, input.toolchain.cache, if (source) |old| (if (std.mem.eql(u8, old.source_root, input.location)) old.provenance else null) else null) },
            .analyze => return .{ .analyzed = try importer.analyze(gpa, io, source orelse return error.SourceRequired, input.toolchain, &self.environment) },
            .prepare => {
                var nonce: [8]u8 = undefined;
                io.random(&nonce);
                const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
                for (&nonce) |*byte| byte.* = alphabet[byte.* % 32];
                if (source) |captured| {
                    const analyzed = input.analysis orelse return error.AnalysisRequired;
                    const analysis: importer.Analysis = .{ .arena = undefined, .captured = analyzed.captured, .data = analyzed.data };
                    return .{ .prepared = try importer.prepare(gpa, io, captured, analysis, input.selector, input.name, nonce) };
                }
                if (input.template != .firmware_default) {
                    if (!std.mem.eql(u8, input.selector, "lk7")) return error.TemplateNotAvailableForBoard;
                    var original = try p.profiles.create(gpa, switch (input.template) {
                        .qwerty => .qwerty,
                        .eurkey => .eurkey,
                        .eurmac => .eurmac,
                        else => unreachable,
                    });
                    defer original.deinit();
                    var board = try boards.OwnedBoard.fromDocument(gpa, original.snapshot.document);
                    errdefer board.deinit();
                    var owned: boards.OwnedProject = .{ .arena = .init(gpa), .snapshot = undefined };
                    errdefer owned.deinit();
                    owned.snapshot = try p.owned_zon.clone(owned.arena.allocator(), original.snapshot);
                    owned.snapshot.document.name = try owned.arena.allocator().dupe(u8, input.name);
                    owned.snapshot.document.profile_id = nonce;
                    return .{ .prepared = .{ .board = board, .project = owned, .captured = self.captured } };
                }
                var board = try boards.OwnedBoard.init(gpa, input.selector);
                errdefer board.deinit();
                var created = try boards.createDefault(gpa, board);
                errdefer created.deinit();
                created.snapshot.document.name = try created.arena.allocator().dupe(u8, input.name);
                created.snapshot.document.profile_id = nonce;
                try p.snapshot.validate(created.snapshot, board.board);
                return .{ .prepared = .{ .board = board, .project = created, .captured = self.captured } };
            },
            .create => {
                const selected = input.prepared orelse return error.PreparedProjectRequired;
                var board = try boards.OwnedBoard.fromDocument(gpa, selected.snapshot.document);
                defer board.deinit();
                if (!std.mem.eql(u8, board.entry.selector, selected.selector)) return error.BuildBoardMismatch;
                const value: importer.Prepared = .{ .board = board, .project = .{ .arena = undefined, .snapshot = selected.snapshot }, .captured = self.captured };
                if (input.collection) |root| {
                    var collection_dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
                    defer collection_dir.close(io);
                    collection_dir.createDir(io, "keyboards", .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
                    var contained = try p.collection.openProject(io, collection_dir, "keyboards");
                    contained.close(io);
                }
                try importer.commit(gpa, io, value, source, input.destination);
                if (input.collection) |root| {
                    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
                    defer dir.close(io);
                    try p.collection.append(gpa, io, dir, input.collection_entry orelse return error.CollectionEntryRequired, input.collection_fingerprint);
                }
                return .{ .opened = try open(gpa, io, input.destination, input.collection) };
            },
            .open => return .{ .opened = try open(gpa, io, input.location, null) },
            .add_existing => {
                const root = input.collection orelse return error.OpenCollectionFirst;
                var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
                defer dir.close(io);
                const entry = input.collection_entry orelse return error.CollectionEntryRequired;
                const path = try std.fs.path.join(gpa, &.{ root, entry.directory });
                defer gpa.free(path);
                if (input.location.len != 0 and !std.mem.eql(u8, input.location, path)) {
                    // The button explicitly requests a portable copy. Its source
                    // project, callbacks and provenance remain untouched.
                    var original = try open(gpa, io, input.location, null);
                    defer original.deinit();
                    var board = try boards.OwnedBoard.fromDocument(gpa, original.model.?.document());
                    defer board.deinit();
                    var retained = try importer.retained(gpa, io, input.location);
                    defer if (retained) |*source_copy| source_copy.deinit();
                    const copied: importer.Prepared = .{ .board = board, .project = .{ .arena = undefined, .snapshot = original.model.?.current.snapshot }, .captured = if (retained) |source_copy| source_copy.provenance.fingerprint else @splat(0) };
                    dir.createDir(io, "keyboards", .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
                    var contained = try p.collection.openProject(io, dir, "keyboards");
                    contained.close(io);
                    try importer.commit(gpa, io, copied, retained, path);
                }
                var contained = try p.collection.openProject(io, dir, entry.directory);
                contained.close(io);
                var verified = try open(gpa, io, path, root);
                errdefer verified.deinit();
                try p.collection.append(gpa, io, dir, entry, input.collection_fingerprint);
                return .{ .opened = verified };
            },
        }
    }
};
pub const Worker = @import("owned_worker.zig").Owner(Request, Result, error.InvalidOnboardingGeneration);
pub fn open(gpa: std.mem.Allocator, io: std.Io, location: []const u8, selected_collection: ?[]const u8) !Opened {
    if (!std.fs.path.isAbsolute(location)) return error.AbsoluteProjectPathRequired;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var root = try std.Io.Dir.cwd().openDir(io, location, .{});
    defer root.close(io);
    var workspace: ?p.collection.Loaded = p.collection.load(gpa, io, root) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (workspace) |*value| value.deinit();
    if (workspace) |value| if (value.manifest.projects.len == 0) {
        const path = try a.dupe(u8, location);
        return .{ .arena = arena, .model = null, .path = path, .collection = path };
    };
    const path = if (workspace) |value| blk: {
        break :blk try std.fs.path.join(a, &.{ location, value.manifest.projects[0].directory });
    } else try a.dupe(u8, location);
    var directory = if (workspace) |value| try p.collection.openProject(io, root, value.manifest.projects[0].directory) else try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    const bytes = try directory.readFileAlloc(io, "project.zon", a, .limited(p.Limits.document_bytes));
    const document = try p.parse(a, bytes, null);
    var board = try boards.OwnedBoard.fromDocument(gpa, document);
    defer board.deinit();
    var loaded = try p.snapshot.load(gpa, io, directory, board.board);
    defer loaded.deinit();
    const collection = if (workspace != null) try a.dupe(u8, location) else if (selected_collection) |value| try a.dupe(u8, value) else null;
    return .{ .arena = arena, .model = try Model.init(gpa, board.board, loaded.snapshot), .path = path, .collection = collection };
}
