//! Offline personal-profile candidate. Host symbols target EurKEY Next's 16c map.
const p = @import("root.zig");
const model = @import("layout-model");

fn key(usage: u8, modifiers: model.Modifiers) p.Action {
    return .{ .tap_only = .{ .key_press = .{ .tap_keycode = usage, .tap_modifiers = modifiers } } };
}

fn dual(usage: u8, hold: p.Hold) p.Action {
    return .{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = usage } },
        .hold = hold,
        .tapping_term = .{ .ms = 180 },
    } };
}

pub const letters = [_]u8{ 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 29, 27, 6, 25, 5, 17, 16, 54, 55, 56 };

pub fn populate(layers: []p.Layer) void {
    for (layers) |layer| @memset(@constCast(layer.actions), null);
    const base = @constCast(layers[0].actions);
    for (letters, 0..) |usage, index| base[index] = key(usage, .{});
    // Mirrored home-row modifiers permit either hand to type modified characters.
    const positions = [_]usize{ 10, 11, 12, 13, 16, 17, 18, 19 };
    const modifiers = [_]model.Modifiers{
        .{ .left_gui = true },    .{ .left_alt = true },   .{ .left_ctrl = true }, .{ .left_shift = true },
        .{ .right_shift = true }, .{ .right_ctrl = true }, .{ .right_alt = true }, .{ .right_gui = true },
    };
    for (positions, modifiers) |index, mods| base[index] = dual(letters[index], .{ .hold_modifiers = mods });
    base[30] = dual(44, .{ .layer_id = 2 }); // Space / Navigation
    base[31] = dual(43, .{ .layer_id = 4 }); // Tab / Symbols
    base[32] = dual(40, .{ .layer_id = 3 }); // Enter / Numbers
    base[33] = dual(42, .{ .hold_modifiers = .{ .right_shift = true } });

    const nav = @constCast(layers[1].actions);
    const shortcuts = [_]u8{ 4, 29, 27, 6, 25 }; // Command A/Z/X/C/V
    for (shortcuts, 0..) |usage, index| nav[index] = key(usage, .{ .left_gui = true });
    nav[5] = key(29, .{ .left_gui = true, .left_shift = true });
    nav[6] = key(43, .{ .left_gui = true });
    nav[7] = key(82, .{});
    nav[8] = key(75, .{});
    nav[9] = key(41, .{});
    nav[15] = key(80, .{ .left_gui = true });
    nav[16] = key(80, .{});
    nav[17] = key(81, .{});
    nav[18] = key(79, .{});
    nav[19] = key(79, .{ .left_gui = true });
    nav[25] = key(42, .{});
    nav[26] = key(76, .{});
    nav[27] = key(78, .{});

    const numbers = @constCast(layers[2].actions);
    for (0..10) |index| numbers[index] = key(@intCast(58 + index), .{}); // F1–F10
    numbers[10] = key(68, .{});
    numbers[11] = key(69, .{});
    numbers[12] = key(64, .{}); // F7–F9 remain available beside F11/F12.
    numbers[13] = key(65, .{});
    numbers[14] = key(66, .{});
    const digit_positions = [_]usize{ 26, 27, 28, 16, 17, 18, 6, 7, 8, 25 };
    for (digit_positions, 0..) |index, digit| numbers[index] = key(
        if (digit == 9) 39 else @intCast(30 + digit),
        .{},
    );
    numbers[19] = key(46, .{ .left_shift = true });
    numbers[29] = key(45, .{});
    numbers[24] = key(55, .{});

    const symbols = @constCast(layers[3].actions);
    const usages = [_]u8{ 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 47, 48, 47, 48, 49, 45, 46, 51, 52, 53, 54, 55, 56, 45, 46, 49, 56, 51, 52, 53 };
    for (usages, 0..) |usage, index| symbols[index] = key(
        usage,
        if (index < 12 or (index >= 15 and index < 22) or index == 25 or index == 26) .{ .left_shift = true } else .{},
    );
    // Keep all layer keys and modifier holds usable through transparent fallthrough.
    for (layers[1..]) |layer| {
        const actions = @constCast(layer.actions);
        for (positions, modifiers) |index, mods| {
            if (actions[index]) |action| {
                const tap = action.tap_only;
                actions[index] = .{ .tap_hold = .{
                    .tap = tap,
                    .hold = .{ .hold_modifiers = mods },
                    .tapping_term = .{ .ms = 180 },
                } };
            }
        }
    }
}

test "Mac candidate reaches every layer and preserves modifier and recovery access" {
    const std = @import("std");
    var loaded = try p.profiles.create(std.testing.allocator, .eurmac);
    defer loaded.deinit();
    const doc = loaded.snapshot.document;
    const assessment = try p.assessment.assess(doc);
    for (assessment.reachable[0..4]) |reachable| try std.testing.expect(reachable);
    try std.testing.expect(assessment.recovery_found);
    try std.testing.expectEqual(@as(usize, 0), doc.callbacks.len);
    for (doc.layers[1..]) |layer| for (30..34) |index| try std.testing.expect(layer.actions[index] == null);
    try std.testing.expect(doc.layers[0].actions[11].?.tap_hold.hold.hold_modifiers.left_alt);
    try std.testing.expect(doc.layers[0].actions[18].?.tap_hold.hold.hold_modifiers.right_alt);
    for (letters, 0..) |usage, index| {
        const action = try p.lowerAction(doc, doc.layers[0].actions[index].?);
        const tap = switch (action) {
            .tap_only => |value| value,
            .tap_hold => |value| value.tap,
            else => unreachable,
        };
        try std.testing.expectEqual(usage, tap.key_press.?.tap_keycode);
    }
    for (doc.layers[1].actions[0..5]) |action| try std.testing.expect(
        action.?.tap_only.key_press.?.tap_modifiers.left_gui,
    );
    // No function key is lost when the number-pad positions override the top row.
    for (58..70) |usage| {
        var found = false;
        for (doc.layers[2].actions) |maybe_action| if (maybe_action) |action| {
            const tap = switch (action) {
                .tap_only => |value| value,
                .tap_hold => |value| value.tap,
                else => continue,
            };
            if (tap.key_press) |press| {
                if (press.tap_keycode == usage) {
                    found = true;
                }
            }
        };
        try std.testing.expect(found);
    }
    var reference = try p.profiles.create(std.testing.allocator, .danish);
    defer reference.deinit();
    const identity = try p.snapshot.identity(std.testing.allocator, loaded.snapshot, p.profiles.board);
    const original_identity = try p.snapshot.identity(
        std.testing.allocator,
        reference.snapshot,
        p.profiles.board,
    );
    try std.testing.expect(!std.mem.eql(u8, &identity.digest, &original_identity.digest));
}
