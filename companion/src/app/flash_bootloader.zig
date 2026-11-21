//! Explicit Flash confirmation gate. Caller owns the live HID Driver and the
//! existing wrapper. Neither polling nor constructing this gate accesses hardware.
const std = @import("std");

pub const timeout_ms: u64 = 2500;

/// The rendered confirmation and the current model must match in every field.
/// `selected_target` is an app-owned stable identity (not a borrowed string).
pub const Snapshot = struct {
    operation: u64,
    model_generation: u64,
    board_id: [8]u8,
    build_key: [32]u8,
    artifact_hash: [32]u8,
    selection_revision: u64,
    selected_target: u64,
};

pub const Session = struct {
    available: bool = false,
    /// Status of the same Driver session used for request_once. The caller must
    /// latch an accepted response with observeAccepted before disconnect erases it.
    status: Status = .idle,
    pub const Status = enum { idle, requested, accepted, rejected, timed_out, disconnected };
};

pub const Effect = enum { noop, request_once, wait, start };
pub const Phase = enum { idle, request_due, waiting, manual, finished };

pub const Gate = struct {
    pending: ?Snapshot = null,
    phase: Phase = .idle,
    deadline: u64 = 0,
    accepted: bool = false,

    /// Call only from an explicit user confirmation handler. Reconfirmation
    /// replaces (and invalidates) any older operation.
    pub fn confirm(self: *Gate, rendered: Snapshot, current: Snapshot) bool {
        self.cancel();
        if (rendered.operation == 0 or !std.meta.eql(rendered, current)) return false;
        self.pending = rendered;
        self.phase = .request_due;
        return true;
    }

    pub fn cancel(self: *Gate) void {
        self.pending = null;
        self.phase = .idle;
        self.deadline = 0;
        self.accepted = false;
    }

    pub fn observe(self: *Gate, current: Snapshot) void {
        if (self.pending) |pending| {
            if (!std.meta.eql(pending, current)) self.cancel();
        }
    }

    /// Call when the Driver reports acceptance, before its disconnect event.
    /// Acceptance after the deadline or after cancellation/fallback is ignored.
    pub fn observeAccepted(self: *Gate, current: Snapshot, now: u64) void {
        self.observe(current);
        if (self.phase == .waiting and now <= self.deadline) self.accepted = true;
    }

    /// request_once must be dispatched once through the existing live Driver.
    /// On refusal call requestFailed. `start` grants a single wrapper invocation.
    /// Manual fallback is a phase/status, NOT a recurring transfer effect.
    pub fn step(self: *Gate, session: Session, current: Snapshot, now: u64) Effect {
        self.observe(current);
        switch (self.phase) {
            .idle, .finished, .manual => return .noop,
            .request_due => {
                if (!session.available) {
                    self.phase = .manual;
                    return .noop;
                }
                self.deadline = now +| timeout_ms;
                self.phase = .waiting;
                return .request_once;
            },
            .waiting => {
                if (self.accepted or (session.status == .accepted and now <= self.deadline)) {
                    self.phase = .finished;
                    return .start;
                }
                const refused = switch (session.status) {
                    .rejected, .timed_out, .disconnected => true,
                    else => false,
                };
                if (now >= self.deadline or refused) {
                    self.phase = .manual;
                    return .noop;
                }
                return .wait;
            },
        }
    }

    pub fn requestFailed(self: *Gate) void {
        if (self.phase == .waiting) self.phase = .manual;
    }

    /// A manual wrapper may run once after showing BOOTSEL guidance. Check phase
    /// for status; never treat a newly appeared device as renewed confirmation.
    pub fn consumeManual(self: *Gate, current: Snapshot) bool {
        self.observe(current);
        if (self.phase != .manual) return false;
        self.phase = .finished;
        return true;
    }
};

const fixture: Snapshot = .{
    .operation = 7,
    .model_generation = 4,
    .board_id = "board123".*,
    .build_key = @splat(2),
    .artifact_hash = @splat(3),
    .selection_revision = 2,
    .selected_target = 44,
};

test "idle remains waiting; acceptance latched before disconnect starts once" {
    var gate: Gate = .{};
    try std.testing.expectEqual(Effect.noop, gate.step(.{ .available = true }, fixture, 0));
    try std.testing.expect(gate.confirm(fixture, fixture));
    try std.testing.expectEqual(Effect.request_once, gate.step(.{ .available = true }, fixture, 10));
    try std.testing.expectEqual(Effect.wait, gate.step(.{}, fixture, 11));
    gate.observeAccepted(fixture, 12);
    try std.testing.expectEqual(Effect.start, gate.step(.{ .status = .disconnected }, fixture, 13));
    try std.testing.expectEqual(Effect.noop, gate.step(.{ .available = true, .status = .accepted }, fixture, 14));
}

test "fallback is status and manual permission consumed once" {
    var gate: Gate = .{};
    try std.testing.expect(gate.confirm(fixture, fixture));
    try std.testing.expectEqual(Effect.noop, gate.step(.{}, fixture, 0));
    try std.testing.expectEqual(Phase.manual, gate.phase);
    try std.testing.expectEqual(Effect.noop, gate.step(.{ .available = true }, fixture, 1));
    try std.testing.expect(gate.consumeManual(fixture));
    try std.testing.expect(!gate.consumeManual(fixture));
    try std.testing.expect(gate.confirm(fixture, fixture));
    try std.testing.expectEqual(Effect.request_once, gate.step(.{ .available = true }, fixture, 20));
    try std.testing.expectEqual(Effect.wait, gate.step(.{}, fixture, 2519));
    try std.testing.expectEqual(Effect.noop, gate.step(.{}, fixture, 2520));
    gate.observeAccepted(fixture, 2521);
    try std.testing.expectEqual(Phase.manual, gate.phase);
    try std.testing.expectEqual(Effect.noop, gate.step(.{ .status = .accepted }, fixture, 2521));
}

test "one confirmation emits one request and one start despite repeated frames" {
    var gate: Gate = .{};
    try std.testing.expect(gate.confirm(fixture, fixture));
    var requests: usize = 0;
    var starts: usize = 0;
    for (0..8) |frame| {
        const effect = gate.step(.{ .available = true, .status = if (frame >= 3) .accepted else .requested }, fixture, @intCast(frame));
        if (effect == .request_once) requests += 1;
        if (effect == .start) starts += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), requests);
    try std.testing.expectEqual(@as(usize, 1), starts);
    try std.testing.expect(!gate.consumeManual(fixture));
}

test "failure, cancellation and each snapshot field invalidate permission" {
    var gate: Gate = .{};
    try std.testing.expect(gate.confirm(fixture, fixture));
    _ = gate.step(.{ .available = true }, fixture, 0);
    gate.requestFailed();
    try std.testing.expectEqual(Phase.manual, gate.phase);
    var variants: [6]Snapshot = @splat(fixture);
    variants[0].model_generation += 1;
    variants[1].board_id[0] ^= 1;
    variants[2].build_key[0] ^= 1;
    variants[3].artifact_hash[0] ^= 1;
    variants[4].selection_revision += 1;
    variants[5].selected_target += 1;
    for (variants) |changed| {
        try std.testing.expect(!gate.confirm(fixture, changed));
        try std.testing.expect(gate.confirm(fixture, fixture));
        try std.testing.expectEqual(Effect.noop, gate.step(.{ .available = true }, changed, 1));
        try std.testing.expect(!gate.consumeManual(fixture));
    }
    try std.testing.expect(gate.confirm(fixture, fixture));
    _ = gate.step(.{ .available = true }, fixture, 2);
    gate.cancel();
    gate.observeAccepted(fixture, 3);
    try std.testing.expectEqual(Effect.noop, gate.step(.{ .available = true, .status = .accepted }, fixture, 4));
}
