const std = @import("std");
const core = @import("zigmkay").core;
pub const version: u16 = 1;
pub const max_input_bytes = 4096;
pub const max_response_bytes = 1024 * 1024;
pub const max_events = 256;
pub const Command = union(enum) { key_down: u7, key_up: u7, encoder: u8, advance, reset, stop };
pub const Input = struct { version: u16 = version, sequence: u64, time_us: u64, command: Command };

pub const Output = struct {
    version: u16 = version,
    sequence: u64,
    snapshot_id: [32]u8,
    state: enum { ready, processed, restart_required, stopped, failed },
    commands: []const core.OutputCommand = &.{},
    events: []const core.ProcessorEvent = &.{},
    signals: []const Signal = &.{},
    active_layers: u16 = 1,
    highest_layer: u4 = 0,
    modifiers: u8 = 0,
    diagnostic: ?[]const u8 = null,
};

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Input {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    const input = try @import("owned-zon").parse(Input, gpa, text);
    if (input.version != version) return error.UnsupportedVersion;
    return input;
}

/// Companion intents of the reserved keymap actions. Firmware reports them as
/// signal messages (`zigmkay/src/companion.zig`); the runner has no Raw HID
/// session, so it derives the same signals from processor events and output
/// commands. Keep both in step when the firmware rules change.
pub const SignalKind = enum(u8) { log_toggle = 1, overlay_toggle = 2, shutdown = 3 };
pub const Signal = struct { kind: SignalKind, pressed: bool };

fn customSignal(id: ?u8) ?SignalKind {
    return switch (id orelse return null) {
        core.CUSTOM_ID_COMPANION_LOG_TOGGLE => .log_toggle,
        core.CUSTOM_ID_COMPANION_TOGGLE => .overlay_toggle,
        core.CUSTOM_ID_COMPANION_SHUTDOWN => .shutdown,
        else => null,
    };
}

/// Reserved custom ids (0xFD..0xFF) on taps and holds, seen by `on_event`.
pub fn eventSignal(event: core.ProcessorEvent) ?Signal {
    const kind, const pressed = switch (event) {
        .OnTapEnterAfter => |value| .{ customSignal(value.tap.custom), true },
        .OnTapExitBefore => |value| .{ customSignal(value.tap.custom), false },
        .OnHoldEnterAfter => |value| .{ customSignal(value.hold.custom), true },
        .OnHoldExitBefore => |value| .{ customSignal(value.hold.custom), false },
        else => return null,
    };
    return .{ .kind = kind orelse return null, .pressed = pressed };
}

/// KC_COMPANION (0xFE) and KC_SHUTDOWN_COMPANION (0xFF) keycodes, which
/// firmware sends as ordinary key presses.
pub fn commandSignal(command: core.OutputCommand) ?Signal {
    const keycode, const pressed = switch (command) {
        .KeyCodePress => |value| .{ value, true },
        .KeyCodeRelease => |value| .{ value, false },
        else => return null,
    };
    const kind: SignalKind = switch (keycode) {
        core.special_keycode_COMPANION => .overlay_toggle,
        core.special_keycode_SHUTDOWN_COMPANION => .shutdown,
        else => return null,
    };
    return .{ .kind = kind, .pressed = pressed };
}
