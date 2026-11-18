//! Optional recall recommendations, never a claim of forgetting or mastery.
const std = @import("std");
const results = @import("practice_results.zig");
pub const day_ns: i64 = 86_400_000_000_000;

pub const Entry = struct {
    cp: u21 = 0,
    opportunities: u64 = 0,
    cued: u64 = 0,
    uncued: u64 = 0,
    last_exposure: i64 = 0,
    last_recall: ?i64 = null,
    recalls: usize = 0,
    context: results.Cohort = .{},

    pub fn dueAt(self: Entry) i64 {
        const days: i64 = if (self.recalls <= 1) 1 else if (self.recalls == 2) 3 else if (self.recalls == 3) 7 else 14;
        return if (self.last_recall) |last| last +| days * day_ns else self.last_exposure;
    }

    pub fn due(self: Entry, now: i64) bool {
        return self.opportunities >= 5 and self.dueAt() <= now;
    }
};

pub const Summary = struct {
    entries: [256]Entry = @splat(.{}),
    count: usize = 0,
    now: i64 = 0,
    unknown_runs: usize = 0,
    eligible_runs: usize = 0,
    truncated: bool = false,

    pub fn add(self: *Summary, record: *const results.Record) void {
        if (!record.scored or
            record.status != .completed or
            record.timestamp < 0 or
            record.timestamp > self.now) return;
        if (!record.cue_evidence or record.timing_truncated) {
            self.unknown_runs += 1;
            return;
        }
        self.eligible_runs += 1;
        for (record.stats[0..record.stat_count]) |stat| {
            if (stat.cp == ' ' or stat.cp == '\n' or stat.cp == '\t') continue;
            var index: usize = 0;
            while (index < self.count and self.entries[index].cp != stat.cp) : (index += 1) {}
            if (index == self.entries.len) {
                self.truncated = true;
                continue;
            }
            if (index == self.count) {
                self.entries[index] = .{
                    .cp = stat.cp,
                    .last_exposure = record.timestamp,
                    .context = record.cohort,
                };
                self.count += 1;
            }
            const entry = &self.entries[index];
            if (record.timestamp > entry.last_exposure) {
                entry.last_exposure = record.timestamp;
                entry.context = record.cohort;
            }
            entry.opportunities +|= stat.opportunities;
            entry.cued +|= stat.cued;
            entry.uncued +|= stat.uncued;
            // A visible layout is assistance even when no highlight appeared.
            if (record.active_us > 0 and
                record.cohort.assistance == .hidden and
                !record.cohort.hints.revealed and
                stat.cued == 0 and
                stat.uncued_clean >= 5 and
                stat.uncued_misses * 100 <= stat.uncued * 3)
            {
                entry.recalls += 1;
                if (entry.last_recall == null or record.timestamp > entry.last_recall.?)
                    entry.last_recall = record.timestamp;
            }
        }
    }
};

test "recall scheduling distinguishes uncued guided exposure from hidden qualified recall" {
    const t = std.testing;
    var summary: Summary = .{ .now = 10 * day_ns };
    var record: results.Record = .{
        .cue_evidence = true,
        .timing_available = true,
        .timestamp = day_ns,
        .matched = 5,
        .stat_count = 1,
        .active_us = 1_000_000,
    };
    record.stats[0] = .{ .cp = 'e', .opportunities = 5, .uncued = 5, .uncued_clean = 5 };
    summary.add(&record);
    try t.expect(summary.entries[0].last_recall == null);
    try t.expect(summary.entries[0].due(summary.now));
    record.cohort.assistance = .hidden;
    record.timestamp = 9 * day_ns;
    summary.add(&record);
    try t.expectEqual(@as(usize, 1), summary.entries[0].recalls);
    try t.expect(summary.entries[0].due(summary.now));
    record.timestamp = 10 * day_ns;
    summary.add(&record);
    try t.expect(!summary.entries[0].due(summary.now));
    try t.expectEqual(13 * day_ns, summary.entries[0].dueAt());
    record.cohort.hints.revealed = true;
    summary.add(&record);
    try t.expectEqual(@as(usize, 2), summary.entries[0].recalls);
    record.cue_evidence = false;
    summary.add(&record);
    try t.expectEqual(@as(usize, 1), summary.unknown_runs);
}

test "recall excludes incomplete timing future runs and batch-only exposure" {
    const t = std.testing;
    var summary: Summary = .{ .now = 10 * day_ns };
    var record: results.Record = .{
        .cue_evidence = true,
        .timing_available = true,
        .timestamp = day_ns,
        .matched = 6,
        .stat_count = 1,
        .active_us = 1_000_000,
    };
    record.cohort.assistance = .hidden;
    record.stats[0] = .{ .cp = 'e', .opportunities = 6, .uncued = 6, .uncued_clean = 0 };
    summary.add(&record);
    try t.expectEqual(@as(usize, 0), summary.entries[0].recalls);
    record.stats[0].uncued_clean = 5;
    record.timestamp = 11 * day_ns;
    summary.add(&record);
    try t.expectEqual(@as(usize, 1), summary.eligible_runs);
    record.timestamp = day_ns;
    record.timing_truncated = true;
    summary.add(&record);
    try t.expectEqual(@as(usize, 1), summary.unknown_runs);
    record.timing_truncated = false;
    record.status = .stopped;
    summary.add(&record);
    try t.expectEqual(@as(usize, 1), summary.eligible_runs);
}
