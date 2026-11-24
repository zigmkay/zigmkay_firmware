//! Clean-room adaptive per-key learning model for the Zigmkay typing tutor.
//! Tracks filtered motor latencies, per-key EMA speed and first-try accuracy,
//! confidence scores, sequential unlock cadence, linear-regression forecasts,
//! bounded bigram bottlenecks, known key positions and per-character resets.
const std = @import("std");
const layout_profile = @import("practice_layout_profile.zig");

pub const Language = enum(u8) {
    en,
};

pub const min_clean_dt_us: u64 = 25_000; // 25 ms
pub const max_clean_dt_us: u64 = 2_000_000; // 2000 ms
pub const ema_ms_alpha: f32 = 0.25;
/// First-try accuracy of a key is measured over its most recent presses, so
/// early mistakes on a new keyboard stop counting once they are this far back.
pub const accuracy_window: u8 = 30;
/// At most two misses in the last 30 presses.
pub const accuracy_gate: f32 = 0.93;
pub const min_samples_for_mastery: u32 = 20;
pub const min_rounds_between_unlocks: u32 = 2;
pub const focus_history_capacity: usize = 10;
pub const max_tracked_keys: usize = 96;
pub const max_bigrams: usize = 256;
pub const max_round_samples_per_key: usize = 64;
pub const max_round_keys: usize = 64;
pub const max_round_bigrams: usize = 256;
/// Positions a character keeps statistics for, one per keyboard it moved
/// between; the oldest is forgotten first.
pub const max_positions_per_key: usize = 4;
pub const max_known_positions: usize = layout_profile.max_routes + max_tracked_keys * (max_positions_per_key - 1);

pub const KeyStat = struct {
    cp: u21 = 0,
    ema_ms: f32 = 0.0,
    /// First-try accuracy over `recent_hits`; older saves without a window
    /// keep their smoothed value until the key is typed again.
    ema_acc: f32 = 0.0,
    samples: u32 = 0,
    acc_initialized: bool = false,
    /// One bit per recent press, newest in bit 0; 1 is a first-try hit.
    recent_hits: u32 = 0,
    recent_len: u8 = 0,
    /// The key once reached full confidence. It stays green and unlocked
    /// from then on, whatever its later presses look like.
    mastered: bool = false,

    pub fn confidence(self: KeyStat, target_wpm: f32) f32 {
        return computeConfidence(self.ema_ms, self.ema_acc, self.samples, target_wpm);
    }

    /// Green: mastered once, or fully confident now.
    pub fn green(self: KeyStat, target_wpm: f32) bool {
        return self.mastered or self.confidence(target_wpm) >= 1.0;
    }

    /// Appends the `len` oldest-first outcomes in `hits` (newest in bit 0)
    /// to the accuracy window and recomputes the accuracy from it.
    pub fn recordOutcomes(self: *KeyStat, hits: u32, len: u8) void {
        if (len == 0) return;
        const mask: u32 = (@as(u32, 1) << accuracy_window) - 1;
        const n: u5 = @intCast(@min(len, accuracy_window));
        self.recent_hits = ((self.recent_hits << n) | (hits & ((@as(u32, 1) << n) - 1))) & mask;
        self.recent_len = @min(accuracy_window, self.recent_len + n);
        const window_mask: u32 = (@as(u32, 1) << @as(u5, @intCast(self.recent_len))) - 1;
        const hit_count: f32 = @floatFromInt(@popCount(self.recent_hits & window_mask));
        self.ema_acc = hit_count / @as(f32, @floatFromInt(self.recent_len));
        self.acc_initialized = true;
    }

    pub fn wpm(self: KeyStat) f32 {
        if (self.ema_ms <= 0.0) return 0.0;
        return 12_000.0 / self.ema_ms;
    }

    pub fn reset(self: *KeyStat) void {
        self.ema_ms = 0.0;
        self.ema_acc = 0.0;
        self.samples = 0;
        self.acc_initialized = false;
        self.recent_hits = 0;
        self.recent_len = 0;
        self.mastered = false;
    }
};

pub const FocusSample = struct {
    ema_ms: f32,
    confidence: f32,
};

pub const BigramStat = struct {
    prev: u21,
    cur: u21,
    ema_ms: f32,
    samples: u32,
};

pub const KeySummary = struct {
    cp: u21,
    confidence: f32,
    ema_ms: f32,
    ema_acc: f32,
    samples: u32,
};

pub const ModelConfig = struct {
    language: Language = .en,
    target_wpm: f32 = 20.0,
};

/// The keys of one keyboard that last produced a known position, for the
/// before/now comparison. `board` is `boardHash` of the board id.
pub const SeenKey = struct {
    board: u64 = 0,
    key_index: u16 = 0,
    combo_key_index: ?u16 = null,
    /// The key held for the layer, when the position is on another layer.
    layer_key_index: ?u16 = null,
};

pub fn boardHash(board_id: []const u8) u64 {
    // Snapshots keep 64 bytes of the id; hash what survives a save.
    return std.hash.Wyhash.hash(0x7a69676d6b6179, board_id[0..@min(board_id.len, 64)]);
}

pub const max_board_snapshots: usize = 8;
pub const max_snapshot_layers: usize = 8;

/// The single-character tap labels of one keyboard, kept so a key can be
/// shown where it used to be after that keyboard is gone.
pub const BoardSnapshot = struct {
    id: [64]u8 = @splat(0),
    id_len: u8 = 0,
    hash: u64 = 0,
    key_count: u16 = 0,
    layers: [max_snapshot_layers]u8 = @splat(0),
    layer_len: u8 = 0,
    /// Codepoint per key and layer; 0 is a key without a single-character label.
    labels: [max_snapshot_layers][layout_profile.max_keys]u21 = undefined,

    pub fn idSlice(self: *const BoardSnapshot) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn layerLabels(self: *const BoardSnapshot, layer: u8) ?[]const u21 {
        for (self.layers[0..self.layer_len], 0..) |value, i| {
            if (value == layer) return self.labels[i][0..self.key_count];
        }
        return null;
    }

    /// Adds or replaces the labels of a layer; returns whether they changed.
    pub fn setLayer(self: *BoardSnapshot, layer: u8, labels: []const u21) bool {
        const n = @min(labels.len, self.key_count);
        const index = for (self.layers[0..self.layer_len], 0..) |value, i| {
            if (value == layer) break i;
        } else blk: {
            if (self.layer_len >= max_snapshot_layers) return false;
            self.layers[self.layer_len] = layer;
            self.layer_len += 1;
            @memset(&self.labels[self.layer_len - 1], 0);
            break :blk self.layer_len - 1;
        };
        const row = self.labels[index][0..n];
        if (std.mem.eql(u21, row, labels[0..n])) return false;
        @memcpy(row, labels[0..n]);
        return true;
    }
};

/// The most recently used keyboards of a profile, oldest first.
pub const BoardSnapshots = struct {
    boards: [max_board_snapshots]BoardSnapshot = undefined,
    len: usize = 0,

    pub fn slice(self: *const BoardSnapshots) []const BoardSnapshot {
        return self.boards[0..self.len];
    }

    pub fn find(self: *const BoardSnapshots, hash: u64) ?*const BoardSnapshot {
        for (self.boards[0..self.len]) |*board| {
            if (board.hash == hash) return board;
        }
        return null;
    }

    /// The snapshot of `id`, moved to the newest place; the oldest keyboard
    /// makes room when the table is full. Layers are kept when the key count
    /// stays.
    pub fn use(self: *BoardSnapshots, id: []const u8, key_count: usize) *BoardSnapshot {
        const hash = boardHash(id);
        const keys: u16 = @intCast(@min(key_count, layout_profile.max_keys));
        var entry: BoardSnapshot = for (self.boards[0..self.len], 0..) |board, i| {
            if (board.hash == hash) {
                std.mem.copyForwards(BoardSnapshot, self.boards[i .. self.len - 1], self.boards[i + 1 .. self.len]);
                self.len -= 1;
                break board;
            }
        } else .{};
        if (entry.key_count != keys) entry.layer_len = 0;
        const id_len = @min(id.len, entry.id.len);
        @memcpy(entry.id[0..id_len], id[0..id_len]);
        entry.id_len = @intCast(id_len);
        entry.hash = hash;
        entry.key_count = keys;
        if (self.len >= max_board_snapshots) {
            std.mem.copyForwards(BoardSnapshot, self.boards[0 .. self.len - 1], self.boards[1..self.len]);
            self.len -= 1;
        }
        self.boards[self.len] = entry;
        self.len += 1;
        return &self.boards[self.len - 1];
    }
};

/// A position at which a character's statistics count as valid.
pub const KnownPosition = struct {
    pos: layout_profile.KeyPosition,
    seen: ?SeenKey = null,
};

pub const RoundOutcome = struct {
    newly_unlocked: ?u8 = null,
    focus_cp: ?u21 = null,
    focus_confidence: f32 = 0.0,
    forecast_rounds: ?u32 = null,
};

/// Computes per-key confidence in [0.0, 1.0].
/// Accuracy below `accuracy_gate` and sample counts below 20 cannot reach 1.0 mastery
/// even when raw speed exceeds target_wpm.
pub fn computeConfidence(ema_ms: f32, ema_acc: f32, samples: u32, target_wpm: f32) f32 {
    if (samples == 0 or ema_ms <= 0.0 or target_wpm <= 0.0) return 0.0;
    const target_ms = 12_000.0 / target_wpm;
    const speed_score = std.math.clamp(target_ms / ema_ms, 0.0, 1.25);
    const acc_penalty: f32 = if (ema_acc >= accuracy_gate) 1.0 else blk: {
        const ratio = std.math.clamp(ema_acc / accuracy_gate, 0.0, 1.0);
        break :blk ratio * ratio;
    };
    const sample_factor = std.math.clamp(
        @as(f32, @floatFromInt(samples)) / @as(f32, @floatFromInt(min_samples_for_mastery)),
        0.0,
        1.0,
    );
    var conf = std.math.clamp(speed_score * acc_penalty * sample_factor, 0.0, 1.0);
    if (ema_acc < accuracy_gate) conf = @min(conf, acc_penalty);
    if (samples < min_samples_for_mastery) conf = @min(conf, sample_factor);
    return conf;
}

/// Evaluates whether an inter-keystroke interval qualifies as a clean motor latency sample.
pub fn filterCleanDtUs(
    prev_us: ?u64,
    now_us: u64,
    is_first_char: bool,
    had_pause_or_blur: bool,
    had_error: bool,
    prev_had_error: bool,
) ?u64 {
    if (is_first_char or had_pause_or_blur or had_error or prev_had_error) return null;
    const prev = prev_us orelse return null;
    if (now_us < prev) return null;
    const dt = now_us - prev;
    if (dt < min_clean_dt_us or dt > max_clean_dt_us) return null;
    return dt;
}

/// Collects per-round clean latencies, first-try accuracy, and clean bigram transitions.
pub const RoundCollector = struct {
    const CharBucket = struct {
        cp: u21 = 0,
        dt_ms: [max_round_samples_per_key]f32 = undefined,
        dt_len: usize = 0,
        total_positions: u32 = 0,
        first_try_hits: u32 = 0,
        /// Last `accuracy_window` outcomes of this round, newest in bit 0.
        recent_hits: u32 = 0,
    };

    const BigramEvent = struct {
        prev: u21,
        cur: u21,
        dt_ms: f32,
    };

    buckets: [max_round_keys]CharBucket = undefined,
    bucket_len: usize = 0,
    bigrams: [max_round_bigrams]BigramEvent = undefined,
    bigram_len: usize = 0,

    last_us: ?u64 = null,
    last_cp: ?u21 = null,
    seen_any: bool = false,
    chain_broken_by_pause: bool = false,
    prev_had_error: bool = false,

    pub fn reset(self: *RoundCollector) void {
        self.* = .{};
    }

    pub fn notePauseOrBlur(self: *RoundCollector) void {
        self.chain_broken_by_pause = true;
        self.last_us = null;
    }

    /// Record a committed reference character position.
    /// `had_error` is true if any wrong keystroke occurred at this character position
    /// before the user typed the matching character.
    pub fn recordCommit(self: *RoundCollector, cp: u21, now_us: u64, had_error: bool) void {
        const is_first = !self.seen_any;
        self.seen_any = true;

        const bucket = self.getOrAddBucket(cp);
        if (bucket) |b| {
            b.total_positions += 1;
            if (!had_error) b.first_try_hits += 1;
            b.recent_hits = (b.recent_hits << 1) | @intFromBool(!had_error);
        }

        const clean_dt = filterCleanDtUs(
            self.last_us,
            now_us,
            is_first,
            self.chain_broken_by_pause,
            had_error,
            self.prev_had_error,
        );

        if (clean_dt) |dt_us| {
            const dt_ms: f32 = @as(f32, @floatFromInt(dt_us)) / 1000.0;
            if (bucket) |b| {
                if (b.dt_len < max_round_samples_per_key) {
                    b.dt_ms[b.dt_len] = dt_ms;
                    b.dt_len += 1;
                }
            }
            if (self.last_cp) |prev_cp| {
                if (self.bigram_len < max_round_bigrams) {
                    self.bigrams[self.bigram_len] = .{
                        .prev = prev_cp,
                        .cur = cp,
                        .dt_ms = dt_ms,
                    };
                    self.bigram_len += 1;
                }
            }
        }

        self.chain_broken_by_pause = false;
        self.prev_had_error = had_error;
        if (had_error) {
            self.last_us = null;
            self.last_cp = null;
        } else {
            self.last_us = now_us;
            self.last_cp = cp;
        }
    }

    fn getOrAddBucket(self: *RoundCollector, cp: u21) ?*CharBucket {
        for (self.buckets[0..self.bucket_len]) |*b| {
            if (b.cp == cp) return b;
        }
        if (self.bucket_len >= max_round_keys) return null;
        self.buckets[self.bucket_len] = .{ .cp = cp };
        const ptr = &self.buckets[self.bucket_len];
        self.bucket_len += 1;
        return ptr;
    }
};

pub fn medianF32(values: []const f32) f32 {
    std.debug.assert(values.len > 0);
    var buf: [max_round_samples_per_key]f32 = undefined;
    const n = @min(values.len, buf.len);
    @memcpy(buf[0..n], values[0..n]);
    std.mem.sort(f32, buf[0..n], {}, std.sort.asc(f32));
    if (n % 2 == 1) return buf[n / 2];
    return (buf[n / 2 - 1] + buf[n / 2]) * 0.5;
}

/// Simple linear regression forecast of rounds remaining until confidence reaches 1.0.
/// Returns null unless there are >= 3 points, positive slope, and R^2 >= 0.5.
pub fn forecastRoundsToUnlock(history: []const FocusSample) ?u32 {
    if (history.len < 3) return null;
    const last_conf = history[history.len - 1].confidence;
    if (last_conf >= 1.0) return 0;

    const n: f64 = @floatFromInt(history.len);
    var sum_x: f64 = 0.0;
    var sum_y: f64 = 0.0;
    for (history, 0..) |pt, i| {
        const x: f64 = @floatFromInt(i);
        sum_x += x;
        sum_y += @as(f64, pt.confidence);
    }
    const mean_x = sum_x / n;
    const mean_y = sum_y / n;

    var sxx: f64 = 0.0;
    var syy: f64 = 0.0;
    var sxy: f64 = 0.0;
    for (history, 0..) |pt, i| {
        const dx = @as(f64, @floatFromInt(i)) - mean_x;
        const dy = @as(f64, pt.confidence) - mean_y;
        sxx += dx * dx;
        syy += dy * dy;
        sxy += dx * dy;
    }
    if (sxx <= 1e-12 or syy <= 1e-12) return null;
    const slope = sxy / sxx;
    if (slope <= 1e-4) return null;
    const r_squared = (sxy * sxy) / (sxx * syy);
    if (r_squared < 0.5) return null;

    const intercept = mean_y - slope * mean_x;
    const target_x = (1.0 - intercept) / slope;
    const remaining = target_x - @as(f64, @floatFromInt(history.len - 1));
    if (!std.math.isFinite(remaining) or remaining <= 0.0) return 1;
    const rounded: u32 = @intFromFloat(@ceil(std.math.clamp(remaining, 1.0, 99.0)));
    return rounded;
}

pub const LearningModel = struct {
    config: ModelConfig = .{},
    unlock_order: [26]u8 = @splat(0),
    unlock_len: usize = 0,
    unlocked_count: usize = 0,
    /// The letters unlocked from the start: what Stage 1 practises.
    first_len: usize = 0,
    rounds_since_unlock: u32 = 0,
    total_rounds: u32 = 0,

    stats: [max_tracked_keys]KeyStat = @splat(.{}),
    stat_len: usize = 0,

    focus_cp: ?u21 = null,
    focus_history: [focus_history_capacity]FocusSample = undefined,
    focus_history_len: usize = 0,

    bigrams: [max_bigrams]BigramStat = undefined,
    bigram_len: usize = 0,

    /// Positions per character at which its statistics were made or kept,
    /// oldest first. Moving a key never resets anything by itself.
    known: [max_known_positions]KnownPosition = undefined,
    known_len: usize = 0,

    pub fn init(unlock_order: []const u8, initial_unlocked: usize, config: ModelConfig) LearningModel {
        var model: LearningModel = .{
            .config = config,
            .unlock_len = @min(unlock_order.len, 26),
        };
        @memcpy(model.unlock_order[0..model.unlock_len], unlock_order[0..model.unlock_len]);
        model.unlocked_count = @min(initial_unlocked, model.unlock_len);
        model.first_len = model.unlocked_count;
        model.refreshFocusKey();
        return model;
    }

    /// Adopts the unlock order of an edited layout. The number of unlocked
    /// letters stays; letters the layout can no longer produce drop out with
    /// the old order.
    pub fn setUnlockOrder(self: *LearningModel, unlock_order: []const u8) void {
        self.unlock_len = @min(unlock_order.len, 26);
        @memcpy(self.unlock_order[0..self.unlock_len], unlock_order[0..self.unlock_len]);
        self.unlocked_count = @min(self.unlocked_count, self.unlock_len);
        self.refreshFocusKey();
    }

    /// Follows a new letter order, keeping every letter that is unlocked or
    /// was mastered unlocked: they move to the front in the new order, and
    /// the first `first` letters of `order` are unlocked too.
    pub fn adoptOrder(self: *LearningModel, order: []const u8, first: usize) void {
        var keep: u32 = self.unlockedMask();
        for (self.stats[0..self.stat_len]) |st| {
            if (st.mastered and st.cp >= 'a' and st.cp <= 'z') keep |= letterBit(@intCast(st.cp));
        }
        self.adoptOrderKeeping(order, first, keep);
    }

    /// `adoptOrder` with the letters to keep unlocked given as a mask.
    pub fn adoptOrderKeeping(self: *LearningModel, order: []const u8, first: usize, keep_mask: u32) void {
        const len = @min(order.len, 26);
        const first_len = @min(first, len);
        var keep = keep_mask;
        for (order[0..first_len]) |ch| keep |= letterBit(ch);
        var out: [26]u8 = undefined;
        var n: usize = 0;
        for (order[0..len]) |ch| if (keep & letterBit(ch) != 0) {
            out[n] = ch;
            n += 1;
        };
        const unlocked = n;
        for (order[0..len]) |ch| if (keep & letterBit(ch) == 0) {
            out[n] = ch;
            n += 1;
        };
        @memcpy(self.unlock_order[0..n], out[0..n]);
        self.unlock_len = n;
        self.unlocked_count = unlocked;
        self.first_len = first_len;
        self.refreshFocusKey();
    }

    /// The letters Stage 1 practises.
    pub fn firstLetters(self: *const LearningModel) []const u8 {
        return self.unlock_order[0..@min(self.first_len, self.unlock_len)];
    }

    pub fn activeLetters(self: *const LearningModel) []const u8 {
        return self.unlock_order[0..self.unlocked_count];
    }

    pub fn unlockedMask(self: *const LearningModel) u32 {
        var mask: u32 = 0;
        for (self.activeLetters()) |ch| {
            if (ch >= 'a' and ch <= 'z') {
                mask |= @as(u32, 1) << @intCast(ch - 'a');
            }
        }
        return mask;
    }

    pub fn isUnlocked(self: *const LearningModel, ch: u8) bool {
        if (ch < 'a' or ch > 'z') return false;
        return (self.unlockedMask() & (@as(u32, 1) << @intCast(ch - 'a'))) != 0;
    }

    pub fn getStat(self: *const LearningModel, cp: u21) ?KeyStat {
        for (self.stats[0..self.stat_len]) |st| {
            if (st.cp == cp) return st;
        }
        return null;
    }

    pub fn getOrAddStat(self: *LearningModel, cp: u21) ?*KeyStat {
        for (self.stats[0..self.stat_len]) |*st| {
            if (st.cp == cp) return st;
        }
        if (self.stat_len >= max_tracked_keys) return null;
        self.stats[self.stat_len] = .{ .cp = cp };
        const ptr = &self.stats[self.stat_len];
        self.stat_len += 1;
        return ptr;
    }

    pub fn confidenceFor(self: *const LearningModel, cp: u21) f32 {
        const st = self.getStat(cp) orelse return 0.0;
        return st.confidence(self.config.target_wpm);
    }

    /// Whether a letter is green: mastered once or fully confident now.
    pub fn isGreen(self: *const LearningModel, cp: u21) bool {
        const st = self.getStat(cp) orelse return false;
        return st.green(self.config.target_wpm);
    }

    /// Selects the active unlocked letter with lowest confidence that is not
    /// green yet, breaking ties by fewest samples, then unlock order. Once
    /// all are green, the least confident of them.
    pub fn computeFocusKey(self: *const LearningModel) ?u21 {
        const active = self.activeLetters();
        if (active.len == 0) return null;
        var best_cp: u21 = active[0];
        var best_green = true;
        var best_conf: f32 = 2.0;
        var best_samples: u32 = std.math.maxInt(u32);
        for (active) |ch| {
            const st = self.getStat(ch) orelse KeyStat{ .cp = ch };
            const conf = st.confidence(self.config.target_wpm);
            const is_green = st.green(self.config.target_wpm);
            const better = (best_green and !is_green) or (is_green == best_green and ((conf < best_conf - 1e-6) or
                (@abs(conf - best_conf) <= 1e-6 and st.samples < best_samples)));
            if (better) {
                best_cp = ch;
                best_green = is_green;
                best_conf = conf;
                best_samples = st.samples;
            }
        }
        return best_cp;
    }

    fn refreshFocusKey(self: *LearningModel) void {
        const next_focus = self.computeFocusKey();
        if (next_focus != self.focus_cp) {
            self.focus_cp = next_focus;
            self.focus_history_len = 0;
        }
    }

    pub fn focusHistorySlice(self: *const LearningModel) []const FocusSample {
        return self.focus_history[0..self.focus_history_len];
    }

    pub fn forecast(self: *const LearningModel) ?u32 {
        return forecastRoundsToUnlock(self.focusHistorySlice());
    }

    /// Applies a completed round's collected timings/accuracy, updates EMA stats,
    /// bigram bottlenecks, focus history, and evaluates sequential unlock eligibility.
    pub fn completeRound(self: *LearningModel, collector: *const RoundCollector) RoundOutcome {
        self.total_rounds += 1;
        self.rounds_since_unlock += 1;

        const prev_focus = self.focus_cp;
        var prev_focus_practiced = false;

        // 1. Update per-character EMA latency & accuracy.
        for (collector.buckets[0..collector.bucket_len]) |b| {
            if (b.total_positions == 0) continue;
            if (prev_focus != null and b.cp == prev_focus.?) prev_focus_practiced = true;

            const st = self.getOrAddStat(b.cp) orelse continue;
            st.recordOutcomes(b.recent_hits, @intCast(@min(b.total_positions, accuracy_window)));

            if (b.dt_len > 0) {
                const med_ms = medianF32(b.dt_ms[0..b.dt_len]);
                if (st.ema_ms <= 0.0) {
                    st.ema_ms = med_ms;
                } else {
                    st.ema_ms = st.ema_ms * (1.0 - ema_ms_alpha) + med_ms * ema_ms_alpha;
                }
                st.samples += @intCast(b.dt_len);
            }
            if (st.confidence(self.config.target_wpm) >= 1.0) st.mastered = true;
        }

        // 2. Update bounded bigram bottleneck tracker.
        for (collector.bigrams[0..collector.bigram_len]) |ev| {
            self.recordBigramSample(ev.prev, ev.cur, ev.dt_ms);
        }

        // 3. Record focus key trend point if practiced and focus did not change yet.
        if (prev_focus) |fcp| {
            if (prev_focus_practiced) {
                const st = self.getStat(fcp) orelse KeyStat{ .cp = fcp };
                self.pushFocusSample(.{
                    .ema_ms = st.ema_ms,
                    .confidence = st.confidence(self.config.target_wpm),
                });
            }
        }

        // 3b. A locked letter mastered in another stage's text is earned:
        // it joins the unlocked letters right away.
        var i = self.unlocked_count;
        while (i < self.unlock_len) : (i += 1) {
            const ch = self.unlock_order[i];
            const st = self.getStat(ch) orelse continue;
            if (!st.mastered) continue;
            std.mem.copyBackwards(u8, self.unlock_order[self.unlocked_count + 1 .. i + 1], self.unlock_order[self.unlocked_count..i]);
            self.unlock_order[self.unlocked_count] = ch;
            self.unlocked_count += 1;
        }

        // 4. Evaluate unlock rule: all active unlocked letters >= 1.0 confidence AND >= 2 rounds cooldown.
        var newly_unlocked: ?u8 = null;
        if (self.unlocked_count < self.unlock_len and self.rounds_since_unlock >= min_rounds_between_unlocks) {
            var all_mastered = self.unlocked_count > 0;
            for (self.activeLetters()) |ch| {
                if (!self.isGreen(ch)) {
                    all_mastered = false;
                    break;
                }
            }
            if (all_mastered) {
                const unlocked_ch = self.unlock_order[self.unlocked_count];
                self.unlocked_count += 1;
                self.rounds_since_unlock = 0;
                newly_unlocked = unlocked_ch;
            }
        }

        // 5. Refresh focus key (resets history if focus key changed).
        self.refreshFocusKey();

        const focus_conf = if (self.focus_cp) |fcp| self.confidenceFor(fcp) else 1.0;
        return .{
            .newly_unlocked = newly_unlocked,
            .focus_cp = self.focus_cp,
            .focus_confidence = focus_conf,
            .forecast_rounds = self.forecast(),
        };
    }

    fn pushFocusSample(self: *LearningModel, sample: FocusSample) void {
        if (self.focus_history_len < focus_history_capacity) {
            self.focus_history[self.focus_history_len] = sample;
            self.focus_history_len += 1;
        } else {
            for (1..focus_history_capacity) |i| {
                self.focus_history[i - 1] = self.focus_history[i];
            }
            self.focus_history[focus_history_capacity - 1] = sample;
        }
    }

    pub fn recordBigramSample(self: *LearningModel, prev: u21, cur: u21, dt_ms: f32) void {
        for (self.bigrams[0..self.bigram_len]) |*entry| {
            if (entry.prev == prev and entry.cur == cur) {
                entry.ema_ms = entry.ema_ms * (1.0 - ema_ms_alpha) + dt_ms * ema_ms_alpha;
                entry.samples += 1;
                return;
            }
        }
        if (self.bigram_len < max_bigrams) {
            self.bigrams[self.bigram_len] = .{
                .prev = prev,
                .cur = cur,
                .ema_ms = dt_ms,
                .samples = 1,
            };
            self.bigram_len += 1;
            return;
        }
        // Bounded capacity: evict lowest-sample (tie-break fastest) entry so real bottlenecks persist.
        var victim: usize = 0;
        for (1..self.bigram_len) |i| {
            const a = self.bigrams[i];
            const b = self.bigrams[victim];
            if (a.samples < b.samples or (a.samples == b.samples and a.ema_ms < b.ema_ms)) {
                victim = i;
            }
        }
        self.bigrams[victim] = .{
            .prev = prev,
            .cur = cur,
            .ema_ms = dt_ms,
            .samples = 1,
        };
    }

    /// Returns up to `out.len` slowest bigrams with at least `min_samples` clean transitions.
    pub fn slowestBigrams(self: *const LearningModel, min_samples: u32, out: []BigramStat) []BigramStat {
        var count: usize = 0;
        for (self.bigrams[0..self.bigram_len]) |entry| {
            if (entry.samples < min_samples) continue;
            // Insert into sorted descending slice `out[0..count]`.
            if (count < out.len) {
                out[count] = entry;
                count += 1;
            } else if (out.len == 0 or entry.ema_ms <= out[count - 1].ema_ms) {
                continue;
            } else {
                out[count - 1] = entry;
            }
            var i = count - 1;
            while (i > 0 and out[i].ema_ms > out[i - 1].ema_ms) : (i -= 1) {
                std.mem.swap(BigramStat, &out[i], &out[i - 1]);
            }
        }
        return out[0..count];
    }

    /// Returns up to `out.len` weakest practiced keys sorted by lowest confidence first.
    pub fn weakestKeys(self: *const LearningModel, out: []KeySummary) []KeySummary {
        var count: usize = 0;
        for (self.stats[0..self.stat_len]) |st| {
            if (st.samples == 0 and !st.acc_initialized) continue;
            // Space is typed between all words; it is not a key to practise.
            if (st.cp == ' ') continue;
            const summary: KeySummary = .{
                .cp = st.cp,
                .confidence = st.confidence(self.config.target_wpm),
                .ema_ms = st.ema_ms,
                .ema_acc = st.ema_acc,
                .samples = st.samples,
            };
            if (count < out.len) {
                out[count] = summary;
                count += 1;
            } else if (out.len == 0 or summary.confidence >= out[count - 1].confidence) {
                continue;
            } else {
                out[count - 1] = summary;
            }
            var i = count - 1;
            while (i > 0 and out[i].confidence < out[i - 1].confidence) : (i -= 1) {
                std.mem.swap(KeySummary, &out[i], &out[i - 1]);
            }
        }
        return out[0..count];
    }

    /// Whether a character has any practice data worth keeping.
    pub fn hasData(self: *const LearningModel, cp: u21) bool {
        const st = self.getStat(cp) orelse return false;
        return st.samples > 0 or st.acc_initialized;
    }

    pub fn knownSlice(self: *const LearningModel) []const KnownPosition {
        return self.known[0..self.known_len];
    }

    /// The position a character was practised at most recently, if any.
    pub fn lastKnownPosition(self: *const LearningModel, cp: u21) ?KnownPosition {
        var i = self.known_len;
        while (i > 0) {
            i -= 1;
            if (self.known[i].pos.cp == cp) return self.known[i];
        }
        return null;
    }

    fn knownIndex(self: *const LearningModel, pos: layout_profile.KeyPosition) ?usize {
        for (self.known[0..self.known_len], 0..) |entry, i| {
            if (entry.pos.eql(pos)) return i;
        }
        return null;
    }

    fn knownCount(self: *const LearningModel, cp: u21) usize {
        var count: usize = 0;
        for (self.known[0..self.known_len]) |entry| {
            if (entry.pos.cp == cp) count += 1;
        }
        return count;
    }

    fn removeKnownAt(self: *LearningModel, index: usize) void {
        std.mem.copyForwards(
            KnownPosition,
            self.known[index .. self.known_len - 1],
            self.known[index + 1 .. self.known_len],
        );
        self.known_len -= 1;
    }

    fn removeKnown(self: *LearningModel, cp: u21) bool {
        var write: usize = 0;
        for (self.known[0..self.known_len]) |entry| {
            if (entry.pos.cp == cp) continue;
            self.known[write] = entry;
            write += 1;
        }
        defer self.known_len = write;
        return write != self.known_len;
    }

    /// Appends a position as the most recent one of its character. A full set
    /// drops the character's oldest position; a full table drops the oldest
    /// entry overall.
    fn pushKnown(self: *LearningModel, entry: KnownPosition) void {
        if (self.knownCount(entry.pos.cp) >= max_positions_per_key) {
            for (self.known[0..self.known_len], 0..) |old, i| {
                if (old.pos.cp == entry.pos.cp) {
                    self.removeKnownAt(i);
                    break;
                }
            }
        }
        if (self.known_len >= max_known_positions) self.removeKnownAt(0);
        self.known[self.known_len] = entry;
        self.known_len += 1;
    }

    /// Takes over the positions of the bound layout without touching any
    /// statistic. A character without practice data simply moves along; a
    /// practised one at a known position becomes its most recent position.
    /// A practised character at an unknown position is left for the user to
    /// decide (see `unconfirmedMoves`). Returns whether a practised
    /// character's positions changed, which is worth saving.
    pub fn adoptPositions(self: *LearningModel, current: []const KnownPosition) bool {
        var changed = false;
        for (current) |cur| {
            const cp = cur.pos.cp;
            if (!self.hasData(cp)) {
                const count = self.knownCount(cp);
                const same = count == 1 and if (self.knownIndex(cur.pos)) |i|
                    std.meta.eql(self.known[i].seen, cur.seen) or cur.seen == null
                else
                    false;
                if (!same) {
                    _ = self.removeKnown(cp);
                    self.pushKnown(cur);
                }
                continue;
            }
            if (self.knownIndex(cur.pos)) |i| {
                var entry = self.known[i];
                const newest = self.lastKnownIndex(cp) == i;
                const seen_changed = cur.seen != null and !std.meta.eql(entry.seen, cur.seen);
                if (newest and !seen_changed) continue;
                if (cur.seen != null) entry.seen = cur.seen;
                self.removeKnownAt(i);
                self.known[self.known_len] = entry;
                self.known_len += 1;
                changed = true;
            } else if (self.knownCount(cp) == 0) {
                // Practised before positions were tracked: nothing to compare with.
                self.pushKnown(cur);
                changed = true;
            }
        }
        // Forget the positions of characters that have neither data nor a route.
        var write: usize = 0;
        for (self.known[0..self.known_len]) |entry| {
            if (!self.hasData(entry.pos.cp) and findCurrent(current, entry.pos.cp) == null) continue;
            self.known[write] = entry;
            write += 1;
        }
        self.known_len = write;
        return changed;
    }

    fn lastKnownIndex(self: *const LearningModel, cp: u21) ?usize {
        var i = self.known_len;
        while (i > 0) {
            i -= 1;
            if (self.known[i].pos.cp == cp) return i;
        }
        return null;
    }

    /// Practised characters that the bound layout puts at a position their
    /// statistics were not made at. Changes nothing.
    pub fn unconfirmedMoves(self: *const LearningModel, current: []const KnownPosition, out: []u21) []u21 {
        var len: usize = 0;
        for (current) |cur| {
            if (len >= out.len) break;
            if (!self.hasData(cur.pos.cp)) continue;
            if (self.knownCount(cur.pos.cp) == 0) continue;
            if (self.knownIndex(cur.pos) != null) continue;
            out[len] = cur.pos.cp;
            len += 1;
        }
        return out[0..len];
    }

    /// Keeps the statistics of `cps` at their current positions: each current
    /// position joins the character's known positions.
    pub fn confirmPositions(self: *LearningModel, cps: []const u21, current: []const KnownPosition) void {
        for (cps) |cp| {
            const cur = findCurrent(current, cp) orelse continue;
            if (self.knownIndex(cur.pos)) |i| {
                if (cur.seen != null) self.known[i].seen = cur.seen;
                continue;
            }
            self.pushKnown(cur);
        }
    }

    /// Starts `cps` over: their statistics and every transition into or out
    /// of them are dropped, and only their current position stays known.
    /// Unlocked letters stay unlocked; since they no longer have full
    /// confidence, they hold back the next unlock until they are mastered
    /// again. Streaks, the daily goal and the run history are untouched.
    pub fn resetKeys(self: *LearningModel, cps: []const u21, current: []const KnownPosition) void {
        if (cps.len == 0) return;
        for (cps) |cp| {
            for (self.stats[0..self.stat_len]) |*st| {
                if (st.cp == cp) st.reset();
            }
            _ = self.removeKnown(cp);
            if (findCurrent(current, cp)) |cur| self.pushKnown(cur);
        }
        self.dropBigramsWith(cps);
        if (self.focus_cp) |fcp| {
            if (containsCp(cps, fcp)) self.focus_history_len = 0;
        }
        self.refreshFocusKey();
    }

    fn dropBigramsWith(self: *LearningModel, cps: []const u21) void {
        var write_idx: usize = 0;
        for (self.bigrams[0..self.bigram_len]) |b| {
            if (containsCp(cps, b.prev) or containsCp(cps, b.cur)) continue;
            self.bigrams[write_idx] = b;
            write_idx += 1;
        }
        self.bigram_len = write_idx;
    }
};

fn letterBit(ch: u8) u32 {
    if (ch < 'a' or ch > 'z') return 0;
    return @as(u32, 1) << @intCast(ch - 'a');
}

fn findCurrent(current: []const KnownPosition, cp: u21) ?KnownPosition {
    for (current) |entry| {
        if (entry.pos.cp == cp) return entry;
    }
    return null;
}

fn containsCp(haystack: []const u21, needle: u21) bool {
    for (haystack) |cp| {
        if (cp == needle) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Deterministic unit tests
// ---------------------------------------------------------------------------

test "motor latency outlier filtering rejects first char, <25ms, >2000ms, post-pause, error, and post-error" {
    const t = std.testing;
    var c: RoundCollector = .{};
    // First char: never produces dt
    c.recordCommit('a', 1_000_000, false);
    // Clean 200ms -> accepted
    c.recordCommit('s', 1_200_000, false);
    // Too fast (10ms < 25ms) -> rejected
    c.recordCommit('d', 1_210_000, false);
    // Too slow (2500ms > 2000ms) -> rejected
    c.recordCommit('f', 3_710_000, false);
    // Clean 300ms after slow outlier -> accepted
    c.recordCommit('s', 4_010_000, false);
    // Pause -> breaks timing chain
    c.notePauseOrBlur();
    c.recordCommit('a', 4_200_000, false);
    // Clean 250ms after post-pause anchor -> accepted
    c.recordCommit('d', 4_450_000, false);
    // Error at 'f' -> rejected, AND breaks timing chain for next char (post-error)
    c.recordCommit('f', 4_650_000, true);
    // Post-error char -> rejected, re-establishes timing anchor
    c.recordCommit('a', 4_850_000, false);
    // Clean 180ms -> accepted
    c.recordCommit('s', 5_030_000, false);

    // Check 's': 3 clean samples (200, 300, 180)
    const sb = c.getOrAddBucket('s').?;
    try t.expectEqual(@as(usize, 3), sb.dt_len);
    try t.expectApproxEqAbs(@as(f32, 200.0), medianF32(sb.dt_ms[0..sb.dt_len]), 0.01);
    // Check 'd': 1 clean sample (250), 2 total positions (both first-try clean)
    const db = c.getOrAddBucket('d').?;
    try t.expectEqual(@as(usize, 1), db.dt_len);
    try t.expectEqual(@as(u32, 2), db.first_try_hits);
    // Check 'f': 0 clean samples, 2 total positions, 1 first-try hit (the second was an error)
    const fb = c.getOrAddBucket('f').?;
    try t.expectEqual(@as(usize, 0), fb.dt_len);
    try t.expectEqual(@as(u32, 2), fb.total_positions);
    try t.expectEqual(@as(u32, 1), fb.first_try_hits);
}

test "accuracy counts only the last 30 presses of a key" {
    const t = std.testing;
    var model = LearningModel.init("asdf", 4, .{});
    // An early round with 3 misses out of 10 presses.
    var c1 = RoundCollector{};
    for (0..10) |i| c1.recordCommit('a', @as(u64, i) * 300_000, i < 3);
    _ = model.completeRound(&c1);
    try t.expectApproxEqAbs(@as(f32, 0.7), model.getStat('a').?.ema_acc, 0.001);
    // Three clean rounds push the misses out of the window entirely.
    for (0..3) |_| {
        var c = RoundCollector{};
        for (0..10) |i| c.recordCommit('a', @as(u64, i) * 300_000, false);
        _ = model.completeRound(&c);
    }
    const st = model.getStat('a').?;
    try t.expectEqual(@as(u8, accuracy_window), st.recent_len);
    try t.expectApproxEqAbs(@as(f32, 1.0), st.ema_acc, 0.001);
    // Two misses in the last 30 still pass the gate, a third does not.
    var two = st;
    two.recordOutcomes(0b00, 2);
    try t.expect(two.ema_acc >= accuracy_gate);
    two.recordOutcomes(0b0, 1);
    try t.expect(two.ema_acc < accuracy_gate);
    // A long round keeps only its newest 30 outcomes.
    var long = KeyStat{ .cp = 'a' };
    var c2 = RoundCollector{};
    for (0..40) |i| c2.recordCommit('a', @as(u64, i) * 300_000, i < 10);
    long.recordOutcomes(c2.buckets[0].recent_hits, accuracy_window);
    try t.expectApproxEqAbs(@as(f32, 1.0), long.ema_acc, 0.001);
}

test "round median, EMA convergence, accuracy gate and sample ramp in confidence formula" {
    const t = std.testing;
    // Median of even count
    try t.expectApproxEqAbs(@as(f32, 250.0), medianF32(&.{ 400.0, 100.0, 300.0, 200.0 }), 0.01);

    // Target 40 WPM => target_ms = 300ms.
    // Accuracy gate: 92% accuracy prevents mastery even at 2x speed (150ms) and 50 samples.
    const low_acc = computeConfidence(150.0, 0.92, 50, 40.0);
    try t.expect(low_acc < 1.0);

    // Sample-count ramp: 10 samples (< 20) prevents mastery even at 2x speed and 100% accuracy.
    const low_samples = computeConfidence(150.0, 1.0, 10, 40.0);
    try t.expectApproxEqAbs(@as(f32, 0.5), low_samples, 0.001);

    // Full mastery: 300ms at 40 WPM, 96% accuracy, 20 samples => 1.0.
    try t.expectApproxEqAbs(@as(f32, 1.0), computeConfidence(300.0, 0.96, 20, 40.0), 0.001);

    // EMA smoothing convergence across rounds
    var model = LearningModel.init("asdf", 2, .{ .target_wpm = 40.0 });
    var c1: RoundCollector = .{};
    c1.recordCommit('a', 1_000_000, false);
    c1.recordCommit('a', 1_400_000, false); // 400ms
    _ = model.completeRound(&c1);
    try t.expectApproxEqAbs(@as(f32, 400.0), model.getStat('a').?.ema_ms, 0.01);

    var c2: RoundCollector = .{};
    c2.recordCommit('a', 1_000_000, false);
    c2.recordCommit('a', 1_200_000, false); // 200ms => 400*0.75 + 200*0.25 = 350ms
    _ = model.completeRound(&c2);
    try t.expectApproxEqAbs(@as(f32, 350.0), model.getStat('a').?.ema_ms, 0.01);
}

test "unlock cadence requires >= 2 rounds cooldown and strictly 1 new key per unlock" {
    const t = std.testing;
    var model = LearningModel.init("asdfg", 2, .{ .target_wpm = 30.0 }); // target_ms = 400ms
    try t.expectEqual(@as(usize, 2), model.unlocked_count);

    // Round 1: high-speed clean typing of 'a' and 's' (22 clean samples each, 200ms each)
    var c: RoundCollector = .{};
    var ts: u64 = 1_000_000;
    c.recordCommit('a', ts, false);
    for (0..22) |_| {
        ts += 200_000;
        c.recordCommit('a', ts, false);
        ts += 200_000;
        c.recordCommit('s', ts, false);
    }
    const r1 = model.completeRound(&c);
    // All active keys have confidence 1.0, but only 1 round since start (< 2 cooldown).
    try t.expectApproxEqAbs(@as(f32, 1.0), model.confidenceFor('a'), 0.001);
    try t.expectApproxEqAbs(@as(f32, 1.0), model.confidenceFor('s'), 0.001);
    try t.expectEqual(@as(?u8, null), r1.newly_unlocked);
    try t.expectEqual(@as(usize, 2), model.unlocked_count);

    // Round 2: cooldown met -> unlocks strictly 1 key ('d').
    const r2 = model.completeRound(&c);
    try t.expectEqual(@as(?u8, 'd'), r2.newly_unlocked);
    try t.expectEqual(@as(usize, 3), model.unlocked_count);
    try t.expectEqual(@as(?u21, 'd'), model.focus_cp);
    try t.expectEqual(@as(u32, 0), model.rounds_since_unlock);
}

test "linear regression forecast enforces R^2 >= 0.5 and rejects flat or noisy data" {
    const t = std.testing;
    // Steady upward ramp: 0.4 -> 0.55 -> 0.7 -> 0.85 (slope = 0.15/round, R^2 = 1.0) => 1 round left.
    const steady = [_]FocusSample{
        .{ .ema_ms = 450, .confidence = 0.40 },
        .{ .ema_ms = 400, .confidence = 0.55 },
        .{ .ema_ms = 350, .confidence = 0.70 },
        .{ .ema_ms = 310, .confidence = 0.85 },
    };
    try t.expectEqual(@as(?u32, 1), forecastRoundsToUnlock(&steady));

    // Too few points (< 3)
    try t.expectEqual(@as(?u32, null), forecastRoundsToUnlock(steady[0..2]));

    // Flat data
    const flat = [_]FocusSample{
        .{ .ema_ms = 400, .confidence = 0.5 },
        .{ .ema_ms = 400, .confidence = 0.5 },
        .{ .ema_ms = 400, .confidence = 0.5 },
    };
    try t.expectEqual(@as(?u32, null), forecastRoundsToUnlock(&flat));

    // Noisy data (R^2 < 0.5)
    const noisy = [_]FocusSample{
        .{ .ema_ms = 400, .confidence = 0.70 },
        .{ .ema_ms = 500, .confidence = 0.30 },
        .{ .ema_ms = 350, .confidence = 0.80 },
        .{ .ema_ms = 480, .confidence = 0.35 },
        .{ .ema_ms = 390, .confidence = 0.72 },
    };
    try t.expectEqual(@as(?u32, null), forecastRoundsToUnlock(&noisy));
}

test "bounded bigram top-3 ranking" {
    const t = std.testing;
    var model = LearningModel.init("asdf", 4, .{ .target_wpm = 35.0 });
    for (0..4) |_| {
        model.recordBigramSample('a', 's', 180.0);
        model.recordBigramSample('s', 'd', 420.0);
        model.recordBigramSample('d', 'f', 310.0);
        model.recordBigramSample('f', 'a', 510.0);
    }
    model.recordBigramSample('a', 'f', 900.0); // only 1 sample (< min_samples=3)

    var top: [3]BigramStat = undefined;
    const slowest = model.slowestBigrams(3, &top);
    try t.expectEqual(@as(usize, 3), slowest.len);
    try t.expectEqual(@as(u21, 'f'), slowest[0].prev);
    try t.expectEqual(@as(u21, 'a'), slowest[0].cur);
    try t.expectEqual(@as(u21, 's'), slowest[1].prev);
    try t.expectEqual(@as(u21, 'd'), slowest[1].cur);
    try t.expectEqual(@as(u21, 'd'), slowest[2].prev);
    try t.expectEqual(@as(u21, 'f'), slowest[2].cur);
}

test "an edited layout replaces the unlock order and keeps the unlocked count" {
    const t = std.testing;
    var model = LearningModel.init("asdfjkle", 6, .{});
    try t.expectEqualStrings("asdfjk", model.activeLetters());
    // 'f' can no longer be typed and 'e' moved forward.
    model.setUnlockOrder("asdejkl");
    try t.expectEqualStrings("asdejk", model.activeLetters());
    try t.expect(model.unlockedMask() & (@as(u32, 1) << ('f' - 'a')) == 0);
    // A shorter order clamps the count.
    model.setUnlockOrder("as");
    try t.expectEqualStrings("as", model.activeLetters());
}

fn testPos(cp: u21, slot: u16, combo_slot: ?u16) KnownPosition {
    return .{ .pos = .{ .cp = cp, .layer = 0, .slot = slot, .shift = false, .combo_slot = combo_slot } };
}

fn practised(model: *LearningModel, cp: u21) void {
    model.getOrAddStat(cp).?.* = .{ .cp = cp, .ema_ms = 250.0, .ema_acc = 0.98, .samples = 25, .acc_initialized = true };
}

test "a moved key keeps its statistics and is reported once per new position" {
    const t = std.testing;
    var model = LearningModel.init("asz", 3, .{});
    practised(&model, 'a');
    practised(&model, 'z');
    const board_a = [_]KnownPosition{ testPos('a', 10, null), testPos('s', 11, null), testPos('z', 20, null) };
    // 'z' becomes a combo, the unpractised 's' moves as well.
    const board_b = [_]KnownPosition{ testPos('a', 10, null), testPos('s', 12, null), testPos('z', 21, 22) };
    try t.expect(model.adoptPositions(&board_a));
    var buf: [8]u21 = undefined;
    try t.expectEqual(@as(usize, 0), model.unconfirmedMoves(&board_a, &buf).len);

    _ = model.adoptPositions(&board_b);
    try t.expectEqualSlices(u21, &.{'z'}, model.unconfirmedMoves(&board_b, &buf));
    try t.expectEqual(@as(u32, 25), model.getStat('z').?.samples);
    try t.expectEqual(@as(u16, 20), model.lastKnownPosition('z').?.pos.slot);

    // Keeping it makes both keyboards known: switching back and forth stays quiet.
    model.confirmPositions(&.{'z'}, &board_b);
    const before = model.stats;
    for (0..3) |_| {
        _ = model.adoptPositions(&board_a);
        try t.expectEqual(@as(usize, 0), model.unconfirmedMoves(&board_a, &buf).len);
        try t.expectEqual(@as(u16, 20), model.lastKnownPosition('z').?.pos.slot);
        _ = model.adoptPositions(&board_b);
        try t.expectEqual(@as(usize, 0), model.unconfirmedMoves(&board_b, &buf).len);
        try t.expectEqual(@as(?u16, 22), model.lastKnownPosition('z').?.pos.combo_slot);
    }
    try t.expectEqualSlices(KeyStat, before[0..model.stat_len], model.stats[0..model.stat_len]);
}

test "a per-character reset clears statistics and transitions but keeps the unlock" {
    const t = std.testing;
    var model = LearningModel.init("asdf", 3, .{ .target_wpm = 30.0 });
    for ("asd") |ch| practised(&model, ch);
    model.recordBigramSample('a', 's', 200.0);
    model.recordBigramSample('s', 'd', 200.0);
    model.recordBigramSample('d', 'a', 200.0);
    const board = [_]KnownPosition{ testPos('a', 1, null), testPos('s', 2, null), testPos('d', 3, null) };
    _ = model.adoptPositions(&board);
    // Fast, accurate rounds make every active letter fully confident.
    var c: RoundCollector = .{};
    var ts: u64 = 1_000_000;
    c.recordCommit('a', ts, false);
    for (0..22) |_| for ("asd") |ch| {
        ts += 200_000;
        c.recordCommit(ch, ts, false);
    };
    _ = model.completeRound(&c);
    const focus_before = model.focus_cp;
    try t.expect(focus_before != null);

    model.resetKeys(&.{'s'}, &board);
    try t.expectEqual(@as(u32, 0), model.getStat('s').?.samples);
    try t.expect(!model.hasData('s'));
    try t.expect(model.hasData('a'));
    for (model.bigrams[0..model.bigram_len]) |b| {
        try t.expect(b.prev != 's' and b.cur != 's');
    }
    // Other transitions stay.
    var kept_da = false;
    for (model.bigrams[0..model.bigram_len]) |b| kept_da = kept_da or (b.prev == 'd' and b.cur == 'a');
    try t.expect(kept_da);
    try t.expectEqual(@as(?u21, 's'), model.focus_cp);
    try t.expectEqual(@as(usize, 0), model.focus_history_len);
    try t.expectEqual(@as(usize, 3), model.unlocked_count);

    // The reset letter holds back the next unlock until it is mastered again.
    var only_ad: RoundCollector = .{};
    ts = 1_000_000;
    only_ad.recordCommit('a', ts, false);
    for (0..22) |_| for ("ad") |ch| {
        ts += 200_000;
        only_ad.recordCommit(ch, ts, false);
    };
    for (0..3) |_| try t.expectEqual(@as(?u8, null), model.completeRound(&only_ad).newly_unlocked);
    try t.expectEqual(@as(?u8, 'f'), model.completeRound(&c).newly_unlocked);
}

test "keys the layout cannot produce stay untouched and a full position set drops the oldest" {
    const t = std.testing;
    var model = LearningModel.init("az", 2, .{});
    practised(&model, 'z');
    var buf: [4]u21 = undefined;
    _ = model.adoptPositions(&.{testPos('z', 1, null)});
    // Not producible: never reported, statistics stay.
    const without_z = [_]KnownPosition{testPos('a', 5, null)};
    _ = model.adoptPositions(&without_z);
    try t.expectEqual(@as(usize, 0), model.unconfirmedMoves(&without_z, &buf).len);
    try t.expectEqual(@as(u32, 25), model.getStat('z').?.samples);
    try t.expect(model.lastKnownPosition('z') != null);
    // Back at its known position: quiet.
    try t.expectEqual(@as(usize, 0), model.unconfirmedMoves(&.{testPos('z', 1, null)}, &buf).len);

    for (2..7) |slot| model.confirmPositions(&.{'z'}, &.{testPos('z', @intCast(slot), null)});
    var count: usize = 0;
    for (model.knownSlice()) |entry| {
        if (entry.pos.cp == 'z') count += 1;
    }
    try t.expectEqual(max_positions_per_key, count);
    try t.expectEqualSlices(u21, &.{'z'}, model.unconfirmedMoves(&.{testPos('z', 1, null)}, &buf));
    try t.expectEqual(@as(usize, 0), model.unconfirmedMoves(&.{testPos('z', 6, null)}, &buf).len);
}

test "the newest seen keys of a known position follow the keyboard" {
    const t = std.testing;
    var model = LearningModel.init("z", 1, .{});
    practised(&model, 'z');
    var on_a = testPos('z', 1, null);
    on_a.seen = .{ .board = boardHash("a"), .key_index = 4 };
    var on_b = testPos('z', 1, null);
    on_b.seen = .{ .board = boardHash("b"), .key_index = 9 };
    try t.expect(model.adoptPositions(&.{on_a}));
    try t.expect(!model.adoptPositions(&.{on_a}));
    try t.expect(model.adoptPositions(&.{on_b}));
    try t.expectEqual(@as(u16, 9), model.lastKnownPosition('z').?.seen.?.key_index);
    // A layout without board details keeps what was seen.
    try t.expect(!model.adoptPositions(&.{testPos('z', 1, null)}));
    try t.expectEqual(boardHash("b"), model.lastKnownPosition('z').?.seen.?.board);
}

test "a mastered letter stays green and unlocked and leaves the focus to the others" {
    const t = std.testing;
    var lm = LearningModel.init("esa", 3, .{ .target_wpm = 20 });
    // 'e' becomes fully confident once.
    const e = lm.getOrAddStat('e').?;
    e.* = .{ .cp = 'e', .ema_ms = 300, .samples = 30 };
    e.recordOutcomes(0x3fff_ffff, 30);
    var collector: RoundCollector = .{};
    collector.recordCommit('e', 1_000_000, false);
    _ = lm.completeRound(&collector);
    try t.expect(lm.getStat('e').?.mastered);
    // Later misses and slow presses do not take it back.
    lm.getOrAddStat('e').?.recordOutcomes(0, 10);
    lm.getOrAddStat('e').?.ema_ms = 900;
    try t.expect(lm.isGreen('e'));
    try t.expect(lm.computeFocusKey().? != 'e');

    // A new order keeps the unlocked and mastered letters unlocked.
    lm.adoptOrder("rtlesa", 2);
    try t.expectEqualStrings("rtesa", lm.activeLetters());
    try t.expectEqualStrings("rt", lm.firstLetters());
    lm.getOrAddStat('e').?.reset();
    try t.expect(!lm.isGreen('e'));
}
