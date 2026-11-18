// SPDX-License-Identifier: GPL-2.0
//! Adapted from zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f.
//! UI-thread transport driver. Native HID is supplied only by the explicit live mode.
const std = @import("std");
const protocol = @import("device-protocol");
const companion = @import("companion-model");
pub const capture = @import("session_capture.zig");

pub const Candidate = struct {
    path: []const u8,
    vendor: u16 = 0xFAFA,
    product: u16 = 0x00F0,
    usage_page: u16 = 0xFF31,
    usage: u16 = 0x0074,
};

pub const Discovery = enum { selected, no_device, multiple_devices, path_not_found };
pub const Selection = union(Discovery) { selected: []const u8, no_device, multiple_devices, path_not_found };

pub fn select(candidates: []const Candidate, path: ?[]const u8) Selection {
    var selected: ?[]const u8 = null;
    var count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.vendor != 0xFAFA or
            candidate.product != 0x00F0 or
            candidate.usage_page != 0xFF31 or
            candidate.usage != 0x0074) continue;
        if (path) |wanted| {
            if (std.mem.eql(u8, wanted, candidate.path)) return .{ .selected = candidate.path };
        } else {
            count += 1;
            selected = candidate.path;
        }
    }
    if (path != null) return .path_not_found;
    if (count == 0) return .no_device;
    if (count > 1) return .multiple_devices;
    return .{ .selected = selected.? };
}

pub fn normalize(bytes: []const u8) !protocol.Report {
    const frame = if (bytes.len == protocol.report_size) bytes else if (bytes.len == protocol.report_size + 1 and bytes[0] == 0) bytes[1..] else return error.InvalidNativeReport;
    return frame[0..protocol.report_size].*;
}

pub fn nativeWrite(report: protocol.Report) [33]u8 {
    var bytes: [33]u8 = undefined;
    bytes[0] = 0;
    @memcpy(bytes[1..], &report);
    return bytes;
}

/// Host-side connection tokens. A seed is obtained from OS randomness by the
/// live entry point, so a new connection never reuses an earlier token.
pub const Nonces = struct {
    value: u32,
    remaining: u64 = std.math.maxInt(u32),

    pub fn next(self: *Nonces) !u32 {
        if (self.remaining == 0) return error.NonceExhausted;
        self.remaining -= 1;
        self.value +%= 1;
        if (self.value == 0) self.value = 1;
        return self.value;
    }
};

pub const Status = enum {
    searching,
    no_device,
    multiple_devices,
    path_not_found,
    connected,
    transport_error,
    nonce_exhausted,
};

pub const report_budget = 32;
pub const drain_budget_ms = 2;
pub const reconnect_ms = 1000;

/// Transport methods: discover(?path)!Discovery, read(*[33]u8)!usize,
/// write([]const u8)!void, close(), and now()u64. discover opens only a uniquely
/// selected vendor collection. read is nonblocking; zero means no report.
pub fn Driver(comptime Transport: type) type {
    return struct {
        const Self = @This();
        transport: Transport,
        session: companion.Session,
        nonces: Nonces,
        path: ?[]const u8 = null,
        connected: bool = false,
        retry_at: u64 = 0,
        status: Status = .searching,
        transport_error: ?anyerror = null,
        /// Validated key events applied during the last poll, oldest first.
        key_events: [report_budget]protocol.KeyEvent = undefined,
        key_event_count: usize = 0,
        /// Companion key signals received during the last poll, oldest first.
        signal_events: [report_budget]protocol.SignalEvent = undefined,
        signal_event_count: usize = 0,
        recording: ?*capture.Recorder = null,

        pub fn init(transport: Transport, expected: protocol.Identity, seed: u32, path: ?[]const u8) !Self {
            return .{
                .transport = transport,
                .session = try companion.Session.init(expected),
                .nonces = .{ .value = seed },
                .path = path,
            };
        }

        /// Clean shutdown: tells a connected keyboard to stop streaming, then
        /// closes the transport.
        pub fn disconnect(self: *Self, now: u64) void {
            self.close(now, true);
        }

        fn close(self: *Self, now: u64, notify: bool) void {
            if (self.recording) |recording| recording.add(.disconnect, now, &.{});
            const command = self.session.close();
            if (self.connected) {
                if (notify) {
                    if (command) |value| {
                        const bytes = nativeWrite(protocol.encodeCommand(value));
                        if (self.recording) |recording| recording.add(.send, now, &bytes);
                        // Best effort: the keyboard also stops when unplugged or reset.
                        self.transport.write(&bytes) catch {};
                    }
                }
                self.transport.close();
            }
            self.connected = false;
            self.retry_at = now +| reconnect_ms;
        }

        fn fail(self: *Self, err: anyerror, now: u64) void {
            self.transport_error = err;
            self.status = .transport_error;
            self.close(now, false);
        }

        fn fresh(self: *Self, now: u64) ?u32 {
            return self.nonces.next() catch {
                self.disconnect(now);
                self.status = .nonce_exhausted;
                self.retry_at = std.math.maxInt(u64);
                return null;
            };
        }

        fn send(self: *Self, command: protocol.Command, now: u64) bool {
            const bytes = nativeWrite(protocol.encodeCommand(command));
            if (self.recording) |recording| recording.add(.send, now, &bytes);
            self.transport.write(&bytes) catch |err| {
                self.fail(err, now);
                return false;
            };
            return true;
        }

        /// Explicit UI action only, never retried. The keyboard reboots into
        /// BOOTSEL without replying, so the transport is closed right away and
        /// the caller waits for the BOOTSEL drive.
        pub fn enterBootloader(self: *Self, now: u64) !void {
            if (!self.connected) return error.BootloaderUnavailable;
            if (self.recording) |recording| recording.add(.bootloader, now, &.{});
            const command = self.session.requestBootloader() orelse return error.BootloaderUnavailable;
            if (!self.send(command, now)) {
                // Nothing reached the keyboard, so nothing is waiting for BOOTSEL.
                self.session.bootloader_status = .idle;
                return error.BootloaderTransportFailed;
            }
            self.close(now, false);
        }

        pub fn poll(self: *Self, now: u64) void {
            self.key_event_count = 0;
            self.signal_event_count = 0;
            if (!self.connected) {
                if (now < self.retry_at) return;
                const found = self.transport.discover(self.path) catch |err| {
                    self.fail(err, now);
                    return;
                };
                self.retry_at = now +| reconnect_ms;
                switch (found) {
                    .selected => {
                        self.connected = true;
                        self.status = .connected;
                        self.transport_error = null;
                        const token = self.fresh(now) orelse return;
                        if (self.recording) |recording| recording.token(.connect, now, token);
                        const command = self.session.connect(now, token) catch |err| {
                            self.fail(err, now);
                            return;
                        };
                        if (!self.send(command, now)) return;
                    },
                    .no_device => {
                        self.status = .no_device;
                        return;
                    },
                    .multiple_devices => {
                        self.status = .multiple_devices;
                        return;
                    },
                    .path_not_found => {
                        self.status = .path_not_found;
                        return;
                    },
                }
            }
            const start = self.transport.now();
            for (0..report_budget) |_| {
                if (self.transport.now() -| start >= drain_budget_ms) break;
                var bytes: [33]u8 = undefined;
                const count = self.transport.read(&bytes) catch |err| {
                    self.fail(err, now);
                    return;
                };
                if (count == 0) break;
                // Invalid native lengths enter the same malformed-report path
                // as invalid codec frames; no bytes are silently truncated.
                const report = normalize(bytes[0..@min(count, bytes.len)]) catch {
                    if (!self.receive(&.{}, now)) return;
                    continue;
                };
                if (count > bytes.len) {
                    if (!self.receive(&.{}, now)) return;
                    continue;
                }
                if (!self.receive(&report, now)) return;
            }
            if (self.session.tick(now)) |command| {
                if (self.recording) |recording| recording.add(.tick, now, &.{});
                _ = self.send(command, now);
            }
        }

        fn receive(self: *Self, bytes: []const u8, now: u64) bool {
            if (self.recording) |recording| recording.add(.receive, now, bytes);
            const outcome = self.session.receive(bytes, now);
            if (outcome.key) |event| {
                // The drain budget bounds the count to the storage.
                self.key_events[self.key_event_count] = event;
                self.key_event_count += 1;
            }
            if (outcome.signal) |event| {
                self.signal_events[self.signal_event_count] = event;
                self.signal_event_count += 1;
            }
            if (outcome.send) |command| return self.send(command, now);
            return true;
        }
    };
}

const Fake = struct {
    discovery: Discovery = .selected,
    discovery_count: usize = 0,
    frames: [64]protocol.Report = undefined,
    count: usize = 0,
    cursor: usize = 0,
    writes: [64][33]u8 = undefined,
    write_count: usize = 0,
    closed: bool = false,
    broken: bool = false,
    clock: u64 = 0,
    clock_step: u64 = 0,

    fn discover(self: *Fake, _: ?[]const u8) !Discovery {
        self.discovery_count += 1;
        self.closed = false;
        return self.discovery;
    }

    fn read(self: *Fake, bytes: *[33]u8) !usize {
        if (self.broken) return error.Unplugged;
        if (self.cursor == self.count) return 0;
        @memcpy(bytes[0..32], &self.frames[self.cursor]);
        self.cursor += 1;
        return 32;
    }

    fn write(self: *Fake, bytes: []const u8) !void {
        if (self.broken) return error.Unplugged;
        self.writes[self.write_count] = bytes[0..33].*;
        self.write_count += 1;
    }

    fn close(self: *Fake) void {
        self.closed = true;
    }

    fn now(self: *Fake) u64 {
        const result = self.clock;
        self.clock += self.clock_step;
        return result;
    }

    fn queue(
        self: *Fake,
        message: protocol.Message,
        dimensions: @import("layout-model").KeymapDimensions,
    ) !void {
        self.frames[self.count] = try protocol.encode(message, dimensions);
        self.count += 1;
    }

    fn command(self: *const Fake, index: usize) ?protocol.Command {
        return protocol.decodeCommand(self.writes[index][1..]) catch null;
    }

    fn last(self: *const Fake) ?protocol.Command {
        return if (self.write_count == 0) null else self.command(self.write_count - 1);
    }
};

fn fixture() protocol.Identity {
    return .{
        .board_id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 },
        .profile_id = .{ 't', 'e', 's', 't', 0, 0, 0, 0 },
        .digest = @splat(1),
        .dimensions = .{ .key_count = 4, .layer_count = 2 },
    };
}

fn hello(identity: protocol.Identity) protocol.Message {
    return .{ .hello = .{ .dimensions = identity.dimensions, .keymap_id = identity.digest } };
}

fn attach(driver: *Driver(Fake), identity: protocol.Identity, held: bool) !void {
    driver.poll(0);
    try driver.transport.queue(hello(identity), identity.dimensions);
    var state = protocol.State{ .sequence = 0 };
    if (held) state.pressed[0] = 1;
    try driver.transport.queue(.{ .state = state }, identity.dimensions);
    driver.poll(1);
}

test "vendor selection refuses ambiguous devices and requires exact path" {
    const candidates = [_]Candidate{
        .{ .path = "keyboard", .usage_page = 1 },
        .{ .path = "a" },
        .{ .path = "b" },
    };
    try std.testing.expect(select(&candidates, null) == .multiple_devices);
    try std.testing.expectEqualStrings("b", select(&candidates, "b").selected);
    try std.testing.expect(select(&candidates, "keyboard") == .path_not_found);
    try std.testing.expect(select(&.{}, null) == .no_device);
}

test "native report ID boundaries are exact" {
    const report: protocol.Report = @splat(7);
    try std.testing.expectEqual(report, try normalize(&report));
    var native = nativeWrite(report);
    try std.testing.expectEqual(report, try normalize(&native));
    native[0] = 1;
    try std.testing.expectError(error.InvalidNativeReport, normalize(&native));
    try std.testing.expectError(error.InvalidNativeReport, normalize(report[0..31]));
}

test "a discovered keyboard is connected, synchronised and cleanly disconnected" {
    var driver = try Driver(Fake).init(.{}, fixture(), 100, null);
    try attach(&driver, fixture(), true);
    try std.testing.expectEqual(@as(?protocol.Command, .connect), driver.transport.command(0));
    try std.testing.expectEqual(companion.Phase.live, driver.session.phase);
    try std.testing.expect(driver.session.state.pressed[0]);
    try driver.transport.queue(.{ .key = .{ .sequence = 1, .event = .{
        .pressed = false,
        .key_index = 0,
        .layer = 0,
        .modifiers = .{},
    } } }, fixture().dimensions);
    driver.poll(2);
    try std.testing.expectEqual(@as(usize, 1), driver.key_event_count);
    try std.testing.expect(!driver.session.state.pressed[0]);
    const writes = driver.transport.write_count;
    driver.disconnect(3);
    try std.testing.expectEqual(writes + 1, driver.transport.write_count);
    try std.testing.expectEqual(@as(?protocol.Command, .disconnect), driver.transport.last());
    try std.testing.expect(driver.transport.closed and !driver.connected);
    try std.testing.expectEqual(companion.Phase.disconnected, driver.session.phase);
}

test "unplug closes without a command and reconnect uses a fresh token" {
    var driver = try Driver(Fake).init(.{}, fixture(), 100, null);
    try attach(&driver, fixture(), true);
    const old = driver.session.token;
    const writes = driver.transport.write_count;
    driver.transport.broken = true;
    driver.poll(3);
    try std.testing.expect(!driver.session.hasCoherentState() and driver.transport.closed);
    try std.testing.expectEqual(Status.transport_error, driver.status);
    try std.testing.expectEqual(writes, driver.transport.write_count);
    driver.transport.broken = false;
    driver.poll(500);
    try std.testing.expectEqual(@as(usize, 1), driver.transport.discovery_count);
    driver.poll(1003);
    try std.testing.expect(driver.session.token != old and driver.session.token != 0);
    try std.testing.expectEqual(companion.Phase.negotiating, driver.session.phase);
    try std.testing.expectEqual(@as(?protocol.Command, .connect), driver.transport.last());
}

test "no device sends nothing and a mismatched keymap is refused and disconnected" {
    var driver = try Driver(Fake).init(.{ .discovery = .no_device }, fixture(), 10, null);
    driver.poll(0);
    try std.testing.expectEqual(Status.no_device, driver.status);
    try std.testing.expectEqual(@as(usize, 0), driver.transport.write_count);
    driver.transport.discovery = .selected;
    driver.poll(1000);
    var wrong = fixture();
    wrong.digest[0] = 2;
    try driver.transport.queue(hello(wrong), wrong.dimensions);
    try driver.transport.queue(.{ .state = .{ .sequence = 0 } }, wrong.dimensions);
    driver.poll(1001);
    try std.testing.expectEqual(companion.Phase.incompatible, driver.session.phase);
    try std.testing.expectEqual(companion.Mismatch.keymap_id, driver.session.mismatch.?);
    try std.testing.expectEqual(@as(?protocol.Command, .disconnect), driver.transport.last());
    // Incompatible sessions neither retry nor apply later reports.
    const writes = driver.transport.write_count;
    driver.poll(5000);
    try std.testing.expectEqual(writes, driver.transport.write_count);
    try std.testing.expect(!driver.session.hasCoherentState());
}

test "malformed reports resynchronise and the drain stays bounded" {
    var good = try Driver(Fake).init(.{}, fixture(), 20, null);
    try attach(&good, fixture(), false);
    const writes = good.transport.write_count;
    var malformed: protocol.Report = @splat(0);
    malformed[0] = 0x22;
    malformed[2] = 7;
    good.transport.frames[good.transport.count] = malformed;
    good.transport.count += 1;
    good.poll(3);
    try std.testing.expectEqual(companion.Phase.negotiating, good.session.phase);
    try std.testing.expectEqual(@as(?protocol.ProtocolError, error.InvalidBoolean), good.session.last_error);
    try std.testing.expectEqual(writes + 1, good.transport.write_count);
    try std.testing.expectEqual(@as(?protocol.Command, .connect), good.transport.last());
    var busy = try Driver(Fake).init(.{}, fixture(), 30, null);
    busy.transport.count = 64;
    for (&busy.transport.frames) |*frame| frame.* = @splat(0);
    busy.poll(0);
    try std.testing.expectEqual(@as(usize, report_budget), busy.transport.cursor);
    // Unknown report ids are ignored and never trigger a resync.
    try std.testing.expectEqual(@as(usize, 1), busy.transport.write_count);
}

test "a sequence gap resynchronises with connect and recovers from the fresh state" {
    var driver = try Driver(Fake).init(.{}, fixture(), 200, null);
    try attach(&driver, fixture(), true);
    try driver.transport.queue(.{ .key = .{ .sequence = 2, .event = .{
        .pressed = false,
        .key_index = 0,
        .layer = 0,
        .modifiers = .{},
    } } }, fixture().dimensions);
    driver.poll(3);
    try std.testing.expectEqual(companion.Phase.negotiating, driver.session.phase);
    try std.testing.expect(!driver.session.hasCoherentState());
    try std.testing.expectEqual(@as(usize, 0), driver.key_event_count);
    try std.testing.expectEqual(@as(?protocol.Command, .connect), driver.transport.last());
    try driver.transport.queue(hello(fixture()), fixture().dimensions);
    try driver.transport.queue(.{ .state = .{ .sequence = 3 } }, fixture().dimensions);
    try driver.transport.queue(.{ .key = .{ .sequence = 4, .event = .{
        .pressed = true,
        .key_index = 3,
        .layer = 1,
        .modifiers = .{},
    } } }, fixture().dimensions);
    driver.poll(4);
    try std.testing.expectEqual(companion.Phase.live, driver.session.phase);
    try std.testing.expect(!driver.session.state.pressed[0] and driver.session.state.pressed[3]);
    try std.testing.expectEqual(@as(usize, 1), driver.key_event_count);
    try std.testing.expectEqual(@as(u8, 3), driver.key_events[0].key_index);
}

test "an unanswered connect is retried with bounded backoff" {
    var driver = try Driver(Fake).init(.{}, fixture(), 1, null);
    driver.poll(0);
    try std.testing.expectEqual(@as(usize, 1), driver.transport.write_count);
    driver.poll(499);
    try std.testing.expectEqual(@as(usize, 1), driver.transport.write_count);
    for ([_]u64{ 500, 1000, 2000, 3000 }, 2..) |time, writes| {
        driver.poll(time);
        try std.testing.expectEqual(writes, driver.transport.write_count);
        try std.testing.expectEqual(@as(?protocol.Command, .connect), driver.transport.last());
    }
    driver.poll(3999);
    try std.testing.expectEqual(@as(usize, 5), driver.transport.write_count);
}

test "fake ambiguous discovery and token exhaustion never reuse a token" {
    var driver = try Driver(Fake).init(.{ .discovery = .multiple_devices }, fixture(), 1, null);
    driver.poll(0);
    try std.testing.expectEqual(Status.multiple_devices, driver.status);
    try std.testing.expectEqual(@as(usize, 0), driver.transport.write_count);
    var nonces = Nonces{ .value = std.math.maxInt(u32), .remaining = 1 };
    try std.testing.expectEqual(@as(u32, 1), try nonces.next());
    try std.testing.expectError(error.NonceExhausted, nonces.next());
}

test "fake elapsed drain budget returns UI and capture replays final state" {
    var driver = try Driver(Fake).init(.{ .clock_step = 1 }, fixture(), 17, null);
    driver.transport.count = 64;
    for (&driver.transport.frames) |*frame| frame.* = @splat(0);
    driver.poll(0);
    try std.testing.expectEqual(@as(usize, 1), driver.transport.cursor);
    var recorder = try capture.Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    var recorded = try Driver(Fake).init(.{}, fixture(), 18, null);
    recorded.recording = &recorder;
    try attach(&recorded, fixture(), true);
    const live = try capture.replay(recorder.encoded(), fixture());
    try std.testing.expectEqual(companion.Phase.live, live.phase);
    try std.testing.expectEqual(recorded.session.state.pressed, live.state.pressed);
    try recorded.transport.queue(.{ .key = .{ .sequence = 9, .event = .{
        .pressed = false,
        .key_index = 0,
        .layer = 0,
        .modifiers = .{},
    } } }, fixture().dimensions);
    recorded.poll(2);
    recorded.poll(600);
    recorded.disconnect(601);
    const replayed = try capture.replay(recorder.encoded(), fixture());
    try std.testing.expectEqual(recorded.session.phase, replayed.phase);
    try std.testing.expectEqual(recorded.session.state.pressed, replayed.state.pressed);
}

test "bootloader is one explicit command after a coherent session, then the transport closes" {
    var driver = try Driver(Fake).init(.{}, fixture(), 300, null);
    try std.testing.expectError(error.BootloaderUnavailable, driver.enterBootloader(0));
    driver.poll(0);
    try std.testing.expectError(error.BootloaderUnavailable, driver.enterBootloader(0));
    try driver.transport.queue(hello(fixture()), fixture().dimensions);
    try driver.transport.queue(.{ .state = .{ .sequence = 0 } }, fixture().dimensions);
    driver.poll(1);
    try std.testing.expect(driver.session.bootloaderAvailable());
    const before = driver.transport.write_count;
    try driver.enterBootloader(4);
    try std.testing.expectEqual(before + 1, driver.transport.write_count);
    try std.testing.expectEqual(@as(?protocol.Command, .enter_bootloader), driver.transport.last());
    try std.testing.expect(driver.transport.closed and !driver.connected);
    try std.testing.expectEqual(companion.BootloaderStatus.sent, driver.session.bootloader_status);
    try std.testing.expectError(error.BootloaderUnavailable, driver.enterBootloader(5));
    // While the keyboard sits in BOOTSEL there is no HID device to reconnect to.
    driver.transport.discovery = .no_device;
    driver.poll(10000);
    try std.testing.expectEqual(companion.BootloaderStatus.sent, driver.session.bootloader_status);
    var boot_requests: usize = 0;
    for (0..driver.transport.write_count) |index| {
        if (driver.transport.command(index) == .enter_bootloader) boot_requests += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), boot_requests);
}

test "a failed bootloader write reports a transport failure" {
    var driver = try Driver(Fake).init(.{}, fixture(), 400, null);
    try attach(&driver, fixture(), false);
    driver.transport.broken = true;
    try std.testing.expectError(error.BootloaderTransportFailed, driver.enterBootloader(2));
    try std.testing.expectEqual(Status.transport_error, driver.status);
    try std.testing.expectEqual(companion.BootloaderStatus.idle, driver.session.bootloader_status);
}
