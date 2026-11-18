//! Immutable, relocatable application resources. No package discovery or network.
const std = @import("std");
const firmware = @import("firmware.zig");

pub const Manifest = struct {
    version: u16 = 1,
    backend: @import("flash_inputs.zig").Backend = .picotool,
    zig_version: []const u8 = "0.17.0",
    id: firmware.Digest,
    firmware_revision: []const u8,
    wrapper_hash: firmware.Digest,
    picotool_hash: firmware.Digest,

    pub fn validate(self: Manifest) !void {
        if ((self.version != 1 and self.version != 2) or
            !std.mem.eql(u8, self.zig_version, "0.17.0")) return error.UnsupportedApplicationBundle;
        if (self.version == 1 and self.backend != .picotool) return error.UnsupportedApplicationBundle;
        if (self.firmware_revision.len != 40) return error.InvalidFirmwareRevision;
        for (self.firmware_revision) |c| if (!std.ascii.isHex(c)) return error.InvalidFirmwareRevision;
    }
};

pub const Bundle = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    manifest: Manifest,
    executable: ?[]const u8 = null,

    pub fn fromExecutable(
        gpa: std.mem.Allocator,
        io: std.Io,
        executable: []const u8,
        cache: []const u8,
    ) !Bundle {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const payload = try @import("bundle_payload.zig").header(a, io, executable);
        const root = try std.fs.path.join(a, &.{
            cache,
            "runtime",
            &std.fmt.bytesToHex(payload.manifest.id, .lower),
        });
        return .{
            .arena = arena,
            .root = root,
            .manifest = payload.manifest,
            .executable = payload.executable,
        };
    }

    pub fn open(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !Bundle {
        if (!std.fs.path.isAbsolute(root)) return error.InvalidBundlePath;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try a.dupe(u8, root);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            try std.fs.path.join(a, &.{ root, "application.zon" }),
            a,
            .limited(8192),
        );
        const manifest = try @import("owned-zon").parse(Manifest, a, try a.dupeSentinel(u8, bytes, 0));
        try manifest.validate();
        return .{ .arena = arena, .root = owned, .manifest = manifest };
    }

    pub fn path(self: Bundle, a: std.mem.Allocator, relative: []const u8) ![]u8 {
        return std.fs.path.join(a, &.{ self.root, relative });
    }

    pub fn deinit(self: *Bundle) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "bundle descriptor rejects incompatible tools without executing them" {
    const value: Manifest = .{
        .id = @splat(1),
        .firmware_revision = "83b689262ae4a6f814ba9c7aa9fa868bf734350f",
        .wrapper_hash = @splat(2),
        .picotool_hash = @splat(3),
    };
    try value.validate();
    var wrong = value;
    wrong.zig_version = "0.16.0";
    try std.testing.expectError(error.UnsupportedApplicationBundle, wrong.validate());
}
