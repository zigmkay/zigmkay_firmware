// SPDX-License-Identifier: GPL-2.0
//! Offline wrapper checks against the fake picotool. No USB access.
const std = @import("std");
const flash = @import("picotool_flash.zig");
const options = @import("options");
const t = std.testing;
const io = t.io;

test "CLI validates bounded waits, digests and complete selection options" {
    _ = try flash.parse(&.{ "tool", "file" });
    try t.expectError(error.InvalidArguments, flash.parse(&.{ "tool", "file", "--bus", "1" }));
    try t.expectError(error.InvalidArguments, flash.parse(&.{ "tool", "file", "--command-ms", "0" }));
    try t.expectError(error.InvalidArguments, flash.parse(&.{ "tool", "file", "--discovery-ms", "3600001" }));
    try t.expectError(
        error.InvalidArguments,
        flash.parse(&.{ "tool", "file", "--serial", "a", "--serial", "b" }),
    );
    try t.expectError(error.InvalidArguments, flash.parse(&.{ "tool", "file", "--sha256", "abc" }));
    try t.expectError(
        error.InvalidArguments,
        flash.parse(&.{ "tool", "file", "--address", "128", "--bus", "1" }),
    );
    try t.expectError(error.InvalidArguments, flash.parse(&.{
        "tool",
        "file",
        "--bus",
        "1",
        "--address",
        "7",
        "--serial",
        "s",
    }));
    const config = try flash.parse(&.{ "tool", "file", "--bus", "0", "--address", "127", "--cancel-stdin" });
    try t.expect(config.cancel_stdin);
}

fn uf2() [512]u8 {
    var block: [512]u8 = @splat(0);
    const offsets = [_]usize{ 0, 4, 8, 12, 16, 20, 24, 28, 508 };
    const values = [_]u32{ 0x0a324655, 0x9e5d5157, 0x2000, 0x10000000, 256, 0, 1, 0xe48bff56, 0x0ab16f30 };
    for (offsets, values) |offset, value| std.mem.writeInt(u32, block[offset..][0..4], value, .little);
    return block;
}

fn path(tmp: std.testing.TmpDir, basename: []const u8) ![]u8 {
    const root = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(root);
    return std.fs.path.join(t.allocator, &.{ root, basename });
}

test "UF2 blocks require magic, complete inventory and RP2040 flash payload" {
    const valid = uf2();
    try flash.validateUf2(&valid);
    for ([_]usize{ 0, 4, 8, 16, 20, 24, 28, 508 }) |offset| {
        var invalid = valid;
        invalid[offset] ^= 1;
        try t.expectError(error.InvalidUf2, flash.validateUf2(&invalid));
    }
    try t.expectError(error.InvalidUf2, flash.validateUf2(""));
    try t.expectError(error.InvalidUf2, flash.validateUf2(valid[0..511]));
}

test "literal selection argv for every phase" {
    const config: flash.Config = .{
        .picotool = options.picotool_fixture,
        .firmware = "a file.uf2",
        .bus = "1",
        .address = "7",
    };
    const commands = [_][]const []const u8{
        &.{"info"},
        &.{ "load", "--verify", config.firmware },
        &.{ "reboot", "--application" },
    };
    const expected = [_][]const u8{
        "info\n--bus\n1\n--address\n7\n",
        "load\n--verify\na file.uf2\n--bus\n1\n--address\n7\n",
        "reboot\n--application\n--bus\n1\n--address\n7\n",
    };
    for (commands, expected) |command, bytes| {
        const result = try flash.tool(t.allocator, io, config, command, 2000);
        defer t.allocator.free(result.stdout);
        defer t.allocator.free(result.stderr);
        try t.expect(result.term.success());
        try t.expectEqualStrings(bytes, result.stdout);
    }
}

test "offline flash success, hash rejection, ambiguity, discovery and phase failures" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const file = try path(tmp, "firmware.uf2");
    defer t.allocator.free(file);
    const block = uf2();
    try tmp.dir.writeFile(io, .{ .sub_path = "firmware.uf2", .data = &block });
    var config: flash.Config = .{
        .picotool = options.picotool_fixture,
        .firmware = file,
        .discovery_ms = 100,
        .command_ms = 2000,
    };
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&block, &hash, .{});
    config.expected_sha256 = hash;
    try flash.execute(t.allocator, io, config);
    config.expected_sha256 = @splat(0);
    config.picotool = "/nonexistent-picotool-must-not-spawn";
    try t.expectError(error.HashMismatch, flash.execute(t.allocator, io, config));
    config.picotool = options.picotool_fixture;
    config.expected_sha256 = null;
    config.serial = "ambiguous";
    try t.expectError(error.AmbiguousDevice, flash.execute(t.allocator, io, config));
    config.serial = "absent";
    try t.expectError(error.DiscoveryTimeout, flash.execute(t.allocator, io, config));
    config.serial = "failure";
    try t.expectError(error.DiscoveryFailed, flash.execute(t.allocator, io, config));
    config.serial = "bad-load";
    try t.expectError(error.LoadVerifyFailed, flash.execute(t.allocator, io, config));
    config.serial = "bad-reboot";
    try t.expectError(error.RebootFailed, flash.execute(t.allocator, io, config));
    const mutate = try std.fmt.allocPrint(t.allocator, "mutate|{s}", .{file});
    defer t.allocator.free(mutate);
    config.serial = mutate;
    try t.expectError(error.ArtifactChanged, flash.execute(t.allocator, io, config));
}

fn waitPid(file: []const u8) !std.posix.pid_t {
    for (0..200) |_| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, t.allocator, .limited(32)) catch |err| {
            if (err != error.FileNotFound) return err;
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
            continue;
        };
        defer t.allocator.free(bytes);
        if (bytes.len != 0) return std.fmt.parseInt(std.posix.pid_t, bytes, 10);
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.FixtureDidNotStart;
}

fn expectReaped(pid: std.posix.pid_t) !void {
    try t.expectError(error.ProcessNotFound, std.posix.kill(pid, @fromBackingInt(@intCast(0))));
}

test "timeout kills and reaps a child which closed output pipes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const pidfile = try path(tmp, "child.pid");
    defer t.allocator.free(pidfile);
    const serial = try std.fmt.allocPrint(t.allocator, "hang|{s}", .{pidfile});
    defer t.allocator.free(serial);
    const config: flash.Config = .{
        .picotool = options.picotool_fixture,
        .firmware = "unused",
        .serial = serial,
    };
    try t.expectError(error.CommandTimeout, flash.tool(t.allocator, io, config, &.{"info"}, 500));
    try expectReaped(try waitPid(pidfile));
}

test "stdin cancellation during discovery and load reaps picotool before wrapper exits" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    for ([_][]const u8{ "hang", "hang-load", "hang" }, 0..) |mode, i| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const pidfile = try path(tmp, "child.pid");
        defer t.allocator.free(pidfile);
        const firmware = try path(tmp, "firmware.uf2");
        defer t.allocator.free(firmware);
        const block = uf2();
        try tmp.dir.writeFile(io, .{ .sub_path = "firmware.uf2", .data = &block });
        const serial = try std.fmt.allocPrint(t.allocator, "{s}|{s}", .{ mode, pidfile });
        defer t.allocator.free(serial);
        var wrapper = try std.process.spawn(io, .{
            .argv = &.{
                options.wrapper,
                options.picotool_fixture,
                firmware,
                "--serial",
                serial,
                "--cancel-stdin",
            },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        defer wrapper.kill(io);
        const pid = try waitPid(pidfile);
        if (i == 2) {
            wrapper.stdin.?.close(io);
            wrapper.stdin = null;
        } else try wrapper.stdin.?.writeStreamingAll(io, "cancel\n");
        const term = try wrapper.wait(io);
        try t.expect(!term.success());
        try expectReaped(pid);
    }
}
