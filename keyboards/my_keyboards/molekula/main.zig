// =============================================================================
// ZIGMKAY MOLEKULA MAIN FIRMWARE
// =============================================================================
// This file contains the hardware-specific configuration for the Molekula keyboard.
// It defines GPIO pin mappings, scanner settings, and initializes the firmware.
//
// **NORMAL USERS DO NOT NEED TO EDIT THIS FILE**
//
// You would only modify this file if:
//   - You are adapting zigmkay for a DIFFERENT KEYBOARD PCB
//   - You are using a DIFFERENT MICROCONTROLLER supported by microzig
//   - You need to adjust debounce timing for your switch type
//
// For customizing your keymap, layers, and combos, edit src/keymap.zig instead.
// =============================================================================

const std = @import("std");

const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const microzig = @import("microzig");
comptime {
    microzig.export_startup();
}
pub const std_options = microzig.std_options(.{});

// rp2xxx = "RP2040" - The Raspberry Pi Pico's microcontroller
// This is the hardware abstraction layer provided by microzig
const rp2xxx = microzig.hal;

// Time utilities for delays
const time = rp2xxx.time;

// GPIO (General Purpose Input/Output) for controlling pins
const gpio = rp2xxx.gpio;

// Import our keymap definitions from keymap.zig
const keymap = @import("keymap.zig");

// =============================================================================
// UART CONFIGURATION (Serial Communication)
// =============================================================================
// UART is disabled by default but can be enabled for debugging.
// UART_TX = Transmit pin, UART_RX = Receive pin
// These are set to GPIO 0 and 1 but are currently unused.

const uart_tx_pin = gpio.num(0);
const uart_rx_pin = gpio.num(1);

// =============================================================================
// PIN CONFIGURATION
// =============================================================================
// This section defines the physical GPIO pins used by the keyboard matrix.
//
// PIN NAMING CONVENTION:
//   c0, c1, c2, c3, c4 = Column pins (output, drives rows)
//   r0, r1, r2, r3, ... = Row pins (input, reads columns)
//   enc_a, enc_b = Rotary encoder pins ( quadrature input)
//   led = Status LED pin (output)
//
// MATRIX WIRING CONCEPT:
//   The keyboard uses a row/column matrix scanning approach:
//   1. Columns are outputs - one column is "active" at a time (driven low)
//   2. Rows are inputs - they read which keys are pressed in the active column
//   3. By scanning through all columns and reading rows, we detect key presses
//
// HOW THIS MATRIX WORKS (simplified):
//   [c0]───[sw0]───[r0]
//              └───[sw10]───[r1]
//   When column 0 is driven low, we read rows to see which keys are pressed
//
// CUSTOMIZATION: If using a different PCB:
//   - Identify which GPIO pins your columns and rows are connected to
//   - Update the pin_config below to match your wiring
//   - Also update pin_mappings array later in this file
//   - Note: Some pins have restrictions (e.g., no analog, no UART on some pins)

pub const pin_config = rp2xxx.pins.GlobalConfiguration{
    // Status LED on GPIO 17 - blinks during startup, flashes on errors
    .GPIO17 = .{ .name = "led", .direction = .out },

    // Column 4 (rightmost column) on GPIO 1
    .GPIO1 = .{ .name = "c4", .direction = .out },

    // Row pins - these read key presses (input with pull-up typically)
    // Rows are read when a column is driven active
    .GPIO6 = .{ .name = "r7", .direction = .in }, // Row 7
    .GPIO7 = .{ .name = "r6", .direction = .in }, // Row 6
    .GPIO8 = .{ .name = "r5", .direction = .in }, // Row 5
    .GPIO9 = .{ .name = "r4", .direction = .in }, // Row 4
    .GPIO21 = .{ .name = "r3", .direction = .in }, // Row 3
    .GPIO23 = .{ .name = "r2", .direction = .in }, // Row 2
    .GPIO20 = .{ .name = "r1", .direction = .in }, // Row 1
    .GPIO22 = .{ .name = "r0", .direction = .in }, // Row 0

    // Column pins - these drive rows (output)
    .GPIO26 = .{ .name = "c0", .direction = .out }, // Column 0 (leftmost)
    .GPIO27 = .{ .name = "c1", .direction = .out }, // Column 1
    .GPIO28 = .{ .name = "c2", .direction = .out }, // Column 2
    .GPIO29 = .{ .name = "c3", .direction = .out }, // Column 3

    // TODO: mag keys again after
    // Rotary encoder pins - quadrature encoder for volume knob
    // Encoder has 2 pins (A and B) that produce different patterns when rotated
    // .GPIO4 = .{ .name = "enc_a", .direction = .in }, // Encoder pin A
    // .GPIO5 = .{ .name = "enc_b", .direction = .in }, // Encoder pin B
};

// Generate pin accessors from the configuration
// This creates named references like 'p.c0', 'p.r0', 'p.led', etc.
pub const p = pin_config.pins();

// zig fmt: off
// =============================================================================
// PIN MAPPINGS
// =============================================================================
// This array maps KEY POSITIONS (indices 0-39) to GPIO PIN PAIRS (column, row).
// This tells the firmware which physical switch corresponds to each key index.
pub const pin_mappings = [keymap.key_count]?[2]usize{
               .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 }, .{ 4, 0 },          .{ 0, 4 }, .{ 1, 4 }, .{ 2, 4 }, .{ 3, 4 }, .{ 4, 4 },
    .{ 0, 3 }, .{ 0, 1 }, .{ 1, 1 }, .{ 2, 1 }, .{ 3, 1 }, .{ 4, 1 },          .{ 0, 5 }, .{ 1, 5 }, .{ 2, 5 }, .{ 3, 5 }, .{ 4, 5 }, .{ 4, 7 },
               .{ 0, 2 }, .{ 1, 2 }, .{ 2, 2 }, .{ 3, 2 }, .{ 4, 2 },          .{ 0, 6 }, .{ 1, 6 }, .{ 2, 6 }, .{ 3, 6 }, .{ 4, 6 },

                                     .{ 2, 3 }, .{ 3, 3 }, .{ 4, 3 },          .{ 0, 7 }, .{ 1, 7 }, .{ 2, 7 },

    // null,  null, TODO: encoder functionality not implemented in zigmkay again
};
// zig fmt: on

// =============================================================================
// SCANNER SETTINGS
// =============================================================================
// Configuration for the matrix scanning algorithm that detects key presses.

// =============================================================================
// PIN ARRAYS FOR MATRIX SCANNER
// =============================================================================
// These arrays are passed to the matrix scanner to identify which pins to scan.
// The scanner will iterate through columns and read rows to detect key presses.

pub const molekula_pin_cols = [_]rp2xxx.gpio.Pin{ p.c0, p.c1, p.c2, p.c3, p.c4 };
pub const molekula_pin_rows = [_]rp2xxx.gpio.Pin{ p.r0, p.r1, p.r2, p.r3, p.r4, p.r5, p.r6, p.r7 };

// Encoder pins: A and B phases for quadrature encoder
pub const encoder_pins = [2]rp2xxx.gpio.Pin{ p.enc_a, p.enc_b };

// =============================================================================
// MAIN FUNCTION - Firmware Entry Point
// =============================================================================
// This is called when the microcontroller starts up.

pub fn main() !void {

    // Apply pin configuration to hardware
    // This configures all the GPIO pins as defined in pin_config above
    // Note: This can't be done inside the module initialization due to hardware constraints
    _ = pin_config.apply();

    // Flash LED once to indicate firmware loaded successfully
    blink_led(1, 300);

    // Run the primary keyboard processing loop
    // This handles:
    //   - Matrix scanning (detecting which keys are pressed)
    //   - Processing (determining tap vs hold, layers, combos)
    //   - USB HID output (sending keycodes to computer)
    //   - Raw HID communication (companion app telemetry)

    // Mandatory
    comptime var config = zigmkay.loops.GetUnibodyConfigType(&keymap.dimensions){
        .config = .{
            .keymap = &keymap.keymap,
            .scanner_settings = &.{
                .matrix = .{
                    .debounce = .{ .ms = 50 },
                    .pin_cols = molekula_pin_cols[0..],
                    .pin_rows = molekula_pin_rows[0..],
                    .pins_to_keys_mapping = &pin_mappings,
                    .direction = .col2row,
                },
            },

            .combos = keymap.combos[0..],
            .custom_functions = &keymap.custom_functions,
            .side_definition = &keymap.sides,
        },
    };

    comptime var runner = config.build();

    runner.run_unibody() catch {
        blink_led(10000000, 500); // in case of an error, let the keyboard start blinking
    };
}

// =============================================================================
// LED BLINK HELPER
// =============================================================================
// Simple utility to blink the status LED a specified number of times.
// Used for startup indication and error reporting.

/// Blink the status LED
///
/// Arguments:
///   blink_count: Number of times to blink
///   interval_ms: Milliseconds between on/off cycles
pub fn blink_led(blink_count: u32, interval_ms: u32) void {
    var counter = blink_count;
    while (counter > 0) : (counter -= 1) {
        p.led.put(1); // LED on
        time.sleep_us(interval_ms * 1000); // Wait
        p.led.put(0); // LED off
        time.sleep_us(interval_ms * 1000); // Wait
    }
}
