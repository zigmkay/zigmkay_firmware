// SPDX-License-Identifier: GPL-2.0
// Retained from conlorz/zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f,
// companion-model/src/root.zig, and rewritten for the companion Raw HID session
// of zigmkay_firmware PR #60. See repository LICENSE for GPL version 2.
//! Pure bounded live-session reducer. All times are monotonic milliseconds.
//! The caller owns the transport and sends the commands this reducer returns.
const std = @import("std");
const model = @import("layout-model");
const protocol = @import("device-protocol");

/// Keyboard state rebuilt from state and key reports.
pub const State = struct {
    dimensions: model.KeymapDimensions,
    pressed: [128]bool = @splat(false),
    active_layers: u16 = 1,
    highest_layer: model.LayerIndex = 0,
    modifiers: model.Modifiers = .{},
    last_sequence: ?u8 = null,

    pub fn init(dimensions: model.KeymapDimensions) protocol.ProtocolError!State {
        try protocol.validateDimensions(dimensions);
        return .{ .dimensions = dimensions };
    }

    /// A state report replaces everything; it is complete on its own.
    pub fn replace(self: *State, report: protocol.State) void {
        for (&self.pressed, 0..) |*pressed, index| pressed.* = report.isPressed(index);
        self.active_layers = report.active_layers;
        self.highest_layer = report.highest_layer;
        self.modifiers = report.modifiers;
        self.last_sequence = report.sequence;
    }

    /// Key reports only change the pressed set. Their layer and modifiers were
    /// sampled before processing; state reports carry the processed values.
    pub fn applyKey(self: *State, key: protocol.Key) void {
        self.pressed[key.event.key_index] = key.event.pressed;
        self.last_sequence = key.sequence;
    }
};

/// disconnected: no connect sent. negotiating: connect sent, waiting for hello.
/// synchronizing: hello matched, waiting for the first state report.
/// live: state is coherent. incompatible: the keyboard runs another keymap.
pub const Phase = enum { disconnected, negotiating, synchronizing, live, incompatible };
/// Why a hello was refused.
pub const Mismatch = enum { unsupported_version, dimensions, unknown_keymap, keymap_id };
/// The enter-bootloader command has no acknowledgement. `sent` survives the
/// disconnect caused by the reboot and is cleared by the next connect.
pub const BootloaderStatus = enum { idle, sent };

/// What one received report produced: a command to send, a validated key
/// event for history consumers, or neither.
pub const Outcome = struct {
    send: ?protocol.Command = null,
    key: ?protocol.KeyEvent = null,
    signal: ?protocol.SignalEvent = null,
};

pub const timeout_ms = 500;
pub const refresh_ms = 1000;
pub const max_attempts = 3;

pub const Session = struct {
    expected: protocol.Identity,
    state: State,
    phase: Phase = .disconnected,
    /// Host-side connection generation; nonzero while a connection is open.
    /// It never goes on the wire.
    token: u32 = 0,
    attempts: u8 = 0,
    deadline: u64 = 0,
    expected_sequence: u8 = 0,
    /// The last hello received in this connection, for diagnostics.
    observed: ?protocol.Hello = null,
    mismatch: ?Mismatch = null,
    last_error: ?protocol.ProtocolError = null,
    bootloader_status: BootloaderStatus = .idle,

    pub fn init(expected: protocol.Identity) protocol.ProtocolError!Session {
        try protocol.validateIdentity(expected);
        return .{ .expected = expected, .state = try State.init(expected.dimensions) };
    }

    pub fn hasCoherentState(self: *const Session) bool {
        return self.phase == .live;
    }

    pub fn bootloaderAvailable(self: *const Session) bool {
        return self.phase == .live and self.bootloader_status == .idle;
    }

    /// Starts a connection with a fresh host token. The keyboard answers with
    /// hello and state.
    pub fn connect(self: *Session, now: u64, token: u32) error{InvalidToken}!protocol.Command {
        if (token == 0 or token == self.token) return error.InvalidToken;
        self.token = token;
        self.observed = null;
        self.mismatch = null;
        self.last_error = null;
        self.bootloader_status = .idle;
        self.attempts = 1;
        return self.resynchronize(now);
    }

    /// Ends the connection. Returns the command that tells the keyboard to stop
    /// streaming, when there is a connection to end; the caller may skip it
    /// when the transport already failed.
    pub fn close(self: *Session) ?protocol.Command {
        const active = self.token != 0 and self.phase != .disconnected;
        self.phase = .disconnected;
        self.token = 0;
        self.attempts = 0;
        self.state = State.init(self.expected.dimensions) catch unreachable;
        return if (active) .disconnect else null;
    }

    /// Sends the enter-bootloader command once per connection. The keyboard
    /// reboots without replying; the caller then waits for the BOOTSEL drive.
    pub fn requestBootloader(self: *Session) ?protocol.Command {
        if (!self.bootloaderAvailable()) return null;
        self.bootloader_status = .sent;
        return .enter_bootloader;
    }

    /// Retries an unanswered connect. Mutates only when it returns a command.
    pub fn tick(self: *Session, now: u64) ?protocol.Command {
        switch (self.phase) {
            .negotiating, .synchronizing => {
                if (now < self.deadline) return null;
                self.attempts +|= 1;
                return self.resynchronize(now);
            },
            .disconnected, .live, .incompatible => return null,
        }
    }

    /// Sending connect again makes the keyboard restart with hello and a fresh
    /// state report. The displayed state is stale until that state arrives.
    fn resynchronize(self: *Session, now: u64) protocol.Command {
        self.phase = .negotiating;
        self.state = State.init(self.expected.dimensions) catch unreachable;
        self.deadline = now +| (if (self.attempts < max_attempts) @as(u64, timeout_ms) else refresh_ms);
        return .connect;
    }

    /// A lost or reordered report leaves the state unknown until it is resent.
    fn sequenceGap(self: *Session, received: u8, now: u64) Outcome {
        std.log.info("Keyboard resynchronising after a sequence gap: expected {d}, received {d}", .{
            self.expected_sequence,
            received,
        });
        return .{ .send = self.resynchronize(now) };
    }

    fn refuse(self: *Session, mismatch: Mismatch) Outcome {
        self.mismatch = mismatch;
        self.phase = .incompatible;
        self.state = State.init(self.expected.dimensions) catch unreachable;
        const observed = self.observed;
        std.log.info("Keyboard handshake rejected ({t}). Expected board={s} profile={s} keys={d} layers={d} keymap={s}; received keys={d} layers={d} keymap={s}", .{
            mismatch,
            std.mem.sliceTo(&self.expected.board_id, 0),
            std.mem.sliceTo(&self.expected.profile_id, 0),
            self.expected.dimensions.key_count,
            self.expected.dimensions.layer_count,
            std.fmt.bytesToHex(protocol.keymapId(self.expected), .lower),
            if (observed) |hello| hello.dimensions.key_count else 0,
            if (observed) |hello| hello.dimensions.layer_count else 0,
            std.fmt.bytesToHex(if (observed) |hello| hello.keymap_id else protocol.unknown_keymap_id, .lower),
        });
        // Stop the keyboard from streaming reports nobody can interpret.
        return .{ .send = .disconnect };
    }

    fn malformed(self: *Session, now: u64, err: protocol.ProtocolError) Outcome {
        self.last_error = err;
        return switch (self.phase) {
            .disconnected, .incompatible => .{},
            .negotiating => if (err == error.UnsupportedVersion) self.refuse(.unsupported_version) else .{},
            .synchronizing, .live => blk: {
                std.log.info("Keyboard resynchronising after a malformed report: {t}", .{err});
                break :blk .{ .send = self.resynchronize(now) };
            },
        };
    }

    /// Decodes and applies one keyboard report. Malformed reports resynchronise
    /// a coherent session; unknown report ids are ignored.
    pub fn receive(self: *Session, bytes: []const u8, now: u64) Outcome {
        const decoded = protocol.decode(
            bytes,
            self.expected.dimensions,
        ) catch |err| return self.malformed(now, err);
        const message = decoded orelse return .{};
        return self.applyValid(message, now);
    }

    /// Validates and applies one decoded keyboard message.
    pub fn apply(self: *Session, message: protocol.Message, now: u64) Outcome {
        protocol.validate(message, self.expected.dimensions) catch |err| return self.malformed(now, err);
        return self.applyValid(message, now);
    }

    /// Applies a message already validated against the expected dimensions.
    fn applyValid(self: *Session, message: protocol.Message, now: u64) Outcome {
        switch (self.phase) {
            .disconnected, .incompatible => return .{},
            .negotiating, .synchronizing, .live => {},
        }
        switch (message) {
            .hello => |hello| {
                self.observed = hello;
                if (!std.meta.eql(hello.dimensions, self.expected.dimensions)) return self.refuse(.dimensions);
                if (protocol.isUnknownKeymap(hello.keymap_id)) return self.refuse(.unknown_keymap);
                if (!std.mem.eql(u8, &hello.keymap_id, &protocol.keymapId(self.expected)))
                    return self.refuse(.keymap_id);
                // A repeated hello restarts synchronisation; a state follows it.
                self.phase = .synchronizing;
                self.state = State.init(self.expected.dimensions) catch unreachable;
                self.deadline = now +| timeout_ms;
                return .{};
            },
            .state => |report| {
                // A state before hello predates this connect; hello comes first.
                if (self.phase == .negotiating) return .{};
                self.state.replace(report);
                self.expected_sequence = report.sequence +% 1;
                self.phase = .live;
                self.attempts = 0;
                return .{};
            },
            .key => |key| {
                // Keys sent before the first state report are already part of it.
                if (self.phase != .live) return .{};
                if (key.sequence != self.expected_sequence) return self.sequenceGap(key.sequence, now);
                self.state.applyKey(key);
                self.expected_sequence +%= 1;
                return .{ .key = key.event };
            },
            .signal => |signal| {
                if (self.phase != .live) return .{};
                if (signal.sequence != self.expected_sequence) return self.sequenceGap(signal.sequence, now);
                self.expected_sequence +%= 1;
                return .{ .signal = signal.event };
            },
        }
    }
};

test "bootloader request is sent once per connection and survives the reboot disconnect" {
    const identity = protocol.Identity{
        .board_id = "lk7\x00\x00\x00\x00\x00".*,
        .profile_id = "default\x00".*,
        .digest = @splat(1),
        .dimensions = .{ .key_count = 1, .layer_count = 1 },
    };
    var session = try Session.init(identity);
    try std.testing.expectEqual(@as(?protocol.Command, null), session.requestBootloader());
    _ = try session.connect(0, 42);
    try std.testing.expectEqual(@as(?protocol.Command, null), session.requestBootloader());
    _ = session.apply(.{ .hello = .{ .dimensions = identity.dimensions, .keymap_id = identity.digest } }, 1);
    _ = session.apply(.{ .state = .{ .sequence = 0 } }, 2);
    try std.testing.expect(session.bootloaderAvailable());
    try std.testing.expectEqual(@as(?protocol.Command, .enter_bootloader), session.requestBootloader());
    try std.testing.expectEqual(@as(?protocol.Command, null), session.requestBootloader());
    try std.testing.expectEqual(@as(?protocol.Command, .disconnect), session.close());
    try std.testing.expectEqual(BootloaderStatus.sent, session.bootloader_status);
    try std.testing.expectEqual(@as(?protocol.Command, null), session.close());
    _ = try session.connect(10, 43);
    try std.testing.expectEqual(BootloaderStatus.idle, session.bootloader_status);
}
