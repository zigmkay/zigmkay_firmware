//! Hardware-free acceptance of keyboard grouping, layout transfer and the
//! layout operations behind My Keyboards and the editor head.
const std = @import("std");
const desktop = @import("desktop-core");
const p = @import("project");
const library = desktop.library;
const boards = desktop.onboarding.boards;

test "layouts group by hardware in place and unreadable projects stay untouched" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var qwerty = try p.profiles.create(t.allocator, .qwerty);
    defer qwerty.deinit();
    var eurmac = try p.profiles.create(t.allocator, .eurmac);
    defer eurmac.deinit();
    var molekula_board = try boards.OwnedBoard.init(t.allocator, "molekula");
    defer molekula_board.deinit();
    var molekula = try boards.createDefault(t.allocator, molekula_board);
    defer molekula.deinit();
    const Project = struct { path: []const u8, snapshot: p.snapshot.Snapshot, board: p.Board };
    const projects = [_]Project{
        .{ .path = "My Keyboards/keyboards/desk", .snapshot = qwerty.snapshot, .board = p.profiles.board },
        .{ .path = "My Keyboards/keyboards/travel", .snapshot = molekula.snapshot, .board = molekula_board.board },
        .{ .path = "eurmac", .snapshot = eurmac.snapshot, .board = p.profiles.board },
    };
    for (projects) |project| {
        var dir = try tmp.dir.createDirPathOpen(t.io, project.path, .{});
        defer dir.close(t.io);
        try p.snapshot.save(t.allocator, t.io, dir, project.snapshot, project.board);
    }
    var collection = try tmp.dir.openDir(t.io, "My Keyboards", .{});
    defer collection.close(t.io);
    try p.collection.save(t.allocator, t.io, collection, .{ .projects = &.{
        .{ .id = "desk", .directory = "keyboards/desk" },
        .{ .id = "travel", .directory = "keyboards/travel" },
    } }, null);
    const broken = "opaque personal bytes\n";
    var corrupt = try tmp.dir.createDirPathOpen(t.io, "corrupt", .{});
    defer corrupt.close(t.io);
    try corrupt.writeFile(t.io, .{ .sub_path = "project.zon", .data = broken });
    const collection_path = try std.fs.path.join(t.allocator, &.{ root, "My Keyboards" });
    defer t.allocator.free(collection_path);
    const desk = try std.fs.path.join(t.allocator, &.{ collection_path, "keyboards/desk" });
    defer t.allocator.free(desk);
    var loaded = try library.load(t.allocator, t.io, .{ .collection = collection_path, .projects = root, .extra = &.{desk} });
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 3), loaded.layouts.len);
    try t.expectEqual(@as(usize, 2), loaded.keyboards.len);
    try t.expectEqual(@as(usize, 2), loaded.keyboards[0].layouts.len);
    try t.expectEqualStrings("keyboards/desk", loaded.layouts[loaded.find(desk).?].member.?);
    const legacy = loaded.layouts[loaded.keyboards[0].layouts[1]];
    try t.expect(legacy.member == null);
    try t.expectEqualStrings("EurKEY Next Mac candidate", legacy.name);
    try t.expectEqualStrings("Q", loaded.layouts[0].base[0]);
    try t.expectEqualStrings("molekula", loaded.layouts[loaded.keyboards[1].layouts[0]].entry.selector);
    try t.expectEqual(@as(usize, 1), loaded.unreadable.len);
    const preserved = try corrupt.readFileAlloc(t.io, "project.zon", t.allocator, .limited(4096));
    defer t.allocator.free(preserved);
    try t.expectEqualStrings(broken, preserved);
}

test "relative ages read naturally" {
    var buffer: [32]u8 = undefined;
    const minute = 60 * std.time.ns_per_s;
    try std.testing.expectEqualStrings("just now", library.age(&buffer, minute / 2, 0));
    try std.testing.expectEqualStrings("2 min ago", library.age(&buffer, 2 * minute, 0));
    try std.testing.expectEqualStrings("yesterday", library.age(&buffer, 30 * 60 * minute, 0));
    try std.testing.expectEqualStrings("3 weeks ago", library.age(&buffer, 21 * 24 * 60 * minute, 0));
}

test "renaming a layout is one undoable edit and refuses empty names" {
    const t = std.testing;
    var template = try p.profiles.create(t.allocator, .eurmac);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, p.profiles.board, template.snapshot);
    defer model.deinit();
    var owner = try desktop.editor_dispatch.State.init(&model);
    defer owner.deinit();
    var name: [129]u8 = @splat(0);
    @memcpy(name[0.."EurKEY Next Mac".len], "EurKEY Next Mac");
    const request = try desktop.editor_dispatch.Request.capture(&model, .{ .rename_layout = name });
    try t.expect(try owner.request(&model, request) == .none);
    try t.expectEqualStrings("EurKEY Next Mac", model.document().name);
    try t.expect(model.dirty());
    try model.undo();
    try t.expectEqualStrings("EurKEY Next Mac candidate", model.document().name);
    const empty = try desktop.editor_dispatch.Request.capture(&model, .{ .rename_layout = @splat(0) });
    try t.expectError(error.InvalidName, owner.request(&model, empty));
}

const new_layout = desktop.new_layout;
const transfer = new_layout.transfer;

test "a layout moves between revisions by key index and reports what drops" {
    const t = std.testing;
    var eurmac = try p.profiles.create(t.allocator, .eurmac);
    defer eurmac.deinit();
    var small = try boards.OwnedBoard.init(t.allocator, "keycaprio_colemak_0_4");
    defer small.deinit();
    var moved = try transfer.transfer(t.allocator, eurmac.snapshot, small.board);
    defer moved.deinit();
    const report = moved.report;
    try t.expectEqual(transfer.Match.key_index, report.match);
    try t.expectEqual(@as(usize, 34), report.source_keys);
    try t.expectEqual(@as(usize, 30), report.matched);
    try t.expectEqual(@as(usize, 4), report.missingCount());
    try t.expect(report.missing[33] and !report.missing[0]);
    try t.expect(!report.exact());
    try t.expectEqual(eurmac.snapshot.document.layers.len, moved.snapshot.document.layers.len);
    try t.expect(std.meta.eql(eurmac.snapshot.document.layers[0].actions[0], moved.snapshot.document.layers[0].actions[0]));
    try t.expectEqualStrings(small.board.key_ids[0], moved.snapshot.document.combos[0].key_ids[0]);
    try p.snapshot.validate(moved.snapshot, small.board);
}

test "revisions with the same key count match exactly and keep callbacks" {
    const t = std.testing;
    var older = try boards.OwnedBoard.init(t.allocator, "keycaprio_colemak_0_6");
    defer older.deinit();
    var newer = try boards.OwnedBoard.init(t.allocator, "keycaprio_colemak_0_7");
    defer newer.deinit();
    var original = try boards.createDefault(t.allocator, older);
    defer original.deinit();
    var moved = try transfer.transfer(t.allocator, original.snapshot, newer.board);
    defer moved.deinit();
    try t.expectEqual(transfer.Match.key_index, moved.report.match);
    try t.expect(moved.report.exact());
    try t.expectEqual(original.snapshot.document.callbacks.len, moved.snapshot.document.callbacks.len);
    try t.expectEqual(original.snapshot.sources.len, moved.snapshot.sources.len);
}

test "new layouts start from templates, blank or a copy without touching the original" {
    const t = std.testing;
    const lk7 = desktop.library.catalog.find("lk7").?;
    var buffer: new_layout.Templates = undefined;
    // PCB 0.7 offers the built-in LK7 layouts first, then the contributed
    // firmware defaults of the same revision.
    const lk7_templates = new_layout.templates(lk7, &buffer);
    try t.expectEqual(@as(usize, 6), lk7_templates.len);
    try t.expectEqualStrings("Rollercole · default", lk7_templates[0].label);
    try t.expectEqualStrings("Colemak", lk7_templates[4].label);
    try t.expectEqualStrings("US International", lk7_templates[5].label);
    var eurmac = try new_layout.prepare(t.allocator, t.io, lk7, .{ .template = lk7_templates[3] });
    defer eurmac.deinit();
    try t.expectEqualStrings("lk7_schematic_v1", eurmac.snapshot.document.physical_layout);
    try t.expectEqualStrings("Q", eurmac.captions[0][0]);
    const keycaprio = desktop.library.catalog.find("keycaprio_colemak_0_7").?;
    try t.expectEqual(@as(usize, 6), new_layout.templates(keycaprio, &buffer).len);
    var blank = try new_layout.prepare(t.allocator, t.io, keycaprio, .blank);
    defer blank.deinit();
    try t.expectEqual(@as(usize, 1), blank.snapshot.document.layers.len);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try p.snapshot.save(t.allocator, t.io, tmp.dir, eurmac.snapshot, eurmac.board.board);
    const before = try tmp.dir.readFileAlloc(t.io, "project.zon", t.allocator, .limited(p.Limits.document_bytes));
    defer t.allocator.free(before);
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var same = try new_layout.prepare(t.allocator, t.io, lk7, .{ .duplicate = path });
    defer same.deinit();
    try t.expect(same.report == null);
    const small = desktop.library.catalog.find("keycaprio_colemak_0_4").?;
    var moved = try new_layout.prepare(t.allocator, t.io, small, .{ .duplicate = path });
    defer moved.deinit();
    try t.expectEqual(@as(usize, 4), moved.report.?.missingCount());
    const after = try tmp.dir.readFileAlloc(t.io, "project.zon", t.allocator, .limited(p.Limits.document_bytes));
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
}

test "directory names are readable and unique" {
    const Taken = struct {
        names: []const []const u8,
        pub fn contains(self: @This(), name: []const u8) bool {
            for (self.names) |taken| if (std.mem.eql(u8, taken, name)) return true;
            return false;
        }
    };
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("eurkey-next-mac", new_layout.directoryName(&buffer, "EurKEY Next Mac", Taken{ .names = &.{} }));
    try std.testing.expectEqualStrings("colemak-jan-2", new_layout.directoryName(&buffer, "Colemak (Jan)", Taken{ .names = &.{"colemak-jan"} }));
    try std.testing.expectEqualStrings("layout", new_layout.directoryName(&buffer, "äö", Taken{ .names = &.{} }));
}

/// Typed keymap data as an analysis would return it, from a catalog default.
fn analyzed(selector: []const u8) struct { desktop.onboarding.importer.Data, []const desktop.library.catalog.SourceFile } {
    const defaults = desktop.library.catalog.defaultData(selector).?;
    return .{ .{
        .layers = defaults.layers,
        .combos = defaults.combos,
        .sides = defaults.sides,
        .encoders = defaults.encoder_actions orelse &.{},
        .has_callbacks = defaults.has_callbacks,
    }, defaults.callback_sources };
}

test "an import is compared with the chosen keyboard before anything is created" {
    const t = std.testing;
    const catalog = desktop.library.catalog;
    const data, const sources = analyzed("keycaprio_colemak_0_7");
    var same = try desktop.import_compare.compare(t.allocator, data, sources, catalog.find("keycaprio_colemak_0_7").?);
    defer same.deinit();
    try t.expect(same.report.exact());
    try t.expectEqualStrings("keycaprio_colemak_0_7", same.source_entry.selector);
    var smaller = try desktop.import_compare.compare(t.allocator, data, sources, catalog.find("keycaprio_colemak_0_4").?);
    defer smaller.deinit();
    try t.expectEqual(@as(usize, 34), smaller.report.source_keys);
    try t.expectEqual(@as(usize, 4), smaller.report.missingCount());
    try t.expect(smaller.report.missing[30] and !smaller.report.missing[29]);
    try t.expectEqual(@as(usize, 30), smaller.target_captions.len);
    var lk7 = try desktop.import_compare.compare(t.allocator, data, sources, catalog.find("lk7").?);
    defer lk7.deinit();
    try t.expectEqual(@as(usize, 34), lk7.report.matched);
    try t.expectEqual(desktop.new_layout.transfer.Match.key_index, lk7.report.match);
}

test "curated LK7 layouts match by key ID" {
    const t = std.testing;
    var eurmac = try p.profiles.create(t.allocator, .eurmac);
    defer eurmac.deinit();
    var moved = try transfer.transfer(t.allocator, eurmac.snapshot, p.profiles.board);
    defer moved.deinit();
    try t.expectEqual(transfer.Match.key_id, moved.report.match);
    try t.expect(moved.report.exact());
}

test "a layout copied onto another revision is created, reopened and listed" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var eurmac = try p.profiles.create(t.allocator, .eurmac);
    defer eurmac.deinit();
    var original = try tmp.dir.createDirPathOpen(t.io, "eurmac", .{});
    defer original.close(t.io);
    try p.snapshot.save(t.allocator, t.io, original, eurmac.snapshot, p.profiles.board);
    const source = try std.fs.path.join(t.allocator, &.{ root, "eurmac" });
    defer t.allocator.free(source);
    const small = desktop.library.catalog.find("keycaprio_colemak_0_4").?;
    var candidate = try new_layout.prepare(t.allocator, t.io, small, .{ .duplicate = source });
    defer candidate.deinit();
    var snapshot = candidate.snapshot;
    snapshot.document.name = "EurKEY on 0.4";
    snapshot.document.profile_id = "copy0004".*;
    const collection = try std.fs.path.join(t.allocator, &.{ root, "My Keyboards" });
    defer t.allocator.free(collection);
    const destination = try std.fs.path.join(t.allocator, &.{ collection, "keyboards/eurkey-on-0-4" });
    defer t.allocator.free(destination);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var create = try desktop.onboarding.Request.init(t.allocator, .{
        .operation = .create,
        .prepared = .{ .snapshot = snapshot, .selector = candidate.board.entry.selector },
        .destination = destination,
        .collection = collection,
        .collection_entry = .{ .id = "eurkey-on-0-4", .directory = "keyboards/eurkey-on-0-4" },
        .toolchain = .{ .compiler = "", .build_root = "", .cache = root },
    }, &env, @splat(0));
    defer create.deinit();
    var result = try create.prepare(t.allocator, t.io);
    defer result.deinit();
    try t.expectEqual(@as(usize, 30), result.opened.model.?.document().key_ids.len);
    var loaded = try library.load(t.allocator, t.io, .{ .collection = collection, .projects = root });
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 2), loaded.keyboards.len);
    try t.expectEqualStrings("EurKEY on 0.4", loaded.layouts[0].name);
    try t.expect(loaded.layouts[0].member != null and loaded.layouts[1].member == null);
}
