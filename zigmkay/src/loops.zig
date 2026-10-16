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
const UartClient = @import("split_communication.zig").UartClient;

fn CreatePrimaryConfig(comptime dimensions: *const core.KeymapDimensions) type {
    return struct {
        dimensions: *const core.KeymapDimensions = dimensions,

        // Mandatory
        keymap: *const [dimensions.layer_count][dimensions.key_count]?core.KeyDef,

        // Extras (both sides)
        scanner_settings: *const matrix_scanning.CreateScannerConfig(dimensions),

        // Extras (primary side only)
        combos: []const core.Combo2Def = &.{},
        custom_functions: *const core.CustomFunctions = &core.CustomFunctions{
            .on_event = null,
        },
        side_definition: *const [dimensions.key_count]core.Side = &@as([dimensions.key_count]core.Side, @splat(.X)),

        encoder_pin_configs: []encoder_scanning.EncoderPinConfig = &.{},
        encoder_actions: []core.EncoderAction = &.{},
        matrix_event_trace: ?core.MatrixEventTrace = null,
    };
}

pub fn GetPrimarySideConfigType(comptime dimensions: *const core.KeymapDimensions) type {
    const ConfigType = CreatePrimaryConfig(dimensions);
    return struct {
        const Self = @This();
        config: ConfigType,

        pub fn build(comptime self: Self) Runner {
            return Runner{ .config = self.config };
        }

        pub const Runner = struct {
            config: ConfigType,
            pub fn run_primary(comptime self: Runner, uart: *UartClient) !void {
                try run_primary_internal(dimensions, self.config, uart);
            }
        };
    };
}

pub fn GetUnibodyConfigType(comptime dimensions: *const core.KeymapDimensions) type {
    const ConfigType = CreatePrimaryConfig(dimensions);
    return struct {
        const Self = @This();
        config: ConfigType,

        pub fn build(comptime self: Self) Runner {
            return Runner{ .config = self.config };
        }

        pub const Runner = struct {
            config: ConfigType,
            pub fn run_unibody(comptime self: Runner) !void {
                try run_primary_internal(dimensions, self.config, null);
            }
        };
    };
}

fn run_primary_internal(
    comptime dimensions: *const core.KeymapDimensions,
    comptime config: CreatePrimaryConfig(dimensions),
    uart_or_null: ?*UartClient,
) !void {
    // Data queues
    var matrix_change_queue = core.MatrixStateChangeQueue.Create();
    var encoder_change_queue = core.EncoderEventQueue.Create();
    var usb_command_queue = core.OutputCommandQueue.Create();

    // Input scanning
    var matrix_scanner = comptime matrix_scanning.CreateMatrixScannerType(dimensions, config.scanner_settings){};
    var encoder_scanner = comptime encoder_scanning.CreateEncoderScannerType(config.encoder_pin_configs){};

    // Processing
    var processor = processing.CreateProcessorType(dimensions, config.keymap, config.side_definition, config.combos, config.custom_functions, config.encoder_actions, config.matrix_event_trace){
        .input_matrix_changes = &matrix_change_queue,
        .output_usb_commands = &usb_command_queue,
        .encoder_event_changes = &encoder_change_queue,
    };

    // uart byte queue
    var uart_receiver = split_protocol.UartReceiveHelper{};

    // USB events
    const usb_command_executor = usb.CreateAndInitUsbCommandExecutor();
    while (true) {
        // Detect local changes
        const current_time = core.TimeSinceBoot{ .time_since_boot_us = time.get_time_since_boot().to_us() };
        try matrix_scanner.DetectKeyboardChanges(&matrix_change_queue, current_time); // Scan local matrix changes
        try encoder_scanner.detectEncoderChanges(&encoder_change_queue, current_time);

        // Receive from remote side
        if (uart_or_null) |uart| {
            try receive_from_uart_to_queue(uart, &uart_receiver, &matrix_change_queue, &encoder_change_queue, current_time);
        }

        // Processing: decide actions
        try processor.Process(current_time);

        // Execute actions: send usb commands to the host
        try usb_command_executor.HouseKeepAndProcessCommands(&usb_command_queue, current_time);
    }
}

fn CreateSecondaryConfig(comptime dimensions: *const core.KeymapDimensions) type {
    return struct {
        dimensions: *const core.KeymapDimensions = dimensions,

        //
        scanner_settings: *const matrix_scanning.CreateScannerConfig(dimensions),
        encoder_pin_configs: []encoder_scanning.EncoderPinConfig = &.{},
    };
}

pub fn GetSecondarySideConfigType(comptime dimensions: *const core.KeymapDimensions) type {
    const ConfigType = CreateSecondaryConfig(dimensions);
    return struct {
        const Self = @This();
        config: ConfigType,

        pub fn build(comptime self: Self) Runner {
            return Runner{ .config = self.config };
        }

        pub const Runner = struct {
            config: ConfigType,

            pub fn run_secondary(comptime self: Runner, uart: *UartClient) !void {
                try run_secondary_internal(dimensions, self.config, uart);
            }
        };
    };
}

fn run_secondary_internal(
    comptime dimensions: *const core.KeymapDimensions,
    comptime config: CreateSecondaryConfig(dimensions),
    uart: *UartClient,
) !void {
    var matrix_change_queue = core.MatrixStateChangeQueue.Create();
    var encoder_change_queue = core.EncoderEventQueue.Create();

    var matrix_scanner = comptime matrix_scanning.CreateMatrixScannerType(dimensions, config.scanner_settings){};
    var encoder_scanner = comptime encoder_scanning.CreateEncoderScannerType(config.encoder_pin_configs){};

    var uart_sender = split_protocol.UartSendHelper{};
    while (true) {
        const current_time = core.TimeSinceBoot{ .time_since_boot_us = time.get_time_since_boot().to_us() };

        // Detect local changes
        try matrix_scanner.DetectKeyboardChanges(&matrix_change_queue, current_time);
        try encoder_scanner.detectEncoderChanges(&encoder_change_queue, current_time);

        // Send to primary side
        try send_from_queue_to_uart(uart, &uart_sender, &matrix_change_queue, &encoder_change_queue);
    }
}

fn receive_from_uart_to_queue(uart: *const UartClient, receiver: *split_protocol.UartReceiveHelper, matrix_change_queue: *core.MatrixStateChangeQueue, encoder_change_queue: *core.EncoderEventQueue, current_time: core.TimeSinceBoot) !void {
    while (uart.receive_byte_or_null()) |byte| {
        if (receiver.receiveByte(byte)) |msg| {
            switch (msg) {
                .MatrixStateChange => |e| {
                    try matrix_change_queue.enqueue(.{ .key_index = e.key_index, .pressed = e.pressed, .time = current_time });
                },
                .EncoderActionIndexTriggered => |e| {
                    try encoder_change_queue.enqueue(.{ .encoder_action_index = e });
                },
            }
        }
    }
}

fn send_from_queue_to_uart(uart: *const UartClient, uart_sender: *split_protocol.UartSendHelper, matrix_change_queue: *core.MatrixStateChangeQueue, encoder_event_queue: *core.EncoderEventQueue) !void {
    while (matrix_change_queue.dequeue()) |matrix_change| {
        try uart_sender.sendMessage(.{ .MatrixStateChange = .{ .key_index = matrix_change.key_index, .pressed = matrix_change.pressed } });
    }
    while (encoder_event_queue.dequeue()) |encoder_event| {
        try uart_sender.sendMessage(.{ .EncoderActionIndexTriggered = encoder_event.encoder_action_index });
    }

    while (uart_sender.byte_queue.dequeue()) |msg| {
        uart.send_blocking(msg) catch {};
    }
}
