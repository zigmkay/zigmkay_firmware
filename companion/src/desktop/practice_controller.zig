//! Adaptive typing tutor controller over `practice.Session`, `LayoutProfile`,
//! `LearningModel`, 6-stage generator, and lightweight persistence.
//! Supports strict `Tutor | Test keys` mode separation, zero-friction rounds,
//! inline rundowns, and explicit draft runner effects.
const std = @import("std");
const practice = @import("practice.zig");
const layout_profile = @import("practice_layout_profile.zig");
const model = @import("practice_model.zig");
const generator = @import("practice_generator.zig");
const storage = @import("practice_storage.zig");

pub const Digest = [32]u8;
pub const Mode = enum { tutor, test_keys };
pub const Stage = generator.Stage;
pub const GuidanceMode = storage.GuidanceMode;
pub const ErrorMode = practice.ErrorMode;

pub const Config = struct {
    mode: Mode = .tutor,
    stage: Stage = .home_row,
    source: practice.Source = .os,
    guidance: GuidanceMode = .guided,
    error_mode: ErrorMode = .stop_on_error,
    target_wpm: f32 = 35.0,
    daily_goal_minutes: u16 = 15,
    punct_group: usize = 0,
    stage5_filter: generator.Stage5Filter = .mixed,
    stage5_layer: ?usize = null,
    stage6_source: generator.Stage6Source = .english_prose,
    zig_lesson_index: usize = 0,
    weak_spot_active: bool = false,

    pub fn validate(self: Config) !void {
        if (self.target_wpm < 10.0 or self.target_wpm > 200.0) return error.InvalidTargetWpm;
        if (self.daily_goal_minutes < 1 or self.daily_goal_minutes > 240) return error.InvalidDailyGoal;
        if (self.stage == .free_text and self.stage6_source == .zig_code and
            self.zig_lesson_index >= practice.lessons.len) return error.InvalidExerciseLevel;
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

pub const Rundown = struct {
    wpm: f32 = 0.0,
    prev_wpm: ?f32 = null,
    wpm_delta: ?f32 = null,
    accuracy: f32 = 100.0,
    active_seconds: f32 = 0.0,
    focus_cp: ?u21 = null,
    focus_confidence: f32 = 0.0,
    forecast_rounds: ?u32 = null,
    newly_unlocked: ?u8 = null,
    weak_keys: [3]model.KeySummary = undefined,
    weak_key_len: usize = 0,
    weak_bigrams: [3]model.BigramStat = undefined,
    weak_bigram_len: usize = 0,
    stage: Stage = .home_row,
    weak_spot_drill: bool = false,
};

pub const TestKeysTelemetry = struct {
    last_text: [32]u8 = @splat(0),
    last_text_len: usize = 0,
    last_event: [64]u8 = @splat(0),
    last_event_len: usize = 0,
    scratchpad: [512]u8 = @splat(0),
    scratchpad_len: usize = 0,
    active_layers: u16 = 1,
    highest_layer: usize = 0,
    modifiers: u8 = 0,
    pressed_count: usize = 0,
    active_combo_cp: ?u21 = null,

    pub fn setLastText(self: *TestKeysTelemetry, text: []const u8) void {
        const kept = utf8Prefix(text, self.last_text.len);
        @memcpy(self.last_text[0..kept.len], kept);
        self.last_text_len = kept.len;
    }

    pub fn appendScratchpad(self: *TestKeysTelemetry, text: []const u8) void {
        if (text.len == 0) return;
        if (text.len >= self.scratchpad.len) {
            // A paste larger than the buffer replaces it with its own tail,
            // starting on a codepoint boundary.
            var start = text.len - self.scratchpad.len;
            while (start < text.len and (text[start] & 0xC0) == 0x80) : (start += 1) {}
            const tail = text[start..];
            @memcpy(self.scratchpad[0..tail.len], tail);
            self.scratchpad_len = tail.len;
            return;
        }
        // Keep the latest tail when the buffer reaches capacity, trimming on UTF-8 boundaries.
        if (self.scratchpad_len + text.len > self.scratchpad.len) {
            const overflow = (self.scratchpad_len + text.len) - self.scratchpad.len;
            var drop = @min(self.scratchpad_len, overflow + 64);
            while (drop < self.scratchpad_len and (self.scratchpad[drop] & 0xC0) == 0x80) : (drop += 1) {}
            const keep = self.scratchpad_len - drop;
            std.mem.copyForwards(u8, self.scratchpad[0..keep], self.scratchpad[drop..self.scratchpad_len]);
            self.scratchpad_len = keep;
        }
        const kept = utf8Prefix(text, self.scratchpad.len - self.scratchpad_len);
        @memcpy(self.scratchpad[self.scratchpad_len .. self.scratchpad_len + kept.len], kept);
        self.scratchpad_len += kept.len;
    }

    /// The longest prefix of `text` of at most `max` bytes that ends on a codepoint boundary.
    fn utf8Prefix(text: []const u8, max: usize) []const u8 {
        if (text.len <= max) return text;
        var n = max;
        while (n > 0 and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
        return text[0..n];
    }

    pub fn backspaceScratchpad(self: *TestKeysTelemetry) void {
        if (self.scratchpad_len == 0) return;
        var end = self.scratchpad_len - 1;
        while (end > 0 and (self.scratchpad[end] & 0xC0) == 0x80) : (end -= 1) {}
        self.scratchpad_len = end;
    }

    pub fn clearScratchpad(self: *TestKeysTelemetry) void {
        self.scratchpad_len = 0;
        self.last_text_len = 0;
    }

    pub fn scratchpadSlice(self: *const TestKeysTelemetry) []const u8 {
        return self.scratchpad[0..self.scratchpad_len];
    }

    pub fn setLastEvent(self: *TestKeysTelemetry, note: []const u8) void {
        const n = @min(note.len, self.last_event.len);
        @memcpy(self.last_event[0..n], note[0..n]);
        self.last_event_len = n;
    }

    pub fn textSlice(self: *const TestKeysTelemetry) []const u8 {
        return self.last_text[0..self.last_text_len];
    }

    pub fn eventSlice(self: *const TestKeysTelemetry) []const u8 {
        return self.last_event[0..self.last_event_len];
    }
};

pub const PendingRun = struct {
    utc_timestamp: u64,
    stage: u8,
    wpm: f32,
    accuracy: f32,
    active_seconds: f32,
    focus_key: ?u32 = null,
    unlocked_char: ?u32 = null,
    weak_keys: [3]u32 = @splat(0),
    weak_key_len: usize = 0,
    weak_bigrams: [3][2]u32 = @splat(.{ 0, 0 }),
    weak_bigram_len: usize = 0,
};

pub const Intent = union(enum) {
    choose: Config,
    set_mode: Mode,
    set_stage: Stage,
    start: bool,
    new_exercise,
    next_round,
    start_weak_spot,
    pause,
    resume_run,
    stop,
    set_target_wpm: f32,
    set_guidance: GuidanceMode,
    set_daily_goal: u16,
    set_source: practice.Source,
    set_stage5_filter: struct { filter: generator.Stage5Filter, layer: ?usize = null },
    set_stage6_source: struct { source: generator.Stage6Source, zig_lesson: usize = 0 },
    reset_progress,
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

    profile: layout_profile.LayoutProfile = .{},
    profile_bound: bool = false,
    learning: model.LearningModel = model.LearningModel.init(layout_profile.english_letter_frequency, 8, .{}),
    persisted: storage.ProfileState = .{},
    rundown: ?Rundown = null,
    last_round_wpm: ?f32 = null,
    round_recorded: bool = false,
    needs_persist: bool = false,
    pending_run: ?PendingRun = null,
    reset_requested: bool = false,
    utc_now_sec: u64 = 0,

    custom_text: [2048]u8 = @splat(0),
    custom_text_len: usize = 0,
    test_keys: TestKeysTelemetry = .{},

    pub fn init(snapshot: Digest) Controller {
        return .{ .current = snapshot };
    }

    pub fn operation(self: *const Controller) Operation {
        return .{ .generation = self.generation, .snapshot = self.captured };
    }

    pub fn action(self: *const Controller, intent: Intent) Action {
        return .{ .generation = self.generation, .snapshot = self.current, .intent = intent };
    }

    /// Binds a derived `LayoutProfile` and optional persisted `ProfileState`.
    /// Applies layout-diff partial reset when persisted key positions exist.
    /// Drops unsaved work of the bound profile before another profile is bound.
    pub fn discardPending(self: *Controller) void {
        self.pending_run = null;
        self.reset_requested = false;
        self.needs_persist = false;
    }

    pub fn bindProfile(
        self: *Controller,
        profile: layout_profile.LayoutProfile,
        loaded_state: ?storage.ProfileState,
    ) usize {
        self.profile = profile;
        self.profile_bound = true;

        if (loaded_state) |st| {
            // One sanitized target for the UI, the persisted copy and the model.
            const target_wpm: f32 = if (std.math.isFinite(st.target_wpm))
                std.math.clamp(st.target_wpm, 15.0, 140.0)
            else
                35.0;
            self.persisted = .{
                .schema_version = storage.schema_version,
                .language = st.language,
                .active_stage = st.active_stage,
                .target_wpm = target_wpm,
                .guidance_mode = st.guidance_mode,
                .error_mode = st.error_mode,
                .daily_goal_minutes = st.daily_goal_minutes,
                .daily_active_seconds = st.daily_active_seconds,
                .daily_utc_day = st.daily_utc_day,
                .streak_days = st.streak_days,
                .unlocked_count = st.unlocked_count,
                .rounds_since_unlock = st.rounds_since_unlock,
                .total_rounds = st.total_rounds,
            };
            self.config.stage = Stage.fromNumber(st.active_stage);
            self.config.target_wpm = target_wpm;
            self.config.guidance = st.guidance_mode;
            self.config.error_mode = switch (st.error_mode) {
                .stop_on_error => .stop_on_error,
                .flow_backspace => .flow_backspace,
            };
            self.config.daily_goal_minutes = std.math.clamp(st.daily_goal_minutes, 5, 120);
            const reset = storage.hydrateLearningModel(st, &self.profile, &self.learning);
            self.learning.config.target_wpm = target_wpm;
            return reset;
        } else {
            self.persisted = .{};
            const order = if (profile.unlock_len > 0) profile.unlockSlice() else layout_profile.english_letter_frequency;
            const initial = if (profile.zone1_len > 0) profile.zone1_len else @min(@as(usize, 8), order.len);
            self.learning = model.LearningModel.init(order, initial, .{
                .language = .en,
                .target_wpm = self.config.target_wpm,
            });
            return 0;
        }
    }

    pub fn setCustomText(self: *Controller, text: []const u8) void {
        const n = @min(text.len, self.custom_text.len);
        @memcpy(self.custom_text[0..n], text[0..n]);
        self.custom_text_len = n;
    }

    /// Ensures Tutor opens immediately with a ready round (zero-friction entry).
    pub fn ensureReady(self: *Controller, prepared_snapshot: ?Digest, now: u64) !Effect {
        if (self.config.mode == .test_keys) return .{};
        if (self.active and self.session.reference_len > 0) return .{};
        return self.start(true, prepared_snapshot, now);
    }

    /// Apply one rendered control after drawing.
    pub fn dispatch(self: *Controller, rendered: Action, prepared_snapshot: ?Digest, now: u64) !Effect {
        if (rendered.generation != self.generation or
            !std.mem.eql(u8, &rendered.snapshot, &self.current)) return error.StalePracticeAction;
        return switch (rendered.intent) {
            .choose => |config| try self.choose(config, now),
            .set_mode => |mode| try self.setMode(mode, prepared_snapshot, now),
            .set_stage => |stage| blk: {
                var next = self.config;
                next.mode = .tutor;
                next.stage = stage;
                next.weak_spot_active = false;
                _ = try self.choose(next, now);
                break :blk try self.start(true, prepared_snapshot, now);
            },
            .start => |fresh_exercise| try self.start(fresh_exercise, prepared_snapshot, now),
            .new_exercise => blk: {
                try self.config.validate();
                if (self.generation == std.math.maxInt(u64)) return error.OperationExhausted;
                if (self.config.stage == .free_text and self.config.stage6_source == .zig_code) {
                    self.config.zig_lesson_index = (self.config.zig_lesson_index + 1) % practice.lessons.len;
                }
                break :blk try self.start(true, prepared_snapshot, now);
            },
            .next_round => try self.start(true, prepared_snapshot, now),
            .start_weak_spot => blk: {
                var next = self.config;
                next.mode = .tutor;
                next.stage = .free_text;
                next.stage6_source = .weak_spot;
                next.weak_spot_active = true;
                _ = try self.choose(next, now);
                break :blk try self.start(true, prepared_snapshot, now);
            },
            .pause => self.pause(now),
            .resume_run => try self.resumeRun(now),
            .stop => self.stop(now),
            .set_target_wpm => |wpm| blk: {
                const clamped = std.math.clamp(wpm, 15.0, 140.0);
                self.config.target_wpm = clamped;
                self.learning.config.target_wpm = clamped;
                self.persisted.target_wpm = clamped;
                self.needs_persist = true;
                break :blk .{};
            },
            .set_guidance => |g| blk: {
                self.config.guidance = g;
                self.persisted.guidance_mode = g;
                self.needs_persist = true;
                break :blk .{};
            },
            .set_daily_goal => |mins| blk: {
                const clamped = std.math.clamp(mins, 5, 120);
                self.config.daily_goal_minutes = clamped;
                self.persisted.daily_goal_minutes = clamped;
                self.needs_persist = true;
                break :blk .{};
            },
            .set_source => |src| blk: {
                var next = self.config;
                next.source = src;
                const eff = try self.choose(next, now);
                if (self.config.mode == .tutor) {
                    break :blk try self.start(true, prepared_snapshot, now);
                }
                break :blk eff;
            },
            .set_stage5_filter => |sf| blk: {
                var next = self.config;
                next.stage = .layers_combos;
                next.stage5_filter = sf.filter;
                next.stage5_layer = sf.layer;
                next.weak_spot_active = false;
                _ = try self.choose(next, now);
                break :blk try self.start(true, prepared_snapshot, now);
            },
            .set_stage6_source => |s6| blk: {
                var next = self.config;
                next.stage = .free_text;
                next.stage6_source = s6.source;
                next.zig_lesson_index = s6.zig_lesson % practice.lessons.len;
                next.weak_spot_active = (s6.source == .weak_spot);
                _ = try self.choose(next, now);
                break :blk try self.start(true, prepared_snapshot, now);
            },
            .reset_progress => blk: {
                self.resetProgress();
                break :blk try self.start(true, prepared_snapshot, now);
            },
        };
    }

    pub fn setMode(self: *Controller, mode: Mode, prepared_snapshot: ?Digest, now: u64) !Effect {
        if (self.config.mode == mode) return .{};
        if (mode == .test_keys) {
            const effect = self.pause(now);
            self.config.mode = .test_keys;
            self.rundown = null;
            return effect;
        }
        self.config.mode = .tutor;
        if (!self.active or self.session.reference_len == 0) {
            return self.start(true, prepared_snapshot, now);
        }
        return .{};
    }

    pub fn resetProgress(self: *Controller) void {
        const order = if (self.profile_bound and self.profile.unlock_len > 0)
            self.profile.unlockSlice()
        else
            layout_profile.english_letter_frequency;
        const initial = if (self.profile_bound and self.profile.zone1_len > 0)
            self.profile.zone1_len
        else
            @min(@as(usize, 8), order.len);
        self.learning = model.LearningModel.init(order, initial, .{
            .language = .en,
            .target_wpm = self.config.target_wpm,
        });
        self.persisted.daily_active_seconds = 0;
        self.persisted.streak_days = 0;
        self.persisted.total_rounds = 0;
        self.persisted.rounds_since_unlock = 0;
        self.persisted.unlocked_count = @intCast(initial);
        self.last_round_wpm = null;
        self.rundown = null;
        self.pending_run = null;
        self.reset_requested = true;
        self.needs_persist = true;
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
        self.learning.config.target_wpm = config.target_wpm;
        self.persisted.active_stage = config.stage.number();
        self.persisted.target_wpm = config.target_wpm;
        self.persisted.guidance_mode = config.guidance;
        self.persisted.daily_goal_minutes = config.daily_goal_minutes;
        if (config.mode == .tutor) {
            self.active = false;
        }
        return effect;
    }

    /// Generates and loads a fresh round for the active stage.
    pub fn start(self: *Controller, _: bool, prepared_snapshot: ?Digest, now: u64) !Effect {
        try self.config.validate();
        if (self.generation == std.math.maxInt(u64)) return error.OperationExhausted;
        if (self.config.mode == .test_keys) return .{};
        const previous: ?Operation = if (self.generation == 0) null else self.operation();
        var buffer: [8192]u8 = undefined;
        self.seed +%= 0x9e3779b97f4a7c15;
        var text = try self.reference(&buffer);
        if (self.config.stage != .free_text and self.session.reference_len > 0) {
            var retries: usize = 0;
            while (sameOpening(&self.session, text) and retries < 4) : (retries += 1) {
                self.seed +%= 0x9e3779b97f4a7c15;
                text = try self.reference(&buffer);
            }
        }
        try self.session.loadWithMode(text, self.config.source, self.config.error_mode);
        self.generation += 1;
        self.captured = self.current;
        self.captured_config = self.config;
        self.active = true;
        self.failure = null;
        self.last_sequence = null;
        self.rundown = null;
        self.round_recorded = false;
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
        const profile_ptr: ?*const layout_profile.LayoutProfile = if (self.profile_bound) &self.profile else null;
        return generator.generateDrill(buffer, .{
            .language = self.learning.config.language,
            .stage = self.config.stage,
            .seed = self.seed,
            .word_count = if (self.config.weak_spot_active) generator.default_weak_spot_words else generator.default_round_words,
            .unlocked_mask = self.learning.unlockedMask(),
            .focus_cp = self.learning.focus_cp,
            .profile = profile_ptr,
            .learning = &self.learning,
            // Rotate through the punctuation and digit groups round by round.
            .punct_group = self.config.punct_group +% self.learning.total_rounds,
            .stage5_filter = self.config.stage5_filter,
            .stage5_layer = self.config.stage5_layer,
            .stage6_source = self.config.stage6_source,
            .zig_lesson_index = self.config.zig_lesson_index,
            .custom_text = self.custom_text[0..self.custom_text_len],
        });
    }

    pub fn prepared(self: *Controller, op: Operation, success: bool) bool {
        if (!self.accepts(op) or self.runner_state != .preparing) return false;
        self.runner_state = if (success) .prepared else .failed;
        self.failure = if (success) null else error.DraftPreparationFailed;
        return true;
    }

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
        if (self.config.mode == .test_keys) return false;
        return focused and self.active and self.session.source == .os and
            (self.session.state == .ready or self.session.state == .running);
    }

    /// Handles Enter/Space in rundown or normal OS text input in Tutor mode.
    pub fn insertOs(self: *Controller, focused: bool, bytes: []const u8, now: u64, paste: bool) !Effect {
        if (self.config.mode == .test_keys) {
            if (focused and bytes.len > 0) {
                self.test_keys.setLastText(bytes);
                self.test_keys.appendScratchpad(bytes);
            }
            return .{};
        }
        if (!self.acceptingOsText(focused)) return .{};
        try self.session.insert(bytes, now, paste);
        return self.finish(now);
    }

    pub fn insertDraft(self: *Controller, op: Operation, sequence: u64, bytes: []const u8, now: u64) !Effect {
        if (self.config.mode == .test_keys) {
            if (bytes.len > 0) {
                self.test_keys.setLastText(bytes);
                self.test_keys.appendScratchpad(bytes);
            }
            return .{};
        }
        if (!self.accepts(op) or self.runner_state != .running or self.session.source != .draft) return .{};
        if (self.last_sequence) |last| if (sequence <= last) return .{};
        try self.session.insert(bytes, now, false);
        self.last_sequence = sequence;
        return self.finish(now);
    }

    /// Handles keyboard shortcuts in Tutor mode: Enter/Space in rundown starts next round.
    pub fn handleRundownContinue(self: *Controller, prepared_snapshot: ?Digest, now: u64) !?Effect {
        if (self.config.mode != .tutor or self.rundown == null) return null;
        return try self.start(true, prepared_snapshot, now);
    }

    pub fn finish(self: *Controller, now: u64) Effect {
        if (self.config.mode == .test_keys) return .{};
        if (!self.active or self.session.state != .complete) return .{};

        if (!self.round_recorded and self.session.scored) {
            self.recordCompletedRound(now);
        }

        if (self.session.source == .draft and self.runner_state == .running) {
            self.runner_state = .stopping;
            return .{ .runner = .{ .stop = self.operation() }, .reset_text = true };
        }
        return .{};
    }

    fn recordCompletedRound(self: *Controller, now: u64) void {
        self.round_recorded = true;
        const round_wpm: f32 = @floatCast(self.session.wpm(now));
        const round_acc: f32 = @floatCast(self.session.accuracy());
        const active_sec: f32 = @as(f32, @floatFromInt(self.session.duration(now))) / 1_000_000.0;

        const outcome = self.learning.completeRound(&self.session.collector);
        if (self.utc_now_sec > 0) {
            storage.recordDailyPractice(&self.persisted, self.utc_now_sec, @intFromFloat(@max(1.0, @round(active_sec))));
        }

        var weak_keys: [3]model.KeySummary = undefined;
        const wk_slice = self.learning.weakestKeys(&weak_keys);
        var weak_bigrams: [3]model.BigramStat = undefined;
        const wb_slice = self.learning.slowestBigrams(2, &weak_bigrams);

        const prev_wpm = self.last_round_wpm;
        const delta = if (prev_wpm) |p| round_wpm - p else null;
        self.last_round_wpm = round_wpm;

        var rd: Rundown = .{
            .wpm = round_wpm,
            .prev_wpm = prev_wpm,
            .wpm_delta = delta,
            .accuracy = round_acc,
            .active_seconds = active_sec,
            .focus_cp = outcome.focus_cp,
            .focus_confidence = outcome.focus_confidence,
            .forecast_rounds = outcome.forecast_rounds,
            .newly_unlocked = outcome.newly_unlocked,
            .weak_key_len = wk_slice.len,
            .weak_bigram_len = wb_slice.len,
            .stage = self.captured_config.stage,
            .weak_spot_drill = self.captured_config.weak_spot_active,
        };
        @memcpy(rd.weak_keys[0..wk_slice.len], wk_slice);
        @memcpy(rd.weak_bigrams[0..wb_slice.len], wb_slice);
        self.rundown = rd;

        var pr: PendingRun = .{
            .utc_timestamp = self.utc_now_sec,
            .stage = self.captured_config.stage.number(),
            .wpm = round_wpm,
            .accuracy = round_acc,
            .active_seconds = active_sec,
            .focus_key = if (outcome.focus_cp) |f| @as(u32, f) else null,
            .unlocked_char = if (outcome.newly_unlocked) |u| @as(u32, u) else null,
            .weak_key_len = wk_slice.len,
            .weak_bigram_len = wb_slice.len,
        };
        for (wk_slice, 0..) |wk, i| pr.weak_keys[i] = wk.cp;
        for (wb_slice, 0..) |wb, i| pr.weak_bigrams[i] = .{ wb.prev, wb.cur };
        self.pending_run = pr;
        self.needs_persist = true;
    }

    /// Flushes any pending `runs.jsonl` entry and atomic `state.zon` save (or reset).
    pub fn persistPending(
        self: *Controller,
        gpa: std.mem.Allocator,
        io: std.Io,
        base_dir: std.Io.Dir,
        board_id: []const u8,
        host_layout: []const u8,
    ) !void {
        if (!self.needs_persist or !self.profile_bound) return;

        if (self.reset_requested) {
            try storage.resetProfile(io, base_dir, self.profile.profile_hash);
            self.reset_requested = false;
            self.pending_run = null;
            self.needs_persist = false;
            return;
        }

        // A failed history append must not keep the learning state from saving;
        // the record stays pending and the error is returned after the save.
        const appended = if (self.pending_run) |pr|
            storage.appendRun(gpa, io, base_dir, self.profile.profile_hash, .{
                .utc_timestamp = pr.utc_timestamp,
                .stage = pr.stage,
                .wpm = pr.wpm,
                .accuracy = pr.accuracy,
                .active_seconds = pr.active_seconds,
                .focus_key = pr.focus_key,
                .unlocked_char = pr.unlocked_char,
                .top_weak_keys = pr.weak_keys[0..pr.weak_key_len],
                .top_weak_bigrams = pr.weak_bigrams[0..pr.weak_bigram_len],
            })
        else {};
        if (appended) |_| self.pending_run = null else |_| {}

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        self.persisted.active_stage = self.config.stage.number();
        self.persisted.target_wpm = self.config.target_wpm;
        self.persisted.guidance_mode = self.config.guidance;
        self.persisted.error_mode = switch (self.config.error_mode) {
            .stop_on_error => .stop_on_error,
            .flow_backspace => .flow_backspace,
        };
        self.persisted.daily_goal_minutes = self.config.daily_goal_minutes;

        const state = try storage.buildProfileState(
            arena.allocator(),
            self.persisted,
            &self.learning,
            &self.profile,
            board_id,
            host_layout,
        );
        try storage.saveState(gpa, io, base_dir, self.profile.profile_hash, state);
        try appended;
        self.needs_persist = false;
    }

    pub fn shouldShowKeyboardGuidance(self: *const Controller, now_us: u64) bool {
        if (self.config.mode == .test_keys) return false;
        if (!self.active or self.session.state == .complete) return false;
        return switch (self.config.guidance) {
            .guided => true,
            .on_hesitation => self.session.shouldShowHesitationHint(now_us),
            .free => false,
        };
    }
};

fn sameOpening(session: *const practice.Session, text: []const u8) bool {
    if (session.reference_len < 12 or text.len < 12) return false;
    for (session.reference[0..12], text[0..12]) |cp, byte| if (cp != byte) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Controller tests
// ---------------------------------------------------------------------------

test "round completion updates model, unlocks key, persists state.zon + runs.jsonl, and advances on Enter/Space" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    var owner = Controller.init(@splat(1));
    var profile: layout_profile.LayoutProfile = .{
        .unlock_len = 3,
        .zone1_len = 2,
        .profile_hash = @splat(0x44),
    };
    profile.unlock_order[0] = 'a';
    profile.unlock_order[1] = 's';
    profile.unlock_order[2] = 'd';
    _ = owner.bindProfile(profile, null);
    owner.utc_now_sec = 20_000 * 86_400 + 100;

    // Two fast clean rounds over "asas..." (22 samples each at 200ms) -> unlocks 'd' on round 2.
    const drill = "asasasasasasasasasasasasasasasasasasasasasas";
    var now: u64 = 1_000_000;
    for (0..2) |round_idx| {
        _ = try owner.start(true, null, now);
        try owner.session.loadWithMode(drill, .os, .stop_on_error);
        for (drill) |ch| {
            now += 200_000;
            const buf = [_]u8{ch};
            _ = try owner.insertOs(true, &buf, now, false);
        }
        try t.expectEqual(practice.State.complete, owner.session.state);
        try t.expect(owner.rundown != null);
        if (round_idx == 1) {
            try t.expectEqual(@as(?u8, 'd'), owner.rundown.?.newly_unlocked);
        }
        try owner.persistPending(t.allocator, t.io, tmp.dir, "test_board", "en-US");
        try t.expect(!owner.needs_persist);

        // Press Enter/Space in rundown -> immediately starts next round
        const next_eff = try owner.handleRundownContinue(null, now + 500_000);
        try t.expect(next_eff != null);
        try t.expect(owner.rundown == null);
        try t.expectEqual(practice.State.ready, owner.session.state);
    }

    var loaded_state = try storage.loadState(t.allocator, t.io, tmp.dir, profile.profile_hash);
    defer loaded_state.deinit();
    try t.expect(loaded_state.existed);
    try t.expectEqual(@as(u16, 3), loaded_state.state.unlocked_count);
    try t.expectEqual(@as(u32, 2), loaded_state.state.total_rounds);

    var loaded_runs = try storage.loadRuns(t.allocator, t.io, tmp.dir, profile.profile_hash);
    defer loaded_runs.deinit();
    try t.expectEqual(@as(usize, 2), loaded_runs.runs.len);
    try t.expectEqual(@as(?u32, 'd'), loaded_runs.runs[1].unlocked_char);
}

test "Tutor <-> Test keys mode switch pauses safely and never pollutes stats or persistence" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    _ = try owner.ensureReady(null, 0);
    try owner.session.load("ab", .os);
    _ = try owner.insertOs(true, "a", 1_000_000, false);
    try t.expectEqual(practice.State.running, owner.session.state);

    // Switch to Test keys -> pauses tutor cleanly, ignores scoring, records telemetry text only
    _ = try owner.dispatch(owner.action(.{ .set_mode = .test_keys }), null, 1_200_000);
    try t.expectEqual(Mode.test_keys, owner.config.mode);
    try t.expectEqual(practice.State.paused, owner.session.state);
    try t.expect(!owner.acceptingOsText(true));
    _ = try owner.insertOs(true, "hello", 1_500_000, false);
    try t.expectEqual(@as(usize, 1), owner.session.len);
    try t.expectEqualStrings("hello", owner.test_keys.textSlice());
    try t.expect(!owner.needs_persist);

    // Switch back to Tutor -> still paused cleanly, no corrupted samples
    _ = try owner.dispatch(owner.action(.{ .set_mode = .tutor }), null, 2_000_000);
    try t.expectEqual(Mode.tutor, owner.config.mode);
    try t.expectEqual(practice.State.paused, owner.session.state);
}

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
    try owner.session.load("ab", .draft);
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
    try owner.session.load("ab", .os);
    _ = try owner.insertOs(false, "ignored", 1, false);
    try t.expectEqual(@as(usize, 0), owner.session.len);
    _ = try owner.insertOs(true, "a", 2, true);
    try t.expect(!owner.session.scored);
    _ = owner.pause(3);
    _ = try owner.insertOs(true, "ignored", 4, false);
    try t.expectEqual(@as(usize, 1), owner.session.len);
    _ = try owner.resumeRun(5);
    try t.expect(owner.acceptingOsText(true));
    try t.expectError(error.InvalidTargetWpm, owner.choose(.{ .target_wpm = 5.0 }, 6));
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

test "Test layout buffers keep whole codepoints when multibyte text overflows them" {
    const t = std.testing;
    var telemetry: TestKeysTelemetry = .{};
    const euro = "€"; // three bytes
    var paste: [171 * euro.len]u8 = undefined;
    for (0..171) |i| @memcpy(paste[i * euro.len ..][0..euro.len], euro);

    telemetry.appendScratchpad(&paste);
    try t.expect(std.unicode.utf8ValidateSlice(telemetry.scratchpadSlice()));
    try t.expectEqual(@as(usize, 170 * euro.len), telemetry.scratchpadSlice().len);

    telemetry.clearScratchpad();
    telemetry.appendScratchpad("ab");
    telemetry.appendScratchpad(paste[0 .. 170 * euro.len]);
    try t.expect(std.unicode.utf8ValidateSlice(telemetry.scratchpadSlice()));

    telemetry.setLastText(&paste);
    try t.expect(std.unicode.utf8ValidateSlice(telemetry.textSlice()));
    try t.expectEqual(@as(usize, 10 * euro.len), telemetry.textSlice().len);
}

test "discardPending drops a confirmed reset and round record before a profile switch" {
    var owner: Controller = .init(@splat(0));
    owner.reset_requested = true;
    owner.needs_persist = true;
    owner.pending_run = .{ .utc_timestamp = 1, .stage = 1, .wpm = 30, .accuracy = 95, .active_seconds = 20 };
    owner.discardPending();
    try std.testing.expect(!owner.reset_requested);
    try std.testing.expect(!owner.needs_persist);
    try std.testing.expect(owner.pending_run == null);
}
