//! The companion's view of the firmware board table (`keyboards/boards.zig`).
//!
//! The companion offers every board with a keymap file and a processing
//! binding below, and builds it with that default keymap or a supplied one.
//! Boards that define their keymap in their main file, such as `encoder_demo`,
//! stay firmware examples; boards without a binding, such as one fresh from
//! `board:new`, build as firmware but are not offered until their main file is
//! reviewed and listed here. Paths are relative to the firmware's `keyboards`
//! directory; wiring stays in each board's main file.
const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    root_source_file: []const u8,
    default_keymap: []const u8,
};

/// Where an entrypoint takes the sides it passes to the processor.
pub const SideSource = enum {
    /// `.side_definition = &<keymap>.sides`.
    keymap,
    /// No `side_definition`; the processor default is all `.X`.
    unassigned,
};

/// What each entrypoint owns beyond its keymap; `processing_descriptors.zig`
/// turns it into the processing contract. Listing a board here is the review
/// of its main file: the sides it passes and its encoder action slots.
pub const Binding = struct { root: []const u8, sides: SideSource = .keymap, encoder_actions: usize = 0 };

pub const bindings = [_]Binding{
    .{ .root = "my_keyboards/rollercole/clacky_chan.zig" },
    .{ .root = "my_keyboards/janbeelte/clackychan_main.zig" },
    .{ .root = "my_keyboards/janbeelte/keycaprio_main_0_4.zig" },
    .{ .root = "my_keyboards/janbeelte/keycaprio_main_0_6.zig" },
    .{ .root = "my_keyboards/janbeelte/keycaprio_main_0_7.zig" },
    .{ .root = "my_keyboards/rollercole/leonardo_keycaprio_0_1.zig" },
    .{ .root = "my_keyboards/rollercole/leonardo_keycaprio_0_2.zig" },
    .{ .root = "my_keyboards/rollercole/leonardo_keycaprio_0_6.zig" },
    .{ .root = "my_keyboards/rollercole/leonardo_keycaprio_0_7.zig" },
    .{ .root = "my_keyboards/rollercole/leonardo_keycaprio_0_8.zig" },
    .{ .root = "examples/dasbob/main.zig", .sides = .unassigned },
    // Uses keymap.encoder_actions when exported, else the entrypoint's 4 defaults.
    .{ .root = "my_keyboards/rollercole/tuckytwotimes.zig", .encoder_actions = 4 },
    // Encoder actions come from the keymap; CW and CCW of one encoder.
    .{ .root = "my_keyboards/molekula/main.zig", .encoder_actions = 2 },
};

/// The binding of the entrypoint `root`, if it has one.
pub fn binding(comptime root: []const u8) ?Binding {
    var selected: ?Binding = null;
    for (bindings) |candidate| if (std.mem.eql(u8, root, candidate.root)) {
        if (selected != null) @compileError("Duplicate processing descriptor root binding");
        selected = candidate;
    };
    return selected;
}

/// The inventory of a firmware board table: `table` is
/// `@import("zigmkay_firmware").keyboards.boards.boards` in build scripts and
/// a copy of `keyboards/boards.zig` inside the default keymap module.
pub fn Inventory(comptime table: anytype) type {
    return struct {
        pub const entries = blk: {
            @setEvalBranchQuota(100_000);
            var result: []const Entry = &.{};
            for (table) |board| if (board.keymap) |keymap| if (binding(board.root_source_file) != null) {
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

        /// Boards with a keymap that the companion does not offer because their
        /// main file has no binding yet.
        pub const without_binding = blk: {
            @setEvalBranchQuota(100_000);
            var result: []const []const u8 = &.{};
            for (table) |board| if (board.keymap != null and binding(board.root_source_file) == null) {
                result = result ++ [_][]const u8{board.name};
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

test "the inventory offers boards with a keymap file and a binding" {
    const table = [_]struct { name: []const u8, root_source_file: []const u8, keymap: ?[]const u8 = null }{
        .{ .name = "lk7", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_7.zig", .keymap = "shared.zig" },
        .{ .name = "encoder_demo", .root_source_file = "encoder_demo.zig" },
        .{ .name = "lk8", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_8.zig", .keymap = "shared.zig" },
        .{ .name = "fresh", .root_source_file = "my_keyboards/fresh/main.zig", .keymap = "my_keyboards/fresh/keymap.zig" },
    };
    const inventory = Inventory(table);
    try std.testing.expectEqual(@as(usize, 2), inventory.entries.len);
    try std.testing.expectEqualStrings("shared.zig", inventory.find("lk8").?.default_keymap);
    try std.testing.expect(inventory.find("encoder_demo") == null);
    try std.testing.expectEqualStrings("encoder_demo.zig", inventory.unselected_examples[0]);
    try std.testing.expect(inventory.find("fresh") == null);
    try std.testing.expectEqual(@as(usize, 1), inventory.without_binding.len);
    try std.testing.expectEqualStrings("fresh", inventory.without_binding[0]);
}
