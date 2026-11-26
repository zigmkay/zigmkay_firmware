//! Tap/hold decisions reported to a connected companion.
const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const companion = zigmkay.companion;

const helpers = @import("test_processing_helpers.zig");

const a = 0x04;
const b = 0x05;
const c = 0x06;
const f = 0x09;
const space = 0x2C;
const term = core.TimeSpan{ .ms = 200 };

fn retro(def: core.KeyDef) core.KeyDef {
    var copy = def;
    copy.tap_hold.retro_tapping = true;
    return copy;
}

// 0: home-row Shift on f (left), 1: a (right), 2: b (left), 3: layer-tap Space.
const base = [_]?core.KeyDef{
    helpers.MT(.{ .key_press = .{ .tap_keycode = f } }, .{ .left_shift = true }, term),
    helpers.TAP(a),
    helpers.TAP(b),
    helpers.LT(1, space, .{}, term),
};
// Layer 1 turns key 2 into a home-row Ctrl on c; the rest falls through.
const layer1 = [_]?core.KeyDef{ null, null, helpers.MT(.{ .key_press = .{ .tap_keycode = c } }, .{ .left_ctrl = true }, term), null };
const keymap = [_][base.len]?core.KeyDef{ base, layer1 };
const retro_keymap = [_][base.len]?core.KeyDef{.{ retro(base[0].?), base[1], base[2], base[3] }};
const sides = [base.len]core.Side{ .L, .R, .L, .X };

const Processor = helpers.init_with_config(.{ .key_count = base.len, .layer_count = keymap.len }, .{ .keymap = &keymap, .sides = sides });
const RetroProcessor = helpers.init_with_config(.{ .key_count = base.len, .layer_count = retro_keymap.len }, .{ .keymap = &retro_keymap, .sides = sides });

const Harness = struct {
    session: companion.Session = companion.Session.init(.{ .key_count = base.len, .layer_count = keymap.len }),

    fn connect(self: *Harness) void {
        var connect_report: companion.Report = @splat(0);
        connect_report[0] = @backingInt(companion.Command.connect);
        _ = self.session.receive(&connect_report);
        _ = self.take(); // hello
        _ = self.take(); // state
    }

    fn take(self: *Harness) ?companion.Report {
        const report = self.session.next_report() orelse return null;
        self.session.sent();
        return report;
    }

    /// The next decision report, skipping key and state reports.
    fn decision(self: *Harness) ?companion.Report {
        while (self.take()) |report| {
            if (report[0] == @backingInt(companion.MessageId.decision)) return report;
        }
        return null;
    }
};

fn at(ms: u64) core.TimeSinceBoot {
    return core.TimeSinceBoot.from_absolute_us(1000 + ms * 1000);
}

fn expectDecision(
    report: ?companion.Report,
    key: u8,
    outcome: companion.DecisionOutcome,
    reason: companion.DecisionReason,
    ms: u16,
    other: u8,
    layer: u8,
) !void {
    const r = report orelse return error.TestExpectedDecision;
    try std.testing.expectEqual(@backingInt(companion.MessageId.decision), r[0]);
    try std.testing.expectEqual(key, r[2]);
    try std.testing.expectEqual(@backingInt(outcome), r[3]);
    try std.testing.expectEqual(@backingInt(reason), r[4]);
    try std.testing.expectEqual(ms, std.mem.readInt(u16, r[5..7], .little));
    try std.testing.expectEqual(other, r[7]);
    try std.testing.expectEqual(term.ms, std.mem.readInt(u16, r[8..10], .little));
    try std.testing.expectEqual(layer, r[10]);
    try std.testing.expectEqual(0, r[11]);
}

test "a tap/hold key released within the tapping term reports a tap" {
    var h: Harness = .{};
    h.connect();
    var o = Processor{ .companion_session = &h.session };
    try o.press_key(0, at(0));
    try o.release_key(0, at(40));
    try o.process(at(40));
    try expectDecision(h.decision(), 0, .tap, .released_within_term, 40, companion.no_other_key, 0);
    try std.testing.expectEqual(null, h.decision());
}

test "a held key reports a hold once the tapping term elapses" {
    var h: Harness = .{};
    h.connect();
    var o = Processor{ .companion_session = &h.session };
    try o.press_key(0, at(0));
    try o.process(at(100));
    try std.testing.expectEqual(null, h.decision());
    try o.process(at(230));
    try expectDecision(h.decision(), 0, .hold, .term_elapsed, 230, companion.no_other_key, 0);
    // A later event past the term decides through the queued events instead.
    var late = Processor{ .companion_session = &h.session };
    try late.press_key(0, at(1000));
    try late.press_key(1, at(1250));
    try late.process(at(1250));
    try expectDecision(h.decision(), 0, .hold, .term_elapsed, 250, companion.no_other_key, 0);
}

test "a roll onto the other hand reports a permissive hold with the other key" {
    var h: Harness = .{};
    h.connect();
    var o = Processor{ .companion_session = &h.session };
    try o.press_key(0, at(0));
    try o.press_key(1, at(30));
    try o.release_key(1, at(70));
    try o.release_key(0, at(90));
    try o.process(at(90));
    try expectDecision(h.decision(), 0, .hold, .permissive_hold, 70, 1, 0);
    try std.testing.expectEqual(null, h.decision());
}

test "a roll on the same hand reports a tap with the other key" {
    var h: Harness = .{};
    h.connect();
    var o = Processor{ .companion_session = &h.session };
    try o.press_key(0, at(0));
    try o.press_key(2, at(20));
    try o.release_key(2, at(60));
    try o.process(at(60));
    try expectDecision(h.decision(), 0, .tap, .same_side_tap, 60, 2, 0);
}

test "a hold released with nothing in between reports a retro tap" {
    var h: Harness = .{};
    h.connect();
    var o = RetroProcessor{ .companion_session = &h.session };
    // The processor retro-taps only when the release is queued as the hold is
    // decided; a hold decided in an earlier pass is released without a tap.
    try o.press_key(0, at(0));
    try o.release_key(0, at(320));
    try o.process(at(320));
    try expectDecision(h.decision(), 0, .hold, .term_elapsed, 320, companion.no_other_key, 0);
    try expectDecision(h.decision(), 0, .retro_tap, .released_after_term, 320, companion.no_other_key, 0);
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{ .left_shift = true } }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .ModifiersChanged = .{} }, o.actions_queue.dequeue());
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = f }, o.actions_queue.dequeue());
    // Without retro tapping a release reports nothing more.
    var plain = Processor{ .companion_session = &h.session };
    try plain.press_key(0, at(1000));
    try plain.process(at(1210));
    _ = h.decision();
    try plain.release_key(0, at(1300));
    try plain.process(at(1300));
    try std.testing.expectEqual(null, h.decision());
}

test "a decision names the layer the key was taken from and follows its press" {
    var h: Harness = .{};
    h.connect();
    var o = Processor{ .companion_session = &h.session };
    try o.press_key(3, at(0));
    try o.process(at(210));
    try expectDecision(h.decision(), 3, .hold, .term_elapsed, 210, companion.no_other_key, 0);
    // Key 2 is a tap/hold key on layer 1 only.
    try o.press_key(2, at(300));
    h.session.key_event(true, 2, 1, .{});
    try o.release_key(2, at(340));
    try o.process(at(340));
    const press = h.take().?;
    try std.testing.expectEqual(@backingInt(companion.MessageId.key), press[0]);
    const decision = h.take();
    try expectDecision(decision, 2, .tap, .released_within_term, 40, companion.no_other_key, 1);
    try std.testing.expectEqual(press[1] +% 1, decision.?[1]);
}

test "decisions are not reported while the companion is disconnected" {
    var h: Harness = .{};
    var o = Processor{ .companion_session = &h.session };
    try o.press_key(0, at(0));
    try o.release_key(0, at(40));
    try o.process(at(40));
    try std.testing.expectEqual(0, h.session.event_count);
    // A processor without a session decides exactly the same.
    var alone = Processor{};
    try alone.press_key(0, at(0));
    try alone.release_key(0, at(40));
    try alone.process(at(40));
    try std.testing.expectEqual(core.OutputCommand{ .KeyCodePress = f }, alone.actions_queue.dequeue());
}
