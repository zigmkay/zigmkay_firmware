const std = @import("std");
const jobs = @import("companion-jobs");
const wire = @import("runner-protocol");
const Client = @import("runner-client").Client;
const async_runner = @import("runner-async");
// Process startup competes with other test executables in the full build. Keep
// the deliberately short hung-peer deadline separate from successful fixtures.
const fixture_timeout_ms = 5_000;

fn awaitReady(owner: *async_runner.Owner, ticket: async_runner.Ticket) !void {
    const event = try awaitAsync(owner, ticket);
    switch (event) {
        .ready => {},
        .failed => |failure| return failure.failure,
        .reply => |reply| {
            var output = reply.output;
            output.deinit();
            return error.UnexpectedRunnerReply;
        },
    }
}

fn awaitAsync(owner: *async_runner.Owner, ticket: async_runner.Ticket) !async_runner.Event {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 10_000;
    while (true) {
        if (owner.poll(ticket)) |event| return event;
        if (std.Io.Clock.awake.now(io).toMilliseconds() > deadline) return error.AsyncRunnerTestTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}

test "asynchronous runner owns greeting serialized input releases and stale cancellation" {
    const t = std.testing;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(
        t.io,
        @import("options").runner_path,
        t.allocator,
    );
    defer t.allocator.free(executable);
    const ticket = async_runner.Ticket{ .generation = 1, .snapshot = @import("test-profile").snapshot_id };
    const owner = try async_runner.Owner.create(
        t.allocator,
        t.io,
        &.{executable},
        ticket,
        34,
        0,
        fixture_timeout_ms,
    );
    defer owner.destroy();
    try awaitReady(owner, ticket);
    try owner.input(.{ .key_down = 10 }, 0);
    try t.expectError(error.InvalidKeyDown, owner.input(.{ .key_down = 10 }, 0));
    try t.expectError(error.InvalidEncoder, owner.input(.{ .encoder = 0 }, 0));
    try owner.releaseHeld(10);
    try t.expect(!owner.pressed[10]);
    var down = (try awaitAsync(owner, ticket)).reply.output;
    defer down.deinit();
    var up = (try awaitAsync(owner, ticket)).reply.output;
    defer up.deinit();
    try t.expectEqual(@as(u64, 1), down.value.sequence);
    try t.expectEqual(@as(u8, 4), down.value.commands[0].KeyCodePress);
    try t.expectEqual(@as(u64, 2), up.value.sequence);
    try t.expectEqual(@as(u8, 4), up.value.commands[0].KeyCodeRelease);
    try owner.input(.advance, 20);
    _ = owner.poll(ticket); // Start an outstanding exchange before invalidation.
    var changed = ticket;
    changed.generation += 1;
    try t.expect(owner.poll(changed) == null);
    try t.expectEqual(.stale, owner.state);
    try t.expect(owner.future == null and owner.peer == null);
    try t.expectEqual(@as(usize, 0), owner.queue.items.len);
}

test "asynchronous runner rejects malformed peers and cancellation during startup" {
    const t = std.testing;
    const invalid = try std.Io.Dir.cwd().realPathFileAlloc(
        t.io,
        @import("options").invalid_runner_path,
        t.allocator,
    );
    defer t.allocator.free(invalid);
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(
        t.io,
        @import("options").runner_path,
        t.allocator,
    );
    defer t.allocator.free(executable);
    const ticket = async_runner.Ticket{ .generation = 2, .snapshot = @import("test-profile").snapshot_id };
    const bad = try async_runner.Owner.create(
        t.allocator,
        t.io,
        &.{ invalid, "sequence" },
        ticket,
        127,
        4,
        fixture_timeout_ms,
    );
    defer bad.destroy();
    try awaitReady(bad, ticket);
    try bad.input(.advance, 0);
    const failure = (try awaitAsync(bad, ticket)).failed;
    try t.expectEqual(error.RunnerSequenceMismatch, failure.failure);
    try t.expect(bad.peer == null and bad.future == null);
    const startup = try async_runner.Owner.create(
        t.allocator,
        t.io,
        &.{executable},
        ticket,
        34,
        0,
        fixture_timeout_ms,
    );
    startup.stop();
    try t.expectEqual(.stopped, startup.state);
    try t.expect(startup.peer == null and startup.future == null);
    startup.destroy();
}

test "asynchronous held releases are atomic when the bounded queue is full" {
    const t = std.testing;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(
        t.io,
        @import("options").runner_path,
        t.allocator,
    );
    defer t.allocator.free(executable);
    const ticket = async_runner.Ticket{ .generation = 3, .snapshot = @import("test-profile").snapshot_id };
    const owner = try async_runner.Owner.create(
        t.allocator,
        t.io,
        &.{executable},
        ticket,
        34,
        0,
        fixture_timeout_ms,
    );
    defer owner.destroy();
    try awaitReady(owner, ticket);
    try owner.input(.{ .key_down = 10 }, 1);
    for (1..async_runner.Owner.queue_limit) |_| try owner.input(.advance, 1);
    try t.expectError(error.InputQueueFull, owner.releaseHeld(2));
    try t.expect(owner.pressed[10]);
    try t.expectEqual(@as(u64, 1), owner.time_us);
    try t.expectEqual(async_runner.Owner.queue_limit, owner.queue.items.len);
    owner.stop();
    try t.expect(!owner.pressed[10]);
}

test "asynchronous runner deadlines close hung greeting and request peers" {
    const t = std.testing;
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(
        t.io,
        @import("options").invalid_runner_path,
        t.allocator,
    );
    defer t.allocator.free(executable);
    const ticket = async_runner.Ticket{ .generation = 4, .snapshot = @import("test-profile").snapshot_id };
    inline for (.{ "hang-greeting", "hang-request" }) |mode| {
        const owner = try async_runner.Owner.create(
            t.allocator,
            t.io,
            &.{ executable, mode },
            ticket,
            34,
            0,
            100,
        );
        defer owner.destroy();
        if (std.mem.eql(u8, mode, "hang-request")) {
            try awaitReady(owner, ticket);
            try owner.input(.advance, 0);
        }
        const event = try awaitAsync(owner, ticket);
        try t.expect(event == .failed);
        try t.expect(owner.peer == null and owner.future == null);
        try t.expectEqual(.failed, owner.state);
    }
}

test "real asynchronous processor output scores draft practice once and stops on completion" {
    const t = std.testing;
    const desktop = @import("desktop-core");
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(
        t.io,
        @import("options").runner_path,
        t.allocator,
    );
    defer t.allocator.free(executable);
    const snapshot = @import("test-profile").snapshot_id;
    var tutor = desktop.practice_controller.Controller.init(snapshot);
    _ = try tutor.choose(.{ .source = .draft }, 0);
    _ = try tutor.start(true, snapshot, 0);
    // A deterministic short exercise verifies literal processor translation.
    try tutor.session.load("aa", .draft);
    const operation = tutor.operation();
    const ticket = async_runner.Ticket{ .generation = operation.generation, .snapshot = operation.snapshot };
    const artifact = jobs.runner_artifact;
    const captured = jobs.firmware.Inputs{
        .project_digest = snapshot,
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = @splat(4),
        .identity_digest = @splat(5),
        .lock = jobs.target_lock.fixture(),
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        t.io,
        executable,
        t.allocator,
        .limited(artifact.max_bytes),
    );
    defer t.allocator.free(bytes);
    var manifest = try artifact.Manifest.complete(
        t.allocator,
        .succeeded,
        artifact.key(captured, artifact.native_target),
        captured,
        captured,
        executable,
        bytes,
    );
    defer manifest.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var frozen = try artifact.freeze(t.allocator, t.io, tmp.dir, manifest, captured);
    defer frozen.deinit();
    var wrong_ticket = ticket;
    wrong_ticket.snapshot[0] ^= 1;
    try t.expectError(
        error.RunnerSnapshotMismatch,
        async_runner.Owner.createVerified(t.allocator, t.io, frozen, captured, wrong_ticket, 34, 0, 1000),
    );
    var stale = captured;
    stale.build_inputs_digest[0] ^= 1;
    try t.expectError(
        error.StaleBuild,
        async_runner.Owner.createVerified(t.allocator, t.io, frozen, stale, ticket, 34, 0, 1000),
    );
    const owner = try async_runner.Owner.createVerified(
        t.allocator,
        t.io,
        frozen,
        captured,
        ticket,
        34,
        0,
        5000,
    );
    defer owner.destroy();
    var text = desktop.text.Text.init(true);
    defer text.deinit();
    const greeting = try awaitAsync(owner, ticket);
    if (greeting == .failed) return greeting.failed.failure;
    try t.expect(greeting == .ready);
    try owner.input(.{ .key_down = 10 }, 1000);
    var down = (try awaitAsync(owner, ticket)).reply.output;
    defer down.deinit();
    const first = desktop.practice_output.consume(
        &tutor,
        &text,
        operation,
        down.value.snapshot_id,
        down.value.sequence,
        down.value.commands,
        1000,
    );
    try t.expect(first.accepted and first.failure == null);
    try t.expect(
        !desktop.practice_output.consume(
            &tutor,
            &text,
            operation,
            down.value.snapshot_id,
            down.value.sequence,
            down.value.commands,
            1001,
        ).accepted,
    );
    var wrong = snapshot;
    wrong[0] ^= 1;
    try t.expect(
        !desktop.practice_output.consume(
            &tutor,
            &text,
            operation,
            wrong,
            2,
            down.value.commands,
            1002,
        ).accepted,
    );
    try t.expectEqual(@as(usize, 1), tutor.session.len);
    try owner.input(.{ .key_up = 10 }, 2000);
    var up = (try awaitAsync(owner, ticket)).reply.output;
    defer up.deinit();
    _ = desktop.practice_output.consume(
        &tutor,
        &text,
        operation,
        up.value.snapshot_id,
        up.value.sequence,
        up.value.commands,
        2000,
    );
    try owner.input(.{ .key_down = 10 }, 1_001_000);
    var second = (try awaitAsync(owner, ticket)).reply.output;
    defer second.deinit();
    const completed = desktop.practice_output.consume(
        &tutor,
        &text,
        operation,
        second.value.snapshot_id,
        second.value.sequence,
        second.value.commands,
        1_001_000,
    );
    try t.expectEqual(desktop.practice.State.complete, tutor.session.state);
    try t.expect(completed.effect.runner == .stop);
    try t.expect(tutor.session.scored and tutor.session.wpm(1_001_000) > 0);
    owner.stop();
    try t.expect(tutor.stopped(completed.effect.runner.stop, snapshot));
    try t.expectEqual(desktop.practice_controller.RunnerState.prepared, tutor.runner_state);
}

test "owned runner client rejects stale snapshot greetings before accepting input" {
    var wrong = @import("test-profile").snapshot_id;
    wrong[0] ^= 1;
    try std.testing.expectError(
        error.RunnerSnapshotMismatch,
        Client.create(std.testing.allocator, std.testing.io, &.{@import("options").runner_path}, wrong, 1000),
    );
}

test "owned runner client rejects unsupported and uncorrelated greetings" {
    const expected = @import("test-profile").snapshot_id;
    try std.testing.expectError(
        error.UnsupportedRunnerVersion,
        Client.create(
            std.testing.allocator,
            std.testing.io,
            &.{ @import("options").invalid_runner_path, "version" },
            expected,
            1000,
        ),
    );
    try std.testing.expectError(
        error.InvalidRunnerGreeting,
        Client.create(
            std.testing.allocator,
            std.testing.io,
            &.{ @import("options").invalid_runner_path, "greeting" },
            expected,
            1000,
        ),
    );
}

test "owned runner client closes peers with stale uncorrelated or oversized event replies" {
    inline for (.{
        .{ "sequence", error.RunnerSequenceMismatch },
        .{ "snapshot", error.RunnerSnapshotMismatch },
        .{ "events", error.RunnerEventLimit },
    }) |case| {
        const client = try Client.create(
            std.testing.allocator,
            std.testing.io,
            &.{ @import("options").invalid_runner_path, case[0] },
            @import("test-profile").snapshot_id,
            1000,
        );
        defer client.destroy();
        try std.testing.expectError(case[1], client.step(.advance, 0, 1000));
        try std.testing.expect(client.session.child == null);
    }
}

test "owned runner client correlates replies and closes reset and failed sessions" {
    const expected = @import("test-profile").snapshot_id;
    const client = try Client.create(
        std.testing.allocator,
        std.testing.io,
        &.{@import("options").runner_path},
        expected,
        1000,
    );
    defer client.destroy();
    var pressed = try client.step(.{ .key_down = 10 }, 0, 1000);
    defer pressed.deinit();
    try std.testing.expectEqual(@as(u8, 4), pressed.value.commands[0].KeyCodePress);
    try std.testing.expect(pressed.fresh(expected));
    var changed = expected;
    changed[0] ^= 1;
    try std.testing.expect(!pressed.fresh(changed));
    var reset = try client.step(.reset, 1, 1000);
    defer reset.deinit();
    try std.testing.expectEqual(.restart_required, reset.value.state);
    try std.testing.expectError(error.RunnerNotRunning, client.step(.advance, 2, 1000));
    const rejected = try Client.create(
        std.testing.allocator,
        std.testing.io,
        &.{@import("options").runner_path},
        expected,
        1000,
    );
    defer rejected.destroy();
    var failure = try rejected.step(.{ .key_up = 10 }, 0, 1000);
    defer failure.deinit();
    try std.testing.expectEqual(.failed, failure.value.state);
    try std.testing.expectEqualStrings("InvalidKeyUp", failure.value.diagnostic.?);
    try std.testing.expect(rejected.session.child == null);
}

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

test "draft runtime prepares explicitly routes real processor output and stops on focus or document changes" {
    const t = std.testing;
    const desktop = @import("desktop-core");
    const p = @import("project");
    var loaded = try p.profiles.create(t.allocator, .eurkey);
    defer loaded.deinit();
    var model = try desktop.model.Model.init(t.allocator, p.profiles.board, loaded.snapshot);
    defer model.deinit();
    const snapshot = try model.id();
    try t.expectEqual(@import("test-profile").snapshot_id, snapshot);
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(
        t.io,
        @import("options").runner_path,
        t.allocator,
    );
    defer t.allocator.free(executable);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        t.io,
        executable,
        t.allocator,
        .limited(jobs.runner_artifact.max_bytes),
    );
    defer t.allocator.free(bytes);
    const captured = jobs.firmware.Inputs{
        .project_digest = snapshot,
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = model.document().profile_id,
        .identity_digest = @splat(5),
        .lock = jobs.target_lock.fixture(),
    };
    var manifest = try jobs.runner_artifact.Manifest.complete(
        t.allocator,
        .succeeded,
        jobs.runner_artifact.key(captured, jobs.runner_artifact.native_target),
        captured,
        captured,
        executable,
        bytes,
    );
    defer manifest.deinit();
    var runtime = desktop.runner_runtime.Runtime.init(t.allocator, t.io, 7, true);
    defer runtime.deinit();
    var tutor = desktop.practice_controller.Controller.init(snapshot);
    _ = try tutor.choose(.{ .source = .draft }, 0);
    const prepare = try tutor.start(true, null, 0);
    try tutor.session.load("aa", .draft);
    tutor.session.pause(0);
    try runtime.apply(&tutor, prepare, manifest, &model, 0);
    try t.expect(
        tutor.runner_state == .prepared and runtime.owner == null and tutor.session.state == .paused,
    );
    try runtime.apply(&tutor, try tutor.resumeRun(1000), manifest, &model, 1000);
    const deadline = std.Io.Clock.awake.now(t.io).toMilliseconds() + 10_000;
    while (!runtime.router.runner_running) {
        try runtime.poll(&tutor, &model, 1000);
        if (std.Io.Clock.awake.now(t.io).toMilliseconds() > deadline) return error.AsyncRunnerTestTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    _ = try runtime.route(&tutor, &model, .{ .focus_gained = 7 }, 1000);
    runtime.router.owns_practice_input = true;
    try t.expect(try runtime.route(&tutor, &model, .{ .text = 7 }, 1000));
    try t.expect(
        try runtime.route(&tutor, &model, .{ .key = .{ .window = 7, .scancode = 4, .down = true } }, 1000),
    );
    try t.expect(try runtime.route(&tutor, &model, .{ .key = .{
        .window = 7,
        .scancode = 4,
        .down = true,
        .repeat = true,
    } }, 1000));
    while (tutor.session.len == 0) {
        try runtime.poll(&tutor, &model, 1000);
        if (std.Io.Clock.awake.now(t.io).toMilliseconds() > deadline) return error.AsyncRunnerTestTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expectEqual(@as(usize, 1), tutor.session.matched());
    _ = try runtime.route(&tutor, &model, .{ .focus_lost = 7 }, 2000);
    try t.expect(
        runtime.owner == null and runtime.router.mapping == null and tutor.session.state == .paused and tutor.runner_state == .prepared,
    );
    try t.expectEqual(@as(usize, 0), runtime.text.len);
    try runtime.apply(&tutor, try tutor.resumeRun(3000), manifest, &model, 3000);
    try model.rename("Changed during draft run");
    const changed = tutor.observe(try model.id(), 4000);
    try runtime.apply(&tutor, changed, manifest, &model, 4000);
    try t.expect(runtime.owner == null and tutor.runner_state == .idle);
    try t.expect(
        !try runtime.route(&tutor, &model, .{ .key = .{ .window = 7, .scancode = 4, .down = true } }, 4000),
    );
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
