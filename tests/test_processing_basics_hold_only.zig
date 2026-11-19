const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");
const init_with_config = helpers.init_with_config;

const a = 0x04;
const b = 0x05;
const c = 0x06;
const d = 0x07;
const e = 0x08;
const f = 0x09;
const g = 0x10;

const A = helpers.TAP(a);
const B = helpers.TAP(b);
const C = helpers.TAP(c);
const D = helpers.TAP(d);
const E = helpers.TAP(e);
const F = helpers.TAP(f);
const G = helpers.TAP(g);
const TestObjects = struct {
    matrix_change_queue: core.MatrixStateChangeQueue,
    actions_queue: core.OutputCommandQueue,
    processor: zigmkay.processing.Processor,
};

test "HOLD_MOD - single hold" {
    const current_time: core.TimeSinceBoot = .from_absolute_us(100);
    const hold_left_shift = comptime helpers.HOLD_MOD(core.Modifiers{ .left_shift = true });
    const base_layer = comptime [_]?core.KeyDef{ hold_left_shift, B, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 }); // Press left shift
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 }); // Press B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 }); // Release B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 }); // Release left shift

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "HOLD_MOD - multiple holds" {
    // multiple mod hold presses at the same time

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const hold_left_shift = comptime helpers.HOLD_MOD(core.Modifiers{ .left_shift = true });
    const hold_left_alt = comptime helpers.HOLD_MOD(core.Modifiers{ .left_alt = true });
    const base_layer = comptime [_]?core.KeyDef{ hold_left_shift, hold_left_alt, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 }); // Press left shift
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 }); // Press left alt
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 }); // Press C
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 2 }); // Release C
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 }); // Release left shift first (to mix things up)
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 }); // Release left alt

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "HOLD_MOD combined with TAP_WITH_MOD" {
    // ensure mods applied but not cancelled if already held
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);

    const c_with_left_gui_and_shift = comptime helpers.TAP_WITH_MOD(0x06, .{ .left_gui = true, .left_shift = true });
    const hold_left_shift = comptime helpers.HOLD_MOD(core.Modifiers{ .left_shift = true, .left_alt = true });
    const base_layer = comptime [_]?core.KeyDef{ hold_left_shift, c_with_left_gui_and_shift, D, E };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    try o.press_key(0, current_time); // enable left shift and left alt
    try o.press_key(1, current_time);
    try o.release_key(1, current_time);

    try o.process(current_time);

    // expect B to be fired as press
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true, .left_gui = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = c }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true, .left_alt = true } }, o.actions_queue.dequeue());

    // expect event removed from input_events
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}
test "Layers - simple switch" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo_key = comptime helpers.MO(1);
    const base_layer = comptime [_]?core.KeyDef{ A, B, mo_key, D };
    const other_layer = comptime [_]?core.KeyDef{ E, F, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, other_layer };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // switch layer
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 }); //mo_key pressed
    // tap
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    try o.process(current_time);

    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = f }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = f }, o.actions_queue.dequeue());

    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}
test "Layers - complex switch" {
    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo_key = comptime helpers.MO(1);
    const base_layer = comptime [_]?core.KeyDef{ A, B, mo_key, D };
    const other_layer = comptime [_]?core.KeyDef{ E, F, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, other_layer };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Tap B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Tap A
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    // Hold for layer switch
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 }); //mo_key pressed

    // Tap F
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Tap E
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    // Release layer switch again
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 2 }); //mo_key released

    // Tap B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Tap A
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    try o.process(current_time);

    // Expect B tapped
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());

    // Expect A
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());

    // At this point, layer 1 is expected to be activated

    // Expect F
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = f }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = f }, o.actions_queue.dequeue());

    // Expect E
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = e }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = e }, o.actions_queue.dequeue());

    // At this point, layer 1 is expected to be deactivated again

    // Expect B tapped
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());

    // Expect A
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());

    // Expect no more actions
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}

test "Layers - ensure correct release key" {
    // Specifically test that a key pressed existing on layer A is also what is released even though the layer changed between press and release

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo_key = comptime helpers.MO(1);
    const base_layer = comptime [_]?core.KeyDef{ A, B, mo_key, D };
    const other_layer = comptime [_]?core.KeyDef{ E, F, C, D };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, other_layer };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Tap B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });

    // Hold for layer switch
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 }); //mo_key pressed

    // Tap E
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });

    // Release B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // release layer switch
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 2 }); //mo_key pressed

    // Release E
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    try o.process(current_time);

    // Press B expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    // Press E expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = e }, o.actions_queue.dequeue());
    // Release B expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    // Release E expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = e }, o.actions_queue.dequeue());

    // Expect no more actions
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}
test "Layers - multiple layers case 1" {
    // multiple layer switches, hold 1, hold 2, release 2, release 1

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo1_key = comptime helpers.MO(1);
    const mo2_key = comptime helpers.MO(2);
    const base_layer = comptime [_]?core.KeyDef{ A, B, mo1_key, D };
    const layer_1 = comptime [_]?core.KeyDef{ E, F, A, mo2_key };
    const layer_2 = comptime [_]?core.KeyDef{ C, G, C, C };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1, layer_2 };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Tap B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Hold for layer switch 1
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 }); //mo_key pressed

    // Tap F
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Hold for layer switch 2
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 3 }); //mo_key pressed

    // Tap G
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Release layer 2
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 3 }); //mo_key pressed

    // Tap F
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Release layer 1
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 2 }); //mo_key pressed

    // Tap B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    try o.process(current_time);

    // Press B expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    // Press F expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = f }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = f }, o.actions_queue.dequeue());
    // Press G expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = g }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = g }, o.actions_queue.dequeue());
    // Press F expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = f }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = f }, o.actions_queue.dequeue());
    // Press B expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    // Expect no more actions
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}
test "Layers - multiple layers case 2" {
    //Layers - multiple layer switches, hold 1, hold 2, release 1, release 2

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo1_key = comptime helpers.MO(1);
    const mo2_key = comptime helpers.MO(2);
    const base_layer = comptime [_]?core.KeyDef{ A, B, mo1_key, D };
    const layer_1 = comptime [_]?core.KeyDef{ E, F, A, mo2_key };
    const layer_2 = comptime [_]?core.KeyDef{ C, G, C, C };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1, layer_2 };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Tap B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Hold for layer switch 1
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 2 }); //mo_key pressed

    // Tap F
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Hold for layer switch 2
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 3 }); //mo_key pressed

    // Tap G
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Release layer 1
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 2 }); //mo_key pressed

    // Tap G
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    // Release layer 2
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 3 }); //mo_key pressed

    // Tap B
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 1 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 1 });

    try o.process(current_time);

    // Press B expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    // Press F expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = f }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = f }, o.actions_queue.dequeue());
    // Press G expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = g }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = g }, o.actions_queue.dequeue());
    // Press G expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = g }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = g }, o.actions_queue.dequeue());
    // Press B expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = b }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = b }, o.actions_queue.dequeue());
    // Expect no more actions
    try std.testing.expectEqual(0, o.actions_queue.Count());
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}
test "MO - invalid layer id" {
    // ensure nothing breaks if referencing too high layer index

    const current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const mo4_key = comptime helpers.MO(4);
    const base_layer = comptime [_]?core.KeyDef{ A, A, A, mo4_key };
    const layer_1 = comptime [_]?core.KeyDef{ B, B, B, B };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{ base_layer, layer_1 };
    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};
    // Hold for invalid layer switch
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 3 });

    // Tap a transparent key at position 0 which is transparent - expect layer 1's key do be pushed
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = true, .key_index = 0 });
    try o.matrix_change_queue.enqueue(.{ .time = current_time, .pressed = false, .key_index = 0 });

    try o.process(current_time);

    // expect A pressed as no layer switch is expected
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = a }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodeRelease = a }, o.actions_queue.dequeue());

    // Expect no more actions
    try std.testing.expectEqual(0, o.matrix_change_queue.Count());
}
