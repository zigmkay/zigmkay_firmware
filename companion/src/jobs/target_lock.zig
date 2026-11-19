//! Explicit target provenance, separate from schema-1 project data and live identity.
const std = @import("std");
const zon = @import("owned-zon");
pub const Digest = [32]u8;
pub const version: u16 = 1;
pub const compiler_origin_version: u16 = 2;
/// Repository of the pinned `zigmkay_firmware` dependency in build.zig.zon.
pub const repository = "conlorz/zigmkay_firmware";
pub const CompilerKind = enum { checked_bundle, selected_installation };

pub const Lock = struct {
    version: u16 = version,
    firmware_repository: []const u8 = repository,
    firmware_revision: []const u8,
    firmware_source_digest: Digest,
    source_kind: enum { published, development },
    dependency_digest: Digest,
    zig_version: []const u8 = "0.17.0",
    compiler_digest: Digest,
    compiler_bundle_digest: Digest,
    board: []const u8,
    board_mapping_digest: Digest,
    target: []const u8 = "thumb-freestanding-eabi",
    optimize: []const u8 = "ReleaseSafe",
    action_abi: u16 = 1,
    export_version: u16 = 1,
    runner_version: u16 = 1,
    device_version: u8 = 2,
    compiler_kind: CompilerKind = .checked_bundle,
    compiler_tree_digest: Digest = @splat(0),
    toolchain_receipt_digest: Digest = @splat(0),

    pub fn validate(self: Lock) !void {
        if (self.version != version and self.version != compiler_origin_version) return error.UnsupportedLockVersion;
        try self.validateCompilerOrigin();
        if (!std.mem.eql(u8, self.firmware_repository, repository)) return error.UnsupportedFirmwareRepository;
        if (self.firmware_revision.len != 40) return error.InvalidFirmwareRevision;
        for (self.firmware_revision) |c| {
            if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return error.InvalidFirmwareRevision;
        }
        if (!std.mem.eql(u8, self.zig_version, "0.17.0")) return error.UnsupportedCompilerVersion;
        if (self.board.len == 0 or self.board.len > 64) return error.InvalidBoardSelector;
        for (self.board) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidBoardSelector;
        }
        if (!std.mem.eql(u8, self.target, "thumb-freestanding-eabi")) return error.UnsupportedTarget;
        if (!std.mem.eql(u8, self.optimize, "ReleaseSafe")) return error.UnsupportedOptimization;
        if (self.action_abi != 1 or
            self.export_version != 1 or
            self.runner_version != 1 or
            self.device_version != 2) return error.UnsupportedTargetContract;
    }

    fn validateCompilerOrigin(self: Lock) !void {
        const has_tree = !isZero(self.compiler_tree_digest);
        const has_receipt = !isZero(self.toolchain_receipt_digest);
        const has_bundle = !isZero(self.compiler_bundle_digest);
        const records_origin = self.version == compiler_origin_version;
        if (!records_origin and (self.compiler_kind != .checked_bundle or has_tree or has_receipt))
            return error.InvalidLegacyCompilerOrigin;
        if (records_origin and (!has_tree or !has_receipt)) return error.MissingCompilerOrigin;
        if (self.compiler_kind == .selected_installation and (!has_tree or !has_receipt or has_bundle))
            return error.InvalidSelectedCompilerOrigin;
        if (records_origin and self.compiler_kind == .checked_bundle and !has_bundle)
            return error.InvalidCheckedCompilerOrigin;
    }

    /// Fixed-field framing avoids dependence on ZON formatting or struct padding.
    pub fn digest(self: Lock) Digest {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(
            if (self.version == version) "zigmkay-target-lock-v1\x00" else "zigmkay-target-lock-v2\x00",
        );
        inline for (@typeInfo(Lock).@"struct".field_names) |name| {
            if (self.version != version or comptime !isOriginField(name)) {
                const value = @field(self, name);
                const T = @TypeOf(value);
                if (T == []const u8) {
                    var length: [8]u8 = undefined;
                    std.mem.writeInt(u64, &length, value.len, .little);
                    hash.update(&length);
                    hash.update(value);
                } else if (T == Digest) {
                    hash.update(&value);
                } else if (@typeInfo(T) == .@"enum") {
                    hash.update(&.{@backingInt(value)});
                } else {
                    var bytes: [@sizeOf(T)]u8 = undefined;
                    std.mem.writeInt(T, &bytes, value, .little);
                    hash.update(&bytes);
                }
            }
        }
        return hash.finalResult();
    }

    pub fn serialize(self: Lock, gpa: std.mem.Allocator) ![]u8 {
        try self.validate();
        var writer: std.Io.Writer.Allocating = .init(gpa);
        errdefer writer.deinit();
        if (self.version == 1) {
            var legacy: Legacy = undefined;
            inline for (@typeInfo(Legacy).@"struct".field_names) |name| @field(legacy, name) = @field(self, name);
            try std.zon.stringify.serializeMaxDepth(legacy, .{}, &writer.writer, 8);
        } else try std.zon.stringify.serializeMaxDepth(self, .{}, &writer.writer, 8);
        return writer.toOwnedSlice();
    }
};

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

/// Fields introduced by version 2; version 1 digests and files omit them.
fn isOriginField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "compiler_kind") or
        std.mem.eql(u8, name, "compiler_tree_digest") or
        std.mem.eql(u8, name, "toolchain_receipt_digest");
}

// Frozen v1 serialization: newer origin fields must not reach older readers.
const Legacy = struct {
    version: u16,
    firmware_repository: []const u8,
    firmware_revision: []const u8,
    firmware_source_digest: Digest,
    source_kind: @FieldType(Lock, "source_kind"),
    dependency_digest: Digest,
    zig_version: []const u8,
    compiler_digest: Digest,
    compiler_bundle_digest: Digest,
    board: []const u8,
    board_mapping_digest: Digest,
    target: []const u8,
    optimize: []const u8,
    action_abi: u16,
    export_version: u16,
    runner_version: u16,
    device_version: u8,
};

/// The caller owns the parsed value and must free it. No compiler runs on load.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Lock {
    if (bytes.len > 16 * 1024) return error.LockTooLarge;
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    const result = try zon.parse(Lock, gpa, text);
    errdefer free(gpa, result);
    try result.validate();
    return result;
}

pub fn free(gpa: std.mem.Allocator, value: Lock) void {
    zon.free(gpa, value);
}

pub fn fixture() Lock {
    return .{
        .firmware_revision = "57497457ec77947426cbc5c6468c92e1a2e0506f",
        .firmware_source_digest = @splat(1),
        .source_kind = .development,
        .dependency_digest = @splat(2),
        .compiler_digest = @splat(3),
        .compiler_bundle_digest = @splat(4),
        .board = "lk7",
        .board_mapping_digest = @splat(5),
    };
}

test "target locks roundtrip without compiling and reject future contracts" {
    const gpa = std.testing.allocator;
    const original = fixture();
    try std.testing.expectEqualStrings(
        "50a39d92a50b779bdef38805eff449c15637f05276ef5150984309982482a71a",
        &std.fmt.bytesToHex(original.digest(), .lower),
    );
    const bytes = try original.serialize(gpa);
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "compiler_kind") == null);
    const restored = try parse(gpa, bytes);
    defer free(gpa, restored);
    try std.testing.expectEqual(original.digest(), restored.digest());
    var changed = original;
    changed.version = 3;
    try std.testing.expectError(error.UnsupportedLockVersion, changed.validate());
    changed.version = 2;
    try std.testing.expectError(error.MissingCompilerOrigin, changed.validate());
    changed = original;
    changed.zig_version = "0.16.0";
    try std.testing.expectError(error.UnsupportedCompilerVersion, changed.validate());
    changed = original;
    changed.firmware_revision = "main";
    try std.testing.expectError(error.InvalidFirmwareRevision, changed.validate());
    changed = original;
    changed.board = "../lk7";
    try std.testing.expectError(error.InvalidBoardSelector, changed.validate());
}

test "all provenance fields affect the target lock digest" {
    var original = fixture();
    original.version = 2;
    inline for (@typeInfo(Lock).@"struct".field_names) |name| {
        var changed = original;
        const T = @TypeOf(@field(changed, name));
        if (T == []const u8) {
            @field(changed, name) = "changed";
        } else if (T == Digest) {
            @field(changed, name)[0] ^= 1;
        } else if (@typeInfo(T) == .@"enum") {
            @field(changed, name) = @fromBackingInt(@backingInt(@field(changed, name)) ^ 1);
        } else {
            @field(changed, name) += 1;
        }
        try std.testing.expect(!std.mem.eql(u8, &original.digest(), &changed.digest()));
    }
}
