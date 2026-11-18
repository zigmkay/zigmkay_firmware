//! Explicit project IO over frozen requests. No startup writes or source execution.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
pub const Kind = enum { save, export_zig, open, restore };
pub const ReplacePolicy = enum { require_clean, discard_confirmed };

pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    loaded: p.snapshot.Loaded,
    board: p.Board,
    captured: [32]u8,
    expected_saved: [32]u8,
    path: []const u8,
    kind: Kind,
    replace_policy: ReplacePolicy = .require_clean,

    pub fn capture(model: *const Model, kind: Kind, path: []const u8) !Request {
        return captureBoard(model, kind, path, model.board);
    }

    /// Other-board opening requires an explicitly selected authoritative contract.
    pub fn openForBoard(model: *const Model, path: []const u8, board: p.Board) !Request {
        return captureBoard(model, .open, path, board);
    }

    pub fn openDiscardConfirmed(model: *const Model, path: []const u8, board: p.Board) !Request {
        var request = try captureBoard(model, .open, path, board);
        request.replace_policy = .discard_confirmed;
        return request;
    }

    fn captureBoard(model: *const Model, kind: Kind, path: []const u8, board: p.Board) !Request {
        if (!std.fs.path.isAbsolute(path) or
            path.len > 4095 or
            std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidProjectPath;
        var arena: std.heap.ArenaAllocator = .init(model.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_board = try p.owned_zon.clone(a, board);
        const owned_path = try a.dupe(u8, path);
        var loaded = try p.snapshot.clone(model.gpa, model.current.snapshot);
        errdefer loaded.deinit();
        const digest = try model.id();
        return .{
            .arena = arena,
            .loaded = loaded,
            .board = owned_board,
            .captured = digest,
            .expected_saved = model.saved_id,
            .path = owned_path,
            .kind = kind,
        };
    }

    pub fn deinit(self: *Request) void {
        self.loaded.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Call only for an explicit path action. The caller owns worker scheduling.
    pub fn prepare(self: *const Request, gpa: std.mem.Allocator, io: std.Io) !Prepared {
        var dir = if (self.kind == .save or self.kind == .export_zig)
            try std.Io.Dir.cwd().createDirPathOpen(io, self.path, .{})
        else
            try std.Io.Dir.cwd().openDir(io, self.path, .{});
        defer dir.close(io);
        var result = Prepared{
            .captured = self.captured,
            .expected_saved = self.expected_saved,
            .kind = self.kind,
            .replace_policy = self.replace_policy,
        };
        switch (self.kind) {
            .save => {
                try p.snapshot.saveChecked(
                    gpa,
                    io,
                    dir,
                    self.loaded.snapshot,
                    self.board,
                    self.expected_saved,
                );
            },
            .export_zig => {
                const manifest = try p.exporter.write(gpa, io, dir, self.loaded.snapshot, self.board);
                defer p.exporter.freeManifest(gpa, manifest);
                result.exported = manifest.snapshot_id;
            },
            .open, .restore => {
                var loaded = try p.snapshot.load(gpa, io, dir, self.board);
                defer loaded.deinit();
                if (self.kind == .open) result.opened = try Model.init(
                    gpa,
                    self.board,
                    loaded.snapshot,
                ) else result.restored = try p.snapshot.clone(gpa, loaded.snapshot);
            },
        }
        return result;
    }
};

pub const Prepared = struct {
    captured: [32]u8,
    expected_saved: [32]u8,
    kind: Kind,
    replace_policy: ReplacePolicy,
    exported: ?[32]u8 = null,
    opened: ?Model = null,
    restored: ?p.snapshot.Loaded = null,
    consumed: bool = false,

    pub fn deinit(self: *Prepared) void {
        if (self.opened) |*model| model.deinit();
        if (self.restored) |*snapshot| snapshot.deinit();
        self.* = undefined;
    }

    /// The caller checks document ownership and destination before delivery.
    /// A completed save advances the disk baseline even when newer edits stay dirty.
    pub fn promote(self: *Prepared, model: *Model) !void {
        if (self.consumed) return error.StaleProjectAction;
        if (self.kind == .save) {
            if (!std.mem.eql(u8, &model.saved_id, &self.expected_saved)) return error.StaleProjectAction;
            model.saved_id = self.captured;
            self.consumed = true;
            if (!std.mem.eql(u8, &self.captured, &(try model.id()))) return error.StaleProjectAction;
            return;
        }
        if (!std.mem.eql(u8, &self.captured, &(try model.id()))) return error.StaleProjectAction;
        switch (self.kind) {
            .save => unreachable,
            .export_zig => {},
            .open => {
                if (self.replace_policy == .require_clean and
                    !std.mem.eql(u8, &model.saved_id, &self.captured)) return error.UnsavedProjectChanges;
                const replacement = self.opened orelse return error.InvalidProjectResult;
                model.deinit();
                model.* = replacement;
                self.opened = null;
            },
            .restore => try model.commit((self.restored orelse return error.InvalidProjectResult).snapshot),
        }
        self.consumed = true;
    }
};
