const std = @import("std");

const microzig = @import("microzig");
comptime {
    microzig.export_startup();
}
pub const std_options = microzig.std_options(.{});
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const gpio = rp2xxx.gpio;
const rollercole_shared_keymap = @import("shared_keymap_28_1.zig");
const zigmkay = @import("zigmkay");
const zkeycodes = @import("zkeycodes");

// uart
const uart_tx_pin = gpio.num(0);
const uart_rx_pin = gpio.num(1);

// zig fmt: off
pub const pin_config = rp2xxx.pins.GlobalConfiguration{
    .GPIO17 = .{ .name = "led", .direction = .out },
    .GPIO19 = .{ .name = "usb_detection", .direction = .in, .pull = .down },

    .GPIO6 = .{ .name = "col", .direction = .out },

    .GPIO7 = .{ .name = "k7", .direction = .in },
    .GPIO8 = .{ .name = "k8", .direction = .in },
    .GPIO9 = .{ .name = "k9", .direction = .in },
    .GPIO12 = .{ .name = "k12", .direction = .in },
    .GPIO13 = .{ .name = "k13", .direction = .in },
    .GPIO14 = .{ .name = "k14", .direction = .in },
    .GPIO15 = .{ .name = "k15", .direction = .in },
    .GPIO16 = .{ .name = "k16", .direction = .in },
    .GPIO21 = .{ .name = "k21", .direction = .in },
    .GPIO23 = .{ .name = "k23", .direction = .in },
    .GPIO20 = .{ .name = "k20", .direction = .in },
    .GPIO22 = .{ .name = "k22", .direction = .in },
    .GPIO26 = .{ .name = "k26", .direction = .in },
    .GPIO27 = .{ .name = "k27", .direction = .in },
    .GPIO10 = .{ .name = "k10", .direction = .in },
};
pub const p = blk: {
    @setEvalBranchQuota(10_000);
    break :blk pin_config.pins();
};
pub const pin_mappings_right = [rollercole_shared_keymap.key_count]?[2]usize{
   null, null, null, null, null,  .{0,13},.{0,12},.{0,11},.{0,10},.{0,5},
   null, null, null, null, null,   .{0,9},.{0,8},.{0,7},.{0,6},.{0,0},
         null, null, null, null,   .{0,4},.{0,3},.{0,2},.{0,1},
                           null,   .{0, 14}
};

pub const pin_mappings_left = [rollercole_shared_keymap.key_count]?[2]usize{
  .{0,5}, .{0,10},.{0,11},.{0,12},.{0,13},       null, null, null, null, null,
  .{0,0}, .{0,6}, .{0,7}, .{0,8}, .{0,9},       null, null, null, null, null,
          .{0,1}, .{0,2}, .{0,3}, .{0,4},      null, null, null, null,
                                 .{0, 14},       null
};

// zig fmt: on
pub const clacky_pin_cols = [_]rp2xxx.gpio.Pin{p.col};
pub const clacky_pin_rows = [_]rp2xxx.gpio.Pin{ p.k7, p.k8, p.k9, p.k12, p.k13, p.k14, p.k15, p.k16, p.k21, p.k23, p.k20, p.k22, p.k26, p.k27, p.k10 };

pub fn main() !void {
    _ = pin_config.apply();
    var uart = init_uart();

    const primary = check_is_primary_side();
    if (primary) {
        blink_led(3, 200); // Show the user that the keyboard has actually booted up.
        comptime var config = zigmkay.loops.GetPrimarySideConfigType(&rollercole_shared_keymap.dimensions){
            .config = .{
                .keymap = &rollercole_shared_keymap.keymap,
                .combos = rollercole_shared_keymap.combos[0..],
                .scanner_settings = &.{
                    .matrix = .{
                        .debounce = .{ .ms = 50 },
                        .pin_cols = clacky_pin_cols[0..],
                        .pin_rows = clacky_pin_rows[0..],
                        .pins_to_keys_mapping = &pin_mappings_right,
                        .direction = .col2row,
                    },
                },
                .custom_functions = &rollercole_shared_keymap.custom_functions,
                .side_definition = &rollercole_shared_keymap.sides,
            },
        };

        comptime var runner = config.build();
        runner.run_primary(&uart) catch {
            blink_led(10000000, 500); // in case of an error, let the keyboard start blinking
        };
    } else {
        blink_led(1, 1000); // Show the user that the keyboard has actually booted up.
        comptime var config = zigmkay.loops.GetSecondarySideConfigType(&rollercole_shared_keymap.dimensions){
            .config = .{
                .scanner_settings = &.{
                    .matrix = .{
                        .debounce = .{ .ms = 50 },
                        .pin_cols = clacky_pin_cols[0..],
                        .pin_rows = clacky_pin_rows[0..],
                        .pins_to_keys_mapping = &pin_mappings_left,
                        .direction = .col2row,
                    },
                },
            },
        };

        comptime var runner = config.build();
        runner.run_secondary(&uart) catch {
            blink_led(10000000, 500); // in case of an error, let the keyboard start blinking
        };
    }
}
pub fn check_is_primary_side() bool {
    const usb_detect_pin = gpio.num(19);
    usb_detect_pin.set_function(.sio);
    usb_detect_pin.set_direction(.in);
    usb_detect_pin.set_pull(.down);
    time.sleep_ms(1);
    const primary = usb_detect_pin.read() == 1;
    return primary;
}

pub fn init_uart() zigmkay.split_communication.UartClient {
    // uart init
    uart_tx_pin.set_function(.uart);
    uart_rx_pin.set_function(.uart);
    const uart = rp2xxx.uart.instance.num(0);
    uart.apply(.{ .clock_config = rp2xxx.clock_config, .baud_rate = 9600 });
    return zigmkay.split_communication.UartClient{ .uart = uart };
}

pub fn blink_led(blink_count: u32, interval_ms: u32) void {
    var counter = blink_count;
    while (counter > 0) : (counter -= 1) {
        p.led.put(1);
        time.sleep_us(interval_ms * 1000);
        p.led.put(0);
        time.sleep_us(interval_ms * 1000);
    }
}
