//! Offline peer fixture for host validation of malformed runner contracts.
const std = @import("std");
const wire = @import("runner-protocol");
const profile = @import("test-profile");

fn emit(gpa: std.mem.Allocator, io: std.Io, value: wire.Output) !void {
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(value, .{ .whitespace = false }, &encoded.writer, 32);
    try encoded.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, encoded.written());
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (std.mem.eql(u8, args[1], "hang-greeting")) {
        try std.Io.sleep(init.io, .fromSeconds(60), .awake);
        return;
    }
    var greeting = wire.Output{ .snapshot_id = profile.snapshot_id, .sequence = 0, .state = .ready };
    if (std.mem.eql(u8, args[1], "version")) greeting.version = 2;
    if (std.mem.eql(u8, args[1], "greeting")) greeting.sequence = 1;
    try emit(init.gpa, init.io, greeting);
    var buffer: [4097]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    _ = try reader.interface.takeDelimiter('\n') orelse return;
    if (std.mem.eql(u8, args[1], "hang-request")) {
        try std.Io.sleep(init.io, .fromSeconds(60), .awake);
        return;
    }
    var reply = wire.Output{ .snapshot_id = profile.snapshot_id, .sequence = 1, .state = .processed };
    if (std.mem.eql(u8, args[1], "sequence")) reply.sequence = 99;
    if (std.mem.eql(u8, args[1], "snapshot")) reply.snapshot_id[0] ^= 1;
    const commands: [257]@import("zigmkay").core.OutputCommand = @splat(.ActivateBootMode);
    if (std.mem.eql(u8, args[1], "events")) reply.commands = &commands;
    try emit(init.gpa, init.io, reply);
}
