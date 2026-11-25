// SPDX-License-Identifier: GPL-2.0-or-later
//! Session reducer regressions for the companion Raw HID session, protocol
//! versions 1 and 2. Keyboard reports come from the firmware's own session
//! (`zigmkay/src/companion.zig`, reached as `protocol.firmware`), driven the way
//! the firmware main loop drives it, so they define the wire independently of
//! the companion codec. Byte literals remain only for reports a correct
//! keyboard never sends (other versions, malformed fields, the legacy trace)
//! and for the golden bytes pinned in the first test.
const std = @import("std");
const protocol = @import("device-protocol");
const model = @import("layout-model");
const companion = @import("companion-model");
const firmware = protocol.firmware;
const core = protocol.core;

fn literal(prefix: []const u8) protocol.Report {
    var report: protocol.Report = @splat(0);
    @memcpy(report[0..prefix.len], prefix);
    return report;
}

// Firmware fixture: 36 keys, 4 layers, keymap id 0xAB repeated.
const dimensions = model.KeymapDimensions{ .key_count = 36, .layer_count = 4 };
const keymap_id: [16]u8 = @splat(0xAB);
const info = firmware.Info{ .key_count = 36, .layer_count = 4, .keymap_id = keymap_id };

/// A firmware session plus the helpers its main loop would use.
const Keyboard = struct {
    session: firmware.Session,

    fn init(keyboard_info: firmware.Info) Keyboard {
        return .{ .session = .init(keyboard_info) };
    }

    fn command(self: *Keyboard, id: protocol.Command) void {
        _ = self.session.receive(&protocol.encodeCommand(id));
    }

    fn key(self: *Keyboard, pressed: bool, key_index: core.KeyIndex, layer: core.LayerIndex) void {
        self.session.key_event(pressed, key_index, layer, .{});
    }

    fn layers(self: *Keyboard, active: []const core.LayerIndex, modifiers: core.Modifiers) void {
        var activations = core.LayerActivations{};
        for (active) |layer| activations.activate(layer);
        self.session.update_state(&activations, modifiers);
    }

    fn hold(self: *Keyboard, custom: u8, pressed: bool) void {
        const def = core.HoldDef{ .custom = custom };
        self.session.processor_event(if (pressed) .{ .OnHoldEnterAfter = .{ .hold = def } } else .{ .OnHoldExitBefore = .{ .hold = def } });
    }

    /// The next report, accepted by the endpoint. Fixtures always expect one.
    fn take(self: *Keyboard) protocol.Report {
        const report = self.session.next_report().?;
        self.session.sent();
        return report;
    }

    fn idle(self: *const Keyboard) bool {
        return self.session.next_report() == null;
    }
};

/// The hello a keyboard built with `keyboard_info` answers connect with.
fn firmwareHello(keyboard_info: firmware.Info) protocol.Report {
    var keyboard = Keyboard.init(keyboard_info);
    keyboard.command(.connect);
    return keyboard.take();
}

/// Key 9 held on layers 1 and 2 with left shift, then connected.
fn connectedKeyboard() Keyboard {
    var keyboard = Keyboard.init(info);
    keyboard.key(true, 9, 0);
    keyboard.layers(&.{ 1, 2 }, .{ .left_shift = true });
    keyboard.command(.connect);
    return keyboard;
}

const Fixture = struct {
    /// Hello answering connect.
    hello: protocol.Report,
    /// State after connect with key 9 held, layers 1 and 2 active and left shift.
    first_state: protocol.Report,
    /// Key 5 pressed then released on layer 1, then key 9 released.
    press: protocol.Report,
    release: protocol.Report,
    release_9: protocol.Report,
    /// Layer change to layer 3 without modifiers.
    layer_state: protocol.Report,
    /// After `press`: the host stopped reading, the firmware dropped its
    /// backlog and resynchronises with a state; key 7 is still held.
    dropped_state: protocol.Report,
    /// The event following `dropped_state`: key 7 released.
    after_dropped: protocol.Report,
    /// After `first_state`: the overlay key (CUSTOM_ID_COMPANION_TOGGLE hold)
    /// held then released.
    overlay_hold: protocol.Report,
    overlay_release: protocol.Report,
    /// After `overlay_release`: key 3 held past its tapping term.
    decision: protocol.Report,
};

const term_hold = protocol.TapHoldDecision{
    .key_index = 3,
    .outcome = .hold,
    .reason = .term_elapsed,
    .elapsed_ms = 210,
    .tapping_term_ms = 200,
};

const fixture: Fixture = blk: {
    @setEvalBranchQuota(100_000);
    var result: Fixture = undefined;
    var keyboard = connectedKeyboard();
    result.hello = keyboard.take();
    result.first_state = keyboard.take();
    keyboard.key(true, 5, 1);
    result.press = keyboard.take();
    var dropping = keyboard;
    keyboard.key(false, 5, 1);
    result.release = keyboard.take();
    keyboard.key(false, 9, 0);
    result.release_9 = keyboard.take();
    keyboard.layers(&.{3}, .{});
    result.layer_state = keyboard.take();
    if (!keyboard.idle()) unreachable;

    // 33 events overflow the 32-event backlog; the last one is dropped too.
    dropping.key(false, 5, 1);
    dropping.key(false, 9, 0);
    for (0..31) |i| dropping.key(i % 2 == 0, 7, 0);
    result.dropped_state = dropping.take();
    if (!dropping.idle()) unreachable;
    dropping.key(false, 7, 0);
    result.after_dropped = dropping.take();

    var signalling = connectedKeyboard();
    _ = signalling.take();
    _ = signalling.take();
    signalling.hold(core.CUSTOM_ID_COMPANION_TOGGLE, true);
    signalling.hold(core.CUSTOM_ID_COMPANION_TOGGLE, false);
    result.overlay_hold = signalling.take();
    result.overlay_release = signalling.take();
    signalling.session.tap_hold_decision(term_hold);
    result.decision = signalling.take();
    break :blk result;
};

const hello = fixture.hello;
const first_state = fixture.first_state;
const press = fixture.press;
const release = fixture.release;
const dropped_state = fixture.dropped_state;
const overlay_hold = fixture.overlay_hold;
const overlay_release = fixture.overlay_release;
const layer_state = fixture.layer_state;

const expected = protocol.Identity{
    .board_id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 },
    .profile_id = .{ 'd', 'a', 'n', 'i', 's', 'h', 0, 0 },
    .digest = keymap_id,
    .dimensions = dimensions,
};

test "firmware reports pin golden bytes, decode and reencode exactly" {
    const t = std.testing;
    // Golden bytes: the wire layout itself, so a change on both sides at once
    // still fails here.
    try t.expectEqual(literal(&(.{ 0x20, 2, 36, 4 } ++ keymap_id)), hello);
    try t.expectEqual(blk: {
        var report = literal(&.{ 0x21, 0, 2, 0x02, 0b0111, 0 });
        report[6 + 1] = 0b10;
        break :blk report;
    }, first_state);
    try t.expectEqual(literal(&.{ 0x22, 1, 1, 5, 1, 0 }), press);
    try t.expectEqual(literal(&.{ 0x23, 1, 2, 1, 2 }), overlay_hold);
    try t.expectEqual(literal(&.{ 0x24, 3, 3, 2, 2, 210, 0, 0xFF, 200, 0, 0, 0 }), fixture.decision);
    try t.expectEqual(literal(&.{0x10}), protocol.encodeCommand(.connect));
    try t.expectEqual(literal(&.{0x11}), protocol.encodeCommand(.disconnect));
    try t.expectEqual(literal(&.{0x12}), protocol.encodeCommand(.enter_bootloader));

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
    const dropped = (try protocol.decode(&dropped_state, dimensions)).?.state;
    try t.expect(dropped.isPressed(7) and !dropped.isPressed(5) and !dropped.isPressed(9));
    try t.expectEqual(
        @as(model.LayerIndex, 3),
        (try protocol.decode(&layer_state, dimensions)).?.state.highest_layer,
    );
    for ([_]protocol.Report{
        hello,         first_state,           press,        release,         fixture.release_9, layer_state,
        dropped_state, fixture.after_dropped, overlay_hold, overlay_release, fixture.decision,
    }) |report| {
        try t.expectEqual(
            report,
            try protocol.encode((try protocol.decode(&report, dimensions)).?, dimensions),
        );
    }
    // The keyboard reads host commands as the firmware does: unknown ids are null.
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
    _ = feed(&session, fixture.release_9, 5);
    _ = feed(&session, layer_state, 6);
    try t.expectEqual(@as(model.LayerIndex, 3), session.state.highest_layer);
    try t.expectEqual(@as(u16, 0b1001), session.state.active_layers);
    try t.expect(!session.state.pressed[9]);
    try t.expectEqual(@as(?u8, 4), session.state.last_sequence);
}

test "companion key signals pass through in sequence with keys" {
    const t = std.testing;
    var session = try connected();
    _ = feed(&session, hello, 1);
    _ = feed(&session, first_state, 2);
    const held = feed(&session, overlay_hold, 3);
    try t.expectEqualDeep(protocol.SignalEvent{ .kind = .overlay_toggle, .pressed = true, .source = .hold }, held.signal.?);
    try t.expectEqualDeep(
        protocol.SignalEvent{ .kind = .overlay_toggle, .pressed = false, .source = .hold },
        feed(&session, overlay_release, 4).signal.?,
    );
    // A signal out of sequence resynchronises like a key.
    try t.expectEqual(@as(?protocol.Command, .connect), feed(&session, overlay_hold, 5).send);
}

test "tap/hold decisions pass through in sequence with signals and keys" {
    const t = std.testing;
    var session = try connected();
    // Before the first state a decision is part of what that state reports.
    _ = feed(&session, hello, 1);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, fixture.decision, 2));
    _ = feed(&session, first_state, 3);
    _ = feed(&session, overlay_hold, 4);
    _ = feed(&session, overlay_release, 5);
    const decided = feed(&session, fixture.decision, 6);
    try t.expectEqualDeep(term_hold, decided.decision.?);
    try t.expect(decided.send == null and decided.key == null and decided.signal == null);
    // A decision out of sequence resynchronises like a key.
    try t.expectEqual(@as(?protocol.Command, .connect), feed(&session, fixture.decision, 7).send);
}

test "a version 1 keyboard connects; it simply never sends decisions" {
    const t = std.testing;
    var session = try connected();
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, literal(&(.{ 0x20, 1, 36, 4 } ++ keymap_id)), 1));
    try t.expectEqual(companion.Phase.synchronizing, session.phase);
    _ = feed(&session, first_state, 2);
    try t.expect(session.hasCoherentState());
    try t.expectEqual(@as(u8, 1), session.observed.?.version);
}

test "hello is matched against the open project and all-zero ids are unknown" {
    const t = std.testing;
    const Case = struct { report: protocol.Report, mismatch: companion.Mismatch };
    var other_id = keymap_id;
    other_id[15] ^= 1;
    for ([_]Case{
        .{ .report = firmwareHello(.{ .key_count = 34, .layer_count = 4, .keymap_id = keymap_id }), .mismatch = .dimensions },
        .{ .report = firmwareHello(.{ .key_count = 36, .layer_count = 3, .keymap_id = keymap_id }), .mismatch = .dimensions },
        .{ .report = firmwareHello(.{ .key_count = 36, .layer_count = 4 }), .mismatch = .unknown_keymap },
        .{ .report = firmwareHello(.{ .key_count = 36, .layer_count = 4, .keymap_id = other_id }), .mismatch = .keymap_id },
        // No firmware speaks a later version yet.
        .{ .report = literal(&(.{ 0x20, 3, 36, 4 } ++ keymap_id)), .mismatch = .unsupported_version },
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
    var keyboard = Keyboard.init(info);
    // The firmware keeps its sequence across connects; start near the wrap.
    keyboard.session.sequence = 254;
    keyboard.command(.connect);
    var session = try connected();
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, keyboard.take(), 1));
    _ = feed(&session, keyboard.take(), 2);
    try t.expectEqual(@as(?u8, 254), session.state.last_sequence);
    keyboard.key(true, 4, 0);
    _ = feed(&session, keyboard.take(), 3);
    keyboard.key(false, 4, 0);
    const wrapped_report = keyboard.take();
    try t.expectEqual(@as(u8, 0), wrapped_report[1]);
    const wrapped = feed(&session, wrapped_report, 4);
    try t.expect(wrapped.key != null and wrapped.send == null);
    try t.expect(session.hasCoherentState() and !session.state.pressed[4]);
    keyboard.key(true, 6, 0);
    _ = feed(&session, keyboard.take(), 5);
    // Report 2 is lost on the way, so sequence 3 follows 1.
    keyboard.key(false, 6, 0);
    _ = keyboard.take();
    keyboard.key(true, 6, 0);
    const gap = feed(&session, keyboard.take(), 6);
    try t.expectEqual(@as(?protocol.Command, .connect), gap.send);
    try t.expectEqual(@as(?protocol.KeyEvent, null), gap.key);
    try t.expectEqual(companion.Phase.negotiating, session.phase);
    try t.expect(!session.hasCoherentState() and !session.state.pressed[6]);
    // Reports already in flight are ignored until hello and state arrive.
    keyboard.key(true, 7, 0);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, keyboard.take(), 7));
    keyboard.layers(&.{1}, .{});
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, keyboard.take(), 7));
    keyboard.command(gap.send.?);
    _ = feed(&session, keyboard.take(), 8);
    // Events queued after connect precede the state; they are not applied.
    keyboard.key(true, 8, 1);
    keyboard.key(false, 8, 1);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, keyboard.take(), 8));
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, keyboard.take(), 8));
    _ = feed(&session, keyboard.take(), 9);
    try t.expect(keyboard.idle());
    try t.expect(session.hasCoherentState() and session.state.pressed[6] and session.state.pressed[7]);
    try t.expect(!session.state.pressed[8] and session.state.highest_layer == 1);
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
    const next = feed(&session, fixture.after_dropped, 5);
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
    var keyboard = connectedKeyboard();
    const keyboard_hello = keyboard.take();
    var session = try connected();
    _ = feed(&session, keyboard.take(), 1);
    try t.expectEqual(companion.Phase.negotiating, session.phase);
    _ = feed(&session, keyboard_hello, 2);
    keyboard.key(true, 5, 1);
    try t.expectEqualDeep(companion.Outcome{}, feed(&session, keyboard.take(), 3));
    try t.expect(!session.state.pressed[5]);
    keyboard.layers(&.{}, .{});
    _ = feed(&session, keyboard.take(), 4);
    try t.expect(session.state.pressed[5] and session.state.pressed[9]);
    keyboard.key(false, 5, 0);
    _ = feed(&session, keyboard.take(), 5);
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
