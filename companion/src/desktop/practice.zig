//! Hardware-free, bounded Unicode copy practice. Times are monotonic microseconds.
//! Supports Stop-on-error (default for Stages 1-5) and Flow+Backspace modes,
//! clean motor-latency collection, hesitation tracking, and extended Shift/Layer/
//! One-Shot/Combo guidance.
const std = @import("std");
const layout_profile = @import("practice_layout_profile.zig");
const model = @import("practice_model.zig");

pub const State = enum { ready, running, paused, complete };
pub const Source = enum { os, draft };
pub const ErrorMode = enum { stop_on_error, flow_backspace };

/// The arrival time the platform layer recorded for the DVUI event `number`.
pub const EventTime = struct { number: u16, now_us: u64 };
pub const route_modifiers = [_]u8{ 0, 2, 4, 6, 64, 66 };
pub const hesitation_threshold_us: u64 = 1_000_000; // 1.0 s

pub const lessons = [_][]const u8{
    \\const std = @import("std");
    \\
    \\fn twice(value: i32) i32 {
    \\    return value * 2;
    \\}
    \\
    \\fn distance(a: i32, b: i32) u32 {
    \\    return @intCast(@abs(a - b));
    \\}
    \\
    \\test "small functions" {
    \\    try std.testing.expectEqual(@as(i32, 14), twice(7));
    \\    try std.testing.expectEqual(@as(i32, -6), twice(-3));
    \\    try std.testing.expectEqual(@as(u32, 9), distance(2, 11));
    \\    try std.testing.expectEqual(@as(u32, 0), distance(4, 4));
    \\}
    \\
    ,
    \\const std = @import("std");
    \\
    \\const Scores = struct {
    \\    values: [4]u16,
    \\
    \\    fn total(self: Scores) u32 {
    \\        var sum: u32 = 0;
    \\        for (self.values) |value| {
    \\            sum += value;
    \\        }
    \\        return sum;
    \\    }
    \\};
    \\
    \\test "sum an array" {
    \\    const scores = Scores{ .values = .{ 3, 5, 8, 13 } };
    \\    try std.testing.expectEqual(@as(u32, 29), scores.total());
    \\}
    \\
    ,
    \\const std = @import("std");
    \\
    \\fn readCount(text: ?[]const u8) !u16 {
    \\    const value = text orelse return error.MissingCount;
    \\    return std.fmt.parseInt(u16, value, 10);
    \\}
    \\
    \\fn defaultCount(text: ?[]const u8) u16 {
    \\    return readCount(text) catch 1;
    \\}
    \\
    \\test "optional input and errors" {
    \\    try std.testing.expectEqual(@as(u16, 12), try readCount("12"));
    \\    try std.testing.expectError(error.MissingCount, readCount(null));
    \\    try std.testing.expectEqual(@as(u16, 1), defaultCount(null));
    \\    try std.testing.expectEqual(@as(u16, 1), defaultCount("bad"));
    \\}
    \\
};

pub const lesson_names = [_][]const u8{
    "Functions and tests",
    "Arrays and a struct",
    "Errors and optionals",
};

pub const Session = struct {
    reference: [8192]u21 = undefined,
    reference_len: usize = 0,
    typed: [8192]u21 = undefined,
    len: usize = 0,
    state: State = .ready,
    source: Source = .os,
    error_mode: ErrorMode = .stop_on_error,
    attempts: usize = 0,
    correct_attempts: usize = 0,
    corrected: usize = 0,
    error_count: usize = 0,
    current_error: bool = false,
    position_had_error: bool = false,
    last_wrong_cp: ?u21 = null,
    last_error_us: ?u64 = null,
    scored: bool = true,
    started: ?u64 = null,
    segment: u64 = 0,
    active_us: u64 = 0,
    last_event_us: ?u64 = null,
    previous_cr: bool = false,
    collector: model.RoundCollector = .{},

    pub fn load(self: *Session, bytes: []const u8, source: Source) !void {
        try self.loadWithMode(bytes, source, self.error_mode);
    }

    pub fn loadWithMode(self: *Session, bytes: []const u8, source: Source, error_mode: ErrorMode) !void {
        var view = try std.unicode.Utf8View.init(bytes);
        var it = view.iterator();
        var count: usize = 0;
        var previous_reference_cr = false;
        while (it.nextCodepoint()) |raw| {
            if (raw == '\n' and previous_reference_cr) {
                previous_reference_cr = false;
                continue;
            }
            previous_reference_cr = raw == '\r';
            const cp: u21 = if (raw == '\r') '\n' else raw;
            if (count == self.reference.len) return error.ExerciseTooLong;
            self.reference[count] = cp;
            count += 1;
        }
        self.reference_len = count;
        self.source = source;
        self.error_mode = error_mode;
        self.restart();
    }

    pub fn restart(self: *Session) void {
        self.len = 0;
        self.state = .ready;
        self.attempts = 0;
        self.correct_attempts = 0;
        self.corrected = 0;
        self.error_count = 0;
        self.current_error = false;
        self.position_had_error = false;
        self.last_wrong_cp = null;
        self.last_error_us = null;
        self.scored = true;
        self.started = null;
        self.active_us = 0;
        self.last_event_us = null;
        self.previous_cr = false;
        self.collector.reset();
    }

    pub fn insert(self: *Session, bytes: []const u8, now: u64, paste: bool) !void {
        if (self.state == .paused or self.state == .complete) return;
        const view = try std.unicode.Utf8View.init(bytes);
        if (paste) {
            self.scored = false;
            self.collector.notePauseOrBlur();
        }
        var it = view.iterator();
        while (it.nextCodepoint()) |raw| {
            // A CR LF pair is one newline, also across separate inserts.
            if (raw == '\n' and self.previous_cr) {
                self.previous_cr = false;
                continue;
            }
            self.previous_cr = raw == '\r';
            const cp: u21 = if (raw == '\r') '\n' else raw;

            if (self.error_mode == .stop_on_error) {
                if (self.len >= self.reference_len) break;
                const expected = self.reference[self.len];
                if (self.state == .ready) {
                    // First matching keystroke starts the clock automatically.
                    if (cp != expected) {
                        self.attempts += 1;
                        self.error_count += 1;
                        self.current_error = true;
                        self.position_had_error = true;
                        self.last_wrong_cp = cp;
                        self.last_error_us = now;
                        self.last_event_us = now;
                        continue;
                    }
                    self.state = .running;
                    self.started = now;
                    self.segment = now;
                }

                self.attempts += 1;
                self.last_event_us = now;

                if (cp != expected) {
                    self.error_count += 1;
                    self.current_error = true;
                    self.position_had_error = true;
                    self.last_wrong_cp = cp;
                    self.last_error_us = now;
                    continue;
                }

                // Matching keystroke advances the cursor.
                self.correct_attempts += 1;
                if (self.current_error) self.corrected += 1;
                const had_err = self.position_had_error;
                self.current_error = false;
                self.position_had_error = false;
                self.last_wrong_cp = null;

                if (self.scored) {
                    self.collector.recordCommit(expected, now, had_err);
                }

                self.typed[self.len] = cp;
                self.len += 1;
                if (self.len == self.reference_len) {
                    self.active_us += now -| self.segment;
                    self.state = .complete;
                    break;
                }
            } else {
                // Legacy flow_backspace mode retained for opt-in / existing test coverage.
                if (self.len == self.typed.len) return error.TextLimit;
                if (self.state == .ready) {
                    self.state = .running;
                    self.started = now;
                    self.segment = now;
                }
                self.attempts += 1;
                self.last_event_us = now;
                const is_match = self.len < self.reference_len and self.reference[self.len] == cp;
                if (is_match) {
                    self.correct_attempts += 1;
                    if (self.scored) self.collector.recordCommit(cp, now, self.position_had_error);
                    self.position_had_error = false;
                } else {
                    self.error_count += 1;
                    self.position_had_error = true;
                    self.last_wrong_cp = cp;
                    self.last_error_us = now;
                    self.collector.notePauseOrBlur();
                }
                self.typed[self.len] = cp;
                self.len += 1;
                if (self.len == self.reference_len and
                    std.mem.eql(u21, self.typed[0..self.len], self.reference[0..self.reference_len]))
                {
                    self.active_us += now -| self.segment;
                    self.state = .complete;
                    break;
                }
            }
        }
    }

    pub fn backspace(self: *Session) void {
        if (self.state == .paused or self.state == .complete) return;
        if (self.error_mode == .stop_on_error) {
            // Stop-on-error does not require Backspace, but pressing it clears the visual red mark.
            self.current_error = false;
            self.last_wrong_cp = null;
            return;
        }
        if (self.len == 0) return;
        self.len -= 1;
        self.previous_cr = false;
        if (self.len >= self.reference_len or self.typed[self.len] != self.reference[self.len]) self.corrected += 1;
        self.collector.notePauseOrBlur();
    }

    pub fn pause(self: *Session, now: u64) void {
        if (self.state == .complete or self.state == .paused) return;
        if (self.state == .running) self.active_us += now -| self.segment;
        self.state = .paused;
        self.collector.notePauseOrBlur();
    }

    pub fn resumeRun(self: *Session, now: u64) void {
        if (self.state != .paused) return;
        self.state = if (self.started == null) .ready else .running;
        self.segment = now;
        self.last_event_us = now;
        self.collector.notePauseOrBlur();
    }

    pub fn duration(self: *const Session, now: u64) u64 {
        return self.active_us + if (self.state == .running) now -| self.segment else 0;
    }

    pub fn hesitationUs(self: *const Session, now: u64) u64 {
        if (self.state == .paused or self.state == .complete) return 0;
        const anchor = self.last_event_us orelse self.started orelse return 0;
        return now -| anchor;
    }

    pub fn shouldShowHesitationHint(self: *const Session, now: u64) bool {
        if (self.current_error) return true;
        if (self.state == .ready) return true;
        return self.hesitationUs(now) >= hesitation_threshold_us;
    }

    pub fn matched(self: *const Session) usize {
        var count: usize = 0;
        for (self.typed[0..@min(self.len, self.reference_len)], self.reference[0..@min(self.len, self.reference_len)]) |a, b| {
            count += @intFromBool(a == b);
        }
        return count;
    }

    pub fn wpm(self: *const Session, now: u64) f64 {
        return wordsPerMinute(self.matched(), self.duration(now));
    }

    pub fn accuracy(self: *const Session) f64 {
        return accuracyPercent(self.correct_attempts, self.attempts);
    }
};

/// Typing speed with the conventional five characters per word.
pub fn wordsPerMinute(characters: u64, active_us: u64) f64 {
    if (active_us == 0) return 0;
    return @as(f64, @floatFromInt(characters)) * 12_000_000 / @as(f64, @floatFromInt(active_us));
}

pub fn accuracyPercent(correct: u64, attempts: u64) f64 {
    if (attempts == 0) return 100;
    return 100 * @as(f64, @floatFromInt(correct)) / @as(f64, @floatFromInt(attempts));
}

/// Project/cache adapters supply only proven literal labels. Never infer text
/// from callback or dead-key captions. Modifier bytes use USB modifier bits.
pub const Label = struct {
    text: ?[]const u8 = null,
    hid_code: ?u8 = null,
    dead: bool = false,
    shortcut: bool = false,
    hold_layer: ?usize = null,
    hold_modifiers: ?u8 = null,
    one_shot_layer: ?usize = null,
    one_shot_modifiers: u8 = 0,
    provider_unknown: bool = false,
    unproven: bool = false,
};

pub const Labels = struct {
    context: *const anyopaque,
    key_count: usize,
    layer_count: usize,
    lookup: *const fn (*const anyopaque, usize, usize, u8, u16) Label,

    pub fn validate(self: Labels) !void {
        if (self.key_count == 0 or self.layer_count == 0 or self.layer_count > 16) return error.InvalidDimensions;
    }

    pub fn get(self: Labels, layer: usize, key: usize, mods: u8, active: u16) Label {
        return self.lookup(self.context, layer, key, mods, active);
    }
};

pub const Hint = struct {
    layer: usize,
    key: usize,
    modifiers: u8,
    combo_key: ?usize = null,
    layer_activator: ?usize = null,
    layer_one_shot: bool = false,
    shift_one_shot: bool = false,
};

pub const KeyMetadata = struct {
    hand: enum { left, right, neutral } = .neutral,
    thumb: bool = false,
    home_row: bool = false,
};

/// Every output slot is in the caller's board processing-index order.
pub const Guidance = struct {
    tap: []bool,
    hold: []bool,
    one_shot: ?[]bool = null,

    fn reset(self: Guidance, count: usize) !void {
        if (self.tap.len != count or self.hold.len != count) return error.InvalidDimensions;
        if (self.one_shot) |os| if (os.len != count) return error.InvalidDimensions;
        @memset(self.tap, false);
        @memset(self.hold, false);
        if (self.one_shot) |os| @memset(os, false);
    }
};

pub fn layerMask(layer: usize) u16 {
    return 1 | (@as(u16, 1) << @intCast(layer));
}

pub fn matches(entry: Label, cp: u21) bool {
    if (entry.dead or entry.shortcut or entry.unproven) return false;
    if (entry.hid_code) |code| {
        if ((cp == '\n' and code == 40) or (cp == '\t' and code == 43) or (cp == ' ' and code == 44)) return true;
    }
    const text = entry.text orelse return false;
    var buffer: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buffer) catch return false;
    return std.mem.eql(u8, text, buffer[0..n]);
}

/// Profile-backed hint lookup supporting base, Shift, layer-hold, one-shot, and 2-key combo routes.
pub fn hintWithProfile(
    profile: ?*const layout_profile.LayoutProfile,
    labels: Labels,
    layer: usize,
    modifiers: u8,
    cp: u21,
    active: u16,
) !?Hint {
    if (profile) |p| {
        if (p.key_count == labels.key_count and p.layer_count == labels.layer_count) {
            // Check 2-key combo route first if no simpler base route exists or combo is primary.
            if (p.routeFor(cp)) |route| {
                var shift_os = false;
                if ((route.modifiers & 0x22) != 0) {
                    if (p.preferredShiftFor(route.key_index)) |sp| {
                        shift_os = (sp.kind == .one_shot);
                    }
                }
                return .{
                    .layer = route.layer,
                    .key = route.key_index,
                    .modifiers = route.modifiers,
                    .combo_key = route.combo_key_index,
                    .layer_activator = route.layer_activator,
                    .layer_one_shot = route.layer_one_shot,
                    .shift_one_shot = shift_os,
                };
            }
        }
    }
    return hint(labels, layer, modifiers, cp, active);
}

pub fn hint(labels: Labels, layer: usize, modifiers: u8, cp: u21, active: u16) !?Hint {
    try labels.validate();
    if (layer >= labels.layer_count) return error.InvalidLayer;
    const variants = [_]u8{ modifiers, 0, 2, 4, 6, 64, 66 };
    for (0..labels.layer_count) |offset| {
        const candidate = (layer + offset) % labels.layer_count;
        for (variants) |mods| {
            if (mods & 0x99 != 0) continue;
            for (0..labels.key_count) |key| {
                if (matches(labels.get(candidate, key, mods, if (candidate == layer) active else layerMask(candidate)), cp)) {
                    return .{
                        .layer = candidate,
                        .key = key,
                        .modifiers = mods,
                    };
                }
            }
        }
    }
    return null;
}

pub fn guidanceWithProfile(
    profile: ?*const layout_profile.LayoutProfile,
    labels: Labels,
    metadata: ?[]const KeyMetadata,
    layer: usize,
    modifiers: u8,
    next: ?Hint,
    output: Guidance,
) !void {
    try labels.validate();
    if (layer >= labels.layer_count) return error.InvalidLayer;
    if (metadata) |keys| {
        if (keys.len != labels.key_count) return error.InvalidDimensions;
    }
    try output.reset(labels.key_count);
    const needed = next orelse return;
    if (needed.layer >= labels.layer_count or needed.key >= labels.key_count) return error.InvalidHint;

    // Highlight primary tap key (and second combo key if this is a 2-key combo).
    output.tap[needed.key] = true;
    if (needed.combo_key) |second_key| {
        if (second_key < labels.key_count) output.tap[second_key] = true;
    }

    // Layer activation (hold or one-shot).
    if (needed.layer != layer) {
        var resolved_act: ?usize = needed.layer_activator;
        var resolved_os: bool = needed.layer_one_shot;
        if (resolved_act == null) {
            if (profile) |p| {
                if (p.preferredLayerActivatorFor(needed.layer, needed.key)) |act| {
                    resolved_act = act.key_index;
                    resolved_os = act.one_shot;
                }
            }
        }
        if (resolved_act == null) {
            for (0..labels.key_count) |key| {
                const entry = labels.get(layer, key, modifiers, layerMask(layer));
                if (entry.provider_unknown) continue;
                if (entry.hold_layer) |held| {
                    if (held == needed.layer and key != needed.key) {
                        resolved_act = key;
                        resolved_os = false;
                        break;
                    }
                }
                if (entry.one_shot_layer) |os_layer| {
                    if (os_layer == needed.layer and key != needed.key) {
                        resolved_act = key;
                        resolved_os = true;
                        break;
                    }
                }
            }
        }
        if (resolved_act) |act_key| {
            if (act_key < labels.key_count and act_key != needed.key) {
                output.hold[act_key] = true;
                if (resolved_os) if (output.one_shot) |os| {
                    os[act_key] = true;
                };
            }
        }
    }

    // Modifier activation (Shift opposite-hand preference, hold or one-shot).
    var missing = needed.modifiers & ~modifiers;
    if (modifiers & 0x22 != 0) missing &= ~@as(u8, 0x22);

    if (missing & 0x22 != 0) {
        if (profile) |p| {
            if (p.preferredShiftFor(needed.key)) |sp| {
                if (sp.key_index < labels.key_count) {
                    output.hold[sp.key_index] = true;
                    if (sp.kind == .one_shot) if (output.one_shot) |os| {
                        os[sp.key_index] = true;
                    };
                    missing &= ~@as(u8, 0x22);
                }
            }
        }
    }

    for (0..8) |bit| {
        const flag = @as(u8, 1) << @intCast(bit);
        if (missing & flag == 0) continue;
        var best: ?usize = null;
        var best_score: usize = 0;
        var best_is_os: bool = false;
        for (0..labels.key_count) |key| {
            if (key == needed.key) continue;
            const entry = labels.get(layer, key, modifiers, layerMask(layer));
            if (entry.provider_unknown) continue;
            const held = entry.hold_modifiers orelse if (entry.hid_code) |code| (if (code >= 224 and code <= 231) @as(u8, 1) << @intCast(code - 224) else 0) else 0;
            const os_mods = entry.one_shot_modifiers;
            const accepted = if (flag & 0x22 != 0) @as(u8, 0x22) else flag;
            const matches_hold = (held & accepted) != 0;
            const matches_os = (os_mods & accepted) != 0;
            if (!matches_hold and !matches_os) continue;
            var score: usize = 1;
            if (metadata) |keys| {
                if (keys[key].hand != keys[needed.key].hand and keys[key].hand != .neutral) score += 16;
                if (!keys[key].thumb) score += 2;
                if (entry.hold_modifiers != null and !keys[key].thumb) score += 1;
                if (keys[key].home_row and entry.hold_modifiers != null) score += 8;
            }
            if (score > best_score) {
                best = key;
                best_score = score;
                best_is_os = !matches_hold and matches_os;
            }
        }
        if (best) |key| {
            output.hold[key] = true;
            if (best_is_os) if (output.one_shot) |os| {
                os[key] = true;
            };
        }
    }
}

pub fn guidance(
    labels: Labels,
    metadata: ?[]const KeyMetadata,
    layer: usize,
    modifiers: u8,
    next: ?Hint,
    output: Guidance,
) !void {
    return guidanceWithProfile(null, labels, metadata, layer, modifiers, next, output);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "Stop-on-error keeps cursor waiting, counts accuracy, invalidates latency on error/pause, and tracks hesitation" {
    const t = std.testing;
    var s: Session = .{};
    try s.load("ab c", .os);
    try t.expectEqual(ErrorMode.stop_on_error, s.error_mode);

    // Wrong key before start marks error without advancing cursor or starting clock
    try s.insert("z", 1_000_000, false);
    try t.expectEqual(State.ready, s.state);
    try t.expectEqual(@as(usize, 0), s.len);
    try t.expect(s.current_error);
    try t.expectEqual(@as(?u21, 'z'), s.last_wrong_cp);
    try t.expect(s.shouldShowHesitationHint(1_000_000));

    // Matching 'a' clears error, starts clock, advances to index 1
    try s.insert("a", 1_200_000, false);
    try t.expectEqual(State.running, s.state);
    try t.expectEqual(@as(usize, 1), s.len);
    try t.expect(!s.current_error);
    try t.expectEqual(@as(usize, 1), s.corrected);

    // Hesitation threshold: < 1.0s false, >= 1.0s true
    try t.expect(!s.shouldShowHesitationHint(1_700_000));
    try t.expect(s.shouldShowHesitationHint(2_300_000));

    // Wrong key at 'b', then right key 'b' (no Backspace needed)
    try s.insert("x", 1_400_000, false);
    try t.expect(s.current_error);
    try t.expectEqual(@as(usize, 1), s.len);
    try s.insert("b", 1_600_000, false);
    try t.expectEqual(@as(usize, 2), s.len);
    try t.expect(!s.current_error);

    // Clean space and clean 'c'
    try s.insert(" ", 1_800_000, false);
    try s.insert("c", 2_000_000, false);
    try t.expectEqual(State.complete, s.state);
    try t.expectEqual(@as(usize, 6), s.attempts);
    try t.expectEqual(@as(usize, 4), s.correct_attempts);
    try t.expectEqual(@as(usize, 2), s.error_count);

    // Clean latency: 'b' had an error, ' ' was post-error, only 'c' got a clean 200ms sample!
    var lm = model.LearningModel.init("abc", 3, .{ .target_wpm = 35.0 });
    _ = lm.completeRound(&s.collector);
    try t.expectEqual(@as(u32, 0), lm.getStat('b').?.samples);
    try t.expectEqual(@as(u32, 1), lm.getStat('c').?.samples);
    try t.expectApproxEqAbs(@as(f32, 200.0), lm.getStat('c').?.ema_ms, 0.01);
}

test "combo and one-shot Shift/Layer guidance highlight both combo triggers and one-shot activators" {
    const t = std.testing;
    const ComboFixture = struct {
        fn lookup(_: *const anyopaque, layer: usize, key: usize, mods: u8, _: u16) Label {
            return switch (key) {
                0 => if (layer == 0) .{ .text = if (mods & 0x22 != 0) "A" else "a" } else .{ .text = "{" },
                1 => .{ .text = "s" },
                2 => .{ .one_shot_modifiers = 0x20 }, // right one-shot Shift
                3 => .{ .one_shot_layer = 1 }, // one-shot Layer 1
                else => .{},
            };
        }
    };
    var ctx: u8 = 0;
    const labels: Labels = .{
        .context = &ctx,
        .key_count = 4,
        .layer_count = 2,
        .lookup = ComboFixture.lookup,
    };
    const geo = [_]layout_profile.GeometryKey{
        .{ .key_index = 0, .x = 0, .y = 1, .hand = .left, .home_row = true },
        .{ .key_index = 1, .x = 1, .y = 1, .hand = .left, .home_row = true },
        .{ .key_index = 2, .x = 5, .y = 1, .hand = .right, .home_row = true },
        .{ .key_index = 3, .x = 6, .y = 2, .hand = .right, .group = .thumb },
    };
    const combos = [_]layout_profile.ComboInput{
        .{ .layer = 0, .key_indices = .{ 0, 1 }, .output_cp = '_' },
    };
    const profile = try layout_profile.derive(&geo, labels, .{ .combos = &combos });

    var taps: [4]bool = undefined;
    var holds: [4]bool = undefined;
    var os: [4]bool = undefined;
    const out: Guidance = .{ .tap = &taps, .hold = &holds, .one_shot = &os };

    // 1. 2-key combo '_' highlights BOTH key 0 and key 1 in tap
    const combo_hint = (try hintWithProfile(&profile, labels, 0, 0, '_', 1)).?;
    try t.expectEqual(@as(?usize, 1), combo_hint.combo_key);
    try guidanceWithProfile(&profile, labels, null, 0, 0, combo_hint, out);
    try t.expect(taps[0] and taps[1] and !holds[2] and !holds[3]);

    // 2. One-shot Shift for 'A' highlights key 0 tap + key 2 hold & one_shot
    const shift_hint = (try hintWithProfile(&profile, labels, 0, 0, 'A', 1)).?;
    try t.expect(shift_hint.shift_one_shot);
    try guidanceWithProfile(&profile, labels, null, 0, 0, shift_hint, out);
    try t.expect(taps[0] and holds[2] and os[2]);

    // 3. One-shot Layer for '{' highlights key 0 tap + key 3 hold & one_shot
    const layer_hint = (try hintWithProfile(&profile, labels, 0, 0, '{', 1)).?;
    try t.expect(layer_hint.layer_one_shot);
    try guidanceWithProfile(&profile, labels, null, 0, 0, layer_hint, out);
    try t.expect(taps[0] and holds[3] and os[3]);
}

test "Unicode corrections, pauses and literal scoring (flow_backspace mode)" {
    var s: Session = .{ .error_mode = .flow_backspace };
    try s.load("é a\n", .os);
    try s.insert("é", 1_000_000, false);
    try std.testing.expectEqual(@as(f64, 0), s.wpm(1_000_000));
    try s.insert("x", 2_000_000, false);
    s.backspace();
    try s.insert(" ", 3_000_000, false);
    s.pause(4_000_000);
    try s.insert("ignored", 9_000_000, false);
    s.resumeRun(10_000_000);
    try s.insert("a\r\n", 11_000_000, false);
    try std.testing.expectEqual(State.complete, s.state);
    try std.testing.expectEqual(@as(u64, 4_000_000), s.duration(99_000_000));
    try std.testing.expectEqual(@as(f64, 12), s.wpm(99_000_000));
    try std.testing.expectEqual(@as(f64, 80), s.accuracy());
    try std.testing.expectEqual(@as(usize, 1), s.corrected);
    s.restart();
    try s.insert("é a\n", 1, true);
    try std.testing.expect(!s.scored);
}

test "ready pauses, UTF-8 validation and split CRLF preserve character attempts" {
    var s: Session = .{ .error_mode = .flow_backspace };
    try s.load("a\nb", .os);
    try s.insert("", 10, false);
    try std.testing.expect(s.started == null);
    s.pause(20);
    s.resumeRun(30);
    try std.testing.expectEqual(State.ready, s.state);
    try std.testing.expectError(error.InvalidUtf8, s.insert("\xff", 40, false));
    try s.insert("a\r", 50, false);
    try s.insert("\nb", 60, false);
    try std.testing.expectEqual(State.complete, s.state);
    try std.testing.expectEqual(@as(usize, 3), s.attempts);
}

test "wrong text lowers accuracy and must be corrected before completion" {
    var s: Session = .{ .error_mode = .flow_backspace };
    try s.load("aa", .os);
    try s.insert("xx", 10, false);
    try std.testing.expectEqual(State.running, s.state);
    s.backspace();
    s.backspace();
    try std.testing.expectEqual(@as(usize, 2), s.corrected);
    try s.insert("aa", 20, false);
    try std.testing.expectEqual(State.complete, s.state);
    try std.testing.expectEqual(@as(f64, 50), s.accuracy());
}

const GuidanceFixture = struct {
    fn lookup(_: *const anyopaque, layer: usize, key: usize, mods: u8, _: u16) Label {
        return switch (key) {
            0 => if (layer == 0) .{ .text = if (mods & 0x22 != 0) "A" else "a" } else .{},
            1 => .{ .hold_layer = 1 },
            2 => .{ .hold_modifiers = 2 },
            3, 4 => .{ .hold_modifiers = 32 },
            129 => if (layer == 1) .{ .text = "!" } else .{},
            128 => .{ .text = "´", .dead = true },
            127 => .{ .text = " ", .hid_code = 44, .shortcut = true },
            else => .{},
        };
    }
};

test "guidance follows board dimensions beyond 128 keys and injected hand metadata" {
    const t = std.testing;
    var context: u8 = 0;
    const labels: Labels = .{
        .context = &context,
        .key_count = 130,
        .layer_count = 2,
        .lookup = GuidanceFixture.lookup,
    };
    var taps: [130]bool = undefined;
    var holds: [130]bool = undefined;
    const output: Guidance = .{ .tap = &taps, .hold = &holds };
    var keys: [130]KeyMetadata = @splat(.{});
    keys[0].hand = .left;
    keys[2].hand = .left;
    keys[3].hand = .right;
    keys[4] = .{ .hand = .right, .thumb = true };
    const capital = (try hint(labels, 0, 0, 'A', 1)).?;
    try guidance(labels, &keys, 0, 0, capital, output);
    try t.expect(taps[0] and holds[3]);
    try t.expect(!holds[2] and !holds[4]);
    try guidance(labels, &keys, 0, 32, capital, output);
    try t.expect(!holds[2] and !holds[3]);
    const punctuation = (try hint(labels, 0, 0, '!', 1)).?;
    try t.expectEqual(@as(usize, 129), punctuation.key);
    try guidance(labels, null, 0, 0, punctuation, output);
    try t.expect(taps[129] and holds[1]);
    try t.expect((try hint(labels, 0, 0, '´', 1)) == null);
    try t.expect((try hint(labels, 0, 0, ' ', 1)) == null);
    try t.expectError(
        error.InvalidDimensions,
        guidance(labels, null, 0, 0, punctuation, .{ .tap = taps[0..128], .hold = &holds }),
    );
    try t.expectError(
        error.InvalidHint,
        guidance(labels, null, 0, 0, .{ .layer = 1, .key = 130, .modifiers = 0 }, output),
    );
}

test "lesson corpus remains original text and bounded exercise scoring uses injected times" {
    const t = std.testing;
    const hashes = [_][]const u8{
        "c8039baa381495a184f8679808e4daacb7b9bc7adf19bb0ea75f7eb9540c4caf",
        "86366a94d88ed55d88b1733fbf415cf2da109d17c476843d4b6e081215956b79",
        "38342ac2998b6acccd50c8bd8eca81cf8bee06144fe61d496add32521b96164e",
    };
    for (lessons, hashes) |lesson, expected| {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(lesson, &hash, .{});
        try t.expectEqualStrings(expected, &std.fmt.bytesToHex(hash, .lower));
        var session: Session = .{};
        try session.load(lesson, .draft);
        try session.insert(lesson, 123, false);
        try t.expectEqual(State.complete, session.state);
        try t.expectEqual(@as(f64, 100), session.accuracy());
        try t.expectEqual(@as(u64, 0), session.duration(999));
    }
    var session: Session = .{ .error_mode = .flow_backspace };
    const long: [8193]u8 = @splat('a');
    try t.expectError(error.ExerciseTooLong, session.load(&long, .os));
    try session.load("a", .os);
    try session.insert("x", 100, false);
    session.backspace();
    try session.insert("a", 50, false);
    try t.expectEqual(@as(u64, 0), session.duration(999));
    try t.expectEqual(@as(usize, 1), session.corrected);
}

test "opposite home row outranks dedicated Shift without assuming letter placement" {
    const Fixture = struct {
        fn lookup(_: *const anyopaque, _: usize, key: usize, mods: u8, _: u16) Label {
            return switch (key) {
                0 => .{ .text = if (mods & 0x22 != 0) "Q" else "q" },
                1 => .{ .hid_code = 229 },
                2 => .{ .hold_modifiers = 32 },
                3 => .{ .hold_modifiers = 2 },
                else => .{},
            };
        }
    };
    var context: u8 = 0;
    const labels: Labels = .{
        .context = &context,
        .key_count = 4,
        .layer_count = 1,
        .lookup = Fixture.lookup,
    };
    var metadata = [_]KeyMetadata{
        .{ .hand = .right },
        .{ .hand = .left },
        .{ .hand = .left, .home_row = true },
        .{ .hand = .right, .home_row = true },
    };
    var taps: [4]bool = undefined;
    var holds: [4]bool = undefined;
    const next = (try hint(labels, 0, 0, 'Q', 1)).?;
    try guidance(labels, &metadata, 0, 0, next, .{ .tap = &taps, .hold = &holds });
    try std.testing.expect(holds[2] and !holds[1] and !holds[3] and !holds[0]);
    metadata[0].hand = .left;
    metadata[2].hand = .left;
    metadata[3].hand = .right;
    try guidance(labels, &metadata, 0, 0, next, .{ .tap = &taps, .hold = &holds });
    try std.testing.expect(holds[3] and !holds[2]);
    try guidance(labels, &metadata, 0, 32, next, .{ .tap = &taps, .hold = &holds });
    try std.testing.expect(std.mem.indexOfScalar(bool, &holds, true) == null);
}

test "split CRLF completes the text and later input is ignored" {
    var session: Session = .{ .error_mode = .flow_backspace };
    try session.load("éa\n", .os);
    try session.insert("é", 10, false);
    session.backspace();
    try session.insert("éXxx", 30, false);
    session.backspace();
    session.backspace();
    session.backspace();
    try session.insert("a\r", 40, false);
    try session.insert("\n", 50, false);
    try std.testing.expectEqual(State.complete, session.state);
    const attempts = session.attempts;
    try session.insert("ignored after completion", 60, false);
    try std.testing.expectEqual(attempts, session.attempts);
}
