//! Owned, verified exported source bytes shared by build setup and managed jobs.
const std = @import("std");
pub const contract = @import("build_contract.zig");
pub const File = struct { path: []const u8, bytes: []const u8 };

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    manifest: contract.Manifest,
    files: []const File,
    source_digest: [32]u8,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn portablePath(path: []const u8) bool {
    return @import("portable_path.zig").valid(path, 512);
}

pub fn listed(manifest: contract.Manifest, path: []const u8) !void {
    for (manifest.files) |file| if (std.mem.eql(u8, file.path, path)) return;
    return error.UnlistedExportFile;
}

pub fn read(comptime zon: type, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Owned {
    if (!std.fs.path.isAbsolute(path)) return error.ProfilePathMustBeAbsolute;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const root = try dir.realPathFileAlloc(io, ".", a);
    try contained(a, io, dir, root, "manifest.zon");
    const bytes = try dir.readFileAlloc(io, "manifest.zon", a, .limited(1024 * 1024));
    const text = try a.dupeSentinel(u8, bytes, 0);
    const manifest = try zon.parse(contract.Manifest, a, text);
    if (manifest.version != contract.version or
        manifest.files.len == 0 or
        manifest.files.len > 65 or
        manifest.callbacks.len > 64 or
        !portablePath(manifest.keymap)) return error.InvalidExportManifest;
    const files = try a.alloc(File, manifest.files.len);
    var total: usize = 0;
    for (manifest.files, files, 0..) |file, *captured, index| {
        if (!portablePath(file.path)) return error.InvalidExportPath;
        try contained(a, io, dir, root, file.path);
        for (manifest.files[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.path, file.path)) return error.DuplicateExportFile;
        }
        const data = try dir.readFileAlloc(io, file.path, a, .limited(4 * 1024 * 1024));
        total += data.len;
        if (total > 6 * 1024 * 1024) return error.ExportTooLarge;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        if (!std.mem.eql(u8, &digest, &file.digest)) return error.ExportSourceMismatch;
        captured.* = .{ .path = file.path, .bytes = data };
    }
    try listed(manifest, manifest.keymap);
    for (manifest.callbacks) |callback| {
        if (!portablePath(callback.entry)) return error.InvalidExportPath;
        try listed(manifest, callback.entry);
    }
    // Bind the exact manifest plus sorted source paths and bytes; independent of cwd.
    const sorted = try a.dupe(File, files);
    std.mem.sort(File, sorted, {}, struct {
        fn less(_: void, lhs: File, rhs: File) bool {
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-exported-source-inventory-v1\x00");
    framed(&hash, bytes);
    for (sorted) |file| {
        framed(&hash, file.path);
        framed(&hash, file.bytes);
    }
    return .{ .arena = arena, .manifest = manifest, .files = files, .source_digest = hash.finalResult() };
}

fn framed(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, bytes.len, .little);
    hash.update(&size);
    hash.update(bytes);
}

fn contained(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, root: []const u8, path: []const u8) !void {
    const actual = try dir.realPathFileAlloc(io, path, gpa);
    defer gpa.free(actual);
    if (!std.mem.startsWith(u8, actual, root) or
        actual.len <= root.len or
        !std.fs.path.isSep(actual[root.len])) return error.ExportSourceEscapesRoot;
}
