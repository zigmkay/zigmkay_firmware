const std = @import("std");
const p = @import("root.zig");

const board = p.Board{
    .id = .{ 'l', 'k', '7', 0, 0, 0, 0, 0 },
    .physical_layout = "fixture",
    .key_ids = &.{ "left_0", "right_0" },
    .sides = &.{ .L, .R },
};

const fixture = p.Document{
    .schema_version = 1,
    .board_id = board.id,
    .profile_id = .{ 't', 'e', 's', 't', 0, 0, 0, 0 },
    .physical_layout = "fixture",
    .name = "Test",
    .key_ids = board.key_ids,
    .layers = &.{
        .{ .id = 10, .name = "Base", .actions = &.{ .{ .tap_hold = .{
            .tap = .{
                .key_press = .{ .tap_keycode = 4, .tap_modifiers = .{ .left_gui = true }, .dead = true },
                .one_shot = .{ .layer_id = 20 },
                .custom = 253,
                .media_key = .VolumeUp,
                .mouse_action = .WheelDown,
            },
            .hold = .{ .layer_id = 20, .hold_modifiers = .{ .right_alt = true } },
            .tapping_term = .{ .ms = 180 },
            .retro_tapping = true,
        } }, null } },
        .{ .id = 20, .name = "Navigation", .actions = &.{ .none, .{ .tap_with_autofire = .{
            .tap = .{ .key_press = .{ .tap_keycode = 80 } },
            .initial_delay = .{ .ms = 200 },
            .repeat_interval = .{ .ms = 50 },
        } } } },
    },
    .combos = &.{.{
        .key_ids = .{ "left_0", "right_0" },
        .layer_id = 10,
        .timeout = .{ .ms = 40 },
        .action = .{ .tap_only = .{ .key_press = .{ .tap_keycode = 252 } } },
    }},
};

test "typed ZON round trip preserves simultaneous tap fields transparency and explicit none" {
    const gpa = std.testing.allocator;
    try p.validate(fixture, board);
    const bytes = try p.serialize(gpa, fixture);
    defer gpa.free(bytes);
    const doc = try p.parse(gpa, bytes, null);
    defer p.deinit(gpa, doc);
    try p.validate(doc, board);
    const second = try p.serialize(gpa, doc);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(bytes, second);
    try std.testing.expect(doc.layers[0].actions[1] == null);
    try std.testing.expect(doc.layers[1].actions[0].? == .none);
    const lowered = try p.lowerAction(doc, doc.layers[0].actions[0].?);
    try std.testing.expectEqual(@as(?u4, 1), lowered.tap_hold.hold.hold_layer);
    try std.testing.expectEqual(@as(?u4, 1), lowered.tap_hold.tap.one_shot.?.hold_layer);
    try std.testing.expectEqual(@as(u8, 8), lowered.tap_hold.tap.key_press.?.tap_modifiers.toByte());
    try std.testing.expect(lowered.tap_hold.tap.key_press.?.dead);
    try std.testing.expect(lowered.tap_hold.retro_tapping);
    try std.testing.expectEqual(@as(?u8, 253), lowered.tap_hold.tap.custom);
    try std.testing.expectEqual(.VolumeUp, lowered.tap_hold.tap.media_key.?);
    try std.testing.expectEqual(.WheelDown, lowered.tap_hold.tap.mouse_action.?);
}

test "parser rejects executable syntax unknown fields and unsupported versions" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.ParseZon, p.parse(gpa, "@import(\"malicious.zig\")", null));
    const bytes = try p.serialize(gpa, fixture);
    defer gpa.free(bytes);
    const invalid = try std.fmt.allocPrint(gpa, ".{{ .unknown = true, {s}", .{bytes[2..]});
    defer gpa.free(invalid);
    try std.testing.expectError(error.ParseZon, p.parse(gpa, invalid, null));
    var future = fixture;
    future.schema_version = 2;
    const future_bytes = try p.serialize(gpa, future);
    defer gpa.free(future_bytes);
    try std.testing.expectError(error.UnsupportedVersion, p.parse(gpa, future_bytes, null));
    const huge = try gpa.alloc(u8, p.Limits.document_bytes + 1);
    defer gpa.free(huge);
    try std.testing.expectError(error.DocumentTooLarge, p.parse(gpa, huge, null));
}

test "validation rejects wrong geometry duplicate layers and reversed duplicate combos" {
    var doc = fixture;
    doc.physical_layout = "wrong";
    try std.testing.expectError(error.InvalidBoard, p.validate(doc, board));
    doc = fixture;
    var layers = fixture.layers[0..2].*;
    layers[1].id = 10;
    doc.layers = &layers;
    try std.testing.expectError(error.DuplicateLayer, p.validate(doc, board));
    doc = fixture;
    var combos = [_]p.Combo{ fixture.combos[0], fixture.combos[0] };
    combos[1].key_ids = .{ "right_0", "left_0" };
    doc.combos = &combos;
    try std.testing.expectError(error.DuplicateCombo, p.validate(doc, board));
}

test "stable layer references and opaque callback index constraints prevent unsafe deletion" {
    try std.testing.expectError(error.LayerReferenced, p.canDeleteLayer(fixture, 20));
    var doc = fixture;
    doc.layers = &.{
        fixture.layers[1],
        .{ .id = 30, .name = "Unused", .actions = &.{ null, null } },
        .{ .id = 40, .name = "Last", .actions = &.{ null, null } },
    };
    try p.canDeleteLayer(doc, 30);
    doc.callbacks = &.{.{
        .kind = .attached,
        .binding = "callback.zig",
        .ids = &.{1},
        .sources = &.{.{ .path = "callback.zig", .digest = @splat(0) }},
    }};
    try std.testing.expectError(error.CallbackIndexLocked, p.canDeleteLayer(doc, 30));
    try p.canDeleteLayer(doc, 40);
}

test "paths custom IDs and timing fail without discarding action fields" {
    for ([_][]const u8{
        "../escape.zig",
        "/absolute.zig",
        "a//b.zig",
        "a/./b.zig",
        "a\\b.zig",
        "bad:drive.zig",
    }) |path| try std.testing.expect(!p.pathValid(path));
    try std.testing.expect(p.pathValid("helpers/util.zig"));
    try std.testing.expectError(error.InvalidCallback, p.lowerTap(fixture, .{ .custom = 1 }));
    try std.testing.expectError(error.InvalidCallback, p.lowerHold(fixture, .{ .custom = 1 }));
    for (253..256) |id| {
        const lowered = try p.lowerHold(fixture, .{ .custom = @intCast(id) });
        try std.testing.expectEqual(@as(?u8, @intCast(id)), lowered.custom);
    }
    try std.testing.expectError(error.InvalidTiming, p.lowerAction(fixture, .{ .tap_with_autofire = .{
        .tap = .{},
        .initial_delay = .{},
        .repeat_interval = .{},
    } }));
    try std.testing.expectError(error.InvalidLayer, p.lowerHold(fixture, .{ .layer_id = 999 }));
}

fn withCallback() p.Document {
    var doc = fixture;
    doc.callbacks = &.{.{
        .kind = .attached,
        .binding = "callback.zig",
        .ids = &.{1},
        .required_layers = &.{20},
        .sources = &.{.{ .path = "callback.zig", .digest = comptime sourceDigest("// opaque callback\n") }},
    }};
    return doc;
}

fn sourceDigest(bytes: []const u8) [32]u8 {
    @setEvalBranchQuota(10000);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

test "legacy registered binding and opaque bytes survive save without template upgrade" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var document = withCallback();
    var callbacks = [_]p.Callback{document.callbacks[0]};
    callbacks[0].kind = .registered;
    callbacks[0].binding = "rollercole_v1";
    document.callbacks = &callbacks;
    const snapshot = p.snapshot.Snapshot{ .document = document, .sources = &.{.{
        .callback_index = 0,
        .path = "callback.zig",
        .bytes = "// opaque callback\n",
    }} };
    try p.snapshot.save(std.testing.allocator, std.testing.io, tmp.dir, snapshot, board);
    var loaded = try p.snapshot.load(std.testing.allocator, std.testing.io, tmp.dir, board);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("rollercole_v1", loaded.snapshot.document.callbacks[0].binding);
    try std.testing.expectEqualStrings(snapshot.sources[0].bytes, loaded.snapshot.sources[0].bytes);
    try std.testing.expectError(
        error.UnknownRegisteredCallback,
        p.profiles.callbackEntry(loaded.snapshot, 0),
    );
}

test "atomic save reopen retains opaque callback bytes and prior snapshot on rejected save" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const snapshot = p.snapshot.Snapshot{ .document = withCallback(), .sources = &.{.{
        .callback_index = 0,
        .path = "callback.zig",
        .bytes = "// opaque callback\n",
    }} };
    try p.snapshot.save(gpa, io, tmp.dir, snapshot, board);
    var loaded = try p.snapshot.load(gpa, io, tmp.dir, board);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(snapshot.sources[0].bytes, loaded.snapshot.sources[0].bytes);
    const original = try tmp.dir.readFileAlloc(io, "project.zon", gpa, .limited(p.Limits.document_bytes));
    defer gpa.free(original);
    var rejected = snapshot;
    rejected.sources = &.{.{
        .callback_index = 0,
        .path = "callback.zig",
        .bytes = "// changed externally\n",
    }};
    try std.testing.expectError(error.SourceMismatch, p.snapshot.save(gpa, io, tmp.dir, rejected, board));
    const unchanged = try tmp.dir.readFileAlloc(io, "project.zon", gpa, .limited(p.Limits.document_bytes));
    defer gpa.free(unchanged);
    try std.testing.expectEqualStrings(original, unchanged);
    // A corrupted existing immutable bundle cannot be silently overwritten.
    const path = try p.snapshot.sourceLocation(gpa, snapshot.document.callbacks[0], "callback.zig");
    defer gpa.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "corrupted" });
    try std.testing.expectError(error.SourceMismatch, p.snapshot.save(gpa, io, tmp.dir, snapshot, board));
    try std.testing.expectError(error.SourceMismatch, p.snapshot.load(gpa, io, tmp.dir, board));
}

test "callback source identity invalidates prepared results while layer rename is metadata only" {
    const gpa = std.testing.allocator;
    const original = p.snapshot.Snapshot{ .document = withCallback(), .sources = &.{.{
        .callback_index = 0,
        .path = "callback.zig",
        .bytes = "// opaque callback\n",
    }} };
    const identity = try p.snapshot.identity(gpa, original, board);
    const digest = try p.snapshot.projectDigest(gpa, original, board);
    var renamed = original;
    var layers = fixture.layers[0..2].*;
    layers[1].name = "Renamed";
    renamed.document.layers = &layers;
    try std.testing.expectEqual(identity.digest, (try p.snapshot.identity(gpa, renamed, board)).digest);
    try std.testing.expect(!std.mem.eql(u8, &digest, &(try p.snapshot.projectDigest(gpa, renamed, board))));
    var edited = original;
    var callbacks = original.document.callbacks[0..1].*;
    const sources = [_]p.Source{.{ .path = "callback.zig", .digest = sourceDigest("// changed callback\n") }};
    callbacks[0].sources = &sources;
    edited.document.callbacks = &callbacks;
    edited.sources = &.{.{ .callback_index = 0, .path = "callback.zig", .bytes = "// changed callback\n" }};
    try std.testing.expect(
        !std.mem.eql(u8, &identity.digest, &(try p.snapshot.identity(gpa, edited, board)).digest),
    );
}

test "source inventory refuses missing extra duplicate and excessive callback bytes" {
    const gpa = std.testing.allocator;
    var snapshot = p.snapshot.Snapshot{ .document = withCallback(), .sources = &.{} };
    try std.testing.expectError(error.MissingSource, p.snapshot.validate(snapshot, board));
    const source = p.snapshot.SourceBytes{
        .callback_index = 0,
        .path = "callback.zig",
        .bytes = "// opaque callback\n",
    };
    snapshot.sources = &.{ source, source };
    try std.testing.expectError(error.UnexpectedSource, p.snapshot.validate(snapshot, board));
    const huge = try gpa.alloc(u8, p.Limits.source_bytes + 1);
    defer gpa.free(huge);
    snapshot.sources = &.{.{ .callback_index = 0, .path = "callback.zig", .bytes = huge }};
    try std.testing.expectError(error.SourceLimit, p.snapshot.validate(snapshot, board));
}

test "source filesystem failure leaves the previous saved project readable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try p.snapshot.save(gpa, io, tmp.dir, .{ .document = fixture, .sources = &.{} }, board);
    try tmp.dir.writeFile(io, .{ .sub_path = ".sources", .data = "not a directory" });
    const replacement = p.snapshot.Snapshot{ .document = withCallback(), .sources = &.{.{
        .callback_index = 0,
        .path = "callback.zig",
        .bytes = "// opaque callback\n",
    }} };
    if (p.snapshot.save(gpa, io, tmp.dir, replacement, board)) |_| {
        return error.ExpectedSaveFailure;
    } else |_| {}
    var loaded = try p.snapshot.load(gpa, io, tmp.dir, board);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.snapshot.document.callbacks.len);
    try std.testing.expectEqualStrings("Test", loaded.snapshot.document.name);
}

test "atomic document replacement commits new metadata and reuses unchanged sources" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var snapshot = p.snapshot.Snapshot{ .document = withCallback(), .sources = &.{.{
        .callback_index = 0,
        .path = "callback.zig",
        .bytes = "// opaque callback\n",
    }} };
    try p.snapshot.save(gpa, io, tmp.dir, snapshot, board);
    snapshot.document.name = "Saved again";
    try p.snapshot.save(gpa, io, tmp.dir, snapshot, board);
    var loaded = try p.snapshot.load(gpa, io, tmp.dir, board);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("Saved again", loaded.snapshot.document.name);
    try std.testing.expectEqualStrings("// opaque callback\n", loaded.snapshot.sources[0].bytes);
}

test "Zig export is deterministic preserves compound fields and keeps metadata out of code" {
    const gpa = std.testing.allocator;
    const snapshot = p.snapshot.Snapshot{ .document = fixture, .sources = &.{} };
    const first = try p.exporter.generate(gpa, snapshot, board);
    defer gpa.free(first);
    const second = try p.exporter.generate(gpa, snapshot, board);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
    for ([_][]const u8{
        "pub const key_count = 2;",   ".tap_keycode=4",       ".left_gui=true",           ".right_alt=true",
        ".dead=true",                 ".retro_tapping=true",  ".tapping_term=.{.ms=180}", ".hold_layer=1",
        ".custom=253",                ".media_key=.VolumeUp", ".mouse_action=.WheelDown", ".initial_delay=.{.ms=200}",
        ".repeat_interval=.{.ms=50}", ".timeout=.{.ms=40}",
    }) |literal| try std.testing.expect(std.mem.indexOf(u8, first, literal) != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "Navigation") == null);
    const source = try gpa.dupeSentinel(u8, first, 0);
    defer gpa.free(source);
    var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer ast.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
}

test "typed adapters round trip every action and all simultaneous fields" {
    for (fixture.layers) |layer| for (layer.actions) |action| {
        if (action) |original| {
            const model_action = try p.lowerAction(fixture, original);
            const lifted = try p.adapter.liftAction(fixture.layers, model_action);
            try std.testing.expect(std.meta.eql(model_action, try p.lowerAction(fixture, lifted)));
        }
    };
    const hold: @import("layout-model").KeyDef = .{ .hold_only = .{
        .hold_modifiers = .fromByte(255),
        .hold_layer = 1,
    } };
    try std.testing.expect(
        std.meta.eql(hold, try p.lowerAction(fixture, try p.adapter.liftAction(fixture.layers, hold))),
    );
    try std.testing.expectError(
        error.InvalidLayer,
        p.adapter.liftHold(fixture.layers, .{ .hold_layer = 14 }),
    );
}

test "caller diagnostics retain their source after parse returns" {
    const gpa = std.testing.allocator;
    var diagnostics: p.Diagnostics = .{};
    defer diagnostics.deinit(gpa);
    try std.testing.expectError(error.ParseZon, p.parse(gpa, ".{ .unknown = true }", &diagnostics));
    try std.testing.expectEqualStrings(".{ .unknown = true }", diagnostics.source.?);
    try std.testing.expect(diagnostics.parser.errors.len != 0);
    try std.testing.expect(diagnostics.parser.errors[0].msg.len != 0);
}

test "explicit owned export preserves callback bytes and refuses conflicting destination files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var project = try p.profiles.create(gpa, .danish);
    defer project.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const manifest = try p.exporter.write(gpa, io, tmp.dir, project.snapshot, p.profiles.board);
    defer p.exporter.freeManifest(gpa, manifest);
    const export_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(export_path);
    var inventory = try p.export_inventory.read(p.owned_zon, gpa, io, export_path);
    defer inventory.deinit();
    try std.testing.expectEqual(manifest.snapshot_id, inventory.manifest.snapshot_id);
    try std.testing.expectEqual(manifest.files.len, inventory.files.len);
    var same_inventory = try p.export_inventory.read(p.owned_zon, gpa, io, export_path);
    defer same_inventory.deinit();
    try std.testing.expectEqual(inventory.source_digest, same_inventory.source_digest);
    const bytes = try tmp.dir.readFileAlloc(
        io,
        "callback_0/rollercole.zig",
        gpa,
        .limited(p.Limits.source_bytes),
    );
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings(p.profiles.registered_source, bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "keymap.zig", .data = "// user-owned file\n" });
    try std.testing.expectError(
        error.ExportSourceMismatch,
        p.export_inventory.read(p.owned_zon, gpa, io, export_path),
    );
    try std.testing.expect(
        !std.mem.eql(u8, inventory.files[inventory.files.len - 1].bytes, "// user-owned file\n"),
    );
    try std.testing.expectError(
        error.ExportOwnershipConflict,
        p.exporter.write(gpa, io, tmp.dir, project.snapshot, p.profiles.board),
    );
    const retained = try tmp.dir.readFileAlloc(io, "keymap.zig", gpa, .limited(128));
    defer gpa.free(retained);
    try std.testing.expectEqualStrings("// user-owned file\n", retained);
}

test "document key layer combo and name capacity limits are exercised at their bounds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ids = try a.alloc([]const u8, 127);
    for (ids, 0..) |*id, index| id.* = try std.fmt.allocPrint(a, "key_{d}", .{index});
    const sides = try a.alloc(@import("layout-model").Side, 127);
    @memset(sides, .X);
    const synthetic = p.Board{
        .id = board.id,
        .physical_layout = "capacity",
        .key_ids = ids,
        .sides = sides,
    };
    const layers = try a.alloc(p.Layer, 15);
    for (layers, 0..) |*layer, index| {
        const actions = try a.alloc(?p.Action, 127);
        @memset(actions, null);
        layer.* = .{
            .id = @intCast(index + 1),
            .name = try std.fmt.allocPrint(a, "Layer {d}", .{index}),
            .actions = actions,
        };
    }
    const combos = try a.alloc(p.Combo, 1024);
    var count: usize = 0;
    outer: for (0..127) |first| for (first + 1..127) |second| {
        combos[count] = .{
            .key_ids = .{ ids[first], ids[second] },
            .layer_id = 1,
            .timeout = .{ .ms = 65535 },
            .action = .none,
        };
        count += 1;
        if (count == combos.len) break :outer;
    };
    var doc = fixture;
    doc.physical_layout = synthetic.physical_layout;
    doc.key_ids = ids;
    doc.layers = layers;
    doc.combos = combos;
    const name = try a.alloc(u8, p.Limits.name_bytes + 1);
    @memset(name, 'N');
    doc.name = name[0..p.Limits.name_bytes];
    try p.validate(doc, synthetic);
    doc.name = name;
    try std.testing.expectError(error.InvalidName, p.validate(doc, synthetic));
    doc.name = "Capacity";
    const extra_combos = try a.alloc(p.Combo, 1025);
    @memcpy(extra_combos[0..1024], combos);
    extra_combos[1024] = combos[0];
    doc.combos = extra_combos;
    try std.testing.expectError(error.InvalidCombo, p.validate(doc, synthetic));
    doc.combos = &.{};
    const extra_layers = try a.alloc(p.Layer, 16);
    @memcpy(extra_layers[0..15], layers);
    extra_layers[15] = layers[0];
    doc.layers = extra_layers;
    try std.testing.expectError(error.InvalidDimensions, p.validate(doc, synthetic));
}
