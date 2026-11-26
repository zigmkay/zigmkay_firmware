//! When the editor quietly builds once in the background to fill the compiler
//! cache, and what happens to that build when the user builds. Pure: no
//! process, filesystem or device access.
//!
//! A warm-up runs at most once per application run, unless a build already
//! ran, and only while the editor is idle. It also runs for a bundle that
//! built before: a reinstalled bundle keeps its id, yet its fresh files make
//! Zig rebuild some host libraries, and a warm cache costs about a second. A user build of the same snapshot adopts the running
//! warm-up; any other user build waits for the cache lease the warm-up holds,
//! so two compilers never share a cache.
const std = @import("std");

/// The editor state a start decision reads, captured once per frame.
pub const Conditions = struct {
    /// An interactive editor run: not a fixture, preview or offline session.
    allowed: bool,
    /// A warm-up was started or ruled out earlier in this run.
    attempted: bool,
    /// The bundle has a toolchain and a board plan for the editor's project.
    can_build: bool,
    /// No startup cleanup, job, Flash or close is in progress.
    idle: bool,
    /// Milliseconds since the first editor frame; startup settles first.
    since_start_ms: u64,
};

pub const startup_delay_ms = 3000;

pub const Start = enum {
    /// Not yet; ask again on a later frame.
    wait,
    /// Never in this run.
    skip,
    /// Check the bundle's completed-build marker, then start if missing.
    check,
};

pub fn decide(conditions: Conditions) Start {
    if (!conditions.allowed or conditions.attempted) return .skip;
    if (!conditions.can_build or !conditions.idle or conditions.since_start_ms < startup_delay_ms) return .wait;
    return .check;
}

/// Identity of a running warm-up: the tickets its result is checked against.
pub const Ticket = struct {
    job_generation: u64,
    editor_generation: u64,
    snapshot: [32]u8,
    board_id: [8]u8,
};

/// The editor's state when a build is requested or a warm-up finishes.
pub const Current = struct {
    job_generation: u64,
    editor_generation: u64,
    snapshot: [32]u8,
    /// Board of the build plan, null without a project.
    plan_board: ?[8]u8,
};

/// Whether the warm-up builds exactly what the editor would build now, so
/// its result is a build of the current layout.
pub fn current(ticket: Ticket, now: Current) bool {
    const board = now.plan_board orelse return false;
    return ticket.job_generation == now.job_generation and
        ticket.editor_generation == now.editor_generation and
        std.mem.eql(u8, &ticket.snapshot, &now.snapshot) and
        std.mem.eql(u8, &ticket.board_id, &board);
}

pub const UserBuild = enum {
    /// The running warm-up becomes the user's build.
    adopt,
    /// Start the user's build; it waits for the warm-up's cache lease.
    queue,
};

pub fn userBuild(ticket: ?Ticket, now: Current) UserBuild {
    const running = ticket orelse return .queue;
    return if (current(running, now)) .adopt else .queue;
}

pub const Finished = enum {
    /// A successful build of the current layout: accept it as the editor's build.
    accept,
    /// Only the cache was the point: drop the result, log a failure.
    discard,
};

pub fn finished(ticket: Ticket, now: Current, succeeded: bool, user_build_running: bool) Finished {
    return if (succeeded and !user_build_running and current(ticket, now)) .accept else .discard;
}

const testing = std.testing;

fn idleConditions() Conditions {
    return .{ .allowed = true, .attempted = false, .can_build = true, .idle = true, .since_start_ms = startup_delay_ms };
}

test "a warm-up starts once, after startup, while the editor is idle" {
    try testing.expectEqual(Start.check, decide(idleConditions()));
    var c = idleConditions();
    c.since_start_ms = startup_delay_ms - 1;
    try testing.expectEqual(Start.wait, decide(c));
    c = idleConditions();
    c.idle = false;
    try testing.expectEqual(Start.wait, decide(c));
    c = idleConditions();
    c.can_build = false;
    try testing.expectEqual(Start.wait, decide(c));
    // Fixtures, previews, offline sessions and a second attempt never warm up.
    c = idleConditions();
    c.allowed = false;
    try testing.expectEqual(Start.skip, decide(c));
    c = idleConditions();
    c.attempted = true;
    try testing.expectEqual(Start.skip, decide(c));
}

const warm: Ticket = .{ .job_generation = 4, .editor_generation = 2, .snapshot = @splat(7), .board_id = @splat(1) };
const same: Current = .{ .job_generation = 4, .editor_generation = 2, .snapshot = @splat(7), .plan_board = @splat(1) };

test "a user build adopts a warm-up of the same snapshot and queues otherwise" {
    try testing.expectEqual(UserBuild.adopt, userBuild(warm, same));
    try testing.expectEqual(UserBuild.queue, userBuild(null, same));
    inline for (.{ "job_generation", "editor_generation" }) |field| {
        var moved = same;
        @field(moved, field) += 1;
        try testing.expectEqual(UserBuild.queue, userBuild(warm, moved));
    }
    var edited = same;
    edited.snapshot[0] ^= 1;
    try testing.expectEqual(UserBuild.queue, userBuild(warm, edited));
    var other_board = same;
    other_board.plan_board.?[0] ^= 1;
    try testing.expectEqual(UserBuild.queue, userBuild(warm, other_board));
    // The default layout warmed during onboarding is never the user's build.
    var no_project = same;
    no_project.plan_board = null;
    try testing.expectEqual(UserBuild.queue, userBuild(warm, no_project));
}

test "a finished warm-up counts as a build only of the current layout" {
    try testing.expectEqual(Finished.accept, finished(warm, same, true, false));
    try testing.expectEqual(Finished.discard, finished(warm, same, false, false));
    try testing.expectEqual(Finished.discard, finished(warm, same, true, true));
    var edited = same;
    edited.snapshot[0] ^= 1;
    try testing.expectEqual(Finished.discard, finished(warm, edited, true, false));
    var no_project = same;
    no_project.plan_board = null;
    try testing.expectEqual(Finished.discard, finished(warm, no_project, true, false));
}
