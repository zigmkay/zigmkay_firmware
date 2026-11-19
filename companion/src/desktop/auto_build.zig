//! Pure debounce for firmware builds; no device or process access.
const std = @import("std");

pub const Scheduler = struct {
    observed: ?[32]u8 = null,
    pending: bool = false,
    deadline: u64 = 0,

    pub fn observe(self: *Scheduler, id: [32]u8, now: u64) void {
        if (self.observed) |previous| {
            if (std.mem.eql(u8, &previous, &id)) return;
            self.pending = true;
            self.deadline = now +| 750;
        }
        self.observed = id;
    }

    pub fn take(self: *Scheduler, now: u64, blocked: bool) bool {
        if (!self.pending or blocked or now < self.deadline) return false;
        self.pending = false;
        return true;
    }

    pub fn manual(self: *Scheduler, id: [32]u8) void {
        self.observed = id;
        self.pending = false;
    }
};

test "startup is idle and successive edits build only the latest settled snapshot" {
    var scheduler = Scheduler{};
    scheduler.observe(@splat(1), 0);
    try std.testing.expect(!scheduler.take(1000, false));
    scheduler.observe(@splat(2), 1000);
    try std.testing.expect(!scheduler.take(1749, false));
    scheduler.observe(@splat(3), 1700);
    try std.testing.expect(!scheduler.take(1750, false));
    try std.testing.expect(scheduler.take(2450, false));
    scheduler.observe(@splat(3), 3000);
    try std.testing.expect(!scheduler.take(4000, false)); // No failure retry loop.
}

test "transfer and source review defer builds while manual build consumes queued work" {
    var scheduler = Scheduler{};
    scheduler.observe(@splat(1), 0);
    scheduler.observe(@splat(2), 1);
    try std.testing.expect(!scheduler.take(1000, true));
    scheduler.observe(@splat(3), 1001);
    try std.testing.expect(!scheduler.take(2000, true));
    try std.testing.expect(scheduler.take(2001, false));
    scheduler.observe(@splat(4), 2100);
    scheduler.manual(@splat(4));
    try std.testing.expect(!scheduler.take(3000, false));
}
