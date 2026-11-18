// SPDX-License-Identifier: GPL-2.0
//! Adapted from zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f.
//! Explicit bounded timed reducer-input and host-control capture, version 2
//! (companion Raw HID session, protocol version 1).
const std = @import("std");
const protocol = @import("device-protocol");
const companion = @import("companion-model");

test "full bounded capture survives file read and replay" {
    var recorder = try Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    for (0..max_records) |index| recorder.add(.disconnect, index, &.{});
    try std.testing.expectEqual(max_bytes, recorder.encoded().len);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "full.bin", .data = recorder.encoded() });
    const bytes = try temp.dir.readFileAlloc(
        std.testing.io,
        "full.bin",
        std.testing.allocator,
        .limited(max_bytes + 1),
    );
    defer std.testing.allocator.free(bytes);
    const session = try replay(bytes, fixture);
    try std.testing.expectEqual(companion.Phase.disconnected, session.phase);
}

pub const magic = "ZMKCAP02";
pub const record_size = 48;
pub const max_records = 4096;
pub const max_bytes = magic.len + record_size * max_records;
/// connect carries the host token; tick is recorded only when it produced a
/// command; send carries the native 33-byte write; bootloader marks the
/// explicit request.
pub const Kind = enum(u8) { connect = 1, tick = 2, receive = 3, disconnect = 4, send = 5, bootloader = 7 };

pub const Recorder = struct {
    records: []u8,
    used: usize = 0,
    full: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Recorder {
        return .{ .records = try allocator.alloc(u8, max_bytes) };
    }

    pub fn deinit(self: *Recorder, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
    }

    pub fn add(self: *Recorder, kind: Kind, now: u64, bytes: []const u8) void {
        if (self.used == 0) {
            @memcpy(self.records[0..magic.len], magic);
            self.used = magic.len;
        }
        if (bytes.len > 33 or self.used + record_size > self.records.len) {
            self.full = true;
            return;
        }
        const record = self.records[self.used..][0..record_size];
        @memset(record, 0);
        std.mem.writeInt(u64, record[0..8], now, .little);
        record[8] = @backingInt(kind);
        record[9] = @intCast(bytes.len);
        @memcpy(record[10..][0..bytes.len], bytes);
        self.used += record_size;
    }

    pub fn token(self: *Recorder, kind: Kind, now: u64, value: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        self.add(kind, now, &bytes);
    }

    pub fn encoded(self: *const Recorder) []const u8 {
        return if (self.used == 0) magic else self.records[0..self.used];
    }
};

/// Replays elapsed times, connect tokens, received reports, explicit requests
/// and disconnects, and verifies every recorded host command against the same
/// pure Session. A disconnect command may be missing from the capture when
/// the transport had already failed.
pub fn replay(bytes: []const u8, expected: protocol.Identity) !companion.Session {
    if (bytes.len < magic.len or
        !std.mem.eql(u8, bytes[0..magic.len], magic) or
        bytes.len > max_bytes or
        (bytes.len - magic.len) % record_size != 0) return error.InvalidCapture;
    var session = try companion.Session.init(expected);
    var previous: u64 = 0;
    var pending: ?protocol.Command = null;
    var offset: usize = magic.len;
    while (offset < bytes.len) : (offset += record_size) {
        const record = bytes[offset..][0..record_size];
        const now = std.mem.readInt(u64, record[0..8], .little);
        if (now < previous or record[9] > 33) return error.InvalidCapture;
        previous = now;
        const data = record[10..][0..record[9]];
        for (record[10 + data.len ..]) |padding| if (padding != 0) return error.InvalidCapture;
        const kind = std.enums.fromInt(Kind, record[8]) orelse return error.InvalidCapture;
        if (kind == .send) {
            const command = pending orelse return error.ControlMismatch;
            if (data.len != 33 or data[0] != 0) return error.ControlMismatch;
            if (!std.mem.eql(u8, &protocol.encodeCommand(command), data[1..])) return error.ControlMismatch;
            pending = null;
            continue;
        }
        if (pending) |command| if (command != .disconnect) return error.MissingControl;
        pending = switch (kind) {
            .connect => blk: {
                if (data.len != 4) return error.InvalidCapture;
                break :blk try session.connect(now, std.mem.readInt(u32, data[0..4], .little));
            },
            .tick => blk: {
                if (data.len != 0) return error.InvalidCapture;
                break :blk session.tick(now) orelse return error.ControlMismatch;
            },
            .receive => session.receive(data, now).send,
            .disconnect => blk: {
                if (data.len != 0) return error.InvalidCapture;
                break :blk session.close();
            },
            .bootloader => blk: {
                if (data.len != 0) return error.InvalidCapture;
                break :blk session.requestBootloader();
            },
            .send => unreachable,
        };
    }
    // A full capture can intentionally stop at a pending command; retain its
    // state rather than asserting that a failed session became live.
    return session;
}

const fixture = protocol.Identity{
    .board_id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 },
    .profile_id = .{ 't', 0, 0, 0, 0, 0, 0, 0 },
    .digest = @splat(1),
    .dimensions = .{ .key_count = 1, .layer_count = 1 },
};

fn recordSend(recorder: *Recorder, now: u64, command: ?protocol.Command) void {
    if (command) |value| recorder.add(.send, now, &([_]u8{0} ++ protocol.encodeCommand(value)));
}

test "timed capture verifies retries, a received hello and state, and disconnect" {
    var recorder = try Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    var session = try companion.Session.init(fixture);
    recorder.token(.connect, 0, 7);
    recordSend(&recorder, 0, try session.connect(0, 7));
    for ([_]u64{ 500, 1000 }) |time| {
        const command = session.tick(time);
        recorder.add(.tick, time, &.{});
        recordSend(&recorder, time, command);
    }
    for ([_]protocol.Message{
        .{ .hello = .{ .dimensions = fixture.dimensions, .keymap_id = fixture.digest } },
        .{ .state = .{ .sequence = 5, .pressed = .{1} ++ @as([15]u8, @splat(0)) } },
    }) |message| {
        const report = try protocol.encode(message, fixture.dimensions);
        recorder.add(.receive, 1001, &report);
        recordSend(&recorder, 1001, session.receive(&report, 1001).send);
    }
    const live = try replay(recorder.encoded(), fixture);
    try std.testing.expectEqual(companion.Phase.live, live.phase);
    try std.testing.expect(live.state.pressed[0]);
    recorder.add(.disconnect, 2501, &.{});
    recordSend(&recorder, 2501, session.close());
    const result = try replay(recorder.encoded(), fixture);
    try std.testing.expectEqual(session.phase, result.phase);
    try std.testing.expect(!result.hasCoherentState());
    // Corrupting the second recorded connect write is detected.
    recorder.records[magic.len + 3 * record_size + 11] ^= 1;
    try std.testing.expectError(error.ControlMismatch, replay(recorder.encoded(), fixture));
}

test "capture rejects missing controls and malformed records" {
    var recorder = try Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    recorder.token(.connect, 0, 7);
    recorder.add(.tick, 1, &.{});
    try std.testing.expectError(error.MissingControl, replay(recorder.encoded(), fixture));
    try std.testing.expectError(error.InvalidCapture, replay("ZMKCAP01", fixture));
    var unsent = try Recorder.init(std.testing.allocator);
    defer unsent.deinit(std.testing.allocator);
    unsent.add(.tick, 0, &.{});
    try std.testing.expectError(error.ControlMismatch, replay(unsent.encoded(), fixture));
}

test "capture memory and file limits are explicit" {
    var recorder = try Recorder.init(std.testing.allocator);
    defer recorder.deinit(std.testing.allocator);
    for (0..max_records + 1) |n| recorder.add(.disconnect, n, &.{});
    try std.testing.expect(recorder.full);
    try std.testing.expectEqual(max_bytes, recorder.encoded().len);
}
