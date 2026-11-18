//! Explicit Windows flash child; stdin EOF cancels the entire native I/O process.
const std = @import("std");
const policy = @import("bootsel-policy");
const native = @import("bootsel-native");

fn cancellation(io: std.Io) void {
    var byte: [1]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &byte);
    _ = reader.interface.takeByte() catch {};
    if (reader.err) |err| {
        if (err == error.Canceled) return;
    }
    native.ExitProcess(2);
}

fn watchdog(io: std.Io, budget: u32) void {
    std.Io.sleep(io, .fromMilliseconds(budget), .awake) catch return;
    std.Io.File.stderr().writeStreamingAll(
        io,
        "BOOTSEL native I/O deadline exceeded; transfer was not retried\n",
    ) catch {};
    native.ExitProcess(3);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 9 or
        !std.mem.eql(u8, args[2], "--sha256") or
        !std.mem.eql(u8, args[4], "--discovery-ms") or
        !std.mem.eql(u8, args[6], "--command-ms") or
        !std.mem.eql(u8, args[8], "--cancel-stdin")) return error.InvalidTransferArguments;
    if (!std.fs.path.isAbsolute(args[1])) return error.AbsolutePathRequired;
    const discovery = try std.fmt.parseInt(u32, args[5], 10);
    const command = try std.fmt.parseInt(u32, args[7], 10);
    if (discovery == 0 or discovery > 3_600_000 or command == 0 or command > 3_600_000) return error.InvalidBudget;
    var hash: [32]u8 = undefined;
    if ((try std.fmt.hexToBytes(&hash, args[3])).len != hash.len) return error.InvalidHash;
    var cancel = try std.Io.concurrent(init.io, cancellation, .{init.io});
    defer cancel.cancel(init.io);
    // This watchdog also bounds synchronous Windows APIs if a device stops responding.
    var guard = try std.Io.concurrent(init.io, watchdog, .{ init.io, discovery + command });
    defer guard.cancel(init.io);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(16 * 1024 * 1024));
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &actual, &hash)) return error.HashMismatch;
    const deadline = std.Io.Clock.awake.now(init.io).toMilliseconds() + discovery;
    while (std.Io.Clock.awake.now(init.io).toMilliseconds() < deadline) {
        if (try native.discover()) |volume| {
            var diagnostics: [256]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(init.io, &diagnostics);
            try stderr.interface.writeAll("phase: load-verify\nBOOTSEL copy; flash read-back unavailable\n");
            try stderr.interface.flush();
            var ops: native.Ops = .{
                .io = init.io,
                .deadline = std.Io.Clock.awake.now(init.io).toMilliseconds() + command,
            };
            policy.transfer(a, &ops, volume, bytes, hash) catch |err| {
                if (err == error.TransferTimeout) {
                    std.debug.print("BOOTSEL transfer deadline exceeded; transfer was not retried\n", .{});
                    native.ExitProcess(3);
                }
                return err;
            };
            try stderr.interface.writeAll("Transfer complete; live firmware identity still required\n");
            try stderr.interface.flush();
            return;
        }
        try std.Io.sleep(init.io, .fromMilliseconds(100), .awake);
    }
    std.debug.print("BOOTSEL discovery timed out; connect exactly one RP2040 in BOOTSEL mode\n", .{});
    native.ExitProcess(3);
}
