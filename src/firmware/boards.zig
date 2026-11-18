//! Companion-owned board inventory for mainline zigmkay_firmware.
//!
//! Mainline keeps its board table private to `keyboards/build.zig`
//! (`keyboard_samples`). This table repeats its selectors and entrypoints and
//! adds the default keymap of each board, so the companion can build any board
//! with either its default or a supplied keymap. Paths are relative to the
//! firmware's `keyboards` directory. Wiring stays in each unmodified entrypoint.
const std = @import("std");

/// A board entrypoint that imports its keymap by relative path instead of
/// `@import("keymap")`. The adapter compiles a copy of the entrypoint next to a
/// generated file with this name, which forwards the listed declarations from
/// `@import("keymap")`.
pub const Shim = struct {
    /// Base name of the keymap file the entrypoint imports by relative path.
    file_name: []const u8,
    /// Declarations the entrypoint reads from that file, plus `custom_functions`,
    /// which carries the companion keymap identity (`companion_keymap_id`).
    declarations: []const []const u8,
};

pub const Entry = struct {
    name: []const u8,
    root_source_file: []const u8,
    default_keymap: []const u8,
    /// Null when the entrypoint already imports `@import("keymap")`.
    shim: ?Shim = null,
};

// Declarations read by the Rollercole unibody and Clacky Chan entrypoints, and
// by Molekula.
const full_declarations = [_][]const u8{
    "key_count",
    "dimensions",
    "keymap",
    "combos",
    "sides",
    "custom_functions",
};

// Tucky Two Times builds its own dimensions from `key_count` and `keymap`.
const tucky_declarations = [_][]const u8{ "key_count", "keymap", "combos", "sides", "custom_functions" };
// Dasbob reads only `key_count` and `keymap`; it passes no combos, callbacks or
// sides. Its entrypoint therefore ignores the forwarded `custom_functions`, and
// the firmware reports the unknown (all-zero) keymap id, which the live session
// refuses as `unknown_keymap`.
const dasbob_declarations = [_][]const u8{ "key_count", "keymap", "custom_functions" };

const rollercole_28: Shim = .{ .file_name = "shared_keymap_28_1.zig", .declarations = &full_declarations };
const rollercole_34: Shim = .{ .file_name = "shared_keymap_3x5_2.zig", .declarations = &full_declarations };

/// Selector order follows mainline `keyboard_samples`.
pub const entries = [_]Entry{
    .{
        .name = "clacky_chan",
        .root_source_file = "my_keyboards/rollercole/clacky_chan.zig",
        .default_keymap = "my_keyboards/rollercole/shared_keymap_28_1.zig",
        .shim = rollercole_28,
    },
    .{
        .name = "clackychan_colemak",
        .root_source_file = "my_keyboards/janbeelte/clackychan_main.zig",
        .default_keymap = "my_keyboards/janbeelte/clackychan_colemak_keymap.zig",
    },
    .{
        .name = "keycaprio_colemak_0_4",
        .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_4.zig",
        .default_keymap = "my_keyboards/janbeelte/clackychan_colemak_keymap.zig",
    },
    .{
        .name = "keycaprio_colemak_0_6",
        .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_6.zig",
        .default_keymap = "my_keyboards/janbeelte/keycaprio_colemak_keymap.zig",
    },
    .{
        .name = "keycaprio_colemak_0_7",
        .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_7.zig",
        .default_keymap = "my_keyboards/janbeelte/keycaprio_colemak_keymap.zig",
    },
    .{
        .name = "keycaprio_us_intl_0_7",
        .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_7.zig",
        .default_keymap = "my_keyboards/janbeelte/keycaprio_us_intl_keymap.zig",
    },
    .{
        .name = "lk1",
        .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_1.zig",
        .default_keymap = "my_keyboards/rollercole/shared_keymap_28_1.zig",
        .shim = rollercole_28,
    },
    .{
        .name = "lk2",
        .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_2.zig",
        .default_keymap = "my_keyboards/rollercole/shared_keymap_28_1.zig",
        .shim = rollercole_28,
    },
    .{
        .name = "lk6",
        .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_6.zig",
        .default_keymap = "my_keyboards/rollercole/shared_keymap_3x5_2.zig",
        .shim = rollercole_34,
    },
    .{
        .name = "lk7",
        .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_7.zig",
        .default_keymap = "my_keyboards/rollercole/shared_keymap_3x5_2.zig",
        .shim = rollercole_34,
    },
    // LK8 rewires LK7's GPIOs and imports the same keymap file.
    .{
        .name = "lk8",
        .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_8.zig",
        .default_keymap = "my_keyboards/rollercole/shared_keymap_3x5_2.zig",
        .shim = rollercole_34,
    },
    .{
        .name = "dasbob",
        .root_source_file = "examples/dasbob/main.zig",
        .default_keymap = "examples/dasbob/keymap.zig",
        .shim = .{ .file_name = "keymap.zig", .declarations = &dasbob_declarations },
    },
    .{
        .name = "tuckytwotimes",
        .root_source_file = "my_keyboards/rollercole/tuckytwotimes.zig",
        .default_keymap = "my_keyboards/rollercole/shared_keymap_28_1.zig",
        .shim = .{ .file_name = "shared_keymap_28_1.zig", .declarations = &tucky_declarations },
    },
    .{
        .name = "molekula",
        .root_source_file = "my_keyboards/molekula/main.zig",
        .default_keymap = "my_keyboards/molekula/keymap.zig",
        .shim = .{ .file_name = "keymap.zig", .declarations = &full_declarations },
    },
};

/// Files that default keymaps import by relative path. They are copied with the
/// default keymaps into the portable inventory module.
pub const default_keymap_support = [_][]const u8{"my_keyboards/janbeelte/keymap_shared.zig"};

/// Mainline sources that are not selectors. Yak is an unbuilt example.
/// `encoder_demo` defines its keymap inline in the entrypoint, so it cannot take
/// a supplied keymap.
pub const unselected_examples = [_][]const u8{
    "examples/yak/main.zig",
    "my_keyboards/rollercole/encoder_demo.zig",
};

pub fn find(name: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, name, entry.name)) return entry;
    return null;
}

test "board selectors are unique and shims never replace their entrypoint" {
    try std.testing.expectEqual(@as(usize, 14), entries.len);
    for (entries, 0..) |entry, index| {
        try std.testing.expectEqualStrings(entry.name, find(entry.name).?.name);
        for (entries[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, entry.name, other.name));
        if (entry.shim) |shim| {
            try std.testing.expect(
                !std.mem.eql(u8, shim.file_name, std.fs.path.basenamePosix(entry.root_source_file)),
            );
            try std.testing.expectEqualStrings(
                shim.file_name,
                std.fs.path.basenamePosix(entry.default_keymap),
            );
            var has_callbacks = false;
            for (shim.declarations) |name| has_callbacks = has_callbacks or std.mem.eql(u8, name, "custom_functions");
            try std.testing.expect(has_callbacks);
        }
    }
    try std.testing.expectEqualStrings(find("lk7").?.default_keymap, find("lk8").?.default_keymap);
    try std.testing.expect(find("encoder_demo") == null);
    try std.testing.expect(find("yak") == null);
    try std.testing.expect(find("unknown") == null);
}
