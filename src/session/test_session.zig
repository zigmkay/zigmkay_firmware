// SPDX-License-Identifier: GPL-2.0
//! Session reducer regressions for the companion Raw HID session, protocol
//! version 1. The byte literals are copied from the firmware's own tests
//! (zigmkay_firmware PR #60, zigmkay/tests/test_companion.zig), so they define
//! the wire independently of the companion codec.
const std = @import("std");
const protocol = @import("device-protocol");
const model = @import("layout-model");
const companion = @import("companion-model");

fn literal(prefix: []const u8) protocol.Report {
    var report: protocol.Report = @splat(0);
    @memcpy(report[0..prefix.len], prefix);
    return report;
}

// Firmware fixture: 36 keys, 4 layers, keymap id 0xAB repeated.
const dimensions = model.KeymapDimensions{ .key_count = 36, .layer_count = 4 };
const keymap_id: [16]u8 = @splat(0xAB);
const left_shift: u8 = 0x02;
/// Hello answering connect.
const hello = literal(&(.{ 0x20, 1, 36, 4 } ++ keymap_id));

/// State after connect with key 9 held, layers 1 and 2 active and left shift.
const first_state = blk: {
    var report = literal(&.{ 0x21, 0, 2, left_shift, 0b0111, 0 });
    report[6 + 1] = 0b10;
    break :blk report;
};

/// Key 5 pressed then released on layer 1.
const press = literal(&.{ 0x22, 1, 1, 5, 1, 0 });
const release = literal(&.{ 0x22, 2, 0, 5, 1, 0 });
/// Resynchronising state after 33 dropped events; key 7 is still held.
const dropped_state = literal(&.{ 0x21, 33, 0, 0, 1, 0, 0b1000_0000 });
/// Overlay key held then released (firmware fixture: CUSTOM_ID_COMPANION_TOGGLE hold).
const overlay_hold = literal(&.{ 0x23, 1, 2, 1 });
const overlay_release = literal(&.{ 0x23, 2, 2, 0 });
/// Layer change to layer 3.
const layer_state = literal(&.{ 0x21, 3, 3, 0, 0b1001, 0 });

const expected = protocol.Identity{
    .board_id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 },
    .profile_id = .{ 'd', 'a', 'n', 'i', 's', 'h', 0, 0 },
    .digest = keymap_id,
    .dimensions = dimensions,
};

test "firmware byte layouts decode and reencode exactly" {
    const t = std.testing;
    try t.expectEqualDeep(
        protocol.Message{ .hello = .{ .dimensions = dimensions, .keymap_id = keymap_id } },
        (try protocol.decode(&hello, dimensions)).?,
    );
    const state = (try protocol.decode(&first_state, dimensions)).?.state;
    try t.expectEqual(@as(u8, 0), state.sequence);
    try t.expectEqual(@as(model.LayerIndex, 2), state.highest_layer);
    try t.expectEqual(@as(u16, 0b0111), state.active_layers);
    try t.expectEqual(model.Modifiers{ .left_shift = true }, state.modifiers);
    try t.expect(state.isPressed(9));
    try t.expectEqualDeep(protocol.Message{ .key = .{ .sequence = 1, .event = .{
        .pressed = true,
        .key_index = 5,
        .layer = 1,
        .modifiers = .{},
    } } }, (try protocol.decode(&press, dimensions)).?);
    try t.expectEqualDeep(protocol.Message{ .key = .{ .sequence = 2, .event = .{
        .pressed = false,
        .key_index = 5,
        .layer = 1,
        .modifiers = .{},
    } } }, (try protocol.decode(&release, dimensions)).?);
    try t.expect((try protocol.decode(&dropped_state, dimensions)).?.state.isPressed(7));
    try t.expectEqual(
        @as(model.LayerIndex, 3),
        (try protocol.decode(&layer_state, dimensions)).?.state.highest_layer,
    );
    for ([_]protocol.Report{ hello, first_state, press, release, dropped_state, layer_state }) |report| {
        try t.expectEqual(
            report,
            try protocol.encode((try protocol.decode(&report, dimensions)).?, dimensions),
        );
    }
    // Host commands as the firmware tests build them.
    try t.expectEqual(literal(&.{0x10}), protocol.encodeCommand(.connect));
    try t.expectEqual(literal(&.{0x11}), protocol.encodeCommand(.disconnect));
    try t.expectEqual(literal(&.{0x12}), protocol.encodeCommand(.enter_bootloader));
    try t.expectEqual(@as(?protocol.Command, null), try protocol.decodeCommand(&literal(&.{0x7F})));
}

fn feed(session: *companion.Session, report: protocol.Report, now: u64) companion.Outcome {
    return session.receive(&report, now);
}

fn connected() !companion.Session {
    var session = try companion.Session.init(expected);
    try std.testing.expectEqual(protocol.Command.connect, try session.connect(0, 9));
    return session;
}

test "connect, hello and state build the live state; keys update it" {
    const t = std.testing;
    var session = try connected();
    try t.expectEqual(companion.Phase.negotiating, session.phase);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, hello, 1));
    try t.expectEqual(companion.Phase.synchronizing, session.phase);
    try t.expect(!session.hasCoherentState());
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, first_state, 2));
    try t.expect(session.hasCoherentState());
    try t.expect(session.state.pressed[9] and !session.state.pressed[5]);
    try t.expectEqual(@as(u16, 0b0111), session.state.active_layers);
    try t.expectEqual(@as(model.LayerIndex, 2), session.state.highest_layer);
    try t.expect(session.state.modifiers.left_shift);
    const pressed = feed(&session, press, 3);
    try t.expectEqual(@as(?protocol.Command, null), pressed.send);
    try t.expectEqual(@as(model.KeyIndex, 5), pressed.key.?.key_index);
    try t.expect(session.state.pressed[5]);
    // Key reports never override the processed layer or modifiers.
    try t.expect(session.state.modifiers.left_shift);
    _ = feed(&session, release, 4);
    try t.expect(!session.state.pressed[5]);
    _ = feed(&session, layer_state, 5);
    try t.expectEqual(@as(model.LayerIndex, 3), session.state.highest_layer);
    try t.expectEqual(@as(u16, 0b1001), session.state.active_layers);
    try t.expect(!session.state.pressed[9]);
    try t.expectEqual(@as(?u8, 3), session.state.last_sequence);
}

test "companion key signals pass through in sequence with keys" {
    const t = std.testing;
    var session = try connected();
    _ = feed(&session, hello, 1);
    _ = feed(&session, first_state, 2);
    const held = feed(&session, overlay_hold, 3);
    try t.expectEqualDeep(protocol.SignalEvent{ .kind = .overlay_toggle, .pressed = true }, held.signal.?);
    try t.expectEqualDeep(
        protocol.SignalEvent{ .kind = .overlay_toggle, .pressed = false },
        feed(&session, overlay_release, 4).signal.?,
    );
    // A signal out of sequence resynchronises like a key.
    try t.expectEqual(@as(?protocol.Command, .connect), feed(&session, overlay_hold, 5).send);
}

test "hello is matched against the open project and all-zero ids are unknown" {
    const t = std.testing;
    const Case = struct { report: protocol.Report, mismatch: companion.Mismatch };
    var unknown = hello;
    @memset(unknown[4..20], 0);
    var other = hello;
    other[19] ^= 1;
    for ([_]Case{
        .{ .report = literal(&(.{ 0x20, 1, 34, 4 } ++ keymap_id)), .mismatch = .dimensions },
        .{ .report = literal(&(.{ 0x20, 1, 36, 3 } ++ keymap_id)), .mismatch = .dimensions },
        .{ .report = unknown, .mismatch = .unknown_keymap },
        .{ .report = other, .mismatch = .keymap_id },
        .{ .report = literal(&(.{ 0x20, 2, 36, 4 } ++ keymap_id)), .mismatch = .unsupported_version },
    }) |case| {
        var session = try connected();
        try t.expectEqual(@as(?protocol.Command, .disconnect), feed(&session, case.report, 1).send);
        try t.expectEqual(companion.Phase.incompatible, session.phase);
        try t.expectEqual(case.mismatch, session.mismatch.?);
        // Nothing after a refusal is applied or retried.
        try t.expectEqualDeep(companion.Outcome{}, feed(&session, first_state, 2));
        try t.expect(!session.hasCoherentState());
        try t.expectEqual(@as(?protocol.Command, null), session.tick(10_000));
        try t.expect(!session.bootloaderAvailable());
    }
}

test "sequence gaps resynchronise with connect and sequences wrap" {
    const t = std.testing;
    var session = try connected();
    _ = feed(&session, hello, 1);
    _ = feed(&session, literal(&.{ 0x21, 254, 0, 0, 1, 0 }), 2);
    _ = feed(&session, literal(&.{ 0x22, 255, 1, 4, 0, 0 }), 3);
    const wrapped = feed(&session, literal(&.{ 0x22, 0, 0, 4, 0, 0 }), 4);
    try t.expect(wrapped.key != null and wrapped.send == null);
    try t.expect(session.hasCoherentState() and !session.state.pressed[4]);
    _ = feed(&session, literal(&.{ 0x22, 1, 1, 6, 0, 0 }), 5);
    // Sequence 3 follows 1: report 2 was lost.
    const gap = feed(&session, literal(&.{ 0x22, 3, 0, 6, 0, 0 }), 6);
    try t.expectEqual(@as(?protocol.Command, .connect), gap.send);
    try t.expectEqual(@as(?protocol.KeyEvent, null), gap.key);
    try t.expectEqual(companion.Phase.negotiating, session.phase);
    try t.expect(!session.hasCoherentState() and !session.state.pressed[6]);
    // Reports already in flight are ignored until hello and state arrive.
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, literal(&.{ 0x22, 4, 1, 7, 0, 0 }), 7));
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, literal(&.{ 0x21, 5, 0, 0, 1, 0 }), 7));
    _ = feed(&session, hello, 8);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, literal(&.{ 0x22, 6, 1, 8, 0, 0 }), 8));
    _ = feed(&session, literal(&.{ 0x21, 7, 0, 0, 1, 0, 0b1000_0000 }), 9);
    try t.expect(session.hasCoherentState() and session.state.pressed[7] and !session.state.pressed[8]);
}

test "a state after dropped events resynchronises without another connect" {
    const t = std.testing;
    var session = try connected();
    _ = feed(&session, hello, 1);
    _ = feed(&session, first_state, 2);
    _ = feed(&session, press, 3);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, dropped_state, 4));
    try t.expect(session.hasCoherentState());
    try t.expect(session.state.pressed[7] and !session.state.pressed[5] and !session.state.pressed[9]);
    // The sequence continues from the state report.
    const next = feed(&session, literal(&.{ 0x22, 34, 0, 7, 0, 0 }), 5);
    try t.expect(next.send == null and next.key != null and !session.state.pressed[7]);
}

test "unknown report ids are ignored in every phase" {
    const t = std.testing;
    const trace = literal(&.{ 0x03, 1, 2, 3, 4 });
    var session = try companion.Session.init(expected);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, trace, 0));
    _ = try session.connect(0, 9);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, trace, 1));
    _ = feed(&session, hello, 1);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, trace, 2));
    _ = feed(&session, first_state, 2);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, trace, 3));
    try t.expect(session.hasCoherentState());
    try t.expectEqual(@as(?u8, 0), session.state.last_sequence);
}

test "malformed reports resynchronise a coherent session only" {
    const t = std.testing;
    var session = try connected();
    // While negotiating a malformed report is recorded and the retry timer stays.
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, literal(&.{ 0x22, 1, 2, 5, 1, 0 }), 1));
    try t.expectEqual(@as(?protocol.ProtocolError, error.InvalidBoolean), session.last_error);
    try t.expectEqual(companion.Phase.negotiating, session.phase);
    _ = feed(&session, hello, 2);
    _ = feed(&session, first_state, 3);
    try t.expectEqual(
        @as(?protocol.Command, .connect),
        feed(&session, literal(&.{ 0x22, 1, 1, 36, 0, 0 }), 4).send,
    );
    try t.expectEqual(@as(?protocol.ProtocolError, error.InvalidKeyIndex), session.last_error);
    try t.expectEqual(companion.Phase.negotiating, session.phase);
    try t.expectEqual(@as(?protocol.Command, null), session.receive(press[0..31], 5).send);
    try t.expectEqual(@as(?protocol.ProtocolError, error.InvalidLength), session.last_error);
}

test "state before hello and keys before the first state are not applied" {
    const t = std.testing;
    var session = try connected();
    _ = feed(&session, first_state, 1);
    try t.expectEqual(companion.Phase.negotiating, session.phase);
    _ = feed(&session, hello, 2);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, press, 3));
    try t.expect(!session.state.pressed[5]);
    _ = feed(&session, literal(&.{ 0x21, 2, 0, 0, 1, 0, 0b10_0000 }), 4);
    try t.expect(session.state.pressed[5]);
    _ = feed(&session, literal(&.{ 0x22, 3, 0, 5, 0, 0 }), 5);
    try t.expect(!session.state.pressed[5]);
}

test "close sends disconnect only for an open connection and clears state" {
    const t = std.testing;
    var session = try companion.Session.init(expected);
    try t.expectEqual(@as(?protocol.Command, null), session.close());
    _ = try session.connect(0, 9);
    _ = feed(&session, hello, 1);
    _ = feed(&session, first_state, 2);
    try t.expectEqual(@as(?protocol.Command, .disconnect), session.close());
    try t.expectEqual(companion.Phase.disconnected, session.phase);
    try t.expectEqual(@as(u32, 0), session.token);
    try t.expect(!session.state.pressed[9] and session.state.active_layers == 1);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, press, 3));
    try t.expectError(error.InvalidToken, session.connect(4, 0));
    _ = try session.connect(4, 10);
    try t.expectError(error.InvalidToken, session.connect(5, 10));
}

test "unanswered connects are retried, quickly at first" {
    const t = std.testing;
    var session = try connected();
    try t.expectEqual(@as(?protocol.Command, null), session.tick(499));
    try t.expectEqual(@as(?protocol.Command, .connect), session.tick(500));
    try t.expectEqual(@as(?protocol.Command, .connect), session.tick(1000));
    try t.expectEqual(@as(?protocol.Command, null), session.tick(1999));
    try t.expectEqual(@as(?protocol.Command, .connect), session.tick(2000));
    _ = feed(&session, hello, 2001);
    // A missing state after hello is retried too.
    try t.expectEqual(@as(?protocol.Command, .connect), session.tick(2501));
    _ = feed(&session, hello, 2502);
    _ = feed(&session, first_state, 2503);
    try t.expectEqual(@as(?protocol.Command, null), session.tick(100_000));
    // Recovering from a later gap starts with the quick retry again.
    _ = feed(&session, release, 100_001);
    try t.expectEqual(@as(?protocol.Command, null), session.tick(100_500));
    try t.expectEqual(@as(?protocol.Command, .connect), session.tick(100_501));
}

test "session static memory budget" {
    try std.testing.expect(@sizeOf(companion.Session) <= 512);
}
