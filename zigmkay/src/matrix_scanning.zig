const std = @import("std");
const core = @import("core.zig");
const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const time = rp2xxx.time;

pub fn CreateScannerConfig(comptime keymap_dimensions: *const core.KeymapDimensions) type {
    return union(enum) {
        direct_wiring: struct {
            debounce: core.TimeSpan = .{ .ms = 50 },
            switch_pins: *const [keymap_dimensions.key_count]?rp2xxx.gpio.Pin,
        },
        matrix: struct {
            debounce: core.TimeSpan = .{ .ms = 50 },
            pin_cols: []const rp2xxx.gpio.Pin,
            pin_rows: []const rp2xxx.gpio.Pin,
            pin_raise_wait_us: u64 = 30,
            pins_to_keys_mapping: *const [keymap_dimensions.key_count]?[2]usize,
            direction: enum { col2row, row2col },
        },
    };
}

const PinAndIndex = struct {
    col_index: usize,
    row_index: usize,
    key_index: core.KeyIndex,
};

pub fn CreateMatrixScannerType(
    comptime keymap_dimensions: *const core.KeymapDimensions,
    comptime settings: *const CreateScannerConfig(keymap_dimensions),
) type {
    switch (settings.*) {
        .matrix => |matrix_settings| {
            comptime var row_col_to_keyindex: [matrix_settings.pin_cols.len][matrix_settings.pin_rows.len]?core.KeyIndex = @splat(@splat(null));
            comptime for (matrix_settings.pins_to_keys_mapping, 0..) |pins_coordinates_or_null, key_index| {
                if (pins_coordinates_or_null) |pin_coordinates| {
                    const col_idx = pin_coordinates[0];
                    const row_idx = pin_coordinates[1];

                    if (col_idx >= matrix_settings.pin_cols.len) {
                        @compileError(std.fmt.comptimePrint("A col index {d} exceeds the total number of pin_cols provided ({d}).", .{ col_idx, matrix_settings.pin_cols.len }));
                    }
                    if (row_idx >= matrix_settings.pin_rows.len) {
                        @compileError(std.fmt.comptimePrint("A row index {d} exceeds the total number of pin_rows provided ({d}).", .{ row_idx, matrix_settings.pin_rows.len }));
                    }

                    row_col_to_keyindex[col_idx][row_idx] = @intCast(key_index);
                }
            };
            const mapping = row_col_to_keyindex;
            return struct {
                // current_states should be a packed struct
                var current_states: [matrix_settings.pins_to_keys_mapping.len]bool = @splat(false);
                var current_states_last_changed: [matrix_settings.pins_to_keys_mapping.len]u64 = @splat(0);

                // map col+row coordinates to keymap positions

                const Self = @This();
                pub fn DetectKeyboardChanges(_: *const Self, output_queue: *core.MatrixStateChangeQueue, current_time: core.TimeSinceBoot) !void {
                    if (matrix_settings.direction == .col2row) {
                        for (matrix_settings.pin_cols, 0..) |col, col_idx| {
                            col.put(1);
                            time.sleep_us(matrix_settings.pin_raise_wait_us);

                            for (matrix_settings.pin_rows, 0..) |row, row_idx| {
                                // find the key index for this combination
                                const key_index_or_null = mapping[col_idx][row_idx];
                                if (key_index_or_null) |key_index| {
                                    const pressed = row.read() == 1;

                                    if (pressed != current_states[key_index]) {
                                        const last_changed_time = current_states_last_changed[key_index];
                                        if (current_time.time_since_boot_us - last_changed_time > matrix_settings.debounce.ms * 1000) {
                                            current_states[key_index] = pressed;
                                            current_states_last_changed[key_index] = current_time.time_since_boot_us;

                                            const key_index_with_type: core.KeyIndex = @intCast(key_index);
                                            try output_queue.enqueue(.{ .pressed = pressed, .key_index = key_index_with_type, .time = current_time });
                                        }
                                    }
                                }
                            }

                            col.put(0);
                        }
                    } else {
                        for (matrix_settings.pin_rows, 0..) |row, row_idx| {
                            row.put(1);
                            time.sleep_us(matrix_settings.pin_raise_wait_us);

                            for (matrix_settings.pin_cols, 0..) |col, col_idx| {
                                // find the key index for this combination
                                const key_index_or_null = mapping[col_idx][row_idx];
                                if (key_index_or_null) |key_index| {
                                    const pressed = col.read() == 1;

                                    if (pressed != current_states[key_index]) {
                                        const last_changed_time = current_states_last_changed[key_index];
                                        if (current_time.time_since_boot_us - last_changed_time > matrix_settings.debounce.ms * 1000) {
                                            current_states[key_index] = pressed;
                                            current_states_last_changed[key_index] = current_time.time_since_boot_us;

                                            const key_index_with_type: core.KeyIndex = @intCast(key_index);
                                            try output_queue.enqueue(.{ .pressed = pressed, .key_index = key_index_with_type, .time = current_time });
                                        }
                                    }
                                }
                            }

                            row.put(0);
                        }
                    }
                }
            };
        },
        .direct_wiring => |pins| {
            return struct {
                const Self = @This();
                // current_states should be a packed struct
                current_states: [keymap_dimensions.key_count]bool = @splat(false),
                current_states_last_changed: [keymap_dimensions.key_count]u64 = @splat(0),
                pub fn DetectKeyboardChanges(self: *Self, output_queue: *core.MatrixStateChangeQueue, current_time: core.TimeSinceBoot) !void {
                    for (pins.switch_pins, 0..) |pin_or_null, key_index| {
                        if (pin_or_null) |pin| {
                            const pressed = pin.read() == 0;
                            if (self.current_states[key_index] != pressed) {
                                const last_changed_time = self.current_states_last_changed[key_index];
                                if (current_time.time_since_boot_us - last_changed_time > pins.debounce.ms * 1000) {
                                    self.current_states[key_index] = pressed;
                                    self.current_states_last_changed[key_index] = current_time.time_since_boot_us;
                                    const key_index_typed: core.KeyIndex = @intCast(key_index);
                                    try output_queue.enqueue(.{ .pressed = pressed, .key_index = key_index_typed, .time = current_time });
                                }
                            }
                        }
                    }
                }
            };
        },
    }
}
