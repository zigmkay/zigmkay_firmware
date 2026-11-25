//! Adaptive typing tutor controller over `practice.Session`, `LayoutProfile`,
//! `LearningModel`, 6-stage generator, and lightweight persistence.
//! Supports strict `Tutor | Test keys` mode separation and an endless flow:
//! a finished lesson is counted and the next one is ready in the same frame.
const std = @import("std");
const practice = @import("practice.zig");
const layout_profile = @import("practice_layout_profile.zig");
const model = @import("practice_model.zig");
const generator = @import("practice_generator.zig");
const storage = @import("practice_storage.zig");
const key_progress = @import("practice_key_progress.zig");
const word_list = @import("practice_words.zig");
const letter_order = @import("practice_letter_order.zig");
const tap_hold = @import("practice_tap_hold.zig");
const scratchpad = @import("practice_scratchpad.zig");

pub const Digest = [32]u8;
pub const Mode = enum { tutor, test_keys };
pub const Stage = generator.Stage;
pub const GuidanceMode = storage.GuidanceMode;
pub const ErrorMode = practice.ErrorMode;
pub const LetterOrder = storage.LetterOrder;
/// Letters unlocked from the start in the word-forming order.
pub const first_letters: usize = letter_order.start_letters;

pub const Config = struct {
    mode: Mode = .tutor,
    stage: Stage = .home_row,
    guidance: GuidanceMode = .guided,
    error_mode: ErrorMode = .forgive,
    letter_order: LetterOrder = .word_forming,
    target_wpm: f32 = 20.0,
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

/// What a finished lesson changed; shown beside the next lesson, never as a stop.
pub const LessonSummary = struct {
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
    /// Keys of this round that turned green or still are not, most telling first.
    changes: [max_round_changes]KeyChange = undefined,
    change_len: usize = 0,
    /// The round was typed as a slow round; its speed did not count.
    slow_round: bool = false,
    /// The letter pair a weak-spot lesson was built around.
    weak_spot: ?[2]u8 = null,
    /// Every key typed in the lesson, for the keyboard heatmap.
    keys: [max_lesson_keys]LessonKey = undefined,
    key_len: usize = 0,
    /// Tap/hold decisions of the lesson; all zero without a Zigmkay keyboard.
    tap_holds: LessonTapHolds = .{},
    /// The keys whose hold or tap came by mistake in the lesson.
    tap_hold_keys: [max_lesson_tap_hold_keys]LessonTapHoldKey = undefined,
    tap_hold_key_len: usize = 0,

    pub fn changeSlice(self: *const LessonSummary) []const KeyChange {
        return self.changes[0..self.change_len];
    }

    pub fn keySlice(self: *const LessonSummary) []const LessonKey {
        return self.keys[0..self.key_len];
    }

    pub fn tapHoldKeySlice(self: *const LessonSummary) []const LessonTapHoldKey {
        return self.tap_hold_keys[0..self.tap_hold_key_len];
    }

    /// The lesson's accidental decisions of the key that types `cp` on tap.
    pub fn tapHoldKey(self: *const LessonSummary, cp: u21) ?LessonTapHoldKey {
        for (self.tapHoldKeySlice()) |key| if (key.cp == cp) return key;
        return null;
    }
};

pub const max_round_changes: usize = 8;
pub const max_lesson_keys: usize = 40;
pub const max_lesson_tap_hold_keys: usize = 8;

/// One key's accidental tap/hold decisions in a lesson.
pub const LessonTapHoldKey = struct {
    /// The character the key types on tap.
    cp: u21,
    accidental_holds: u16 = 0,
    accidental_taps: u16 = 0,
    /// Accidental holds a roll into the next key decided (permissive hold).
    rolls: u16 = 0,
    /// Accidental holds the tapping term decided: the key was held too long.
    term: u16 = 0,

    /// Why the holds came, when that is clear: a roll or the term.
    pub fn holdReason(self: LessonTapHoldKey) ?model.TapHoldReason {
        if (self.rolls == 0 and self.term == 0) return null;
        return if (self.rolls >= self.term) .permissive_hold else .term_elapsed;
    }

    fn add(self: *LessonTapHoldKey, sample: model.TapHoldSample) void {
        switch (sample.class) {
            .accidental_hold => {
                self.accidental_holds +|= 1;
                switch (sample.reason) {
                    .permissive_hold => self.rolls +|= 1,
                    .term_elapsed => self.term +|= 1,
                    else => {},
                }
            },
            .accidental_tap => self.accidental_taps +|= 1,
            .wanted_tap, .wanted_hold, .near_hold => {},
        }
    }
};

/// The lesson notice about a key whose hold or tap kept coming by mistake.
pub const TapHoldNotice = struct {
    cp: u21,
    count: u16,
    /// The key held when its character was wanted; otherwise it tapped when
    /// its hold was wanted.
    hold: bool,
    reason: ?model.TapHoldReason = null,
};

/// A key gets the tap/hold notice at most once in this many lessons.
pub const tap_hold_notice_every: u32 = 5;
/// The confidence strip marks a key with this many accidental holds (or
/// taps) in its window.
pub const tap_hold_marker_at: u8 = 2;
/// A tapping term suggestion needs this many decisions of the key.
pub const tap_hold_suggest_after: u32 = 50;

/// A longer tapping term for a key that is held past it by mistake: 15 %
/// more, at least 20 ms, rounded up to 10 ms.
pub fn suggestedTerm(term_ms: u16) u16 {
    const more = @max(@as(u32, 20), (@as(u32, term_ms) * 15 + 99) / 100);
    const raw = @as(u32, term_ms) + more;
    return @intCast(@min(@as(u32, 10_000), (raw + 9) / 10 * 10));
}

/// Whether a key's window asks for a longer tapping term: enough decisions,
/// and the accidental holds come from holding past the term.
pub fn suggestsTerm(summary: model.TapHoldSummary) bool {
    return summary.total >= tap_hold_suggest_after and summary.accidental_holds > 0 and
        summary.tapping_term_ms > 0 and summary.dominant_reason == .term_elapsed;
}

/// A tap/hold decision of Test layout, kept only for display.
pub const TestTapHold = struct {
    decision: tap_hold.Decision,
    /// When it arrived, for the keyboard marks that fade out.
    at_us: u64,
};

/// Whether the connected keyboard reports tap/hold decisions.
pub const TapHoldSupport = enum {
    /// No verified keyboard yet.
    unknown,
    /// Its firmware predates the decision report.
    old_firmware,
    reporting,
};

/// Classified tap/hold decisions of one lesson.
pub const LessonTapHolds = struct {
    decisions: u16 = 0,
    accidental_holds: u16 = 0,
    accidental_taps: u16 = 0,
    near_holds: u16 = 0,

    fn count(self: *LessonTapHolds, class: model.TapHoldClass) void {
        self.decisions +|= 1;
        switch (class) {
            .accidental_hold => self.accidental_holds +|= 1,
            .accidental_tap => self.accidental_taps +|= 1,
            .near_hold => self.near_holds +|= 1,
            .wanted_tap, .wanted_hold => {},
        }
    }
};

/// A hold the tapping term decided, which a retro tap of the same key may
/// turn into a late tap.
const TermHold = struct { key_index: usize, cp: u21, class: model.TapHoldClass };

/// One key of a finished lesson: how often it was pressed, missed, and how
/// long it took (median of its clean presses, 0 without one).
pub const LessonKey = struct {
    cp: u21,
    presses: u32,
    misses: u32,
    ms: f32,
};

/// Something a finished lesson achieved, shown as a short notice that does
/// not stop typing.
pub const LessonEvent = union(enum) {
    new_letter: u8,
    green: u21,
    daily_goal,
    stage: Stage,
    tap_hold: TapHoldNotice,
};

pub const max_lesson_events: usize = 4;
/// How long a lesson notice stays visible.
pub const notice_us: u64 = 3_000_000;

/// One key of a finished round, before and after the round was counted.
pub const KeyChange = struct {
    cp: u21,
    before: model.KeyStat,
    after: model.KeyStat,
    presses: u32,
    misses: u32,
    newly_green: bool,
};

fn isUnlockedLetter(lm: *const model.LearningModel, cp: u21) bool {
    return cp >= 'a' and cp <= 'z' and lm.isUnlocked(@intCast(cp));
}

/// The next lower target preset, if any.
pub fn lowerPreset(target: f32) ?f32 {
    var i = target_presets.len;
    while (i > 0) : (i -= 1) {
        if (target_presets[i - 1] < target - 0.5) return target_presets[i - 1];
    }
    return null;
}

/// Target speeds offered in Settings and by the stuck help, slowest first.
pub const target_presets = [_]f32{ 15, 20, 25, 35, 45 };

/// Rounds a letter may go without progress before the Tutor offers help.
pub const stuck_after_rounds: u8 = 4;

pub const StuckReason = enum { hits, speed };

pub const StuckHelp = struct {
    cp: u21,
    reason: StuckReason,
    progress: key_progress.KeyProgress,
    rounds: u8,
    /// The next lower target preset, when speed is what holds the key back.
    lower_target: ?f32,
};

pub const TestKeysTelemetry = struct {
    /// The last key or text, such as "a" or "⌥⇧←".
    last_text: [48]u8 = @splat(0),
    last_text_len: usize = 0,
    /// The field command the last key ran, such as "select word left".
    last_action: []const u8 = "",
    last_event: [64]u8 = @splat(0),
    last_event_len: usize = 0,
    /// The text field; it keeps its text, cursor and history across modes.
    field: scratchpad.Editor = .{},
    active_layers: u16 = 1,
    highest_layer: usize = 0,
    modifiers: u8 = 0,
    pressed_count: usize = 0,
    active_combo_cp: ?u21 = null,
    /// The latest tap/hold decisions, oldest first. Test layout is unscored:
    /// they are shown and never counted.
    tap_holds: [max_test_tap_holds]TestTapHold = undefined,
    tap_hold_len: usize = 0,

    pub const max_test_tap_holds = 4;

    /// Keeps `decision` as the newest one; combos have no tap or hold.
    pub fn addTapHold(self: *TestKeysTelemetry, decision: tap_hold.Decision, at_us: u64) void {
        if (decision.combo) return;
        if (self.tap_hold_len == max_test_tap_holds) {
            std.mem.copyForwards(TestTapHold, self.tap_holds[0 .. max_test_tap_holds - 1], self.tap_holds[1..]);
            self.tap_hold_len -= 1;
        }
        self.tap_holds[self.tap_hold_len] = .{ .decision = decision, .at_us = at_us };
        self.tap_hold_len += 1;
    }

    pub fn tapHoldSlice(self: *const TestKeysTelemetry) []const TestTapHold {
        return self.tap_holds[0..self.tap_hold_len];
    }

    /// Shows typed `text` as the last key.
    pub fn setLastText(self: *TestKeysTelemetry, text: []const u8) void {
        const kept = utf8Prefix(text, self.last_text.len);
        @memcpy(self.last_text[0..kept.len], kept);
        self.last_text_len = kept.len;
        self.last_action = "";
    }

    /// Types `text` into the field and shows it as the last key.
    pub fn typeText(self: *TestKeysTelemetry, text: []const u8) void {
        if (text.len == 0) return;
        self.setLastText(text);
        _ = self.field.insert(text);
    }

    /// Shows `combo` as the last key, with the editor action it ran, if any.
    pub fn setLastKey(self: *TestKeysTelemetry, combo: []const u8, action: []const u8) void {
        self.setLastText(combo);
        self.last_action = action;
    }

    /// The longest prefix of `text` of at most `max` bytes that ends on a codepoint boundary.
    fn utf8Prefix(text: []const u8, max: usize) []const u8 {
        if (text.len <= max) return text;
        var n = max;
        while (n > 0 and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
        return text[0..n];
    }

    /// Empties the field (undo brings it back) and the last key.
    pub fn clearField(self: *TestKeysTelemetry) void {
        self.field.clear();
        self.last_text_len = 0;
        self.last_action = "";
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
    weak_spot: ?[2]u32 = null,
    newly_green: [max_round_changes]u32 = @splat(0),
    newly_green_len: usize = 0,
    tap_holds: LessonTapHolds = .{},
    top_accidental_hold: ?[2]u32 = null,
    top_accidental_tap: ?[2]u32 = null,
};

/// Every this many lessons of Stages 1 and 2 one is built around the
/// slowest letter pair, without a stop or a button.
pub const weak_spot_every: u8 = 5;

pub const max_key_reset: usize = model.max_tracked_keys;

/// Characters to start over, for the profile they were chosen in.
pub const KeyReset = struct {
    profile_hash: Digest,
    cps: [max_key_reset]u21 = undefined,
    len: usize = 0,

    pub fn slice(self: *const KeyReset) []const u21 {
        return self.cps[0..self.len];
    }

    pub fn add(self: *KeyReset, cp: u21) void {
        if (self.len >= max_key_reset or std.mem.indexOfScalar(u21, self.slice(), cp) != null) return;
        self.cps[self.len] = cp;
        self.len += 1;
    }
};

pub const Intent = union(enum) {
    choose: Config,
    set_mode: Mode,
    set_stage: Stage,
    start,
    new_exercise,
    start_weak_spot,
    pause,
    resume_run,
    stop,
    set_target_wpm: f32,
    set_guidance: GuidanceMode,
    /// Changes how typos are handled; the lesson in progress keeps its mode.
    set_error_mode: ErrorMode,
    /// Changes which letters come first; unlocked letters stay unlocked.
    set_letter_order: LetterOrder,
    set_daily_goal: u16,
    set_stage5_filter: struct { filter: generator.Stage5Filter, layer: ?usize = null },
    set_stage6_source: struct { source: generator.Stage6Source, zig_lesson: usize = 0 },
    reset_progress,
    /// Keeps the statistics of the moved characters of this profile.
    keep_moved_keys: Digest,
    reset_keys: KeyReset,
    /// Resets the listed moved characters and keeps the others.
    resolve_layout_changes: KeyReset,
    /// Stops offering stuck help for this letter until it makes progress.
    dismiss_stuck: u21,
    /// Starts a round around this letter; a slow round does not count speed.
    practise_key: struct { cp: u21, slow: bool },
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
    failure: ?anyerror = null,

    profile: layout_profile.LayoutProfile = .{},
    profile_bound: bool = false,
    learning: model.LearningModel = model.LearningModel.init(layout_profile.english_letter_frequency, 8, .{}),
    persisted: storage.ProfileState = .{},
    /// The last finished lesson of this session.
    last_lesson: ?LessonSummary = null,
    /// Notices of the last finished lesson and when they appeared.
    events: [max_lesson_events]LessonEvent = undefined,
    event_len: usize = 0,
    events_at_us: u64 = 0,
    last_round_wpm: ?f32 = null,
    round_recorded: bool = false,
    needs_persist: bool = false,
    pending_run: ?PendingRun = null,
    reset_requested: bool = false,
    utc_now_sec: u64 = 0,
    /// Practised characters the bound layout moved; derived, never saved.
    review: [model.max_tracked_keys]u21 = undefined,
    review_len: usize = 0,
    /// Keyboards the profile was shown on, for the before/now comparison.
    boards: model.BoardSnapshots = .{},
    /// `model.boardHash` of the current keyboard; null until `adoptBoard`.
    board_hash: ?u64 = null,
    /// Rounds in a row without progress, per position in the unlock order.
    stall_rounds: [26]u8 = @splat(0),
    stall_best: [26]f32 = @splat(0),
    stall_dismissed: u32 = 0,
    /// The next round, and the current one, are slow rounds.
    slow_round_next: bool = false,
    slow_round: bool = false,
    /// Lessons finished since the last weak-spot lesson.
    lessons_since_weak_spot: u8 = 0,
    /// The letter pair the current lesson is built around, if any.
    lesson_bigram: ?[2]u8 = null,
    /// Tap/hold decisions of the current lesson.
    lesson_tap_holds: LessonTapHolds = .{},
    last_term_hold: ?TermHold = null,
    /// Text positions the latest tap decisions typed, newest last.
    tap_claims: [4]usize = undefined,
    tap_claim_len: usize = 0,
    /// Keys with accidental decisions in the current lesson.
    lesson_tap_hold_keys: [max_lesson_tap_hold_keys]LessonTapHoldKey = undefined,
    lesson_tap_hold_key_len: usize = 0,
    /// When each key last got the tap/hold notice, in `total_rounds`; this
    /// session only.
    tap_hold_noticed: [max_lesson_tap_hold_keys]struct { cp: u21, round: u32 } = undefined,
    tap_hold_noticed_len: usize = 0,

    custom_text: [2048]u8 = @splat(0),
    custom_text_len: usize = 0,
    test_keys: TestKeysTelemetry = .{},

    pub fn init(snapshot: Digest) Controller {
        return .{ .current = snapshot };
    }

    pub fn action(self: *const Controller, intent: Intent) Action {
        return .{ .generation = self.generation, .snapshot = self.current, .intent = intent };
    }

    /// Drops unsaved work of the bound profile before another profile is bound.
    pub fn discardPending(self: *Controller) void {
        self.review_len = 0;
        self.clearStalls();
        self.pending_run = null;
        self.reset_requested = false;
        self.needs_persist = false;
    }

    /// Binds a derived `LayoutProfile` and optional persisted `ProfileState`.
    /// Nothing is reset when keys moved; returns how many practised
    /// characters sit at a position their statistics were not made at.
    pub fn bindProfile(
        self: *Controller,
        profile: layout_profile.LayoutProfile,
        loaded_state: ?storage.ProfileState,
    ) usize {
        self.clearStalls();
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
                .letter_order = st.letter_order,
                .rounds_since_unlock = st.rounds_since_unlock,
                .total_rounds = st.total_rounds,
            };
            self.config.stage = Stage.fromNumber(st.active_stage);
            self.config.target_wpm = target_wpm;
            self.config.guidance = st.guidance_mode;
            self.config.error_mode = switch (st.error_mode) {
                // Before schema 3 nobody could choose; the old default
                // becomes the forgiving one.
                .stop_on_error => if (st.schema_version < 3) .forgive else .stop_on_error,
                .flow_backspace => .flow_backspace,
                .forgive => .forgive,
            };
            self.persisted.error_mode = storageErrorMode(self.config.error_mode);
            self.config.daily_goal_minutes = std.math.clamp(st.daily_goal_minutes, 5, 120);
            self.config.letter_order = st.letter_order;
            var order_buf: [26]u8 = undefined;
            const order = self.letterOrder(&order_buf);
            storage.hydrateLearningModel(st, &self.profile, order, self.firstCount(order.len), &self.learning);
            storage.hydrateBoards(st, &self.boards);
            self.learning.config.target_wpm = target_wpm;
        } else {
            self.persisted = .{ .letter_order = self.config.letter_order };
            var order_buf: [26]u8 = undefined;
            const order = self.letterOrder(&order_buf);
            self.learning = model.LearningModel.init(order, self.firstCount(order.len), .{
                .language = .en,
                .target_wpm = self.config.target_wpm,
            });
            self.boards = .{};
        }
        // The keyboard is named by `adoptBoard`.
        self.board_hash = null;
        self.adoptCurrent();
        return self.review_len;
    }

    /// The keyboard a profile is shown on, for the before/now comparison.
    pub const BoardInput = struct {
        id: []const u8,
        labels: practice.Labels,
    };

    /// Practised characters that the bound layout moved and the user has not
    /// answered for yet.
    pub fn reviewSlice(self: *const Controller) []const u21 {
        return self.review[0..self.review_len];
    }

    /// The bound layout's positions, with the keys of the current keyboard.
    pub fn currentPositions(
        self: *const Controller,
        buf: *[layout_profile.max_routes]model.KnownPosition,
    ) []model.KnownPosition {
        const positions = self.profile.keyPositionSlice();
        for (positions, buf[0..positions.len]) |pos, *dst| {
            dst.* = .{
                .pos = pos,
                .seen = if (self.board_hash) |board| seenFor(&self.profile, pos.cp, board) else null,
            };
        }
        return buf[0..positions.len];
    }

    fn seenFor(profile: *const layout_profile.LayoutProfile, cp: u21, board: u64) ?model.SeenKey {
        const route = profile.routeFor(cp) orelse return null;
        return .{
            .board = board,
            .key_index = @intCast(route.key_index),
            .combo_key_index = if (route.combo_key_index) |k| @intCast(k) else null,
            .layer_key_index = if (route.layer != 0)
                (if (route.layer_activator) |k| @as(u16, @intCast(k)) else null)
            else
                null,
        };
    }

    pub fn refreshReview(self: *Controller) void {
        var buf: [layout_profile.max_routes]model.KnownPosition = undefined;
        const current = self.currentPositions(&buf);
        self.review_len = self.learning.unconfirmedMoves(current, &self.review).len;
    }

    fn adoptCurrent(self: *Controller) void {
        var buf: [layout_profile.max_routes]model.KnownPosition = undefined;
        const current = self.currentPositions(&buf);
        if (self.learning.adoptPositions(current)) self.needs_persist = true;
        self.refreshReview();
    }

    fn hasPractice(self: *const Controller) bool {
        for (self.learning.stats[0..self.learning.stat_len]) |st| {
            if (st.samples > 0 or st.acc_initialized) return true;
        }
        return false;
    }

    /// Records the keyboard the bound profile is shown on: its labels for the
    /// layers the layout uses, and the keys each position sits on.
    pub fn adoptBoard(self: *Controller, board: BoardInput) void {
        const key_count = @min(board.labels.key_count, layout_profile.max_keys);
        const snapshot = self.boards.use(board.id, key_count);
        var layers: u16 = 1;
        for (self.profile.routeSlice()) |route| {
            if (route.layer < 16) layers |= @as(u16, 1) << @intCast(route.layer);
        }
        var snapshot_changed = false;
        var row: [layout_profile.max_keys]u21 = undefined;
        for (0..@min(board.labels.layer_count, 16)) |layer| {
            if (layers & (@as(u16, 1) << @intCast(layer)) == 0) continue;
            snapshotLayer(board.labels, layer, row[0..key_count]);
            if (snapshot.setLayer(@intCast(layer), row[0..key_count])) snapshot_changed = true;
        }
        self.board_hash = snapshot.hash;
        self.adoptCurrent();
        if (snapshot_changed and self.hasPractice()) self.needs_persist = true;
    }

    /// Follows an edited layout of the bound profile. Statistics stay; moved
    /// practised characters wait for the user's answer in `review`.
    pub fn adoptLayout(self: *Controller, profile: layout_profile.LayoutProfile, board: ?BoardInput) void {
        self.profile = profile;
        if (profile.unlock_len > 0) self.followLetterOrder();
        if (board) |b| self.adoptBoard(b) else self.adoptCurrent();
    }

    pub fn setCustomText(self: *Controller, text: []const u8) void {
        const n = @min(text.len, self.custom_text.len);
        @memcpy(self.custom_text[0..n], text[0..n]);
        self.custom_text_len = n;
    }

    /// Ensures Tutor opens immediately with a ready round (zero-friction entry).
    pub fn ensureReady(self: *Controller) !void {
        if (self.config.mode == .test_keys) return;
        if (self.active and self.session.reference_len > 0) return;
        return self.start();
    }

    /// Apply one rendered control after drawing.
    pub fn dispatch(self: *Controller, rendered: Action, now: u64) !void {
        if (rendered.generation != self.generation or
            !std.mem.eql(u8, &rendered.snapshot, &self.current)) return error.StalePracticeAction;
        return switch (rendered.intent) {
            .choose => |config| try self.choose(config, now),
            .set_mode => |mode| try self.setMode(mode, now),
            .set_stage => |stage| blk: {
                var next = self.config;
                next.mode = .tutor;
                next.stage = stage;
                next.weak_spot_active = false;
                _ = try self.choose(next, now);
                break :blk try self.start();
            },
            .start => try self.start(),
            .new_exercise => blk: {
                try self.config.validate();
                if (self.generation == std.math.maxInt(u64)) return error.OperationExhausted;
                if (self.config.stage == .free_text and self.config.stage6_source == .zig_code) {
                    self.config.zig_lesson_index = (self.config.zig_lesson_index + 1) % practice.lessons.len;
                }
                break :blk try self.start();
            },
            .start_weak_spot => blk: {
                var next = self.config;
                next.mode = .tutor;
                next.stage = .free_text;
                next.stage6_source = .weak_spot;
                next.weak_spot_active = true;
                _ = try self.choose(next, now);
                break :blk try self.start();
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
                // Progress is measured against the new target from here on.
                self.clearStalls();
                break :blk;
            },
            .set_guidance => |g| blk: {
                self.config.guidance = g;
                self.persisted.guidance_mode = g;
                self.needs_persist = true;
                break :blk;
            },
            .set_letter_order => |order| blk: {
                if (self.config.letter_order == order) break :blk;
                self.config.letter_order = order;
                self.persisted.letter_order = order;
                self.followLetterOrder();
                self.clearStalls();
                self.needs_persist = true;
                break :blk try self.start();
            },
            .set_error_mode => |mode| blk: {
                self.config.error_mode = mode;
                self.persisted.error_mode = storageErrorMode(mode);
                self.needs_persist = true;
                break :blk;
            },
            .set_daily_goal => |mins| blk: {
                const clamped = std.math.clamp(mins, 5, 120);
                self.config.daily_goal_minutes = clamped;
                self.persisted.daily_goal_minutes = clamped;
                self.needs_persist = true;
                break :blk;
            },
            .set_stage5_filter => |sf| blk: {
                var next = self.config;
                next.stage = .layers_combos;
                next.stage5_filter = sf.filter;
                next.stage5_layer = sf.layer;
                next.weak_spot_active = false;
                _ = try self.choose(next, now);
                break :blk try self.start();
            },
            .set_stage6_source => |s6| blk: {
                var next = self.config;
                next.stage = .free_text;
                next.stage6_source = s6.source;
                next.zig_lesson_index = s6.zig_lesson % practice.lessons.len;
                next.weak_spot_active = (s6.source == .weak_spot);
                _ = try self.choose(next, now);
                break :blk try self.start();
            },
            .reset_progress => blk: {
                self.resetProgress();
                break :blk try self.start();
            },
            .keep_moved_keys => |hash| try self.keepMovedKeys(hash),
            .reset_keys => |request| try self.resetKeys(request),
            .resolve_layout_changes => |request| try self.resolveLayoutChanges(request),
            .dismiss_stuck => |cp| self.dismissStuck(cp),
            .practise_key => |p| try self.practiseKey(p.cp, p.slow),
        };
    }

    pub fn setMode(self: *Controller, mode: Mode, now: u64) !void {
        if (self.config.mode == mode) return;
        if (mode == .test_keys) {
            self.pause(now);
            self.config.mode = .test_keys;
            return;
        }
        self.config.mode = .tutor;
        if (!self.active or self.session.reference_len == 0) {
            return self.start();
        }
        return;
    }

    fn checkProfile(self: *const Controller, profile_hash: Digest) !void {
        if (!self.profile_bound or !std.mem.eql(u8, &profile_hash, &self.profile.profile_hash))
            return error.StalePracticeAction;
    }

    /// Keeps the statistics of every moved character at its new position.
    pub fn keepMovedKeys(self: *Controller, profile_hash: Digest) !void {
        try self.checkProfile(profile_hash);
        var buf: [layout_profile.max_routes]model.KnownPosition = undefined;
        self.learning.confirmPositions(self.reviewSlice(), self.currentPositions(&buf));
        self.refreshReview();
        self.needs_persist = true;
    }

    /// Starts the chosen characters over; a letter takes its other case along.
    /// The round in progress is replaced so its samples do not land in the
    /// fresh statistics.
    pub fn resetKeys(self: *Controller, request: KeyReset) !void {
        try self.checkProfile(request.profile_hash);
        const expanded = expandLetterCase(request.slice());
        var buf: [layout_profile.max_routes]model.KnownPosition = undefined;
        self.learning.resetKeys(expanded.slice(), self.currentPositions(&buf));
        self.refreshReview();
        self.needs_persist = true;
        if (expanded.len > 0) try self.start();
    }

    /// Answers the layout-change question: `request` starts over and every
    /// other moved character keeps its statistics.
    pub fn resolveLayoutChanges(self: *Controller, request: KeyReset) !void {
        try self.checkProfile(request.profile_hash);
        const expanded = expandLetterCase(request.slice());
        var keep: KeyReset = .{ .profile_hash = request.profile_hash };
        for (self.reviewSlice()) |cp| {
            if (std.mem.indexOfScalar(u21, expanded.slice(), cp) == null) keep.add(cp);
        }
        var buf: [layout_profile.max_routes]model.KnownPosition = undefined;
        self.learning.confirmPositions(keep.slice(), self.currentPositions(&buf));
        try self.resetKeys(request);
    }

    /// Whether a key counts as learned for the strip and the unlock: it was
    /// mastered once or is fully confident now.
    pub fn isGreen(self: *const Controller, st: model.KeyStat) bool {
        return st.green(self.learning.config.target_wpm);
    }

    const RoundChanges = struct { items: [max_round_changes]KeyChange = undefined, len: usize = 0 };

    /// Keys of the finished round worth naming: those that just turned green
    /// first, then unlocked letters that still are not green.
    fn roundChanges(self: *const Controller, before: []const model.KeyStat) RoundChanges {
        var out: RoundChanges = .{};
        const collector = &self.session.collector;
        for (0..2) |pass| {
            for (collector.buckets[0..before.len], before) |b, old| {
                if (out.len == max_round_changes) return out;
                if (b.cp == ' ') continue;
                const after = self.learning.getStat(b.cp) orelse continue;
                const newly_green = !self.isGreen(old) and self.isGreen(after);
                const still_open = !self.isGreen(after) and isUnlockedLetter(&self.learning, b.cp);
                if ((pass == 0 and !newly_green) or (pass == 1 and !still_open)) continue;
                out.items[out.len] = .{
                    .cp = b.cp,
                    .before = old,
                    .after = after,
                    .presses = b.total_positions,
                    .misses = b.total_positions - b.first_try_hits,
                    .newly_green = newly_green,
                };
                out.len += 1;
            }
        }
        return out;
    }

    fn clearStalls(self: *Controller) void {
        self.stall_rounds = @splat(0);
        self.stall_best = @splat(0);
        self.stall_dismissed = 0;
        self.slow_round_next = false;
    }

    /// Counts, per unlocked letter typed this round, how many rounds in a row
    /// its confidence did not rise.
    fn trackStalls(self: *Controller) void {
        const lm = &self.learning;
        const collector = &self.session.collector;
        for (lm.unlock_order[0..@min(lm.unlocked_count, 26)], 0..) |ch, i| {
            const typed = for (collector.buckets[0..collector.bucket_len]) |b| {
                if (b.cp == ch) break true;
            } else false;
            if (!typed) continue;
            const st = lm.getStat(ch) orelse continue;
            const conf = st.confidence(lm.config.target_wpm);
            const bit = @as(u32, 1) << @intCast(i);
            if (self.isGreen(st) or conf > self.stall_best[i] + 0.02) {
                self.stall_best[i] = @max(self.stall_best[i], conf);
                self.stall_rounds[i] = 0;
                self.stall_dismissed &= ~bit;
            } else {
                self.stall_rounds[i] +|= 1;
            }
        }
    }

    /// The letter that has gone longest without progress, once it reached
    /// `stuck_after_rounds`, with the reason that holds it back.
    pub fn stuckHelp(self: *const Controller) ?StuckHelp {
        if (self.config.mode != .tutor) return null;
        const lm = &self.learning;
        var pick: ?usize = null;
        for (0..@min(lm.unlocked_count, 26)) |i| {
            if (self.stall_rounds[i] < stuck_after_rounds) continue;
            if (self.stall_dismissed & (@as(u32, 1) << @intCast(i)) != 0) continue;
            if (pick == null or self.stall_rounds[i] > self.stall_rounds[pick.?]) pick = i;
        }
        const i = pick orelse return null;
        const ch = lm.unlock_order[i];
        const st = lm.getStat(ch) orelse return null;
        if (self.isGreen(st)) return null;
        const kp = key_progress.of(st, lm.config.target_wpm);
        const reason: StuckReason = switch (kp.blocker) {
            .hits => .hits,
            .speed => .speed,
            .presses, .none => return null,
        };
        return .{
            .cp = ch,
            .reason = reason,
            .progress = kp,
            .rounds = self.stall_rounds[i],
            .lower_target = if (reason == .speed) lowerPreset(self.config.target_wpm) else null,
        };
    }

    fn dismissStuck(self: *Controller, cp: u21) void {
        const lm = &self.learning;
        for (lm.unlock_order[0..@min(lm.unlock_len, 26)], 0..) |ch, i| {
            if (ch == cp) self.stall_dismissed |= @as(u32, 1) << @intCast(i);
        }
    }

    /// Starts a round built around `cp`; a slow round leaves its latencies out.
    fn practiseKey(self: *Controller, cp: u21, slow: bool) !void {
        self.dismissStuck(cp);
        if (isUnlockedLetter(&self.learning, cp)) self.learning.focus_cp = cp;
        self.slow_round_next = slow;
        try self.start();
    }

    /// The letter the next lesson is built around. Stage 1 stays on the first
    /// letters, so it focuses on the weakest of them when the learning focus
    /// lies beyond.
    pub fn lessonFocus(self: *const Controller) ?u21 {
        const focus = self.learning.focus_cp;
        if (self.config.stage != .home_row) return focus;
        const first = self.learning.firstLetters();
        if (focus) |cp| if (cp <= 'z' and std.mem.indexOfScalar(u8, first, @intCast(cp)) != null) return cp;
        return self.learning.focusAmong(first) orelse focus;
    }

    /// The letters of the bound layout in the order they unlock.
    pub fn letterOrder(self: *const Controller, buf: *[26]u8) []const u8 {
        return orderFor(if (self.profile_bound) &self.profile else null, self.config.letter_order, buf);
    }

    pub fn firstCount(self: *const Controller, len: usize) usize {
        return firstCountFor(if (self.profile_bound) &self.profile else null, self.config.letter_order, len);
    }

    /// Follows the letter order of the bound layout and setting; letters
    /// unlocked or mastered before stay unlocked.
    fn followLetterOrder(self: *Controller) void {
        var order_buf: [26]u8 = undefined;
        const order = self.letterOrder(&order_buf);
        self.learning.adoptOrder(order, self.firstCount(order.len));
    }

    pub fn resetProgress(self: *Controller) void {
        var order_buf: [26]u8 = undefined;
        const order = self.letterOrder(&order_buf);
        const initial = self.firstCount(order.len);
        self.learning = model.LearningModel.init(order, initial, .{
            .language = .en,
            .target_wpm = self.config.target_wpm,
        });
        self.persisted.daily_active_seconds = 0;
        self.persisted.streak_days = 0;
        self.persisted.total_rounds = 0;
        self.persisted.rounds_since_unlock = 0;
        self.persisted.unlocked_count = @intCast(initial);
        self.adoptCurrent();
        self.last_round_wpm = null;
        self.clearStalls();
        self.last_lesson = null;
        self.event_len = 0;
        self.pending_run = null;
        self.reset_requested = true;
        self.needs_persist = true;
    }

    fn fresh(self: *const Controller) bool {
        return std.mem.eql(u8, &self.current, &self.captured);
    }

    pub fn choose(self: *Controller, config: Config, now: u64) !void {
        try config.validate();
        if (std.meta.eql(config, self.config)) return;
        self.pause(now);
        self.config = config;
        self.learning.config.target_wpm = config.target_wpm;
        self.persisted.active_stage = config.stage.number();
        self.persisted.target_wpm = config.target_wpm;
        self.persisted.guidance_mode = config.guidance;
        self.persisted.daily_goal_minutes = config.daily_goal_minutes;
        if (config.mode == .tutor) {
            self.active = false;
        }
    }

    /// Generates and loads a fresh round for the active stage.
    pub fn start(self: *Controller) !void {
        try self.config.validate();
        if (self.generation == std.math.maxInt(u64)) return error.OperationExhausted;
        if (self.config.mode == .test_keys) return;
        var buffer: [8192]u8 = undefined;
        self.seed +%= 0x9e3779b97f4a7c15;
        self.lesson_bigram = self.weakSpotPair();
        var text = try self.reference(&buffer);
        if (self.config.stage != .free_text and self.session.reference_len > 0) {
            var retries: usize = 0;
            while (sameOpening(&self.session, text) and retries < 4) : (retries += 1) {
                self.seed +%= 0x9e3779b97f4a7c15;
                text = try self.reference(&buffer);
            }
        }
        try self.session.loadWithMode(text, self.config.error_mode);
        self.generation += 1;
        self.captured = self.current;
        self.captured_config = self.config;
        self.active = true;
        self.slow_round = self.slow_round_next;
        self.slow_round_next = false;
        self.failure = null;
        self.round_recorded = false;
        self.lesson_tap_holds = .{};
        self.lesson_tap_hold_key_len = 0;
        self.last_term_hold = null;
        self.tap_claim_len = 0;
        return;
    }

    /// The slowest letter pair of the unlocked letters when the next lesson is
    /// due to be a weak-spot lesson.
    fn weakSpotPair(self: *const Controller) ?[2]u8 {
        const stage = self.config.stage;
        if (stage != .home_row and stage != .all_letters) return null;
        if (self.config.weak_spot_active or self.slow_round_next) return null;
        if (self.lessons_since_weak_spot + 1 < weak_spot_every) return null;
        var slowest: [8]model.BigramStat = undefined;
        for (self.learning.slowestBigrams(3, &slowest)) |bg| {
            if (bg.prev > 'z' or bg.cur > 'z' or bg.prev < 'a' or bg.cur < 'a') continue;
            const pair = [2]u8{ @intCast(bg.prev), @intCast(bg.cur) };
            if (!self.learning.isUnlocked(pair[0]) or !self.learning.isUnlocked(pair[1])) continue;
            if (stage == .home_row and (std.mem.indexOfScalar(u8, self.learning.firstLetters(), pair[0]) == null or
                std.mem.indexOfScalar(u8, self.learning.firstLetters(), pair[1]) == null)) continue;
            return pair;
        }
        return null;
    }

    fn reference(self: *const Controller, buffer: []u8) ![]const u8 {
        const profile_ptr: ?*const layout_profile.LayoutProfile = if (self.profile_bound) &self.profile else null;
        return generator.generateDrill(buffer, .{
            .language = self.learning.config.language,
            .stage = self.config.stage,
            .seed = self.seed,
            .word_count = if (self.config.weak_spot_active) generator.default_weak_spot_words else generator.default_round_words,
            .bigram = self.lesson_bigram,
            .unlocked_mask = self.learning.unlockedMask(),
            .focus_cp = self.lessonFocus(),
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

    pub fn resumeRun(self: *Controller, now: u64) !void {
        if (self.failure) |failure| if (failure == error.PracticeContextChanged) return error.PracticeContextChanged;
        if (!self.active or self.session.state != .paused) return error.ExerciseNotPaused;
        self.session.resumeRun(now);
        return;
    }

    pub fn pause(self: *Controller, now: u64) void {
        if (!self.active) return;
        self.session.pause(now);
        return;
    }

    pub fn stop(self: *Controller, now: u64) void {
        self.pause(now);
        self.active = false;
    }

    /// Follows the project that practice runs on.
    pub fn observe(self: *Controller, snapshot: Digest) void {
        self.current = snapshot;
    }

    pub fn acceptingOsText(self: *const Controller, focused: bool) bool {
        if (self.config.mode == .test_keys) return false;
        return focused and self.active and
            (self.session.state == .ready or self.session.state == .running);
    }

    /// Whether tap/hold decisions of the keyboard count for the lesson. The
    /// caller also makes sure they come from the verified keyboard the
    /// lesson's layout profile was derived from.
    pub fn acceptingTapHold(self: *const Controller) bool {
        return self.config.mode == .tutor and self.active and self.profile_bound and
            (self.session.state == .ready or self.session.state == .running);
    }

    /// Classifies a tap/hold decision against the text at the cursor and
    /// records it for the character the key types on tap. Scoring of the
    /// typed text is untouched. Returns the class, or null when the decision
    /// was ignored.
    pub fn observeTapHold(self: *Controller, decision: tap_hold.Decision) ?model.TapHoldClass {
        if (!self.acceptingTapHold()) return null;
        const term_hold = self.last_term_hold;
        self.last_term_hold = null;
        if (decision.outcome == .retro_tap) if (term_hold) |held| if (held.key_index == decision.key_index) {
            // The hold the term decided typed the character after all.
            if (held.class != .accidental_hold or !self.learning.amendRetroTap(held.cp)) return null;
            self.lesson_tap_holds.accidental_holds -|= 1;
            self.lesson_tap_holds.near_holds +|= 1;
            for (self.lesson_tap_hold_keys[0..self.lesson_tap_hold_key_len]) |*key| if (key.cp == held.cp) {
                key.accidental_holds -|= 1;
                key.term -|= 1;
            };
            return .near_hold;
        };
        const classified = tap_hold.classify(&self.profile, &self.session, decision, self.tap_claims[0..self.tap_claim_len]) orelse return null;
        if (classified.typed_at) |index| self.claimTap(index);
        self.learning.recordTapHold(classified.cp, classified.sample);
        self.lesson_tap_holds.count(classified.sample.class);
        if (classified.sample.class == .accidental_hold or classified.sample.class == .accidental_tap) {
            if (self.lessonTapHoldKey(classified.cp)) |key| key.add(classified.sample);
        }
        if (decision.outcome == .hold and decision.reason == .term_elapsed) {
            self.last_term_hold = .{ .key_index = decision.key_index, .cp = classified.cp, .class = classified.sample.class };
        }
        return classified.sample.class;
    }

    fn lessonTapHoldKey(self: *Controller, cp: u21) ?*LessonTapHoldKey {
        const keys = self.lesson_tap_hold_keys[0..self.lesson_tap_hold_key_len];
        for (keys) |*key| if (key.cp == cp) return key;
        if (self.lesson_tap_hold_key_len == max_lesson_tap_hold_keys) return null;
        self.lesson_tap_hold_keys[self.lesson_tap_hold_key_len] = .{ .cp = cp };
        self.lesson_tap_hold_key_len += 1;
        return &self.lesson_tap_hold_keys[self.lesson_tap_hold_key_len - 1];
    }

    /// Keeps a Test layout decision for display. Test layout is unscored:
    /// nothing reaches the statistics. Returns whether it was kept.
    pub fn observeTestTapHold(self: *Controller, decision: tap_hold.Decision, now_us: u64) bool {
        if (self.config.mode != .test_keys or decision.combo) return false;
        self.test_keys.addTapHold(decision, now_us);
        return true;
    }

    /// The lesson's key whose accidental decisions deserve a notice, if any:
    /// most holds first, then most taps, skipping keys noticed in the last
    /// `tap_hold_notice_every` lessons.
    fn tapHoldNotice(self: *const Controller, keys: []const LessonTapHoldKey, round: u32) ?TapHoldNotice {
        var best: ?TapHoldNotice = null;
        for (keys) |key| {
            if (self.noticedRecently(key.cp, round)) continue;
            const candidate: TapHoldNotice = if (key.accidental_holds > 0)
                .{ .cp = key.cp, .count = key.accidental_holds, .hold = true, .reason = key.holdReason() }
            else if (key.accidental_taps > 0)
                .{ .cp = key.cp, .count = key.accidental_taps, .hold = false, .reason = .released_within_term }
            else
                continue;
            if (best) |b| {
                if (b.hold and !candidate.hold) continue;
                if (b.hold == candidate.hold and b.count >= candidate.count) continue;
            }
            best = candidate;
        }
        return best;
    }

    fn noticedRecently(self: *const Controller, cp: u21, round: u32) bool {
        for (self.tap_hold_noticed[0..self.tap_hold_noticed_len]) |entry| {
            if (entry.cp == cp) return round -| entry.round < tap_hold_notice_every;
        }
        return false;
    }

    fn rememberNotice(self: *Controller, cp: u21, round: u32) void {
        for (self.tap_hold_noticed[0..self.tap_hold_noticed_len]) |*entry| if (entry.cp == cp) {
            entry.round = round;
            return;
        };
        if (self.tap_hold_noticed_len == self.tap_hold_noticed.len) {
            // Forget the oldest notice.
            var oldest: usize = 0;
            for (self.tap_hold_noticed, 0..) |entry, i| {
                if (entry.round < self.tap_hold_noticed[oldest].round) oldest = i;
            }
            self.tap_hold_noticed[oldest] = .{ .cp = cp, .round = round };
            return;
        }
        self.tap_hold_noticed[self.tap_hold_noticed_len] = .{ .cp = cp, .round = round };
        self.tap_hold_noticed_len += 1;
    }

    fn claimTap(self: *Controller, index: usize) void {
        if (self.tap_claim_len == self.tap_claims.len) {
            std.mem.copyForwards(usize, self.tap_claims[0 .. self.tap_claims.len - 1], self.tap_claims[1..]);
            self.tap_claim_len -= 1;
        }
        self.tap_claims[self.tap_claim_len] = index;
        self.tap_claim_len += 1;
    }

    /// The tap/hold window of the key that types `cp` on tap.
    pub fn tapHoldSummary(self: *const Controller, cp: u21) ?model.TapHoldSummary {
        return self.learning.tapHoldSummary(cp);
    }

    /// The keys with the most accidental holds in their window, most first.
    pub fn mostAccidentalHolds(self: *const Controller, out: []model.TapHoldSummary) []model.TapHoldSummary {
        return self.learning.mostAccidentalHolds(out);
    }

    /// Handles OS text input in Tutor mode.
    pub fn insertOs(self: *Controller, focused: bool, bytes: []const u8, now: u64, paste: bool) !void {
        if (self.config.mode == .test_keys) {
            if (focused) self.test_keys.typeText(bytes);
            return;
        }
        if (!self.acceptingOsText(focused)) return;
        try self.session.insert(bytes, now, paste);
        return self.finish(now);
    }

    /// Counts a completed lesson and loads the next one right away; there is
    /// no result screen to confirm.
    pub fn finish(self: *Controller, now: u64) !void {
        if (self.config.mode == .test_keys) return;
        if (!self.active or self.session.state != .complete) return;

        self.event_len = 0;
        if (!self.round_recorded and self.session.scored) {
            self.recordCompletedRound(now);
        }
        // The first letters lead into the rest of the alphabet without a stop.
        if (self.captured_config.stage == .home_row and self.config.stage == .home_row and !self.config.weak_spot_active) {
            if (self.last_lesson) |lesson| if (lesson.newly_unlocked != null and self.round_recorded) {
                self.config.stage = .all_letters;
                self.persisted.active_stage = Stage.all_letters.number();
                self.addEvent(.{ .stage = .all_letters });
            };
        }
        if (self.event_len > 0) self.events_at_us = now;
        if (self.config.stage == .free_text and self.config.stage6_source == .zig_code) {
            self.config.zig_lesson_index = (self.config.zig_lesson_index + 1) % practice.lessons.len;
        }
        try self.start();
    }

    fn addEvent(self: *Controller, event: LessonEvent) void {
        if (self.event_len >= max_lesson_events) return;
        self.events[self.event_len] = event;
        self.event_len += 1;
    }

    /// Puts `event` in front of the others; the last one makes room.
    fn addEventFirst(self: *Controller, event: LessonEvent) void {
        const kept = @min(self.event_len, max_lesson_events - 1);
        std.mem.copyBackwards(LessonEvent, self.events[1 .. kept + 1], self.events[0..kept]);
        self.events[0] = event;
        self.event_len = kept + 1;
    }

    /// Notices of the last lesson that are still visible at `now`.
    pub fn visibleEvents(self: *const Controller, now: u64) []const LessonEvent {
        if (now -| self.events_at_us >= notice_us) return &.{};
        return self.events[0..self.event_len];
    }

    fn recordCompletedRound(self: *Controller, now: u64) void {
        self.round_recorded = true;
        const round_wpm: f32 = @floatCast(self.session.wpm(now));
        const round_acc: f32 = @floatCast(self.session.accuracy());
        const active_sec: f32 = @as(f32, @floatFromInt(self.session.duration(now))) / 1_000_000.0;

        const collector = &self.session.collector;
        var before: [model.max_round_keys]model.KeyStat = undefined;
        for (collector.buckets[0..collector.bucket_len], 0..) |b, i| {
            before[i] = self.learning.getStat(b.cp) orelse .{ .cp = b.cp };
        }
        // A slow round trains clean presses; its latencies would only drag
        // the speed estimate down.
        if (self.slow_round) {
            for (collector.buckets[0..collector.bucket_len]) |*b| b.dt_len = 0;
            collector.bigram_len = 0;
        }

        const outcome = self.learning.completeRound(collector);
        const changes = self.roundChanges(before[0..collector.bucket_len]);
        self.trackStalls();
        if (self.utc_now_sec > 0) {
            const goal_s = @as(u32, self.config.daily_goal_minutes) * 60;
            const before_s = storage.dailyView(self.persisted, self.utc_now_sec).active_seconds;
            storage.recordDailyPractice(&self.persisted, self.utc_now_sec, @intFromFloat(@max(1.0, @round(active_sec))));
            const after_s = storage.dailyView(self.persisted, self.utc_now_sec).active_seconds;
            if (before_s < goal_s and after_s >= goal_s) self.addEvent(.daily_goal);
        }

        var weak_keys: [3]model.KeySummary = undefined;
        const wk_slice = self.learning.weakestKeys(&weak_keys);
        var weak_bigrams: [3]model.BigramStat = undefined;
        const wb_slice = self.learning.slowestBigrams(2, &weak_bigrams);

        const prev_wpm = self.last_round_wpm;
        const delta = if (prev_wpm) |p| round_wpm - p else null;
        self.last_round_wpm = round_wpm;

        var rd: LessonSummary = .{
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
        rd.changes = changes.items;
        rd.change_len = changes.len;
        rd.slow_round = self.slow_round;
        rd.weak_spot = self.lesson_bigram;
        rd.tap_holds = self.lesson_tap_holds;
        const th_keys = self.lesson_tap_hold_keys[0..self.lesson_tap_hold_key_len];
        @memcpy(rd.tap_hold_keys[0..th_keys.len], th_keys);
        rd.tap_hold_key_len = th_keys.len;
        if (self.lesson_bigram != null) {
            self.lessons_since_weak_spot = 0;
        } else {
            self.lessons_since_weak_spot +|= 1;
        }
        for (collector.buckets[0..collector.bucket_len]) |b| {
            if (b.cp == ' ' or rd.key_len >= max_lesson_keys) continue;
            rd.keys[rd.key_len] = .{
                .cp = b.cp,
                .presses = b.total_positions,
                .misses = b.total_positions - b.first_try_hits,
                .ms = if (b.dt_len > 0) model.medianF32(b.dt_ms[0..b.dt_len]) else 0,
            };
            rd.key_len += 1;
        }
        self.last_lesson = rd;
        if (outcome.newly_unlocked) |ch| self.addEvent(.{ .new_letter = ch });
        for (changes.items[0..changes.len]) |change| {
            if (change.newly_green) self.addEvent(.{ .green = change.cp });
        }
        if (self.tapHoldNotice(th_keys, self.learning.total_rounds)) |notice| {
            self.addEventFirst(.{ .tap_hold = notice });
            self.rememberNotice(notice.cp, self.learning.total_rounds);
        }

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
        if (self.lesson_bigram) |pair| pr.weak_spot = .{ pair[0], pair[1] };
        pr.tap_holds = self.lesson_tap_holds;
        for (th_keys) |key| {
            if (key.accidental_holds > 0 and (pr.top_accidental_hold == null or key.accidental_holds > pr.top_accidental_hold.?[1]))
                pr.top_accidental_hold = .{ key.cp, key.accidental_holds };
            if (key.accidental_taps > 0 and (pr.top_accidental_tap == null or key.accidental_taps > pr.top_accidental_tap.?[1]))
                pr.top_accidental_tap = .{ key.cp, key.accidental_taps };
        }
        for (changes.items[0..changes.len]) |change| {
            if (!change.newly_green) continue;
            pr.newly_green[pr.newly_green_len] = change.cp;
            pr.newly_green_len += 1;
        }
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
                .weak_spot = pr.weak_spot,
                .newly_green = pr.newly_green[0..pr.newly_green_len],
                .tap_hold_decisions = pr.tap_holds.decisions,
                .accidental_holds = pr.tap_holds.accidental_holds,
                .accidental_taps = pr.tap_holds.accidental_taps,
                .near_holds = pr.tap_holds.near_holds,
                .top_accidental_hold = pr.top_accidental_hold,
                .top_accidental_tap = pr.top_accidental_tap,
            })
        else {};
        if (appended) |_| self.pending_run = null else |_| {}

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        self.persisted.active_stage = self.config.stage.number();
        self.persisted.target_wpm = self.config.target_wpm;
        self.persisted.guidance_mode = self.config.guidance;
        self.persisted.error_mode = storageErrorMode(self.config.error_mode);
        self.persisted.letter_order = self.config.letter_order;
        self.persisted.daily_goal_minutes = self.config.daily_goal_minutes;

        const state = try storage.buildProfileState(
            arena.allocator(),
            self.persisted,
            &self.learning,
            &self.profile,
            &self.boards,
            board_id,
            host_layout,
        );
        try storage.saveState(gpa, io, base_dir, self.profile.profile_hash, state);
        try appended;
        self.needs_persist = false;
    }

    /// Whether the running round practises combos, so hints show the combo
    /// for a character that a plain key produces as well.
    pub fn drillsCombos(self: *const Controller) bool {
        return self.active and self.captured_config.stage == .layers_combos and
            self.captured_config.stage5_filter != .specific_layer;
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

/// The letters `profile` can type in the order they unlock: home-row start
/// letters that form enough words with both hands, then the letters that add
/// the most words; or the home row first.
pub fn orderFor(profile: ?*const layout_profile.LayoutProfile, order: LetterOrder, buf: *[26]u8) []const u8 {
    const p = profile orelse return layout_profile.english_letter_frequency;
    if (p.unlock_len == 0) return layout_profile.english_letter_frequency;
    const typeable = p.unlockSlice();
    if (order == .home_row) return typeable;
    return letter_order.compute(word_list.english(), letter_order.inputFor(p), buf);
}

/// How many letters of an order of `len` letters are unlocked from the
/// start: the first letters, or the home row of the layout.
pub fn firstCountFor(profile: ?*const layout_profile.LayoutProfile, order: LetterOrder, len: usize) usize {
    const p = profile orelse return @min(first_letters, len);
    if (order == .word_forming) return @min(first_letters, len);
    return if (p.zone1_len > 0) @min(p.zone1_len, len) else @min(@as(usize, 8), len);
}

fn storageErrorMode(mode: ErrorMode) storage.ErrorMode {
    return switch (mode) {
        .forgive => .forgive,
        .stop_on_error => .stop_on_error,
        .flow_backspace => .flow_backspace,
    };
}

/// The single-character tap labels of one layer; 0 for any other key.
pub fn snapshotLayer(labels: practice.Labels, layer: usize, out: []u21) void {
    const active: u16 = 1 | (@as(u16, 1) << @intCast(@min(layer, 15)));
    for (out, 0..) |*dst, key| {
        dst.* = 0;
        if (key >= labels.key_count) continue;
        const text = labels.get(layer, key, 0, active).text orelse continue;
        const len = std.unicode.utf8ByteSequenceLength(if (text.len > 0) text[0] else continue) catch continue;
        if (len != text.len) continue;
        dst.* = std.unicode.utf8Decode(text) catch 0;
    }
}

/// `cps` with the other case of every ASCII letter.
pub fn expandLetterCase(cps: []const u21) KeyReset {
    var out: KeyReset = .{ .profile_hash = @splat(0) };
    for (cps) |cp| {
        out.add(cp);
        if (cp < 128 and std.ascii.isAlphabetic(@intCast(cp))) {
            const ch: u8 = @intCast(cp);
            out.add(if (std.ascii.isLower(ch)) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
        }
    }
    return out;
}

fn sameOpening(session: *const practice.Session, text: []const u8) bool {
    if (session.reference_len < 12 or text.len < 12) return false;
    for (session.reference[0..12], text[0..12]) |cp, byte| if (cp != byte) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Controller tests
// ---------------------------------------------------------------------------

test "a finished lesson updates the model, unlocks a key, persists and loads the next lesson at once" {
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
    // The home row ("as") first, so 'd' has to be unlocked.
    owner.config.letter_order = .home_row;
    _ = owner.bindProfile(profile, null);
    owner.utc_now_sec = 20_000 * 86_400 + 100;

    // Two fast clean rounds over "asas..." (22 samples each at 200ms) -> unlocks 'd' on round 2.
    const drill = "asasasasasasasasasasasasasasasasasasasasasas";
    var now: u64 = 1_000_000;
    for (0..2) |round_idx| {
        _ = try owner.start();
        try owner.session.loadWithMode(drill, .stop_on_error);
        for (drill) |ch| {
            now += 200_000;
            const buf = [_]u8{ch};
            _ = try owner.insertOs(true, &buf, now, false);
        }
        // No result screen: the next lesson is already waiting.
        try t.expectEqual(practice.State.ready, owner.session.state);
        try t.expect(owner.last_lesson != null);
        if (round_idx == 1) {
            try t.expectEqual(@as(?u8, 'd'), owner.last_lesson.?.newly_unlocked);
            // The first letters lead on to the rest of the alphabet by themselves.
            const events = owner.visibleEvents(now);
            try t.expectEqual(LessonEvent{ .new_letter = 'd' }, events[events.len - 2]);
            try t.expectEqual(LessonEvent{ .stage = .all_letters }, events[events.len - 1]);
            try t.expectEqual(Stage.all_letters, owner.config.stage);
            try t.expectEqual(@as(usize, 0), owner.visibleEvents(now + notice_us).len);
        }
        try owner.persistPending(t.allocator, t.io, tmp.dir, "test_board", "en-US");
        try t.expect(!owner.needs_persist);
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
    _ = try owner.ensureReady();
    try owner.session.load("ab");
    _ = try owner.insertOs(true, "a", 1_000_000, false);
    try t.expectEqual(practice.State.running, owner.session.state);

    // Switch to Test keys -> pauses tutor cleanly, ignores scoring, records telemetry text only
    _ = try owner.dispatch(owner.action(.{ .set_mode = .test_keys }), 1_200_000);
    try t.expectEqual(Mode.test_keys, owner.config.mode);
    try t.expectEqual(practice.State.paused, owner.session.state);
    try t.expect(!owner.acceptingOsText(true));
    _ = try owner.insertOs(true, "hello", 1_500_000, false);
    try t.expectEqual(@as(usize, 1), owner.session.len);
    try t.expectEqualStrings("hello", owner.test_keys.textSlice());
    try t.expect(!owner.needs_persist);

    // Switch back to Tutor -> still paused cleanly, no corrupted samples
    _ = try owner.dispatch(owner.action(.{ .set_mode = .tutor }), 2_000_000);
    try t.expectEqual(Mode.tutor, owner.config.mode);
    try t.expectEqual(practice.State.paused, owner.session.state);
}

test "OS text respects focus pause and paste remains unscored" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    _ = try owner.start();
    try owner.session.load("ab");
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
    const old = owner.action(.start);
    _ = owner.observe(@splat(2));
    try t.expectError(error.StalePracticeAction, owner.dispatch(old, 0));
    const current = owner.action(.start);
    _ = try owner.dispatch(current, 1);
    try t.expectError(error.StalePracticeAction, owner.dispatch(current, 2));
}

test "Test layout keeps whole codepoints when multibyte text fills the field" {
    const t = std.testing;
    var telemetry: TestKeysTelemetry = .{};
    const euro = "€"; // three bytes
    const count = scratchpad.capacity / euro.len + 1;
    var paste: [count * euro.len]u8 = undefined;
    for (0..count) |i| @memcpy(paste[i * euro.len ..][0..euro.len], euro);

    // The field keeps the start of a paste that does not fit.
    telemetry.typeText(&paste);
    try t.expect(std.unicode.utf8ValidateSlice(telemetry.field.text()));
    try t.expectEqual(@as(usize, (count - 1) * euro.len), telemetry.field.text().len);
    try t.expect(telemetry.field.full);

    telemetry.clearField();
    telemetry.typeText("ab");
    telemetry.typeText(paste[0 .. (count - 1) * euro.len]);
    try t.expect(std.unicode.utf8ValidateSlice(telemetry.field.text()));
    try t.expect(std.mem.startsWith(u8, telemetry.field.text(), "ab€"));

    telemetry.setLastText(&paste);
    try t.expect(std.unicode.utf8ValidateSlice(telemetry.textSlice()));
    try t.expectEqual(@as(usize, 16 * euro.len), telemetry.textSlice().len);
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

fn movedProfile(z_slot: u16) layout_profile.LayoutProfile {
    var profile: layout_profile.LayoutProfile = .{
        .unlock_len = 3,
        .zone1_len = 3,
        .key_position_len = 4,
        .profile_hash = @splat(0x55),
    };
    @memcpy(profile.unlock_order[0..3], "asz");
    profile.key_positions[0] = .{ .cp = 'Z', .layer = 0, .slot = z_slot, .shift = true };
    profile.key_positions[1] = .{ .cp = 'a', .layer = 0, .slot = 1, .shift = false };
    profile.key_positions[2] = .{ .cp = 's', .layer = 0, .slot = z_slot + 1, .shift = false };
    profile.key_positions[3] = .{ .cp = 'z', .layer = 0, .slot = z_slot, .shift = false };
    return profile;
}

fn practiseAll(owner: *Controller) void {
    for ("aszZ") |ch| owner.learning.getOrAddStat(ch).?.* = .{
        .cp = ch,
        .ema_ms = 240,
        .ema_acc = 0.99,
        .samples = 30,
        .acc_initialized = true,
    };
}

test "moved practised keys wait for an answer and keeping them is saved" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try t.allocator.create(Controller);
    defer t.allocator.destroy(owner);
    owner.* = .init(@splat(1));
    try t.expectEqual(@as(usize, 0), owner.bindProfile(movedProfile(10), null));
    practiseAll(owner);
    owner.adoptLayout(movedProfile(10), null);
    try t.expectEqual(@as(usize, 0), owner.reviewSlice().len);

    owner.adoptLayout(movedProfile(20), null);
    try t.expectEqualSlices(u21, &.{ 'Z', 's', 'z' }, owner.reviewSlice());
    try t.expectEqual(@as(u32, 30), owner.learning.getStat('z').?.samples);
    // An answer for another profile is refused.
    try t.expectError(error.StalePracticeAction, owner.dispatch(owner.action(.{ .keep_moved_keys = @splat(0x66) }), 0));
    try owner.dispatch(owner.action(.{ .keep_moved_keys = owner.profile.profile_hash }), 0);
    try t.expectEqual(@as(usize, 0), owner.reviewSlice().len);
    try owner.persistPending(t.allocator, t.io, tmp.dir, "board", "en-US");

    // After a restart both keyboards are known.
    var loaded = try storage.loadState(t.allocator, t.io, tmp.dir, owner.profile.profile_hash);
    defer loaded.deinit();
    const resumed = try t.allocator.create(Controller);
    defer t.allocator.destroy(resumed);
    resumed.* = .init(@splat(1));
    try t.expectEqual(@as(usize, 0), resumed.bindProfile(movedProfile(10), loaded.state));
    resumed.adoptLayout(movedProfile(20), null);
    try t.expectEqual(@as(usize, 0), resumed.reviewSlice().len);

    // A pending question is derived state and never outlives its profile.
    resumed.adoptLayout(movedProfile(30), null);
    try t.expect(resumed.reviewSlice().len > 0);
    resumed.discardPending();
    try t.expectEqual(@as(usize, 0), resumed.reviewSlice().len);
}

test "resetting characters saves state, keeps the history and replaces the round" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try t.allocator.create(Controller);
    defer t.allocator.destroy(owner);
    owner.* = .init(@splat(1));
    _ = owner.bindProfile(movedProfile(10), null);
    practiseAll(owner);
    try storage.appendRun(t.allocator, t.io, tmp.dir, owner.profile.profile_hash, .{
        .utc_timestamp = 1,
        .stage = 1,
        .wpm = 30,
        .accuracy = 99,
        .active_seconds = 20,
    });
    try owner.start();
    try owner.session.load("zzzz");
    try owner.insertOs(true, "z", 1_000_000, false);
    try owner.insertOs(true, "z", 1_200_000, false);
    const generation = owner.generation;

    var request: KeyReset = .{ .profile_hash = owner.profile.profile_hash };
    request.add('z');
    try owner.dispatch(owner.action(.{ .reset_keys = request }), 1_300_000);
    try t.expect(owner.generation > generation);
    try t.expectEqual(practice.State.ready, owner.session.state);
    // Both cases start over; the other letters keep their statistics.
    try t.expect(!owner.learning.hasData('z'));
    try t.expect(!owner.learning.hasData('Z'));
    try t.expectEqual(@as(u32, 30), owner.learning.getStat('a').?.samples);
    try t.expect(owner.needs_persist and !owner.reset_requested);
    try owner.persistPending(t.allocator, t.io, tmp.dir, "board", "en-US");

    var loaded = try storage.loadState(t.allocator, t.io, tmp.dir, owner.profile.profile_hash);
    defer loaded.deinit();
    for (loaded.state.key_stats) |ks| {
        if (ks.cp == 'z') try t.expectEqual(@as(u32, 0), ks.samples);
    }
    var runs = try storage.loadRuns(t.allocator, t.io, tmp.dir, owner.profile.profile_hash);
    defer runs.deinit();
    try t.expectEqual(@as(usize, 1), runs.runs.len);

    var stale = request;
    stale.profile_hash = @splat(0x01);
    try t.expectError(error.StalePracticeAction, owner.dispatch(owner.action(.{ .reset_keys = stale }), 2_000_000));
}

test "answering the layout question resets the chosen keys and keeps the rest" {
    const t = std.testing;
    const owner = try t.allocator.create(Controller);
    defer t.allocator.destroy(owner);
    owner.* = .init(@splat(1));
    _ = owner.bindProfile(movedProfile(10), null);
    practiseAll(owner);
    owner.adoptLayout(movedProfile(10), null);
    owner.adoptLayout(movedProfile(20), null);
    try t.expectEqual(@as(usize, 3), owner.reviewSlice().len);

    var request: KeyReset = .{ .profile_hash = owner.profile.profile_hash };
    request.add('Z');
    try owner.dispatch(owner.action(.{ .resolve_layout_changes = request }), 0);
    try t.expectEqual(@as(usize, 0), owner.reviewSlice().len);
    try t.expect(!owner.learning.hasData('z'));
    try t.expectEqual(@as(u32, 30), owner.learning.getStat('s').?.samples);
    // Back on the first keyboard: 's' was kept for both, 'z' was practised only here now.
    owner.adoptLayout(movedProfile(10), null);
    try t.expectEqual(@as(usize, 0), owner.reviewSlice().len);

    // Resetting the whole profile follows the bound layout again.
    owner.resetProgress();
    try t.expectEqual(@as(usize, 0), owner.reviewSlice().len);
    try t.expect(owner.learning.knownSlice().len > 0);
}

test "a lesson names keys that turned green and stuck help appears after four flat lessons" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    var profile: layout_profile.LayoutProfile = .{
        .unlock_len = 3,
        .zone1_len = 2,
        .profile_hash = @splat(0x45),
    };
    profile.unlock_order[0] = 'a';
    profile.unlock_order[1] = 's';
    profile.unlock_order[2] = 'd';
    // The home row ("as") first, so 'd' has to be unlocked.
    owner.config.letter_order = .home_row;
    _ = owner.bindProfile(profile, null);

    // 'a' comes quickly, 's' always takes 900 ms (about 13 WPM against 20).
    const drill = "asasasasasasasasasasasasasasasasasasasasasas";
    var now: u64 = 1_000_000;
    const Play = struct {
        fn round(o: *Controller, text: []const u8, clock: *u64) !void {
            try o.session.loadWithMode(text, .stop_on_error);
            for (text) |ch| {
                clock.* += if (ch == 's') 900_000 else 200_000;
                _ = try o.insertOs(true, &[_]u8{ch}, clock.*, false);
            }
        }
    };
    for (0..5) |round_idx| {
        try owner.start();
        try Play.round(&owner, drill, &now);
        const rd = owner.last_lesson.?;
        if (round_idx == 0) {
            try t.expectEqual(@as(u21, 'a'), rd.changeSlice()[0].cp);
            try t.expect(rd.changeSlice()[0].newly_green);
        }
        const open = rd.changeSlice()[rd.change_len - 1];
        try t.expectEqual(@as(u21, 's'), open.cp);
        try t.expect(!open.newly_green);
        try t.expectEqual(@as(u32, 0), open.misses);
        if (round_idx < 4) try t.expect(owner.stuckHelp() == null);
    }
    const help = owner.stuckHelp().?;
    try t.expectEqual(@as(u21, 's'), help.cp);
    try t.expectEqual(StuckReason.speed, help.reason);
    try t.expectEqual(@as(?f32, 15), help.lower_target);

    try owner.dispatch(owner.action(.{ .dismiss_stuck = 's' }), now);
    try t.expect(owner.stuckHelp() == null);

    // A slow round counts hits but leaves the latencies out.
    const before = owner.learning.getStat('s').?;
    try owner.dispatch(owner.action(.{ .practise_key = .{ .cp = 's', .slow = true } }), now);
    try t.expect(owner.slow_round);
    try Play.round(&owner, drill, &now);
    try t.expect(owner.last_lesson.?.slow_round);
    const after = owner.learning.getStat('s').?;
    try t.expectEqual(before.ema_ms, after.ema_ms);
    try t.expectEqual(before.samples, after.samples);
    try owner.start();
    try t.expect(!owner.slow_round);

    try t.expectEqual(@as(?f32, 25), lowerPreset(35));
    try t.expectEqual(@as(?f32, null), lowerPreset(15));
}

test "every fifth lesson of the first letters is built around the slowest pair" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    var profile: layout_profile.LayoutProfile = .{
        .unlock_len = 8,
        .zone1_len = 6,
        .profile_hash = @splat(0x46),
    };
    @memcpy(profile.unlock_order[0..8], "esartldi");
    _ = owner.bindProfile(profile, null);
    var now: u64 = 1_000_000;
    for (0..weak_spot_every - 1) |_| {
        try owner.start();
        try t.expect(owner.lesson_bigram == null);
        const generation = owner.generation;
        while (owner.generation == generation) {
            const s = &owner.session;
            const cp = s.reference[s.len];
            // "t" after "s" is slow; everything else is quick.
            now += if (cp == 't' and s.len > 0 and s.reference[s.len - 1] == 's') 700_000 else 180_000;
            var bytes: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &bytes);
            try owner.insertOs(true, bytes[0..n], now, false);
        }
    }
    // The lesson the last one loaded is the weak-spot lesson.
    const pair = owner.lesson_bigram orelse return error.NoWeakSpotLesson;
    const text = owner.session.reference[0..owner.session.reference_len];
    var start: usize = 0;
    for (text, 0..) |cp, i| {
        if (cp != ' ' and i + 1 < text.len) continue;
        const end = if (cp == ' ') i else i + 1;
        var found = false;
        for (start..end -| 1) |k| found = found or (text[k] == pair[0] and text[k + 1] == pair[1]);
        try t.expect(found);
        start = i + 1;
    }
    try t.expectEqualSlices(u8, "st", &pair);
}

fn alphabetProfile(hash: u8) layout_profile.LayoutProfile {
    var profile: layout_profile.LayoutProfile = .{
        .unlock_len = 26,
        .zone1_len = 8,
        .profile_hash = @splat(hash),
    };
    @memcpy(profile.unlock_order[0..26], "arstneiodhgmlcpfuwybkvjxqz");
    return profile;
}

test "letters come in the word-forming order and the home row is an option that keeps progress" {
    const t = std.testing;
    const owner = try t.allocator.create(Controller);
    defer t.allocator.destroy(owner);
    owner.* = .init(@splat(1));
    _ = owner.bindProfile(alphabetProfile(0x47), null);
    // The start letters stay on the home row while it forms enough words.
    try t.expectEqualStrings("esarti", owner.learning.activeLetters());
    try t.expectEqualStrings("esarti", owner.learning.firstLetters());

    try owner.dispatch(owner.action(.{ .set_letter_order = .home_row }), 0);
    // The home row comes first, and nothing unlocked before is locked again.
    try t.expectEqualStrings("arstneio", owner.learning.activeLetters());
    try t.expectEqualStrings("arstneio", owner.learning.firstLetters());
    try t.expectEqual(LetterOrder.home_row, owner.persisted.letter_order);
}

test "Stage 1 practises and names a focus among the first letters" {
    const t = std.testing;
    const owner = try t.allocator.create(Controller);
    defer t.allocator.destroy(owner);
    owner.* = .init(@splat(1));
    // Letters beyond the first ones are unlocked and one of them is the focus.
    _ = owner.bindProfile(alphabetProfile(0x49), .{ .unlocked_count = 9, .active_stage = 1, .focus_cp = 'd' });
    const first = owner.learning.firstLetters();
    try t.expectEqual(@as(?u21, 'd'), owner.learning.focus_cp);
    const focus = owner.lessonFocus().?;
    try t.expect(std.mem.indexOfScalar(u8, first, @intCast(focus)) != null);
    try owner.start();
    const reference = owner.session.reference[0..owner.session.reference_len];
    try t.expect(std.mem.indexOfScalar(u21, reference, focus) != null);
    try t.expect(std.mem.indexOfScalar(u21, reference, 'd') == null);
    // Stage 2 practises the learning focus itself.
    try owner.dispatch(owner.action(.{ .set_stage = .all_letters }), 0);
    try t.expectEqual(@as(?u21, 'd'), owner.lessonFocus());
}

test "a save from before the word-forming order keeps its unlocked letters" {
    const t = std.testing;
    const owner = try t.allocator.create(Controller);
    defer t.allocator.destroy(owner);
    owner.* = .init(@splat(1));
    // Schema 2: the first nine letters of the home-row order were unlocked.
    _ = owner.bindProfile(alphabetProfile(0x48), .{
        .schema_version = 2,
        .unlocked_count = 9,
        .error_mode = .stop_on_error,
        .key_stats = &.{.{ .cp = 'q', .ema_ms = 300, .ema_acc = 1, .samples = 40 }},
    });
    for ("arstneiod" ++ "esarti" ++ "q") |ch| try t.expect(owner.learning.isUnlocked(ch));
    try t.expectEqualStrings("esarti", owner.learning.firstLetters());
    try t.expectEqual(ErrorMode.forgive, owner.config.error_mode);
    // 'q' was green, so it counts as mastered and stays unlocked.
    try t.expect(owner.learning.getStat('q').?.mastered);
}

test "tap/hold decisions are classified during a lesson, counted for it and saved" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var owner = Controller.init(@splat(1));
    var profile = tap_hold.testProfile();
    @memcpy(profile.unlock_order[0..6], "asdfjk");
    profile.unlock_len = 6;
    profile.zone1_len = 4;
    profile.profile_hash = @splat(0x55);
    owner.config.letter_order = .home_row;
    _ = owner.bindProfile(profile, null);

    const roll: tap_hold.Decision = .{ .key_index = 3, .outcome = .hold, .reason = .permissive_hold, .elapsed_ms = 80, .other_key = 0, .tapping_term_ms = 200 };
    // Nothing counts without a lesson.
    try t.expectEqual(@as(?model.TapHoldClass, null), owner.observeTapHold(roll));
    try owner.start();
    try owner.session.loadWithMode("fad fad", .forgive);
    owner.config.mode = .test_keys;
    try t.expectEqual(@as(?model.TapHoldClass, null), owner.observeTapHold(roll));
    owner.config.mode = .tutor;

    try t.expectEqual(@as(?model.TapHoldClass, .accidental_hold), owner.observeTapHold(roll));
    // A hold the term decided, released into a retro tap: the f came late.
    var slow = roll;
    slow.reason = .term_elapsed;
    slow.elapsed_ms = 210;
    slow.other_key = null;
    try t.expectEqual(@as(?model.TapHoldClass, .accidental_hold), owner.observeTapHold(slow));
    const retro: tap_hold.Decision = .{ .key_index = 3, .outcome = .retro_tap, .reason = .released_after_term, .elapsed_ms = 260, .tapping_term_ms = 200 };
    try t.expectEqual(@as(?model.TapHoldClass, .near_hold), owner.observeTapHold(retro));
    try t.expectEqual(@as(?model.TapHoldClass, .wanted_tap), owner.observeTapHold(.{ .key_index = 3, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 70, .tapping_term_ms = 200 }));
    // A key the text does not ask for is ignored.
    try t.expectEqual(@as(?model.TapHoldClass, null), owner.observeTapHold(.{ .key_index = 5, .outcome = .tap, .reason = .released_within_term, .elapsed_ms = 70, .tapping_term_ms = 200 }));

    const before_accuracy = owner.session.accuracy();
    try t.expectEqual(LessonTapHolds{ .decisions = 3, .accidental_holds = 1, .near_holds = 1 }, owner.lesson_tap_holds);
    // Typed text is scored as before; decisions do not touch it.
    try t.expectEqual(before_accuracy, owner.session.accuracy());
    var now: u64 = 1_000_000;
    for ("fad fad") |ch| {
        now += 200_000;
        try owner.insertOs(true, &.{ch}, now, false);
    }
    try t.expectEqual(LessonTapHolds{ .decisions = 3, .accidental_holds = 1, .near_holds = 1 }, owner.last_lesson.?.tap_holds);
    try t.expectEqual(LessonTapHolds{}, owner.lesson_tap_holds);
    // The roll stays an accidental hold of f; the term hold became late.
    try t.expectEqual(LessonTapHoldKey{ .cp = 'f', .accidental_holds = 1, .rolls = 1 }, owner.last_lesson.?.tapHoldKey('f').?);
    try t.expectEqual(@as(?model.TapHoldReason, .permissive_hold), owner.last_lesson.?.tapHoldKey('f').?.holdReason());
    // The notice comes first and names the key and the roll.
    try t.expectEqual(LessonEvent{ .tap_hold = .{ .cp = 'f', .count = 1, .hold = true, .reason = .permissive_hold } }, owner.visibleEvents(now)[0]);
    const f = owner.tapHoldSummary('f').?;
    try t.expectEqual(@as(u8, 3), f.window);
    try t.expectEqual(@as(u8, 1), f.accidental_holds);
    try t.expectEqual(@as(u8, 1), f.near_holds);
    var top: [4]model.TapHoldSummary = undefined;
    try t.expectEqual(@as(u21, 'f'), owner.mostAccidentalHolds(&top)[0].cp);

    try owner.persistPending(t.allocator, t.io, tmp.dir, "board", "en-US");
    var runs = try storage.loadRuns(t.allocator, t.io, tmp.dir, profile.profile_hash);
    defer runs.deinit();
    try t.expectEqual(@as(u16, 3), runs.runs[0].tap_hold_decisions);
    try t.expectEqual(@as(u16, 1), runs.runs[0].accidental_holds);
    try t.expectEqual(@as(u16, 1), runs.runs[0].near_holds);
    try t.expectEqual(@as(?[2]u32, .{ 'f', 1 }), runs.runs[0].top_accidental_hold);
    try t.expectEqual(@as(?[2]u32, null), runs.runs[0].top_accidental_tap);
    var saved = try storage.loadState(t.allocator, t.io, tmp.dir, profile.profile_hash);
    defer saved.deinit();
    var reloaded = Controller.init(@splat(1));
    reloaded.config.letter_order = .home_row;
    _ = reloaded.bindProfile(profile, saved.state);
    try t.expectEqualDeep(f, reloaded.tapHoldSummary('f').?);
}

test "the tap/hold notice names a key at most once in five lessons" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    const roll: LessonTapHoldKey = .{ .cp = 'a', .accidental_holds = 3, .rolls = 3 };
    const slow: LessonTapHoldKey = .{ .cp = 's', .accidental_holds = 1, .term = 1 };
    const tapped: LessonTapHoldKey = .{ .cp = 'o', .accidental_taps = 4 };
    // Holds come before taps, more before fewer.
    const first = owner.tapHoldNotice(&.{ tapped, slow, roll }, 10).?;
    try t.expectEqual(TapHoldNotice{ .cp = 'a', .count = 3, .hold = true, .reason = .permissive_hold }, first);
    owner.rememberNotice('a', 10);
    try t.expectEqual(@as(u21, 's'), owner.tapHoldNotice(&.{ roll, slow }, 14).?.cp);
    try t.expectEqual(@as(?model.TapHoldReason, .term_elapsed), owner.tapHoldNotice(&.{slow}, 14).?.reason);
    try t.expectEqual(@as(?TapHoldNotice, null), owner.tapHoldNotice(&.{roll}, 14));
    try t.expectEqual(@as(u21, 'a'), owner.tapHoldNotice(&.{roll}, 15).?.cp);
    try t.expectEqual(TapHoldNotice{ .cp = 'o', .count = 4, .hold = false, .reason = .released_within_term }, owner.tapHoldNotice(&.{tapped}, 11).?);

    // It goes in front of the other notices.
    owner.addEvent(.{ .green = 'c' });
    owner.addEvent(.daily_goal);
    owner.addEventFirst(.{ .tap_hold = first });
    try t.expectEqual(@as(usize, 3), owner.event_len);
    try t.expectEqual(LessonEvent{ .tap_hold = first }, owner.events[0]);
    try t.expectEqual(LessonEvent{ .green = 'c' }, owner.events[1]);
}

test "a longer tapping term is suggested only when holding past it is the cause" {
    const t = std.testing;
    try t.expectEqual(@as(u16, 230), suggestedTerm(200));
    try t.expectEqual(@as(u16, 140), suggestedTerm(120));
    try t.expectEqual(@as(u16, 290), suggestedTerm(250));
    var s: model.TapHoldSummary = .{
        .cp = 's',
        .window = 30,
        .accidental_holds = 2,
        .accidental_taps = 0,
        .near_holds = 4,
        .wanted_holds = 0,
        .dominant_reason = .term_elapsed,
        .typical_ms = 160,
        .overlap_ms = 0,
        .tapping_term_ms = 200,
        .last_overlap_cp = null,
        .total = 50,
    };
    try t.expect(suggestsTerm(s));
    s.total = 49;
    try t.expect(!suggestsTerm(s));
    s.total = 80;
    s.dominant_reason = .permissive_hold;
    try t.expect(!suggestsTerm(s));
}

test "Test layout keeps its last four decisions for display and counts none" {
    const t = std.testing;
    var owner = Controller.init(@splat(1));
    const decision: tap_hold.Decision = .{ .key_index = 3, .outcome = .hold, .reason = .permissive_hold, .elapsed_ms = 143, .other_key = 4, .tapping_term_ms = 200 };
    try t.expect(!owner.observeTestTapHold(decision, 1));
    owner.config.mode = .test_keys;
    for (0..6) |i| {
        var d = decision;
        d.key_index = i;
        try t.expect(owner.observeTestTapHold(d, i));
    }
    var combo = decision;
    combo.combo = true;
    try t.expect(!owner.observeTestTapHold(combo, 9));
    const kept = owner.test_keys.tapHoldSlice();
    try t.expectEqual(@as(usize, 4), kept.len);
    try t.expectEqual(@as(usize, 2), kept[0].decision.key_index);
    try t.expectEqual(@as(usize, 5), kept[3].decision.key_index);
    try t.expectEqual(@as(u64, 5), kept[3].at_us);
    try t.expectEqual(@as(usize, 0), owner.learning.tap_hold_len);
}
