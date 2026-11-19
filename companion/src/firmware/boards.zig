//! The companion's view of the firmware board table (`keyboards/boards.zig`).
//!
//! The companion offers every board with a keymap file and builds it with that
//! default keymap or a supplied one. Boards that define their keymap in their
//! main file, such as `encoder_demo`, stay firmware examples. Paths are
//! relative to the firmware's `keyboards` directory; wiring stays in each
//! board's main file.
const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    root_source_file: []const u8,
    default_keymap: []const u8,
};

/// The inventory of a firmware board table: `table` is
/// `@import("zigmkay_firmware").keyboards.boards.boards` in build scripts and
/// a copy of `keyboards/boards.zig` inside the default keymap module.
pub fn Inventory(comptime table: anytype) type {
    return struct {
        pub const entries = blk: {
            var result: []const Entry = &.{};
            for (table) |board| if (board.keymap) |keymap| {
                result = result ++ [_]Entry{.{ .name = board.name, .root_source_file = board.root_source_file, .default_keymap = keymap }};
            };
            break :blk result[0..result.len].*;
        };

        /// Firmware boards the companion does not offer.
        pub const unselected_examples = blk: {
            var result: []const []const u8 = &.{};
            for (table) |board| if (board.keymap == null) {
                result = result ++ [_][]const u8{board.root_source_file};
            };
            break :blk result[0..result.len].*;
        };

        pub fn find(name: []const u8) ?Entry {
            for (entries) |entry| if (std.mem.eql(u8, name, entry.name)) return entry;
            return null;
        }
    };
}

/// Files that default keymaps import by relative path. They are copied with the
/// default keymaps into the portable inventory module.
pub const default_keymap_support = [_][]const u8{"my_keyboards/janbeelte/keymap_shared.zig"};

test "the inventory offers boards with a keymap file" {
    const table = [_]struct { name: []const u8, root_source_file: []const u8, keymap: ?[]const u8 = null }{
        .{ .name = "lk7", .root_source_file = "lk7.zig", .keymap = "shared.zig" },
        .{ .name = "encoder_demo", .root_source_file = "encoder_demo.zig" },
        .{ .name = "lk8", .root_source_file = "lk8.zig", .keymap = "shared.zig" },
    };
    const inventory = Inventory(table);
    try std.testing.expectEqual(@as(usize, 2), inventory.entries.len);
    try std.testing.expectEqualStrings("shared.zig", inventory.find("lk8").?.default_keymap);
    try std.testing.expect(inventory.find("encoder_demo") == null);
    try std.testing.expectEqualStrings("encoder_demo.zig", inventory.unselected_examples[0]);
}
