//! Offline firmware build contract. Callers capture verified exports and all
//! compiler/dependency/build inputs before invoking the existing Job boundary.
const std = @import("std");
const uf2 = @import("firmware-uf2");
const target_lock = @import("target_lock.zig");
pub const Digest = [32]u8;

pub fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub const Inputs = struct {
    project_digest: Digest,
    source_digest: Digest,
    build_inputs_digest: Digest,
    profile_id: [8]u8,
    identity_digest: [16]u8,
    lock: target_lock.Lock,
};

/// Includes the complete owned source inventory digest, independently of live
/// telemetry identity (metadata changes still invalidate a build).
pub fn key(input: Inputs) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-firmware-manifest-v2\x00");
    hash.update(&input.project_digest);
    hash.update(&input.source_digest);
    hash.update(&input.build_inputs_digest);
    hash.update(&input.lock.digest());
    hash.update(&input.profile_id);
    hash.update(&input.identity_digest);
    return hash.finalResult();
}

fn validateInputs(input: Inputs) !void {
    try input.lock.validate();
}

pub const Command = struct {
    /// Index of the build step name in `argv`.
    pub const step_arg = 4;
    /// Index of the local cache directory in `argv`.
    pub const cache_dir_arg = 9;

    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    cwd: []const u8,
    uf2_path: []const u8,
    build_key: Digest,

    /// Input paths are absolute literals; --fork is a canonical relative path
    /// resolved from the canonical cwd. No shell, flash or device discovery.
    pub fn init(
        gpa: std.mem.Allocator,
        input: Inputs,
        compiler: []const u8,
        repository: []const u8,
        export_directory: []const u8,
        install_directory: []const u8,
        development_firmware: ?[]const u8,
    ) !Command {
        try validateInputs(input);
        if ((input.lock.source_kind == .development) != (development_firmware != null))
            return error.FirmwareOverrideMismatch;
        for ([_][]const u8{ compiler, repository, export_directory, install_directory }) |path| {
            if (!std.fs.path.isAbsolute(path) or
                std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidBuildPath;
        }
        if (development_firmware) |path| {
            if (!std.fs.path.isAbsolute(path) or
                std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidBuildPath;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const args = try a.alloc([]const u8, if (development_firmware != null) 14 else 12);
        var owned_cwd: []const u8 = try a.dupe(u8, repository);
        args[0] = try a.dupe(u8, compiler);
        args[1] = "build";
        args[2] = "--build-file";
        args[3] = "build.zig";
        args[step_arg] = "build-project";
        args[5] = try std.fmt.allocPrint(a, "-Dproject-board={s}", .{input.lock.board});
        args[6] = try std.fmt.allocPrint(a, "-Dproject-export={s}", .{export_directory});
        args[7] = "-j2";
        args[8] = "--cache-dir";
        args[cache_dir_arg] = try std.fs.path.join(a, &.{ install_directory, "local-cache" });
        args[10] = "-p";
        args[11] = try a.dupe(u8, install_directory);
        if (development_firmware) |path| {
            // Zig 0.17 needs a relative --fork for local package dependencies.
            // Canonicalize both paths so symlinked checkout spellings agree with
            // the process cwd. Source ownership is checked by the caller.
            var threaded = std.Io.Threaded.init(gpa, .{});
            defer threaded.deinit();
            const io = threaded.io();
            owned_cwd = try std.Io.Dir.realPathFileAbsoluteAlloc(io, repository, a);
            const canonical_firmware = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, a);
            const relative = try std.fs.path.relativeAlloc(a, owned_cwd, null, owned_cwd, canonical_firmware);
            if (std.fs.path.isAbsolute(relative)) return error.InvalidBuildPath;
            args[12] = "--fork";
            args[13] = relative;
        }
        const owned_path = try std.fs.path.join(a, &.{ install_directory, "firmware", "project.uf2" });
        return .{
            .arena = arena,
            .argv = args,
            .cwd = owned_cwd,
            .uf2_path = owned_path,
            .build_key = key(input),
        };
    }

    pub fn deinit(self: *Command) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Completion = enum { succeeded, failed, cancelled };
pub const AuditMode = enum { deep, fast_prepared_inputs_no_fresh_full_provenance_audit, bundled };

pub const Record = struct {
    version: u32,
    audit_mode: ?AuditMode = null,
    inputs: Inputs,
    build_key: Digest,
    uf2_path: []const u8,
    uf2_size: usize,
    uf2_hash: Digest,
};

/// An owned frozen value: it never aliases editable input strings. A failed or
/// cancelled job cannot manufacture a manifest around an earlier UF2 file.
pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    version: u32 = 2,
    audit_mode: AuditMode = .deep,
    inputs: Inputs,
    build_key: Digest,
    uf2_path: []const u8,
    uf2_size: usize,
    uf2_hash: Digest,

    pub fn complete(
        gpa: std.mem.Allocator,
        completion: Completion,
        prepared_key: Digest,
        captured: Inputs,
        current: Inputs,
        path: []const u8,
        bytes: []const u8,
    ) !Manifest {
        switch (completion) {
            .failed => return error.BuildFailed,
            .cancelled => return error.BuildCancelled,
            .succeeded => {},
        }
        try validateInputs(captured);
        if (!std.mem.eql(u8, &prepared_key, &key(captured)) or
            !std.mem.eql(u8, &prepared_key, &key(current))) return error.StaleBuild;
        if (!std.fs.path.isAbsolute(path) or
            std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArtifactPath;
        try uf2.validate(gpa, bytes);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var owned = captured;
        owned.lock.firmware_repository = try a.dupe(u8, captured.lock.firmware_repository);
        owned.lock.firmware_revision = try a.dupe(u8, captured.lock.firmware_revision);
        owned.lock.board = try a.dupe(u8, captured.lock.board);
        owned.lock.zig_version = try a.dupe(u8, captured.lock.zig_version);
        owned.lock.target = try a.dupe(u8, captured.lock.target);
        owned.lock.optimize = try a.dupe(u8, captured.lock.optimize);
        const owned_path = try a.dupe(u8, path);
        return .{
            .arena = arena,
            .inputs = owned,
            .build_key = prepared_key,
            .uf2_path = owned_path,
            .uf2_size = bytes.len,
            .uf2_hash = digest(bytes),
        };
    }

    pub fn fresh(self: Manifest, current: Inputs) bool {
        return std.mem.eql(u8, &self.build_key, &key(current));
    }

    /// Persist this versioned record beside the UF2. Filesystem ownership and
    /// atomic replacement stay with the caller, never with the build process.
    pub fn serialize(self: Manifest, gpa: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try std.zon.stringify.serializeMaxDepth(.{
            .version = self.version,
            .audit_mode = self.audit_mode,
            .inputs = self.inputs,
            .build_key = self.build_key,
            .uf2_path = self.uf2_path,
            .uf2_size = self.uf2_size,
            .uf2_hash = self.uf2_hash,
        }, .{}, &out.writer, 32);
        return out.toOwnedSlice();
    }

    /// Loading provenance is read-only and never starts a job or a transfer.
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Manifest {
        if (bytes.len > 32 * 1024) return error.ManifestTooLarge;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const text = try a.dupeSentinel(u8, bytes, 0);
        const record = try @import("owned-zon").parse(Record, a, text);
        if (record.version != 2) return error.UnsupportedManifestVersion;
        // Legacy v2 records without this field were produced by deep audits.
        try validateInputs(record.inputs);
        if (!std.mem.eql(u8, &record.build_key, &key(record.inputs))) return error.ManifestKeyMismatch;
        if (!std.fs.path.isAbsolute(record.uf2_path) or
            std.mem.indexOfScalar(u8, record.uf2_path, 0) != null) return error.InvalidArtifactPath;
        if (record.uf2_size == 0 or
            record.uf2_size % 512 != 0 or
            record.uf2_size > 4 * 1024 * 1024) return error.InvalidUf2Length;
        return .{
            .arena = arena,
            .version = record.version,
            .audit_mode = record.audit_mode orelse .deep,
            .inputs = record.inputs,
            .build_key = record.build_key,
            .uf2_path = record.uf2_path,
            .uf2_size = record.uf2_size,
            .uf2_hash = record.uf2_hash,
        };
    }

    /// Re-read the exact recorded path through the caller's filesystem adapter
    /// and check these bytes immediately before offering a transfer.
    pub fn verify(self: Manifest, gpa: std.mem.Allocator, current: Inputs, bytes: []const u8) !void {
        if (!self.fresh(current)) return error.StaleBuild;
        if (bytes.len != self.uf2_size or
            !std.mem.eql(u8, &self.uf2_hash, &digest(bytes))) return error.ArtifactChanged;
        try uf2.validate(gpa, bytes);
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn fixture() [512]u8 {
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
    return bytes;
}

fn inputs() Inputs {
    return .{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .lock = target_lock.fixture(),
        .profile_id = @splat(5),
        .identity_digest = @splat(6),
    };
}

fn publishedInputs() Inputs {
    var result = inputs();
    result.lock.source_kind = .published;
    return result;
}

test "firmware argv preserves literal metacharacters and selects build only" {
    var command = try Command.init(
        std.testing.allocator,
        publishedInputs(),
        "/compiler with spaces/zig",
        "/repo",
        "/export ; $(touch nope)",
        "/cache ; output",
        null,
    );
    defer command.deinit();
    try std.testing.expectEqualStrings("-Dproject-export=/export ; $(touch nope)", command.argv[6]);
    try std.testing.expectEqualStrings("/cache ; output", command.argv[11]);
    const expected_uf2 = if (@import("builtin").os.tag == .windows)
        "/cache ; output\\firmware\\project.uf2"
    else
        "/cache ; output/firmware/project.uf2";
    try std.testing.expectEqualStrings(expected_uf2, command.uf2_path);
    try std.testing.expectEqual(@as(usize, 12), command.argv.len);
    try std.testing.expectError(
        error.InvalidBuildPath,
        Command.init(std.testing.allocator, inputs(), "zig", "/repo", "/export", "/cache", "/firmware"),
    );
    try std.testing.expectError(
        error.FirmwareOverrideMismatch,
        Command.init(std.testing.allocator, inputs(), "/zig", "/repo", "/export", "/cache", null),
    );
}

test "development fork canonicalizes symlinked cwd and sibling with spaces" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(io, "companion checkout", .default_dir);
    try temp.dir.createDir(io, "firmware checkout", .default_dir);
    try temp.dir.symLink(io, "companion checkout", "companion link", .{ .is_directory = true });
    const root = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const repo = try std.fs.path.join(a, &.{ root, "companion link" });
    defer a.free(repo);
    const firmware = try std.fs.path.join(a, &.{ root, "firmware checkout" });
    defer a.free(firmware);
    var command = try Command.init(a, inputs(), "/zig", repo, "/export", "/cache", firmware);
    defer command.deinit();
    const canonical_repo = try std.Io.Dir.realPathFileAbsoluteAlloc(io, repo, a);
    defer a.free(canonical_repo);
    try std.testing.expectEqualStrings(canonical_repo, command.cwd);
    try std.testing.expectEqualStrings("--fork", command.argv[12]);
    const expected_fork = if (@import("builtin").os.tag == .windows) "..\\firmware checkout" else "../firmware checkout";
    try std.testing.expectEqualStrings(expected_fork, command.argv[13]);
}

test "manifest rejects failures cancellation stale input and corrupt artifact" {
    const a = std.testing.allocator;
    const captured = inputs();
    var bytes = fixture();
    try std.testing.expectError(
        error.BuildFailed,
        Manifest.complete(a, .failed, key(captured), captured, captured, "/cache/firmware.uf2", &bytes),
    );
    try std.testing.expectError(
        error.BuildCancelled,
        Manifest.complete(a, .cancelled, key(captured), captured, captured, "/cache/firmware.uf2", &bytes),
    );
    var current = captured;
    current.source_digest[0] ^= 1;
    try std.testing.expectError(
        error.StaleBuild,
        Manifest.complete(a, .succeeded, key(captured), captured, current, "/cache/firmware.uf2", &bytes),
    );
    var manifest = try Manifest.complete(
        a,
        .succeeded,
        key(captured),
        captured,
        captured,
        "/cache/firmware.uf2",
        &bytes,
    );
    defer manifest.deinit();
    const record = try manifest.serialize(a);
    defer a.free(record);
    try std.testing.expect(std.mem.indexOf(u8, record, "compiler_digest") != null);
    var restored = try Manifest.parse(a, record);
    defer restored.deinit();
    try restored.verify(a, captured, &bytes);
    try manifest.verify(a, captured, &bytes);
    try std.testing.expectError(error.StaleBuild, manifest.verify(a, current, &bytes));
    bytes[32] ^= 1;
    try std.testing.expectError(error.ArtifactChanged, manifest.verify(a, captured, &bytes));
    bytes[0] = 0;
    try std.testing.expectError(
        error.InvalidUf2Magic,
        Manifest.complete(a, .succeeded, key(captured), captured, captured, "/cache/firmware.uf2", &bytes),
    );
}

test "every compiler build project identity input invalidates manifests" {
    const original = inputs();
    inline for (.{
        "project_digest",
        "source_digest",
        "build_inputs_digest",
        "profile_id",
        "identity_digest",
    }) |name| {
        var changed = original;
        @field(changed, name)[0] ^= 1;
        try std.testing.expect(!std.mem.eql(u8, &key(original), &key(changed)));
    }
    var changed = original;
    changed.lock.compiler_digest[0] ^= 1;
    try std.testing.expect(!std.mem.eql(u8, &key(original), &key(changed)));
}

test "manifest freezes provenance and rejects an unpinned compiler" {
    const a = std.testing.allocator;
    var revision = "57497457ec77947426cbc5c6468c92e1a2e0506f".*;
    var captured = inputs();
    captured.lock.firmware_revision = &revision;
    const bytes = fixture();
    var manifest = try Manifest.complete(
        a,
        .succeeded,
        key(captured),
        captured,
        captured,
        "/cache/firmware.uf2",
        &bytes,
    );
    defer manifest.deinit();
    revision[0] = 'a';
    try std.testing.expectEqualStrings(
        "57497457ec77947426cbc5c6468c92e1a2e0506f",
        manifest.inputs.lock.firmware_revision,
    );
    try std.testing.expect(!manifest.fresh(captured));
    captured.lock.zig_version = "0.15.2";
    try std.testing.expectError(
        error.UnsupportedCompilerVersion,
        Command.init(a, captured, "/zig", "/repo", "/export", "/cache", "/firmware"),
    );
}
