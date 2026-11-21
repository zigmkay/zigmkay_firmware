//! Owned profile associations. Existing project files always win over templates.
//! Versioned preference output leaves the original four-slot file untouched.
const std = @import("std");
const p = @import("project");
pub const filename = "profile-projects-v1.zon";
pub const legacy_filename = "profile-projects.zon";
pub const Key = struct { board_id: [8]u8, profile_id: [8]u8 };
pub const Entry = struct { key: Key, directory: []const u8 };
const Document = struct { version: u8 = 1, entries: []const Entry };

fn validateKey(key: Key) !void {
    for ([_][8]u8{ key.board_id, key.profile_id }) |id| {
        var ended = false;
        if (id[0] == 0) return error.InvalidProfileIdentity;
        for (id) |byte| {
            if (byte == 0) {
                ended = true;
                continue;
            }
            if (ended or
                !(byte >= 'a' and byte <= 'z' or byte >= '0' and byte <= '9' or byte == '_'))
                return error.InvalidProfileIdentity;
        }
    }
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or
        path.len >= 1024 or
        !std.fs.path.isAbsolute(path) or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidProjectPath;
    if (@import("builtin").os.tag == .windows) {
        const kind = std.fs.path.parsePathWindows(u8, path).kind;
        if (kind != .drive_absolute and kind != .unc_absolute) return error.InvalidProjectPath;
    }
}

pub const Registry = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |entry| self.gpa.free(entry.directory);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn path(self: *const Registry, key: Key) ?[]const u8 {
        for (self.entries.items) |entry| if (std.meta.eql(entry.key, key)) return entry.directory;
        return null;
    }

    pub fn set(self: *Registry, key: Key, directory: []const u8) !void {
        try validateKey(key);
        try validatePath(directory);
        const owned = try self.gpa.dupe(u8, directory);
        errdefer self.gpa.free(owned);
        for (self.entries.items) |*entry| if (std.meta.eql(entry.key, key)) {
            self.gpa.free(entry.directory);
            entry.directory = owned;
            return;
        };
        if (self.entries.items.len >= 256) return error.TooManyProfiles;
        try self.entries.append(self.gpa, .{ .key = key, .directory = owned });
    }

    fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Registry {
        if (bytes.len > 512 * 1024) return error.PreferenceTooLarge;
        const text = try gpa.dupeSentinel(u8, bytes, 0);
        defer gpa.free(text);
        const doc = try p.owned_zon.parse(Document, gpa, text);
        defer p.owned_zon.free(gpa, doc);
        if (doc.version != 1) return error.UnsupportedProfilePreferenceVersion;
        var registry = Registry.init(gpa);
        errdefer registry.deinit();
        for (doc.entries) |entry| {
            if (registry.path(entry.key) != null) return error.DuplicateProfile;
            try registry.set(entry.key, entry.directory);
        }
        return registry;
    }

    /// Missing modern preferences may import the old array only with an exact
    /// caller-supplied slot binding. The legacy file remains byte-exact.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, legacy_keys: ?*const [4]Key) !Registry {
        const modern = dir.readFileAlloc(io, filename, gpa, .limited(512 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (modern) |bytes| {
            defer gpa.free(bytes);
            return parse(gpa, bytes);
        }
        const legacy = dir.readFileAlloc(io, legacy_filename, gpa, .limited(65536)) catch |err| switch (err) {
            error.FileNotFound => return Registry.init(gpa),
            else => return err,
        };
        defer gpa.free(legacy);
        const keys = legacy_keys orelse return error.LegacyProfileBindingRequired;
        const text = try gpa.dupeSentinel(u8, legacy, 0);
        defer gpa.free(text);
        const paths = try p.owned_zon.parse([4][]const u8, gpa, text);
        defer p.owned_zon.free(gpa, paths);
        var registry = Registry.init(gpa);
        errdefer registry.deinit();
        for (keys, 0..) |key, index| {
            try validateKey(key);
            for (keys[0..index]) |earlier| if (std.meta.eql(key, earlier)) return error.DuplicateProfile;
            if (paths[index].len != 0) try registry.set(key, paths[index]);
        }
        return registry;
    }

    pub fn save(self: *const Registry, io: std.Io, dir: std.Io.Dir) !void {
        if (self.entries.items.len > 256) return error.TooManyProfiles;
        for (self.entries.items, 0..) |entry, index| {
            try validateKey(entry.key);
            try validatePath(entry.directory);
            for (self.entries.items[0..index]) |earlier| {
                if (std.meta.eql(entry.key, earlier.key)) return error.DuplicateProfile;
            }
        }
        // Preserve unsupported/corrupt modern evidence before any replacement.
        var previous = load(self.gpa, io, dir, null) catch |err| switch (err) {
            error.LegacyProfileBindingRequired => Registry.init(self.gpa),
            else => return err,
        };
        defer previous.deinit();
        var writer: std.Io.Writer.Allocating = .init(self.gpa);
        defer writer.deinit();
        try std.zon.stringify.serialize(Document{ .entries = self.entries.items }, .{}, &writer.writer);
        var file = try dir.createFileAtomic(io, filename, .{ .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, writer.written());
        try file.file.sync(io);
        try file.replace(io);
    }
};

/// Caller supplies a selected board/template; no hardcoded profile or board.
/// Existing project.zon is opened and validated; a failed open never replaces it.
pub fn open(
    model: *@import("model.zig").Model,
    io: std.Io,
    directory: []const u8,
    template: p.snapshot.Snapshot,
) !void {
    try validatePath(directory);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, directory, .{});
    defer dir.close(io);
    dir.access(io, "project.zon", .{}) catch |err| switch (err) {
        error.FileNotFound => try p.snapshot.save(model.gpa, io, dir, template, model.board),
        else => return err,
    };
    try model.open(io, dir);
}

test "registry owns Unicode paths and migrates slots without overwriting the original" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const personal = try std.fs.path.join(gpa, &.{ root, "Zoë project" });
    defer gpa.free(personal);
    const other = try std.fs.path.join(gpa, &.{ root, "other" });
    defer gpa.free(other);
    var legacy_writer: std.Io.Writer.Allocating = .init(gpa);
    defer legacy_writer.deinit();
    try std.zon.stringify.serialize([4][]const u8{ personal, "", other, "" }, .{}, &legacy_writer.writer);
    const legacy = legacy_writer.written();
    try tmp.dir.writeFile(io, .{ .sub_path = legacy_filename, .data = legacy });
    const keys: [4]Key = .{
        .{ .board_id = "board1\x00\x00".*, .profile_id = "one\x00\x00\x00\x00\x00".* },
        .{ .board_id = "board1\x00\x00".*, .profile_id = "two\x00\x00\x00\x00\x00".* },
        .{ .board_id = "board2\x00\x00".*, .profile_id = "one\x00\x00\x00\x00\x00".* },
        .{ .board_id = "board2\x00\x00".*, .profile_id = "two\x00\x00\x00\x00\x00".* },
    };
    try std.testing.expectError(error.LegacyProfileBindingRequired, Registry.load(gpa, io, tmp.dir, null));
    var registry = try Registry.load(gpa, io, tmp.dir, &keys);
    defer registry.deinit();
    try std.testing.expectEqualStrings(personal, registry.path(keys[0]).?);
    try registry.save(io, tmp.dir);
    var reopened = try Registry.load(gpa, io, tmp.dir, null);
    defer reopened.deinit();
    try std.testing.expectEqualStrings(other, reopened.path(keys[2]).?);
    const original = try tmp.dir.readFileAlloc(io, legacy_filename, gpa, .limited(65536));
    defer gpa.free(original);
    try std.testing.expectEqualStrings(legacy, original);
    try std.testing.expectError(error.InvalidProjectPath, registry.set(keys[0], "relative"));
    const future = ".{ .version = 2, .entries = .{} }\n";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = future });
    try std.testing.expectError(error.UnsupportedProfilePreferenceVersion, registry.save(io, tmp.dir));
    const preserved = try tmp.dir.readFileAlloc(io, filename, gpa, .limited(65536));
    defer gpa.free(preserved);
    try std.testing.expectEqualStrings(future, preserved);
}

test "existing personal projects win over templates and corrupt files are preserved" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const directory = try std.fs.path.join(gpa, &.{ root, "personal" });
    defer gpa.free(directory);
    var first = try p.profiles.create(gpa, .qwerty);
    defer first.deinit();
    var second = try p.profiles.create(gpa, .eurkey);
    defer second.deinit();
    const Model = @import("model.zig").Model;
    var model = try Model.init(gpa, p.profiles.board, first.snapshot);
    defer model.deinit();
    try open(&model, io, directory, first.snapshot);
    try model.rename("Personal original");
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{});
    defer dir.close(io);
    try model.save(io, dir);
    const saved = try model.id();
    try open(&model, io, directory, second.snapshot);
    try std.testing.expectEqual(saved, try model.id());
    const broken = "opaque unsupported personal project\n";
    try dir.writeFile(io, .{ .sub_path = "project.zon", .data = broken });
    if (open(&model, io, directory, second.snapshot)) |_| return error.ExpectedInvalidProject else |_| {}
    try std.testing.expectEqual(saved, try model.id());
    const preserved = try dir.readFileAlloc(io, "project.zon", gpa, .limited(4096));
    defer gpa.free(preserved);
    try std.testing.expectEqualStrings(broken, preserved);
}
