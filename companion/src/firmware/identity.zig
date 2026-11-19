// SPDX-License-Identifier: GPL-2.0-or-later
//! Host-only canonical keymap identity, authored for this companion and
//! derived from the EuroZig firmware fork (`zigmkay/src/device_protocol.zig`
//! at e122f75).
//!
//! The 16-byte digest is the first 16 bytes of SHA-256 over a canonical
//! encoding of the board id, profile id, dimensions and keymap semantics. It is
//! also the keymap id that a keyboard reports in its companion hello: generated
//! keymaps set `custom_functions.companion_keymap_id` to this digest.
const std = @import("std");
const core = @import("zigmkay").core;

pub const Error = error{ InvalidIdentity, InvalidDimensions, InvalidCallback, InvalidLayer, InvalidKeyIndex };

pub const Identity = struct {
    board_id: [8]u8,
    profile_id: [8]u8,
    digest: [16]u8,
    dimensions: core.KeymapDimensions,
};

/// The id firmware reports in its companion hello for a keymap with this identity.
pub fn keymapId(identity: Identity) [16]u8 {
    return identity.digest;
}

/// Ids are lowercase ASCII letters, digits or underscores, zero padded.
pub fn validateId(id: [8]u8) Error!void {
    if (id[0] == 0) return error.InvalidIdentity;
    var ended = false;
    for (id) |byte| {
        if (byte == 0) {
            ended = true;
            continue;
        }
        if (ended or
            !(byte >= 'a' and byte <= 'z' or byte >= '0' and byte <= '9' or byte == '_')) return error.InvalidIdentity;
    }
}

pub fn validateIdentity(identity: Identity) Error!void {
    try validateId(identity.board_id);
    try validateId(identity.profile_id);
    if (identity.dimensions.key_count == 0 or identity.dimensions.layer_count == 0) return error.InvalidDimensions;
}

pub const CallbackIdentity = struct { id: u8, behavior: []const u8 };

pub const IdentityInput = struct {
    board_id: [8]u8,
    profile_id: [8]u8,
    dimensions: core.KeymapDimensions,
    keys: []const ?core.KeyDef,
    sides: []const core.Side,
    combos: []const core.Combo2Def,
    encoders: []const core.EncoderAction,
    callbacks: []const CallbackIdentity,
};

const Canonical = struct {
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    dimensions: core.KeymapDimensions,
    callbacks: []const CallbackIdentity,

    fn byte(self: *Canonical, value: u8) void {
        self.hash.update(&.{value});
    }

    fn boolean(self: *Canonical, value: bool) void {
        self.byte(@intFromBool(value));
    }

    fn word(self: *Canonical, value: u16) void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        self.hash.update(&bytes);
    }

    fn count(self: *Canonical, value: usize) Error!void {
        if (value > 65535) return error.InvalidIdentity;
        self.word(@intCast(value));
    }

    fn custom(self: *Canonical, value: ?u8) Error!void {
        self.boolean(value != null);
        if (value) |id| {
            if (id == 0) return error.InvalidCallback;
            if (id < 253) {
                var declared = false;
                for (self.callbacks) |callback| {
                    if (callback.id == id) declared = true;
                }
                if (!declared) return error.InvalidCallback;
            }
            self.byte(id);
        }
    }

    fn hold(self: *Canonical, value: core.HoldDef) Error!void {
        self.byte(value.hold_modifiers.toByte());
        self.boolean(value.hold_layer != null);
        if (value.hold_layer) |layer| {
            if (layer >= self.dimensions.layer_count) return error.InvalidLayer;
            self.byte(layer);
        }
        try self.custom(value.custom);
    }

    fn tap(self: *Canonical, value: core.TapDef) Error!void {
        self.boolean(value.key_press != null);
        if (value.key_press) |key_value| {
            self.byte(key_value.tap_keycode);
            self.byte(key_value.tap_modifiers.toByte());
            self.boolean(key_value.dead);
        }
        self.boolean(value.one_shot != null);
        if (value.one_shot) |hold_value| try self.hold(hold_value);
        try self.custom(value.custom);
        self.boolean(value.media_key != null);
        if (value.media_key) |media| self.word(@backingInt(media));
        self.boolean(value.mouse_action != null);
        if (value.mouse_action) |mouse| {
            self.byte(switch (mouse) {
                .LeftButton => 0,
                .RightButton => 1,
                .MiddleButton => 2,
                .Button4 => 3,
                .Button5 => 4,
                .WheelUp => 5,
                .WheelDown => 6,
                .WheelLeft => 7,
                .WheelRight => 8,
            });
        }
    }

    fn key(self: *Canonical, value: ?core.KeyDef) Error!void {
        const action = value orelse {
            self.byte(5);
            return;
        };
        switch (action) {
            .none => self.byte(0),
            .tap_only => |tap_value| {
                self.byte(1);
                try self.tap(tap_value);
            },
            .hold_only => |hold_value| {
                self.byte(2);
                try self.hold(hold_value);
            },
            .tap_hold => |value_th| {
                self.byte(3);
                try self.tap(value_th.tap);
                try self.hold(value_th.hold);
                self.word(value_th.tapping_term.ms);
                self.boolean(value_th.retro_tapping);
            },
            .tap_with_autofire => |fire| {
                self.byte(4);
                try self.tap(fire.tap);
                self.word(fire.initial_delay.ms);
                self.word(fire.repeat_interval.ms);
            },
        }
    }
};

/// Hashes semantic fields, never pointer addresses or compiler object representations.
pub fn computeIdentity(input: IdentityInput) Error!Identity {
    var identity = Identity{
        .board_id = input.board_id,
        .profile_id = input.profile_id,
        .digest = undefined,
        .dimensions = input.dimensions,
    };
    try validateIdentity(identity);
    if (input.keys.len != @as(usize, input.dimensions.key_count) * input.dimensions.layer_count or
        input.sides.len != input.dimensions.key_count) return error.InvalidDimensions;
    if (input.callbacks.len > 252) return error.InvalidCallback;
    for (input.callbacks, 0..) |callback, index| {
        if (callback.id == 0 or
            callback.id >= 253 or
            callback.behavior.len == 0 or
            callback.behavior.len > 65535) return error.InvalidCallback;
        for (callback.behavior) |byte| if (byte < 0x21 or byte > 0x7E) return error.InvalidCallback;
        for (input.callbacks[0..index]) |earlier| if (earlier.id == callback.id) return error.InvalidCallback;
    }
    var canonical = Canonical{ .dimensions = input.dimensions, .callbacks = input.callbacks };
    canonical.hash.update("zigmkay-profile-v1\x00");
    canonical.hash.update(&input.board_id);
    canonical.hash.update(&input.profile_id);
    canonical.byte(input.dimensions.key_count);
    canonical.byte(input.dimensions.layer_count);
    try canonical.count(input.keys.len);
    for (input.keys) |key_value| try canonical.key(key_value);
    try canonical.count(input.sides.len);
    for (input.sides) |side| canonical.byte(switch (side) {
        .L => 0,
        .R => 1,
        .X => 2,
    });
    try canonical.count(input.combos.len);
    for (input.combos) |combo| {
        if (combo.key_indexes[0] >= input.dimensions.key_count or
            combo.key_indexes[1] >= input.dimensions.key_count or
            combo.key_indexes[0] == combo.key_indexes[1]) return error.InvalidKeyIndex;
        if (combo.layer >= input.dimensions.layer_count) return error.InvalidLayer;
        canonical.byte(combo.key_indexes[0]);
        canonical.byte(combo.key_indexes[1]);
        canonical.word(combo.timeout.ms);
        canonical.byte(combo.layer);
        try canonical.key(combo.key_def);
    }
    try canonical.count(input.encoders.len);
    for (input.encoders) |encoder| try canonical.tap(encoder.tap);
    try canonical.count(input.callbacks.len);
    for (input.callbacks) |callback| {
        canonical.byte(callback.id);
        try canonical.count(callback.behavior.len);
        canonical.hash.update(callback.behavior);
    }
    var full: [32]u8 = undefined;
    canonical.hash.final(&full);
    identity.digest = full[0..16].*;
    return identity;
}

const base_keys = [_]?core.KeyDef{.{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } }};

const base_input = IdentityInput{
    .board_id = .{ 't', 'e', 's', 't', 0, 0, 0, 0 },
    .profile_id = .{ 'b', 'a', 's', 'e', 0, 0, 0, 0 },
    .dimensions = .{ .key_count = 1, .layer_count = 1 },
    .keys = &base_keys,
    .sides = &.{.L},
    .combos = &.{},
    .encoders = &.{},
    .callbacks = &.{},
};

test "canonical profile digest uses independent semantic bytes and is the reported keymap id" {
    const literal = "zigmkay-profile-v1\x00" ++ "test\x00\x00\x00\x00" ++ "base\x00\x00\x00\x00" ++ [_]u8{ 1, 1, 1, 0, 1, 1, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(literal, &digest, .{});
    const identity = try computeIdentity(base_input);
    try std.testing.expectEqualSlices(u8, digest[0..16], &identity.digest);
    const golden = [_]u8{ 0x11, 0xb5, 0x59, 0x62, 0xb8, 0x78, 0x55, 0xf9, 0x41, 0xde, 0x48, 0x43, 0x92, 0xa9, 0x66, 0x50 };
    try std.testing.expectEqual(golden, identity.digest);
    try std.testing.expectEqual(golden, keymapId(identity));
}

test "identity changes cover optional actions sides combos encoders and callback declarations" {
    const original = (try computeIdentity(base_input)).digest;
    const variants = [_]?core.KeyDef{
        null,
        .none,
        .{ .tap_only = .{ .key_press = .{ .tap_keycode = 4, .dead = true } } },
        .{ .tap_only = .{ .key_press = .{ .tap_keycode = 4, .tap_modifiers = .{ .left_shift = true } } } },
        .{ .tap_only = .{ .one_shot = .{ .hold_modifiers = .{ .left_ctrl = true } } } },
        .{ .tap_only = .{ .media_key = .VolumeUp } },
        .{ .tap_only = .{ .mouse_action = .WheelLeft } },
        .{ .hold_only = .{ .hold_layer = 0 } },
        .{ .tap_hold = .{ .tap = .{}, .hold = .{}, .tapping_term = .{ .ms = 150 }, .retro_tapping = true } },
        .{ .tap_with_autofire = .{
            .tap = .{},
            .initial_delay = .{ .ms = 10 },
            .repeat_interval = .{ .ms = 20 },
        } },
    };
    for (variants) |variant| {
        var input = base_input;
        input.keys = &.{variant};
        try std.testing.expect(!std.mem.eql(u8, &original, &(try computeIdentity(input)).digest));
    }
    var input = base_input;
    input.sides = &.{.R};
    try std.testing.expect(!std.mem.eql(u8, &original, &(try computeIdentity(input)).digest));
    input = base_input;
    input.encoders = &.{.{ .tap = .{ .custom = 1 } }};
    input.callbacks = &.{.{ .id = 1, .behavior = "combined-tap-hold-v1" }};
    const callback_v1 = try computeIdentity(input);
    input.callbacks = &.{.{ .id = 1, .behavior = "combined-tap-hold-v2" }};
    try std.testing.expect(!std.mem.eql(u8, &callback_v1.digest, &(try computeIdentity(input)).digest));
    input.callbacks = &.{};
    try std.testing.expectError(error.InvalidCallback, computeIdentity(input));
    input = base_input;
    input.keys = &.{.{ .hold_only = .{ .hold_layer = 1 } }};
    try std.testing.expectError(error.InvalidLayer, computeIdentity(input));
    input = base_input;
    input.callbacks = &.{ .{ .id = 1, .behavior = "a" }, .{ .id = 1, .behavior = "b" } };
    try std.testing.expectError(error.InvalidCallback, computeIdentity(input));
    input = base_input;
    input.dimensions.key_count = 2;
    input.keys = &.{ base_keys[0], base_keys[0] };
    input.sides = &.{ .L, .L };
    const no_combo = try computeIdentity(input);
    input.combos = &.{.{ .key_indexes = .{ 0, 1 }, .timeout = .{ .ms = 40 }, .layer = 0, .key_def = .none }};
    try std.testing.expect(!std.mem.eql(u8, &no_combo.digest, &(try computeIdentity(input)).digest));
}

test "identity ids and dimensions are validated before hashing" {
    var input = base_input;
    input.board_id = .{ 'T', 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidIdentity, computeIdentity(input));
    input = base_input;
    input.profile_id = .{ 'a', 0, 'b', 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidIdentity, computeIdentity(input));
    input = base_input;
    input.dimensions.layer_count = 0;
    try std.testing.expectError(error.InvalidDimensions, computeIdentity(input));
    input = base_input;
    input.sides = &.{};
    try std.testing.expectError(error.InvalidDimensions, computeIdentity(input));
}
