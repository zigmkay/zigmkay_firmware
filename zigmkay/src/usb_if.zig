const std = @import("std");
const microzig = @import("microzig");

const rp2xxx = microzig.hal;
const usb = microzig.core.usb;
const USB_Device = rp2xxx.usb.Polled(.{});

pub const HID_KeymodifierCodes = enum(u8) {
    left_control = 0xe0,
    left_shift,
    left_alt,
    left_gui,
    right_control,
    right_shift,
    right_alt,
    right_gui,
};

pub const KeyboardInReport = extern struct {
    modifiers: u8,
    keys: [6]u8,

    pub const empty: @This() = .{ .modifiers = 0, .keys = @splat(0) };
};

pub const KeyboardOutReport = packed struct(u8) {
    num_lock: bool,
    caps_lock: bool,
    scroll_lock: bool,
    padding: u5 = 0,
};

// HID Interrupt Driver for Standard Boot Keyboard
const Keyboard = usb.drivers.hid.InterruptDriver(.{
    .subclass = .Boot,
    .protocol = .Boot,
    .report_descriptor = &.{
        .{ .global_usage_page = .generic_desktop },
        .local_usage_enum(.{ .generic_desktop = .keyboard }),
        .{ .main_collection = .Application },
        // Input: modifier key bitmap
        .{ .data = .{
            .usage = .{ .global_page = .keyboard },
            .usage_range = .{ 0xE0, 0xE7 },
            .count = 8,
            .Child = bool,
            .dir = .in,
            .type = .dynamic,
        } },
        // Input: up to 6 pressed key codes
        .{ .data = .{
            .usage = .{ .global_page = .keyboard },
            .usage_range = .{ 0x00, 0xff },
            .count = 6,
            .Child = u8,
            .dir = .in,
            .type = .selector,
        } },
        // Output: indicator LEDs
        .{ .data = .{
            .usage = .{ .global_page = .led },
            .usage_range = .{ 1, 5 },
            .count = 5,
            .Child = bool,
            .dir = .out,
            .type = .dynamic,
        } },
        // Padding
        .{ .data_static = .{ .out, u3 } },
        // End
        .main_collection_end,
    },
    .InReport = KeyboardInReport,
    .OutReport = KeyboardOutReport,
});

// Consumer Control (Media Keys)
pub const ConsumerInReport = extern struct {
    button: u16,
    pub const empty: @This() = .{ .button = 0 };
};

// HID Interrupt Driver for Consumer Control endpoints
const ConsumerControl = usb.drivers.hid.InterruptDriver(.{
    .subclass = .Unspecified,
    .protocol = .NoneRequired,
    .report_descriptor = &.{
        .{ .global_usage_page = @fromBackingInt(@intCast(0x0C)) }, // Consumer Page
        .{ .local_usage = 0x01 }, // Consumer Control
        .{ .main_collection = .Application },
        .{ .data = .{
            .usage = .{ .global_page = @fromBackingInt(@intCast(0x0C)) },
            .usage_range = .{ 0x00, 0x03FF },
            .count = 1,
            .Child = u16,
            .dir = .in,
            .type = .selector,
        } },
        .main_collection_end,
    },
    .InReport = ConsumerInReport,
    .OutReport = u8, // Dummy OutReport
});

// Mouse Implementation
pub const MouseInReport = extern struct {
    buttons: u8,
    x: i8,
    y: i8,
    wheel: i8,
    pan: i8,

    pub const empty: @This() = .{ .buttons = 0, .x = 0, .y = 0, .wheel = 0, .pan = 0 };
};

// HID Interrupt Driver for generic Mouse functionality
const Mouse = usb.drivers.hid.InterruptDriver(.{
    .subclass = .Unspecified,
    .protocol = .NoneRequired,
    .report_descriptor = &.{
        .{ .global_usage_page = .generic_desktop },
        .local_usage_enum(.{ .generic_desktop = @fromBackingInt(@intCast(0x02)) }), // Mouse
        .{ .main_collection = .Application },
        .{ .local_usage = 0x01 }, // Pointer
        .{ .main_collection = .Physical },
        .{
            .data = .{
                .usage = .{ .global_page = @fromBackingInt(@intCast(0x09)) }, // Button
                .usage_range = .{ 1, 5 },
                .count = 5,
                .Child = bool,
                .dir = .in,
                .type = .dynamic,
            },
        },
        .{ .data_static = .{ .in, u3 } }, // Padding
        .{ .global_usage_page = .generic_desktop },
        .{
            .data = .{
                .usage = .{ .global_page = .generic_desktop },
                .usage_range = .{ 0x30, 0x31 }, // X, Y
                .logical_range = .{ -127, 127 },
                .count = 2,
                .Child = i8,
                .dir = .in,
                .type = .dynamic,
            },
        },
        // Wheel — must be Relative so the OS maps it to REL_WHEEL, not ABS_WHEEL
        .{ .local_usage = 0x38 },
        .{ .global_logical_range = .{ -127, 127 } },
        .{ .global_report_count = 1 },
        .{ .global_report_size = 8 },
        .{ .main_input = .{ .variable = true, .relative = true } },
        // Pan — same: Relative maps to REL_HWHEEL
        .{ .global_usage_page = @fromBackingInt(@intCast(0x0C)) }, // Consumer
        .{ .local_usage = 0x0238 },
        .{ .global_logical_range = .{ -127, 127 } },
        .{ .global_report_count = 1 },
        .{ .global_report_size = 8 },
        .{ .main_input = .{ .variable = true, .relative = true } },
        .main_collection_end,
        .main_collection_end,
    },
    .InReport = MouseInReport,
    .OutReport = u8, // Dummy
});

// RAWHID Implementation (QMK Style)
pub const RawHidReport = [32]u8;

// HID Interrupt Driver for the dedicated 32-byte bidirectional RAWHID channel (Companion App Telemetry)
const RawHid = usb.drivers.hid.InterruptDriver(.{
    .subclass = .Unspecified,
    .protocol = .NoneRequired,
    .report_descriptor = &.{
        .{ .global_usage_page = @fromBackingInt(@intCast(0xFF31)) }, // Vendor Page 0xFF31
        .{ .local_usage = 0x0074 }, // Usage 0x0074
        .{ .main_collection = .Application },
        // Input: 32 bytes
        .{ .data = .{
            .usage = .{ .local_raw = 0x01 },
            .count = 32,
            .Child = u8,
            .dir = .in,
            .type = .dynamic,
        } },
        // Output: 32 bytes
        .{ .data = .{
            .usage = .{ .local_raw = 0x02 },
            .count = 32,
            .Child = u8,
            .dir = .out,
            .type = .dynamic,
        } },
        .main_collection_end,
    },
    .InReport = RawHidReport,
    .OutReport = RawHidReport,
});

pub var usb_device: USB_Device = undefined;

pub const ControllerType = usb.DeviceController(.{
    .bcd_usb = .v2_00,
    .device_triple = .unspecified,
    .vendor = .{ .id = 0xFAFA, .str = "OpenKeyboardCollective" },
    .product = .{ .id = 0x00F0, .str = "ZigMkay" },
    // Keep this in sync with descriptor-set changes. Hosts cache HID report
    // descriptors by device identity, so changing the revision forces them to
    // enumerate newly added interfaces such as RawHID.
    .bcd_device = .v1_10,
    .serial = "00000001",
    .max_supported_packet_size = USB_Device.max_supported_packet_size,
    .configurations = &.{.{
        .attributes = .{ .self_powered = false },
        .max_current_ma = 500,
        .Drivers = struct {
            keyboard: Keyboard,
            consumer: ConsumerControl,
            mouse: Mouse,
            rawhid: RawHid,
            reset: rp2xxx.usb.ResetDriver(null, 0),
        },
    }},
}, .{.{
    .keyboard = .{ .itf_string = "Keyboard", .poll_interval = 1 },
    .consumer = .{ .itf_string = "Consumer Control", .poll_interval = 10 },
    .mouse = .{ .itf_string = "Mouse", .poll_interval = 1 },
    .rawhid = .{ .itf_string = "RawHID", .poll_interval = 1 },
    .reset = "",
}});

pub var usb_controller: ControllerType = .init;

pub fn init() void {
    usb_device = .init();
}

pub fn poll() void {
    usb_device.poll(&usb_controller);
}

/// Dispatches a keyboard report over the first HID interface
pub fn send_keyboard_report(report: *const KeyboardInReport) void {
    if (usb_controller.drivers()) |drivers| {
        _ = drivers.keyboard.send_report(report);
    }
}

/// Dispatches a consumer layout report (Media Keys)
pub fn send_consumer_report(report: *const ConsumerInReport) void {
    if (usb_controller.drivers()) |drivers| {
        _ = drivers.consumer.send_report(report);
    }
}

/// Dispatches a mouse payload containing movement or clicks
pub fn send_mouse_report(report: *const MouseInReport) void {
    if (usb_controller.drivers()) |drivers| {
        _ = drivers.mouse.send_report(report);
    }
}

/// Pushes a custom 32-byte payload to the RAWHID interface for companion app signalling
pub fn send_raw_report(report: *const RawHidReport) void {
    if (usb_controller.drivers()) |drivers| {
        _ = drivers.rawhid.send_report(report);
    }
}
