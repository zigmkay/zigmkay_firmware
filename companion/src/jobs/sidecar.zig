//! Explicit atomic saves to a caller-owned project/cache directory. Callers
//! serialize writers; filesystem atomic replacement does not provide a CAS lock.
const std = @import("std");
const target = @import("target_lock.zig");
const firmware = @import("firmware.zig");
const provenance = @import("build_context.zig");
const runner = @import("runner_artifact.zig");
pub const Replacement = enum { create, replace_supported };
pub const lock_name = "target-lock.zon";
pub const manifest_name = "firmware-manifest.zon";
pub const receipt_name = "bundle-build.zon";
pub const runner_name = "runner-manifest.zon";

fn write(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    comptime kind: enum { lock, manifest, receipt, runner },
    bytes: []const u8,
    replacement: Replacement,
) !void {
    const name = switch (kind) {
        .lock => lock_name,
        .manifest => manifest_name,
        .receipt => receipt_name,
        .runner => runner_name,
    };
    const old = dir.readFileAlloc(io, name, gpa, .limited(32 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (old) |existing| {
        defer gpa.free(existing);
        if (replacement == .create) return error.SidecarAlreadyExists;
        if (kind == .lock) {
            const parsed = try target.parse(gpa, existing);
            defer target.free(gpa, parsed);
        } else if (kind == .manifest) {
            var parsed = try firmware.Manifest.parse(gpa, existing);
            defer parsed.deinit();
        } else if (kind == .runner) {
            var parsed = try runner.Manifest.parse(gpa, existing);
            defer parsed.deinit();
        } else _ = try provenance.Receipt.parse(gpa, existing);
    }
    var atomic = try dir.createFileAtomic(io, name, .{
        .replace = old != null and replacement == .replace_supported,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    if (old != null and replacement == .replace_supported) try atomic.replace(io) else try atomic.link(io);
}

pub fn saveRunner(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    manifest: runner.Manifest,
    replacement: Replacement,
) !void {
    const bytes = try manifest.serialize(gpa);
    defer gpa.free(bytes);
    try write(gpa, io, dir, .runner, bytes, replacement);
}

test "runner sidecar creates supported records and preserves future provenance" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const input = firmware.Inputs{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = @splat(4),
        .identity_digest = @splat(5),
        .lock = target.fixture(),
    };
    var manifest = try runner.Manifest.complete(
        t.allocator,
        .succeeded,
        runner.key(input, runner.native_target),
        input,
        input,
        "/cache/runner",
        "executable",
    );
    defer manifest.deinit();
    try saveRunner(t.allocator, t.io, tmp.dir, manifest, .replace_supported);
    try t.expectError(error.SidecarAlreadyExists, saveRunner(t.allocator, t.io, tmp.dir, manifest, .create));
    try saveRunner(t.allocator, t.io, tmp.dir, manifest, .replace_supported);
    var future = manifest.record;
    future.version = 2;
    var encoded = std.Io.Writer.Allocating.init(t.allocator);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(future, .{}, &encoded.writer, 32);
    try tmp.dir.writeFile(t.io, .{ .sub_path = runner_name, .data = encoded.written() });
    try t.expectError(
        error.UnsupportedRunnerManifest,
        saveRunner(t.allocator, t.io, tmp.dir, manifest, .replace_supported),
    );
    const bytes = try tmp.dir.readFileAlloc(t.io, runner_name, t.allocator, .limited(32 * 1024));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(encoded.written(), bytes);
}

/// Keep bundled-build evidence separate from firmware bytes and project schema.
pub fn saveReceipt(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    receipt: provenance.Receipt,
    replacement: Replacement,
) !void {
    const bytes = try receipt.serialize(gpa);
    defer gpa.free(bytes);
    _ = try provenance.Receipt.parse(gpa, bytes);
    try write(gpa, io, dir, .receipt, bytes, replacement);
}

/// A deliberate target selection saves separately from project.zon. Unsupported
/// or malformed existing locks are preserved until an explicit migration exists.
pub fn saveLock(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    lock: target.Lock,
    replacement: Replacement,
) !void {
    const bytes = try lock.serialize(gpa);
    defer gpa.free(bytes);
    try write(gpa, io, dir, .lock, bytes, replacement);
}

/// Manifest.complete and byte verification must precede artifact promotion.
/// This writes provenance only; it does not copy a UF2 or dispatch a transfer.
pub fn saveManifest(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    manifest: firmware.Manifest,
    replacement: Replacement,
) !void {
    const bytes = try manifest.serialize(gpa);
    defer gpa.free(bytes);
    var validated = try firmware.Manifest.parse(gpa, bytes);
    defer validated.deinit();
    try write(gpa, io, dir, .manifest, bytes, replacement);
}

test "explicit lock sidecar saves preserve future data and project bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "project.zon", .data = "preserved legacy project bytes" });
    var lock = target.fixture();
    try saveLock(gpa, io, tmp.dir, lock, .create);
    try std.testing.expectError(error.SidecarAlreadyExists, saveLock(gpa, io, tmp.dir, lock, .create));
    lock.board = "dasbob";
    try saveLock(gpa, io, tmp.dir, lock, .replace_supported);
    const bytes = try tmp.dir.readFileAlloc(io, lock_name, gpa, .limited(32 * 1024));
    defer gpa.free(bytes);
    const parsed = try target.parse(gpa, bytes);
    defer target.free(gpa, parsed);
    try std.testing.expectEqualStrings("dasbob", parsed.board);
    var future = lock;
    future.version = 3;
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(future, .{}, &encoded.writer, 8);
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = encoded.written() });
    try std.testing.expectError(
        error.UnsupportedLockVersion,
        saveLock(gpa, io, tmp.dir, lock, .replace_supported),
    );
    const retained = try tmp.dir.readFileAlloc(io, lock_name, gpa, .limited(32 * 1024));
    defer gpa.free(retained);
    try std.testing.expectEqualStrings(encoded.written(), retained);
    const project = try tmp.dir.readFileAlloc(io, "project.zon", gpa, .limited(100));
    defer gpa.free(project);
    try std.testing.expectEqualStrings("preserved legacy project bytes", project);
    future.version = 2;
    var missing_origin: std.Io.Writer.Allocating = .init(gpa);
    defer missing_origin.deinit();
    try std.zon.stringify.serializeMaxDepth(future, .{}, &missing_origin.writer, 8);
    try tmp.dir.writeFile(io, .{ .sub_path = lock_name, .data = missing_origin.written() });
    try std.testing.expectError(
        error.MissingCompilerOrigin,
        saveLock(gpa, io, tmp.dir, lock, .replace_supported),
    );
    const opaque_v2 = try tmp.dir.readFileAlloc(io, lock_name, gpa, .limited(32 * 1024));
    defer gpa.free(opaque_v2);
    try std.testing.expectEqualStrings(missing_origin.written(), opaque_v2);
}

test "manifest sidecars reject malformed replacements and preserve existing record" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const inputs: firmware.Inputs = .{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = @splat(4),
        .identity_digest = @splat(5),
        .lock = target.fixture(),
    };
    var uf2: [512]u8 = @splat(0);
    for ([_]struct { usize, u32 }{
        .{ 0, 0x0a324655 },
        .{ 4, 0x9e5d5157 },
        .{ 8, 0x2000 },
        .{ 12, 0x10000000 },
        .{ 16, 256 },
        .{ 24, 1 },
        .{ 28, 0xe48bff56 },
        .{ 508, 0x0ab16f30 },
    }) |word| std.mem.writeInt(u32, uf2[word[0]..][0..4], word[1], .little);
    var manifest = try firmware.Manifest.complete(
        gpa,
        .succeeded,
        firmware.key(inputs),
        inputs,
        inputs,
        "/cache/fixture.uf2",
        &uf2,
    );
    defer manifest.deinit();
    try saveManifest(gpa, io, tmp.dir, manifest, .create);
    manifest.version = 3;
    try std.testing.expectError(
        error.UnsupportedManifestVersion,
        saveManifest(gpa, io, tmp.dir, manifest, .replace_supported),
    );
    manifest.version = 2;
    const bytes = try tmp.dir.readFileAlloc(io, manifest_name, gpa, .limited(32 * 1024));
    defer gpa.free(bytes);
    var restored = try firmware.Manifest.parse(gpa, bytes);
    defer restored.deinit();
    try restored.verify(gpa, inputs, &uf2);
    try tmp.dir.writeFile(io, .{ .sub_path = manifest_name, .data = "preserve unsupported provenance" });
    if (saveManifest(gpa, io, tmp.dir, manifest, .replace_supported)) |_| return error.ExpectedPreservationError else |_| {}
    const retained = try tmp.dir.readFileAlloc(io, manifest_name, gpa, .limited(100));
    defer gpa.free(retained);
    try std.testing.expectEqualStrings("preserve unsupported provenance", retained);
}

test "bundle receipt saves preserve unsupported existing evidence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const receipt: provenance.Receipt = .{
        .lock_digest = @splat(1),
        .bundle_id = @splat(2),
    };
    try saveReceipt(gpa, io, tmp.dir, receipt, .create);
    try std.testing.expectError(error.SidecarAlreadyExists, saveReceipt(gpa, io, tmp.dir, receipt, .create));
    const bytes = try tmp.dir.readFileAlloc(io, receipt_name, gpa, .limited(16 * 1024));
    defer gpa.free(bytes);
    try std.testing.expectEqual(receipt.digest(), (try provenance.Receipt.parse(gpa, bytes)).digest());
    var future = receipt;
    future.version = 3;
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(future, .{}, &encoded.writer, 8);
    try tmp.dir.writeFile(io, .{ .sub_path = receipt_name, .data = encoded.written() });
    try std.testing.expectError(
        error.UnsupportedReceiptVersion,
        saveReceipt(gpa, io, tmp.dir, receipt, .replace_supported),
    );
    const retained = try tmp.dir.readFileAlloc(io, receipt_name, gpa, .limited(16 * 1024));
    defer gpa.free(retained);
    try std.testing.expectEqualStrings(encoded.written(), retained);
}
