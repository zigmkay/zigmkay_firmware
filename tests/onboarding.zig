//! Hardware-free lifecycle acceptance over the same requests used by native UI.
const std = @import("std");
const desktop = @import("desktop-core");
const flow = desktop.onboarding;
const p = @import("project");
test "every catalog selector creates edits saves reopens and exports in a relocated collection" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const root = try std.fs.path.join(t.allocator, &.{ base, "original" });
    defer t.allocator.free(root);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var previous: ?[8]u8 = null;
    for (flow.catalog.entries, 0..) |entry, index| {
        var request = try flow.Request.init(t.allocator, .{ .operation = .prepare, .selector = entry.selector, .name = "Personal profile", .toolchain = .{ .compiler = "", .build_root = "", .cache = base } }, &env, @splat(0));
        defer request.deinit();
        var prepared = try request.prepare(t.allocator, t.io);
        defer prepared.deinit();
        if (previous) |old| try t.expect(!std.mem.eql(u8, &old, &prepared.prepared.project.snapshot.document.profile_id));
        previous = prepared.prepared.project.snapshot.document.profile_id;
        const relative = try std.fmt.allocPrint(t.allocator, "keyboards/{s}", .{entry.selector});
        defer t.allocator.free(relative);
        const destination = try std.fs.path.join(t.allocator, &.{ root, relative });
        defer t.allocator.free(destination);
        var membership: ?p.collection.Loaded = null;
        defer if (membership) |*value| value.deinit();
        if (index != 0) {
            var dir = try std.Io.Dir.cwd().openDir(t.io, root, .{});
            defer dir.close(t.io);
            membership = try p.collection.load(t.allocator, t.io, dir);
        }
        var create = try flow.Request.init(t.allocator, .{ .operation = .create, .prepared = .{ .snapshot = prepared.prepared.project.snapshot, .selector = entry.selector }, .destination = destination, .collection = root, .collection_entry = .{ .id = entry.selector, .directory = relative }, .collection_fingerprint = if (membership) |value| value.fingerprint else null, .toolchain = .{ .compiler = "", .build_root = "", .cache = base } }, &env, @splat(0));
        defer create.deinit();
        var result = try create.prepare(t.allocator, t.io);
        defer result.deinit();
        const model = &result.opened.model.?;
        try model.rename("Editable imported layer name");
        try model.apply(.none);
        var dir = try std.Io.Dir.cwd().openDir(t.io, destination, .{});
        defer dir.close(t.io);
        try model.save(t.io, dir);
        var export_dir = try dir.createDirPathOpen(t.io, "export", .{});
        defer export_dir.close(t.io);
        const exported = try p.exporter.write(t.allocator, t.io, export_dir, model.current.snapshot, model.board);
        defer p.exporter.freeManifest(t.allocator, exported);
        try t.expectEqualStrings("Editable imported layer name", model.document().layers[0].name);
        const host = try flow.importer.hostScancodes(t.allocator, model.document());
        defer t.allocator.free(host);
        try (desktop.host_input.Binding{ .board_id = model.document().board_id, .key_ids = model.document().key_ids, .scancodes = host }).validate(model.document());
    }
    try tmp.dir.renamePreserve("original", tmp.dir, "relocated", t.io);
    const relocated = try std.fs.path.join(t.allocator, &.{ base, "relocated" });
    defer t.allocator.free(relocated);
    var opened = try flow.open(t.allocator, t.io, relocated, null);
    defer opened.deinit();
    try t.expect(opened.collection != null);
    var dir = try tmp.dir.openDir(t.io, "relocated", .{});
    defer dir.close(t.io);
    var collection = try p.collection.load(t.allocator, t.io, dir);
    defer collection.deinit();
    try t.expectEqual(@as(usize, 14), collection.manifest.projects.len);
    for (collection.manifest.projects) |entry| {
        const path = try std.fs.path.join(t.allocator, &.{ relocated, entry.directory });
        defer t.allocator.free(path);
        var child = try flow.open(t.allocator, t.io, path, relocated);
        defer child.deinit();
        try p.sources.verify(t.allocator, child.model.?.current.snapshot);
    }
}
test "cancelling preparation leaves destination absent and portable existing copies preserve standalone data" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var request = try flow.Request.init(t.allocator, .{ .operation = .prepare, .selector = "molekula", .destination = base, .toolchain = .{ .compiler = "", .build_root = "", .cache = base } }, &env, @splat(0));
    const worker = try flow.Worker.create(t.allocator, t.io, &request, 1);
    worker.destroy();
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "project.zon", .{}));
    var template = try p.profiles.create(t.allocator, .danish);
    defer template.deinit();
    var standalone = try tmp.dir.createDirPathOpen(t.io, "standalone", .{});
    defer standalone.close(t.io);
    try p.snapshot.save(t.allocator, t.io, standalone, template.snapshot, p.profiles.board);
    const before = try standalone.readFileAlloc(t.io, "project.zon", t.allocator, .limited(p.Limits.document_bytes));
    defer t.allocator.free(before);
    var workspace = try tmp.dir.createDirPathOpen(t.io, "collection", .{});
    defer workspace.close(t.io);
    try p.collection.save(t.allocator, t.io, workspace, .{}, null);
    var loaded = try p.collection.load(t.allocator, t.io, workspace);
    defer loaded.deinit();
    const root = try std.fs.path.join(t.allocator, &.{ base, "collection" });
    defer t.allocator.free(root);
    const original = try std.fs.path.join(t.allocator, &.{ base, "standalone" });
    defer t.allocator.free(original);
    var empty_workspace = try flow.open(t.allocator, t.io, root, null);
    defer empty_workspace.deinit();
    try t.expect(empty_workspace.model == null and empty_workspace.collection != null);
    var copy = try flow.Request.init(t.allocator, .{ .operation = .add_existing, .location = original, .collection = root, .collection_entry = .{ .id = "desk", .directory = "keyboards/desk" }, .collection_fingerprint = loaded.fingerprint, .toolchain = .{ .compiler = "", .build_root = "", .cache = base } }, &env, @splat(0));
    defer copy.deinit();
    var copied = try copy.prepare(t.allocator, t.io);
    defer copied.deinit();
    try t.expectEqualDeep(template.snapshot.document, copied.opened.model.?.document());
    const after = try standalone.readFileAlloc(t.io, "project.zon", t.allocator, .limited(p.Limits.document_bytes));
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
    try standalone.writeFile(t.io, .{ .sub_path = "project.zon", .data = "Preserved unsupported saved document" });
    if (flow.open(t.allocator, t.io, original, null)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedUnsupportedSavedDocument;
    } else |_| {}
    const broken = try standalone.readFileAlloc(t.io, "project.zon", t.allocator, .limited(p.Limits.document_bytes));
    defer t.allocator.free(broken);
    try t.expectEqualStrings("Preserved unsupported saved document", broken);
    var empty = try flow.open(t.allocator, t.io, root, null);
    defer empty.deinit();
    try t.expect(empty.model != null);
}
