//! Converts screenshots of the Tutor gallery into the PNG files the
//! documentation shows. `zig build doc-screenshots -Ddesktop` renders the
//! gallery first, then runs this with:
//!
//!     <gallery dir> <bmp name>=<png path>...
//!
//! It reads uncompressed 24- or 32-bit BMP files, the format SDL saves.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3) {
        std.debug.print("usage: doc-screenshots <gallery dir> <bmp>=<png path>...\n", .{});
        return error.Usage;
    }
    const cwd: std.Io.Dir = .cwd();
    const gallery = try cwd.openDir(io, args[1], .{});
    defer gallery.close(io);
    for (args[2..]) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.Usage;
        const bmp = try gallery.readFileAlloc(io, pair[0..eq], a, .limited(64 << 20));
        const image = try decodeBmp(a, bmp);
        const png_path = pair[eq + 1 ..];
        if (std.fs.path.dirname(png_path)) |dir| try cwd.createDirPath(io, dir);
        try cwd.writeFile(io, .{ .sub_path = png_path, .data = try encodePng(init.gpa, a, image) });
        std.debug.print("{s} -> {s}\n", .{ pair[0..eq], png_path });
    }
}

/// Top-down rows of RGB pixels.
const Image = struct {
    width: u32,
    height: u32,
    rgb: []const u8,
};

fn decodeBmp(a: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < 54 or !std.mem.eql(u8, bytes[0..2], "BM")) return error.NotBmp;
    const offset = std.mem.readInt(u32, bytes[10..14], .little);
    const raw_width = std.mem.readInt(i32, bytes[18..22], .little);
    const raw_height = std.mem.readInt(i32, bytes[22..26], .little);
    const bpp = std.mem.readInt(u16, bytes[28..30], .little);
    const compression = std.mem.readInt(u32, bytes[30..34], .little);
    if (raw_width <= 0 or raw_height == 0) return error.BadBmpSize;
    if (bpp != 24 and bpp != 32) return error.UnsupportedBmpDepth;
    // 0 is plain BGR(X); 3 (bit fields) is what SDL writes for 32-bit BGRA.
    if (compression != 0 and compression != 3) return error.UnsupportedBmpCompression;
    const width: u32 = @intCast(raw_width);
    const height: u32 = @intCast(@abs(raw_height));
    const bottom_up = raw_height > 0;
    const step: usize = bpp / 8;
    const stride = (width * step + 3) & ~@as(usize, 3);
    if (offset + stride * height > bytes.len) return error.TruncatedBmp;

    const rgb = try a.alloc(u8, @as(usize, width) * height * 3);
    for (0..height) |y| {
        const src_y = if (bottom_up) height - 1 - y else y;
        const row = bytes[offset + src_y * stride ..][0 .. width * step];
        const out = rgb[y * width * 3 ..][0 .. width * 3];
        for (0..width) |x| {
            const px = row[x * step ..][0..3];
            out[x * 3 ..][0..3].* = .{ px[2], px[1], px[0] };
        }
    }
    return .{ .width = width, .height = height, .rgb = rgb };
}

/// An 8-bit RGB PNG; every row takes the filter with the smallest sum of
/// absolute values, the usual heuristic.
fn encodePng(gpa: std.mem.Allocator, a: std.mem.Allocator, image: Image) ![]const u8 {
    const row_len = @as(usize, image.width) * 3;
    var compressed = try std.Io.Writer.Allocating.initCapacity(gpa, 1 << 20);
    defer compressed.deinit();
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    var zlib = try std.compress.flate.Compress.init(&compressed.writer, &history, .zlib, .best);

    const zero = try a.alloc(u8, row_len);
    @memset(zero, 0);
    var candidates: [5][]u8 = undefined;
    for (&candidates) |*c| c.* = try a.alloc(u8, row_len);
    for (0..image.height) |y| {
        const cur = image.rgb[y * row_len ..][0..row_len];
        const prev = if (y == 0) zero else image.rgb[(y - 1) * row_len ..][0..row_len];
        var best: u8 = 0;
        var best_sum: u64 = std.math.maxInt(u64);
        for (&candidates, 0..) |out, f| {
            var sum: u64 = 0;
            for (0..row_len) |i| {
                const left: u8 = if (i >= 3) cur[i - 3] else 0;
                const up = prev[i];
                const up_left: u8 = if (i >= 3) prev[i - 3] else 0;
                const predicted: u8 = switch (f) {
                    0 => 0,
                    1 => left,
                    2 => up,
                    3 => @intCast((@as(u16, left) + up) / 2),
                    else => paeth(left, up, up_left),
                };
                const v = cur[i] -% predicted;
                out[i] = v;
                sum += @min(v, 256 - @as(u16, v));
            }
            if (sum < best_sum) {
                best_sum = sum;
                best = @intCast(f);
            }
        }
        try zlib.writer.writeByte(best);
        try zlib.writer.writeAll(candidates[best]);
    }
    try zlib.finish();

    var png: std.Io.Writer.Allocating = .init(a);
    const out = &png.writer;
    try out.writeAll("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 2, 0, 0, 0 };
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    try chunk(out, "IHDR", &header);
    try chunk(out, "IDAT", compressed.written());
    try chunk(out, "IEND", "");
    return png.written();
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn chunk(out: *std.Io.Writer, kind: *const [4]u8, bytes: []const u8) !void {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(bytes);
    try out.writeInt(u32, @intCast(bytes.len), .big);
    try out.writeAll(kind);
    try out.writeAll(bytes);
    try out.writeInt(u32, crc.final(), .big);
}
