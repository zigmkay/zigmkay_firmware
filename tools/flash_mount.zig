const std = @import("std");
const builtin = @import("builtin");

const poll_interval: std.Io.Duration = .fromMilliseconds(200);
const default_label = "RPI-RP2";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const usage =
        \\usage: flash_mount <firmware.uf2> [mount_point_or_label]
        \\  mount_point_or_label: absolute path of the mounted bootloader volume,
        \\                        or its volume label (default: "RPI-RP2")
    ;
    const firmware_path = args.next() orelse std.process.fatal(usage, .{});
    const mount_point_or_label = blk: {
        const arg = args.next() orelse break :blk default_label;
        break :blk if (arg.len == 0) default_label else arg;
    };
    if (args.next() != null) std.process.fatal(usage, .{});

    const firmware = try std.Io.Dir.cwd().readFileAlloc(io, firmware_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(firmware);
    std.debug.print("Firmware: {s}\n", .{firmware_path});

    const mount_point = if (std.fs.path.isAbsolute(mount_point_or_label))
        try waitForMountPoint(io, allocator, mount_point_or_label)
    else
        try waitForLabel(io, allocator, init.environ_map, mount_point_or_label);
    defer allocator.free(mount_point);

    // Give the host a moment to finish mounting before writing to the volume.
    try std.Io.sleep(io, .fromMilliseconds(500), .awake);

    const target_path = try std.fs.path.join(allocator, &.{ mount_point, "firmware.uf2" });
    defer allocator.free(target_path);
    std.debug.print("Copying firmware to {s}...\n", .{target_path});

    // Write in place instead of using Dir.copyFile: that writes a temporary
    // file and renames it afterwards, but the bootloader reboots as soon as
    // the last UF2 block arrives, so the rename fails on a vanished volume.
    const file = try std.Io.Dir.cwd().createFile(io, target_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, firmware);
    // The device may already be rebooting, so a failed flush is not fatal.
    file.sync(io) catch {};

    std.debug.print("Firmware copied; the device reboots into the new firmware.\n", .{});
}

/// Waits until `mount_point` exists and returns a copy of it.
fn waitForMountPoint(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) ![]const u8 {
    std.debug.print("Waiting for the bootloader volume at {s}...\n", .{mount_point});
    while (true) {
        if (std.Io.Dir.accessAbsolute(io, mount_point, .{})) |_| {
            return allocator.dupe(u8, mount_point);
        } else |_| {}
        try std.Io.sleep(io, poll_interval, .awake);
    }
}

/// Waits for a volume labelled `label` to be mounted and returns its mount point.
fn waitForLabel(io: std.Io, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map, label: []const u8) ![]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            std.debug.print("Waiting for a drive labelled '{s}'...\n", .{label});
            // Keep Windows from showing "insert a disk" dialogs for empty card readers.
            _ = windows.SetErrorMode(windows.SEM_FAILCRITICALERRORS);
            while (true) {
                if (windows.findDriveByLabel(label)) |drive| {
                    std.debug.print("Found drive {s}\n", .{&drive});
                    return allocator.dupe(u8, &drive);
                }
                try std.Io.sleep(io, poll_interval, .awake);
            }
        },
        .macos => {
            const mount_point = try std.fs.path.join(allocator, &.{ "/Volumes", label });
            defer allocator.free(mount_point);
            return waitForMountPoint(io, allocator, mount_point);
        },
        .linux => {
            const user = environ_map.get("USER") orelse std.process.fatal("USER is not set; pass an absolute mount point instead", .{});
            const mount_point = try std.fs.path.join(allocator, &.{ "/run/media", user, label });
            defer allocator.free(mount_point);
            const device = try std.fs.path.join(allocator, &.{ "/dev/disk/by-label", label });
            defer allocator.free(device);

            std.debug.print("Waiting for the bootloader volume at {s}...\n", .{mount_point});
            while (true) {
                if (std.Io.Dir.accessAbsolute(io, mount_point, .{})) |_| {
                    return allocator.dupe(u8, mount_point);
                } else |_| {}
                // Desktops without an automounter (e.g. COSMIC) leave the volume
                // unmounted, so mount it via udisksctl when available.
                if (std.Io.Dir.accessAbsolute(io, device, .{})) |_| {
                    udisksctlMount(io, device);
                } else |_| {}
                try std.Io.sleep(io, poll_interval, .awake);
            }
        },
        else => std.process.fatal("finding a volume by label is unsupported on {t}; pass an absolute mount point", .{builtin.os.tag}),
    }
}

fn udisksctlMount(io: std.Io, device: []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "udisksctl", "mount", "-b", device },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

const windows = struct {
    const BOOL = std.os.windows.BOOL;
    const SEM_FAILCRITICALERRORS: u32 = 0x0001;

    extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
    extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetVolumeInformationW(
        root_path_name: ?[*:0]const u16,
        volume_name_buffer: ?[*]u16,
        volume_name_size: u32,
        volume_serial_number: ?*u32,
        maximum_component_length: ?*u32,
        file_system_flags: ?*u32,
        file_system_name_buffer: ?[*]u16,
        file_system_name_size: u32,
    ) callconv(.winapi) BOOL;

    /// Returns the drive (e.g. "E:") whose volume label equals `label`,
    /// ignoring ASCII case.
    fn findDriveByLabel(label: []const u8) ?[2]u8 {
        const drives = GetLogicalDrives();
        for (0..26) |index| {
            if (drives & (@as(u32, 1) << @intCast(index)) == 0) continue;
            const letter: u8 = 'A' + @as(u8, @intCast(index));
            const root = [_:0]u16{ letter, ':', '\\' };

            var name_wtf16: [261]u16 = undefined;
            if (GetVolumeInformationW(&root, &name_wtf16, name_wtf16.len, null, null, null, null, 0) == .FALSE) continue;
            const name_len = std.mem.indexOfScalar(u16, &name_wtf16, 0) orelse continue;

            var name_buf: [261 * 3]u8 = undefined;
            const name = name_buf[0..std.unicode.wtf16LeToWtf8(&name_buf, name_wtf16[0..name_len])];
            if (std.ascii.eqlIgnoreCase(name, label)) return .{ letter, ':' };
        }
        return null;
    }
};
