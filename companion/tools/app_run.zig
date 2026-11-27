//! AppDir entrypoint. Derive paths from this executable, never APPDIR or cwd.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const executable = try std.process.executablePathAlloc(init.io, a);
    const root = std.fs.path.dirname(executable) orelse return error.InvalidApplicationPath;
    const application = try std.fs.path.join(a, &.{ root, "usr/bin/zigmkay-companion" });
    const libraries = try std.fs.path.join(a, &.{ root, "usr/lib" });
    try init.environ_map.put("LD_LIBRARY_PATH", libraries);
    // Release packaging bundles XKB layout and Compose data matching the bundled
    // libxkbcommon. A locally assembled AppDir links the host library and has
    // neither, so it keeps the host data.
    try putIfBundled(init, "XKB_CONFIG_ROOT", try std.fs.path.join(a, &.{ root, "usr/share/X11/xkb" }));
    try putIfBundled(init, "XLOCALEDIR", try std.fs.path.join(a, &.{ root, "usr/share/X11/locale" }));
    const original = try init.minimal.args.toSlice(a);
    const args = try a.alloc([]const u8, original.len);
    args[0] = application;
    @memcpy(args[1..], original[1..]);
    return std.process.replace(init.io, .{ .argv = args, .environ_map = init.environ_map });
}

fn putIfBundled(init: std.process.Init, name: []const u8, directory: []const u8) !void {
    std.Io.Dir.accessAbsolute(init.io, directory, .{}) catch return;
    try init.environ_map.put(name, directory);
}
