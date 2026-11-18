//! Build identity and paths inside the shipped application. No discovery,
//! receipts for developer installations, package audits or network policy.
const std = @import("std");
const firmware = @import("firmware.zig");
pub const Digest = firmware.Digest;

pub const Receipt = struct {
    version: u16 = 1,
    bundle_id: Digest,
    lock_digest: Digest,

    pub fn validate(self: Receipt) !void {
        if (self.version != 1) return error.UnsupportedReceiptVersion;
    }

    pub fn digest(self: Receipt) Digest {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zigmkay-bundled-build-v1");
        hash.update(&self.bundle_id);
        hash.update(&self.lock_digest);
        return hash.finalResult();
    }

    pub fn serialize(self: Receipt, a: std.mem.Allocator) ![]u8 {
        try self.validate();
        var text: std.Io.Writer.Allocating = .init(a);
        errdefer text.deinit();
        try std.zon.stringify.serialize(self, .{}, &text.writer);
        return text.toOwnedSlice();
    }

    pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Receipt {
        if (bytes.len > 8192) return error.ReceiptTooLarge;
        const text = try a.dupeSentinel(u8, bytes, 0);
        defer a.free(text);
        const receipt = try @import("owned-zon").parse(Receipt, a, text);
        try receipt.validate();
        return receipt;
    }
};

pub const Selection = struct {
    lock: @import("target_lock.zig").Lock,
    compiler_path: []const u8,
    compiler_distribution_path: []const u8,
    build_root: []const u8,
    project_digest: Digest,
    exported_source_digest: Digest,
    profile_id: [8]u8,
    identity_digest: [16]u8,
};

pub const Captured = struct {
    arena: std.heap.ArenaAllocator,
    inputs: firmware.Inputs,
    receipt: Receipt,

    pub fn deinit(self: *Captured) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
