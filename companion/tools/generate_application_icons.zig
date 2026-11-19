//! Rasterize the canonical logo and write the platform icon containers.
const std = @import("std");
const svg2tvg = @import("svg2tvg");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.Usage;
    const cwd: std.Io.Dir = .cwd();
    const source = try cwd.readFileAlloc(init.io, args[1], a, .limited(64 * 1024));
    const tvg = try svg2tvg.tvg_from_svg(a, source, .{});
    const output = try cwd.openDir(init.io, args[2], .{});
    defer output.close(init.io);

    const sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256, 512, 1024 };
    var pngs: [sizes.len][]const u8 = undefined;
    for (sizes, &pngs) |size, *png| png.* = try rasterize(init.gpa, a, tvg, size, false);
    try output.writeFile(init.io, .{ .sub_path = "application.png", .data = pngs[6] });
    try output.writeFile(init.io, .{ .sub_path = "window.png", .data = pngs[2] });
    try output.writeFile(init.io, .{ .sub_path = "window@2x.png", .data = pngs[4] });
    try output.writeFile(init.io, .{ .sub_path = "tray.png", .data = pngs[1] });
    try output.writeFile(init.io, .{ .sub_path = "tray-template.png", .data = try rasterize(init.gpa, a, tvg, 36, true) });

    const ico_sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256 };
    try output.writeFile(init.io, .{ .sub_path = "application.ico", .data = try ico(a, &ico_sizes, pngs[0..ico_sizes.len]) });
    try output.writeFile(init.io, .{ .sub_path = "tray.ico", .data = try ico(a, ico_sizes[0..3], pngs[0..3]) });

    const icns_types = [_]*const [4]u8{ "icp4", "icp5", "icp6", "ic07", "ic08", "ic09", "ic10", "ic11", "ic12", "ic13", "ic14" };
    const icns_pngs = [_][]const u8{ pngs[0], pngs[2], pngs[4], pngs[5], pngs[6], pngs[7], pngs[8], pngs[2], pngs[4], pngs[6], pngs[7] };
    try output.writeFile(init.io, .{ .sub_path = "Zigmkay.icns", .data = try icns(a, &icns_types, &icns_pngs) });
    try output.writeFile(init.io, .{ .sub_path = "application.rc", .data = "1 ICON \"application.ico\"\n" });
}

const Framebuffer = struct {
    width: usize,
    height: usize,
    pixels: [][4]u8,

    pub fn setPixel(self: Framebuffer, x: isize, y: isize, color: anytype) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const index = @as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x));
        self.pixels[index] = if (@TypeOf(color) == [4]u8) color else color.toRgba8();
    }
};

fn rasterize(gpa: std.mem.Allocator, a: std.mem.Allocator, tvg: []const u8, size: u32, template: bool) ![]const u8 {
    // Supersample the single-color logo to preserve its outline at tray sizes.
    const scale: usize = if (size <= 256) 4 else 2;
    const width = size * scale;
    const samples = try gpa.alloc([4]u8, width * width);
    defer gpa.free(samples);
    @memset(samples, .{ 0, 0, 0, 0 });
    var reader: std.Io.Reader = .fixed(tvg);
    try svg2tvg.tvg.renderStream(gpa, Framebuffer{ .width = width, .height = width, .pixels = samples }, &reader);

    var compressed = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
    defer compressed.deinit();
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib = try std.compress.flate.Compress.init(&compressed.writer, &history, .zlib, .default);
    var row: [1024][4]u8 = undefined;
    for (0..size) |y| {
        for (row[0..size], 0..) |*pixel, x| {
            var alpha: u16 = 0;
            var rgb: [3]u8 = @splat(0);
            for (0..scale) |dy| for (0..scale) |dx| {
                const sample = samples[(y * scale + dy) * width + x * scale + dx];
                alpha += sample[3];
                if (!template and sample[3] != 0) rgb = sample[0..3].*;
            };
            pixel.* = rgb ++ [1]u8{@intCast((alpha + scale * scale / 2) / (scale * scale))};
        }
        try zlib.writer.writeByte(0); // No PNG row filter.
        try zlib.writer.writeAll(std.mem.sliceAsBytes(row[0..size]));
    }
    try zlib.finish();

    var png: std.Io.Writer.Allocating = .init(a);
    const out = &png.writer;
    try out.writeAll("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 6, 0, 0, 0 };
    std.mem.writeInt(u32, header[0..4], size, .big);
    std.mem.writeInt(u32, header[4..8], size, .big);
    try pngChunk(out, "IHDR", &header);
    try pngChunk(out, "IDAT", compressed.written());
    try pngChunk(out, "IEND", "");
    return png.written();
}

fn pngChunk(out: *std.Io.Writer, kind: *const [4]u8, bytes: []const u8) !void {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(bytes);
    try out.writeInt(u32, @intCast(bytes.len), .big);
    try out.writeAll(kind);
    try out.writeAll(bytes);
    try out.writeInt(u32, crc.final(), .big);
}

fn ico(a: std.mem.Allocator, sizes: []const u32, pngs: []const []const u8) ![]const u8 {
    var ico_file: std.Io.Writer.Allocating = .init(a);
    const out = &ico_file.writer;
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, 1, .little);
    try out.writeInt(u16, @intCast(pngs.len), .little);
    var offset: u32 = @intCast(6 + 16 * pngs.len);
    for (sizes, pngs) |size, png| {
        const dimension: u8 = @truncate(size); // 256 is encoded as zero.
        try out.writeAll(&.{ dimension, dimension, 0, 0 });
        try out.writeInt(u16, 1, .little);
        try out.writeInt(u16, 32, .little);
        try out.writeInt(u32, @intCast(png.len), .little);
        try out.writeInt(u32, offset, .little);
        offset += @intCast(png.len);
    }
    for (pngs) |png| try out.writeAll(png);
    return ico_file.written();
}

fn icns(a: std.mem.Allocator, types: []const *const [4]u8, pngs: []const []const u8) ![]const u8 {
    var icns_file: std.Io.Writer.Allocating = .init(a);
    const out = &icns_file.writer;
    var size: usize = 8;
    for (pngs) |png| size += 8 + png.len;
    try out.writeAll("icns");
    try out.writeInt(u32, @intCast(size), .big);
    for (types, pngs) |kind, png| {
        try out.writeAll(kind);
        try out.writeInt(u32, @intCast(8 + png.len), .big);
        try out.writeAll(png);
    }
    return icns_file.written();
}
