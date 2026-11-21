//! Original callback code is preservation data, never compiled by these tests.
const std = @import("std");
const p = @import("project");
const t = std.testing;
const historical = @embedFile("historical-rollercole-source");
const historical_hash = "9f4dd8dd3900799e4484d1d34851de369b2e3af0cd005f5f4ecceb4ea057a945";

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn historicalSnapshot(kind: @FieldType(p.Callback, "kind")) !p.snapshot.Loaded {
    var template = try p.profiles.create(t.allocator, .danish);
    defer template.deinit();
    var doc = template.snapshot.document;
    var callback = doc.callbacks[0];
    callback.kind = kind;
    callback.binding = if (kind == .registered) "rollercole_v1" else "rollercole.zig";
    callback.sources = &.{.{ .path = "rollercole.zig", .digest = digest(historical) }};
    doc.callbacks = &.{callback};
    return p.snapshot.clone(t.allocator, .{ .document = doc, .sources = &.{.{
        .callback_index = 0,
        .path = "rollercole.zig",
        .bytes = historical,
    }} });
}

test "original 0.16 callback bytes and registered binding survive read save reopen without template upgrade" {
    try t.expectEqualStrings(historical_hash, &std.fmt.bytesToHex(digest(historical), .lower));
    try t.expect(!std.mem.eql(u8, historical, p.profiles.registered_source));
    var saved = try historicalSnapshot(.registered);
    defer saved.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const board = p.profiles.board;
    const original_identity = try p.snapshot.identity(t.allocator, saved.snapshot, board);
    try p.snapshot.save(t.allocator, t.io, tmp.dir, saved.snapshot, board);
    var loaded = try p.snapshot.load(t.allocator, t.io, tmp.dir, board);
    defer loaded.deinit();
    try t.expectEqualStrings(historical, try p.snapshot.find(loaded.snapshot, 0, "rollercole.zig"));
    try t.expectEqualStrings("rollercole_v1", loaded.snapshot.document.callbacks[0].binding);
    try t.expectEqual(
        saved.snapshot.document.callbacks[0].sources[0].digest,
        loaded.snapshot.document.callbacks[0].sources[0].digest,
    );
    try t.expectEqual(
        original_identity.digest,
        (try p.snapshot.identity(t.allocator, loaded.snapshot, board)).digest,
    );
    // A normal metadata edit cannot replace immutable callback bytes.
    t.allocator.free(loaded.snapshot.document.name);
    loaded.snapshot.document.name = try t.allocator.dupe(u8, "Preserved historical callback");
    try p.snapshot.save(t.allocator, t.io, tmp.dir, loaded.snapshot, board);
    var reopened = try p.snapshot.load(t.allocator, t.io, tmp.dir, board);
    defer reopened.deinit();
    try t.expectEqualStrings(historical, try p.snapshot.find(reopened.snapshot, 0, "rollercole.zig"));
    try t.expectEqual(
        original_identity.digest,
        (try p.snapshot.identity(t.allocator, reopened.snapshot, board)).digest,
    );
    try t.expectError(error.UnknownRegisteredCallback, p.profiles.callbackEntry(reopened.snapshot, 0));
    try t.expectError(
        error.UnknownRegisteredCallback,
        p.exporter.generate(t.allocator, reopened.snapshot, board),
    );
    var export_dir = t.tmpDir(.{});
    defer export_dir.cleanup();
    try t.expectError(
        error.UnknownRegisteredCallback,
        p.exporter.write(t.allocator, t.io, export_dir.dir, reopened.snapshot, board),
    );
    try t.expectError(
        error.FileNotFound,
        export_dir.dir.readFileAlloc(t.io, "manifest.zon", t.allocator, .limited(1024)),
    );
}

test "historical source cannot be relabelled as the current registered template" {
    var saved = try historicalSnapshot(.registered);
    defer saved.deinit();
    var callback = saved.snapshot.document.callbacks[0];
    callback.binding = p.profiles.registered_binding;
    var doc = saved.snapshot.document;
    doc.callbacks = &.{callback};
    const relabelled = p.snapshot.Snapshot{ .document = doc, .sources = saved.snapshot.sources };
    try p.snapshot.validate(relabelled, p.profiles.board);
    try t.expectError(error.RegisteredSourceMismatch, p.profiles.callbackEntry(relabelled, 0));
    try t.expectError(
        error.RegisteredSourceMismatch,
        p.exporter.generate(t.allocator, relabelled, p.profiles.board),
    );
}

test "explicit attached historical source export preserves original bytes without claiming compiler compatibility" {
    var saved = try historicalSnapshot(.attached);
    defer saved.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var output = t.tmpDir(.{});
    defer output.cleanup();
    try p.snapshot.save(t.allocator, t.io, tmp.dir, saved.snapshot, p.profiles.board);
    var loaded = try p.snapshot.load(t.allocator, t.io, tmp.dir, p.profiles.board);
    defer loaded.deinit();
    const manifest = try p.exporter.write(t.allocator, t.io, output.dir, loaded.snapshot, p.profiles.board);
    defer p.exporter.freeManifest(t.allocator, manifest);
    try t.expectEqualStrings("callback_0/rollercole.zig", manifest.callbacks[0].entry);
    const bytes = try output.dir.readFileAlloc(
        t.io,
        manifest.callbacks[0].entry,
        t.allocator,
        .limited(p.Limits.source_bytes),
    );
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(historical, bytes);
    try t.expectEqualStrings(historical_hash, &std.fmt.bytesToHex(digest(bytes), .lower));
    // Deterministic re-export never changes the original callback file.
    const again = try p.exporter.write(t.allocator, t.io, output.dir, loaded.snapshot, p.profiles.board);
    defer p.exporter.freeManifest(t.allocator, again);
    try t.expectEqual(manifest.snapshot_id, again.snapshot_id);
}
