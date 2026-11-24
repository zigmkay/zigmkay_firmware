//! What a single key still needs before it counts as mastered: enough
//! presses, enough first-try hits in its recent window, and the target speed.
//! Shared by the confidence strip, the round rundown and the stuck help so
//! they all speak about a key in the same terms.
const std = @import("std");
const model = @import("practice_model.zig");

pub const Blocker = enum { none, presses, hits, speed };

pub const KeyProgress = struct {
    wpm: f32,
    target_wpm: f32,
    /// Fraction of the target speed reached, capped at 1.
    speed_fraction: f32,
    /// First-try hits within the last `window` presses.
    hits: u8,
    window: u8,
    /// Hits the current window needs to pass the accuracy gate.
    hits_needed: u8,
    presses: u32,
    mastered: bool,
    blocker: Blocker,

    pub fn speedOk(self: KeyProgress) bool {
        return self.speed_fraction >= 1.0;
    }

    pub fn hitsOk(self: KeyProgress) bool {
        return self.hits >= self.hits_needed;
    }

    pub fn pressesOk(self: KeyProgress) bool {
        return self.presses >= model.min_samples_for_mastery;
    }

    pub fn hitFraction(self: KeyProgress) f32 {
        if (self.window == 0) return 0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(self.window));
    }
};

fn needed(window: u8) u8 {
    const raw = model.accuracy_gate * @as(f32, @floatFromInt(window));
    return @intFromFloat(@ceil(raw - 0.0001));
}

pub fn of(st: model.KeyStat, target_wpm: f32) KeyProgress {
    // Saves from before the 30-press window only carry a smoothed accuracy;
    // show it on the same 30-press scale until the key is typed again.
    const window: u8 = if (st.recent_len > 0) st.recent_len else if (st.acc_initialized) model.accuracy_window else 0;
    const hits: u8 = if (st.recent_len > 0)
        @intCast(@popCount(st.recent_hits & windowMask(st.recent_len)))
    else if (st.acc_initialized)
        @intFromFloat(@round(std.math.clamp(st.ema_acc, 0, 1) * @as(f32, @floatFromInt(model.accuracy_window))))
    else
        0;
    const wpm = st.wpm();
    const speed_fraction: f32 = if (target_wpm > 0) @min(1.0, wpm / target_wpm) else 0;
    const mastered = st.confidence(target_wpm) >= 1.0;
    var p: KeyProgress = .{
        .wpm = wpm,
        .target_wpm = target_wpm,
        .speed_fraction = speed_fraction,
        .hits = hits,
        .window = window,
        .hits_needed = needed(window),
        .presses = st.samples,
        .mastered = mastered,
        .blocker = .none,
    };
    if (!mastered) {
        p.blocker = if (!p.pressesOk())
            .presses
        else if (window == 0 or !p.hitsOk())
            .hits
        else
            .speed;
    }
    return p;
}

fn windowMask(len: u8) u32 {
    if (len >= 32) return std.math.maxInt(u32);
    return (@as(u32, 1) << @as(u5, @intCast(len))) - 1;
}

/// Clean presses in a row that would bring the key over the accuracy gate,
/// or null when even a full clean window would not be enough.
pub fn cleanPressesToGo(st: model.KeyStat) ?u8 {
    var hits = st.recent_hits;
    var len = st.recent_len;
    var n: u8 = 0;
    while (n <= model.accuracy_window) : (n += 1) {
        if (len > 0) {
            const count: u8 = @intCast(@popCount(hits & windowMask(len)));
            if (count >= needed(len)) return n;
        }
        hits = ((hits << 1) | 1) & windowMask(model.accuracy_window);
        len = @min(model.accuracy_window, len + 1);
    }
    return null;
}

/// Presses until the oldest miss still in the window stops counting, or
/// null when the window holds no miss.
pub fn oldestMissLeavesIn(st: model.KeyStat) ?u8 {
    const misses = ~st.recent_hits & windowMask(st.recent_len);
    if (misses == 0) return null;
    const oldest: u8 = 31 - @as(u8, @clz(misses));
    return model.accuracy_window - oldest;
}

test "progress names the first thing a key still needs" {
    const t = std.testing;
    var st = model.KeyStat{ .cp = 'f', .ema_ms = 340, .samples = 56, .acc_initialized = true };
    // 26 hits in the last 30 presses at 35 WPM against a 20 WPM target.
    st.recordOutcomes(0x3fff_ffff, 26);
    st.recordOutcomes(0b0000, 4);
    var p = of(st, 20);
    try t.expectEqual(@as(u8, 26), p.hits);
    try t.expectEqual(@as(u8, 28), p.hits_needed);
    try t.expect(p.speedOk());
    try t.expectEqual(Blocker.hits, p.blocker);
    // The four misses are the newest presses: a clean press only pushes out
    // an old hit until the misses themselves age out of the window.
    try t.expectEqual(@as(?u8, 28), cleanPressesToGo(st));
    try t.expectEqual(@as(?u8, 27), oldestMissLeavesIn(st));

    st.samples = 12;
    p = of(st, 20);
    try t.expectEqual(Blocker.presses, p.blocker);

    var slow = model.KeyStat{ .cp = 'd', .ema_ms = 750, .samples = 70, .acc_initialized = true };
    slow.recordOutcomes(0x3fff_ffff, 30);
    p = of(slow, 20);
    try t.expectEqual(Blocker.speed, p.blocker);
    try t.expectApproxEqAbs(@as(f32, 0.8), p.speed_fraction, 0.001);
    try t.expectEqual(@as(?u8, 0), cleanPressesToGo(slow));
}

test "an old save without a press window shows its smoothed accuracy on the 30-press scale" {
    const t = std.testing;
    const st = model.KeyStat{ .cp = 'k', .ema_ms = 214, .ema_acc = 0.852, .samples = 85, .acc_initialized = true };
    const p = of(st, 20);
    try t.expectEqual(@as(u8, 30), p.window);
    try t.expectEqual(@as(u8, 26), p.hits);
    try t.expectEqual(Blocker.hits, p.blocker);
}
