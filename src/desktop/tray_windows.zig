//! Supply ztray with a native multi-resolution ICO. Win32 loads the icon
//! synchronously, so the temporary file can be removed as soon as it returns.
const std = @import("std");
const ztray = @import("ztray");

extern "kernel32" fn GetTempPathW(u32, [*]u16) callconv(.winapi) u32;

pub fn install(allocator: std.mem.Allocator, io: std.Io, ico: []const u8) !void {
    var wide: [std.os.windows.MAX_PATH + 1]u16 = undefined;
    const len = GetTempPathW(wide.len, &wide);
    if (len == 0 or len >= wide.len) return error.TrayTempDirectoryUnavailable;
    const temp_path = try std.unicode.wtf16LeToWtf8Alloc(allocator, wide[0..len]);
    defer allocator.free(temp_path);

    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const path = try std.fmt.allocPrint(allocator, "{s}zigmkay-tray-{x}.ico", .{ temp_path, &nonce });
    defer allocator.free(path);
    const cwd: std.Io.Dir = .cwd();
    const file = try cwd.createFile(io, path, .{ .exclusive = true });
    defer cwd.deleteFile(io, path) catch {};
    {
        defer file.close(io);
        try file.writeStreamingAll(io, ico);
    }
    try ztray.installTrayIcon(allocator, .{ .tooltip = "Zigmkay is running", .icon_file = path });
}
