//! Version 1 text timing analysis. Possible physical routes are never telemetry.
const std = @import("std");
const timing = @import("practice_timing.zig");
pub const version = 1;
pub const Quantiles = struct { count: usize = 0, median_us: u64 = 0, p95_us: u64 = 0 };
pub const Character = struct { cp: u21 = 0, timing: Quantiles = .{} };
pub const Transition = struct { from: u21 = 0, to: u21 = 0, timing: Quantiles = .{} };

pub const Bucket = struct {
    count: usize = 0,
    mean_ms: f64 = 0,
    errors: usize = 0,
    corrections: usize = 0,
    pauses: usize = 0,
    hints: usize = 0,
};

pub const Summary = struct {
    characters: [256]Character = @splat(.{}),
    character_count: usize = 0,
    transitions: [256]Transition = @splat(.{}),
    transition_count: usize = 0,
    transitions_truncated: bool = false,
    rhythm: [64]Bucket = @splat(.{}),
    active_us: u64 = 0,
    eligible: usize = 0,
    eligibility: [9]usize = @splat(0),
    clocks: [3]usize = @splat(0),
    truncated: bool = false,

    pub fn character(self: *const Summary, cp: u21) ?Quantiles {
        for (self.characters[0..self.character_count]) |value| if (value.cp == cp) return value.timing;
        return null;
    }
};

fn quantiles(values: []const u64) Quantiles {
    if (values.len == 0) return .{};
    const low = values[(values.len - 1) / 2];
    const high = values[values.len / 2];
    return .{
        .count = values.len,
        .median_us = low + (high - low) / 2,
        .p95_us = values[(values.len * 95 + 99) / 100 - 1],
    };
}

pub fn analyze(gpa: std.mem.Allocator, payload: timing.Payload) !*Summary {
    try payload.validate();
    const output = try gpa.create(Summary);
    errdefer gpa.destroy(output);
    output.* = .{
        .truncated = payload.truncated,
        .active_us = if (payload.events.len > 0) payload.events[payload.events.len - 1].active_us else 0,
    };
    const samples = try gpa.alloc(Sample, payload.events.len);
    defer gpa.free(samples);
    const values = try gpa.alloc(u64, payload.events.len);
    defer gpa.free(values);
    const count = collectSamples(output, payload, samples);
    summarizeCharacters(output, samples[0..count], values);
    summarizeTransitions(output, samples[0..count], values);
    return output;
}

/// One clean keystroke interval: typing `cp` after `from`, if any.
const Sample = struct { cp: u21, from: ?u21, us: u64 };

/// Fills the rhythm, clock and eligibility counters and stores the clean
/// intervals in `samples`. Returns the number of samples.
fn collectSamples(output: *Summary, payload: timing.Payload, samples: []Sample) usize {
    var count: usize = 0;
    for (payload.events) |event| {
        output.clocks[@backingInt(event.clock)] += 1;
        const bin: usize = if (output.active_us == 0) 0 else @intCast(
            @min(63, @as(u128, event.active_us) * 64 / output.active_us),
        );
        const bucket = &output.rhythm[bin];
        switch (event.kind) {
            .attempt => {
                output.eligibility[@backingInt(event.eligibility)] += 1;
                if (!event.correct) bucket.errors += 1;
            },
            .backspace => bucket.corrections += 1,
            .pause, .focus_lost => bucket.pauses += 1,
            .hint_shown => bucket.hints += 1,
            else => {},
        }
        if (event.eligibility != .clean) continue;
        const interval = event.interval_us.?;
        samples[count] = .{
            .cp = event.expected.?,
            .from = if (event.position > 0) payload.reference[event.position - 1] else null,
            .us = interval,
        };
        count += 1;
        bucket.count += 1;
        bucket.mean_ms += @as(f64, @floatFromInt(interval)) / 1000;
    }
    output.eligible = count;
    for (&output.rhythm) |*bucket| {
        if (bucket.count > 0) bucket.mean_ms /= @as(f64, @floatFromInt(bucket.count));
    }
    return count;
}

/// Interval quantiles per typed character.
fn summarizeCharacters(output: *Summary, samples: []Sample, values: []u64) void {
    std.mem.sort(Sample, samples, {}, struct {
        fn less(_: void, a: Sample, b: Sample) bool {
            return if (a.cp == b.cp) a.us < b.us else a.cp < b.cp;
        }
    }.less);
    var start: usize = 0;
    while (start < samples.len) {
        var end = start + 1;
        while (end < samples.len and samples[end].cp == samples[start].cp) : (end += 1) {}
        for (samples[start..end], 0..) |sample, index| values[index] = sample.us;
        if (output.character_count < output.characters.len) {
            output.characters[output.character_count] = .{
                .cp = samples[start].cp,
                .timing = quantiles(values[0 .. end - start]),
            };
            output.character_count += 1;
        }
        start = end;
    }
}

/// Interval quantiles per character pair, for samples with a predecessor.
fn summarizeTransitions(output: *Summary, samples: []Sample, values: []u64) void {
    std.mem.sort(Sample, samples, {}, struct {
        fn less(_: void, a: Sample, b: Sample) bool {
            const af = a.from orelse 0x1fffff;
            const bf = b.from orelse 0x1fffff;
            if (af != bf) return af < bf;
            return if (a.cp == b.cp) a.us < b.us else a.cp < b.cp;
        }
    }.less);
    var start: usize = 0;
    while (start < samples.len) {
        var end = start + 1;
        while (end < samples.len and
            samples[end].from == samples[start].from and
            samples[end].cp == samples[start].cp) : (end += 1)
        {}
        if (samples[start].from) |from| {
            for (samples[start..end], 0..) |sample, index| values[index] = sample.us;
            if (output.transition_count < output.transitions.len) {
                output.transitions[output.transition_count] = .{
                    .from = from,
                    .to = samples[start].cp,
                    .timing = quantiles(values[0 .. end - start]),
                };
                output.transition_count += 1;
            } else output.transitions_truncated = true;
        }
        start = end;
    }
}

test "analysis uses clean intervals only and nearest-rank tail while retaining exclusions" {
    const t = std.testing;
    var recorder: timing.Recorder = .init(t.allocator);
    defer recorder.deinit();
    recorder.reset(&.{ 'a', 'b', 'b', 'b', 'b' });
    recorder.begin(100, 0);
    recorder.record(.attempt, 100, 0, 0, 'a', .ordinary);
    recorder.record(.attempt, 200, 100, 1, 'b', .ordinary);
    recorder.record(.attempt, 400, 300, 2, 'b', .ordinary);
    recorder.record(.attempt, 800, 700, 3, 'b', .ordinary);
    recorder.record(.attempt, 1000, 900, 4, 'x', .ordinary);
    const summary = try analyze(t.allocator, recorder.payload());
    defer t.allocator.destroy(summary);
    try t.expectEqual(@as(usize, 3), summary.eligible);
    try t.expectEqual(@as(u64, 200), summary.character('b').?.median_us);
    try t.expectEqual(@as(u64, 400), summary.character('b').?.p95_us);
    try t.expectEqual(@as(usize, 2), summary.transition_count);
    try t.expectEqual(@as(usize, 1), summary.eligibility[@backingInt(timing.Eligibility.first_input)]);
}

test "quantiles average even medians without overflow and empty samples stay absent" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), quantiles(&.{}).count);
    const values = quantiles(&.{ 10, 20, 40, 80 });
    try t.expectEqual(@as(u64, 30), values.median_us);
    try t.expectEqual(@as(u64, 80), values.p95_us);
    const large = quantiles(&.{ std.math.maxInt(u64) - 2, std.math.maxInt(u64) });
    try t.expectEqual(std.math.maxInt(u64) - 1, large.median_us);
}
