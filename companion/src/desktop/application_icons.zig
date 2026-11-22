//! Embedded logo variants produced from packaging/icons/zigmkay.svg.
const std = @import("std");

pub const tray_png = @embedFile("tray.png");
pub const tray_template_png = @embedFile("tray-template.png");
pub const tray_ico = @embedFile("tray.ico");
pub const window_png = @embedFile("window.png");
pub const window_2x_png = @embedFile("window@2x.png");

test "embedded tray images retain the key outline, cutout, and platform color" {
    const c = @import("dvui").c;
    for ([_]struct { png: []const u8, size: c_int, rgb: [3]u8 }{
        .{ .png = tray_png, .size = 24, .rgb = .{ 0xff, 0xab, 0x20 } },
        .{ .png = tray_template_png, .size = 36, .rgb = .{ 0, 0, 0 } },
    }) |variant| {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const pixels = c.stbi_load_from_memory(variant.png.ptr, @intCast(variant.png.len), &width, &height, &channels, 4);
        try std.testing.expect(pixels != null);
        defer c.stbi_image_free(pixels);
        try std.testing.expectEqual(variant.size, width);
        try std.testing.expectEqual(variant.size, height);
        const size: usize = @intCast(width);
        try std.testing.expectEqual(@as(u8, 0), pixels[3]);
        const top = (size / 20 * size + size / 2) * 4;
        try std.testing.expect(pixels[top + 3] > 128);
        const cutout = ((size / 10) * size + size / 2) * 4;
        try std.testing.expectEqual(@as(u8, 0), pixels[cutout + 3]);
        const base = ((size * 5 / 6) * size + size / 2) * 4;
        try std.testing.expectEqual(variant.rgb ++ [1]u8{255}, pixels[base..][0..4].*);
    }
}
