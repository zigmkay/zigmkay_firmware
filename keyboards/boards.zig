//! The keyboards this package builds, selected with `-Dkeyboard=<name>`.
//! Plain data with no build dependencies, so other packages can import it too.
const std = @import("std");

pub const Board = struct {
    name: []const u8,
    /// The board's main file, relative to this directory.
    root_source_file: []const u8,
    /// Keymap source exposed to the board's main file as `@import("keymap")`,
    /// so one main file per board can be combined with different keymaps.
    keymap: ?[]const u8 = null,
};

pub const boards = [_]Board{
    .{ .name = "clacky_chan", .root_source_file = "my_keyboards/rollercole/clacky_chan.zig" },
    .{ .name = "clackychan_colemak", .root_source_file = "my_keyboards/janbeelte/clackychan_main.zig", .keymap = "my_keyboards/janbeelte/clackychan_colemak_keymap.zig" },
    .{ .name = "keycaprio_colemak_0_4", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_4.zig", .keymap = "my_keyboards/janbeelte/clackychan_colemak_keymap.zig" },
    .{ .name = "keycaprio_colemak_0_6", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_6.zig", .keymap = "my_keyboards/janbeelte/keycaprio_colemak_keymap.zig" },
    .{ .name = "keycaprio_colemak_0_7", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_7.zig", .keymap = "my_keyboards/janbeelte/keycaprio_colemak_keymap.zig" },
    .{ .name = "keycaprio_us_intl_0_7", .root_source_file = "my_keyboards/janbeelte/keycaprio_main_0_7.zig", .keymap = "my_keyboards/janbeelte/keycaprio_us_intl_keymap.zig" },
    .{ .name = "lk1", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_1.zig" },
    .{ .name = "lk2", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_2.zig" },
    .{ .name = "lk6", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_6.zig" },
    .{ .name = "lk7", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_7.zig" },
    .{ .name = "lk8", .root_source_file = "my_keyboards/rollercole/leonardo_keycaprio_0_8.zig" },
    .{ .name = "encoder_demo", .root_source_file = "my_keyboards/rollercole/encoder_demo.zig" },
    .{ .name = "dasbob", .root_source_file = "examples/dasbob/main.zig" },
    .{ .name = "tuckytwotimes", .root_source_file = "my_keyboards/rollercole/tuckytwotimes.zig" },
    .{ .name = "molekula", .root_source_file = "my_keyboards/molekula/main.zig" },
};

pub fn find(name: []const u8) ?Board {
    for (boards) |board| {
        if (std.mem.eql(u8, board.name, name)) return board;
    }
    return null;
}

test "board names are unique" {
    for (boards, 0..) |board, index| {
        for (boards[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, board.name, other.name));
    }
    try std.testing.expectEqualStrings("lk8", find("lk8").?.name);
    try std.testing.expect(find("unknown") == null);
}
