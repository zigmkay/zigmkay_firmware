//! Executable overlay for a self-contained Windows distribution. Shipped bytes
//! are unpacked only when a build needs filesystem-backed compiler resources.
const std = @import("std");
const bundle = @import("application_bundle.zig");
const magic = "ZIGMKAYBUNDLE001";
pub const Header = struct { manifest: bundle.Manifest, offset: u64, executable: []const u8 };

pub fn header(a: std.mem.Allocator, io: std.Io, executable: []const u8) !Header {
    const file = try std.Io.Dir.cwd().openFile(io, executable, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size < 24) return error.MissingApplicationPayload;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.seekTo(size - 24);
    const offset = try reader.interface.takeInt(u64, .little);
    if (!std.mem.eql(u8, try reader.interface.take(16), magic) or
        offset >= size - 24) return error.MissingApplicationPayload;
    try reader.seekTo(offset);
    const length = try reader.interface.takeInt(u32, .little);
    if (length > 8192 or
        size - 24 - offset < 4 or
        length > size - 24 - offset - 4) return error.InvalidApplicationPayload;
    const bytes = try reader.interface.readAlloc(a, length);
    const manifest = try @import("owned-zon").parse(bundle.Manifest, a, try a.dupeSentinel(u8, bytes, 0));
    try manifest.validate();
    return .{ .manifest = manifest, .offset = offset + 4 + length, .executable = try a.dupe(u8, executable) };
}

pub fn safePath(path: []const u8) bool {
    if (path.len == 0 or
        path.len > 4096 or
        std.fs.path.isAbsolute(path) or
        std.mem.indexOfAny(u8, path, "\\:\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
        for (part) |byte| if (byte < 32 or std.mem.indexOfScalar(u8, "<>\"|?*", byte) != null) return false;
        const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{
            "CON",
            "PRN",
            "AUX",
            "NUL",
            "COM1",
            "COM2",
            "COM3",
            "COM4",
            "COM5",
            "COM6",
            "COM7",
            "COM8",
            "COM9",
            "LPT1",
            "LPT2",
            "LPT3",
            "LPT4",
            "LPT5",
            "LPT6",
            "LPT7",
            "LPT8",
            "LPT9",
        }) |reserved| if (std.ascii.eqlIgnoreCase(stem, reserved)) return false;
    }
    return true;
}

pub fn materialize(gpa: std.mem.Allocator, io: std.Io, executable: []const u8, root: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const info = try header(a, io, executable);
    const marker = try std.fs.path.join(a, &.{ root, ".complete" });
    // Completed resources are immutable and may be mounted or ACL-protected
    // read-only. Inspect them before attempting any extraction writes.
    if (try complete(a, io, marker, info.manifest.id)) return;
    const parent = std.fs.path.dirname(root) orelse return error.InvalidBundlePath;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    const lock = try std.Io.Dir.cwd().createFile(
        io,
        try std.fmt.allocPrint(a, "{s}.lock", .{root}),
        .{ .truncate = false, .lock = .exclusive },
    );
    defer lock.close(io);
    // Another extractor may have completed while this caller waited for the lock.
    if (try complete(a, io, marker, info.manifest.id)) return;
    const staging = try std.fmt.allocPrint(a, "{s}.unpacking", .{root});
    try std.Io.Dir.cwd().deleteTree(io, staging);
    try std.Io.Dir.cwd().createDirPath(io, staging);
    errdefer std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    const file = try std.Io.Dir.cwd().openFile(io, executable, .{});
    defer file.close(io);
    const size = try file.length(io);
    var buffer: [65536]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.seekTo(info.offset);
    var consumed = info.offset;
    while (true) {
        if (consumed > size - 24 or size - 24 - consumed < 4) return error.InvalidApplicationPayload;
        const length = try reader.interface.takeInt(u32, .little);
        consumed += 4;
        if (length == 0) break;
        if (length > 4096 or size - 24 - consumed < @as(u64, length) + 8) return error.InvalidApplicationPayload;
        const path = try reader.interface.readAlloc(a, length);
        if (!safePath(path)) return error.InvalidApplicationPayload;
        const count = try reader.interface.takeInt(u64, .little);
        consumed += length + 8;
        if (count > size - 24 or consumed > size - 24 - count) return error.InvalidApplicationPayload;
        const destination = try std.fs.path.join(a, &.{ staging, path });
        if (std.fs.path.dirname(destination)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        const output = try std.Io.Dir.cwd().createFile(io, destination, .{ .exclusive = true });
        defer output.close(io);
        var remaining = count;
        while (remaining != 0) {
            const chunk = @min(remaining, 65536);
            try output.writeStreamingAll(io, try reader.interface.take(@intCast(chunk)));
            remaining -= chunk;
        }
        consumed += count;
    }
    if (consumed != size - 24) return error.InvalidApplicationPayload;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ staging, ".complete" }),
        .data = &info.manifest.id,
    });
    // Only an incomplete, application-owned extraction may be replaced.
    try std.Io.Dir.cwd().deleteTree(io, root);
    try std.Io.Dir.renameAbsolute(staging, root, io);
}

fn complete(a: std.mem.Allocator, io: std.Io, marker: []const u8, id: [32]u8) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(64)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (!std.mem.eql(u8, bytes, &id)) return error.InvalidApplicationPayload;
    return true;
}

fn addTree(
    a: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    root: []const u8,
    relative: []const u8,
) anyerror!void {
    const path = try std.fs.path.join(a, &.{ root, relative });
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind == .directory) {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| try names.append(a, try a.dupe(u8, entry.name));
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.less);
        for (names.items) |name| try addTree(
            a,
            io,
            writer,
            root,
            try std.fs.path.join(a, &.{ relative, name }),
        );
    } else if (stat.kind == .file) {
        const portable = try a.dupe(u8, relative);
        std.mem.replaceScalar(u8, portable, '\\', '/');
        if (!safePath(portable)) return error.InvalidApplicationPayload;
        try writer.writeInt(u32, @intCast(portable.len), .little);
        try writer.writeAll(portable);
        try writer.writeInt(u64, stat.size, .little);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buffer: [65536]u8 = undefined;
        var reader = file.reader(io, &buffer);
        _ = try reader.interface.streamRemaining(writer);
    } else return error.InvalidApplicationPayload;
}

pub fn pack(
    a: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    resources: []const u8,
    destination: []const u8,
) !void {
    try std.Io.Dir.cwd().copyFile(source, .cwd(), destination, io, .{ .make_path = true });
    const file = try std.Io.Dir.cwd().openFile(io, destination, .{ .mode = .read_write });
    defer file.close(io);
    const offset = try file.length(io);
    var buffer: [65536]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.seekTo(offset);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try std.fs.path.join(a, &.{ resources, "application.zon" }),
        a,
        .limited(8192),
    );
    try writer.interface.writeInt(u32, @intCast(manifest.len), .little);
    try writer.interface.writeAll(manifest);
    try addTree(a, io, &writer.interface, resources, "");
    try writer.interface.writeInt(u32, 0, .little);
    try writer.interface.writeInt(u64, offset, .little);
    try writer.interface.writeAll(magic);
    try writer.interface.flush();
}

test "payload rejects absolute and traversing paths" {
    try std.testing.expect(safePath("toolchain/lib/std/std.zig"));
    for ([_][]const u8{
        "../escape",
        "/absolute",
        "C:/drive",
        "a/../../escape",
        "a\\b",
        "a//b",
        "a/.. /escape",
        "a/NUL.txt",
        "a/com1",
        "a/end.",
        "a/end ",
        "a/line\nfeed",
    }) |path| try std.testing.expect(!safePath(path));
}

test "single executable materializes shipped bytes once and recovers an interrupted extraction" {
    const t = std.testing;
    const io = t.io;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "editor", .data = "executable fixture" });
    try tmp.dir.createDirPath(io, "resources/toolchain/lib");
    try tmp.dir.writeFile(io, .{
        .sub_path = "resources/toolchain/lib/input",
        .data = "shipped compiler input",
    });
    const manifest: bundle.Manifest = .{
        .id = @splat(7),
        .firmware_revision = "83b689262ae4a6f814ba9c7aa9fa868bf734350f",
        .wrapper_hash = @splat(1),
        .picotool_hash = @splat(2),
    };
    var text: std.Io.Writer.Allocating = .init(a);
    try std.zon.stringify.serialize(manifest, .{}, &text.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "resources/application.zon", .data = text.written() });
    const executable = try std.fs.path.join(a, &.{ root, "standalone.exe" });
    try pack(
        a,
        io,
        try std.fs.path.join(a, &.{ root, "editor" }),
        try std.fs.path.join(a, &.{ root, "resources" }),
        executable,
    );
    var application = try bundle.Bundle.fromExecutable(t.allocator, io, executable, root);
    defer application.deinit();
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, application.root, .{}));
    const staging = try std.fmt.allocPrint(a, "{s}.unpacking", .{application.root});
    try std.Io.Dir.cwd().createDirPath(io, staging);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ staging, "interrupted" }),
        .data = "partial",
    });
    try materialize(t.allocator, io, executable, application.root);
    const input = try std.Io.Dir.cwd().readFileAlloc(
        io,
        try application.path(a, "toolchain/lib/input"),
        a,
        .limited(64),
    );
    try t.expectEqualStrings("shipped compiler input", input);
    // A warm call reads only the completion marker, rather than rewriting inputs.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try application.path(a, "retained"), .data = "warm" });
    // A directory at the lock path makes opening a write lock fail on every
    // platform, including Windows, without relying on POSIX chmod semantics.
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{application.root});
    try std.Io.Dir.cwd().deleteFile(io, lock_path);
    try std.Io.Dir.cwd().createDir(io, lock_path, .default_dir);
    try materialize(t.allocator, io, executable, application.root);
    try t.expectEqualStrings(
        "warm",
        try std.Io.Dir.cwd().readFileAlloc(io, try application.path(a, "retained"), a, .limited(64)),
    );
    const marker = try application.path(a, ".complete");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "invalid bundle identity" });
    try t.expectError(
        error.InvalidApplicationPayload,
        materialize(t.allocator, io, executable, application.root),
    );
}
