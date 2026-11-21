//! Explicit tutor controls over the retained Session. Runner effects require a
//! caller-owned adapter: stop/reap before replacing a runner, never infer keys
//! from OS text. Times are injected microseconds.
const std = @import("std");
const practice = @import("practice.zig");
const generator = @import("practice_generator.zig");
pub const Digest = [32]u8;
pub const Mode = enum { english, zig };
/// What the keyboard guide shows during a run.
pub const Assistance = enum { guided, layout_only, hidden };

pub const Config = struct {
    mode: Mode = .english,
    /// An index into `generator.sentence_counts` for English, the lesson for Zig.
    level: usize = 1,
    source: practice.Source = .os,
    assistance: Assistance = .guided,

    pub fn validate(self: Config) !void {
        const levels = switch (self.mode) {
            .english => generator.sentence_counts.len,
            .zig => practice.lessons.len,
        };
        if (self.level >= levels) return error.InvalidExerciseLevel;
    }
};

pub const Operation = struct { generation: u64, snapshot: Digest };
pub const RunnerState = enum { idle, preparing, prepared, running, stopping, failed, stale };
pub const Replacement = struct { previous: ?Operation, operation: Operation };

pub const RunnerEffect = union(enum) {
    none,
    stop: Operation,
    stop_then_prepare: Replacement,
    stop_then_start: Replacement,
    start: Operation,
};

pub const Effect = struct { runner: RunnerEffect = .none, reset_text: bool = false };

pub const Intent = union(enum) {
    choose: Config,
    start: bool,
    new_exercise,
    pause,
    resume_run,
    stop,
};

pub const Action = struct { generation: u64, snapshot: Digest, intent: Intent };

pub const Controller = struct {
    session: practice.Session = .{},
    config: Config = .{},
    captured_config: Config = .{},
    current: Digest,
    captured: Digest = @splat(0),
    generation: u64 = 0,
    active: bool = false,
    seed: u64 = 1,
    runner_state: RunnerState = .idle,
    last_sequence: ?u64 = null,
    failure: ?anyerror = null,

    pub fn init(snapshot: Digest) Controller {
        return .{ .current = snapshot };
    }

    pub fn operation(self: *const Controller) Operation {
        return .{ .generation = self.generation, .snapshot = self.captured };
    }

    pub fn action(self: *const Controller, intent: Intent) Action {
        return .{ .generation = self.generation, .snapshot = self.current, .intent = intent };
    }

    /// Apply one rendered control after drawing. This prevents batched clicks
    /// from losing the operation of a runner that still needs to be stopped.
    pub fn dispatch(self: *Controller, rendered: Action, prepared_snapshot: ?Digest, now: u64) !Effect {
        if (rendered.generation != self.generation or
            !std.mem.eql(u8, &rendered.snapshot, &self.current)) return error.StalePracticeAction;
        return switch (rendered.intent) {
            .choose => |config| try self.choose(config, now),
            .start => |fresh_exercise| try self.start(fresh_exercise, prepared_snapshot, now),
            .new_exercise => blk: {
                try self.config.validate();
                if (self.generation == std.math.maxInt(u64)) return error.OperationExhausted;
                if (self.config.mode == .zig) self.config.level = (self.config.level + 1) % practice.lessons.len;
                break :blk try self.start(true, prepared_snapshot, now);
            },
            .pause => self.pause(now),
            .resume_run => try self.resumeRun(now),
            .stop => self.stop(now),
        };
    }

    fn fresh(self: *const Controller) bool {
        return std.mem.eql(u8, &self.current, &self.captured);
    }

    fn accepts(self: *const Controller, operation_value: Operation) bool {
        return self.active and self.fresh() and std.meta.eql(self.operation(), operation_value);
    }

    pub fn choose(self: *Controller, config: Config, now: u64) !Effect {
        try config.validate();
        if (std.meta.eql(config, self.config)) return .{};
        const effect = self.pause(now);
        self.config = config;
        self.active = false;
        return effect;
    }

    /// Only the caller's deliberate Start/Restart/New exercise action calls this.
    /// Preparation completion leaves draft scoring paused until explicit Resume.
    pub fn start(self: *Controller, _: bool, prepared_snapshot: ?Digest, now: u64) !Effect {
        try self.config.validate();
        if (self.generation == std.math.maxInt(u64)) return error.OperationExhausted;
        const previous: ?Operation = if (self.generation == 0) null else self.operation();
        var buffer: [8192]u8 = undefined;
        self.seed +%= 0x9e3779b97f4a7c15;
        var text = try self.reference(&buffer);
        if (self.config.mode == .english and self.session.reference_len > 0) {
            var retries: usize = 0;
            while (sameOpening(&self.session, text)) : (retries += 1) {
                if (retries == 4) return error.ExerciseFreshnessUnavailable;
                self.seed +%= 0x9e3779b97f4a7c15;
                text = try self.reference(&buffer);
            }
        }
        try self.session.load(text, self.config.source);
        self.generation += 1;
        self.captured = self.current;
        self.captured_config = self.config;
        self.active = true;
        self.failure = null;
        self.last_sequence = null;
        if (self.session.source == .os) {
            self.runner_state = .idle;
            return .{ .runner = if (previous) |old| .{ .stop = old } else .none, .reset_text = true };
        }
        const already_prepared = if (prepared_snapshot) |snapshot| std.mem.eql(u8, &snapshot, &self.current) else false;
        self.runner_state = if (already_prepared) .running else .preparing;
        if (!already_prepared) self.session.pause(now);
        const replacement: Replacement = .{ .previous = previous, .operation = self.operation() };
        return .{
            .runner = if (already_prepared) .{ .stop_then_start = replacement } else .{
                .stop_then_prepare = replacement,
            },
            .reset_text = true,
        };
    }

    fn reference(self: *const Controller, buffer: []u8) ![]const u8 {
        return switch (self.config.mode) {
            .zig => practice.lessons[self.config.level],
            .english => generator.generate(buffer, self.seed, generator.sentence_counts[self.config.level]),
        };
    }

    pub fn prepared(self: *Controller, op: Operation, success: bool) bool {
        if (!self.accepts(op) or self.runner_state != .preparing) return false;
        self.runner_state = if (success) .prepared else .failed;
        self.failure = if (success) null else error.DraftPreparationFailed;
        return true;
    }

    /// Called only after the owned runner has stopped/reaped. Accepted prepared
    /// artifact evidence may then retain the reference fast Resume behavior.
    pub fn stopped(self: *Controller, op: Operation, prepared_snapshot: ?Digest) bool {
        if (!std.meta.eql(op, self.operation()) or self.runner_state != .stopping) return false;
        const prepared_current = if (prepared_snapshot) |snapshot| self.fresh() and std.mem.eql(u8, &snapshot, &self.current) else false;
        self.runner_state = if (prepared_current) .prepared else .idle;
        return true;
    }

    pub fn resumeRun(self: *Controller, now: u64) !Effect {
        if (self.failure) |failure| if (failure == error.PracticeContextChanged) return error.PracticeContextChanged;
        if (!self.active or self.session.state != .paused) return error.ExerciseNotPaused;
        if (self.session.source == .draft) {
            if (!self.fresh()) return error.DraftChangedRestartPractice;
            if (self.runner_state == .stopping) return error.RunnerStopping;
            if (self.generation == std.math.maxInt(u64)) return error.OperationExhausted;
            const previous = self.operation();
            self.generation += 1;
            if (self.runner_state != .prepared) {
                self.runner_state = .preparing;
                return .{ .runner = .{ .stop_then_prepare = .{
                    .previous = previous,
                    .operation = self.operation(),
                } }, .reset_text = true };
            }
            self.runner_state = .running;
            self.last_sequence = null;
            self.session.resumeRun(now);
            return .{ .runner = .{ .start = self.operation() }, .reset_text = true };
        }
        self.session.resumeRun(now);
        return .{ .reset_text = true };
    }

    pub fn pause(self: *Controller, now: u64) Effect {
        if (!self.active) return .{};
        self.session.pause(now);
        if (self.session.source == .draft) {
            self.runner_state = .stopping;
            return .{ .runner = .{ .stop = self.operation() }, .reset_text = true };
        }
        return .{ .reset_text = true };
    }

    pub fn stop(self: *Controller, now: u64) Effect {
        const effect = self.pause(now);
        self.active = false;
        return effect;
    }

    pub fn observe(self: *Controller, snapshot: Digest, now: u64) Effect {
        if (std.mem.eql(u8, &snapshot, &self.current)) return .{};
        self.current = snapshot;
        if (!self.active or self.session.source != .draft) return .{};
        const effect = self.pause(now);
        self.failure = error.DraftChangedRestartPractice;
        return effect;
    }

    pub fn acceptingOsText(self: *const Controller, focused: bool) bool {
        return focused and self.active and self.session.source == .os and (self.session.state == .ready or self.session.state == .running);
    }

    pub fn insertOs(self: *Controller, focused: bool, bytes: []const u8, now: u64, paste: bool) !Effect {
        if (!self.acceptingOsText(focused)) return .{};
        try self.session.insert(bytes, now, paste);
        return self.finish(now);
    }

    pub fn insertDraft(self: *Controller, op: Operation, sequence: u64, bytes: []const u8, now: u64) !Effect {
        if (!self.accepts(op) or self.runner_state != .running or self.session.source != .draft) return .{};
        if (self.last_sequence) |last| if (sequence <= last) return .{};
        try self.session.insert(bytes, now, false);
        self.last_sequence = sequence;
        return self.finish(now);
    }

    pub fn finish(self: *Controller, _: u64) Effect {
        if (!self.active or self.session.state != .complete) return .{};
        if (self.session.source == .draft and self.runner_state == .running) {
            self.runner_state = .stopping;
            return .{ .runner = .{ .stop = self.operation() }, .reset_text = true };
        }
        return .{};
    }
};

test "draft preparation is explicit resume rejects edits and stale completions" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    _ = try owner.choose(.{ .source = .draft }, 0);
    const effect = try owner.start(true, null, 0);
    try t.expect(effect.runner == .stop_then_prepare);
    try t.expectEqual(practice.State.paused, owner.session.state);
    const op = owner.operation();
    try t.expect(owner.prepared(op, true));
    try t.expectEqual(practice.State.paused, owner.session.state);
    try t.expect((try owner.resumeRun(10)).runner == .start);
    const running_op = owner.operation();
    _ = try owner.insertDraft(op, 1, "stale preparation output", 19);
    _ = try owner.insertDraft(running_op, 1, "a", 20);
    _ = try owner.insertDraft(running_op, 1, "duplicate", 21);
    try t.expectEqual(@as(usize, 1), owner.session.len);
    const stopped_effect = owner.observe(@splat(2), 30);
    try t.expect(stopped_effect.runner == .stop);
    try t.expectError(error.DraftChangedRestartPractice, owner.resumeRun(31));
    _ = try owner.start(true, null, 40);
    try t.expect(!owner.prepared(op, true));
    try t.expectEqual(@as(usize, 0), owner.session.len);
}

test "restart binds the prior runner and failed preparation retry gets a new ticket" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    _ = try owner.choose(.{ .source = .draft }, 0);
    const first = try owner.start(true, null, 0);
    const old = first.runner.stop_then_prepare.operation;
    try t.expect(first.runner.stop_then_prepare.previous == null);
    try t.expect(owner.prepared(old, false));
    const retry = try owner.resumeRun(1);
    try t.expectEqualDeep(old, retry.runner.stop_then_prepare.previous.?);
    try t.expect(!owner.prepared(old, true));
    try t.expect(owner.prepared(retry.runner.stop_then_prepare.operation, true));
    const replacement = try owner.start(false, @as(Digest, @splat(1)), 2);
    try t.expectEqualDeep(
        retry.runner.stop_then_prepare.operation,
        replacement.runner.stop_then_start.previous.?,
    );
    try t.expect(!owner.prepared(retry.runner.stop_then_prepare.operation, true));
}

test "OS text respects focus pause and paste remains unscored" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    _ = try owner.start(true, null, 0);
    _ = try owner.insertOs(false, "ignored", 1, false);
    try t.expectEqual(@as(usize, 0), owner.session.len);
    _ = try owner.insertOs(true, "a", 2, true);
    try t.expect(!owner.session.scored);
    _ = owner.pause(3);
    _ = try owner.insertOs(true, "ignored", 4, false);
    try t.expectEqual(@as(usize, 1), owner.session.len);
    _ = try owner.resumeRun(5);
    try t.expect(owner.acceptingOsText(true));
    try t.expectError(error.InvalidExerciseLevel, owner.choose(.{ .level = generator.sentence_counts.len }, 6));
}

test "rendered tutor actions reject changed project and replaced operation" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    const old = owner.action(.{ .start = true });
    _ = owner.observe(@splat(2), 0);
    try t.expectError(error.StalePracticeAction, owner.dispatch(old, null, 0));
    const current = owner.action(.{ .start = true });
    _ = try owner.dispatch(current, null, 1);
    try t.expectError(error.StalePracticeAction, owner.dispatch(current, null, 2));
}

fn sameOpening(session: *const practice.Session, text: []const u8) bool {
    if (session.reference_len < 12 or text.len < 12) return false;
    for (session.reference[0..12], text[0..12]) |cp, byte| if (cp != byte) return false;
    return true;
}

test "new runs stay fresh, Zig lessons rotate and completion is idempotent" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    _ = try owner.start(true, null, 0);
    const first = owner.session.reference;
    try t.expectEqual(@as(usize, 3), std.mem.count(u21, owner.session.reference[0..owner.session.reference_len], &.{'.'}));
    _ = try owner.start(false, null, 1);
    try t.expect(!std.mem.eql(u21, first[0..12], owner.session.reference[0..12]));
    _ = try owner.choose(.{ .mode = .zig, .level = 2 }, 2);
    _ = try owner.dispatch(owner.action(.new_exercise), null, 3);
    try t.expectEqual(@as(usize, 0), owner.config.level);
    try t.expectEqual(practice.lessons[0].len, owner.session.reference_len);
    try owner.session.load("a", .os);
    _ = try owner.insertOs(true, "a", 5, false);
    const first_effect = owner.finish(6);
    const repeated_effect = owner.finish(7);
    try t.expectEqualDeep(first_effect, repeated_effect);
    try t.expectError(error.InvalidExerciseLevel, (Config{ .mode = .zig, .level = practice.lessons.len }).validate());
    try t.expectError(error.InvalidExerciseLevel, (Config{ .level = generator.sentence_counts.len }).validate());
}
