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
        try waitForLabel(io, allocator, mount_point_or_label);
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
fn waitForLabel(io: std.Io, allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
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
            const device = try std.fs.path.join(allocator, &.{ "/dev/disk/by-label", label });
            defer allocator.free(device);
            std.debug.print("Waiting for the bootloader volume labelled '{s}'...\n", .{label});
            var requested: ?[]u8 = null;
            defer if (requested) |path| allocator.free(path);
            while (true) {
                // Distributions mount removable media in different places
                // (/run/media/$USER on Arch and Fedora, /media/$USER on Debian
                // and Ubuntu), so ask the kernel where the device is mounted.
                if (std.Io.Dir.realPathFileAbsoluteAlloc(io, device, allocator)) |source| {
                    defer allocator.free(source);
                    if (try mountPointOf(io, allocator, source)) |mount_point| return mount_point;
                    // Desktops without an automounter (e.g. COSMIC) leave the
                    // volume unmounted; ask udisks once per device node.
                    if (requested == null or !std.mem.eql(u8, requested.?, source)) {
                        if (requested) |path| allocator.free(path);
                        requested = try allocator.dupe(u8, source);
                        udisksctlMount(io, source);
                    }
                } else |_| {}
                try std.Io.sleep(io, poll_interval, .awake);
            }
        },
        else => std.process.fatal("finding a volume by label is unsupported on {t}; pass an absolute mount point", .{builtin.os.tag}),
    }
}

/// Reads a procfs virtual file whose reported stat size is 0.
fn readProcFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        if (out.items.len + n > max_bytes) return error.StreamTooLong;
        try out.appendSlice(allocator, chunk[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

/// The mount point of block device `source` (e.g. /dev/sdb1), if it is mounted.
fn mountPointOf(io: std.Io, allocator: std.mem.Allocator, source: []const u8) !?[]const u8 {
    const mountinfo = readProcFile(io, allocator, "/proc/self/mountinfo", 4 * 1024 * 1024) catch return null;
    defer allocator.free(mountinfo);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const mount_point = mountPointIn(mountinfo, source, &buffer) orelse return null;
    return try allocator.dupe(u8, mount_point);
}

/// Parses /proc/self/mountinfo text: "id parent major:minor root mount-point
/// options ... - fstype source super-options". Only whole-filesystem mounts count.
fn mountPointIn(mountinfo: []const u8, source: []const u8, out: []u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOf(u8, line, " - ") orelse continue;
        var tail = std.mem.tokenizeScalar(u8, line[separator + 3 ..], ' ');
        _ = tail.next() orelse continue;
        const mounted = tail.next() orelse continue;
        if (!std.mem.eql(u8, mounted, source)) continue;
        var head = std.mem.tokenizeScalar(u8, line[0..separator], ' ');
        _ = head.next(); // mount id
        _ = head.next(); // parent id
        _ = head.next(); // major:minor
        const root = head.next() orelse continue;
        const point = head.next() orelse continue;
        if (!std.mem.eql(u8, root, "/")) continue;
        return unescape(point, out);
    }
    return null;
}

/// Decodes mountinfo's octal escapes such as \040 for a space.
fn unescape(escaped: []const u8, out: []u8) ?[]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < escaped.len) : (n += 1) {
        if (n == out.len) return null;
        if (escaped[i] == '\\' and i + 4 <= escaped.len) {
            out[n] = std.fmt.parseInt(u8, escaped[i + 1 .. i + 4], 8) catch return null;
            i += 4;
        } else {
            out[n] = escaped[i];
            i += 1;
        }
    }
    return out[0..n];
}

test mountPointIn {
    const mountinfo =
        "22 1 0:21 / / rw - btrfs /dev/nvme0n1p2 rw\n" ++
        "88 22 8:17 / /media/lisa\\040smith/RPI-RP2 rw,nosuid - vfat /dev/sdb1 rw\n" ++
        "90 22 8:33 /sub /mnt/bind rw - vfat /dev/sdc1 rw\n";
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/media/lisa smith/RPI-RP2", mountPointIn(mountinfo, "/dev/sdb1", &out).?);
    try std.testing.expect(mountPointIn(mountinfo, "/dev/sdc1", &out) == null);
    try std.testing.expect(mountPointIn(mountinfo, "/dev/sdd1", &out) == null);
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
