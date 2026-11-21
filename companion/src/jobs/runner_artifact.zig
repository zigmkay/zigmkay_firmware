//! Native runner provenance; loading/verifying never executes an artifact.
const std = @import("std");
const firmware = @import("firmware.zig");
const zon = @import("owned-zon");
const builtin = @import("builtin");
pub const native_target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);
pub const max_bytes = 64 * 1024 * 1024;

pub const Record = struct {
    version: u16 = 1,
    inputs: firmware.Inputs,
    host_target: []const u8,
    optimize: []const u8 = "Debug",
    build_key: firmware.Digest,
    path: []const u8,
    size: usize,
    hash: firmware.Digest,

    pub fn validate(self: Record) !void {
        if (self.version != 1) return error.UnsupportedRunnerManifest;
        try self.inputs.lock.validate();
        if (self.host_target.len == 0 or self.host_target.len > 96) return error.InvalidRunnerTarget;
        var components = std.mem.splitScalar(u8, self.host_target, '-');
        var count: usize = 0;
        while (components.next()) |component| {
            count += 1;
            if (component.len == 0) return error.InvalidRunnerTarget;
            for (component) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidRunnerTarget;
            }
        }
        if (count != 3) return error.InvalidRunnerTarget;
        if (!std.mem.eql(u8, self.optimize, "Debug")) return error.UnsupportedRunnerOptimization;
        if (!std.mem.eql(u8, &self.build_key, &key(self.inputs, self.host_target)))
            return error.RunnerManifestKeyMismatch;
        if (!std.fs.path.isAbsolute(self.path) or
            std.mem.indexOfScalar(u8, self.path, 0) != null) return error.InvalidArtifactPath;
        if (self.size == 0 or self.size > max_bytes) return error.InvalidRunnerLength;
    }
};

pub fn key(inputs: firmware.Inputs, host_target: []const u8) firmware.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-native-runner-v1\x00");
    hash.update(&firmware.key(inputs));
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, host_target.len, .little);
    hash.update(&length);
    hash.update(host_target);
    hash.update("\x00Debug");
    return hash.finalResult();
}

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    record: Record,

    pub fn complete(
        gpa: std.mem.Allocator,
        completion: firmware.Completion,
        prepared_key: firmware.Digest,
        captured: firmware.Inputs,
        current: firmware.Inputs,
        path: []const u8,
        bytes: []const u8,
    ) !Manifest {
        switch (completion) {
            .failed => return error.BuildFailed,
            .cancelled => return error.BuildCancelled,
            .succeeded => {},
        }
        if (!std.mem.eql(u8, &prepared_key, &key(captured, native_target)) or
            !std.mem.eql(u8, &prepared_key, &key(current, native_target))) return error.StaleBuild;
        return clone(gpa, .{
            .inputs = captured,
            .host_target = native_target,
            .build_key = prepared_key,
            .path = path,
            .size = bytes.len,
            .hash = firmware.digest(bytes),
        });
    }

    pub fn clone(gpa: std.mem.Allocator, record: Record) !Manifest {
        try record.validate();
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const owned = try zon.clone(arena.allocator(), record);
        return .{ .arena = arena, .record = owned };
    }

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Manifest {
        if (bytes.len > 32 * 1024) return error.RunnerManifestTooLarge;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const text = try a.dupeSentinel(u8, bytes, 0);
        const record = try zon.parse(Record, a, text);
        try record.validate();
        return .{ .arena = arena, .record = record };
    }

    pub fn serialize(self: Manifest, gpa: std.mem.Allocator) ![]u8 {
        try self.record.validate();
        var writer = std.Io.Writer.Allocating.init(gpa);
        errdefer writer.deinit();
        try std.zon.stringify.serializeMaxDepth(self.record, .{}, &writer.writer, 32);
        return writer.toOwnedSlice();
    }

    pub fn verify(self: Manifest, current: firmware.Inputs, bytes: []const u8) !void {
        try self.record.validate();
        if (!std.mem.eql(u8, self.record.host_target, native_target)) return error.RunnerHostMismatch;
        if (!std.mem.eql(u8, &self.record.build_key, &key(current, native_target))) return error.StaleBuild;
        if (bytes.len != self.record.size or
            !std.mem.eql(u8, &self.record.hash, &firmware.digest(bytes))) return error.RunnerArtifactChanged;
    }

    /// Re-read immediately before explicitly dispatching this absolute path.
    pub fn verifyFile(self: Manifest, gpa: std.mem.Allocator, io: std.Io, current: firmware.Inputs) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, self.record.path, gpa, .limited(max_bytes));
        defer gpa.free(bytes);
        try self.verify(current, bytes);
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Content-addressed copy independent of the mutable build output. Existing
/// entries are verified and preserved on corruption; callers serialize writers.
pub fn freeze(
    gpa: std.mem.Allocator,
    io: std.Io,
    cache: std.Io.Dir,
    manifest: Manifest,
    current: firmware.Inputs,
) !Manifest {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest.record.path, gpa, .limited(max_bytes));
    defer gpa.free(bytes);
    try manifest.verify(current, bytes);
    const digest = std.fmt.bytesToHex(manifest.record.hash, .lower);
    const name = digest ++ if (builtin.os.tag == .windows) ".exe" else "-runner";
    const existing = cache.readFileAlloc(
        io,
        name,
        gpa,
        .limited(max_bytes),
    ) catch |failure| switch (failure) {
        error.FileNotFound => null,
        else => return failure,
    };
    if (existing) |old| {
        defer gpa.free(old);
        try manifest.verify(current, old);
    } else {
        var atomic = try cache.createFileAtomic(io, name, .{ .replace = false });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        // Zig 0.17's Windows setReadOnly helper names a removed constant.
        // Use the typed attribute while retaining POSIX executable permissions.
        const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows)
            @fromBackingInt(
                @intCast(
                    @as(std.os.windows.DWORD, @bitCast(std.os.windows.FILE.ATTRIBUTE{ .READONLY = true })),
                ),
            )
        else
            std.Io.File.Permissions.executable_file.setReadOnly(true);
        if (builtin.os.tag == .windows) {
            // Zig's Windows rename opens the source with write/delete access;
            // marking the temporary file read-only first makes it fail. Publish
            // without replacement, then protect the published file before use.
            try atomic.link(io);
            const published = try cache.openFile(io, name, .{ .mode = .read_write });
            defer published.close(io);
            try published.setPermissions(io, permissions);
        } else {
            try atomic.file.setPermissions(io, permissions);
            try atomic.link(io);
        }
    }
    const base = try cache.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const path = try std.fs.path.join(gpa, &.{ base, name });
    defer gpa.free(path);
    var record = manifest.record;
    record.path = path;
    var frozen = try Manifest.clone(gpa, record);
    errdefer frozen.deinit();
    try frozen.verifyFile(gpa, io, current);
    return frozen;
}

test "runner manifests bind host captured inputs and actual executable bytes" {
    const t = std.testing;
    const inputs = firmware.Inputs{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = @splat(4),
        .identity_digest = @splat(5),
        .lock = @import("target_lock.zig").fixture(),
    };
    const build_key = key(inputs, native_target);
    var manifest = try Manifest.complete(
        t.allocator,
        .succeeded,
        build_key,
        inputs,
        inputs,
        "/cache/runner",
        "test executable bytes",
    );
    defer manifest.deinit();
    const bytes = try manifest.serialize(t.allocator);
    defer t.allocator.free(bytes);
    var restored = try Manifest.parse(t.allocator, bytes);
    defer restored.deinit();
    try restored.verify(inputs, "test executable bytes");
    try t.expectError(error.RunnerArtifactChanged, restored.verify(inputs, "changed"));
    try t.expectError(
        error.BuildCancelled,
        Manifest.complete(t.allocator, .cancelled, build_key, inputs, inputs, "/cache/runner", "old bytes"),
    );
    try t.expectError(
        error.BuildFailed,
        Manifest.complete(t.allocator, .failed, build_key, inputs, inputs, "/cache/runner", "old bytes"),
    );
    var changed = inputs;
    changed.build_inputs_digest[0] ^= 1;
    try t.expectError(error.StaleBuild, restored.verify(changed, "test executable bytes"));
    try t.expectError(
        error.StaleBuild,
        Manifest.complete(t.allocator, .succeeded, build_key, inputs, changed, "/cache/runner", "old bytes"),
    );
    var record = restored.record;
    record.host_target = "other-host-abi";
    record.build_key = key(inputs, record.host_target);
    var other_host = try Manifest.clone(t.allocator, record);
    defer other_host.deinit();
    try t.expectError(error.RunnerHostMismatch, other_host.verify(inputs, "test executable bytes"));
    record.version = 2;
    try t.expectError(error.UnsupportedRunnerManifest, Manifest.clone(t.allocator, record));
}

test "runner target accepts Zig Linux ABI names and rejects malformed values" {
    const t = std.testing;
    const inputs = firmware.Inputs{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = @splat(4),
        .identity_digest = @splat(5),
        .lock = @import("target_lock.zig").fixture(),
    };
    var record = Record{
        .inputs = inputs,
        .host_target = "x86_64-linux-gnu",
        .build_key = undefined,
        .path = "/cache/runner",
        .size = 1,
        .hash = @splat(0),
    };
    record.build_key = key(inputs, record.host_target);
    try record.validate();
    for ([_][]const u8{
        "x86_64-linux-gnu/evil",
        "x86_64-linux-gnu\\evil",
        "x86_64-linux-gnu\n",
        "x86_64--gnu",
        "-linux-gnu",
        "x86_64-linux-",
        "x86_64-linux-gnu-extra",
        "x86_64_linux_gnu",
    }) |invalid| {
        record.host_target = invalid;
        record.build_key = key(inputs, invalid);
        try t.expectError(error.InvalidRunnerTarget, record.validate());
    }
}

test "frozen runner survives source output replacement and preserves corrupt cache" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "output", .data = "runner executable bytes" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "output", t.allocator);
    defer t.allocator.free(path);
    const inputs = firmware.Inputs{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = @splat(4),
        .identity_digest = @splat(5),
        .lock = @import("target_lock.zig").fixture(),
    };
    var manifest = try Manifest.complete(
        t.allocator,
        .succeeded,
        key(inputs, native_target),
        inputs,
        inputs,
        path,
        "runner executable bytes",
    );
    defer manifest.deinit();
    var frozen = try freeze(t.allocator, t.io, tmp.dir, manifest, inputs);
    defer frozen.deinit();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "output", .data = "new build output" });
    try frozen.verifyFile(t.allocator, t.io, inputs);
    try t.expectError(error.RunnerArtifactChanged, manifest.verifyFile(t.allocator, t.io, inputs));
    // Replace the read-only entry to simulate external corruption; the
    // production freeze operation never repairs that entry. Deleting works on
    // every platform, while clearing Windows' read-only attribute needs a
    // handle with attribute write access that Zig does not open.
    try std.Io.Dir.cwd().deleteFile(t.io, frozen.record.path);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = frozen.record.path, .data = "corrupt cache" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "output", .data = "runner executable bytes" });
    try t.expectError(error.RunnerArtifactChanged, freeze(t.allocator, t.io, tmp.dir, manifest, inputs));
    const preserved = try std.Io.Dir.cwd().readFileAlloc(
        t.io,
        frozen.record.path,
        t.allocator,
        .limited(100),
    );
    defer t.allocator.free(preserved);
    try t.expectEqualStrings("corrupt cache", preserved);
}
