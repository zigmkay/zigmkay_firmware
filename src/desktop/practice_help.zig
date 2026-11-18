//! Hint policy v1. Active hesitation includes ready time, excludes paused time.
const std = @import("std");
pub const Policy = enum { full, delayed, on_request };

pub const Config = struct {
    version: u16 = 1,
    policy: Policy = .full,
    delay_ms: u16 = 1500,
    adaptive: bool = true,
    revealed: bool = false,

    pub fn validate(self: Config) !void {
        if (self.version != 1) return error.UnsupportedHintPolicy;
        if (self.delay_ms < 250 or self.delay_ms > 10_000) return error.InvalidHintPolicy;
    }

    pub fn effective(self: Config) Config {
        var value = self;
        if (value.policy != .delayed) {
            value.delay_ms = 1500;
            value.adaptive = true;
        }
        return value;
    }

    pub fn delay(self: Config, baseline_us: ?u64) u64 {
        const configured = @as(u64, self.delay_ms) * 1000;
        if (self.adaptive) {
            if (baseline_us) |reference_us| return @intCast(
                @max(
                    250_000,
                    @min(
                        10_000_000,
                        @max(configured / 2, @min(@as(u128, configured) * 2, @as(u128, reference_us) * 3)),
                    ),
                ),
            );
        }
        return configured;
    }
};

pub const choices = [_][]const u8{
    "Full guidance",
    "Delayed hints",
    "Hints on request",
    "Layout only",
    "Hidden",
};

pub fn choice(config: anytype) usize {
    return switch (config.assistance) {
        .hidden => 4,
        .layout_only => 3,
        .guided => @backingInt(config.hints.policy),
    };
}

pub fn apply(config: anytype, selected: usize) void {
    config.assistance = if (selected == 4) .hidden else if (selected == 3) .layout_only else .guided;
    config.hints.policy = if (selected < 3) @fromBackingInt(@as(u2, @intCast(selected))) else .full;
    config.hints.revealed = false;
}

pub const State = struct {
    generation: u64 = 0,
    position: ?usize = null,
    last: ?u64 = null,
    waited_us: u64 = 0,
    paused: bool = true,
    requested: bool = false,

    pub fn tick(self: *State, generation: u64, position: usize, now: u64, paused: bool) void {
        if (self.generation != generation or self.position == null or self.position.? != position) {
            self.* = .{ .generation = generation, .position = position, .last = now, .paused = paused };
            return;
        }
        if (!paused and !self.paused) {
            if (self.last) |last| {
                self.waited_us +|= now -| last;
            }
        }
        self.last = now;
        self.paused = paused;
    }

    pub fn visible(self: State, config: Config, baseline_us: ?u64) bool {
        if (self.paused) return false;
        return self.requested or config.policy == .full or (config.policy == .delayed and self.waited_us >= config.delay(baseline_us));
    }
};

pub fn baseline(progress: anytype, cp: u21) ?u64 {
    var values: [60]u64 = undefined;
    var count: usize = 0;
    if (progress) |data| {
        for (data.points[0..data.count]) |point| {
            if (point.truncated) continue;
            for (point.characters[0..point.count]) |character| if (character.cp == cp and character.samples >= 5) {
                values[count] = character.median_us;
                count += 1;
            };
        }
    }
    if (count == 0) return null;
    std.mem.sort(u64, values[0..count], {}, std.sort.asc(u64));
    return values[(count - 1) / 2] + (values[count / 2] - values[(count - 1) / 2]) / 2;
}

test "hint hesitation excludes pauses resets per position and requests are deliberate" {
    const t = std.testing;
    var state: State = .{};
    const delayed: Config = .{ .policy = .delayed, .adaptive = false };
    state.tick(1, 0, 0, false);
    state.tick(1, 0, 1_000_000, false);
    try t.expect(!state.visible(delayed, null));
    state.tick(1, 0, 1_100_000, true);
    state.tick(1, 0, 60_000_000, true);
    state.tick(1, 0, 60_100_000, false);
    try t.expectEqual(@as(u64, 1_000_000), state.waited_us);
    state.tick(1, 0, 60_600_000, false);
    try t.expect(state.visible(delayed, null));
    state.tick(1, 1, 60_700_000, false);
    try t.expectEqual(@as(u64, 0), state.waited_us);
    const requested: Config = .{ .policy = .on_request };
    try t.expect(!state.visible(requested, null));
    state.requested = true;
    try t.expect(state.visible(requested, null));
    state.tick(2, 1, 60_800_000, false);
    try t.expect(!state.requested);
    try t.expectEqual(@as(u64, 750_000), (Config{ .policy = .delayed }).delay(120_000));
    try t.expectEqual(@as(u64, 3_000_000), (Config{ .policy = .delayed }).delay(std.math.maxInt(u64)));
}
