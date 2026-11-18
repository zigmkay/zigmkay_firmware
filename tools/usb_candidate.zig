//! Offline artifact inventory; does not discover, open or flash a device.
const std = @import("std");
const builtin = @import("builtin");
const profile = @import("generated-profile");
const protocol = @import("device-protocol");

fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn validate(bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len % 512 != 0 or bytes.len / 512 > 8192) return error.InvalidUf2Size;
    for (0..bytes.len / 512) |i| {
        const block = bytes[i * 512 ..][0..512];
        if (word(block, 0) != 0x0a324655 or word(block, 4) != 0x9e5d5157 or word(block, 508) != 0x0ab16f30)
            return error.InvalidUf2Magic;
        if (word(block, 8) != 0x2000 or word(block, 28) != 0xe48bff56) return error.InvalidUf2Family;
        const address = word(block, 12);
        const length = word(block, 16);
        if (length != 256 or address % 256 != 0 or address < 0x10000000 or address > 0x101fff00)
            return error.InvalidUf2Payload;
        if (word(block, 20) != i or word(block, 24) != bytes.len / 512) return error.InvalidUf2Inventory;
        if (i != 0 and address <= word(bytes[(i - 1) * 512 ..], 12)) return error.InvalidUf2AddressOrder;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4 or args[3].len != 40) return error.Usage;
    for (args[3]) |byte| if (!std.ascii.isHex(byte)) return error.InvalidRevision;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(4 * 1024 * 1024));
    try validate(bytes);
    const identity = profile.identity(protocol);
    if (!std.mem.eql(u8, &protocol.keymapId(identity), &profile.custom_functions.companion_keymap_id))
        return error.KeymapIdMismatch;
    var sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sha256, .{});
    const manifest = .{
        .version = @as(u16, 1),
        .acceptance = .offline_candidate,
        .firmware_revision = args[3],
        .compiler = builtin.zig_version_string,
        .identity = identity,
        // What the flashed keyboard reports in its companion hello.
        .keymap_id = profile.custom_functions.companion_keymap_id,
        .uf2_bytes = bytes.len,
        .uf2_sha256 = sha256,
        .uf2_family = @as(u32, 0xe48bff56),
        .limitations = "Local firmware override; native/hardware acceptance and S06 release provenance remain pending",
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    try std.zon.stringify.serializeMaxDepth(manifest, .{ .whitespace = true }, &output.writer, 16);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = output.written() });
}

test "candidate validation rejects malformed family length ordering and inventory" {
    var bytes: [1024]u8 = @splat(0);
    for (0..2) |i| {
        const block = bytes[i * 512 ..][0..512];
        const values = [_]u32{
            0x0a324655,
            0x9e5d5157,
            0x2000,
            @as(u32, 0x10000000) + @as(u32, @intCast(i * 256)),
            256,
            @intCast(i),
            2,
            0xe48bff56,
        };
        for (values, 0..) |value, index| std.mem.writeInt(u32, block[index * 4 ..][0..4], value, .little);
        std.mem.writeInt(u32, block[508..512], 0x0ab16f30, .little);
    }
    try validate(&bytes);
    const fields = [_]struct { offset: usize, value: u32, err: anyerror }{
        .{ .offset = 0, .value = 0, .err = error.InvalidUf2Magic },
        .{ .offset = 28, .value = 0, .err = error.InvalidUf2Family },
        .{ .offset = 16, .value = 476, .err = error.InvalidUf2Payload },
        .{ .offset = 20, .value = 1, .err = error.InvalidUf2Inventory },
        .{ .offset = 524, .value = 0x10000000, .err = error.InvalidUf2AddressOrder },
    };
    for (fields) |field| {
        var invalid = bytes;
        std.mem.writeInt(u32, invalid[field.offset..][0..4], field.value, .little);
        try std.testing.expectError(field.err, validate(&invalid));
    }
    try std.testing.expectError(error.InvalidUf2Size, validate(bytes[0..513]));
}
