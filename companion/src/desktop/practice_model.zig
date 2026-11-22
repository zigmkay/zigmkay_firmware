//! Clean-room adaptive per-key learning model for the Zigmkay typing tutor.
//! Tracks filtered motor latencies, per-key EMA speed and first-try accuracy,
//! confidence scores, sequential unlock cadence, linear-regression forecasts,
//! bounded bigram bottlenecks, and layout-diff partial resets.
const std = @import("std");
const layout_profile = @import("practice_layout_profile.zig");

pub const Language = enum(u8) {
    en,
};

pub const min_clean_dt_us: u64 = 25_000; // 25 ms
pub const max_clean_dt_us: u64 = 2_000_000; // 2000 ms
pub const ema_ms_alpha: f32 = 0.25;
pub const ema_acc_alpha: f32 = 0.20;
pub const accuracy_gate: f32 = 0.95;
pub const min_samples_for_mastery: u32 = 20;
pub const min_rounds_between_unlocks: u32 = 2;
pub const focus_history_capacity: usize = 10;
pub const max_tracked_keys: usize = 96;
pub const max_bigrams: usize = 256;
pub const max_round_samples_per_key: usize = 64;
pub const max_round_keys: usize = 64;
pub const max_round_bigrams: usize = 256;

pub const KeyStat = struct {
    cp: u21 = 0,
    ema_ms: f32 = 0.0,
    ema_acc: f32 = 0.0,
    samples: u32 = 0,
    acc_initialized: bool = false,

    pub fn confidence(self: KeyStat, target_wpm: f32) f32 {
        return computeConfidence(self.ema_ms, self.ema_acc, self.samples, target_wpm);
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
    target_wpm: f32 = 35.0,
};

pub const RoundOutcome = struct {
    newly_unlocked: ?u8 = null,
    focus_cp: ?u21 = null,
    focus_confidence: f32 = 0.0,
    forecast_rounds: ?u32 = null,
};

/// Computes per-key confidence in [0.0, 1.0].
/// Accuracy below 95% and sample counts below 20 cannot reach 1.0 mastery
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
    rounds_since_unlock: u32 = 0,
    total_rounds: u32 = 0,

    stats: [max_tracked_keys]KeyStat = @splat(.{}),
    stat_len: usize = 0,

    focus_cp: ?u21 = null,
    focus_history: [focus_history_capacity]FocusSample = undefined,
    focus_history_len: usize = 0,

    bigrams: [max_bigrams]BigramStat = undefined,
    bigram_len: usize = 0,

    pub fn init(unlock_order: []const u8, initial_unlocked: usize, config: ModelConfig) LearningModel {
        var model: LearningModel = .{
            .config = config,
            .unlock_len = @min(unlock_order.len, 26),
        };
        @memcpy(model.unlock_order[0..model.unlock_len], unlock_order[0..model.unlock_len]);
        model.unlocked_count = @min(initial_unlocked, model.unlock_len);
        model.refreshFocusKey();
        return model;
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

    /// Selects the active unlocked letter with lowest confidence, breaking ties
    /// by fewest samples, then unlock order.
    pub fn computeFocusKey(self: *const LearningModel) ?u21 {
        const active = self.activeLetters();
        if (active.len == 0) return null;
        var best_cp: u21 = active[0];
        var best_conf: f32 = 2.0;
        var best_samples: u32 = std.math.maxInt(u32);
        for (active) |ch| {
            const st = self.getStat(ch) orelse KeyStat{ .cp = ch };
            const conf = st.confidence(self.config.target_wpm);
            const better = (conf < best_conf - 1e-6) or
                (@abs(conf - best_conf) <= 1e-6 and st.samples < best_samples);
            if (better) {
                best_cp = ch;
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
            const round_acc: f32 = @as(f32, @floatFromInt(b.first_try_hits)) /
                @as(f32, @floatFromInt(b.total_positions));
            if (!st.acc_initialized) {
                st.ema_acc = round_acc;
                st.acc_initialized = true;
            } else {
                st.ema_acc = st.ema_acc * (1.0 - ema_acc_alpha) + round_acc * ema_acc_alpha;
            }

            if (b.dt_len > 0) {
                const med_ms = medianF32(b.dt_ms[0..b.dt_len]);
                if (st.ema_ms <= 0.0) {
                    st.ema_ms = med_ms;
                } else {
                    st.ema_ms = st.ema_ms * (1.0 - ema_ms_alpha) + med_ms * ema_ms_alpha;
                }
                st.samples += @intCast(b.dt_len);
            }
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

        // 4. Evaluate unlock rule: all active unlocked letters >= 1.0 confidence AND >= 2 rounds cooldown.
        var newly_unlocked: ?u8 = null;
        if (self.unlocked_count < self.unlock_len and self.rounds_since_unlock >= min_rounds_between_unlocks) {
            var all_mastered = self.unlocked_count > 0;
            for (self.activeLetters()) |ch| {
                if (self.confidenceFor(ch) < 1.0) {
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

    /// Layout-diff partial reset: preserves stats for characters whose physical route
    /// did not change, and resets stats (plus affected bigrams) for characters that moved.
    /// Returns the number of characters reset.
    pub fn applyLayoutDiff(
        self: *LearningModel,
        prev_positions: []const layout_profile.KeyPosition,
        cur_positions: []const layout_profile.KeyPosition,
    ) usize {
        var moved_cps: [max_tracked_keys]u21 = undefined;
        var moved_len: usize = 0;

        for (self.stats[0..self.stat_len]) |*st| {
            const prev_pos = findPosition(prev_positions, st.cp);
            const cur_pos = findPosition(cur_positions, st.cp);
            const unchanged = if (prev_pos != null and cur_pos != null)
                prev_pos.?.eql(cur_pos.?)
            else
                false;
            if (!unchanged) {
                st.reset();
                if (moved_len < moved_cps.len) {
                    moved_cps[moved_len] = st.cp;
                    moved_len += 1;
                }
            }
        }

        // Remove bigrams referencing any moved character.
        if (moved_len > 0) {
            var write_idx: usize = 0;
            for (self.bigrams[0..self.bigram_len]) |b| {
                if (!containsCp(moved_cps[0..moved_len], b.prev) and
                    !containsCp(moved_cps[0..moved_len], b.cur))
                {
                    self.bigrams[write_idx] = b;
                    write_idx += 1;
                }
            }
            self.bigram_len = write_idx;

            if (self.focus_cp) |fcp| {
                if (containsCp(moved_cps[0..moved_len], fcp)) {
                    self.focus_history_len = 0;
                }
            }
            self.refreshFocusKey();
        }

        return moved_len;
    }
};

fn findPosition(positions: []const layout_profile.KeyPosition, cp: u21) ?layout_profile.KeyPosition {
    for (positions) |pos| {
        if (pos.cp == cp) return pos;
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

test "round median, EMA convergence, accuracy gate and sample ramp in confidence formula" {
    const t = std.testing;
    // Median of even count
    try t.expectApproxEqAbs(@as(f32, 250.0), medianF32(&.{ 400.0, 100.0, 300.0, 200.0 }), 0.01);

    // Target 40 WPM => target_ms = 300ms.
    // Accuracy gate: 94% accuracy prevents mastery even at 2x speed (150ms) and 50 samples.
    const low_acc = computeConfidence(150.0, 0.94, 50, 40.0);
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

test "bounded bigram top-3 ranking and layout-diff partial reset" {
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

    // Populate stats for 'a' and 's', then move only 's' in layout diff.
    model.getOrAddStat('a').?.* = .{ .cp = 'a', .ema_ms = 250.0, .ema_acc = 0.98, .samples = 25, .acc_initialized = true };
    model.getOrAddStat('s').?.* = .{ .cp = 's', .ema_ms = 260.0, .ema_acc = 0.97, .samples = 25, .acc_initialized = true };

    const prev_pos = [_]layout_profile.KeyPosition{
        .{ .cp = 'a', .layer = 0, .key_index = 10, .shift = false },
        .{ .cp = 's', .layer = 0, .key_index = 11, .shift = false },
    };
    const cur_pos = [_]layout_profile.KeyPosition{
        .{ .cp = 'a', .layer = 0, .key_index = 10, .shift = false },
        .{ .cp = 's', .layer = 0, .key_index = 12, .shift = false }, // moved!
    };
    const reset_count = model.applyLayoutDiff(&prev_pos, &cur_pos);
    try t.expectEqual(@as(usize, 1), reset_count);
    // 'a' preserved, 's' reset.
    try t.expectEqual(@as(u32, 25), model.getStat('a').?.samples);
    try t.expectEqual(@as(u32, 0), model.getStat('s').?.samples);
    try t.expectApproxEqAbs(@as(f32, 0.0), model.getStat('s').?.ema_ms, 0.001);
    // Bigrams involving 's' were cleared, 'd'->'f' and 'f'->'a' remain.
    const after = model.slowestBigrams(3, &top);
    try t.expectEqual(@as(usize, 2), after.len);
    try t.expectEqual(@as(u21, 'f'), after[0].prev);
    try t.expectEqual(@as(u21, 'd'), after[1].prev);
}
