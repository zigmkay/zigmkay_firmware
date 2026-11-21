//! AppDir entrypoint. Derive paths from this executable, never APPDIR or cwd.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const executable = try std.process.executablePathAlloc(init.io, a);
    const root = std.fs.path.dirname(executable) orelse return error.InvalidApplicationPath;
    const application = try std.fs.path.join(a, &.{ root, "usr/bin/zigmkay-companion" });
    const libraries = try std.fs.path.join(a, &.{ root, "usr/lib" });
    try init.environ_map.put("LD_LIBRARY_PATH", libraries);
    try init.environ_map.put("XKB_CONFIG_ROOT", try std.fs.path.join(a, &.{ root, "usr/share/X11/xkb" }));
    const original = try init.minimal.args.toSlice(a);
    const args = try a.alloc([]const u8, original.len);
    args[0] = application;
    @memcpy(args[1..], original[1..]);
    return std.process.replace(init.io, .{ .argv = args, .environ_map = init.environ_map });
}
