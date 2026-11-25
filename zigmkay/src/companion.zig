//! Optional live link to a companion app on the host over the Raw HID interface.
//!
//! Nothing is sent until the host sends `connect`, so keyboards behave exactly as
//! before when no companion app is running. Every report is 32 bytes and starts
//! with a message id.
//!
//! Host to keyboard:
//!   0x10 connect           start streaming; the keyboard answers hello + state
//!   0x11 disconnect        stop streaming
//!   0x12 enter bootloader  reboot into the RP2040 USB bootloader
//!
//! Keyboard to host (byte 1 is a sequence number that wraps at 255):
//!   0x20 hello  [1]=protocol version [2]=key count [3]=layer count [4..20]=keymap id
//!   0x21 state  [1]=seq [2]=top layer [3]=modifiers [4..6]=active layers, one bit per layer
//!               (little endian) [6..22]=pressed keys, one bit per key index
//!   0x22 key    [1]=seq [2]=pressed [3]=key index [4]=layer [5]=modifiers
//!   0x23 signal [1]=seq [2]=signal (1 log toggle, 2 overlay toggle, 3 shutdown) [3]=pressed
//!   0x24 decision (version 2) a tap/hold key resolved
//!               [1]=seq [2]=key index [3]=outcome (1 tap, 2 hold, 3 retro tap)
//!               [4]=reason (see below) [5..7]=ms from the press to the decision
//!               (u16 little endian, saturating) [7]=the other key index, or 0xFF
//!               [8..10]=the key's tapping term in ms (u16 little endian)
//!               [10]=layer the key was taken from [11]=flags (bit 0: a combo)
//!
//! Decision reasons:
//!   1 the key was released within the tapping term: tap
//!   2 the tapping term elapsed while the key was held: hold
//!   3 another key on the other side (or a key without a side) was pressed and
//!     released within the tapping term: hold (permissive hold)
//!   4 another key on the same side was pressed and released: tap
//!   5 a hold was released with no other key in between: retro tap
//!
//! Signals come from keys bound to the reserved CUSTOM_ID_COMPANION_* ids (as tap
//! or hold) or to KC_COMPANION / KC_SHUTDOWN_COMPANION, after tap/hold decisions.
//! A decision follows the key report of the press it belongs to and precedes
//! the signals and state the decision causes. Version 1 keyboards never send it.
//!
//! A state report is sent after connecting, whenever the layer or modifiers
//! change, and after key events were dropped because the host stopped reading.
//! A host that sees a gap in the sequence numbers can send connect again.
const std = @import("std");
const core = @import("core.zig");

/// 2 added the tap/hold decision message.
pub const protocol_version: u8 = 2;
pub const Report = [32]u8;

pub const Command = enum(u8) {
    connect = 0x10,
    disconnect = 0x11,
    enter_bootloader = 0x12,
    _,
};

pub const MessageId = enum(u8) {
    hello = 0x20,
    state = 0x21,
    key = 0x22,
    signal = 0x23,
    decision = 0x24,
};

pub const Signal = enum(u8) {
    log_toggle = 1,
    overlay_toggle = 2,
    shutdown = 3,
};

pub const DecisionOutcome = enum(u8) {
    tap = 1,
    hold = 2,
    retro_tap = 3,
};

pub const DecisionReason = enum(u8) {
    released_within_term = 1,
    term_elapsed = 2,
    permissive_hold = 3,
    same_side_tap = 4,
    released_after_term = 5,
};

/// The other key byte when no other key took part.
pub const no_other_key: u8 = 0xFF;

/// How the processor resolved a tap/hold key.
pub const Decision = struct {
    key_index: core.KeyIndex,
    outcome: DecisionOutcome,
    reason: DecisionReason,
    /// From the press to the decision, saturating.
    elapsed_ms: u16,
    /// The key whose press and release decided it, for reasons 3 and 4.
    other_key: ?core.KeyIndex = null,
    tapping_term_ms: u16,
    /// The layer the key definition was taken from.
    layer: core.LayerIndex = 0,
    /// The key is the first key of a combo.
    combo: bool = false,
};

pub const Info = struct {
    key_count: u8,
    layer_count: u8,
    keymap_id: [16]u8 = @splat(0),
};

pub const Action = enum { none, enter_bootloader };

const Event = union(enum) {
    key: struct {
        pressed: bool,
        key_index: core.KeyIndex,
        layer: core.LayerIndex,
        modifiers: u8,
    },
    signal: struct { signal: Signal, pressed: bool },
    decision: Decision,
};

fn custom_signal(id: ?u8) ?Signal {
    return switch (id orelse return null) {
        core.CUSTOM_ID_COMPANION_LOG_TOGGLE => .log_toggle,
        core.CUSTOM_ID_COMPANION_TOGGLE => .overlay_toggle,
        core.CUSTOM_ID_COMPANION_SHUTDOWN => .shutdown,
        else => null,
    };
}

fn tap_signal(tap: core.TapDef) ?Signal {
    if (custom_signal(tap.custom)) |signal| return signal;
    const key = tap.key_press orelse return null;
    return switch (key.tap_keycode) {
        core.special_keycode_COMPANION => .overlay_toggle,
        core.special_keycode_SHUTDOWN_COMPANION => .shutdown,
        else => null,
    };
}

pub const Session = struct {
    info: Info,
    connected: bool = false,
    hello_pending: bool = false,
    state_pending: bool = false,
    sequence: u8 = 0,
    layer: core.LayerIndex = 0,
    active_layers: u16 = 1,
    modifiers: u8 = 0,
    pressed_keys: [16]u8 = @splat(0),
    events: [32]Event = undefined,
    event_start: usize = 0,
    event_count: usize = 0,

    pub fn init(info: Info) Session {
        return .{ .info = info };
    }

    /// Handles a report from the host.
    pub fn receive(self: *Session, report: *const Report) Action {
        switch (@as(Command, @fromBackingInt(@intCast(report[0])))) {
            .connect => {
                self.connected = true;
                self.hello_pending = true;
                self.state_pending = true;
                self.event_count = 0;
            },
            .disconnect => {
                self.connected = false;
                self.event_count = 0;
            },
            .enter_bootloader => return .enter_bootloader,
            _ => {},
        }
        return .none;
    }

    /// Records a matrix change. Pressed keys are tracked even while disconnected
    /// so the first state report after connecting is correct.
    pub fn key_event(self: *Session, pressed: bool, key_index: core.KeyIndex, layer: core.LayerIndex, modifiers: core.Modifiers) void {
        const bit = @as(u8, 1) << @intCast(key_index % 8);
        if (pressed) self.pressed_keys[key_index / 8] |= bit else self.pressed_keys[key_index / 8] &= ~bit;
        self.push(.{ .key = .{
            .pressed = pressed,
            .key_index = key_index,
            .layer = layer,
            .modifiers = modifiers.toByte(),
        } });
    }

    /// Records companion signals from the processor's tap and hold decisions.
    pub fn processor_event(self: *Session, event: core.ProcessorEvent) void {
        const signal: Signal, const pressed = switch (event) {
            .OnTapEnterAfter => |e| .{ tap_signal(e.tap) orelse return, true },
            .OnTapExitBefore => |e| .{ tap_signal(e.tap) orelse return, false },
            .OnHoldEnterAfter => |e| .{ custom_signal(e.hold.custom) orelse return, true },
            .OnHoldExitBefore => |e| .{ custom_signal(e.hold.custom) orelse return, false },
            else => return,
        };
        self.push(.{ .signal = .{ .signal = signal, .pressed = pressed } });
    }

    /// Records a tap/hold decision of the processor.
    pub fn tap_hold_decision(self: *Session, decision: Decision) void {
        self.push(.{ .decision = decision });
    }

    fn push(self: *Session, event: Event) void {
        if (!self.connected) return;
        if (self.event_count == self.events.len) {
            // The host stopped reading. Drop the backlog and resynchronise with a state report.
            self.event_count = 0;
            self.state_pending = true;
            return;
        }
        self.events[(self.event_start + self.event_count) % self.events.len] = event;
        self.event_count += 1;
    }

    /// Records the layer and modifiers after processing, so changes that are not
    /// caused by a key event (for example a hold that resolves later) are reported.
    pub fn update_state(self: *Session, layers: *const core.LayerActivations, modifiers: core.Modifiers) void {
        var active_layers: u16 = 1;
        for (layers.layers[1..16], 1..) |active, index| {
            if (active) active_layers |= @as(u16, 1) << @intCast(index);
        }
        const layer = layers.get_top_most_active_layer();
        if (layer == self.layer and active_layers == self.active_layers and modifiers.toByte() == self.modifiers) return;
        self.layer = layer;
        self.active_layers = active_layers;
        self.modifiers = modifiers.toByte();
        if (self.connected) self.state_pending = true;
    }

    /// Returns the next report to send, if any. Call `sent` once the report was
    /// accepted by the USB endpoint, so a busy endpoint never loses a report.
    pub fn next_report(self: *const Session) ?Report {
        if (!self.connected) return null;
        var report: Report = @splat(0);
        if (self.hello_pending) {
            report[0] = @backingInt(MessageId.hello);
            report[1] = protocol_version;
            report[2] = self.info.key_count;
            report[3] = self.info.layer_count;
            report[4..20].* = self.info.keymap_id;
        } else if (self.event_count > 0) {
            report[1] = self.sequence;
            switch (self.events[self.event_start]) {
                .key => |key| {
                    report[0] = @backingInt(MessageId.key);
                    report[2] = @intFromBool(key.pressed);
                    report[3] = key.key_index;
                    report[4] = key.layer;
                    report[5] = key.modifiers;
                },
                .signal => |signal| {
                    report[0] = @backingInt(MessageId.signal);
                    report[2] = @backingInt(signal.signal);
                    report[3] = @intFromBool(signal.pressed);
                },
                .decision => |decision| {
                    report[0] = @backingInt(MessageId.decision);
                    report[2] = decision.key_index;
                    report[3] = @backingInt(decision.outcome);
                    report[4] = @backingInt(decision.reason);
                    std.mem.writeInt(u16, report[5..7], decision.elapsed_ms, .little);
                    report[7] = if (decision.other_key) |other| other else no_other_key;
                    std.mem.writeInt(u16, report[8..10], decision.tapping_term_ms, .little);
                    report[10] = decision.layer;
                    report[11] = @intFromBool(decision.combo);
                },
            }
        } else if (self.state_pending) {
            report[0] = @backingInt(MessageId.state);
            report[1] = self.sequence;
            report[2] = self.layer;
            report[3] = self.modifiers;
            std.mem.writeInt(u16, report[4..6], self.active_layers, .little);
            report[6..22].* = self.pressed_keys;
        } else return null;
        return report;
    }

    pub fn sent(self: *Session) void {
        if (self.hello_pending) {
            self.hello_pending = false;
            return;
        }
        self.sequence +%= 1;
        if (self.event_count > 0) {
            self.event_start = (self.event_start + 1) % self.events.len;
            self.event_count -= 1;
        } else {
            self.state_pending = false;
        }
    }
};
