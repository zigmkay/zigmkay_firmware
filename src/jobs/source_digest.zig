//! Digests of exported project sources. No package acquisition or tool execution.
const std = @import("std");
const sources = @import("source_files.zig");
pub const Digest = [32]u8;

fn length(hash: *std.crypto.hash.sha2.Sha256, n: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, n, .little);
    hash.update(&bytes);
}

/// Hash the exact explicitly selected source root, including hidden source files.
/// Excludes only VCS/build outputs and resolved package caches. Dependencies have
/// their own lock digest; symlinks are rejected rather than silently escaping root.
pub fn treeDigest(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Digest {
    return tree(gpa, io, dir);
}

pub fn excludedDirectoryName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-pkg") or
        std.mem.eql(u8, name, ".slim");
}

fn excludedDirectory(_: []const u8, name: []const u8, kind: std.Io.File.Kind) bool {
    return kind == .directory and excludedDirectoryName(name);
}

fn tree(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Digest {
    const policy: sources.Policy = .{ .excluded = excludedDirectory, .max_files = 10_000 };
    const files = try sources.collect(gpa, io, dir, policy);
    defer sources.free(gpa, files);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-source-tree-v1\x00");
    var total: usize = 0;
    for (files) |file| {
        if (file.kind != .file) return error.UnsupportedSourceKind;
        const bytes = try dir.readFileAlloc(io, file.path, gpa, .limited(32 * 1024 * 1024));
        defer gpa.free(bytes);
        total += bytes.len;
        if (total > 128 * 1024 * 1024) return error.SourceTreeTooLarge;
        length(&hash, file.path.len);
        // Canonicalize directory separators for identical Windows/POSIX sources.
        for (file.path) |c| hash.update(&.{if (c == '\\') '/' else c});
        length(&hash, bytes.len);
        hash.update(bytes);
    }
    return hash.finalResult();
}

test "source trees ignore caches but retain hidden and non-Zig build inputs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "source" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigversion", .data = "0.17.0" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bridge.c", .data = "imported source" });
    const original = try treeDigest(gpa, io, tmp.dir);
    try tmp.dir.createDirPath(io, ".zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/output", .data = "ignored" });
    try std.testing.expectEqual(original, try treeDigest(gpa, io, tmp.dir));
    for ([_][]const u8{ ".zig-cache-flash-preparation", ".zig-cache2" }) |cache| {
        try tmp.dir.createDirPath(io, cache);
        const file = try std.fs.path.join(gpa, &.{ cache, "output" });
        defer gpa.free(file);
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "ignored" });
        try std.testing.expectEqual(original, try treeDigest(gpa, io, tmp.dir));
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "edited ignored bytes" });
        try std.testing.expectEqual(original, try treeDigest(gpa, io, tmp.dir));
    }
    try tmp.dir.createDirPath(io, ".slim/worktrees/nested/.slim");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".slim/worktrees/nested/.slim/source.zig",
        .data = "nested source",
    });
    try std.testing.expectEqual(original, try treeDigest(gpa, io, tmp.dir));
    try tmp.dir.writeFile(io, .{
        .sub_path = ".slim/worktrees/nested/.slim/source.zig",
        .data = "edited nested source",
    });
    try std.testing.expectEqual(original, try treeDigest(gpa, io, tmp.dir));
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache-note", .data = "hidden project input" });
    try std.testing.expect(!std.mem.eql(u8, &original, &try treeDigest(gpa, io, tmp.dir)));
    const with_note = try treeDigest(gpa, io, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache-note", .data = "edited hidden project input" });
    try std.testing.expect(!std.mem.eql(u8, &with_note, &try treeDigest(gpa, io, tmp.dir)));
    try tmp.dir.writeFile(io, .{ .sub_path = ".project-settings", .data = "hidden input" });
    try std.testing.expect(!std.mem.eql(u8, &original, &try treeDigest(gpa, io, tmp.dir)));
    try tmp.dir.writeFile(io, .{ .sub_path = "bridge.c", .data = "changed" });
    try std.testing.expect(!std.mem.eql(u8, &original, &try treeDigest(gpa, io, tmp.dir)));
}

test "exported source trees reject links" {
    const t = std.testing;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source.zig", .data = "source bytes" });
    try tmp.dir.symLink(t.io, "source.zig", "alias.zig", .{});
    try t.expectError(error.UnsupportedSourceKind, treeDigest(t.allocator, t.io, tmp.dir));
}

test "excluded directories ignore nested contents but same-named files remain inputs" {
    const t = std.testing;
    const names = [_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg" };
    for (names) |name| {
        try t.expect(excludedDirectory("nested", name, .directory));
        try t.expect(!excludedDirectory("nested", name, .file));
    }
    try t.expect(!excludedDirectory("nested", "ordinary", .directory));

    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source.zig", .data = "source" });
    const original = try treeDigest(t.allocator, t.io, tmp.dir);
    for (names) |name| {
        const nested = try std.fmt.allocPrint(t.allocator, "{s}/deep", .{name});
        defer t.allocator.free(nested);
        try tmp.dir.createDirPath(t.io, nested);
        const path = try std.fmt.allocPrint(t.allocator, "{s}/ignored.zig", .{nested});
        defer t.allocator.free(path);
        try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = "ignored contents" });
    }
    try t.expectEqual(original, try treeDigest(t.allocator, t.io, tmp.dir));
    try tmp.dir.createDirPath(t.io, "ordinary");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ordinary/kept.zig", .data = "kept" });
    try t.expect(!std.mem.eql(u8, &original, &try treeDigest(t.allocator, t.io, tmp.dir)));
}
