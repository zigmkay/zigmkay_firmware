//! UI-thread history of already validated protocol events. No device reads.
const std = @import("std");
pub const KeyEvent = @import("device-protocol").KeyEvent;

pub const TimedLogMessage = struct {
    delta_ms: i64 = 0,
    msg: KeyEvent = .{ .pressed = false, .key_index = 0, .layer = 0, .modifiers = .{} },
};

pub const History = struct {
    events: [100]TimedLogMessage = @splat(.{}),
    head: usize = 0,
    count: usize = 0,
    last_event_timestamp: i64 = 0,

    pub fn record(self: *History, message: KeyEvent, now: i64) void {
        const delta = if (self.last_event_timestamp != 0) now - self.last_event_timestamp else 0;
        self.last_event_timestamp = now;
        self.events[self.head] = .{ .delta_ms = delta, .msg = message };
        self.head = (self.head + 1) % self.events.len;
        self.count = @min(self.count + 1, self.events.len);
    }

    pub fn newest(self: *const History, index: usize) ?TimedLogMessage {
        if (index >= self.count) return null;
        return self.events[(self.head + self.events.len - 1 - index) % self.events.len];
    }
};

test "reference event history preserves newest order deltas and bounded wrap" {
    const t = std.testing;
    var history = History{};
    try t.expect(history.newest(0) == null);
    for (0..105) |index| history.record(.{
        .pressed = index % 2 == 0,
        .key_index = @intCast(index % 100),
        .layer = @intCast(index % 2),
        .modifiers = .{},
    }, @intCast(1000 + index * 7));
    try t.expectEqual(@as(usize, 100), history.count);
    try t.expectEqual(@as(i64, 7), history.newest(0).?.delta_ms);
    try t.expectEqual(@as(u8, 4), history.newest(0).?.msg.key_index);
    try t.expectEqual(@as(u8, 5), history.newest(99).?.msg.key_index);
    try t.expect(history.newest(100) == null);
}
