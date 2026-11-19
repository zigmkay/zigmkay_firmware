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
const dk = zigmkay.keycodes.dk;
const core = zigmkay.core;
const us = zigmkay.keycodes.us;

// zig fmt: off
pub const pin_config = rp2xxx.pins.GlobalConfiguration{
    .GPIO17 = .{ .name = "led", .direction = .out },

    .GPIO20 = .{ .name = "col0", .direction = .out },
    .GPIO23 = .{ .name = "col1", .direction = .out },
    .GPIO21 = .{ .name = "col2", .direction = .out },
    .GPIO7 = .{ .name = "col3", .direction = .out },
    .GPIO8 = .{ .name = "col4", .direction = .out },

    .GPIO27 = .{ .name = "row0", .direction = .in },
    .GPIO26= .{ .name = "row1", .direction = .in },
    .GPIO22 = .{ .name = "row2", .direction = .in },
    .GPIO4 = .{ .name = "row3", .direction = .in },
    .GPIO5 = .{ .name = "row4", .direction = .in },
    .GPIO6 = .{ .name = "row5", .direction = .in },
};
pub const p = pin_config.pins();

pub const pin_mappings = [rollercole_shared_keymap.key_count]?[2]usize{
  .{0,0}, .{1,0}, .{2,0}, .{3,0}, .{4,0},  .{4,3},.{3,3},.{2,3},.{1,3},.{0,3},
  .{0,1}, .{1,1}, .{2,1}, .{3,1}, .{4,1},    .{4,4},.{3,4},.{2,4},.{1,4},.{0,4},
          .{1,2}, .{2,2}, .{3,2}, .{4,2},    .{4,5},.{3,5},.{2,5},.{1,5},
                                 .{0, 2},   .{0, 5}
};

// zig fmt: on
pub const clacky_pin_cols = [_]rp2xxx.gpio.Pin{ p.col0, p.col1, p.col2, p.col3, p.col4 };
pub const clacky_pin_rows = [_]rp2xxx.gpio.Pin{ p.row0, p.row1, p.row2, p.row3, p.row4, p.row5 };

pub fn main() !void {
    _ = pin_config.apply();
    blink_led(1, 300); // Show the user that the keyboard has actually booted up.

    // Mandatory
    comptime var config = zigmkay.loops.GetUnibodyConfigType(&rollercole_shared_keymap.dimensions){
        .config = .{
            .keymap = &rollercole_shared_keymap.keymap,
            .custom_functions = &rollercole_shared_keymap.custom_functions,
            .side_definition = &rollercole_shared_keymap.sides,
            .combos = rollercole_shared_keymap.combos[0..],
            .scanner_settings = &.{
                .matrix = .{
                    .debounce = .{ .ms = 50 },
                    .pins_to_keys_mapping = &pin_mappings,
                    .pin_cols = clacky_pin_cols[0..],
                    .pin_rows = clacky_pin_rows[0..],
                    .direction = .col2row,
                },
            },
        },
    };

    // Optionals
    comptime var runner = config.build();
    runner.run_unibody() catch {
        blink_led(10000000, 500); // in case of an error, let the keyboard start blinking
    };
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
