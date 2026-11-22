//! Preserve independently allocated typed values across the arena-based ZON API.
const std = @import("std");

pub fn clone(gpa: std.mem.Allocator, value: anytype) !@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |info| {
            if (info.size != .slice or info.sentinel() != null) {
                @compileError(
                    "Unsupported owned ZON pointer",
                );
            }
            const out = try gpa.alloc(info.child, value.len);
            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |item| free(gpa, item);
                gpa.free(out);
            }
            for (value, out) |item, *destination| {
                destination.* = try clone(gpa, item);
                initialized += 1;
            }
            return out;
        },
        .optional => return if (value) |item| try clone(gpa, item) else null,
        .@"struct" => |info| {
            var out: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (info.field_names, 0..) |name, index| {
                if (index < initialized) free(gpa, @field(out, name));
            };
            inline for (info.field_names) |name| {
                @field(out, name) = try clone(gpa, @field(value, name));
                initialized += 1;
            }
            return out;
        },
        .@"union" => |info| {
            inline for (info.field_names) |name| {
                if (std.meta.activeTag(value) == @field(std.meta.Tag(T), name)) {
                    return @unionInit(
                        T,
                        name,
                        try clone(gpa, @field(value, name)),
                    );
                }
            }
            unreachable;
        },
        .array => {
            var out = value;
            var initialized: usize = 0;
            errdefer for (out[0..initialized]) |item| free(gpa, item);
            for (value, &out) |item, *destination| {
                destination.* = try clone(gpa, item);
                initialized += 1;
            }
            return out;
        },
        else => return value,
    }
}

pub fn free(gpa: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |info| {
            if (info.size != .slice) @compileError("Unsupported owned ZON pointer");
            for (value) |item| free(gpa, item);
            gpa.free(value);
        },
        .optional => if (value) |item| free(gpa, item),
        .@"struct" => |info| inline for (info.field_names) |name| free(gpa, @field(value, name)),
        .@"union" => |info| inline for (info.field_names) |name| {
            if (std.meta.activeTag(value) == @field(std.meta.Tag(T), name)) free(gpa, @field(value, name));
        },
        .array => for (value) |item| free(gpa, item),
        else => {},
    }
}

pub fn parse(comptime T: type, gpa: std.mem.Allocator, source: [:0]const u8) !T {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return clone(gpa, try std.zon.parse.fromSlice(T, .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
    }));
}

test "owned ZON clone releases partial nested allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const Fixture = struct {
        name: []const u8,
        entries: []const union(enum) { text: []const u8, names: ?[]const []const u8 },
    };
    const value = try parse(
        Fixture,
        gpa,
        ".{ .name = \"fixture\", .entries = .{ .{ .text = \"value\" }, .{ .names = .{ \"first\", \"second\" } } } }",
    );
    defer free(gpa, value);
    try std.testing.expectEqualStrings("second", value.entries[1].names.?[1]);
}
