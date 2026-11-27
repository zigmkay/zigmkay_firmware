//! Linux BOOTSEL volume discovery and copy for `tools/bootsel_transfer.zig`.
//! Needs no udev rule or root: the volume is mounted for the desktop user by
//! udisks2 (automounted, or explicitly with `udisksctl mount`).
const std = @import("std");
const policy = @import("bootsel-policy");

const sys_block = "/sys/class/block";

/// A mounted RPI-RP2 filesystem on the block device of one RP2040 ROM.
pub const Volume = struct {
    /// Block device number, "major:minor".
    dev: [16]u8 = @splat(0),
    /// sysfs name of the USB device, for example "2-1.4".
    usb: [64]u8 = @splat(0),
    serial: [64]u8 = @splat(0),
    mount: [256]u8 = @splat(0),

    pub fn same(a: Volume, b: Volume) bool {
        return std.meta.eql(a, b);
    }

    fn mountPoint(volume: *const Volume) []const u8 {
        return std.mem.sliceTo(&volume.mount, 0);
    }
};

pub fn ExitProcess(code: u8) noreturn {
    std.process.exit(code);
}

fn copy(destination: []u8, source: []const u8) !void {
    if (source.len >= destination.len) return error.VolumeIdentityUnavailable;
    @memcpy(destination[0..source.len], source);
}

fn readSmall(io: std.Io, buffer: []u8, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.VolumeIdentityUnavailable;
    defer file.close(io);
    const n = file.readStreaming(io, &.{buffer}) catch return error.VolumeIdentityUnavailable;
    return std.mem.trim(u8, buffer[0..n], " \n");
}

/// Walks from the block device up its sysfs ancestry to the first USB device
/// and requires it to be the RP2040 ROM; a label or product string never counts.
fn usbIdentity(io: std.Io, gpa: std.mem.Allocator, name: []const u8, volume: *Volume) !void {
    const link = try std.fs.path.join(gpa, &.{ sys_block, name });
    defer gpa.free(link);
    const real = std.Io.Dir.realPathFileAbsoluteAlloc(io, link, gpa) catch return error.VolumeIdentityUnavailable;
    defer gpa.free(real);
    var ancestor: []const u8 = real;
    while (std.fs.path.dirname(ancestor)) |parent| : (ancestor = parent) {
        if (!std.mem.startsWith(u8, parent, "/sys/devices/")) break;
        var path: [512]u8 = undefined;
        var vendor: [16]u8 = undefined;
        const vendor_id = readSmall(io, &vendor, std.fmt.bufPrint(&path, "{s}/idVendor", .{parent}) catch break) catch continue;
        var product: [16]u8 = undefined;
        const product_id = try readSmall(io, &product, try std.fmt.bufPrint(&path, "{s}/idProduct", .{parent}));
        if (!policy.isRp2040UsbIds(vendor_id, product_id)) return error.NotRp2040UsbDevice;
        var serial: [64]u8 = undefined;
        const serial_text = readSmall(io, &serial, try std.fmt.bufPrint(&path, "{s}/serial", .{parent})) catch "";
        try copy(&volume.usb, std.fs.path.basename(parent));
        try copy(&volume.serial, serial_text);
        return;
    }
    return error.NotRp2040UsbDevice;
}

/// Block devices already handed to udisksctl; each is asked to mount once.
var mount_requests: [8][16]u8 = @splat(@splat(0));

fn requestMount(io: std.Io, name: []const u8, dev: []const u8) void {
    var key: [16]u8 = @splat(0);
    if (dev.len >= key.len) return;
    @memcpy(key[0..dev.len], dev);
    for (&mount_requests) |*slot| {
        if (std.mem.eql(u8, slot, &key)) return;
        if (slot[0] == 0) {
            slot.* = key;
            break;
        }
    } else return;
    var device: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&device, "/dev/{s}", .{name}) catch return;
    // Desktops without an automounter leave the volume unmounted. udisks2
    // mounts removable media for the active session without a password; a
    // whole disk without a filesystem simply fails here.
    var child = std.process.spawn(io, .{
        .argv = &.{ "udisksctl", "mount", "--no-user-interaction", "-b", path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

fn inspect(io: std.Io, gpa: std.mem.Allocator, name: []const u8, mountinfo: []const u8) !?Volume {
    var volume: Volume = .{};
    try usbIdentity(io, gpa, name, &volume);
    var path: [512]u8 = undefined;
    var dev_buffer: [16]u8 = undefined;
    const dev = try readSmall(io, &dev_buffer, try std.fmt.bufPrint(&path, "{s}/{s}/dev", .{ sys_block, name }));
    try copy(&volume.dev, dev);
    if (policy.mountPoint(mountinfo, dev, &volume.mount) == null) {
        @memset(&volume.mount, 0);
        requestMount(io, name, dev);
        return null;
    }
    var info: [4097]u8 = undefined;
    const info_path = try std.fmt.bufPrint(&path, "{s}/INFO_UF2.TXT", .{volume.mountPoint()});
    const file = std.Io.Dir.openFileAbsolute(io, info_path, .{}) catch return error.InvalidBootselInfo;
    defer file.close(io);
    const n = file.readStreaming(io, &.{&info}) catch return error.InvalidBootselInfo;
    try policy.validateInfo(info[0..n]);
    return volume;
}

pub fn discover(io: std.Io) !?Volume {
    const gpa = std.heap.page_allocator;
    const mountinfo = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/mountinfo", gpa, .limited(4 * 1024 * 1024)) catch
        return error.VolumeEnumerationFailed;
    defer gpa.free(mountinfo);
    var dir = std.Io.Dir.openDirAbsolute(io, sys_block, .{ .iterate = true }) catch return error.VolumeEnumerationFailed;
    defer dir.close(io);
    var entries = dir.iterate();
    var found: ?Volume = null;
    while (entries.next(io) catch return error.VolumeEnumerationFailed) |entry| {
        const volume = inspect(io, gpa, entry.name, mountinfo) catch |err| switch (err) {
            error.NotRp2040UsbDevice, error.VolumeIdentityUnavailable => continue,
            else => return err,
        } orelse continue;
        if (found != null) return error.AmbiguousBootselDevices;
        found = volume;
    }
    return found;
}

pub const Ops = struct {
    io: std.Io,
    deadline: i64,

    pub fn check(self: *Ops) !void {
        if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= self.deadline) return error.TransferTimeout;
    }

    pub fn revalidate(self: *Ops, volume: Volume) !Volume {
        // Re-enumeration rejects a second device arriving during discovery.
        const current = try discover(self.io) orelse return error.DeviceDisappeared;
        if (!volume.same(current)) return error.BootselVolumeChanged;
        return current;
    }

    pub fn open(self: *Ops, volume: Volume) !std.Io.File {
        // Final recheck immediately before opening; the file is created beneath
        // the verified mount point without following links out of it.
        if (!volume.same(try self.revalidate(volume))) return error.BootselVolumeChanged;
        var root = std.Io.Dir.openDirAbsolute(self.io, volume.mountPoint(), .{}) catch
            return error.BootselDestinationUnavailable;
        defer root.close(self.io);
        return root.createFile(self.io, "FIRMWARE.UF2", .{ .resolve_beneath = true }) catch
            error.BootselDestinationUnavailable;
    }

    pub fn close(self: *Ops, file: std.Io.File) void {
        // The page cache must reach the device; the ROM may already be
        // rebooting into the new firmware, so a failed flush is not fatal.
        file.sync(self.io) catch {};
        file.close(self.io);
    }

    pub fn write(self: *Ops, file: std.Io.File, bytes: []const u8) !usize {
        file.writeStreamingAll(self.io, bytes) catch return error.BootselWriteFailed;
        return bytes.len;
    }
};
