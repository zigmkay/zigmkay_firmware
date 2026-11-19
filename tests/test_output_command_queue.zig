const std = @import("std");
const core = @import("zigmkay").core;
const helpers = @import("test_processing_helpers.zig");
test "press key" {
    var q = core.OutputCommandQueue.Create();
    try q.press_key(.{ .tap_keycode = 0x04 });

    try std.testing.expectEqual(1, q.Count());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 0x04 }, q.dequeue());
    try std.testing.expectEqual(0, q.Count());
}

test "press key with modifier" {
    var q = core.OutputCommandQueue.Create();
    try q.press_key(.{ .tap_keycode = 0x04, .tap_modifiers = .{ .left_shift = true } });

    try std.testing.expectEqual(4, q.Count());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 0x04 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 0x04 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, q.dequeue());
    try std.testing.expectEqual(0, q.Count());
}

test "press/release key - simple sequence" {
    var q = core.OutputCommandQueue.Create();

    try q.press_key(.{ .tap_keycode = 0x04 });
    try q.release_key(.{ .tap_keycode = 0x04 });

    try q.press_key(.{ .tap_keycode = 0x05 });
    try q.release_key(.{ .tap_keycode = 0x05 });

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 0x04 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 0x04 }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 0x05 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 0x05 }, q.dequeue());

    try std.testing.expectEqual(0, q.Count());
}

test "rolling" {
    var q = core.OutputCommandQueue.Create();
    try q.press_key(core.KeyCodeFire{ .tap_keycode = 4 });

    try q.press_key(core.KeyCodeFire{ .tap_keycode = 5 });
    try q.release_key(core.KeyCodeFire{ .tap_keycode = 4 });

    try q.press_key(core.KeyCodeFire{ .tap_keycode = 6 });
    try q.release_key(core.KeyCodeFire{ .tap_keycode = 5 });

    try q.release_key(core.KeyCodeFire{ .tap_keycode = 6 });

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 4 }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 5 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 4 }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 6 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 5 }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 6 }, q.dequeue());

    try std.testing.expectEqual(0, q.Count());
}

test "rolling with modifiers" {
    var q = core.OutputCommandQueue.Create();
    try q.press_key(core.KeyCodeFire{ .tap_keycode = 4 });

    try q.press_key(core.KeyCodeFire{ .tap_keycode = 5, .tap_modifiers = .{ .left_shift = true } });
    try q.release_key(core.KeyCodeFire{ .tap_keycode = 4 });

    try q.press_key(core.KeyCodeFire{ .tap_keycode = 6 });
    try q.release_key(core.KeyCodeFire{ .tap_keycode = 5, .tap_modifiers = .{ .left_shift = true } });

    try q.release_key(core.KeyCodeFire{ .tap_keycode = 6 });

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 4 }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 5 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 5 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 4 }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 6 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 6 }, q.dequeue());

    try std.testing.expectEqual(0, q.Count());
}

test "rolling same key code" {
    var q = core.OutputCommandQueue.Create();
    try q.press_key(core.KeyCodeFire{ .tap_keycode = 4 });
    try q.press_key(core.KeyCodeFire{ .tap_keycode = 4 });

    try q.release_key(core.KeyCodeFire{ .tap_keycode = 4 });
    try q.release_key(core.KeyCodeFire{ .tap_keycode = 4 });

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 4 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 4 }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 4 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 4 }, q.dequeue());
    try std.testing.expectEqual(0, q.Count());
}

test "rolling same key code - with modifiers in the mix" {
    var q = core.OutputCommandQueue.Create();
    try q.press_key(core.KeyCodeFire{ .tap_keycode = 4, .tap_modifiers = .{ .left_shift = true } });
    try q.press_key(core.KeyCodeFire{ .tap_keycode = 4 });

    try q.release_key(core.KeyCodeFire{ .tap_keycode = 4, .tap_modifiers = .{ .left_shift = true } });
    try q.release_key(core.KeyCodeFire{ .tap_keycode = 4 });

    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 4 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 4 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, q.dequeue());

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 4 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 4 }, q.dequeue());
    try std.testing.expectEqual(0, q.Count());
}
test "release key" {
    var q = core.OutputCommandQueue.Create();
    try q.press_key(core.KeyCodeFire{ .tap_keycode = 0x04 });
    try q.release_key(core.KeyCodeFire{ .tap_keycode = 0x04 });

    try std.testing.expectEqual(2, q.Count());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = 0x04 }, q.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = 0x04 }, q.dequeue());
    try std.testing.expectEqual(0, q.Count());
}
