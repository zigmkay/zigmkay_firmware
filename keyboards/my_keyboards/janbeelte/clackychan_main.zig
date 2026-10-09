const std = @import("std");

const keymap = @import("clackychan_colemak_keymap.zig");
const zigmkay = @import("zigmkay");
const microzig = @import("microzig");
comptime {
    microzig.export_startup();
}
pub const std_options = microzig.std_options(.{});
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const gpio = rp2xxx.gpio;

const uart_tx_pin = gpio.num(0);
const uart_rx_pin = gpio.num(1);

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

// zig fmt: off
pub const pin_mappings_right = [keymap.key_count]?[2]usize{
   null, null, null, null, null,  .{0,13},.{0,12},.{0,11},.{0,10},.{0,5},
   null, null, null, null, null,   .{0,9},.{0,8},.{0,7},.{0,6},.{0,0},
         null, null, null, null,   .{0,4},.{0,3},.{0,2},.{0,1},
                           null,   .{0, 14}
};

pub const pin_mappings_left = [keymap.key_count]?[2]usize{
  .{0,5}, .{0,10},.{0,11},.{0,12},.{0,13},       null, null, null, null, null,
  .{0,0}, .{0,6}, .{0,7}, .{0,8}, .{0,9},       null, null, null, null, null,
          .{0,1}, .{0,2}, .{0,3}, .{0,4},      null, null, null, null,
                                 .{0, 14},       null
};
// zig fmt: on

// =============================================================================
// PIN ARRAYS FOR MATRIX SCANNER
// =============================================================================
// These arrays are passed to the matrix scanner to identify which pins to scan.
// The scanner will iterate through columns and read rows to detect key presses.

pub const clacky_pin_cols = [_]rp2xxx.gpio.Pin{p.col};
pub const clacky_pin_rows = [_]rp2xxx.gpio.Pin{ p.k7, p.k8, p.k9, p.k12, p.k13, p.k14, p.k15, p.k16, p.k21, p.k23, p.k20, p.k22, p.k26, p.k27, p.k10 };

// =============================================================================
// MAIN FUNCTION - Firmware Entry Point
// =============================================================================
// This is called when the microcontroller starts up.

pub fn main() !void {

    // Init pins
    _ = pin_config.apply(); // dont know how this could be done inside the module, but it needs to be done for things to work
    var uart = init_uart();
    const primary = check_is_primary_side();
    if (primary) {
        blink_led(1, 300);
        comptime var config = zigmkay.loops.GetPrimarySideConfigType(&keymap.dimensions){
            .config = .{
                .keymap = &keymap.keymap,
                .combos = keymap.combos[0..],
                .scanner_settings = &.{
                    .matrix = .{
                        .debounce = .{ .ms = 50 },
                        .pin_cols = clacky_pin_cols[0..],
                        .pin_rows = clacky_pin_rows[0..],
                        .pins_to_keys_mapping = &pin_mappings_right,
                        .direction = .col2row,
                    },
                },
                .custom_functions = &keymap.custom_functions,
                .side_definition = &keymap.sides,
            },
        };
        comptime var runner = config.build();
        runner.run_primary(&uart) catch {
            blink_led(100000, 50);
        };
    } else {
        blink_led(5, 50);
        comptime var config = zigmkay.loops.GetSecondarySideConfigType(&keymap.dimensions){
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
            blink_led(100000, 50);
        };
    }
}

pub fn check_is_primary_side() bool {
    time.sleep_ms(1);
    return p.usb_detection.read() == 1;
}

pub fn init_uart() zigmkay.split_communication.UartClient {
    // uart init
    uart_tx_pin.set_function(.uart);
    uart_rx_pin.set_function(.uart);
    const uart = rp2xxx.uart.instance.num(0);
    uart.apply(.{ .clock_config = rp2xxx.clock_config, .baud_rate = 9600 });
    return .{ .uart = uart };
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
