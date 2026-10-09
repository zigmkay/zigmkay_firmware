const std = @import("std");

const poll_interval: std.Io.Duration = .fromMilliseconds(200);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const usage = "usage: picotool_flash <picotool> <firmware.uf2>";
    const picotool = args.next() orelse std.process.fatal(usage, .{});
    const firmware_path = args.next() orelse std.process.fatal(usage, .{});
    if (args.next() != null) std.process.fatal(usage, .{});

    const firmware = try std.Io.Dir.cwd().readFileAlloc(io, firmware_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(firmware);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(firmware, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    std.debug.print("Firmware: {s}\nSHA-256:  {s}\n", .{ firmware_path, digest_hex });
    check_rp2040_uf2(firmware, firmware_path);
    std.debug.print("Waiting for an RP-series device in BOOTSEL mode...\n", .{});

    while (true) {
        const term = try run(io, &.{ picotool, "info" }, .ignore);
        if (term.success()) break;
        try std.Io.sleep(io, poll_interval, .awake);
    }

    std.debug.print("BOOTSEL device found; loading and verifying firmware...\n", .{});
    const load_term = try run(io, &.{ picotool, "load", "--verify", firmware_path }, .inherit);
    if (!load_term.success()) std.process.fatal("picotool load failed: {f}", .{load_term});

    const reboot_term = try run(io, &.{ picotool, "reboot", "--application" }, .inherit);
    if (!reboot_term.success()) std.process.fatal("picotool reboot failed: {f}", .{reboot_term});
}

/// picotool silently skips UF2 blocks without a matching family ID and still
/// exits successfully ("No ranges to verify"), so reject such files up front.
fn check_rp2040_uf2(uf2: []const u8, path: []const u8) void {
    const block_size = 512;
    const flag_family_id_present: u32 = 0x2000;
    const rp2040_family_id: u32 = 0xe48bff56;

    if (uf2.len == 0 or uf2.len % block_size != 0) std.process.fatal("{s} is not a UF2 file", .{path});
    var offset: usize = 0;
    while (offset < uf2.len) : (offset += block_size) {
        const flags = std.mem.readInt(u32, uf2[offset + 8 ..][0..4], .little);
        const family_id = std.mem.readInt(u32, uf2[offset + 28 ..][0..4], .little);
        if (flags & flag_family_id_present == 0 or family_id != rp2040_family_id) {
            std.process.fatal("{s}: UF2 block at offset {d} has no RP2040 family ID; picotool would flash nothing", .{ path, offset });
        }
    }
}

fn run(io: std.Io, argv: []const []const u8, output_behavior: std.process.SpawnOptions.StdIo) !std.process.Child.Term {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = output_behavior,
        .stderr = output_behavior,
    }) catch |err| switch (err) {
        error.FileNotFound => std.process.fatal("unable to run {s}", .{argv[0]}),
        else => return err,
    };
    return child.wait(io);
}
