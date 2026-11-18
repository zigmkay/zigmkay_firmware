// SPDX-License-Identifier: GPL-2.0
//! Companion-owned host codec for the zigmkay companion Raw HID session,
//! protocol version 1 (zigmkay_firmware PR #60, `zigmkay/src/companion.zig`).
//!
//! Every report is 32 bytes on the existing Raw HID interface (vendor page
//! 0xFF31, usage 0x74) and starts with a message id. The keyboard sends
//! nothing until the host connects.
//!
//! Host to keyboard:
//!   0x10 connect           the keyboard answers hello, then state
//!   0x11 disconnect        the keyboard stops streaming
//!   0x12 enter bootloader  the keyboard reboots into BOOTSEL without a reply
//!
//! Keyboard to host:
//!   0x20 hello  [1] version [2] key count [3] layer count [4..20] keymap id
//!   0x21 state  [1] seq [2] top layer [3] modifiers [4..6] active-layer mask
//!               (u16 little endian, bit 0 always set) [6..22] pressed keys
//!   0x22 key    [1] seq [2] pressed [3] key index [4] layer [5] modifiers
//!   0x23 signal [1] seq [2] kind (1 log toggle, 2 overlay toggle, 3 shutdown)
//!               [3] pressed
//!
//! State, key and signal reports share a u8 sequence that wraps. Key reports carry the
//! layer and modifiers at scan time, before processing. Unknown report ids,
//! for example the legacy 0x03 trace, are ignored. Bytes after a message's
//! fields are not interpreted.
const std = @import("std");
const core = @import("zigmkay").core;
pub const identity = @import("identity.zig");

pub const protocol_version: u8 = 1;
pub const report_size = 32;
pub const Report = [report_size]u8;
pub const KeymapId = [16]u8;
/// Firmware reports all zeros when its keymap was not generated with an id.
pub const unknown_keymap_id: KeymapId = @splat(0);

pub const Command = enum(u8) {
    connect = 0x10,
    disconnect = 0x11,
    enter_bootloader = 0x12,
};

pub const MessageId = enum(u8) {
    hello = 0x20,
    state = 0x21,
    key = 0x22,
    signal = 0x23,
};

/// Companion keys on the keyboard, reported after its tap/hold decision.
pub const SignalKind = enum(u8) { log_toggle = 1, overlay_toggle = 2, shutdown = 3 };
pub const SignalEvent = struct { kind: SignalKind, pressed: bool };

pub const KeyEvent = struct {
    pressed: bool,
    key_index: core.KeyIndex,
    layer: core.LayerIndex,
    modifiers: core.Modifiers,
};

pub const Hello = struct {
    version: u8 = protocol_version,
    dimensions: core.KeymapDimensions,
    keymap_id: KeymapId = unknown_keymap_id,
};

pub const State = struct {
    sequence: u8,
    highest_layer: core.LayerIndex = 0,
    /// One bit per active layer; bit 0 (the base layer) is always set.
    active_layers: u16 = 1,
    modifiers: core.Modifiers = .{},
    /// One bit per key index, least significant bit first.
    pressed: [16]u8 = @splat(0),

    pub fn isPressed(self: State, key_index: usize) bool {
        return self.pressed[key_index / 8] & (@as(u8, 1) << @as(u3, @intCast(key_index % 8))) != 0;
    }
};

pub const Key = struct { sequence: u8, event: KeyEvent };
pub const Signal = struct { sequence: u8, event: SignalEvent };

pub const Message = union(MessageId) {
    hello: Hello,
    state: State,
    key: Key,
    signal: Signal,

    /// Hello carries no sequence number.
    pub fn sequence(self: Message) ?u8 {
        return switch (self) {
            .hello => null,
            .state => |state| state.sequence,
            .key => |key| key.sequence,
            .signal => |signal| signal.sequence,
        };
    }
};

pub const WireError = error{ InvalidLength, InvalidDimensions, UnsupportedVersion, InvalidBoolean, InvalidKeyIndex, InvalidLayer, InvalidLayerMask, InvalidSignal };
pub const ProtocolError = WireError || identity.Error;

pub const Identity = identity.Identity;
pub const CallbackIdentity = identity.CallbackIdentity;
pub const IdentityInput = identity.IdentityInput;
pub const computeIdentity = identity.computeIdentity;
pub const validateId = identity.validateId;
pub const validateIdentity = identity.validateIdentity;
pub const keymapId = identity.keymapId;

pub fn isUnknownKeymap(id: KeymapId) bool {
    return std.mem.allEqual(u8, &id, 0);
}

/// Dimensions need at least one key and one layer. The core index types already
/// bound them to 127 keys and 15 layers.
pub fn validateDimensions(dimensions: core.KeymapDimensions) WireError!void {
    if (dimensions.key_count == 0 or dimensions.layer_count == 0) return error.InvalidDimensions;
}

/// The mask includes the base layer, only names existing layers, and contains
/// the reported top layer.
pub fn validateLayers(
    active_layers: u16,
    highest_layer: core.LayerIndex,
    dimensions: core.KeymapDimensions,
) WireError!void {
    try validateDimensions(dimensions);
    if (highest_layer >= dimensions.layer_count) return error.InvalidLayer;
    const allowed = (@as(u16, 1) << dimensions.layer_count) - 1;
    if (active_layers & 1 == 0 or active_layers & ~allowed != 0) return error.InvalidLayerMask;
    if (active_layers & (@as(u16, 1) << highest_layer) == 0) return error.InvalidLayerMask;
}

/// Validates a keyboard message against the expected keymap dimensions. Hello
/// is checked for its own consistency; matching it is the session's job.
pub fn validate(message: Message, dimensions: core.KeymapDimensions) WireError!void {
    try validateDimensions(dimensions);
    switch (message) {
        .hello => |hello| {
            if (hello.version != protocol_version) return error.UnsupportedVersion;
            try validateDimensions(hello.dimensions);
        },
        .state => |state| {
            try validateLayers(state.active_layers, state.highest_layer, dimensions);
            for (@as(usize, dimensions.key_count)..128) |index| {
                if (state.isPressed(index)) return error.InvalidKeyIndex;
            }
        },
        .key => |key| {
            if (key.event.key_index >= dimensions.key_count) return error.InvalidKeyIndex;
            if (key.event.layer >= dimensions.layer_count) return error.InvalidLayer;
        },
        .signal => {},
    }
}

/// Decodes one keyboard report. Returns null for report ids this protocol does
/// not define, which callers must ignore.
pub fn decode(bytes: []const u8, dimensions: core.KeymapDimensions) WireError!?Message {
    if (bytes.len != report_size) return error.InvalidLength;
    try validateDimensions(dimensions);
    const id = std.enums.fromInt(MessageId, bytes[0]) orelse return null;
    const message: Message = switch (id) {
        .hello => blk: {
            if (bytes[1] != protocol_version) return error.UnsupportedVersion;
            if (bytes[2] == 0 or
                bytes[2] > std.math.maxInt(core.KeyIndex) or
                bytes[3] == 0 or
                bytes[3] > std.math.maxInt(core.LayerIndex)) return error.InvalidDimensions;
            break :blk .{ .hello = .{
                .version = bytes[1],
                .dimensions = .{ .key_count = @intCast(bytes[2]), .layer_count = @intCast(bytes[3]) },
                .keymap_id = bytes[4..20].*,
            } };
        },
        .state => blk: {
            if (bytes[2] > std.math.maxInt(core.LayerIndex)) return error.InvalidLayer;
            break :blk .{ .state = .{
                .sequence = bytes[1],
                .highest_layer = @intCast(bytes[2]),
                .modifiers = core.Modifiers.fromByte(bytes[3]),
                .active_layers = std.mem.readInt(u16, bytes[4..6], .little),
                .pressed = bytes[6..22].*,
            } };
        },
        .key => blk: {
            if (bytes[2] > 1) return error.InvalidBoolean;
            if (bytes[3] > std.math.maxInt(core.KeyIndex)) return error.InvalidKeyIndex;
            if (bytes[4] > std.math.maxInt(core.LayerIndex)) return error.InvalidLayer;
            break :blk .{ .key = .{ .sequence = bytes[1], .event = .{
                .pressed = bytes[2] == 1,
                .key_index = @intCast(bytes[3]),
                .layer = @intCast(bytes[4]),
                .modifiers = core.Modifiers.fromByte(bytes[5]),
            } } };
        },
        .signal => blk: {
            const kind = std.enums.fromInt(SignalKind, bytes[2]) orelse return error.InvalidSignal;
            if (bytes[3] > 1) return error.InvalidBoolean;
            break :blk .{ .signal = .{
                .sequence = bytes[1],
                .event = .{ .kind = kind, .pressed = bytes[3] == 1 },
            } };
        },
    };
    try validate(message, dimensions);
    return message;
}

/// Encodes a keyboard report exactly as firmware does. The companion only
/// uses this for fakes, captures and tests; it never acts as a keyboard.
pub fn encode(message: Message, dimensions: core.KeymapDimensions) WireError!Report {
    try validate(message, dimensions);
    var report: Report = @splat(0);
    report[0] = @backingInt(std.meta.activeTag(message));
    switch (message) {
        .hello => |hello| {
            report[1] = hello.version;
            report[2] = hello.dimensions.key_count;
            report[3] = hello.dimensions.layer_count;
            report[4..20].* = hello.keymap_id;
        },
        .state => |state| {
            report[1] = state.sequence;
            report[2] = state.highest_layer;
            report[3] = state.modifiers.toByte();
            std.mem.writeInt(u16, report[4..6], state.active_layers, .little);
            report[6..22].* = state.pressed;
        },
        .key => |key| {
            report[1] = key.sequence;
            report[2] = @intFromBool(key.event.pressed);
            report[3] = key.event.key_index;
            report[4] = key.event.layer;
            report[5] = key.event.modifiers.toByte();
        },
        .signal => |signal| {
            report[1] = signal.sequence;
            report[2] = @backingInt(signal.event.kind);
            report[3] = @intFromBool(signal.event.pressed);
        },
    }
    return report;
}

/// Host commands carry no payload; the rest of the report is zero.
pub fn encodeCommand(command: Command) Report {
    var report: Report = @splat(0);
    report[0] = @backingInt(command);
    return report;
}

/// Decodes a host command as the keyboard reads it: unknown ids are null.
pub fn decodeCommand(bytes: []const u8) WireError!?Command {
    if (bytes.len != report_size) return error.InvalidLength;
    return std.enums.fromInt(Command, bytes[0]);
}

test {
    _ = identity;
}

const test_dimensions = core.KeymapDimensions{ .key_count = 36, .layer_count = 4 };

fn literal(prefix: []const u8) Report {
    var report: Report = @splat(0);
    @memcpy(report[0..prefix.len], prefix);
    return report;
}

test "hello decodes version dimensions and keymap id" {
    const bytes = literal(&(.{ 0x20, 1, 36, 4 } ++ @as([16]u8, @splat(0xAB))));
    const message = (try decode(&bytes, test_dimensions)).?;
    try std.testing.expectEqualDeep(Message{ .hello = .{
        .dimensions = test_dimensions,
        .keymap_id = @splat(0xAB),
    } }, message);
    try std.testing.expectEqual(@as(?u8, null), message.sequence());
    try std.testing.expect(!isUnknownKeymap(message.hello.keymap_id));
    // Hello is decoded independently of the expected dimensions.
    const other = literal(&.{ 0x20, 1, 34, 6 });
    const unknown = (try decode(&other, test_dimensions)).?.hello;
    try std.testing.expectEqual(
        core.KeymapDimensions{ .key_count = 34, .layer_count = 6 },
        unknown.dimensions,
    );
    try std.testing.expect(isUnknownKeymap(unknown.keymap_id));
}

test "state decodes layers modifiers and pressed bitmap" {
    var bytes = literal(&.{ 0x21, 0, 2, 0x02, 0b0111, 0 });
    bytes[6 + 1] = 0b10;
    const state = (try decode(&bytes, test_dimensions)).?.state;
    try std.testing.expectEqual(@as(u8, 0), state.sequence);
    try std.testing.expectEqual(@as(core.LayerIndex, 2), state.highest_layer);
    try std.testing.expectEqual(@as(u16, 0b0111), state.active_layers);
    try std.testing.expect(state.modifiers.left_shift);
    try std.testing.expect(state.isPressed(9));
    try std.testing.expect(!state.isPressed(8));
}

test "key decodes sequence press index layer and modifiers" {
    const bytes = literal(&.{ 0x22, 1, 1, 5, 1, 0x81 });
    const key = (try decode(&bytes, test_dimensions)).?.key;
    try std.testing.expectEqual(@as(u8, 1), key.sequence);
    try std.testing.expectEqualDeep(KeyEvent{
        .pressed = true,
        .key_index = 5,
        .layer = 1,
        .modifiers = core.Modifiers.fromByte(0x81),
    }, key.event);
}

test "signal decodes sequence kind and press" {
    const bytes = literal(&.{ 0x23, 4, 2, 1 });
    const signal = (try decode(&bytes, test_dimensions)).?.signal;
    try std.testing.expectEqual(@as(u8, 4), signal.sequence);
    try std.testing.expectEqualDeep(SignalEvent{ .kind = .overlay_toggle, .pressed = true }, signal.event);
    try std.testing.expectEqual(bytes, try encode(.{ .signal = signal }, test_dimensions));
    try std.testing.expectError(error.InvalidSignal, decode(&literal(&.{ 0x23, 4, 9, 1 }), test_dimensions));
    try std.testing.expectError(error.InvalidBoolean, decode(&literal(&.{ 0x23, 4, 2, 2 }), test_dimensions));
}

test "decoder ignores unknown report ids including the legacy trace" {
    for ([_]u8{ 0x00, 0x03, 0x10, 0x11, 0x12, 0x24, 0x7F, 0xA7, 0xFF }) |id| {
        const bytes = literal(&.{ id, 1, 2, 3 });
        try std.testing.expectEqual(@as(?Message, null), try decode(&bytes, test_dimensions));
    }
}

test "decoder rejects bad lengths versions dimensions and values" {
    const t = std.testing;
    const valid = literal(&.{ 0x22, 1, 1, 5, 1, 0 });
    try t.expectError(error.InvalidLength, decode(valid[0..31], test_dimensions));
    try t.expectError(error.InvalidLength, decode(&(valid ++ .{0}), test_dimensions));
    try t.expectError(error.InvalidDimensions, decode(&valid, .{ .key_count = 0, .layer_count = 4 }));
    try t.expectError(error.UnsupportedVersion, decode(&literal(&.{ 0x20, 2, 36, 4 }), test_dimensions));
    try t.expectError(error.InvalidDimensions, decode(&literal(&.{ 0x20, 1, 0, 4 }), test_dimensions));
    try t.expectError(error.InvalidDimensions, decode(&literal(&.{ 0x20, 1, 36, 0 }), test_dimensions));
    try t.expectError(error.InvalidDimensions, decode(&literal(&.{ 0x20, 1, 128, 4 }), test_dimensions));
    try t.expectError(error.InvalidDimensions, decode(&literal(&.{ 0x20, 1, 36, 16 }), test_dimensions));
    try t.expectError(error.InvalidBoolean, decode(&literal(&.{ 0x22, 1, 2, 5, 1, 0 }), test_dimensions));
    try t.expectError(error.InvalidKeyIndex, decode(&literal(&.{ 0x22, 1, 1, 36, 1, 0 }), test_dimensions));
    try t.expectError(error.InvalidKeyIndex, decode(&literal(&.{ 0x22, 1, 1, 200, 1, 0 }), test_dimensions));
    try t.expectError(error.InvalidLayer, decode(&literal(&.{ 0x22, 1, 1, 5, 4, 0 }), test_dimensions));
    try t.expectError(error.InvalidLayer, decode(&literal(&.{ 0x21, 1, 4, 0, 0b10001, 0 }), test_dimensions));
    try t.expectError(error.InvalidLayer, decode(&literal(&.{ 0x21, 1, 16, 0, 1, 0 }), test_dimensions));
    // The base layer is always active, the mask names existing layers only,
    // and the top layer is active.
    try t.expectError(error.InvalidLayerMask, decode(&literal(&.{ 0x21, 1, 0, 0, 0, 0 }), test_dimensions));
    try t.expectError(
        error.InvalidLayerMask,
        decode(&literal(&.{ 0x21, 1, 0, 0, 0b10001, 0 }), test_dimensions),
    );
    try t.expectError(
        error.InvalidLayerMask,
        decode(&literal(&.{ 0x21, 1, 2, 0, 0b0011, 0 }), test_dimensions),
    );
    var pressed = literal(&.{ 0x21, 1, 0, 0, 1, 0 });
    pressed[6 + 4] = 0b10000; // key 36 is past the last key
    try t.expectError(error.InvalidKeyIndex, decode(&pressed, test_dimensions));
}

test "arbitrary reports either fail, are ignored, or reencode their fields" {
    for (0..256) |id| for (0..256) |value| for ([_]usize{ 1, 2, 3, 4, 5, 6 }) |index| {
        var bytes = literal(&.{ @intCast(id), 1, 1, 3, 1, 0 });
        bytes[index] = @intCast(value);
        const message = (decode(&bytes, test_dimensions) catch continue) orelse continue;
        const report = try encode(message, test_dimensions);
        try std.testing.expectEqualDeep(message, (try decode(&report, test_dimensions)).?);
    };
}

test "commands encode as zero padded reports and decode like the keyboard" {
    for ([_]Command{ .connect, .disconnect, .enter_bootloader }, [_]u8{ 0x10, 0x11, 0x12 }) |command, id| {
        const report = encodeCommand(command);
        try std.testing.expectEqual(literal(&.{id}), report);
        try std.testing.expectEqual(@as(?Command, command), try decodeCommand(&report));
    }
    try std.testing.expectEqual(@as(?Command, null), try decodeCommand(&literal(&.{0x7F})));
    try std.testing.expectError(error.InvalidLength, decodeCommand(&.{0x10}));
}
