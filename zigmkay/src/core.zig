const generic_queue = @import("generic_queue.zig");
const std = @import("std");
const string_printing = @import("string_printing.zig");

// TODO: move to keycodes
pub const special_keycode_BOOT: u8 = 0xFC; // Special keycode that signals puts the keyboard into bootloader mode.
pub const special_keycode_PRINT_STATS: u8 = 0xFD; // Special keycode that prints stats into any text editor.
pub const special_keycode_COMPANION: u8 = 0xFE; // Special keycode that signals the companion app to toggle the overlay.
pub const special_keycode_SHUTDOWN_COMPANION: u8 = 0xFF; // Special keycode that signals the companion app to shut down entirely.

/// Reserved TapDef.custom ID for SIG(): toggles companion app log visibility.
/// Mirrors the special_keycode_* naming convention. Do not use in user keymaps.
pub const CUSTOM_ID_COMPANION_LOG_TOGGLE: u8 = 0xFD;
/// Reserved TapDef.custom ID for SIG(): sends a companion app shutdown command.
/// Mirrors the special_keycode_* naming convention. Do not use in user keymaps.
pub const CUSTOM_ID_COMPANION_SHUTDOWN: u8 = 0xFE;
/// Reserved TapDef.custom ID for SIG(): signals the companion overlay to toggle
/// (press=1 on key enter, release=0 on key exit). Mirrors the special_keycode_*
/// naming convention. Do not use in user keymaps.
///
/// User-defined custom IDs may use any value from 1 to 252 (0x01..0xFC).
/// Values 0xFD, 0xFE, and 0xFF are reserved by zigmkay for built-in companion
/// signals and must not be used for keymap-specific logic.
pub const CUSTOM_ID_COMPANION_TOGGLE: u8 = 0xFF;
pub const KC_BOOT = KeyCodeFire{ .tap_keycode = special_keycode_BOOT };
pub const KC_PRINT_STATS = KeyCodeFire{ .tap_keycode = special_keycode_PRINT_STATS };
pub const KC_COMPANION = KeyCodeFire{ .tap_keycode = special_keycode_COMPANION };
pub const KC_SHUTDOWN_COMPANION = KeyCodeFire{ .tap_keycode = special_keycode_SHUTDOWN_COMPANION };

pub const Modifiers = packed struct {
    left_ctrl: bool = false,
    left_shift: bool = false,
    left_alt: bool = false,
    left_gui: bool = false,
    right_ctrl: bool = false,
    right_shift: bool = false,
    right_alt: bool = false,
    right_gui: bool = false,
    pub fn has_any(self: *const Modifiers) bool {
        return self.left_gui or self.left_alt or self.left_shift or self.left_ctrl or self.right_gui or self.right_alt or self.right_shift or self.right_ctrl;
    }

    pub fn add(self: *const Modifiers, other: Modifiers) Modifiers {
        const self_bytes = self.toByte();
        const other_bytes = other.toByte();
        return Modifiers.fromByte(self_bytes | other_bytes);
    }

    pub fn remove(self: *const Modifiers, other: Modifiers) Modifiers {
        const self_bytes = self.toByte();
        const other_bytes = other.toByte();
        return Modifiers.fromByte(self_bytes & ~other_bytes);
    }
    pub fn toByte(self: Modifiers) u8 {
        return @bitCast(self);
    }
    pub fn fromByte(byte_val: u8) Modifiers {
        return @bitCast(byte_val);
    }
};

pub const KeymapDimensions = struct {
    key_count: KeyIndex,
    layer_count: LayerIndex,
};

/// Defines an action representing mouse movement, wheel scrolling, or a mouse button click.
pub const MouseAction = enum(u8) {
    LeftButton,
    RightButton,
    MiddleButton,
    Button4,
    Button5,
    WheelUp,
    WheelDown,
    WheelLeft,
    WheelRight,
};
pub const TapDef = struct {
    key_press: ?KeyCodeFire = null,
    one_shot: ?HoldDef = null,
    custom: ?u8 = null,
    media_key: ?MediaCode = null, // Optional media keycode for consumer control (e.g., volume, play/pause).
    mouse_action: ?MouseAction = null, // Optional mouse action to be executed on tap.
};

// this list comes from here: https://www.usb.org/sites/default/files/documents/hut1_12v2.pdf
pub const MediaCode = enum(u16) {
    NextTrack = 0x00b5,
    PreviousTrack = 0x00b6,
    VolumeMute = 0x00e8,
    VolumeUp = 0x00e9,
    VolumeDown = 0x00ea,
};

pub const HoldDef = struct {
    hold_modifiers: Modifiers = .{},
    hold_layer: ?LayerIndex = null,
    custom: ?u8 = null,
};

pub const TapHoldDef = struct {
    tap: TapDef,
    hold: HoldDef,
    tapping_term: TimeSpan,
    retro_tapping: bool = false,
};

pub const KeyDef = union(enum) {
    none,
    tap_only: TapDef,
    hold_only: HoldDef,
    tap_hold: TapHoldDef,
    tap_with_autofire: AutoFireDef,
};

/// Defines the physical placement of a key or component. L=Left, R=Right, TL=Thumb Left, TR=Thumb Right, E=Encoder.
pub const Side = enum { L, R, X };
pub const Combo2Def = struct {
    key_indexes: [2]KeyIndex,
    timeout: TimeSpan,
    layer: LayerIndex,
    key_def: KeyDef,
};

pub const AutoFireDef = struct {
    tap: TapDef,
    initial_delay: TimeSpan,
    repeat_interval: TimeSpan,
};

pub const TimeSpan = struct {
    ms: u16 = 0,
};
pub const KeyIndex = u7;
pub const LayerIndex = u4;

pub const RAWHID_SIGNAL_KEY_EVENT: u8 = 0x03;

/// Optional Raw HID diagnostics for matrix events consumed by the processor.
/// Events use the companion-compatible `LogMessage` payload.
pub const MatrixEventTrace = struct {
    signal_id: u8 = RAWHID_SIGNAL_KEY_EVENT,
    key_range: ?struct { first: KeyIndex, last: KeyIndex } = null,

    pub fn includes(self: MatrixEventTrace, key_index: KeyIndex) bool {
        const range = self.key_range orelse return true;
        return key_index >= range.first and key_index <= range.last;
    }
};

const queue_capacities = 250;

// Matrix events: switch press/release,
pub const UartMessage = packed struct {
    pressed: bool,
    key_index: u7,
    pub fn toByte(self: UartMessage) u8 {
        return @bitCast(self);
    }
    pub fn fromByte(byte_val: u8) UartMessage {
        return @bitCast(byte_val);
    }
};

pub const LogMessage = extern struct {
    pressed: u8,
    key_index: u8,
    layer: u8,
    modifiers: u8,

    pub fn init(pressed: bool, key_index: KeyIndex, layer: LayerIndex, modifiers: Modifiers) LogMessage {
        return .{
            .pressed = @intFromBool(pressed),
            .key_index = key_index,
            .layer = layer,
            .modifiers = modifiers.toByte(),
        };
    }

    pub fn toBytes(self: LogMessage) [4]u8 {
        return .{ self.pressed, self.key_index, self.layer, self.modifiers };
    }

    pub fn fromBytes(bytes: [4]u8) LogMessage {
        return .{
            .pressed = bytes[0],
            .key_index = bytes[1],
            .layer = bytes[2],
            .modifiers = bytes[3],
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(LogMessage) == 4);
    std.debug.assert(@alignOf(LogMessage) == 1);
    std.debug.assert(@offsetOf(LogMessage, "pressed") == 0);
    std.debug.assert(@offsetOf(LogMessage, "key_index") == 1);
    std.debug.assert(@offsetOf(LogMessage, "layer") == 2);
    std.debug.assert(@offsetOf(LogMessage, "modifiers") == 3);
}

pub const MatrixStateChange = struct { pressed: bool, key_index: KeyIndex, time: TimeSinceBoot };
pub const MatrixStateChangeQueue = generic_queue.GenericQueue(MatrixStateChange, queue_capacities);
pub const EncoderEventQueue = generic_queue.GenericQueue(EncoderEvent, queue_capacities);

pub const EncoderAction = struct {
    tap: TapDef,
};
pub const EncoderEvent = struct {
    encoder_action_index: u8,
};
pub const KeyCodeFire = struct {
    tap_keycode: u8 = 0,
    tap_modifiers: Modifiers = .{},
    dead: bool = false,
};

// Media Key Codes (Consumer Page)
pub const MEDIA_VOLUME_UP: u16 = 0xE9;
pub const MEDIA_VOLUME_DOWN: u16 = 0xEA;
pub const MEDIA_MUTE: u16 = 0xE2;
pub const MEDIA_PLAY_PAUSE: u16 = 0xCD;
pub const MEDIA_NEXT_TRACK: u16 = 0xB5;
pub const MEDIA_PREV_TRACK: u16 = 0xB6;

// USB output
pub const OutputCommand = union(enum) {
    KeyCodePress: u8,
    KeyCodeRelease: u8,
    ModifiersChanged: Modifiers,
    ActivateBootMode,
    RawHidSignal: struct { signal_id: u8, data: [8]u8, len: u8 },
    ConsumerKeyPressed: MediaCode,
    ConsumerKeyReleased: MediaCode,
    MouseCommandPressed: MouseAction,
    MouseCommandReleased: MouseAction,
};
pub const OutputCommandQueue = struct {
    const QueueType = generic_queue.GenericQueue(OutputCommand, queue_capacities);
    currently_pressed_keycodes: [256]bool = @splat(false),
    queue: QueueType = QueueType.Create(),
    current_mods: Modifiers = .{}, // holds the latest submitted
    pub fn Create() OutputCommandQueue {
        return OutputCommandQueue{};
    }
    pub fn dequeue(self: *OutputCommandQueue) ?OutputCommand {
        return self.queue.dequeue();
    }
    pub fn Count(self: *OutputCommandQueue) usize {
        return self.queue.Count();
    }
    pub fn has_events(self: *OutputCommandQueue) bool {
        return self.queue.Count() > 0;
    }
    pub fn go_to_boot_mode(self: *OutputCommandQueue) !void {
        try self.queue.enqueue(OutputCommand.ActivateBootMode);
    }

    pub fn tap_key(self: *OutputCommandQueue, tap: KeyCodeFire) !void {
        try press_key(self, tap);
        try release_key(self, tap);
    }
    pub fn press_key(self: *OutputCommandQueue, tap: KeyCodeFire) !void {
        if (self.currently_pressed_keycodes[tap.tap_keycode]) {
            try self.queue.enqueue(.{ .KeyCodeRelease = tap.tap_keycode });
            self.currently_pressed_keycodes[tap.tap_keycode] = false;
        }

        if (tap.tap_modifiers.has_any()) {
            const temp_mods = self.current_mods.add(tap.tap_modifiers);
            try self.queue.enqueue(.{ .ModifiersChanged = temp_mods });

            try self.queue.enqueue(.{ .KeyCodePress = tap.tap_keycode });
            try self.queue.enqueue(.{ .KeyCodeRelease = tap.tap_keycode });

            try self.queue.enqueue(.{ .ModifiersChanged = self.current_mods });
        } else {
            self.currently_pressed_keycodes[tap.tap_keycode] = true;
            try self.queue.enqueue(.{ .KeyCodePress = tap.tap_keycode });
        }
    }
    pub fn release_key(self: *OutputCommandQueue, tap: KeyCodeFire) !void {
        if (tap.tap_modifiers.has_any()) {
            return; // if modifiers exist, release has already been fire
        }
        if (self.currently_pressed_keycodes[tap.tap_keycode] == false) {
            return; // release has already been fired per #CASE 1
        }
        try self.queue.enqueue(.{ .KeyCodeRelease = tap.tap_keycode });
        self.currently_pressed_keycodes[tap.tap_keycode] = false;
    }
    pub fn get_current_modifiers(self: *OutputCommandQueue) Modifiers {
        return self.current_mods;
    }
    pub fn set_mods(self: *OutputCommandQueue, modifiers: Modifiers) !void {
        if (self.current_mods.toByte() != modifiers.toByte()) {}
        self.current_mods = modifiers;
        try self.queue.enqueue(.{ .ModifiersChanged = modifiers });
    }

    pub fn send_raw_hid_signal(self: *OutputCommandQueue, signal_id: u8, data: []const u8) !void {
        var buf: [8]u8 = @splat(0);
        const len = @min(data.len, 8);
        @memcpy(buf[0..len], data[0..len]);
        try self.queue.enqueue(.{ .RawHidSignal = .{ .signal_id = signal_id, .data = buf, .len = @intCast(len) } });
    }

    pub fn print_string(self: *OutputCommandQueue, string: []u8) !void {
        try string_printing.print_string(string, self);
    }
};
pub const TimeSinceBoot = struct {
    time_since_boot_us: u64,

    pub fn from_absolute_us(time_us: u64) TimeSinceBoot {
        return .{ .time_since_boot_us = time_us };
    }
    pub fn add_us(self: *const TimeSinceBoot, delta_us: u64) TimeSinceBoot {
        return .{ .time_since_boot_us = self.time_since_boot_us + delta_us };
    }
    pub fn add_ms(self: *const TimeSinceBoot, delta_ms: u64) TimeSinceBoot {
        return .{ .time_since_boot_us = self.time_since_boot_us + delta_ms * 1000 };
    }
    pub fn add(self: *const TimeSinceBoot, delta: TimeSpan) TimeSinceBoot {
        return self.add_ms(delta.ms);
    }
    pub fn diff_us(self: *const TimeSinceBoot, other: *const TimeSinceBoot) DiffError!u64 {
        if (self.time_since_boot_us < other.time_since_boot_us) {
            return DiffError.CurrentIsEarlierThanInput;
        }
        return self.time_since_boot_us - other.time_since_boot_us;
    }
    pub fn diff_ms(self: *const TimeSinceBoot, other: *const TimeSinceBoot) DiffError!u64 {
        return try self.diff_us(other) * 1000;
    }
    pub fn up_til_ms(self: *const TimeSinceBoot, other: *const TimeSinceBoot) DiffError!u64 {
        if (self.time_since_boot_us > other.time_since_boot_us) {
            return DiffError.CurrentIsLaterThanInput;
        }
        return (other.time_since_boot_us - self.time_since_boot_us) / 1000;
    }
};

pub const DiffError = error{ CurrentIsEarlierThanInput, CurrentIsLaterThanInput };

pub const LayerActivations = struct {
    layers: [32]bool = @splat(false),
    top_most_active_layer: LayerIndex = 0,
    const Self = @This();
    pub fn activate(self: *Self, layer_index: LayerIndex) void {
        if (layer_index == 0)
            return;
        self.layers[layer_index] = true;
        if (layer_index > self.top_most_active_layer) {
            self.top_most_active_layer = layer_index;
        }
    }

    pub fn deactivate(self: *Self, layer_index: LayerIndex) void {
        if (layer_index == 0)
            return;
        self.layers[layer_index] = false;
        if (layer_index == self.top_most_active_layer) {
            // now find the next top most active layer
            var counter = self.top_most_active_layer - 1;
            while (self.layers[counter] == false and counter > 0) {
                counter -= 1;
            }
            if (self.top_most_active_layer != counter) {
                self.top_most_active_layer = counter;
            }
        }
    }

    pub fn set_layer_state(self: *Self, layer_index: LayerIndex, state: bool) void {
        switch (state) {
            true => activate(self, layer_index),
            false => deactivate(self, layer_index),
        }
    }

    pub fn is_layer_active(self: *const Self, layer_index: LayerIndex) bool {
        if (layer_index == 0)
            return true;
        return self.layers[layer_index];
    }
    pub fn get_top_most_active_layer(self: *const Self) LayerIndex {
        return self.top_most_active_layer;
    }
};

/// Plugin interface for injecting keymap-specific logic into the processing pipeline.
///
/// zigmkay handles a set of built-in behaviors automatically without requiring a
/// custom handler (see processing.zig for the full list). Only define `on_event`
/// when your keymap needs logic that goes beyond the built-ins — for example,
/// activating a custom layer, chaining multiple keys, or reacting to hold events
/// in a keyboard-specific way.
///
/// A keymap with no custom logic can simply use the zero value:
///   `pub const custom_functions = core.CustomFunctions{};`
pub const CustomFunctions = struct {
    /// Optional callback invoked by the processor on every firmware event.
    /// Receives the event, a pointer to the current layer state, and the output
    /// command queue so that custom actions can enqueue USB output.
    /// Set to null (the default) when no custom logic is needed.
    on_event: ?*const fn (event: ProcessorEvent, layers: *LayerActivations, output_queue: *OutputCommandQueue) void = null,
};
pub const ProcessorEvent = union(enum) {
    Tick,
    OnMatrixChanged: struct { event: MatrixStateChange, layer: LayerIndex, modifiers: Modifiers },
    OnTapEnterBefore: struct { tap: TapDef },
    OnTapEnterAfter: struct { tap: TapDef },
    OnTapExitBefore: struct { tap: TapDef },
    OnTapExitAfter: struct { tap: TapDef },
    OnHoldEnterBefore: struct { hold: HoldDef },
    OnHoldEnterAfter: struct { hold: HoldDef },
    OnHoldExitBefore: struct { hold: HoldDef },
    OnHoldExitAfter: struct { hold: HoldDef },
};
