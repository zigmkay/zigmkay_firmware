//! No platform/device dispatch. All firmware output is serialized as data.
const std = @import("std");
const firmware = @import("zigmkay");
const core = firmware.core;
const profile = @import("selected-profile");
const protocol = @import("runner-protocol");
const snapshot_id = profile.snapshot_id;

comptime {
    const expected = @import("snapshot-options").snapshot_id;
    if (@import("snapshot-options").verify_snapshot and !std.mem.eql(u8, &expected, &snapshot_id))
        @compileError("Export snapshot identity mismatch");
}

var trace: [protocol.max_events]core.ProcessorEvent = undefined;
var trace_count: usize = 0;
var trace_overflow = false;
var signals: [protocol.max_events]protocol.Signal = undefined;
var signal_count: usize = 0;

fn signal(value: protocol.Signal) void {
    if (signal_count < signals.len) {
        signals[signal_count] = value;
        signal_count += 1;
    } else trace_overflow = true;
}

fn event(e: core.ProcessorEvent, layers: *core.LayerActivations, queue: *core.OutputCommandQueue) void {
    if (trace_count < trace.len) {
        trace[trace_count] = e;
        trace_count += 1;
    } else trace_overflow = true;
    if (protocol.eventSignal(e)) |value| signal(value);
    if (profile.custom_functions.on_event) |handler| handler(e, layers, queue);
}

const callbacks = core.CustomFunctions{ .on_event = event };

const Processor = firmware.processing.CreateProcessorType(
    &profile.dimensions,
    &profile.keymap,
    &profile.sides,
    &profile.combos,
    &callbacks,
    &profile.encoder_actions,
    null,
);

fn emit(gpa: std.mem.Allocator, io: std.Io, output: protocol.Output) !void {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try std.zon.stringify.serializeMaxDepth(output, .{ .whitespace = false }, &text.writer, 32);
    if (text.written().len > protocol.max_response_bytes) return error.OutputTooLarge;
    try text.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, text.written());
}

fn fail(gpa: std.mem.Allocator, io: std.Io, sequence: u64, diagnostic: []const u8) !void {
    try emit(gpa, io, .{
        .sequence = sequence,
        .snapshot_id = snapshot_id,
        .state = .failed,
        .diagnostic = diagnostic,
    });
}

const Host = struct {
    last_time: u64 = 0,
    last_sequence: u64 = 0,
    pressed: [127]bool = @splat(false),

    /// Returns the diagnostic for an input that is out of order or does not
    /// match the keys and encoders of the selected profile.
    fn reject(self: *const Host, input: protocol.Input) ?[]const u8 {
        if (input.sequence <= self.last_sequence) return "InvalidSequence";
        if (input.time_us < self.last_time or input.time_us > std.math.maxInt(u64) - 65_535_000) return "InvalidTime";
        return switch (input.command) {
            .key_down => |key| if (key >= profile.key_count or self.pressed[key]) "InvalidKeyDown" else null,
            .key_up => |key| if (key >= profile.key_count or !self.pressed[key]) "InvalidKeyUp" else null,
            .encoder => |index| if (index >= profile.encoder_actions.len) "InvalidEncoder" else null,
            else => null,
        };
    }
};

fn activeLayerMask(processor: *Processor) u16 {
    var active: u16 = 1;
    for (1..profile.dimensions.layer_count) |index| {
        if (processor.layers_activations.is_layer_active(@intCast(index))) {
            active |= @as(u16, 1) << @as(u4, @intCast(index));
        }
    }
    return active;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var matrix = core.MatrixStateChangeQueue.Create();
    var encoder = core.EncoderEventQueue.Create();
    var queue = core.OutputCommandQueue.Create();
    var processor = Processor{
        .input_matrix_changes = &matrix,
        .encoder_event_changes = &encoder,
        .output_usb_commands = &queue,
    };
    try emit(gpa, io, .{ .sequence = 0, .snapshot_id = snapshot_id, .state = .ready });
    var buffer: [protocol.max_input_bytes + 1]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    var host: Host = .{};
    while (try reader.interface.takeDelimiter('\n')) |line| {
        const input = protocol.parse(gpa, line) catch |err| return fail(
            gpa,
            io,
            host.last_sequence,
            @errorName(err),
        );
        if (host.reject(input)) |diagnostic| return fail(gpa, io, input.sequence, diagnostic);
        host.last_sequence = input.sequence;
        host.last_time = input.time_us;
        if (input.command == .reset or input.command == .stop) {
            return emit(gpa, io, .{
                .sequence = input.sequence,
                .snapshot_id = snapshot_id,
                .state = if (input.command == .reset) .restart_required else .stopped,
            });
        }
        trace_count = 0;
        trace_overflow = false;
        signal_count = 0;
        const time = core.TimeSinceBoot.from_absolute_us(input.time_us);
        switch (input.command) {
            .key_down => |key| {
                host.pressed[key] = true;
                try matrix.enqueue(.{ .time = time, .key_index = key, .pressed = true });
            },
            .key_up => |key| {
                host.pressed[key] = false;
                try matrix.enqueue(.{ .time = time, .key_index = key, .pressed = false });
            },
            .encoder => |index| try encoder.enqueue(.{ .encoder_action_index = index }),
            else => {},
        }
        processor.Process(time) catch |err| return fail(gpa, io, input.sequence, @errorName(err));
        if (trace_overflow) return fail(gpa, io, input.sequence, "EventOverflow");
        var commands: [256]core.OutputCommand = undefined;
        var count: usize = 0;
        while (queue.dequeue()) |command| {
            // Companion keycodes are intents for the host, not typing output.
            if (protocol.commandSignal(command)) |value| {
                signal(value);
                continue;
            }
            if (count >= commands.len) return error.CommandOverflow;
            commands[count] = command;
            count += 1;
        }
        if (trace_overflow) return fail(gpa, io, input.sequence, "EventOverflow");
        try emit(gpa, io, .{
            .sequence = input.sequence,
            .snapshot_id = snapshot_id,
            .state = .processed,
            .commands = commands[0..count],
            .events = trace[0..trace_count],
            .signals = signals[0..signal_count],
            .active_layers = activeLayerMask(&processor),
            .highest_layer = processor.layers_activations.get_top_most_active_layer(),
            .modifiers = queue.current_mods.toByte(),
        });
    }
}
