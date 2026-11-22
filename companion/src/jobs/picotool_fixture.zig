//! Offline wrapper stand-in: literal argv, bounded output and EOF handshake.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var mode: []const u8 = "ok";
    for (args, 0..) |arg, i| if (std.mem.eql(u8, arg, "--serial")) {
        mode = args[i + 1];
    };
    if (std.mem.eql(u8, mode, "wait")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "waiting\n");
        var buffer: [1]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
        _ = reader.interface.takeByte() catch {};
        try std.Io.File.stderr().writeStreamingAll(init.io, "controlled-exit\n");
        std.process.exit(1);
    }
    if (std.mem.eql(u8, mode, "flood")) {
        const data: [4096]u8 = @splat('x');
        for (0..40) |_| {
            try std.Io.File.stdout().writeStreamingAll(init.io, &data);
            try std.Io.File.stderr().writeStreamingAll(init.io, &data);
        }
        return;
    }
    for (args[1..]) |arg| {
        try std.Io.File.stdout().writeStreamingAll(init.io, arg);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}
