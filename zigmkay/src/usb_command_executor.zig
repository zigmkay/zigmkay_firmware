const std = @import("std");
const core = @import("core.zig");
const microzig = @import("microzig");
const rp2xxx = @import("microzig").hal;

const usb_if = @import("usb_if.zig");
const time = rp2xxx.time;

pub fn CreateAndInitUsbCommandExecutor() UsbCommandExecutor {
    usb_if.init();
    return UsbCommandExecutor{};
}

pub const UsbCommandExecutor = struct {
    var keyboard_report: usb_if.KeyboardInReport = .empty;
    var mouse_report: usb_if.MouseInReport = .empty;
    var prev_action_time: core.TimeSinceBoot = core.TimeSinceBoot.from_absolute_us(0);

    // Time to wait between USB polls in microseconds.
    const next_tick_delay: u64 = 10000;
    pub fn HouseKeepAndProcessCommands(self: *const UsbCommandExecutor, output_command_queue: *core.OutputCommandQueue, current_time: core.TimeSinceBoot) !void {
        _ = self;

        usb_if.poll(); // Process pending USB events

        const diff_us = current_time.time_since_boot_us - prev_action_time.time_since_boot_us;

        if (diff_us > next_tick_delay) {
            if (output_command_queue.dequeue()) |command| {
                prev_action_time = current_time;
                var should_send_keyboard_report = false;
                switch (command) {
                    .KeyCodePress => |keycode| {
                        should_send_keyboard_report = true;

                        // look through the keyboard report and check if the key is already pressed
                        var already_pressed = false;
                        for (&keyboard_report.keys) |key| {
                            if (key == keycode) {
                                already_pressed = true;
                                break;
                            }
                        }

                        if (!already_pressed) {
                            for (&keyboard_report.keys) |*key| {
                                if (key.* == 0) {
                                    key.* = keycode;
                                    break;
                                }
                            }
                        }
                    },
                    .KeyCodeRelease => |keycode| {
                        should_send_keyboard_report = true;
                        for (&keyboard_report.keys) |*key| {
                            if (key.* == keycode) {
                                key.* = 0;
                                break;
                            }
                        }
                    },
                    .ModifiersChanged => |modifiers| {
                        should_send_keyboard_report = true;
                        keyboard_report.modifiers = modifiers.toByte();
                    },
                    .ActivateBootMode => {
                        rp2xxx.rom.reset_to_usb_boot();
                    },
                    .RawHidSignal => |sig| {
                        var report: usb_if.RawHidReport = @splat(0);
                        report[0] = sig.signal_id;
                        @memcpy(report[1 .. 1 + sig.len], sig.data[0..sig.len]);
                        usb_if.send_raw_report(&report);
                    },
                    .ConsumerKeyPressed => |key| {
                        var report = usb_if.ConsumerInReport{ .button = @backingInt(key) };
                        usb_if.send_consumer_report(&report);
                    },
                    .ConsumerKeyReleased => {
                        var empty_report = usb_if.ConsumerInReport{ .button = 0 };
                        usb_if.send_consumer_report(&empty_report);
                    },
                    .MouseCommandPressed => |action| {
                        update_report(action, true, &mouse_report);
                        usb_if.send_mouse_report(&mouse_report);
                        // Clear relative movements after sending
                        mouse_report.wheel = 0;
                        mouse_report.pan = 0;
                    },
                    .MouseCommandReleased => |action| {
                        update_report(action, false, &mouse_report);
                        usb_if.send_mouse_report(&mouse_report);

                        // Clear relative movements after sending
                        mouse_report.wheel = 0;
                        mouse_report.pan = 0;
                    },
                }

                if (should_send_keyboard_report) {
                    usb_if.send_keyboard_report(&keyboard_report);
                }
            }
        }
    }
};

fn update_report(mouse_action: core.MouseAction, pressed: bool, mouse_report: *usb_if.MouseInReport) void {
    switch (mouse_action) {
        .LeftButton => {
            if (pressed) mouse_report.buttons |= 0x01 else mouse_report.buttons &= ~@as(u8, 0x01);
        },
        .RightButton => {
            if (pressed) mouse_report.buttons |= 0x02 else mouse_report.buttons &= ~@as(u8, 0x02);
        },
        .MiddleButton => {
            if (pressed) mouse_report.buttons |= 0x04 else mouse_report.buttons &= ~@as(u8, 0x04);
        },
        .Button4 => {
            if (pressed) mouse_report.buttons |= 0x08 else mouse_report.buttons &= ~@as(u8, 0x08);
        },
        .Button5 => {
            if (pressed) mouse_report.buttons |= 0x10 else mouse_report.buttons &= ~@as(u8, 0x10);
        },
        .WheelUp => {
            if (pressed) mouse_report.wheel = 1;
        },
        .WheelDown => {
            if (pressed) mouse_report.wheel = -1;
        },
        .WheelLeft => {
            if (pressed) mouse_report.pan = -1;
        },
        .WheelRight => {
            if (pressed) mouse_report.pan = 1;
        },
    }
}
