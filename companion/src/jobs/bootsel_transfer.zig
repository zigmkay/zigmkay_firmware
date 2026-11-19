//! BOOTSEL policy with injected enumeration and I/O. No native calls in tests.
const std = @import("std");

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
    captured: Volume,
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
