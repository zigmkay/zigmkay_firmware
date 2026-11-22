const std = @import("std");
const p = @import("keymap-project");

pub const board = p.Board{
    .id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 },
    .physical_layout = "export-fixture",
    .key_ids = &.{ "left_0", "right_0" },
    .sides = &.{ .L, .R },
};

pub const document = p.Document{
    .schema_version = 1,
    .board_id = board.id,
    .profile_id = .{ 't', 'e', 's', 't', 0, 0, 0, 0 },
    .physical_layout = board.physical_layout,
    .key_ids = board.key_ids,
    .name = "Export compile fixture",
    .layers = &.{
        .{ .id = 10, .name = "Base", .actions = &.{
            .{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } },
            .{ .hold_only = .{ .layer_id = 20 } },
        } },
        .{
            .id = 20,
            .name = "Navigation",
            .actions = &.{ .{ .tap_only = .{ .key_press = .{ .tap_keycode = 80 } } }, null },
        },
    },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) return error.Usage;
    const bytes = try p.exporter.generate(gpa, .{ .document = document, .sources = &.{} }, board);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = bytes });
}
