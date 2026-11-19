//! Pre-widget routing of explicit draft input. Native text never invents keys.
const control = @import("practice_controller.zig");
const host = @import("host_input.zig");
const std = @import("std");
const project = @import("project");

pub const Event = union(enum) {
    focus_lost: u32,
    focus_gained: u32,
    text: u32,
    key: struct { window: u32, scancode: u32, down: bool, repeat: bool = false },
};

pub const Key = struct { operation: control.Operation, index: u7, down: bool };
pub const Route = union(enum) { pass, consumed, pause, release_input, key: Key };

pub const Router = struct {
    window: u32,
    focused: bool = false,
    owns_practice_input: bool = false,
    /// Runner startup and accepted greeting must finish before this is true.
    runner_running: bool = false,
    mapping: ?struct { binding: host.Binding, snapshot: control.Digest } = null,

    /// The caller retains the immutable document and binding storage until cleared.
    pub fn installMapping(
        self: *Router,
        binding: host.Binding,
        document: project.Document,
        snapshot: control.Digest,
    ) !void {
        try binding.validate(document);
        self.mapping = .{ .binding = binding, .snapshot = snapshot };
    }

    pub fn route(self: *Router, tutor: *const control.Controller, event: Event) Route {
        switch (event) {
            .focus_lost => |window| {
                if (window != self.window) return .pass;
                self.focused = false;
                self.owns_practice_input = false;
                return .release_input;
            },
            .focus_gained => |window| {
                if (window == self.window) self.focused = true;
                return .pass;
            },
            else => {},
        }
        if (!self.focused or !self.owns_practice_input or !tutor.active) return .pass;
        if (event == .key and
            event.key.window == self.window and
            event.key.down and
            event.key.scancode == 41) return .pause;
        if (!self.runner_running or
            tutor.runner_state != .running or
            tutor.session.source != .draft or
            (tutor.session.state != .ready and tutor.session.state != .running)) return .pass;
        if (!std.mem.eql(u8, &tutor.current, &tutor.captured)) return .pass;
        switch (event) {
            .text => |window| return if (window == self.window) .consumed else .pass,
            .key => |key| {
                if (key.window != self.window) return .pass;
                const mapping = self.mapping orelse return .pass;
                if (!std.mem.eql(u8, &mapping.snapshot, &tutor.current)) return .pass;
                const index = mapping.binding.keyIndex(key.scancode) orelse return .pass;
                if (key.repeat) return .consumed;
                return .{ .key = .{ .operation = tutor.operation(), .index = index, .down = key.down } };
            },
            else => return .pass,
        }
    }
};

test "draft routing requires ownership and accepted runner and consumes repeat/native text" {
    const t = @import("std").testing;
    var tutor = control.Controller.init(@splat(1));
    _ = try tutor.choose(.{ .source = .draft }, 0);
    _ = try tutor.start(true, @as(control.Digest, @splat(1)), 0);
    var router = Router{
        .window = 7,
        .focused = true,
        .owns_practice_input = true,
        .mapping = .{ .binding = .{
            .board_id = @splat(0),
            .key_ids = &.{"fixture"},
            .scancodes = &.{4},
        }, .snapshot = @splat(1) },
    };
    const down: Event = .{ .key = .{ .window = 7, .scancode = 4, .down = true } };
    try t.expect(router.route(&tutor, down) == .pass);
    router.runner_running = true;
    const routed = router.route(&tutor, down).key;
    try t.expectEqualDeep(tutor.operation(), routed.operation);
    try t.expectEqual(@as(u7, 0), routed.index);
    try t.expect(routed.down);
    try t.expect(router.route(&tutor, .{ .key = .{
        .window = 7,
        .scancode = 4,
        .down = true,
        .repeat = true,
    } }) == .consumed);
    try t.expect(router.route(&tutor, .{ .text = 7 }) == .consumed);
    try t.expect(router.route(&tutor, .{ .text = 8 }) == .pass);
    try t.expect(router.route(&tutor, .{ .key = .{ .window = 7, .scancode = 41, .down = true } }) == .pause);
    try t.expect(router.route(&tutor, .{ .focus_lost = 8 }) == .pass);
    try t.expect(router.focused);
    try t.expect(router.route(&tutor, .{ .focus_lost = 7 }) == .release_input);
    try t.expect(!router.focused and !router.owns_practice_input);
    try t.expect(router.route(&tutor, down) == .pass);
    _ = router.route(&tutor, .{ .focus_gained = 7 });
    try t.expect(router.focused and !router.owns_practice_input);
    try t.expect(router.route(&tutor, down) == .pass);
    router.owns_practice_input = true;
    router.mapping.?.snapshot = @splat(2);
    try t.expect(router.route(&tutor, down) == .pass);
}
