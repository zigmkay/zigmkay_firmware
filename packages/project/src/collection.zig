//! Portable membership over ordinary schema-1 projects. No startup writes.
const std = @import("std");
const p = @import("root.zig");
pub const Entry = struct { id: []const u8, directory: []const u8 };
pub const Manifest = struct { version: u32 = 1, projects: []const Entry = &.{} };
pub const ignore = ".zig-cache/\nzig-out/\n.project.lock\n.workspace.lock\n*.tmp\nexport/\nbuilds/\npractice*.db*\n";
/// Open a contained child without following any directory links.
pub fn openProject(io: std.Io, root: std.Io.Dir, relative: []const u8) !std.Io.Dir {
    if (!@import("portable_path.zig").valid(relative, 512)) return error.InvalidCollectionPath;
    var current = root;
    var owns = false;
    errdefer if (owns) current.close(io);
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        const next = try current.openDir(io, part, .{ .follow_symlinks = false });
        if (owns) current.close(io);
        current = next;
        owns = true;
    }
    return current;
}
pub fn validate(value: Manifest) !void {
    if (value.version != 1) return error.UnsupportedCollectionVersion;
    if (value.projects.len > 256) return error.CollectionLimit;
    for (value.projects, 0..) |entry, i| {
        if (!@import("portable_path.zig").valid(entry.id, 128) or std.mem.indexOfScalar(u8, entry.id, '/') != null or !@import("portable_path.zig").valid(entry.directory, 512)) return error.InvalidCollectionPath;
        for (value.projects[0..i]) |old| {
            if (std.mem.eql(u8, old.id, entry.id) or std.mem.eql(u8, old.directory, entry.directory)) return error.DuplicateCollectionEntry;
            if (nested(old.directory, entry.directory) or nested(entry.directory, old.directory)) return error.OverlappingCollectionProjects;
        }
    }
}
fn nested(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    manifest: Manifest,
    fingerprint: [32]u8,
    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Loaded {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const bytes = try dir.readFileAlloc(io, "workspace.zon", a, .limited(128 * 1024));
    const value = try p.owned_zon.parse(Manifest, a, try a.dupeSentinel(u8, bytes, 0));
    try validate(value);
    return .{ .arena = arena, .manifest = value, .fingerprint = digest(bytes) };
}
fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
/// Membership is published last. Detect external manifest edits under a stable lock.
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, value: Manifest, expected: ?[32]u8) !void {
    try validate(value);
    const lock = try dir.createFile(io, ".workspace.lock", .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    if (expected) |baseline| {
        var current = try load(gpa, io, dir);
        defer current.deinit();
        if (!std.mem.eql(u8, &baseline, &current.fingerprint)) return error.CollectionChangedExternally;
    } else {
        if (dir.statFile(io, "workspace.zon", .{})) |_| return error.CollectionAlreadyExists else |err| if (err != error.FileNotFound) return err;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serialize(value, .{}, &out.writer);
    // Prepare auxiliary files before the membership publication. Never replace
    // a user's ignore file, and retain source/provenance directories in Git.
    const ignored = dir.createFile(io, ".gitignore", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };
    if (ignored) |ignore_file| {
        defer ignore_file.close(io);
        try ignore_file.writeStreamingAll(io, ignore);
    }
    var file = try dir.createFileAtomic(io, "workspace.zon", .{ .replace = expected != null });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, out.written());
    try file.file.sync(io);
    if (expected != null) try file.replace(io) else try file.link(io);
}
pub fn append(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, entry: Entry, expected: ?[32]u8) !void {
    var current: ?Loaded = if (expected != null) try load(gpa, io, dir) else null;
    defer if (current) |*value| value.deinit();
    const old: []const Entry = if (current) |value| value.manifest.projects else &.{};
    const entries = try gpa.alloc(Entry, old.len + 1);
    defer gpa.free(entries);
    @memcpy(entries[0..old.len], old);
    entries[old.len] = entry;
    try save(gpa, io, dir, .{ .projects = entries }, expected);
}

test "portable collection rejects ambiguous paths and detects external edits" {
    const t = std.testing;
    try t.expectError(error.InvalidCollectionPath, validate(.{ .projects = &.{.{ .id = "x", .directory = "../escape" }} }));
    try t.expectError(error.DuplicateCollectionEntry, validate(.{ .projects = &.{ .{ .id = "x", .directory = "keyboards/a" }, .{ .id = "x", .directory = "keyboards/b" } } }));
    try t.expectError(error.UnsupportedCollectionVersion, validate(.{ .version = 2 }));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try append(t.allocator, t.io, tmp.dir, .{ .id = "first", .directory = "keyboards/one" }, null);
    var loaded = try load(t.allocator, t.io, tmp.dir);
    defer loaded.deinit();
    try append(t.allocator, t.io, tmp.dir, .{ .id = "second", .directory = "keyboards/two" }, loaded.fingerprint);
    try t.expectError(error.CollectionChangedExternally, append(t.allocator, t.io, tmp.dir, .{ .id = "third", .directory = "keyboards/three" }, loaded.fingerprint));
    try t.expect(std.mem.indexOf(u8, ignore, ".sources") == null);
}
