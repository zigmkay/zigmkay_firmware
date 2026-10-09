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

// uart
const uart_rx_pin = gpio.num(1);

// zig fmt: off
pub const pin_config = rp2xxx.pins.GlobalConfiguration{
    .GPIO17 = .{ .name = "led", .direction = .out },
    .GPIO19 = .{ .name = "usb_detection", .direction = .in, .pull = .down },

    .GPIO13 = .{ .name = "GP13", .direction = .in, .pull = .up},
    .GPIO28 = .{ .name = "GP28", .direction = .in, .pull = .up},
    .GPIO12 = .{ .name = "GP12", .direction = .in, .pull = .up},
    .GPIO29 = .{ .name = "GP29", .direction = .in, .pull = .up},
    .GPIO0 = .{ .name = "GP0", .direction = .in, .pull = .up},

    .GPIO22 = .{ .name = "GP22", .direction = .in, .pull = .up},
    .GPIO14 = .{ .name = "GP14", .direction = .in, .pull = .up},
    .GPIO26 = .{ .name = "GP26", .direction = .in, .pull = .up},
    .GPIO4 = .{ .name = "GP4", .direction = .in, .pull = .up},
    .GPIO27 = .{ .name = "GP27", .direction = .in, .pull = .up},

    .GPIO21 = .{ .name = "GP21", .direction = .in, .pull = .up},
    .GPIO23 = .{ .name = "GP23", .direction = .in, .pull = .up},
    .GPIO7 = .{ .name = "GP7", .direction = .in, .pull = .up},
    .GPIO20 = .{ .name = "GP20", .direction = .in, .pull = .up},
    .GPIO6 = .{ .name = "GP6", .direction = .in, .pull = .up},

    .GPIO16 = .{ .name = "GP16", .direction = .in, .pull = .up},
    .GPIO9 = .{ .name = "GP9", .direction = .in, .pull = .up},
    .GPIO8 = .{ .name = "GP8", .direction = .in, .pull = .up},
};
pub const p = blk: {
    @setEvalBranchQuota(10_000);
    break :blk pin_config.pins();
};

pub const switch_pins_left = [_]?rp2xxx.gpio.Pin{
    p.GP13, p.GP28, p.GP12, p.GP29, p.GP0,      null,null,null,null,null,
    p.GP22, p.GP14, p.GP26, p.GP4,  p.GP27,     null,null,null,null,null,
    p.GP21, p.GP23, p.GP7,  p.GP20, p.GP6,      null,null,null,null,null,
                    p.GP16, p.GP9,  p.GP8,      null,null,null,
};

pub const switch_pins_right = [_]?rp2xxx.gpio.Pin{
        null,null,null,null,null,        p.GP0, p.GP29, p.GP12, p.GP28, p.GP13,  
        null,null,null,null,null,       p.GP27,  p.GP4, p.GP26, p.GP14,  p.GP22, 
        null,null,null,null,null,        p.GP6, p.GP20,  p.GP7, p.GP23, p.GP21,  
                  null,null,null,        p.GP8,  p.GP9, p.GP16                                  
};
// zig fmt: on

pub fn main() !void {
    @setEvalBranchQuota(10_000);
    _ = pin_config.apply();

    const keymap_dimensions = zigmkay.core.KeymapDimensions{
        .key_count = keymap.key_count,
        .layer_count = keymap.keymap.len,
    };

    blink_led(1, 300); // Show the user that the keyboard has actually booted up.

    const primary = check_is_primary_side();
    p.led.put(if (primary) 1 else 0);

    if (primary) {
        var uart = init_uart();
        comptime var config = zigmkay.loops.GetPrimarySideConfigType(&keymap_dimensions){
            .config = .{
                .keymap = &keymap.keymap,
                .scanner_settings = &.{
                    .direct_wiring = .{
                        .debounce = .{ .ms = 50 },
                        .switch_pins = &switch_pins_left,
                    },
                },
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
        var uart = init_pio_uart();
        comptime var config = zigmkay.loops.GetSecondarySideConfigType(&keymap_dimensions){
            .config = .{
                .scanner_settings = &.{
                    .direct_wiring = .{
                        .debounce = .{ .ms = 50 },
                        .switch_pins = &switch_pins_right,
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
    // Primary side: GPIO1 is UART0 RX only (hardwired in RP2040 silicon)
    uart_rx_pin.set_function(.uart);
    const uart = rp2xxx.uart.instance.num(0);
    uart.apply(.{ .clock_config = rp2xxx.clock_config, .baud_rate = 9600 });
    return zigmkay.split_communication.UartClient{ .uart = uart };
}

pub fn init_pio_uart() zigmkay.split_communication.UartClient {
    // Secondary side: PIO TX on GPIO1 (hardware UART cannot TX on GPIO1)
    const pio_tx = zigmkay.split_communication.init_pio_uart_tx(gpio.num(1), 9600);
    return zigmkay.split_communication.UartClient{ .pio_uart_tx = pio_tx };
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
