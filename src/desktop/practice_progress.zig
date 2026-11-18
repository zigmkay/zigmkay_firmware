//! Bounded history evidence. Dates are UTC; stopped/unscored runs are excluded.
const std = @import("std");
const results = @import("practice_results.zig");
const timing = @import("practice_timing.zig");
pub const day_ns: i64 = 86_400_000_000_000;
pub const limit = 60;

pub const Character = struct {
    cp: u21 = 0,
    opportunities: u16 = 0,
    misses: u16 = 0,
    samples: u16 = 0,
    median_us: u64 = 0,
};

pub const Point = struct {
    id: [16]u8 = @splat(0),
    timestamp: i64 = 0,
    wpm: f64 = 0,
    accuracy: f64 = 100,
    active_us: u64 = 0,
    timing: bool = false,
    truncated: bool = false,
    characters: [256]Character = @splat(.{}),
    count: usize = 0,

    pub fn enrich(self: *Point, gpa: std.mem.Allocator, payload: timing.Payload) !void {
        const Sample = struct { cp: u21, us: u64 };
        const values = try gpa.alloc(Sample, payload.events.len);
        defer gpa.free(values);
        var count: usize = 0;
        for (payload.events) |event| if (event.eligibility == .clean) {
            values[count] = .{ .cp = event.expected.?, .us = event.interval_us.? };
            count += 1;
        };
        std.mem.sort(Sample, values[0..count], {}, struct {
            fn less(_: void, a: Sample, b: Sample) bool {
                return if (a.cp == b.cp) a.us < b.us else a.cp < b.cp;
            }
        }.less);
        var start: usize = 0;
        while (start < count) {
            var end = start + 1;
            while (end < count and values[end].cp == values[start].cp) : (end += 1) {}
            const n = end - start;
            const lower = values[start + (n - 1) / 2].us;
            const upper = values[start + n / 2].us;
            for (self.characters[0..self.count]) |*character| if (character.cp == values[start].cp) {
                character.samples = @intCast(n);
                character.median_us = lower + (upper - lower) / 2;
            };
            start = end;
        }
        self.timing = true;
        self.truncated = payload.truncated;
    }
};

test "character timing excludes correction paste and batch evidence and keeps median units" {
    const t = std.testing;
    var point: Point = .{ .count = 1 };
    point.characters[0].cp = 'a';
    var events: [5]timing.Event = undefined;
    for (&events, 0..) |*event, index| event.* = .{
        .observed_us = (index + 1) * 1000,
        .elapsed_us = (index + 1) * 1000,
        .active_us = (index + 1) * 1000,
        .kind = .attempt,
        .position = 0,
        .expected = 'a',
        .typed = 'a',
        .correct = true,
        .eligibility = .clean,
        .interval_us = (index + 1) * 100,
    };
    events[2].eligibility = .correction;
    events[2].interval_us = null;
    events[3].eligibility = .paste;
    events[3].interval_us = null;
    events[3].input = .paste;
    events[4].eligibility = .batch;
    events[4].interval_us = null;
    events[4].input = .batch;
    const payload: timing.Payload = .{ .reference = &.{'a'}, .events = &events };
    try payload.validate();
    try point.enrich(t.allocator, payload);
    try t.expectEqual(@as(u16, 2), point.characters[0].samples);
    try t.expectEqual(@as(u64, 150), point.characters[0].median_us);
}

pub const Summary = struct {
    // Newest first, with deterministic ID tie breaking.
    points: [limit]Point = @splat(.{}),
    count: usize = 0,
    eligible: usize = 0,
    today: i64 = 0,
    days: [28]u64 = @splat(0),
    day_runs: [28]usize = @splat(0),

    pub fn add(self: *Summary, record: *const results.Record) void {
        if (!record.scored or record.status != .completed) return;
        self.eligible += 1;
        const day = @divFloor(record.timestamp, day_ns);
        const ago = self.today - day;
        if (ago >= 0 and ago < self.days.len) {
            const index: usize = @intCast(ago);
            self.days[index] +|= record.active_us;
            self.day_runs[index] += 1;
        }
        var at: usize = 0;
        while (at < self.count) : (at += 1) {
            const point = self.points[at];
            if (record.timestamp > point.timestamp or
                (record.timestamp == point.timestamp and std.mem.order(u8, &record.id, &point.id) == .gt)) break;
        }
        if (at == limit) return;
        const end = @min(self.count, limit - 1);
        var index = end;
        while (index > at) : (index -= 1) self.points[index] = self.points[index - 1];
        var point: Point = .{
            .id = record.id,
            .timestamp = record.timestamp,
            .wpm = record.wpm(),
            .accuracy = record.accuracy(),
            .active_us = record.active_us,
            .timing = record.timing_available,
            .count = record.stat_count,
        };
        for (record.stats[0..record.stat_count], 0..) |stat, i| point.characters[i] = .{
            .cp = stat.cp,
            .opportunities = @intCast(stat.opportunities),
            .misses = @intCast(stat.misses),
        };
        self.points[at] = point;
        self.count = @min(limit, self.count + 1);
    }

    pub fn accuracyStreak(self: *const Summary) usize {
        var count: usize = 0;
        for (self.points[0..self.count]) |point| {
            if (point.accuracy < 95 or point.active_us == 0) break;
            count += 1;
        }
        return count;
    }
};

test "bounded chronological evidence preserves UTC activity beyond plotted window" {
    const t = std.testing;
    var summary: Summary = .{ .today = 100 };
    var record: results.Record = .{
        .active_us = 1_000_000,
        .matched = 1,
        .attempts = 1,
        .correct_attempts = 1,
        .stat_count = 1,
    };
    record.stats[0] = .{ .cp = 'a', .opportunities = 1 };
    for (0..70) |i| {
        record.id[0] = @intCast(i);
        record.timestamp = 100 * day_ns + @as(i64, @intCast(i));
        summary.add(&record);
    }
    try t.expectEqual(@as(usize, 60), summary.count);
    try t.expectEqual(@as(u8, 69), summary.points[0].id[0]);
    try t.expectEqual(@as(u8, 10), summary.points[59].id[0]);
    try t.expectEqual(@as(usize, 70), summary.day_runs[0]);
    try t.expectEqual(@as(u64, 70_000_000), summary.days[0]);
    record.scored = false;
    summary.add(&record);
    try t.expectEqual(@as(usize, 70), summary.eligible);
    record.scored = true;
    record.timestamp = 99 * day_ns;
    summary.add(&record);
    try t.expectEqual(@as(usize, 1), summary.day_runs[1]);
    try t.expectEqual(@as(usize, 60), summary.accuracyStreak());
    summary.points[2].accuracy = 94;
    try t.expectEqual(@as(usize, 2), summary.accuracyStreak());
}
