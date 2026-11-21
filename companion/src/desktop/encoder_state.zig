//! Encoder activity supplied by an explicit event source; no telemetry invention.
const std = @import("std");

pub const State = struct {
    last_action_index: ?usize = null,
    last_activity_ms: ?u64 = null,

    pub fn observe(self: *State, action_index: usize, action_count: usize, now_ms: u64) !void {
        if (action_index >= action_count) return error.InvalidEncoderIndex;
        self.last_action_index = action_index;
        self.last_activity_ms = now_ms;
    }

    pub fn active(self: State, now_ms: u64) bool {
        const last = self.last_activity_ms orelse return false;
        return now_ms >= last and now_ms - last < 150;
    }
};

test "encoder activity is bounded and refused indices preserve state" {
    const t = std.testing;
    var state = State{};
    try t.expect(!state.active(0));
    try state.observe(3, 4, 1000);
    try t.expect(state.active(1149));
    try t.expect(!state.active(1150));
    try t.expect(!state.active(999));
    try t.expectError(error.InvalidEncoderIndex, state.observe(4, 4, 1100));
    try t.expectEqual(@as(?usize, 3), state.last_action_index);
    try t.expectEqual(@as(?u64, 1000), state.last_activity_ms);
}
