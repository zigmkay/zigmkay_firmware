// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f,
// zig-flash/src/uf2.zig. See repository NOTICE and LICENSE.
const std = @import("std");

fn word(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

/// Validate the complete RP2040 flash transfer before opening any device file.
pub fn validate(gpa: std.mem.Allocator, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len % 512 != 0) return error.InvalidUf2Length;
    const count = bytes.len / 512;
    // Support a conservative 2 MiB transfer capacity; never infer physical
    // capacity from the RP2040's larger 16 MiB XIP window.
    if (count > 2 * 1024 * 1024 / 256) return error.Uf2ExceedsBoardFlash;
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, count);
    defer seen.deinit(gpa);
    for (0..count) |index| {
        const block = bytes[index * 512 ..][0..512];
        if (word(block, 0) != 0x0a324655 or
            word(block, 4) != 0x9e5d5157 or
            word(block, 508) != 0x0ab16f30) return error.InvalidUf2Magic;
        const flags = word(block, 8);
        if (flags & 0x2000 == 0 or word(block, 28) != 0xe48bff56) return error.MissingOrWrongRP2040Family;
        if (flags != 0x2000 or word(block, 16) != 256) return error.InvalidUf2FlashBlock;
        const address = word(block, 12);
        if (address < 0x10000000 or address > 0x10ffff00 or address % 256 != 0) return error.InvalidUf2FlashAddress;
        const number = word(block, 20);
        if (word(block, 24) != count or number >= count) return error.IncompleteUf2Transfer;
        if (seen.isSet(number)) return error.DuplicateUf2Block;
        if (address != 0x10000000 + number * 256) return error.InvalidUf2AddressOrder;
        seen.set(number);
    }
}

test "UF2 rejects aliased addresses and unsupported block flags" {
    var bytes = fixture(0, 2) ++ fixture(1, 2);
    @memcpy(bytes[512 + 12 ..][0..4], bytes[12..16]);
    try std.testing.expectError(error.InvalidUf2AddressOrder, validate(std.testing.allocator, &bytes));
    var single = fixture(0, 1);
    single[8] |= 0x80;
    try std.testing.expectError(error.InvalidUf2FlashBlock, validate(std.testing.allocator, &single));
}

fn fixture(number: u32, count: u32) [512]u8 {
    var bytes: [512]u8 = @splat(0);
    for ([_]struct { usize, u32 }{
        .{ 0, 0x0a324655 },                 .{ 4, 0x9e5d5157 },  .{ 8, 0x2000 },
        .{ 12, 0x10000000 + number * 256 }, .{ 16, 256 },        .{ 20, number },
        .{ 24, count },                     .{ 28, 0xe48bff56 }, .{ 508, 0x0ab16f30 },
    }) |entry| std.mem.writeInt(u32, bytes[entry[0]..][0..4], entry[1], .little);
    return bytes;
}

test "RP2040 requires family metadata in every block" {
    var bytes = fixture(0, 1);
    try validate(std.testing.allocator, &bytes);
    @memset(bytes[8..12], 0);
    try std.testing.expectError(error.MissingOrWrongRP2040Family, validate(std.testing.allocator, &bytes));
    bytes = fixture(0, 1);
    bytes[28] ^= 1;
    try std.testing.expectError(error.MissingOrWrongRP2040Family, validate(std.testing.allocator, &bytes));
}

test "complete UF2 rejects missing duplicate malformed and nonflash blocks" {
    var bytes = fixture(1, 2) ++ fixture(0, 2);
    try validate(std.testing.allocator, &bytes);
    try std.testing.expectError(error.IncompleteUf2Transfer, validate(std.testing.allocator, bytes[0..512]));
    @memcpy(bytes[512..], bytes[0..512]);
    try std.testing.expectError(error.DuplicateUf2Block, validate(std.testing.allocator, &bytes));
    try std.testing.expectError(error.InvalidUf2Length, validate(std.testing.allocator, bytes[0..511]));
    var single = fixture(0, 1);
    single[508] = 0;
    try std.testing.expectError(error.InvalidUf2Magic, validate(std.testing.allocator, &single));
    single = fixture(0, 1);
    single[8] |= 1;
    try std.testing.expectError(error.InvalidUf2FlashBlock, validate(std.testing.allocator, &single));
    single = fixture(0, 1);
    single[12] = 1;
    try std.testing.expectError(error.InvalidUf2FlashAddress, validate(std.testing.allocator, &single));
}
