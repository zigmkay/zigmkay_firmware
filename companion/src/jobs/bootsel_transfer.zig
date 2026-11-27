//! BOOTSEL policy with injected enumeration and I/O. No native calls in tests.
const std = @import("std");

/// Windows volume identity; `bootsel_linux.zig` defines its own. `transfer`
/// accepts either through a `same` method.
pub const Volume = struct {
    /// Fully qualified volume GUID root, including its trailing backslash.
    root: [64]u16,
    serial: u32,
    disk: u32,
    usb_identity: [256]u16,

    pub fn same(a: Volume, b: Volume) bool {
        return std.meta.eql(a, b);
    }
};

pub fn isRp2040UsbIdentity(id: []const u16) bool {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("USB\\VID_2E8A&PID_0003\\");
    return std.mem.startsWith(u16, id, prefix) and id.len > prefix.len and id[prefix.len] != 0;
}

/// Linux sysfs `idVendor`/`idProduct` file contents of the RP2040 ROM.
pub fn isRp2040UsbIds(vendor: []const u8, product: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, vendor, " \n"), "2e8a") and
        std.mem.eql(u8, std.mem.trim(u8, product, " \n"), "0003");
}

/// The mount point of block device `dev` ("major:minor") in /proc/self/mountinfo
/// text, unescaped into `out`. Null if it is not mounted, mounted more than
/// once, or the path does not fit.
pub fn mountPoint(mountinfo: []const u8, dev: []const u8, out: []u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        // id parent major:minor root mount-point ...
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const device = fields.next() orelse continue;
        const root = fields.next() orelse continue;
        const point = fields.next() orelse continue;
        if (!std.mem.eql(u8, device, dev) or !std.mem.eql(u8, root, "/")) continue;
        if (found != null) return null;
        found = point;
    }
    return unescapeMount(found orelse return null, out);
}

/// Decodes the octal escapes (\040 and friends) of a mountinfo path.
fn unescapeMount(escaped: []const u8, out: []u8) ?[]const u8 {
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
    if (n == 0 or out[0] != '/') return null;
    return out[0..n];
}

pub fn validateInfo(bytes: []const u8) !void {
    if (bytes.len > 4096 or !std.mem.startsWith(u8, bytes, "UF2 Bootloader v")) return error.InvalidBootselInfo;
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    var model = false;
    var board = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "Model: Raspberry Pi RP2")) model = true;
        if (std.mem.eql(u8, line, "Board-ID: RPI-RP2")) board = true;
    }
    if (!model or !board) return error.InvalidBootselInfo;
}

pub fn unique(volumes: []const Volume) !?Volume {
    if (volumes.len > 1) return error.AmbiguousBootselDevices;
    return if (volumes.len == 1) volumes[0] else null;
}

/// ops must recheck USB ancestry, GUID, serial and INFO before returning an open
/// destination. All bytes are validated and held in memory before any write.
pub fn transfer(
    gpa: std.mem.Allocator,
    ops: anytype,
    captured: anytype,
    bytes: []const u8,
    expected: [32]u8,
) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &expected)) return error.HashMismatch;
    try @import("firmware-uf2").validate(gpa, bytes);
    try ops.check();
    if (!captured.same(try ops.revalidate(captured))) return error.BootselVolumeChanged;
    const destination = try ops.open(captured);
    defer ops.close(destination);
    var offset: usize = 0;
    while (offset < bytes.len) {
        try ops.check();
        const count = try ops.write(destination, bytes[offset..@min(offset + 64 * 1024, bytes.len)]);
        if (count == 0 or count > bytes.len - offset) return error.IncompleteBootselTransfer;
        offset += count;
    }
    try ops.check();
    // The ROM reboots after accepting the complete UF2. No flash read-back is
    // claimed; the managed controller still requires coherent live identity.
}

test "BOOTSEL rejects fake labels and ambiguous enumeration" {
    const t = std.testing;
    try t.expectError(error.InvalidBootselInfo, validateInfo("RPI-RP2"));
    try t.expectError(
        error.InvalidBootselInfo,
        validateInfo("UF2 Bootloader v3\nModel: Raspberry Pi RP2\nBoard-ID: RPI-RP2350\n"),
    );
    try validateInfo("UF2 Bootloader v3.0\r\nModel: Raspberry Pi RP2\r\nBoard-ID: RPI-RP2\r\n");
    try t.expect(
        isRp2040UsbIdentity(std.unicode.utf8ToUtf16LeStringLiteral("USB\\VID_2E8A&PID_0003\\serial")),
    );
    try t.expect(
        !isRp2040UsbIdentity(std.unicode.utf8ToUtf16LeStringLiteral("USB\\VID_1234&PID_0003\\RPI-RP2")),
    );
    try t.expect(
        !isRp2040UsbIdentity(std.unicode.utf8ToUtf16LeStringLiteral("USB\\VID_2E8A&PID_0004\\serial")),
    );
    try t.expect(!isRp2040UsbIdentity(std.unicode.utf8ToUtf16LeStringLiteral("USB\\VID_2E8A&PID_0003\\")));
    const volume: Volume = .{ .root = @splat(0), .serial = 1, .disk = 2, .usb_identity = @splat(0) };
    try t.expect(try unique(&.{}) == null);
    try t.expectError(error.AmbiguousBootselDevices, unique(&.{ volume, volume }));
}

test "injected transfer validates bytes and identity before opening; no retries" {
    const t = std.testing;
    const Fixture = struct {
        changed: bool = false,
        failure: ?anyerror = null,
        checks: usize = 0,
        fail_after: usize = 0,
        written: usize = 0,
        opened: usize = 0,
        closed: bool = false,

        fn check(self: *@This()) !void {
            self.checks += 1;
            if (self.failure != null and self.checks > self.fail_after) return self.failure.?;
        }

        fn revalidate(self: *@This(), volume: Volume) !Volume {
            var result = volume;
            if (self.changed) result.serial += 1;
            return result;
        }

        fn open(self: *@This(), _: Volume) !usize {
            self.opened += 1;
            return 1;
        }

        fn close(self: *@This(), _: usize) void {
            self.closed = true;
        }

        fn write(self: *@This(), _: usize, bytes: []const u8) !usize {
            const n = @min(bytes.len, 31); // force partial writes
            self.written += n;
            return n;
        }
    };
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
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &hash, .{});
    const volume: Volume = .{ .root = @splat(0), .serial = 1, .disk = 2, .usb_identity = @splat(0) };
    var good: Fixture = .{};
    try transfer(t.allocator, &good, volume, &bytes, hash);
    try t.expect(good.closed and good.opened == 1 and good.written == 512);
    var changed: Fixture = .{ .changed = true };
    try t.expectError(error.BootselVolumeChanged, transfer(t.allocator, &changed, volume, &bytes, hash));
    try t.expectEqual(@as(usize, 0), changed.opened);
    bytes[100] ^= 1;
    try t.expectError(error.HashMismatch, transfer(t.allocator, &changed, volume, &bytes, hash));
    bytes[100] ^= 1;
    for ([_]anyerror{ error.FlashCancelled, error.TransferTimeout, error.DeviceDisappeared }) |err| {
        var failed: Fixture = .{ .failure = err, .fail_after = 3 };
        try t.expectError(err, transfer(t.allocator, &failed, volume, &bytes, hash));
        try t.expect(failed.closed and failed.opened == 1 and failed.written < 512);
    }
}

test "Linux BOOTSEL identity and mount lookup" {
    const t = std.testing;
    try t.expect(isRp2040UsbIds("2e8a\n", "0003\n"));
    try t.expect(!isRp2040UsbIds("2e8a\n", "000f\n"));
    try t.expect(!isRp2040UsbIds("1234\n", "0003\n"));
    const mountinfo =
        "22 1 0:21 / / rw,relatime - btrfs /dev/nvme0n1p2 rw\n" ++
        "88 22 8:17 / /run/media/conni/RPI-RP2 rw,nosuid - vfat /dev/sdb1 rw\n" ++
        "89 22 8:33 / /media/lisa\\040smith/RPI-RP2 rw - vfat /dev/sdc1 rw\n" ++
        "90 22 8:49 /sub /mnt/bind rw - vfat /dev/sdd1 rw\n" ++
        "91 22 8:65 / /mnt/a rw - vfat /dev/sde1 rw\n" ++
        "92 22 8:65 / /mnt/b rw - vfat /dev/sde1 rw\n";
    var out: [256]u8 = undefined;
    try t.expectEqualStrings("/run/media/conni/RPI-RP2", mountPoint(mountinfo, "8:17", &out).?);
    try t.expectEqualStrings("/media/lisa smith/RPI-RP2", mountPoint(mountinfo, "8:33", &out).?);
    // Bind mounts of a subdirectory, missing and doubly mounted devices are rejected.
    try t.expect(mountPoint(mountinfo, "8:49", &out) == null);
    try t.expect(mountPoint(mountinfo, "8:1", &out) == null);
    try t.expect(mountPoint(mountinfo, "8:65", &out) == null);
    var small: [4]u8 = undefined;
    try t.expect(mountPoint(mountinfo, "8:17", &small) == null);
}
