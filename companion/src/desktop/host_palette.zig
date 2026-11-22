//! Explicit owned OS-label preview capture; rendering never queries an input source.
const std = @import("std");
const labels = @import("labels.zig");
const zkeymap = @import("zkeymap");

pub const Cache = struct {
    arena: std.heap.ArenaAllocator,
    captions: [4][256][]const u8,
    source_id: []const u8,
    revision: u64,
    host: labels.Host,

    pub fn init(
        gpa: std.mem.Allocator,
        host: labels.Host,
        source_id: []const u8,
        revision: u64,
        translator: anytype,
    ) !Cache {
        if (source_id.len > 4096 or !std.unicode.utf8ValidateSlice(source_id)) return error.InvalidInputSourceIdentity;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_id = try a.dupe(u8, source_id);
        var captions: [4][256][]const u8 = undefined;
        for (&captions, 0..) |*variant, mods| for (variant, 0..) |*entry, code| {
            var scratch: [256]u8 = undefined;
            var text = labels.keycapUsage(host, @intCast(code), &scratch);
            if (zkeymap.isLayoutDependent(@intCast(code)) and code != 44) {
                const result = translator.keyToText(.{
                    .tap_keycode = @intCast(code),
                    .tap_modifiers = .{ .left_shift = mods & 1 != 0, .left_alt = mods & 2 != 0 },
                });
                if (result.len > result.data.len) return error.InvalidPaletteTranslation;
                if (result.len != 0) {
                    text = result.data[0..result.len];
                    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidPaletteTranslation;
                    entry.* = try a.dupe(u8, text);
                    continue;
                }
            }
            entry.* = try a.dupe(u8, text);
        };
        return .{
            .arena = arena,
            .captions = captions,
            .source_id = owned_id,
            .revision = revision,
            .host = host,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn caption(self: *const Cache, code: u8, shift: bool, option: bool) []const u8 {
        return self.captions[@as(usize, @intFromBool(shift)) | (@as(usize, @intFromBool(option)) << 1)][code];
    }
};

pub const HostKey = struct { code: u8, name: []const u8 = "", units: f32 = 1 };

pub const rows = [_][]const HostKey{
    &.{
        .{ .code = 41 },
        .{ .code = 58 },
        .{ .code = 59 },
        .{ .code = 60 },
        .{ .code = 61 },
        .{ .code = 62 },
        .{ .code = 63 },
        .{ .code = 64 },
        .{ .code = 65 },
        .{ .code = 66 },
        .{ .code = 67 },
        .{ .code = 68 },
        .{ .code = 69 },
        .{ .code = 76, .name = "Del" },
    },
    &.{
        .{ .code = 53 },
        .{ .code = 30 },
        .{ .code = 31 },
        .{ .code = 32 },
        .{ .code = 33 },
        .{ .code = 34 },
        .{ .code = 35 },
        .{ .code = 36 },
        .{ .code = 37 },
        .{ .code = 38 },
        .{ .code = 39 },
        .{ .code = 45 },
        .{ .code = 46 },
        .{ .code = 42, .units = 2 },
    },
    &.{
        .{ .code = 43, .units = 1.5 },
        .{ .code = 20 },
        .{ .code = 26 },
        .{ .code = 8 },
        .{ .code = 21 },
        .{ .code = 23 },
        .{ .code = 28 },
        .{ .code = 24 },
        .{ .code = 12 },
        .{ .code = 18 },
        .{ .code = 19 },
        .{ .code = 47 },
        .{ .code = 48 },
        .{ .code = 49, .units = 1.5 },
    },
    &.{
        .{ .code = 57, .units = 1.75 },
        .{ .code = 4 },
        .{ .code = 22 },
        .{ .code = 7 },
        .{ .code = 9 },
        .{ .code = 10 },
        .{ .code = 11 },
        .{ .code = 13 },
        .{ .code = 14 },
        .{ .code = 15 },
        .{ .code = 51 },
        .{ .code = 52 },
        .{ .code = 40, .units = 2.25 },
    },
    &.{
        .{ .code = 225, .name = "Shift", .units = 2.25 },
        .{ .code = 29 },
        .{ .code = 27 },
        .{ .code = 6 },
        .{ .code = 25 },
        .{ .code = 5 },
        .{ .code = 17 },
        .{ .code = 16 },
        .{ .code = 54 },
        .{ .code = 55 },
        .{ .code = 56 },
        .{ .code = 229, .name = "Shift", .units = 1.75 },
        .{ .code = 82 },
    },
    &.{
        .{ .code = 224, .name = "Control", .units = 1.25 },
        .{ .code = 226, .name = "Option", .units = 1.25 },
        .{ .code = 227, .name = "Command", .units = 1.5 },
        .{ .code = 44, .units = 5.5 },
        .{ .code = 231, .name = "Command", .units = 1.5 },
        .{ .code = 230, .name = "Option" },
        .{ .code = 80 },
        .{ .code = 81 },
        .{ .code = 79 },
    },
};
