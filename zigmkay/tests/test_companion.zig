const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const companion = zigmkay.companion;

const info = companion.Info{ .key_count = 36, .layer_count = 4, .keymap_id = @splat(0xAB) };

fn command(id: companion.Command) companion.Report {
    var report: companion.Report = @splat(0);
    report[0] = @backingInt(id);
    return report;
}

fn layers_with(comptime active: []const core.LayerIndex) core.LayerActivations {
    var layers = core.LayerActivations{};
    for (active) |layer| layers.activate(layer);
    return layers;
}

fn take(session: *companion.Session) ?companion.Report {
    const report = session.next_report() orelse return null;
    session.sent();
    return report;
}

test "companion session stays silent until the host connects" {
    var session = companion.Session.init(info);
    session.key_event(true, 3, 0, .{});
    session.update_state(&layers_with(&.{1}), .{});
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session answers connect with hello and current state" {
    var session = companion.Session.init(info);
    session.key_event(true, 9, 0, .{});
    session.update_state(&layers_with(&.{ 1, 2 }), .{ .left_shift = true });

    try std.testing.expectEqual(.none, session.receive(&command(.connect)));

    const hello = take(&session).?;
    try std.testing.expectEqual(@backingInt(companion.MessageId.hello), hello[0]);
    try std.testing.expectEqual(companion.protocol_version, hello[1]);
    try std.testing.expectEqual(36, hello[2]);
    try std.testing.expectEqual(4, hello[3]);
    try std.testing.expectEqualSlices(u8, &info.keymap_id, hello[4..20]);

    const state = take(&session).?;
    try std.testing.expectEqual(@backingInt(companion.MessageId.state), state[0]);
    try std.testing.expectEqual(0, state[1]);
    try std.testing.expectEqual(2, state[2]);
    try std.testing.expectEqual((core.Modifiers{ .left_shift = true }).toByte(), state[3]);
    try std.testing.expectEqual(0b0111, std.mem.readInt(u16, state[4..6], .little)); // base, 1 and 2
    try std.testing.expectEqual(0b10, state[6 + 1]); // key 9 is bit 1 of byte 1

    try std.testing.expectEqual(null, session.next_report());
}

test "companion session streams key events with sequence numbers" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);

    session.key_event(true, 5, 1, .{});
    session.key_event(false, 5, 1, .{});

    const press = take(&session).?;
    try std.testing.expectEqualSlices(u8, &.{ @backingInt(companion.MessageId.key), 1, 1, 5, 1, 0 }, press[0..6]);
    const release = take(&session).?;
    try std.testing.expectEqualSlices(u8, &.{ @backingInt(companion.MessageId.key), 2, 0, 5, 1, 0 }, release[0..6]);
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session keeps a report until the endpoint accepts it" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    const first = session.next_report().?;
    try std.testing.expectEqual(first, session.next_report().?);
}

test "companion session resynchronises with a state report after dropping events" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);

    for (0..33) |i| session.key_event(i % 2 == 0, 7, 0, .{});

    const state = take(&session).?;
    try std.testing.expectEqual(@backingInt(companion.MessageId.state), state[0]);
    try std.testing.expectEqual(0b1000_0000, state[6]); // key 7 is still pressed
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session reports layer changes and stops on disconnect" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);

    session.update_state(&layers_with(&.{3}), .{});
    const state = take(&session).?;
    try std.testing.expectEqual(3, state[2]);
    try std.testing.expectEqual(0b1001, std.mem.readInt(u16, state[4..6], .little));

    _ = session.receive(&command(.disconnect));
    session.key_event(true, 1, 0, .{});
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session asks for the bootloader and ignores unknown commands" {
    var session = companion.Session.init(info);
    try std.testing.expectEqual(.enter_bootloader, session.receive(&command(.enter_bootloader)));
    var unknown: companion.Report = @splat(0);
    unknown[0] = 0x7F;
    try std.testing.expectEqual(.none, session.receive(&unknown));
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session reports companion signals from tap and hold decisions" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);

    const overlay_hold = core.HoldDef{ .custom = core.CUSTOM_ID_COMPANION_TOGGLE };
    session.processor_event(.{ .OnHoldEnterAfter = .{ .hold = overlay_hold } });
    session.processor_event(.{ .OnHoldExitBefore = .{ .hold = overlay_hold } });
    session.processor_event(.{ .OnTapEnterAfter = .{ .tap = .{ .custom = core.CUSTOM_ID_COMPANION_SHUTDOWN } } });
    session.processor_event(.{ .OnTapEnterAfter = .{ .tap = .{ .key_press = core.KC_COMPANION } } });

    const signal = @backingInt(companion.MessageId.signal);
    const overlay = @backingInt(companion.Signal.overlay_toggle);
    try std.testing.expectEqualSlices(u8, &.{ signal, 1, overlay, 1 }, take(&session).?[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ signal, 2, overlay, 0 }, take(&session).?[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ signal, 3, @backingInt(companion.Signal.shutdown), 1 }, take(&session).?[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ signal, 4, overlay, 1 }, take(&session).?[0..4]);
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session ignores ordinary keys and signals while disconnected" {
    var session = companion.Session.init(info);
    session.processor_event(.{ .OnTapEnterAfter = .{ .tap = .{ .custom = core.CUSTOM_ID_COMPANION_TOGGLE } } });
    try std.testing.expectEqual(null, session.next_report());

    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);
    session.processor_event(.{ .OnTapEnterAfter = .{ .tap = .{ .custom = 7 } } });
    session.processor_event(.{ .OnTapEnterAfter = .{ .tap = .{ .key_press = .{ .tap_keycode = 0x04 } } } });
    session.processor_event(.{ .OnHoldEnterAfter = .{ .hold = .{ .hold_layer = 1 } } });
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session encodes tap/hold decisions in sequence with keys" {
    var session = companion.Session.init(info);
    session.tap_hold_decision(.{ .key_index = 4, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 50, .tapping_term_ms = 200 });
    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);

    session.key_event(true, 12, 0, .{});
    session.tap_hold_decision(.{
        .key_index = 12,
        .outcome = .hold,
        .reason = .permissive_hold,
        .elapsed_ms = 0x0123,
        .other_key = 20,
        .tapping_term_ms = 0x0201,
        .layer = 3,
        .combo = true,
    });
    session.tap_hold_decision(.{ .key_index = 5, .outcome = .retro_tap, .reason = .released_after_term, .elapsed_ms = 0xFFFF, .tapping_term_ms = 250 });

    const decision = @backingInt(companion.MessageId.decision);
    try std.testing.expectEqual(@backingInt(companion.MessageId.key), take(&session).?[0]);
    try std.testing.expectEqualSlices(u8, &.{ decision, 2, 12, 2, 3, 0x23, 0x01, 20, 0x01, 0x02, 3, 1, 0 }, take(&session).?[0..13]);
    try std.testing.expectEqualSlices(u8, &.{ decision, 3, 5, 3, 5, 0xFF, 0xFF, companion.no_other_key, 250, 0, 0, 0 }, take(&session).?[0..12]);
    try std.testing.expectEqual(null, session.next_report());
    try std.testing.expectEqual(2, companion.protocol_version);
}
