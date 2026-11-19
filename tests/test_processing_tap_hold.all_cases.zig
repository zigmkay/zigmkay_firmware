const std = @import("std");
const zigmkay = @import("zigmkay");

const core = zigmkay.core;

const helpers = @import("test_processing_helpers.zig");
const init_with_config = helpers.init_with_config;

const TestObjects = struct {
    matrix_change_queue: core.MatrixStateChangeQueue,
    actions_queue: core.OutputCommandQueue,
    processor: zigmkay.processing.Processor,
};

test "[A down, not yet timed out] => ?" {
    try run(&[_]TestEvent{}, TestExpectation.undecided);
}

test "[A down, timeout] => hold" {
    var events = [_]TestEvent{ .{ .down = A }, TestEvent.timed_out };
    try run(&events, TestExpectation.hold);
}

test "[A down, timeout, ...] => hold" {
    var e = [_]TestEvent{ .{ .down = A }, TestEvent.timed_out, .{ .down = B } };
    try run(&e, TestExpectation.hold);
}

test "[A down, A up, ...] => tap" {
    var e = [_]TestEvent{ .{ .down = A }, .{ .up = A } };
    try run(&e, TestExpectation.tap);
}

test "[A down, B down, A up, ...] => tap" {
    var e = [_]TestEvent{ .{ .down = A }, .{ .down = B }, .{ .up = A } };
    try run(&e, TestExpectation.tap);
}

test "[A down, B up, timeout] => hold" {
    var e = [_]TestEvent{ .{ .down = A }, .{ .up = B }, TestEvent.timed_out };
    try run(&e, TestExpectation.hold);
}

test "[A down, B up, timeout, ...] => hold" {
    var e = [_]TestEvent{ .{ .down = A }, .{ .up = B }, TestEvent.timed_out, .{ .down = B } };
    try run(&e, TestExpectation.hold);
}

test "[A down, B up, B down, ...] => ?" {
    {
        var e = [_]TestEvent{ .{ .down = A }, .{ .up = B }, .{ .down = B } };
        try run(&e, TestExpectation.undecided);
    }
    {
        var e = [_]TestEvent{ .{ .down = A }, .{ .up = B }, .{ .down = B }, .{ .up = B } };
        try run(&e, TestExpectation.hold);
    }
}

test "[A down, B down, B up, ...] => hold" {
    {
        var e = [_]TestEvent{ .{ .down = A }, .{ .down = B }, .{ .up = B } };
        try run(&e, TestExpectation.hold);
    }
}
test "[A down, B down] => ?" {
    var e = [_]TestEvent{ .{ .down = A }, .{ .down = B } };
    try run(&e, TestExpectation.undecided);
}
const TestEvent = union(enum) {
    timed_out,
    down: core.KeyIndex,
    up: core.KeyIndex,
};
const TestExpectation = union(enum) {
    tap,
    hold,
    undecided,
};

const A = 0;
const B = 1;

fn run(events: []TestEvent, expect: TestExpectation) !void {
    var current_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(100);
    const tapping_term: core.TimeSpan = .{ .ms = 250 };

    const KC_A = 0x04;
    const KC_B = 0x05;

    const a_with_tap_hold = core.KeyDef{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = KC_A } },
        .hold = .{ .hold_modifiers = .{ .left_shift = true } },
        .tapping_term = tapping_term,
    } };
    const b_tap = core.KeyDef{ .tap_only = .{ .key_press = .{ .tap_keycode = KC_B } } };

    const base_layer = comptime [_]?core.KeyDef{ a_with_tap_hold, b_tap };
    const keymap = comptime [_][base_layer.len]?core.KeyDef{base_layer};

    var o = init_with_config(.{ .key_count = base_layer.len, .layer_count = keymap.len }, .{ .keymap = &keymap }){};

    for (events) |e| {
        switch (e) {
            .timed_out => {
                current_time = current_time.add_ms(500);
            },
            .up => |key| {
                try o.release_key(key, current_time);
            },
            .down => |key| {
                try o.press_key(key, current_time);
            },
        }
    }
    try o.process(current_time);
    switch (expect) {
        .undecided => {
            try std.testing.expectEqual(0, o.actions_queue.Count());
        },
        .tap => {
            try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = KC_A }, o.actions_queue.dequeue());
        },
        .hold => {
            try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
        },
    }
}

