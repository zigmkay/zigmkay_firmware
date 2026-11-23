const std = @import("std");
const jobs = @import("companion-jobs");
const wire = @import("runner-protocol");
fn response(gpa: std.mem.Allocator, bytes: []const u8) !wire.Output {
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    return @import("owned-zon").parse(wire.Output, gpa, text);
}

fn send(session: *jobs.Session, command: wire.Input) !wire.Output {
    const gpa = std.testing.allocator;
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(command, .{ .whitespace = false }, &encoded.writer, 16);
    const bytes = try session.request(gpa, std.testing.io, encoded.written(), 1000);
    defer gpa.free(bytes);
    return response(gpa, bytes);
}

test "native runner literal trace validation and fresh-process reset" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session = try gpa.create(jobs.Session);
    defer gpa.destroy(session);
    session.* = .{};
    defer session.stop(io);
    try session.start(io, &.{@import("options").runner_path});
    const greeting = try session.request(gpa, io, null, 1000);
    defer gpa.free(greeting);
    const ready = try response(gpa, greeting);
    defer @import("owned-zon").free(gpa, ready);
    try std.testing.expectEqual(.ready, ready.state);
    const down = try send(session, .{ .sequence = 1, .time_us = 0, .command = .{ .key_down = 10 } });
    defer @import("owned-zon").free(gpa, down);
    try std.testing.expectEqual(.processed, down.state);
    try std.testing.expectEqual(@as(usize, 1), down.commands.len);
    try std.testing.expectEqual(@as(u8, 4), down.commands[0].KeyCodePress);
    const up = try send(session, .{ .sequence = 2, .time_us = 10000, .command = .{ .key_up = 10 } });
    defer @import("owned-zon").free(gpa, up);
    try std.testing.expectEqual(@as(u8, 4), up.commands[0].KeyCodeRelease);
    const reset = try send(session, .{ .sequence = 3, .time_us = 11000, .command = .reset });
    defer @import("owned-zon").free(gpa, reset);
    try std.testing.expectEqual(.restart_required, reset.state);
    session.stop(io);
    try session.start(io, &.{@import("options").runner_path});
    const restarted = try session.request(gpa, io, null, 1000);
    defer gpa.free(restarted);
    const invalid = try send(session, .{ .sequence = 1, .time_us = 0, .command = .{ .key_up = 10 } });
    defer @import("owned-zon").free(gpa, invalid);
    try std.testing.expectEqual(.failed, invalid.state);
    try std.testing.expectEqualStrings("InvalidKeyUp", invalid.diagnostic.?);
}

const Harness = struct {
    session: *jobs.Session,
    sequence: u64 = 0,
    time: u64 = 0,

    fn init() !Harness {
        return initPath(@import("options").action_runner_path);
    }

    fn initPath(path: []const u8) !Harness {
        const gpa = std.testing.allocator;
        const session = try gpa.create(jobs.Session);
        errdefer gpa.destroy(session);
        session.* = .{};
        try session.start(std.testing.io, &.{path});
        errdefer session.stop(std.testing.io);
        const greeting = try session.request(gpa, std.testing.io, null, 1000);
        defer gpa.free(greeting);
        return .{ .session = session };
    }

    fn deinit(self: *Harness) void {
        self.session.stop(std.testing.io);
        std.testing.allocator.destroy(self.session);
    }

    fn step(
        self: *Harness,
        command: wire.Command,
        delta_ms: u64,
        expected: []const @import("zigmkay").core.OutputCommand,
        layers: u16,
    ) !void {
        self.sequence += 1;
        self.time += delta_ms * 1000;
        const output = try send(self.session, .{
            .sequence = self.sequence,
            .time_us = self.time,
            .command = command,
        });
        defer @import("owned-zon").free(std.testing.allocator, output);
        try std.testing.expectEqual(.processed, output.state);
        if (output.commands.len != expected.len) {
            std.debug.print(
                "sequence {d}: got {any}, expected {any}\n",
                .{ self.sequence, output.commands, expected },
            );
        }
        try std.testing.expectEqual(expected.len, output.commands.len);
        for (expected, output.commands) |wanted, actual| try std.testing.expect(std.meta.eql(wanted, actual));
        try std.testing.expectEqual(layers, output.active_layers);
    }
};

test "generated action matrix literal modifiers tap hold autofire media mouse transparency and custom traces" {
    var h = try Harness.init();
    defer h.deinit();
    try h.step(.{ .key_down = 11 }, 0, &.{.{ .ModifiersChanged = .{ .left_shift = true } }}, 1);
    try h.step(.{ .key_up = 11 }, 1, &.{.{ .ModifiersChanged = .{} }}, 1);
    try h.step(.{ .key_down = 12 }, 1, &.{}, 1);
    try h.step(.{ .key_up = 12 }, 20, &.{ .{ .KeyCodePress = 6 }, .{ .KeyCodeRelease = 6 } }, 1);
    try h.step(.{ .key_down = 12 }, 1, &.{}, 1);
    try h.step(.advance, 200, &.{.{ .ModifiersChanged = .{ .left_ctrl = true } }}, 1);
    // A separate advance is a processor action, so its existing retro rule suppresses the tap.
    try h.step(.{ .key_up = 12 }, 1, &.{.{ .ModifiersChanged = .{} }}, 1);
    try h.step(.{ .key_down = 12 }, 1, &.{}, 1);
    try h.step(.{ .key_up = 12 }, 201, &.{
        .{ .ModifiersChanged = .{ .left_ctrl = true } },
        .{ .ModifiersChanged = .{} },
        .{ .KeyCodePress = 6 },
        .{ .KeyCodeRelease = 6 },
    }, 1);
    try h.step(.{ .key_down = 13 }, 1, &.{ .{ .KeyCodePress = 7 }, .{ .KeyCodeRelease = 7 } }, 1);
    try h.step(.advance, 101, &.{ .{ .KeyCodePress = 7 }, .{ .KeyCodeRelease = 7 } }, 1);
    try h.step(.{ .key_up = 13 }, 1, &.{}, 1);
    for ([_]u7{ 14, 15 }) |key| {
        try h.step(.{ .key_down = key }, 1, &.{}, 1);
        try h.step(.{ .key_up = key }, 1, &.{}, 1);
    }
    try h.step(.{ .key_down = 17 }, 1, &.{.{ .ConsumerKeyPressed = .VolumeUp }}, 1);
    try h.step(.{ .key_up = 17 }, 1, &.{.{ .ConsumerKeyReleased = .VolumeUp }}, 1);
    try h.step(.{ .key_down = 18 }, 1, &.{.{ .MouseCommandPressed = .WheelDown }}, 1);
    try h.step(.{ .key_up = 18 }, 1, &.{.{ .MouseCommandReleased = .WheelDown }}, 1);
    try h.step(.{ .key_down = 19 }, 1, &.{ .{ .KeyCodePress = 5 }, .{ .KeyCodeRelease = 5 } }, 1);
    try h.step(.{ .key_up = 19 }, 1, &.{}, 1);
    try h.step(.{ .key_down = 19 }, 1, &.{ .{ .KeyCodePress = 6 }, .{ .KeyCodeRelease = 6 } }, 1);
    try h.step(.{ .key_up = 19 }, 1, &.{}, 1);
    try h.step(.{ .key_down = 24 }, 1, &.{ .ActivateBootMode, .{ .KeyCodePress = 252 } }, 1);
    try h.step(.{ .key_up = 24 }, 1, &.{.{ .KeyCodeRelease = 252 }}, 1);
    try h.step(.{ .encoder = 0 }, 1, &.{ .{ .KeyCodePress = 9 }, .{ .KeyCodeRelease = 9 } }, 1);
}

test "generated layer one-shot combo dead chord custom hold and signal traces" {
    var h = try Harness.init();
    defer h.deinit();
    try h.step(.{ .key_down = 21 }, 0, &.{}, 3);
    try h.step(.{ .key_down = 16 }, 1, &.{.{ .KeyCodePress = 80 }}, 3);
    try h.step(.{ .key_up = 16 }, 1, &.{.{ .KeyCodeRelease = 80 }}, 3);
    try h.step(.{ .key_up = 21 }, 1, &.{}, 1);
    try h.step(.{ .key_down = 25 }, 1, &.{}, 3);
    try h.step(.{ .key_up = 25 }, 1, &.{}, 1);
    try h.step(.{ .key_down = 16 }, 1, &.{}, 1);
    try h.step(.{ .key_up = 16 }, 1, &.{}, 1);
    try h.step(.{ .key_down = 10 }, 1, &.{ .{
        .ModifiersChanged = .{ .left_shift = true },
    }, .{ .KeyCodePress = 4 } }, 1);
    try h.step(.{ .key_up = 10 }, 1, &.{ .{ .KeyCodeRelease = 4 }, .{ .ModifiersChanged = .{} } }, 1);
    try h.step(.{ .key_down = 20 }, 1, &.{
        .{ .ModifiersChanged = .{ .left_gui = true } },
        .{ .KeyCodePress = 8 },
        .{ .KeyCodeRelease = 8 },
        .{ .ModifiersChanged = .{} },
    }, 1);
    try h.step(.{ .key_up = 20 }, 1, &.{ .{ .KeyCodePress = 44 }, .{ .KeyCodeRelease = 44 } }, 1);
    try h.step(.{ .key_down = 0 }, 1, &.{}, 1);
    try h.step(.{ .key_down = 4 }, 1, &.{ .ActivateBootMode, .{ .KeyCodePress = 252 } }, 1);
    try h.step(.{ .key_up = 0 }, 1, &.{.{ .KeyCodeRelease = 252 }}, 1);
    try h.step(.{ .key_up = 4 }, 1, &.{}, 1);
    h.sequence += 1;
    h.time += 1000;
    const signal = try send(h.session, .{
        .sequence = h.sequence,
        .time_us = h.time,
        .command = .{ .key_down = 23 },
    });
    defer @import("owned-zon").free(std.testing.allocator, signal);
    try std.testing.expectEqual(@as(usize, 1), signal.signals.len);
    try std.testing.expectEqual(.log_toggle, signal.signals[0].kind);
    try std.testing.expect(signal.signals[0].pressed);
}

test "restarting the native runner resets attached callback globals" {
    for (0..2) |_| {
        var h = try Harness.init();
        defer h.deinit();
        try h.step(.{ .key_down = 19 }, 0, &.{ .{ .KeyCodePress = 5 }, .{ .KeyCodeRelease = 5 } }, 1);
    }
}

test "native runner rejects backward time duplicate sequence and unsupported version" {
    const Case = struct { input: wire.Input, diagnostic: []const u8 };
    for ([_]Case{
        .{ .input = .{ .sequence = 1, .time_us = 0, .command = .advance }, .diagnostic = "InvalidSequence" },
        .{ .input = .{ .sequence = 2, .time_us = 0, .command = .advance }, .diagnostic = "InvalidTime" },
        .{
            .input = .{ .version = 2, .sequence = 2, .time_us = 1000, .command = .advance },
            .diagnostic = "UnsupportedVersion",
        },
    }) |case| {
        var h = try Harness.init();
        defer h.deinit();
        try h.step(.advance, 1, &.{}, 1);
        const result = try send(h.session, case.input);
        defer @import("owned-zon").free(std.testing.allocator, result);
        try std.testing.expectEqual(.failed, result.state);
        try std.testing.expectEqualStrings(case.diagnostic, result.diagnostic.?);
    }
}

test "native runner startup and input roundtrip latency measurement" {
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io);
    var h = try Harness.init();
    defer h.deinit();
    const prepared = std.Io.Clock.awake.now(io);
    try h.step(.{ .key_down = 10 }, 0, &.{.{ .KeyCodePress = 4 }}, 1);
    const completed = std.Io.Clock.awake.now(io);
    try std.testing.expect(start.durationTo(prepared).nanoseconds >= 0);
    try std.testing.expect(prepared.durationTo(completed).nanoseconds >= 0);
}

test "unchanged registered Danish callback layers and Alt Tab literal trace" {
    var h = try Harness.initPath(@import("options").registered_runner_path);
    defer h.deinit();
    try h.step(.{ .key_down = 31 }, 0, &.{}, 1);
    try h.step(.advance, 151, &.{}, 5);
    try h.step(.{ .key_down = 32 }, 1, &.{}, 5);
    try h.step(.advance, 151, &.{}, 9);
    try h.step(.{ .key_up = 32 }, 1, &.{}, 5);
    try h.step(.{ .key_down = 1 }, 1, &.{
        .{ .ModifiersChanged = .{ .left_alt = true } },
        .{ .KeyCodePress = 43 },
        .{ .KeyCodeRelease = 43 },
    }, 5);
    try h.step(.{ .key_up = 1 }, 1, &.{}, 5);
    try h.step(.{ .key_up = 31 }, 1, &.{.{ .ModifiersChanged = .{} }}, 1);
}

test "companion signals are derived host-side from reserved custom ids and keycodes" {
    const core = @import("zigmkay").core;
    const t = std.testing;
    const log_tap = core.TapDef{ .custom = core.CUSTOM_ID_COMPANION_LOG_TOGGLE };
    try t.expectEqual(
        wire.Signal{ .kind = .log_toggle, .pressed = true },
        wire.eventSignal(.{ .OnTapEnterAfter = .{ .tap = log_tap } }).?,
    );
    try t.expectEqual(
        wire.Signal{ .kind = .log_toggle, .pressed = false },
        wire.eventSignal(.{ .OnTapExitBefore = .{ .tap = log_tap } }).?,
    );
    try t.expectEqual(
        @as(?wire.Signal, null),
        wire.eventSignal(.{ .OnTapEnterBefore = .{ .tap = log_tap } }),
    );
    const overlay_hold = core.HoldDef{ .custom = core.CUSTOM_ID_COMPANION_TOGGLE };
    try t.expectEqual(
        wire.Signal{ .kind = .overlay_toggle, .pressed = true },
        wire.eventSignal(.{ .OnHoldEnterAfter = .{ .hold = overlay_hold } }).?,
    );
    try t.expectEqual(
        wire.Signal{ .kind = .overlay_toggle, .pressed = false },
        wire.eventSignal(.{ .OnHoldExitBefore = .{ .hold = overlay_hold } }).?,
    );
    try t.expectEqual(
        wire.Signal{ .kind = .shutdown, .pressed = true },
        wire.eventSignal(.{ .OnTapEnterAfter = .{ .tap = .{
            .custom = core.CUSTOM_ID_COMPANION_SHUTDOWN,
        } } }).?,
    );
    try t.expectEqual(
        @as(?wire.Signal, null),
        wire.eventSignal(.{ .OnTapEnterAfter = .{ .tap = .{ .custom = 1 } } }),
    );
    try t.expectEqual(@as(?wire.Signal, null), wire.eventSignal(.Tick));
    try t.expectEqual(
        wire.Signal{ .kind = .overlay_toggle, .pressed = true },
        wire.commandSignal(.{ .KeyCodePress = core.special_keycode_COMPANION }).?,
    );
    try t.expectEqual(
        wire.Signal{ .kind = .shutdown, .pressed = false },
        wire.commandSignal(.{ .KeyCodeRelease = core.special_keycode_SHUTDOWN_COMPANION }).?,
    );
    try t.expectEqual(@as(?wire.Signal, null), wire.commandSignal(.{ .KeyCodePress = 4 }));
    try t.expectEqual(@as(?wire.Signal, null), wire.commandSignal(.ActivateBootMode));
}
