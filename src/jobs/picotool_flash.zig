// SPDX-License-Identifier: GPL-2.0
//! Bounded picotool flash wrapper. Standalone executable root; depends only on std.
//!
//! usage: picotool_flash <picotool> <firmware.uf2> [options]
//!   --sha256 HEX           expected SHA-256; a mismatch stops before picotool runs
//!   --discovery-ms N       BOOTSEL discovery budget (default 30000)
//!   --command-ms N         per-command budget including child wait (default 60000)
//!   --bus N --address N    complete USB target filter (bus 0-255, address 1-127)
//!   --serial S             alternative target filter, forwarded as picotool --ser
//!   --cancel-stdin         any stdin byte or EOF requests cancellation
//!
//! Budgets are 1-3600000 milliseconds. Unknown or duplicate flags, an incomplete
//! bus/address pair and serial combined with bus/address are rejected. Arguments
//! are passed to picotool literally, without a shell. Discovery retries only the
//! pinned picotool 2.3.1 no-device exit status 249 and rejects its literal
//! multiple-device diagnostic. No write is retried: a timeout or cancellation
//! during load or reboot leaves the device state uncertain and requires an
//! explicit recovery decision. Reboot completion does not verify the running
//! firmware; the companion reconnects and checks its identity separately.
const std = @import("std");

pub const Config = struct {
    picotool: []const u8,
    firmware: []const u8,
    expected_sha256: ?[32]u8 = null,
    discovery_ms: u32 = 30_000,
    command_ms: u32 = 60_000,
    bus: ?[]const u8 = null,
    address: ?[]const u8 = null,
    serial: ?[]const u8 = null,
    cancel_stdin: bool = false,
};

const usage = "usage: picotool_flash <picotool> <firmware.uf2> [--sha256 HEX] [--discovery-ms N] [--command-ms N] [--bus N --address N | --serial S] [--cancel-stdin]";
const multiple_devices = "Multiple RP-series devices in BOOTSEL mode found:";
/// Pinned picotool ERROR_NO_DEVICE (-7) as a process exit status.
pub const no_device_status = 249;

pub fn parse(args: []const []const u8) !Config {
    if (args.len < 2) return error.InvalidArguments;
    var config: Config = .{ .picotool = args[0], .firmware = args[1] };
    var index: usize = 2;
    var seen: u8 = 0;
    while (index < args.len) {
        const flag = args[index];
        const names = [_][]const u8{
            "--sha256",
            "--discovery-ms",
            "--command-ms",
            "--bus",
            "--address",
            "--serial",
            "--cancel-stdin",
        };
        const tag = for (names, 0..) |name, tag| {
            if (std.mem.eql(u8, name, flag)) break tag;
        } else return error.InvalidArguments;
        const bit = @as(u8, 1) << @intCast(tag);
        if (seen & bit != 0) return error.InvalidArguments;
        seen |= bit;
        index += 1;
        if (tag == 6) {
            config.cancel_stdin = true;
            continue;
        }
        if (index == args.len) return error.InvalidArguments;
        const value = args[index];
        index += 1;
        switch (tag) {
            0 => {
                var hash: [32]u8 = undefined;
                if (value.len != 64) return error.InvalidArguments;
                _ = std.fmt.hexToBytes(&hash, value) catch return error.InvalidArguments;
                config.expected_sha256 = hash;
            },
            1, 2 => {
                const ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments;
                if (ms == 0 or ms > 3_600_000) return error.InvalidArguments;
                if (tag == 1) config.discovery_ms = ms else config.command_ms = ms;
            },
            3, 4 => {
                const number = std.fmt.parseInt(u8, value, 10) catch return error.InvalidArguments;
                if (tag == 4 and (number == 0 or number > 127)) return error.InvalidArguments;
                if (tag == 3) config.bus = value else config.address = value;
            },
            5 => {
                if (value.len == 0) return error.InvalidArguments;
                config.serial = value;
            },
            else => unreachable,
        }
    }
    if ((config.bus == null) != (config.address == null)) return error.InvalidArguments;
    if (config.serial != null and config.bus != null) return error.InvalidArguments;
    return config;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = parse(args[1..]) catch std.process.fatal("{s}", .{usage});
    controlledExecute(init.gpa, init.io, config) catch |err| {
        std.process.fatal(
            "flash stopped: {t}; interrupted load/reboot requires explicit recovery, never automatic retry",
            .{err},
        );
    };
}

/// With --cancel-stdin, any stdin byte or EOF requests cancellation. The caller
/// keeps the pipe open until then and awaits the wrapper's exit before releasing
/// its job. Killing only this wrapper would bypass its child cleanup.
pub fn controlledExecute(gpa: std.mem.Allocator, io: std.Io, config: Config) !void {
    if (!config.cancel_stdin) return execute(gpa, io, config);
    const Completion = union(enum) { flash: anyerror!void, cancel: anyerror!void };
    var buffer: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.flash, execute, .{ gpa, io, config });
    try select.concurrent(.cancel, readCancel, .{io});
    switch (try select.await()) {
        .flash => |result| try result,
        .cancel => |result| {
            try result;
            return error.Canceled;
        },
    }
}

fn readCancel(io: std.Io) anyerror!void {
    var byte: [1]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(io, &.{&byte});
}

pub fn execute(gpa: std.mem.Allocator, io: std.Io, config: Config) !void {
    const hash = try validateFile(gpa, io, config);
    std.debug.print(
        "Firmware: {s}\nSHA-256: {s}\nphase: discovery\n",
        .{ config.firmware, std.fmt.bytesToHex(hash, .lower) },
    );
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(config.discovery_ms),
        .clock = .awake,
    });
    while (true) {
        const remaining = std.Io.Clock.Timestamp.now(io, .awake).durationTo(deadline).raw.toMilliseconds();
        if (remaining <= 0) return error.DiscoveryTimeout;
        var result = tool(
            gpa,
            io,
            config,
            &.{"info"},
            @min(config.command_ms, @as(u32, @intCast(remaining))),
        ) catch |err| {
            if (err == error.CommandTimeout) return error.DiscoveryTimeout;
            return err;
        };
        defer freeResult(gpa, result);
        if (std.mem.indexOf(u8, result.stdout, multiple_devices) != null) return error.AmbiguousDevice;
        if (result.term.success()) break;
        // Other errors, including permission failures reported on stderr,
        // must not become endless polls.
        if (result.term != .exited or result.term.exited != no_device_status) {
            std.debug.print("discovery failed: {s}{s}\n", .{ result.stdout, result.stderr });
            return error.DiscoveryFailed;
        }
        const sleep_ms = std.Io.Clock.Timestamp.now(io, .awake).durationTo(deadline).raw.toMilliseconds();
        if (sleep_ms <= 0) return error.DiscoveryTimeout;
        try std.Io.sleep(io, .fromMilliseconds(@min(200, sleep_ms)), .awake);
    }
    // Reject a file replaced during BOOTSEL discovery. A mutable standalone path
    // can still change between this check and picotool opening it; managed
    // callers pass an immutable frozen copy.
    const current_hash = try validateFile(gpa, io, config);
    if (!std.mem.eql(u8, &hash, &current_hash)) return error.ArtifactChanged;
    std.debug.print("phase: load-verify\n", .{});
    var load = try tool(gpa, io, config, &.{ "load", "--verify", config.firmware }, config.command_ms);
    defer freeResult(gpa, load);
    std.debug.print("{s}{s}", .{ load.stdout, load.stderr });
    if (!load.term.success()) return error.LoadVerifyFailed;
    std.debug.print("phase: reboot\n", .{});
    if (config.bus == null and config.serial == null) {
        // Unlike load, picotool reboot accepts multiple devices. Recheck the
        // unselected case; managed callers select a target.
        const target = try tool(gpa, io, config, &.{"info"}, config.command_ms);
        defer freeResult(gpa, target);
        if (std.mem.indexOf(u8, target.stdout, multiple_devices) != null) return error.AmbiguousDevice;
        if (!target.term.success()) return error.RebootTargetLost;
    }
    var reboot = try tool(gpa, io, config, &.{ "reboot", "--application" }, config.command_ms);
    defer freeResult(gpa, reboot);
    std.debug.print("{s}{s}", .{ reboot.stdout, reboot.stderr });
    if (!reboot.term.success()) return error.RebootFailed;
    std.debug.print(
        "phase: reboot-complete (running identity still requires host reconnect verification)\n",
        .{},
    );
}

fn validateFile(gpa: std.mem.Allocator, io: std.Io, config: Config) ![32]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, config.firmware, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);
    try validateUf2(bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    if (config.expected_sha256) |expected| if (!std.mem.eql(u8, &expected, &hash)) return error.HashMismatch;
    return hash;
}

/// Complete ordered 512-byte blocks with UF2 magic, 256-byte payloads, the
/// RP2040 family flag and ID, and a matching block count.
pub fn validateUf2(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len % 512 != 0) return error.InvalidUf2;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 512) {
        const block = bytes[offset..][0..512];
        if (std.mem.readInt(u32, block[0..4], .little) != 0x0a324655 or
            std.mem.readInt(u32, block[4..8], .little) != 0x9e5d5157 or
            std.mem.readInt(u32, block[508..512], .little) != 0x0ab16f30 or
            std.mem.readInt(u32, block[8..12], .little) != 0x2000 or
            std.mem.readInt(u32, block[16..20], .little) != 256 or
            std.mem.readInt(u32, block[20..24], .little) != offset / 512 or
            std.mem.readInt(u32, block[24..28], .little) != bytes.len / 512 or
            std.mem.readInt(u32, block[28..32], .little) != 0xe48bff56) return error.InvalidUf2;
    }
}

fn freeResult(gpa: std.mem.Allocator, result: std.process.RunResult) void {
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

fn invoke(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) anyerror!std.process.RunResult {
    try io.checkCancel();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(gpa, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(4096, .none)) |_| {
        if (reader.reader(0).buffered().len > 64 * 1024 or
            reader.reader(1).buffered().len > 64 * 1024) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const id = child.id;
    const term = child.wait(io) catch |err| {
        // Zig 0.17.0 Threaded.childWaitPosix cleans up the child even when
        // cancellation interrupts wait4 before reap. Retain only the PID;
        // its pipes were closed by wait. The deferred kill then reaps it.
        if (@import("builtin").os.tag != .windows and child.id == null) child.id = id;
        return err;
    };
    const stdout = try reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .stdout = stdout, .stderr = stderr, .term = term };
}

fn expire(io: std.Io, ms: u32) anyerror!void {
    try std.Io.sleep(io, .fromMilliseconds(ms), .awake);
}

/// The watchdog covers child wait, even if a hung child closes its output pipes.
/// On cancellation the invocation kills and reaps the child before returning.
pub fn tool(
    gpa: std.mem.Allocator,
    io: std.Io,
    config: Config,
    command: []const []const u8,
    ms: u32,
) !std.process.RunResult {
    var argv: [10][]const u8 = undefined;
    argv[0] = config.picotool;
    @memcpy(argv[1..][0..command.len], command);
    var len = 1 + command.len;
    if (config.bus) |bus| {
        argv[len..][0..4].* = .{ "--bus", bus, "--address", config.address.? };
        len += 4;
    }
    if (config.serial) |serial| {
        argv[len..][0..2].* = .{ "--ser", serial };
        len += 2;
    }
    const Completion = union(enum) { process: anyerror!std.process.RunResult, timeout: anyerror!void };
    var buffer: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &buffer);
    defer while (select.cancel()) |pending| {
        if (pending == .process) {
            if (pending.process) |result| freeResult(gpa, result) else |_| {}
        }
    };
    try select.concurrent(.process, invoke, .{ gpa, io, argv[0..len] });
    try select.concurrent(.timeout, expire, .{ io, ms });
    return switch (try select.await()) {
        .process => |result| try result,
        .timeout => |result| blk: {
            try result;
            break :blk error.CommandTimeout;
        },
    };
}
