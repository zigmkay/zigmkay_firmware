pub const split_protocol = @import("split_protocol.zig");
pub const generic_queue = @import("generic_queue.zig");
pub const core = @import("core.zig");
pub const processing = @import("processing.zig");
pub const usb = @import("usb_command_executor.zig");

pub const matrix_scanning = @import("matrix_scanning.zig");
pub const encoder_scanning = @import("encoder_scanning.zig");

const std = @import("std");
const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const time = rp2xxx.time;

const pio_uart_tx_program = blk: {
    @setEvalBranchQuota(5000);
    break :blk rp2xxx.pio.assemble(
        \\.program uart_tx
        \\.side_set 1 opt
        \\    pull       side 1 [7]
        \\    set x, 7   side 0 [7]
        \\bitloop:
        \\    out pins, 1        [6]
        \\    jmp x-- bitloop
    , .{}).get_program_by_name("uart_tx");
};

pub const PioUartTx = struct {
    pio: rp2xxx.pio.Pio,
    sm: rp2xxx.pio.StateMachine,
};

pub fn init_pio_uart_tx(pin: rp2xxx.gpio.Pin, comptime baud_rate: u32) PioUartTx {
    const pio: rp2xxx.pio.Pio = .pio0;
    const sm: rp2xxx.pio.StateMachine = .sm0;

    pio.gpio_init(pin);
    pio.sm_set_pindir(sm, pin, 1, .out) catch unreachable;

    const div = @as(f32, @floatFromInt(rp2xxx.clock_config.sys.?.frequency())) /
        @as(f32, @floatFromInt(baud_rate * 8));

    pio.sm_load_and_start_program(sm, pio_uart_tx_program, .{
        .clkdiv = rp2xxx.pio.ClkDivOptions.from_float(div),
        .pin_mappings = .{
            .out = .single(pin),
            .side_set = .single(pin),
        },
        .shift = .{
            .out_shiftdir = .right,
            .autopull = false,
        },
    }) catch unreachable;

    pio.sm_set_enabled(sm, true);

    return .{ .pio = pio, .sm = sm };
}

pub const UartClient = union(enum) {
    uart: rp2xxx.uart.UART,
    pio_uart_tx: PioUartTx,

    pub fn send_blocking(self: *const UartClient, data: u8) !void {
        switch (self.*) {
            .uart => |uart| {
                const uart_send_buffer = [1]u8{data};
                _ = uart.write_blocking(&uart_send_buffer, microzig.drivers.time.Deadline{ .timeout = microzig.drivers.time.Absolute.from_us(100 * 1000) }) catch |e| {
                    uart.clear_errors();
                    return e;
                };
            },
            .pio_uart_tx => |p| {
                p.pio.sm_blocking_write(p.sm, @as(u32, data));
            },
        }
    }

    pub fn receive_byte_or_null(self: *const UartClient) ?u8 {
        switch (self.*) {
            .uart => |uart| {
                if (uart.read_word() catch {
                    uart.clear_errors();
                    return null;
                }) |byte| {
                    return byte;
                } else {
                    return null;
                }
            },
            .pio_uart_tx => return null,
        }
    }
};
