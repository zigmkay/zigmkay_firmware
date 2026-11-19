const std = @import("std");
const p = @import("keymap-project");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const registered = args.len == 3 and std.mem.eql(u8, args[2], "danish");
    var fixture = try p.profiles.create(gpa, if (registered) .danish else .eurkey);
    defer fixture.deinit();
    var board = p.profiles.board;
    if (args.len == 3 and !registered) {
        const actions = @constCast(fixture.snapshot.document.layers[0].actions);
        actions[11] = .{ .hold_only = .{ .hold_modifiers = .{ .left_shift = true } } };
        actions[12] = .{ .tap_hold = .{
            .tap = .{ .key_press = .{ .tap_keycode = 6 } },
            .hold = .{ .hold_modifiers = .{ .left_ctrl = true } },
            .tapping_term = .{ .ms = 180 },
            .retro_tapping = true,
        } };
        actions[13] = .{ .tap_with_autofire = .{
            .tap = .{ .key_press = .{ .tap_keycode = 7 } },
            .initial_delay = .{ .ms = 100 },
            .repeat_interval = .{ .ms = 50 },
        } };
        actions[14] = .none;
        actions[15] = null;
        actions[16] = .{ .tap_only = .{ .one_shot = .{ .hold_modifiers = .{ .left_shift = true } } } };
        actions[17] = .{ .tap_only = .{ .media_key = .VolumeUp } };
        actions[18] = .{ .tap_only = .{ .mouse_action = .WheelDown } };
        actions[19] = .{ .tap_only = .{ .custom = 1 } };
        actions[20] = .{ .tap_only = .{ .key_press = .{
            .tap_keycode = 8,
            .tap_modifiers = .{ .left_gui = true },
            .dead = true,
        } } };
        actions[21] = .{ .hold_only = .{ .layer_id = 2 } };
        actions[22] = .{ .tap_only = .{ .one_shot = .{ .layer_id = 2 } } };
        actions[23] = .{ .tap_only = .{ .custom = 253 } };
        actions[24] = .{ .tap_only = .{ .key_press = .{ .tap_keycode = 252 } } };
        actions[25] = .{ .hold_only = .{ .custom = 2 } };
        const bytes = @embedFile("callback_fixture.zig");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        // The fixture's previous empty callback arrays are parser-owned zero-length allocations.
        const metadata = try gpa.alloc(p.Source, 1);
        metadata[0] = .{ .path = try gpa.dupe(u8, "callback_fixture.zig"), .digest = digest };
        const bindings = try gpa.alloc(p.Callback, 1);
        bindings[0] = .{
            .kind = .attached,
            .binding = try gpa.dupe(u8, "callback_fixture.zig"),
            .ids = try gpa.dupe(u8, &.{ 1, 2 }),
            .sources = metadata,
        };
        fixture.snapshot.document.callbacks = bindings;
        const sources = try gpa.alloc(p.snapshot.SourceBytes, 1);
        sources[0] = .{ .callback_index = 0, .path = metadata[0].path, .bytes = try gpa.dupe(u8, bytes) };
        fixture.snapshot.sources = sources;
        board.encoder_actions = 1;
        const encoders = try gpa.alloc(p.Tap, 1);
        encoders[0] = .{ .key_press = .{ .tap_keycode = 9 } };
        fixture.snapshot.document.encoders = encoders;
    }
    const source = try p.exporter.generate(gpa, fixture.snapshot, board);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = source });
}
