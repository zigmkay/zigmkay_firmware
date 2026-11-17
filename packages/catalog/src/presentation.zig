//! Host presentation only. Display hands never supply processor sides.
const std = @import("std");
const model = @import("layout-model");
pub const Metadata = struct { name: []const u8, revision: []const u8, template: []const u8, host_layout: []const u8, encoders: usize = 0 };
pub fn metadata(comptime selector: []const u8) Metadata {
    if (std.mem.eql(u8, selector, "molekula")) return .{ .name = "Molekula", .revision = "38-key", .template = "QWERTY", .host_layout = "US International" };
    if (std.mem.eql(u8, selector, "dasbob")) return .{ .name = "Dasbob", .revision = "36-key", .template = "Danish", .host_layout = "Danish" };
    if (std.mem.eql(u8, selector, "encoder_demo")) return .{ .name = "Encoder demo", .revision = "1-key", .template = "Firmware default", .host_layout = "US", .encoders = 1 };
    if (std.mem.eql(u8, selector, "tuckytwotimes")) return .{ .name = "Tucky Two Times", .revision = "30-key", .template = "Rollercole", .host_layout = "Danish", .encoders = 2 };
    if (std.mem.startsWith(u8, selector, "clacky")) return .{ .name = "Clacky Chan", .revision = "30-key", .template = if (std.mem.eql(u8, selector, "clacky_chan")) "Rollercole" else "Colemak", .host_layout = if (std.mem.eql(u8, selector, "clacky_chan")) "Danish" else "US International" };
    if (std.mem.startsWith(u8, selector, "keycaprio")) return .{ .name = "Keycaprio", .revision = if (std.mem.endsWith(u8, selector, "0_4")) "0.4" else if (std.mem.endsWith(u8, selector, "0_6")) "0.6" else "0.7", .template = if (std.mem.indexOf(u8, selector, "us_intl") != null) "US International" else "Colemak", .host_layout = "US International" };
    if (std.mem.eql(u8, selector, "lk1")) return .{ .name = "Leonardo Keycaprio", .revision = "0.1 (LK1)", .template = "Rollercole", .host_layout = "Danish" };
    if (std.mem.eql(u8, selector, "lk2")) return .{ .name = "Leonardo Keycaprio", .revision = "0.2 (LK2)", .template = "Rollercole", .host_layout = "Danish" };
    if (std.mem.eql(u8, selector, "lk6")) return .{ .name = "Leonardo Keycaprio", .revision = "0.6 (LK6)", .template = "Rollercole", .host_layout = "Danish" };
    if (std.mem.eql(u8, selector, "lk7")) return .{ .name = "Leonardo Keycaprio", .revision = "0.7 (LK7)", .template = "Rollercole", .host_layout = "Danish" };
    @compileError("Missing catalog presentation");
}
/// Schematic rows follow the selected firmware's array order, including omitted
/// bottom pinkies on 30-key layouts and Molekula's six-column middle row.
pub fn geometry(comptime count: usize) [count]model.physical_layout.Key {
    const widths = switch (count) {
        1 => [_]usize{ 1, 0, 0, 0 },
        30 => .{ 10, 10, 8, 2 },
        34 => .{ 10, 10, 10, 4 },
        36 => .{ 10, 10, 10, 6 },
        38 => .{ 10, 12, 10, 6 },
        else => @compileError("Missing schematic family"),
    };
    var keys: [count]model.physical_layout.Key = undefined;
    var index: usize = 0;
    for (widths, 0..) |width, row| {
        for (0..width) |column| {
            const left = column < (width + 1) / 2;
            const local = if (left) column else column - width / 2;
            const half = width / 2;
            const start: f32 = if (!left) 0 else if (row == 3) 5 - @as(f32, @floatFromInt(half)) else if (width == 8) 1 else if (width == 12) -1 else 0;
            const stagger = if (row == 3) @as(f32, 0) else ([_]f32{ 0.3, 0.1, 0, 0.1, 0.3, 0.4 })[@min(local, 5)];
            keys[index] = .{ .id = @intCast(index), .key_index = @intCast(index), .x = start + @as(f32, @floatFromInt(local)) + (if (left) @as(f32, 0) else 7), .y = @as(f32, @floatFromInt(row)) + stagger + (if (row == 3) @as(f32, 0.25) else 0), .hand = if (count == 1) .neutral else if (left) .left else .right, .group = if (row == 3) .thumb else .finger, .home_row = row == 1 };
            index += 1;
        }
    }
    return keys;
}
