//! Correlated processor output reaches tutor scoring through retained translation.
const std = @import("std");
const control = @import("practice_controller.zig");
const Text = @import("text.zig").Text;
const Command = @import("layout-model").OutputCommand;
pub const Result = struct { accepted: bool = false, effect: control.Effect = .{}, failure: ?anyerror = null };

pub fn consume(
    owner: *control.Controller,
    text: *Text,
    operation: control.Operation,
    snapshot: control.Digest,
    sequence: u64,
    commands: []const Command,
    now: u64,
) Result {
    if (!owner.active or
        owner.session.source != .draft or
        owner.runner_state != .running or
        !std.meta.eql(owner.operation(), operation) or
        !std.mem.eql(u8, &snapshot, &operation.snapshot) or
        !std.mem.eql(u8, &owner.current, &snapshot)) return .{};
    if (sequence == 0) return .{}; // Greeting never carries scored input.
    if (owner.last_sequence) |last| if (sequence <= last) return .{};
    text.practiceOutput(commands, &owner.session, now) catch |failure| {
        const effect = owner.pause(now);
        owner.failure = failure;
        text.clear();
        return .{ .effect = effect, .failure = failure };
    };
    owner.last_sequence = sequence;
    return .{ .accepted = true, .effect = owner.finish(now) };
}
