const std = @import("std");

const keymap = @import("keycaprio_colemak_keymap.zig");
const zigmkay = @import("zigmkay");
const microzig = @import("microzig");
comptime {
    microzig.export_startup();
}
pub const std_options = microzig.std_options(.{});
const rp2xxx = microzig.hal;
const time = rp2xxx.time;

// Pinout of the Leonardo Keycaprio 0.6 (see my_keyboards/rollercole/leonardo_keycaprio_0_6.zig).
// zig fmt: off
pub const pin_config = rp2xxx.pins.GlobalConfiguration{
    .GPIO17 = .{ .name = "led", .direction = .out },

    .GPIO2 = .{ .name = "colPinkyL", .direction = .out },
    .GPIO3 = .{ .name = "colRingL", .direction = .out },
    .GPIO4 = .{ .name = "colMidL", .direction = .out },
    .GPIO8 = .{ .name = "colIndexL", .direction = .out },
    .GPIO9 = .{ .name = "colInnerL", .direction = .out },
    .GPIO7 = .{ .name = "rowTopL", .direction = .in },
    .GPIO12= .{ .name = "rowHomeL", .direction = .in },
    .GPIO6 = .{ .name = "rowBottomL", .direction = .in },

    .GPIO29 = .{ .name = "colPinkyR", .direction = .out },
    .GPIO28 = .{ .name = "colRingR", .direction = .out },
    .GPIO27 = .{ .name = "colMidR", .direction = .out },
    .GPIO23 = .{ .name = "colIndexR", .direction = .out },
    .GPIO21 = .{ .name = "colInnerR", .direction = .out },

    .GPIO20 = .{ .name = "rowTopR", .direction = .in },
    .GPIO16= .{ .name = "rowHomeR", .direction = .in },
    .GPIO22 = .{ .name = "rowBottomR", .direction = .in },

    .GPIO5 = .{ .name = "thumbCol1L", .direction = .out },
    .GPIO13= .{ .name = "thumbCol2L", .direction = .out },
    .GPIO26 = .{ .name = "thumbCol1R", .direction = .out },
    .GPIO15 = .{ .name = "thumbCol2R", .direction = .out },
};
pub const p = blk: {
    @setEvalBranchQuota(10_000);
    break :blk pin_config.pins();
};
pub const pin_mappings = [keymap.key_count]?[2]usize{
  .{0,0}, .{1,0}, .{2,0}, .{3,0}, .{4,0},  .{11,3},.{10,3},.{9,3},.{8,3},.{7,3},
  .{0,1}, .{1,1}, .{2,1}, .{3,1}, .{4,1},    .{11,4},.{10,4},.{9,4},.{8,4},.{7,4},
  .{0,2}, .{1,2}, .{2,2}, .{3,2}, .{4,2},    .{11,5},.{10,5},.{9,5},.{8,5},.{7,5},
                          .{6, 2},.{5, 2},   .{12, 5},.{13, 5}
};
// zig fmt: on

pub const pin_cols = [_]rp2xxx.gpio.Pin{
    //0         1           2           3           4           5               6
    p.colPinkyL, p.colRingL, p.colMidL, p.colIndexL, p.colInnerL, p.thumbCol1L, p.thumbCol2L,
    //7         8           9           10           11          12             13
    p.colPinkyR, p.colRingR, p.colMidR, p.colIndexR, p.colInnerR, p.thumbCol1R, p.thumbCol2R,
};

pub const pin_rows = [_]rp2xxx.gpio.Pin{
    //0        1           2
    p.rowTopL, p.rowHomeL, p.rowBottomL,
    //3        4           5
    p.rowTopR, p.rowHomeR, p.rowBottomR,
};

pub fn main() !void {
    @setEvalBranchQuota(10_000);
    _ = pin_config.apply();
    blink_led(1, 300); // Show the user that the keyboard has actually booted up.

    comptime var config = zigmkay.loops.GetUnibodyConfigType(&keymap.dimensions){
        .config = .{
            .keymap = &keymap.keymap,
            .custom_functions = &keymap.custom_functions,
            .side_definition = &keymap.sides,
            .combos = keymap.combos[0..],
            .scanner_settings = &.{
                .matrix = .{
                    .debounce = .{ .ms = 50 },
                    .pins_to_keys_mapping = &pin_mappings,
                    .pin_cols = pin_cols[0..],
                    .pin_rows = pin_rows[0..],
                    .direction = .col2row,
                },
            },
        },
    };

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
