//! Verified running keyboard presentation independent of native typing/drafts.
const std = @import("std");
const cache = @import("label_cache.zig");
const companion = @import("session");
const protocol = @import("device-protocol");
const model = @import("layout-model");

pub const Frame = struct {
    labels: ?*const cache.LabelCache = null,
    profile: [8]u8 = @splat(0),
    stale: bool = true,
    layer: usize = 0,
    active: u16 = 1,
    modifiers: model.Modifiers = .{},
    pressed: []const bool = &.{},

    pub fn content(self: Frame, index: usize) ?*const cache.CachedKeyContent {
        const labels = self.labels orelse return null;
        if (index >= labels.key_count) return null;
        return labels.lookupActiveChecked(self.layer, index, self.modifiers, self.active) catch null;
    }
};

pub const Presenter = struct {
    accepted_identity: ?protocol.Identity = null,

    pub fn invalidate(self: *Presenter) void {
        self.accepted_identity = null;
    }

    /// Labels are built from the immutable project matching `binding`. Missing
    /// or newly mismatched identity cannot promote a draft as a live layout.
    /// The caller owns labels, session and output until the draw has finished.
    pub fn select(
        self: *Presenter,
        labels: ?*const cache.LabelCache,
        binding: ?protocol.Identity,
        session: ?*const companion.Session,
        output: []bool,
    ) !Frame {
        const verified = labels orelse return .{};
        const identity = binding orelse return .{};
        const current = session orelse return .{};
        try protocol.validateIdentity(identity);
        if (!std.meta.eql(identity, current.expected) or
            !std.meta.eql(identity.dimensions, current.state.dimensions) or
            verified.key_count != identity.dimensions.key_count or
            verified.layer_count != identity.dimensions.layer_count)
        {
            self.invalidate();
            return .{};
        }
        const coherent = current.token != 0 and current.hasCoherentState();
        if (output.len < verified.key_count) return error.LiveFrameStorageTooSmall;
        if (coherent) {
            try protocol.validateLayers(
                current.state.active_layers,
                current.state.highest_layer,
                identity.dimensions,
            );
        }
        if (coherent) self.accepted_identity = identity else {
            const accepted = self.accepted_identity orelse return .{};
            if (!std.meta.eql(accepted, identity)) {
                self.invalidate();
                return .{};
            }
        }
        const pressed = output[0..verified.key_count];
        @memset(pressed, false);
        var frame = Frame{ .labels = verified, .profile = identity.profile_id, .pressed = pressed };
        if (coherent) {
            frame.stale = false;
            frame.layer = current.state.highest_layer;
            frame.active = current.state.active_layers;
            frame.modifiers = current.state.modifiers;
            @memcpy(pressed, current.state.pressed[0..verified.key_count]);
        }
        return frame;
    }
};

/// Companion-owned overlay intent. The live session reports keyboard signal
/// messages (`fromKeyboard`); the draft runner derives them on the host.
pub const SignalKind = enum { log_toggle, overlay_toggle, shutdown };
pub const Signal = struct { kind: SignalKind, pressed: bool };
pub const max_signals = 32;

/// Converts keyboard signals from the live session, keeping at most `max_signals`.
pub fn fromKeyboard(buffer: *[max_signals]Signal, events: []const protocol.SignalEvent) []const Signal {
    const count = @min(events.len, buffer.len);
    for (events[0..count], buffer[0..count]) |event, *signal| signal.* = .{
        .kind = switch (event.kind) {
            .log_toggle => .log_toggle,
            .overlay_toggle => .overlay_toggle,
            .shutdown => .shutdown,
        },
        .pressed = event.pressed,
    };
    return buffer[0..count];
}

/// Overlay requests never make an unverified draft visible. Hold state is
/// transient and must be cleared on loss of coherent session state.
pub const Visibility = struct {
    mode: enum { toggle, hold, tap_hold } = .toggle,
    latched: bool = false,
    held: bool = false,
    down: bool = false,
    pressed_at: u64 = 0,
    pub const hold_ms = 250;

    pub fn update(self: *Visibility, frame: Frame, signals: []const Signal) bool {
        return self.updateAt(frame, signals, 0);
    }

    pub fn updateAt(self: *Visibility, frame: Frame, signals: []const Signal, now: u64) bool {
        if (frame.labels == null or frame.stale) {
            self.held = false;
            self.down = false;
            self.latched = false;
            return false;
        }
        for (signals) |signal| {
            if (signal.kind != .overlay_toggle) continue;
            if (self.mode == .tap_hold) {
                if (signal.pressed and !self.down) {
                    self.pressed_at = now;
                    self.held = true;
                } else if (!signal.pressed and self.down) {
                    if (now -| self.pressed_at < hold_ms) self.latched = !self.latched;
                    self.held = false;
                }
                self.down = signal.pressed;
                continue;
            }
            if (self.mode == .hold) self.held = signal.pressed else if (signal.pressed and !self.down) self.latched = !self.latched;
            self.down = signal.pressed;
        }
        return switch (self.mode) {
            .hold => self.held,
            .toggle => self.latched,
            .tap_hold => self.held or self.latched,
        };
    }
};

/// HID report arrival does not wake SDL's event wait. Live mode must poll well
/// below the gesture threshold, even when all application windows are hidden.
pub fn waitBudget(live_enabled: bool, busy: bool, resident_idle: bool) u32 {
    return if (live_enabled or busy) 10_000 else if (resident_idle) 500_000 else 250_000;
}

test "live SDL wait budget preserves quick-tap timing with visible and hidden windows" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 10_000), waitBudget(true, false, false));
    try t.expectEqual(@as(u32, 10_000), waitBudget(true, false, true));
    try t.expectEqual(@as(u32, 250_000), waitBudget(false, false, false));
    try t.expectEqual(@as(u32, 500_000), waitBudget(false, false, true));
    var labels = try cache.LabelCache.init(t.allocator, 2, 3);
    defer labels.deinit();
    const frame = Frame{ .labels = &labels, .stale = false };
    const press = [_]Signal{.{ .kind = .overlay_toggle, .pressed = true }};
    const release = [_]Signal{.{ .kind = .overlay_toggle, .pressed = false }};
    for ([_]bool{ false, true }) |hidden| {
        var visibility = Visibility{ .mode = .tap_hold };
        const poll_ms = waitBudget(true, false, hidden) / 1000;
        // Approximate report acceptance at the next polling boundary. Each
        // physical tap lasts 50 ms, and must toggle in both directions.
        _ = visibility.updateAt(frame, &press, 100);
        try t.expect(visibility.updateAt(frame, &release, 150 + poll_ms));
        _ = visibility.updateAt(frame, &press, 300);
        try t.expect(!visibility.updateAt(frame, &release, 350 + poll_ms));
        _ = visibility.updateAt(frame, &press, 500);
        try t.expect(!visibility.updateAt(frame, &release, 1000 + poll_ms));
    }
}

test "quick taps latch while long holds restore preceding visibility" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 2, 3);
    defer labels.deinit();
    const frame = Frame{ .labels = &labels, .stale = false };
    const press = [_]Signal{.{ .kind = .overlay_toggle, .pressed = true }};
    const release = [_]Signal{.{ .kind = .overlay_toggle, .pressed = false }};
    var visibility = Visibility{ .mode = .tap_hold };
    try t.expect(visibility.updateAt(frame, &press, 100));
    try t.expect(visibility.updateAt(frame, &release, 200));
    try t.expect(visibility.updateAt(frame, &.{}, 1000));
    try t.expect(visibility.updateAt(frame, &press, 1100));
    try t.expect(visibility.updateAt(frame, &release, 1500));
    try t.expect(visibility.updateAt(frame, &press, 1600));
    try t.expect(!visibility.updateAt(frame, &release, 1700));
    try t.expect(visibility.updateAt(frame, &press, 1800));
    try t.expect(visibility.updateAt(frame, &press, 1900));
    try t.expect(!visibility.updateAt(frame, &release, 2200));
    try t.expect(visibility.updateAt(frame, &press, 2300));
    try t.expect(!visibility.updateAt(.{}, &.{}, 2400));
    try t.expect(!visibility.updateAt(frame, &release, 2450));
}

test "verified visibility preserves releases and clears holds on stale or mismatched identity" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 2, 3);
    defer labels.deinit();
    const frame = Frame{ .labels = &labels, .stale = false };
    const press = [_]Signal{.{ .kind = .overlay_toggle, .pressed = true }};
    const release = [_]Signal{.{ .kind = .overlay_toggle, .pressed = false }};
    var hold = Visibility{ .mode = .hold };
    try t.expect(hold.update(frame, &press));
    try t.expect(!hold.update(frame, &release));
    try t.expect(hold.update(frame, &press));
    try t.expect(!hold.update(.{}, &.{}));
    try t.expect(!hold.update(frame, &.{}));
    var toggle = Visibility{};
    try t.expect(toggle.update(frame, &press));
    try t.expect(toggle.update(frame, &press));
    try t.expect(toggle.update(frame, &release));
    try t.expect(!toggle.update(frame, &press));
    try t.expect(!toggle.update(.{}, &press));
}

test "live frame waits for coherent identity and clears stale held state" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 4, 34);
    defer labels.deinit();
    const identity = protocol.Identity{
        .board_id = "lk7\x00\x00\x00\x00\x00".*,
        .profile_id = "eurmac\x00\x00".*,
        .digest = @splat(1),
        .dimensions = .{ .key_count = 34, .layer_count = 4 },
    };
    var session = try companion.Session.init(identity);
    var presenter = Presenter{};
    var storage: [34]bool = @splat(true);
    try t.expect((try presenter.select(&labels, identity, &session, &storage)).labels == null);
    // Coherent phase is normally established by the protocol reducer. These
    // presentation fixtures inject its accepted result without device access.
    session.phase = .live;
    session.token = 7;
    session.state.pressed[30] = true;
    session.state.highest_layer = 2;
    session.state.active_layers = 5;
    session.state.modifiers.left_shift = true;
    var frame = try presenter.select(&labels, identity, &session, &storage);
    try t.expect(frame.labels != null and !frame.stale and frame.pressed[30]);
    try t.expectEqual(@as(usize, 2), frame.layer);
    try t.expectEqual(@as(u16, 5), frame.active);
    _ = session.close();
    frame = try presenter.select(&labels, identity, &session, &storage);
    try t.expect(frame.labels != null and frame.stale);
    try t.expectEqual(@as(usize, 0), frame.layer);
    try t.expectEqual(@as(u16, 1), frame.active);
    try t.expectEqual(@as(u8, 0), frame.modifiers.toByte());
    for (frame.pressed) |down| try t.expect(!down);
    var changed = identity;
    changed.digest[0] ^= 1;
    try t.expect((try presenter.select(&labels, changed, &session, &storage)).labels == null);
    try t.expect(presenter.accepted_identity == null);
}

test "hello and the first state promote the verified presentation atomically" {
    const t = std.testing;
    var labels = try cache.LabelCache.init(t.allocator, 2, 3);
    defer labels.deinit();
    const identity = protocol.Identity{
        .board_id = "fixture\x00".*,
        .profile_id = "profile\x00".*,
        .digest = @splat(2),
        .dimensions = .{ .key_count = 3, .layer_count = 2 },
    };
    var session = try companion.Session.init(identity);
    var presenter = Presenter{};
    var output: [3]bool = @splat(false);
    _ = try session.connect(0, 42);
    const hello = try protocol.encode(.{ .hello = .{
        .dimensions = identity.dimensions,
        .keymap_id = protocol.keymapId(identity),
    } }, identity.dimensions);
    _ = session.receive(&hello, 1);
    try t.expect((try presenter.select(&labels, identity, &session, &output)).labels == null);
    var state = protocol.State{ .sequence = 9, .active_layers = 3, .highest_layer = 1 };
    state.pressed[0] = 4;
    const first = try protocol.encode(.{ .state = state }, identity.dimensions);
    _ = session.receive(&first, 2);
    const frame = try presenter.select(&labels, identity, &session, &output);
    try t.expect(frame.labels != null and !frame.stale and frame.pressed[2]);
    try t.expectEqual(@as(usize, 1), frame.layer);
    try t.expect(frame.content(2) != null and frame.content(3) == null);
    var visibility = Visibility{ .mode = .hold };
    try t.expect(visibility.update(frame, &.{.{ .kind = .overlay_toggle, .pressed = true }}));
    // A sequence gap makes the presentation stale until the keyboard resends state.
    const gap = try protocol.encode(.{ .key = .{ .sequence = 13, .event = .{
        .key_index = 2,
        .pressed = false,
        .layer = 1,
        .modifiers = .{},
    } } }, identity.dimensions);
    try t.expectEqual(@as(?protocol.Command, .connect), session.receive(&gap, 3).send);
    const stale = try presenter.select(&labels, identity, &session, &output);
    try t.expect(stale.stale and !stale.pressed[2]);
    try t.expect(!visibility.update(stale, &.{}));
}

test "keyboard signals convert to overlay signals" {
    var buffer: [max_signals]Signal = undefined;
    const converted = fromKeyboard(&buffer, &.{
        .{ .kind = .overlay_toggle, .pressed = true },
        .{ .kind = .shutdown, .pressed = false },
    });
    try std.testing.expectEqualSlices(Signal, &.{
        .{ .kind = .overlay_toggle, .pressed = true },
        .{ .kind = .shutdown, .pressed = false },
    }, converted);
}
