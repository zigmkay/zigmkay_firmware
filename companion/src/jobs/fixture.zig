//! Child process for the job tests. The first argument selects a behavior;
//! `build` imitates the managed firmware build when ZIGMKAY_BUILD_FIXTURE is set.
const std = @import("std");

const Command = enum {
    build,
    environment,
    version,
    @"output-hang",
    hang,
    crash,
    @"closed-hang",
    echo,
    flood,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const stdout = std.Io.File.stdout();
    const command = std.meta.stringToEnum(Command, args[1]) orelse {
        try stdout.writeStreamingAll(init.io, args[1]);
        return;
    };
    switch (command) {
        .build => {
            const mode = init.environ_map.get("ZIGMKAY_BUILD_FIXTURE") orelse {
                try stdout.writeStreamingAll(init.io, args[1]);
                return;
            };
            try fakeBuild(init, args, mode);
        },
        .environment => try stdout.writeStreamingAll(
            init.io,
            init.environ_map.get("ZIGMKAY_JOB_FIXTURE") orelse "absent",
        ),
        .version => try stdout.writeStreamingAll(init.io, "0.17.0\n"),
        .@"output-hang" => {
            try stdout.writeStreamingAll(init.io, "stdout before timeout\n");
            try std.Io.File.stderr().writeStreamingAll(init.io, "stderr before timeout\n");
            try std.Io.sleep(init.io, .fromSeconds(10), .awake);
        },
        .hang => try std.Io.sleep(init.io, .fromSeconds(10), .awake),
        .crash => std.process.exit(7),
        .@"closed-hang" => {
            stdout.close(init.io);
            std.Io.File.stderr().close(init.io);
            try std.Io.sleep(init.io, .fromSeconds(10), .awake);
        },
        .echo => {
            var buffer: [4097]u8 = undefined;
            var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
            while (try reader.interface.takeDelimiter('\n')) |line| {
                try stdout.writeStreamingAll(init.io, line);
                try stdout.writeStreamingAll(init.io, "\n");
            }
        },
        .flood => {
            const block: [4096]u8 = @splat('x');
            for (0..300) |_| try stdout.writeStreamingAll(init.io, &block);
        },
    }
}

/// The value following `-p`, the build's install prefix.
fn installPrefix(args: []const [:0]const u8) ?[]const u8 {
    for (args[0 .. args.len - 1], 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "-p")) return args[index + 1];
    }
    return null;
}

fn fakeBuild(init: std.process.Init, args: []const [:0]const u8, mode: []const u8) !void {
    const a = init.arena.allocator();
    if (std.mem.eql(u8, mode, "spawn-hang") or std.mem.eql(u8, mode, "hang")) {
        var descendant: ?std.process.Child = null;
        defer if (descendant) |*child| child.kill(init.io);
        if (std.mem.eql(u8, mode, "spawn-hang")) {
            const own_path = try std.process.executablePathAlloc(init.io, a);
            descendant = try std.process.spawn(init.io, .{
                .argv = &.{ own_path, "hang" },
                .stdin = .ignore,
            });
        }
        for (args[0 .. args.len - 1], 0..) |arg, index| if (std.mem.eql(u8, arg, "-p")) {
            var output = try std.Io.Dir.cwd().openDir(init.io, args[index + 1], .{});
            defer output.close(init.io);
            try output.writeFile(init.io, .{
                .sub_path = "cancel-ready",
                .data = "running fixture producer",
            });
        };
        try std.Io.sleep(init.io, .fromSeconds(10), .awake);
        return;
    }
    if (std.mem.eql(u8, mode, "failed")) std.process.exit(7);
    if (std.mem.eql(u8, mode, "missing")) return;
    const install = installPrefix(args) orelse return error.MissingFixtureInstall;
    const path = try std.fs.path.join(a, &.{ install, "firmware" });
    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, path, .{});
    defer dir.close(init.io);
    var bytes = uf2Block();
    if (std.mem.eql(u8, mode, "invalid")) bytes[0] = 0;
    try dir.writeFile(init.io, .{ .sub_path = "project.uf2", .data = &bytes });
    if (std.mem.eql(u8, mode, "missing-runner")) return;
    try installRunner(init, install);
}

/// One valid, empty UF2 block for an RP2040 flash address.
fn uf2Block() [512]u8 {
    var bytes: [512]u8 = @splat(0);
    for ([_]struct { usize, u32 }{
        .{ 0, 0x0a324655 },
        .{ 4, 0x9e5d5157 },
        .{ 8, 0x2000 },
        .{ 12, 0x10000000 },
        .{ 16, 256 },
        .{ 24, 1 },
        .{ 28, 0xe48bff56 },
        .{ 508, 0x0ab16f30 },
    }) |entry| std.mem.writeInt(u32, bytes[entry[0]..][0..4], entry[1], .little);
    return bytes;
}

/// Installs a copy of this executable as the build's native runner.
fn installRunner(init: std.process.Init, install: []const u8) !void {
    const a = init.arena.allocator();
    const bin_path = try std.fs.path.join(a, &.{ install, "bin" });
    var bin = try std.Io.Dir.cwd().createDirPathOpen(init.io, bin_path, .{});
    defer bin.close(init.io);
    const own_path = try std.process.executablePathAlloc(init.io, a);
    const own_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, own_path, a, .limited(64 * 1024 * 1024));
    const runner_name = "project-runner" ++ if (@import("builtin").os.tag == .windows) ".exe" else "";
    var runner = try bin.createFileAtomic(init.io, runner_name, .{});
    defer runner.deinit(init.io);
    try runner.file.writeStreamingAll(init.io, own_bytes);
    try runner.file.setPermissions(init.io, .executable_file);
    try runner.link(init.io);
}
