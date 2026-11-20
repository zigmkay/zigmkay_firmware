// =============================================================================
// template_board: main file
// =============================================================================
// Created by `mise run //keyboards:board:new template_board` from
// keyboards/tools/templates/main.zig, for a unibody RP2040 board with a
// row/column switch matrix, like the Leonardo Keycaprio and the Molekula.
//
// This file owns the hardware: GPIO pins, the matrix, which switch is which
// key index, and the processing loop. The keys themselves live in the keymap,
// reached as @import("keymap") so the same main file builds with any keymap.
//
// Replace every pin below with your PCB's wiring (the schematic, or the QMK or
// ZMK files of the board, list it). Everything marked "Optional" can go.
//
// For a split keyboard, start from keyboards/examples/dasbob/ instead: it
// shows the UART link and how each half detects that it is the primary side.
// =============================================================================

const microzig = @import("microzig");
comptime {
    microzig.export_startup();
}
pub const std_options = microzig.std_options(.{});

const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const gpio = rp2xxx.gpio;
const zigmkay = @import("zigmkay");
const keymap = @import("keymap");

// =============================================================================
// PINS
// =============================================================================
// One entry per GPIO: columns are outputs, rows are inputs. The names are
// yours; `p.<name>` refers to the pin below. Use the RP2040 GPIO numbers, not
// the pin numbers printed on a Pro Micro style controller.

// zig fmt: off
pub const pin_config = rp2xxx.pins.GlobalConfiguration{
    // Optional: a status LED that blinks once at startup and keeps blinking
    // after an error. Remove it, and blink_led below, if the board has none.
    .GPIO17 = .{ .name = "led", .direction = .out },

    // Columns, left to right.
    .GPIO2  = .{ .name = "c0", .direction = .out },
    .GPIO3  = .{ .name = "c1", .direction = .out },
    .GPIO4  = .{ .name = "c2", .direction = .out },
    .GPIO5  = .{ .name = "c3", .direction = .out },
    .GPIO6  = .{ .name = "c4", .direction = .out },
    .GPIO7  = .{ .name = "c5", .direction = .out },
    .GPIO8  = .{ .name = "c6", .direction = .out },
    .GPIO9  = .{ .name = "c7", .direction = .out },
    .GPIO10 = .{ .name = "c8", .direction = .out },
    .GPIO11 = .{ .name = "c9", .direction = .out },

    // Rows, top to bottom; row 3 holds the thumb keys.
    .GPIO26 = .{ .name = "r0", .direction = .in },
    .GPIO27 = .{ .name = "r1", .direction = .in },
    .GPIO28 = .{ .name = "r2", .direction = .in },
    .GPIO29 = .{ .name = "r3", .direction = .in },
};
// zig fmt: on

pub const p = blk: {
    @setEvalBranchQuota(10_000);
    break :blk pin_config.pins();
};

/// The scan order: `pin_mappings` refers to these by position.
pub const pin_cols = [_]gpio.Pin{ p.c0, p.c1, p.c2, p.c3, p.c4, p.c5, p.c6, p.c7, p.c8, p.c9 };
pub const pin_rows = [_]gpio.Pin{ p.r0, p.r1, p.r2, p.r3 };

// =============================================================================
// PIN MAPPINGS
// =============================================================================
// One `.{ column, row }` pair per key index, in keymap order: entry 0 is the
// first key of every keymap layer. Column and row are positions in pin_cols
// and pin_rows, not GPIO numbers. `null` marks a key index with no switch.
// The array length comes from keymap.key_count, so a keymap with a different
// number of keys fails to compile instead of mixing up keys.

// zig fmt: off
pub const pin_mappings = [keymap.key_count]?[2]usize{
    .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 }, .{ 4, 0 },     .{ 5, 0 }, .{ 6, 0 }, .{ 7, 0 }, .{ 8, 0 }, .{ 9, 0 },
    .{ 0, 1 }, .{ 1, 1 }, .{ 2, 1 }, .{ 3, 1 }, .{ 4, 1 },     .{ 5, 1 }, .{ 6, 1 }, .{ 7, 1 }, .{ 8, 1 }, .{ 9, 1 },
    .{ 0, 2 }, .{ 1, 2 }, .{ 2, 2 }, .{ 3, 2 }, .{ 4, 2 },     .{ 5, 2 }, .{ 6, 2 }, .{ 7, 2 }, .{ 8, 2 }, .{ 9, 2 },
                                    .{ 3, 3 }, .{ 4, 3 },     .{ 5, 3 }, .{ 6, 3 },
};
// zig fmt: on

// =============================================================================
// MAIN
// =============================================================================

pub fn main() !void {
    @setEvalBranchQuota(10_000);
    _ = pin_config.apply();
    blink_led(1, 300); // Shows that the firmware started.

    comptime var config = zigmkay.loops.GetUnibodyConfigType(&keymap.dimensions){
        .config = .{
            .keymap = &keymap.keymap,
            .combos = keymap.combos[0..],
            .custom_functions = &keymap.custom_functions,
            // Which hand each key belongs to; the processor uses it for
            // home-row modifiers. Leave it out to treat every key as `.X`.
            .side_definition = &keymap.sides,
            .scanner_settings = &.{
                .matrix = .{
                    .debounce = .{ .ms = 50 },
                    .pin_cols = pin_cols[0..],
                    .pin_rows = pin_rows[0..],
                    .pins_to_keys_mapping = &pin_mappings,
                    // Diode direction: .col2row when the diodes point from
                    // the column to the row (the common case), else .row2col.
                    .direction = .col2row,
                },
            },
            // Optional: rotary encoders. See my_keyboards/molekula/main.zig.
            // .encoder_pin_configs = encoder_pin_configs[0..],
            // .encoder_actions = encoder_actions[0..],
        },
    };

    comptime var runner = config.build();
    runner.run_unibody() catch {
        blink_led(10000000, 500); // Keeps blinking after an error.
    };
}

/// Blinks the status LED `blink_count` times.
pub fn blink_led(blink_count: u32, interval_ms: u32) void {
    var counter = blink_count;
    while (counter > 0) : (counter -= 1) {
        p.led.put(1);
        time.sleep_us(interval_ms * 1000);
        p.led.put(0);
        time.sleep_us(interval_ms * 1000);
    }
}
