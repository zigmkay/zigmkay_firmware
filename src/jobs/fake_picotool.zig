// SPDX-License-Identifier: GPL-2.0
//! Offline picotool stand-in for the flash wrapper tests. Never opens a device.
//! The `--ser` value selects a behavior: `mode` or `mode|path`.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var serial: []const u8 = "ok";
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--ser")) serial = args[i + 1];
    }
    var parts = std.mem.splitScalar(u8, serial, '|');
    const mode = parts.next().?;
    if (std.mem.eql(u8, mode, "hang") or (std.mem.eql(u8, mode, "hang-load") and std.mem.eql(u8, args[1], "load"))) {
        if (parts.next()) |path| {
            const pid = try std.fmt.allocPrint(init.arena.allocator(), "{d}", .{std.posix.system.getpid()});
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = pid });
        }
        // Exercise the watchdog around wait after both output pipes close.
        std.Io.File.stdout().close(init.io);
        std.Io.File.stderr().close(init.io);
        try std.Io.sleep(init.io, .fromSeconds(30), .awake);
        return;
    }
    if (std.mem.eql(u8, args[1], "info")) {
        if (std.mem.eql(u8, mode, "mutate")) {
            const path = parts.next().?;
            const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1024));
            defer init.gpa.free(bytes);
            bytes[32] ^= 1;
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = bytes });
        }
        if (std.mem.eql(u8, mode, "absent")) std.process.exit(249);
        if (std.mem.eql(u8, mode, "ambiguous")) {
            try std.Io.File.stdout().writeStreamingAll(
                init.io,
                "Multiple RP-series devices in BOOTSEL mode found:\n",
            );
            return;
        }
        if (std.mem.eql(u8, mode, "failure")) std.process.exit(1);
    }
    if (std.mem.eql(u8, mode, "bad-load") and std.mem.eql(u8, args[1], "load")) std.process.exit(1);
    if (std.mem.eql(u8, mode, "bad-reboot") and std.mem.eql(u8, args[1], "reboot")) std.process.exit(1);
    for (args[1..]) |arg| {
        try std.Io.File.stdout().writeStreamingAll(init.io, arg);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}
