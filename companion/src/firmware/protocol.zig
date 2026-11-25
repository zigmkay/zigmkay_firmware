// SPDX-License-Identifier: GPL-2.0-or-later
//! Companion-owned host codec for the zigmkay companion Raw HID session,
//! protocol versions 1 and 2 (`zigmkay/src/companion.zig`).
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
//!               [3] pressed [4] source (version 2: 1 tap action, 2 hold
//!               action; 0 and other values are unknown, which version 1
//!               keyboards and earlier version 2 builds send as padding)
//!   0x24 decision (version 2) [1] seq [2] key index [3] outcome (1 tap,
//!               2 hold, 3 retro tap) [4] reason (1 released within the
//!               tapping term, 2 term elapsed, 3 permissive hold, 4 same-side
//!               tap, 5 released after the term) [5..7] ms from press to
//!               decision (u16 little endian, saturating) [7] other key index
//!               or 0xFF [8..10] tapping term ms (u16 little endian)
//!               [10] layer of the key [11] flags (bit 0 combo; other bits
//!               are ignored)
//!
//! A version 1 keyboard never sends decisions; the host accepts both versions.
//! State, key, signal and decision reports share a u8 sequence that wraps.
//! Key reports carry the layer and modifiers at scan time, before processing.
//! A decision follows the key report of its press. Unknown report ids,
//! for example the legacy 0x03 trace, are ignored. Bytes after a message's
//! fields are not interpreted.
const std = @import("std");
pub const core = @import("zigmkay").core;
pub const identity = @import("identity.zig");
/// The keyboard side of this protocol. Ids, sizes and the version below are
/// taken from it; byte offsets are not named there and stay spelled out here.
pub const firmware = @import("zigmkay").companion;

/// The version this host speaks and its fakes send in hello.
pub const protocol_version: u8 = firmware.protocol_version;
/// The oldest keyboard version the host accepts; it never sends decisions.
pub const min_protocol_version: u8 = 1;

pub fn supportsVersion(version: u8) bool {
    return version >= min_protocol_version and version <= protocol_version;
}
pub const report_size = @sizeOf(firmware.Report);
pub const Report = firmware.Report;
pub const KeymapId = @FieldType(firmware.Info, "keymap_id");
/// Firmware reports all zeros when its keymap was not generated with an id.
pub const unknown_keymap_id: KeymapId = @splat(0);

/// Exhaustive, unlike the firmware's: the host only sends commands it knows.
pub const Command = enum(u8) {
    connect = @backingInt(firmware.Command.connect),
    disconnect = @backingInt(firmware.Command.disconnect),
    enter_bootloader = @backingInt(firmware.Command.enter_bootloader),
};

pub const MessageId = firmware.MessageId;

/// Companion keys on the keyboard, reported after its tap/hold decision.
pub const SignalKind = firmware.Signal;
/// Whether the key's tap or hold action sent a signal; unknown when the
/// keyboard does not say.
pub const SignalSource = firmware.SignalSource;
pub const SignalEvent = struct { kind: SignalKind, pressed: bool, source: SignalSource = .unknown };

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

pub const DecisionOutcome = firmware.DecisionOutcome;
pub const DecisionReason = firmware.DecisionReason;

/// How the keyboard resolved a tap/hold key (protocol version 2): key index,
/// outcome, reason, ms from press to decision (saturating), the other key of
/// a permissive hold or same-side tap, tapping term, layer and combo flag.
pub const TapHoldDecision = firmware.Decision;

pub const Decision = struct { sequence: u8, event: TapHoldDecision };

pub const Message = union(MessageId) {
    hello: Hello,
    state: State,
    key: Key,
    signal: Signal,
    decision: Decision,

    /// Hello carries no sequence number.
    pub fn sequence(self: Message) ?u8 {
        return switch (self) {
            .hello => null,
            .state => |state| state.sequence,
            .key => |key| key.sequence,
            .signal => |signal| signal.sequence,
            .decision => |decision| decision.sequence,
        };
    }
};

pub const WireError = error{ InvalidLength, InvalidDimensions, UnsupportedVersion, InvalidBoolean, InvalidKeyIndex, InvalidLayer, InvalidLayerMask, InvalidSignal, InvalidDecision };
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
            if (!supportsVersion(hello.version)) return error.UnsupportedVersion;
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
        .decision => |decision| {
            const event = decision.event;
            if (event.key_index >= dimensions.key_count) return error.InvalidKeyIndex;
            if (event.other_key) |other| if (other >= dimensions.key_count) return error.InvalidKeyIndex;
            if (event.layer >= dimensions.layer_count) return error.InvalidLayer;
        },
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
            if (!supportsVersion(bytes[1])) return error.UnsupportedVersion;
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
                .event = .{
                    .kind = kind,
                    .pressed = bytes[3] == 1,
                    .source = std.enums.fromInt(SignalSource, bytes[4]) orelse .unknown,
                },
            } };
        },
        .decision => blk: {
            const outcome = std.enums.fromInt(DecisionOutcome, bytes[3]) orelse return error.InvalidDecision;
            const reason = std.enums.fromInt(DecisionReason, bytes[4]) orelse return error.InvalidDecision;
            if (bytes[2] > std.math.maxInt(core.KeyIndex)) return error.InvalidKeyIndex;
            const other: ?core.KeyIndex = if (bytes[7] == firmware.no_other_key)
                null
            else if (bytes[7] > std.math.maxInt(core.KeyIndex))
                return error.InvalidKeyIndex
            else
                @intCast(bytes[7]);
            if (bytes[10] > std.math.maxInt(core.LayerIndex)) return error.InvalidLayer;
            break :blk .{ .decision = .{ .sequence = bytes[1], .event = .{
                .key_index = @intCast(bytes[2]),
                .outcome = outcome,
                .reason = reason,
                .elapsed_ms = std.mem.readInt(u16, bytes[5..7], .little),
                .other_key = other,
                .tapping_term_ms = std.mem.readInt(u16, bytes[8..10], .little),
                .layer = @intCast(bytes[10]),
                .combo = bytes[11] & 1 != 0,
            } } };
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
            report[4] = @backingInt(signal.event.source);
        },
        .decision => |decision| {
            const event = decision.event;
            report[1] = decision.sequence;
            report[2] = event.key_index;
            report[3] = @backingInt(event.outcome);
            report[4] = @backingInt(event.reason);
            std.mem.writeInt(u16, report[5..7], event.elapsed_ms, .little);
            report[7] = if (event.other_key) |other| other else firmware.no_other_key;
            std.mem.writeInt(u16, report[8..10], event.tapping_term_ms, .little);
            report[10] = event.layer;
            report[11] = @intFromBool(event.combo);
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
    const bytes = literal(&(.{ 0x20, 2, 36, 4 } ++ @as([16]u8, @splat(0xAB))));
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

test "signal decodes its tap or hold source, anything else is unknown" {
    const t = std.testing;
    for ([_]u8{ 1, 2 }, [_]SignalSource{ .tap, .hold }) |byte, source| {
        const bytes = literal(&.{ 0x23, 5, 2, 0, byte });
        const signal = (try decode(&bytes, test_dimensions)).?.signal;
        try t.expectEqualDeep(SignalEvent{ .kind = .overlay_toggle, .pressed = false, .source = source }, signal.event);
        try t.expectEqual(bytes, try encode(.{ .signal = signal }, test_dimensions));
    }
    // Older keyboards pad with zero; unassigned values are not an error.
    for ([_]u8{ 0, 3, 0xFF }) |byte| {
        const signal = (try decode(&literal(&.{ 0x23, 5, 2, 1, byte }), test_dimensions)).?.signal;
        try t.expectEqual(SignalSource.unknown, signal.event.source);
        try t.expectEqual(literal(&.{ 0x23, 5, 2, 1, 0 }), try encode(.{ .signal = signal }, test_dimensions));
    }
}

test "decision decodes outcome reason timing other key term layer and combo" {
    const t = std.testing;
    const bytes = literal(&.{ 0x24, 7, 12, 2, 3, 0x2C, 0x01, 20, 0xC8, 0x00, 3, 1 });
    const decision = (try decode(&bytes, test_dimensions)).?.decision;
    try t.expectEqual(@as(u8, 7), decision.sequence);
    try t.expectEqualDeep(TapHoldDecision{
        .key_index = 12,
        .outcome = .hold,
        .reason = .permissive_hold,
        .elapsed_ms = 300,
        .other_key = 20,
        .tapping_term_ms = 200,
        .layer = 3,
        .combo = true,
    }, decision.event);
    try t.expectEqual(bytes, try encode(.{ .decision = decision }, test_dimensions));
    // No other key, and flag bits other than the combo bit are ignored.
    const alone = (try decode(&literal(&.{ 0x24, 8, 1, 1, 1, 40, 0, 0xFF, 0xC8, 0, 0, 0xFE }), test_dimensions)).?.decision;
    try t.expectEqual(@as(?core.KeyIndex, null), alone.event.other_key);
    try t.expect(!alone.event.combo);
    try t.expectEqual(@as(?u8, 8), (Message{ .decision = alone }).sequence());
    try t.expectError(error.InvalidDecision, decode(&literal(&.{ 0x24, 1, 1, 0, 1, 0, 0, 0xFF }), test_dimensions));
    try t.expectError(error.InvalidDecision, decode(&literal(&.{ 0x24, 1, 1, 4, 1, 0, 0, 0xFF }), test_dimensions));
    try t.expectError(error.InvalidDecision, decode(&literal(&.{ 0x24, 1, 1, 1, 6, 0, 0, 0xFF }), test_dimensions));
    try t.expectError(error.InvalidKeyIndex, decode(&literal(&.{ 0x24, 1, 36, 1, 1, 0, 0, 0xFF }), test_dimensions));
    try t.expectError(error.InvalidKeyIndex, decode(&literal(&.{ 0x24, 1, 1, 2, 3, 0, 0, 36 }), test_dimensions));
    try t.expectError(error.InvalidKeyIndex, decode(&literal(&.{ 0x24, 1, 1, 2, 3, 0, 0, 0x80 }), test_dimensions));
    try t.expectError(error.InvalidLayer, decode(&literal(&.{ 0x24, 1, 1, 1, 1, 0, 0, 0xFF, 0, 0, 4 }), test_dimensions));
}

test "a version 1 hello is accepted: such keyboards never send decisions" {
    const hello = (try decode(&literal(&.{ 0x20, 1, 36, 4 }), test_dimensions)).?.hello;
    try std.testing.expectEqual(@as(u8, 1), hello.version);
    try std.testing.expect(supportsVersion(1) and supportsVersion(2) and !supportsVersion(3));
    try std.testing.expectEqual(literal(&.{ 0x20, 1, 36, 4 }), try encode(.{ .hello = hello }, test_dimensions));
}

test "decoder ignores unknown report ids including the legacy trace" {
    for ([_]u8{ 0x00, 0x03, 0x10, 0x11, 0x12, 0x25, 0x7F, 0xA7, 0xFF }) |id| {
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
    try t.expectError(error.UnsupportedVersion, decode(&literal(&.{ 0x20, 3, 36, 4 }), test_dimensions));
    try t.expectError(error.UnsupportedVersion, decode(&literal(&.{ 0x20, 0, 36, 4 }), test_dimensions));
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

test "host and firmware agree on every shared constant" {
    const t = std.testing;
    // Golden: the wire itself, independent of either side.
    try t.expectEqual(32, report_size);
    try t.expectEqual(2, protocol_version);
    try t.expectEqual(16, @sizeOf(KeymapId));
    try t.expectEqual(@sizeOf(KeymapId), @sizeOf(@FieldType(identity.Identity, "digest")));
    // Every firmware command is known to the host under the same name and id.
    const firmware_commands = @typeInfo(firmware.Command).@"enum";
    const host_commands = @typeInfo(Command).@"enum";
    try t.expectEqual(firmware_commands.field_names.len, host_commands.field_names.len);
    inline for (firmware_commands.field_names, host_commands.field_names) |fw, host| try t.expectEqualStrings(fw, host);
    inline for (firmware_commands.field_values, host_commands.field_values) |fw, host| try t.expectEqual(fw, host);
}

/// Takes the firmware session's next report as the USB endpoint would.
fn takeFirmware(session: *firmware.Session) ?Report {
    const report = session.next_report() orelse return null;
    session.sent();
    return report;
}

test "firmware reports decode to the events that produced them" {
    const t = std.testing;
    var session = firmware.Session.init(.{ .key_count = 36, .layer_count = 4, .keymap_id = @splat(0xAB) });
    session.key_event(true, 9, 0, .{});
    var layers = core.LayerActivations{};
    layers.activate(1);
    layers.activate(2);
    session.update_state(&layers, .{ .left_shift = true });
    try t.expectEqual(firmware.Action.none, session.receive(&encodeCommand(.connect)));
    const hello = (try decode(&takeFirmware(&session).?, test_dimensions)).?;
    try t.expectEqualDeep(Message{ .hello = .{ .dimensions = test_dimensions, .keymap_id = @splat(0xAB) } }, hello);
    const state = (try decode(&takeFirmware(&session).?, test_dimensions)).?.state;
    try t.expectEqualDeep(State{
        .sequence = 0,
        .highest_layer = 2,
        .active_layers = 0b0111,
        .modifiers = .{ .left_shift = true },
        .pressed = blk: {
            var pressed: [16]u8 = @splat(0);
            pressed[1] = 0b10;
            break :blk pressed;
        },
    }, state);

    const modifiers = core.Modifiers{ .left_ctrl = true, .right_gui = true };
    session.key_event(true, 5, 1, modifiers);
    session.processor_event(.{ .OnHoldEnterAfter = .{ .hold = .{ .custom = core.CUSTOM_ID_COMPANION_TOGGLE } } });
    session.processor_event(.{ .OnTapExitBefore = .{ .tap = .{ .custom = core.CUSTOM_ID_COMPANION_LOG_TOGGLE } } });
    session.processor_event(.{ .OnTapEnterAfter = .{ .tap = .{ .key_press = core.KC_SHUTDOWN_COMPANION } } });
    const decision = TapHoldDecision{
        .key_index = 5,
        .outcome = .tap,
        .reason = .same_side_tap,
        .elapsed_ms = 95,
        .other_key = 7,
        .tapping_term_ms = 220,
        .layer = 1,
    };
    session.tap_hold_decision(decision);
    for ([_]Message{
        .{ .key = .{ .sequence = 1, .event = .{ .pressed = true, .key_index = 5, .layer = 1, .modifiers = modifiers } } },
        .{ .signal = .{ .sequence = 2, .event = .{ .kind = .overlay_toggle, .pressed = true, .source = .hold } } },
        .{ .signal = .{ .sequence = 3, .event = .{ .kind = .log_toggle, .pressed = false, .source = .tap } } },
        .{ .signal = .{ .sequence = 4, .event = .{ .kind = .shutdown, .pressed = true, .source = .tap } } },
        .{ .decision = .{ .sequence = 5, .event = decision } },
    }) |expected| {
        const report = takeFirmware(&session).?;
        try t.expectEqualDeep(expected, (try decode(&report, test_dimensions)).?);
        // The host fake encodes exactly what the firmware sends.
        try t.expectEqual(report, try encode(expected, test_dimensions));
    }
    try t.expectEqual(@as(?Report, null), takeFirmware(&session));
}

test "a firmware session built with a computed keymap id reports it in hello" {
    const t = std.testing;
    const keys = [_]?core.KeyDef{ .{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } }, null };
    const computed = try computeIdentity(.{
        .board_id = .{ 'b', 'o', 'a', 'r', 'd', 0, 0, 0 },
        .profile_id = .{ 'm', 'a', 'i', 'n', 0, 0, 0, 0 },
        .dimensions = .{ .key_count = 2, .layer_count = 1 },
        .keys = &keys,
        .sides = &.{ .L, .R },
        .combos = &.{},
        .encoders = &.{},
        .callbacks = &.{},
    });
    // Exports write the id into the keymap's custom functions; the firmware
    // main loop builds its session from them.
    const custom_functions = core.CustomFunctions{ .companion_keymap_id = keymapId(computed) };
    var session = firmware.Session.init(.{
        .key_count = computed.dimensions.key_count,
        .layer_count = computed.dimensions.layer_count,
        .keymap_id = custom_functions.companion_keymap_id,
    });
    _ = session.receive(&encodeCommand(.connect));
    const report = takeFirmware(&session).?;
    try t.expectEqualSlices(u8, &computed.digest, report[4..20]);
    const hello = (try decode(&report, computed.dimensions)).?.hello;
    try t.expectEqual(computed.digest, hello.keymap_id);
    try t.expectEqual(computed.dimensions, hello.dimensions);
    try t.expect(!isUnknownKeymap(hello.keymap_id));
    // Without an id the firmware reports the unknown keymap.
    var unnamed = firmware.Session.init(.{ .key_count = 2, .layer_count = 1, .keymap_id = (core.CustomFunctions{}).companion_keymap_id });
    _ = unnamed.receive(&encodeCommand(.connect));
    try t.expect(isUnknownKeymap((try decode(&takeFirmware(&unnamed).?, computed.dimensions)).?.hello.keymap_id));
}
