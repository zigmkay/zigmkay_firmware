//! Exercise-only raw datapoints. Analysis eligibility never deletes an observation.
const std = @import("std");
pub const max_events = 32768;

pub const Kind = enum {
    attempt,
    backspace,
    pause,
    resume_run,
    focus_lost,
    focus_gained,
    context_changed,
    hint_shown,
    complete,
    stop,
    hint_requested,
    hint_hidden,
};

pub const Input = enum { ordinary, batch, paste, repeat };

pub const Eligibility = enum {
    clean,
    first_input,
    boundary,
    correction,
    batch,
    paste,
    repeat,
    nonpositive_interval,
    clock_regression,
};

pub const Clock = enum { injected, native_event, frame };
pub const EventTime = struct { number: u16, now_us: u64 };

pub const Event = struct {
    observed_us: u64,
    clock: Clock = .injected,
    elapsed_us: u64,
    active_us: u64,
    kind: Kind,
    position: u32,
    expected: ?u21 = null,
    typed: ?u21 = null,
    batch: u32 = 0,
    input: Input = .ordinary,
    correct: bool = false,
    eligibility: Eligibility = .boundary,
    interval_us: ?u64 = null,
    assistance: u8 = 0,
    cue_visible: bool = false,
};

pub const Payload = struct {
    version: u16 = 1,
    reference: []const u21,
    events: []const Event,
    truncated: bool = false,
    dropped: u64 = 0,
    cue_tracking: bool = false,
    help_revealed: bool = false,

    pub fn validate(self: Payload) !void {
        if (self.version != 1) return error.UnsupportedPracticeTiming;
        if (self.help_revealed and !self.cue_tracking) return error.InvalidPracticeTiming;
        if (self.reference.len > 8192 or
            self.events.len > max_events or
            self.truncated != (self.dropped != 0)) return error.InvalidPracticeTiming;
        for (self.reference) |cp| if (!scalar(cp)) return error.InvalidPracticeTiming;
        var elapsed: u64 = 0;
        var active: u64 = 0;
        for (self.events) |event| {
            if (event.cue_visible and !self.cue_tracking) return error.InvalidPracticeTiming;
            if (event.position > 8192 or
                event.assistance > 2 or
                event.elapsed_us < elapsed or
                event.active_us < active or
                event.active_us > event.elapsed_us) return error.InvalidPracticeTiming;
            elapsed = event.elapsed_us;
            active = event.active_us;
            if (event.expected) |cp| {
                if (!scalar(cp) or
                    event.position >= self.reference.len or
                    cp != self.reference[event.position]) return error.InvalidPracticeTiming;
            }
            if (event.typed) |cp| if (!scalar(cp)) return error.InvalidPracticeTiming;
            if (event.kind == .attempt) {
                if ((event.position < self.reference.len) != (event.expected != null))
                    return error.InvalidPracticeTiming;
                if (event.typed == null or
                    event.correct != (event.expected != null and event.expected.? == event.typed.?))
                    return error.InvalidPracticeTiming;
            } else if (event.interval_us != null or event.typed != null) return error.InvalidPracticeTiming;
            if (event.eligibility == .clean) {
                if (event.kind != .attempt or
                    !event.correct or
                    event.input != .ordinary or
                    event.interval_us == null or
                    event.interval_us.? == 0 or
                    event.interval_us.? > event.active_us) return error.InvalidPracticeTiming;
            } else if (event.interval_us != null) return error.InvalidPracticeTiming;
        }
    }
};

fn scalar(cp: u21) bool {
    return cp <= 0x10ffff and !(cp >= 0xd800 and cp <= 0xdfff);
}

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    payload: Payload,

    pub fn clone(gpa: std.mem.Allocator, payload: Payload) !Owned {
        try payload.validate();
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var copy = payload;
        copy.reference = try arena.allocator().dupe(u21, payload.reference);
        copy.events = try arena.allocator().dupe(Event, payload.events);
        return .{ .arena = arena, .payload = copy };
    }

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Recorder = struct {
    cue_tracking: bool = false,
    help_revealed: bool = false,
    cue_positions: [8192]bool = @splat(false),
    clean_positions: [8192]bool = @splat(false),
    cue_visible: bool = false,
    cue_position: usize = 0,
    gpa: std.mem.Allocator,
    reference: [8192]u21 = undefined,
    reference_len: usize = 0,
    events: std.ArrayList(Event) = .empty,
    started: ?u64 = null,
    last_now: u64 = 0,
    previous_active: ?u64 = null,
    previous_clean: bool = false,
    boundary_pending: bool = false,
    batch: u32 = 0,
    assistance: u8 = 0,
    dropped: u64 = 0,
    clock: Clock = .injected,

    pub fn init(gpa: std.mem.Allocator) Recorder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Recorder) void {
        self.events.deinit(self.gpa);
    }

    pub fn reset(self: *Recorder, reference: []const u21) void {
        @memset(&self.cue_positions, false);
        @memset(&self.clean_positions, false);
        self.cue_visible = false;
        self.cue_position = 0;
        self.help_revealed = false;
        self.reference_len = reference.len;
        @memcpy(self.reference[0..reference.len], reference);
        self.events.clearRetainingCapacity();
        self.started = null;
        self.last_now = 0;
        self.previous_active = null;
        self.previous_clean = false;
        self.boundary_pending = false;
        self.batch = 0;
        self.dropped = 0;
    }

    pub fn begin(self: *Recorder, now: u64, assistance: u8) void {
        self.started = now;
        self.last_now = now;
        self.assistance = assistance;
    }

    pub fn nextBatch(self: *Recorder) u32 {
        self.batch +|= 1;
        return self.batch;
    }

    pub fn record(
        self: *Recorder,
        kind: Kind,
        now: u64,
        active: u64,
        position: usize,
        typed: ?u21,
        input: Input,
    ) void {
        if (kind == .hint_shown and self.cue_tracking and position < self.reference_len) {
            self.cue_positions[position] = true;
            self.cue_visible = true;
            self.cue_position = position;
        }
        if (self.started == null) self.started = now;
        const regressed = now < self.last_now;
        const monotonic = @max(now, self.last_now);
        self.last_now = monotonic;
        const prior = if (self.events.items.len == 0) 0 else self.events.items[self.events.items.len - 1].active_us;
        const active_now = @max(active, prior);
        var event = Event{
            .observed_us = now,
            .clock = self.clock,
            .elapsed_us = @max(monotonic -| self.started.?, active_now),
            .active_us = active_now,
            .kind = kind,
            .position = @intCast(position),
            .typed = typed,
            .batch = self.batch,
            .input = input,
            .assistance = self.assistance,
        };
        event.cue_visible = self.cue_tracking and self.cue_visible and self.cue_position == position;
        if (kind == .hint_hidden) self.cue_visible = false;
        if (position < self.reference_len) event.expected = self.reference[position];
        if (kind == .attempt) {
            event.correct = typed != null and event.expected != null and typed.? == event.expected.?;
            event.eligibility = if (regressed) .clock_regression else switch (input) {
                .paste => .paste,
                .batch => .batch,
                .repeat => .repeat,
                .ordinary => if (self.previous_active == null) (if (self.boundary_pending) .boundary else .first_input) else if (!self.previous_clean or !event.correct) .correction else if (active_now <= self.previous_active.?) .nonpositive_interval else .clean,
            };
            if (event.eligibility == .clean) event.interval_us = active_now - self.previous_active.?;
            if (event.eligibility == .clean and
                !event.cue_visible and
                position < self.reference_len) self.clean_positions[position] = true;
            self.previous_active = active_now;
            self.previous_clean = event.correct and input == .ordinary and !regressed;
            self.boundary_pending = false;
        } else if (kind != .hint_shown and kind != .hint_hidden and kind != .hint_requested) {
            self.previous_active = null;
            self.previous_clean = false;
            self.boundary_pending = true;
        }
        if (self.dropped != 0 or self.events.items.len == max_events) {
            self.dropped +|= 1;
            return;
        }
        self.events.append(self.gpa, event) catch {
            self.dropped +|= 1;
        };
    }

    pub fn payload(self: *const Recorder) Payload {
        return .{
            .reference = self.reference[0..self.reference_len],
            .events = self.events.items,
            .truncated = self.dropped != 0,
            .dropped = self.dropped,
            .cue_tracking = self.cue_tracking,
            .help_revealed = self.help_revealed,
        };
    }

    pub fn setCue(self: *Recorder, visible: bool, position: usize, now: u64, active: u64) void {
        if (self.cue_visible and (!visible or self.cue_position != position)) {
            self.record(
                .hint_hidden,
                now,
                active,
                self.cue_position,
                null,
                .ordinary,
            );
        }
        if (visible and
            (!self.cue_visible or self.cue_position != position) and
            position < self.reference_len)
        {
            self.record(
                .hint_shown,
                now,
                active,
                position,
                null,
                .ordinary,
            );
        }
    }
};

test "raw attempts survive correction and boundaries; first input and batches have no motor interval" {
    const t = std.testing;
    var r = Recorder.init(t.allocator);
    defer r.deinit();
    r.reset(&.{ 'a', 'b' });
    r.begin(100, 0);
    _ = r.nextBatch();
    r.record(.attempt, 200, 0, 0, 'a', .ordinary);
    _ = r.nextBatch();
    r.record(.attempt, 500, 300, 1, 'x', .ordinary);
    r.record(.backspace, 550, 350, 1, null, .ordinary);
    _ = r.nextBatch();
    r.record(.attempt, 700, 500, 1, 'b', .ordinary);
    r.record(.pause, 800, 600, 2, null, .ordinary);
    r.record(.resume_run, 1800, 600, 2, null, .ordinary);
    try r.payload().validate();
    try t.expectEqual(Eligibility.first_input, r.events.items[0].eligibility);
    try t.expectEqual(Eligibility.correction, r.events.items[1].eligibility);
    try t.expectEqual(Eligibility.boundary, r.events.items[3].eligibility);
    try t.expectEqual(@as(?u21, 'x'), r.events.items[1].typed);
    var owned = try Owned.clone(t.allocator, r.payload());
    defer owned.deinit();
    r.reset(&.{'c'});
    try t.expectEqual(@as(u21, 'a'), owned.payload.reference[0]);
}

test "clean interval, nonpositive time, regressed clocks and explicit truncation remain distinguishable" {
    const t = std.testing;
    var r = Recorder.init(t.allocator);
    defer r.deinit();
    r.reset(&.{'a'});
    r.record(.attempt, 100, 0, 0, 'a', .ordinary);
    r.record(.attempt, 400, 300, 0, 'a', .ordinary);
    try t.expectEqual(@as(?u64, 300), r.events.items[1].interval_us);
    r.record(.attempt, 400, 300, 0, 'a', .ordinary);
    r.record(.attempt, 350, 250, 0, 'a', .ordinary);
    try t.expectEqual(Eligibility.nonpositive_interval, r.events.items[2].eligibility);
    try t.expectEqual(Eligibility.clock_regression, r.events.items[3].eligibility);
    r.record(.attempt, 500, 400, 0, 'a', .batch);
    try t.expectEqual(Eligibility.batch, r.events.items[4].eligibility);
    for (0..max_events) |_| r.record(.hint_shown, 600, 500, 0, null, .ordinary);
    try t.expect(r.payload().truncated);
    try t.expectEqual(max_events, r.events.items.len);
    try r.payload().validate();
}
