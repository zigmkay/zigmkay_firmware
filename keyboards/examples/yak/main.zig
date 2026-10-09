const std = @import("std");

const microzig = @import("microzig");
comptime {
    microzig.export_startup();
}
pub const std_options = microzig.std_options(.{});
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const gpio = rp2xxx.gpio;
const rollercole_shared_keymap = @import("keymap.zig");
const zigmkay = @import("zigmkay");
const zkeycodes = @import("zkeycodes");
const keymap = @import("keymap.zig");
const core = zigmkay.core;
const encoder_scanning = zigmkay.encoder_scanning;

// uart
const uart_0_rx_pin = gpio.num(1);
const uart_1_tx_pin = gpio.num(4);

// zig fmt: off
pub const pin_config = rp2xxx.pins.GlobalConfiguration{
    .GPIO17 = .{ .name = "led", .direction = .out },
    .GPIO19 = .{ .name = "usb_detection", .direction = .in, .pull = .down },

    .GPIO27 = .{ .name = "data1", .direction = .in, .pull = .up, .function = .SIO},
    .GPIO26 = .{ .name = "data2", .direction = .in, .pull = .up, .function = .SIO},

    .GPIO4 = .{ .name = "GP4", .direction = .in, .pull = .up},
    .GPIO3 = .{ .name = "GP3", .direction = .out, .pull = .up},

    .GPIO13 = .{ .name = "GP13", .direction = .in, .pull = .up},
    .GPIO28 = .{ .name = "GP28", .direction = .in, .pull = .up},
    .GPIO12 = .{ .name = "GP12", .direction = .in, .pull = .up},
    .GPIO29 = .{ .name = "GP29", .direction = .in, .pull = .up},
    .GPIO0 = .{ .name = "GP0", .direction = .in, .pull = .up},

    .GPIO22 = .{ .name = "GP22", .direction = .in, .pull = .up},
    .GPIO14 = .{ .name = "GP14", .direction = .in, .pull = .up},
    .GPIO2 = .{ .name = "GP2", .direction = .in, .pull = .up},

    .GPIO21 = .{ .name = "GP21", .direction = .in, .pull = .up},
    .GPIO23 = .{ .name = "GP23", .direction = .in, .pull = .up},
    .GPIO7 = .{ .name = "GP7", .direction = .in, .pull = .up},
    .GPIO20 = .{ .name = "GP20", .direction = .in, .pull = .up},
    .GPIO5 = .{ .name = "GP5", .direction = .in, .pull = .up},
    .GPIO15 = .{ .name = "GP15", .direction = .in, .pull = .up},
    .GPIO6 = .{ .name = "GP6", .direction = .in, .pull = .up},

    .GPIO16 = .{ .name = "GP16", .direction = .in, .pull = .up},
    .GPIO9 = .{ .name = "GP9", .direction = .in, .pull = .up},
    .GPIO8 = .{ .name = "GP8", .direction = .in, .pull = .up},
};

var encoder_actions = [_]core.EncoderAction{
    .{ .tap = core.TapDef{ .media_key = .VolumeUp } },
    .{ .tap = core.TapDef{ .media_key = .VolumeDown } },
    .{ .tap = core.TapDef{ .key_press = .{ .tap_keycode = 10 } } },
    .{ .tap = core.TapDef{ .key_press = .{ .tap_keycode = 11 } } },
};
var encoder_pin_configs_left = [_]encoder_scanning.EncoderPinConfig{
    .{
    .pin_a = p.data1,
    .pin_b = p.data2,
    .sensitivity = 4,
    .action_index_cw = 0,
    .action_index_ccw = 1,
    }
};
var encoder_pin_configs_right = [_]encoder_scanning.EncoderPinConfig{
    .{
    .pin_a = p.data1,
    .pin_b = p.data2,
    .sensitivity = 4,
    .action_index_cw = 2,
    .action_index_ccw = 3,
    }
};

pub const p = blk: {
    @setEvalBranchQuota(10_000);
    break :blk pin_config.pins();
};

pub const switch_pins_left = [_]?rp2xxx.gpio.Pin{
    p.GP5, p.GP7, p.GP2, p.GP15, p.GP23,      null,null,null,null,null,
    p.GP6, p.GP8, p.GP13, p.GP16,  p.GP20,     null,null,null,null,null,
            p.GP9, p.GP14,  p.GP21, p.GP22,      null,null,null,null,
                                   p.GP12,        null,
};

pub const switch_pins_right = [_]?rp2xxx.gpio.Pin{

        null,null,null,null,null,        p.GP23, p.GP15, p.GP2, p.GP7, p.GP5,
        null,null,null,null,null,        p.GP20, p.GP16, p.GP13, p.GP8, p.GP6,
             null,null,null,null,        p.GP22, p.GP21, p.GP14, p.GP9,
                            null,        p.GP12,
};
// zig fmt: on

pub fn main() !void {
    @setEvalBranchQuota(10_000);
    _ = pin_config.apply();

    const keymap_dimensions = zigmkay.core.KeymapDimensions{
        .key_count = keymap.key_count,
        .layer_count = keymap.keymap.len,
    };

    const primary = check_is_primary_side();
    p.led.put(if (primary) 1 else 0);

    if (primary) {
        blink_led(3, 300); // Show the user that the keyboard has actually booted up.
        var uart = init_uart_0_rx();
        comptime var config = zigmkay.loops.GetPrimarySideConfigType(&keymap_dimensions){
            .config = .{
                .keymap = &keymap.keymap,
                .scanner_settings = &.{
                    .direct_wiring = .{
                        .debounce = .{ .ms = 50 },
                        .switch_pins = &switch_pins_left,
                    },
                },
                .encoder_pin_configs = encoder_pin_configs_left[0..],
                .encoder_actions = encoder_actions[0..],
                //.combos = rollercole_shared_keymap.combos[0..],
                //.custom_functions = &rollercole_shared_keymap.custom_functions,
                //.side_definition = &rollercole_shared_keymap.sides,
            },
        };

        comptime var runner = config.build();
        runner.run_primary(&uart) catch {
            blink_led(10000000, 500); // in case of an error, let the keyboard start blinking
        };
    } else {
        var uart = init_uart_1_tx();

        blink_led(1, 1000); // Show the user that the keyboard has actually booted up.
        comptime var config = zigmkay.loops.GetSecondarySideConfigType(&keymap_dimensions){
            .config = .{
                .scanner_settings = &.{
                    .direct_wiring = .{
                        .debounce = .{ .ms = 50 },
                        .switch_pins = &switch_pins_right,
                    },
                },
                .encoder_pin_configs = encoder_pin_configs_right[0..],
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

pub fn init_uart_0_rx() zigmkay.split_communication.UartClient {
    // Primary side: GPIO1 is UART0 RX only (hardwired in RP2040 silicon)
    uart_0_rx_pin.set_function(.uart);
    const uart = rp2xxx.uart.instance.num(0);
    uart.apply(.{ .clock_config = rp2xxx.clock_config, .baud_rate = 9600 });
    return zigmkay.split_communication.UartClient{ .uart = uart };
}

pub fn init_uart_1_tx() zigmkay.split_communication.UartClient {
    // Primary side: GPIO1 is UART0 RX only (hardwired in RP2040 silicon)
    uart_1_tx_pin.set_function(.uart);
    const uart = rp2xxx.uart.instance.num(1);
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
