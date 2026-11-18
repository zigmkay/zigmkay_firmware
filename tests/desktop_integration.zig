//! Real combined module graph: document edits, cache/practice and explicit flash.
const std = @import("std");

test "edits and reverting during a build are scheduled after Flash has finished" {
    const t = std.testing;
    var scheduler: desktop.auto_build.Scheduler = .{};
    scheduler.observe(@splat(1), 0);
    scheduler.manual(@splat(1));
    scheduler.observe(@splat(2), 10);
    try t.expect(scheduler.take(1000, desktop.flash_presenter.blocksAutoBuild(.ready)));
    // Revert while the new build is busy; keep the replacement queued.
    scheduler.observe(@splat(1), 1100);
    try t.expect(!scheduler.take(2000, true));
    try t.expect(scheduler.take(2100, desktop.flash_presenter.blocksAutoBuild(.stale)));
    try t.expect(!scheduler.take(3000, desktop.flash_presenter.blocksAutoBuild(.stale)));
}

/// A hang guard only. It outlasts the build worker's own timeout, so a slow
/// shared CI runner reports the worker's diagnostic rather than this deadline.
fn awaitWorker(worker: anytype) !@TypeOf(worker.*).Event {
    const started = std.Io.Clock.awake.now(std.testing.io);
    while (true) {
        if (worker.poll()) |event| return event;
        if (started.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds() > 30_000)
            return error.WorkerDeadline;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
}

test "source workers own attach requests and preserve externally edited checkout mirrors" {
    const t = std.testing;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "custom.zig", .data = "// frozen callback bytes\n" });
    var inner = try desktop.callback_editor.Request.capture(&model, .attach, 0, "custom.zig", &.{1}, &.{});
    var inner_owned = true;
    defer if (inner_owned) inner.deinit();
    try t.expectError(
        error.InvalidSourcePath,
        desktop.source_worker.Request.prepareCallback(&inner, "relative"),
    );
    var request = try desktop.source_worker.Request.prepareCallback(&inner, root);
    inner_owned = false;
    var request_owned = true;
    defer if (request_owned) request.deinit();
    const worker = try desktop.source_worker.Owner.create(t.allocator, t.io, &request, 1);
    request_owned = false;
    defer worker.destroy();
    var prepared = try (try awaitWorker(worker)).result;
    defer prepared.deinit();
    try t.expect(try prepared.promote(&model));
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    var checkout = try desktop.source_worker.Request.captureCheckout(&model, root, 0);
    var checkout_owned = true;
    defer if (checkout_owned) checkout.deinit();
    const mirror_worker = try desktop.source_worker.Owner.create(t.allocator, t.io, &checkout, 2);
    checkout_owned = false;
    defer mirror_worker.destroy();
    var mirrored = try (try awaitWorker(mirror_worker)).result;
    defer mirrored.deinit();
    try t.expect(!try mirrored.promote(&model));
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "callbacks/0/custom.zig", .data = "// external edits\n" });
    var again = try desktop.source_worker.Request.captureCheckout(&model, root, 0);
    defer again.deinit();
    var mirrored_again = try again.prepare(t.allocator, t.io);
    defer mirrored_again.deinit();
    const external = try tmp.dir.readFileAlloc(t.io, "callbacks/0/custom.zig", t.allocator, .limited(4096));
    defer t.allocator.free(external);
    try t.expectEqualStrings("// external edits\n", external);
    try model.rename("Changed during delivery");
    try t.expectError(error.StaleCallbackAction, mirrored_again.promote(&model));
}

test "owned file worker freezes save and joins canceled or consumed jobs" {
    const t = std.testing;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var request = try desktop.project_files.Request.capture(&model, .save, path);
    var retained = true;
    defer if (retained) request.deinit();
    try t.expectError(
        error.InvalidProjectGeneration,
        desktop.project_worker.Owner.create(t.allocator, t.io, &request, 0),
    );
    const captured = request.captured;
    const worker = try desktop.project_worker.Owner.create(t.allocator, t.io, &request, 1);
    retained = false;
    defer worker.destroy();
    try model.rename("Later UI layer edit");
    const event = try awaitWorker(worker);
    try t.expectEqual(captured, event.ticket.snapshot);
    var result = try event.result;
    defer result.deinit();
    try t.expectError(error.StaleProjectAction, result.promote(&model));
    try t.expect(worker.poll() == null);
    var saved = try project.snapshot.load(t.allocator, t.io, tmp.dir, model.board);
    defer saved.deinit();
    try t.expectEqual(captured, try project.snapshot.projectDigest(t.allocator, saved.snapshot, model.board));
    var next = try desktop.project_files.Request.capture(&model, .save, path);
    var next_retained = true;
    defer if (next_retained) next.deinit();
    const canceled = try desktop.project_worker.Owner.create(t.allocator, t.io, &next, 2);
    next_retained = false;
    canceled.destroy();
    // Cancellation may race completion; either outcome retains editor ownership.
    try t.expect(model.dirty());
}

test "a completed older save advances the disk baseline without clearing newer edits" {
    const t = std.testing;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try model.save(t.io, temp.dir);
    try model.rename("Revision A");
    var request = try desktop.project_files.Request.capture(&model, .save, root);
    defer request.deinit();
    try model.rename("Revision B");
    var completed = try request.prepare(t.allocator, t.io);
    defer completed.deinit();
    try t.expectError(error.StaleProjectAction, completed.promote(&model));
    try t.expect(model.dirty());
    try t.expectEqual(request.captured, model.saved_id);
    try t.expectEqualStrings("Revision B", model.document().layers[0].name);
    var next = try desktop.project_files.Request.capture(&model, .save, root);
    defer next.deinit();
    var saved = try next.prepare(t.allocator, t.io);
    defer saved.deinit();
    try saved.promote(&model);
    try t.expect(!model.dirty());
    var disk = try project.snapshot.load(t.allocator, t.io, temp.dir, model.board);
    defer disk.deinit();
    try t.expectEqualStrings("Revision B", disk.snapshot.document.layers[0].name);
}

test "two independent project writers cannot publish over the same baseline" {
    const t = std.testing;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try model.save(t.io, temp.dir);
    try model.rename("Writer A");
    var first = try desktop.project_files.Request.capture(&model, .save, root);
    defer first.deinit();
    try model.rename("Writer B");
    var second = try desktop.project_files.Request.capture(&model, .save, root);
    defer second.deinit();
    const Writer = struct {
        fn run(request: *const desktop.project_files.Request, io: std.Io) !bool {
            var completed = request.prepare(std.heap.page_allocator, io) catch |err| {
                if (err == error.ExternalProjectChanged) return false;
                return err;
            };
            defer completed.deinit();
            return true;
        }
    };
    var a = try std.Io.concurrent(t.io, Writer.run, .{ &first, t.io });
    defer _ = a.cancel(t.io) catch false;
    var b = try std.Io.concurrent(t.io, Writer.run, .{ &second, t.io });
    defer _ = b.cancel(t.io) catch false;
    const a_saved = try a.await(t.io);
    const b_saved = try b.await(t.io);
    try t.expect(a_saved != b_saved);
    var disk = try project.snapshot.load(t.allocator, t.io, temp.dir, model.board);
    defer disk.deinit();
    try t.expectEqualStrings(if (a_saved) "Writer A" else "Writer B", disk.snapshot.document.layers[0].name);
}

test "encoder slot drafts preserve compound actions and bind staged and document revisions" {
    const t = std.testing;
    var loaded = try project.profiles.create(t.allocator, .qwerty);
    defer loaded.deinit();
    var snapshot = loaded.snapshot;
    const initial: [4]project.Tap = @splat(.{});
    snapshot.document.encoders = &initial;
    var board = project.profiles.board;
    board.encoder_actions = initial.len;
    var model = try desktop.model.Model.init(t.allocator, board, snapshot);
    defer model.deinit();
    var session = try desktop.encoder_editor.Session.init(&model);
    session.index = 3;
    const compound = project.Tap{
        .key_press = .{ .tap_keycode = 8, .dead = true, .tap_modifiers = .{ .right_alt = true } },
        .one_shot = .{ .layer_id = model.document().layers[1].id },
        .media_key = .VolumeUp,
        .mouse_action = .WheelDown,
    };
    session.drafts[3] = compound;
    const stale_stage = session.action(.apply);
    session.drafts[2] = .{ .key_press = .{ .tap_keycode = 9 } };
    try t.expectError(error.StaleEncoderAction, session.dispatch(&model, stale_stage));
    const accepted = session.action(.apply);
    try session.dispatch(&model, accepted);
    try t.expectEqualDeep(compound, model.document().encoders[3]);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try t.expect(!session.dirty());
    try t.expectError(error.StaleEncoderAction, session.dispatch(&model, accepted));
    session.drafts[0].one_shot = .{ .layer_id = 999 };
    const before_invalid = try model.id();
    try t.expectError(error.InvalidLayer, session.dispatch(&model, session.action(.apply)));
    try t.expectEqual(before_invalid, try model.id());
    try t.expect(session.dirty());
    try session.dispatch(&model, session.action(.discard));
    try t.expect(!session.dirty());
    try model.undo();
    try t.expectEqualDeep(@as([]const project.Tap, &initial), model.document().encoders);
    try t.expectError(error.StaleEncoderAction, session.dispatch(&model, session.action(.apply)));
    var absent = try desktop.model.Model.init(t.allocator, project.profiles.board, loaded.snapshot);
    defer absent.deinit();
    var empty = try desktop.encoder_editor.Session.init(&absent);
    try empty.dispatch(&absent, empty.action(.apply));
    try t.expectEqual(@as(usize, 0), absent.undo_stack.items.len);
}

test "frozen project IO refuses stale promotion and external overwrite" {
    const t = std.testing;
    const files = desktop.project_files;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var request = try files.Request.capture(&model, .save, path);
    defer request.deinit();
    try model.rename("Later edit");
    var saved = try request.prepare(t.allocator, t.io);
    defer saved.deinit();
    try t.expectError(error.StaleProjectAction, saved.promote(&model));
    try t.expect(model.dirty());
    var on_disk = try project.snapshot.load(t.allocator, t.io, tmp.dir, model.board);
    defer on_disk.deinit();
    try t.expectEqualStrings("Base", on_disk.snapshot.document.layers[0].name);
    var newer = try files.Request.capture(&model, .save, path);
    defer newer.deinit();
    var acknowledged = try newer.prepare(t.allocator, t.io);
    defer acknowledged.deinit();
    try acknowledged.promote(&model);
    try t.expect(!model.dirty());
    try t.expectError(error.StaleProjectAction, acknowledged.promote(&model));
    var open = try files.Request.capture(&model, .open, path);
    defer open.deinit();
    var opened = try open.prepare(t.allocator, t.io);
    defer opened.deinit();
    try opened.promote(&model);
    try t.expectEqual(@as(usize, 0), model.undo_stack.items.len);
    try t.expectEqualStrings("Later edit", model.document().layers[0].name);
    try model.rename("Unsaved edit");
    var clean_open = try files.Request.capture(&model, .open, path);
    defer clean_open.deinit();
    var blocked_open = try clean_open.prepare(t.allocator, t.io);
    defer blocked_open.deinit();
    try t.expectError(error.UnsavedProjectChanges, blocked_open.promote(&model));
    try t.expectEqualStrings("Unsaved edit", model.document().layers[0].name);
    var confirmed_open = try files.Request.openDiscardConfirmed(&model, path, model.board);
    defer confirmed_open.deinit();
    var accepted_open = try confirmed_open.prepare(t.allocator, t.io);
    defer accepted_open.deinit();
    try accepted_open.promote(&model);
    var external = try desktop.model.Model.init(t.allocator, model.board, model.current.snapshot);
    defer external.deinit();
    try external.rename("External change");
    try external.save(t.io, tmp.dir);
    var conflict = try files.Request.capture(&model, .save, path);
    defer conflict.deinit();
    try t.expectError(error.ExternalProjectChanged, conflict.prepare(t.allocator, t.io));
    var preserved = try project.snapshot.load(t.allocator, t.io, tmp.dir, model.board);
    defer preserved.deinit();
    try t.expectEqualStrings("External change", preserved.snapshot.document.layers[0].name);
    var restore = try files.Request.capture(&model, .restore, path);
    defer restore.deinit();
    var restored = try restore.prepare(t.allocator, t.io);
    defer restored.deinit();
    try restored.promote(&model);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try model.undo();
    try t.expectEqualStrings("Later edit", model.document().layers[0].name);
    var future_document = model.document();
    future_document.schema_version = 99;
    const future = try project.serialize(t.allocator, future_document);
    defer t.allocator.free(future);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "project.zon", .data = future });
    var refused = try files.Request.capture(&model, .save, path);
    defer refused.deinit();
    try t.expectError(error.UnsupportedVersion, refused.prepare(t.allocator, t.io));
    const bytes = try tmp.dir.readFileAlloc(
        t.io,
        "project.zon",
        t.allocator,
        .limited(project.Limits.document_bytes),
    );
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(future, bytes);
    try t.expectError(error.InvalidProjectPath, files.Request.capture(&model, .save, "relative"));
    var output = t.tmpDir(.{});
    defer output.cleanup();
    const output_path = try output.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(output_path);
    var export_request = try files.Request.capture(&model, .export_zig, output_path);
    defer export_request.deinit();
    var exported = try export_request.prepare(t.allocator, t.io);
    defer exported.deinit();
    try t.expectEqualSlices(u8, &export_request.captured, &exported.exported.?);
    try exported.promote(&model);
    try t.expectError(error.StaleProjectAction, exported.promote(&model));
    try output.dir.writeFile(t.io, .{ .sub_path = "keymap.zig", .data = "external export edit" });
    try t.expectError(error.ExportOwnershipConflict, export_request.prepare(t.allocator, t.io));
    const preserved_export = try output.dir.readFileAlloc(t.io, "keymap.zig", t.allocator, .limited(1024));
    defer t.allocator.free(preserved_export);
    try t.expectEqualStrings("external export edit", preserved_export);
}

test "editor dispatch resolves owned staged drafts before captured navigation" {
    const t = std.testing;
    const dispatch = desktop.editor_dispatch;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var owner = try dispatch.State.init(&model);
    defer owner.deinit();
    owner.inspector.mutate(.{ .tap_usage = 5 });
    const key = try desktop.key_selection.Action.capture(&model, 3, false);
    try t.expect((try owner.request(&model, dispatch.Request.fromKey(key))) == .pending);
    try t.expectEqual(@as(usize, 0), model.primary);
    try t.expectError(
        error.PendingEditorRequest,
        owner.request(&model, try dispatch.Request.capture(&model, .undo)),
    );
    _ = try owner.inspect(
        &model,
        try desktop.inspector_action.Action.capture(&owner.inspector, &model, .keep_editing),
    );
    try t.expect(owner.pending == null and owner.inspector.dirty());
    _ = try owner.request(&model, dispatch.Request.fromKey(key));
    const old = try desktop.inspector_action.Action.capture(&owner.inspector, &model, .resolve_apply);
    owner.inspector.mutate(.{ .tap_usage = 6 });
    try t.expectError(error.StaleInspectorAction, owner.inspect(&model, old));
    const apply = try desktop.inspector_action.Action.capture(&owner.inspector, &model, .resolve_apply);
    try t.expect((try owner.inspect(&model, apply)) == .none);
    try t.expectEqual(@as(usize, 3), model.primary);
    try t.expectEqual(@as(u8, 6), model.document().layers[0].actions[0].?.tap_only.key_press.?.tap_keycode);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try t.expect(owner.pending == null);
    try owner.sync(&model);
    owner.inspector.mutate(.{ .tap_usage = 7 });
    try t.expect(
        (try owner.request(&model, try dispatch.Request.capture(&model, .{ .open = .combo }))) == .pending,
    );
    const discard = try desktop.inspector_action.Action.capture(&owner.inspector, &model, .resolve_discard);
    try t.expectEqual(dispatch.Open.combo, (try owner.inspect(&model, discard)).open);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try t.expect(!owner.inspector.dirty());
    // Dirty document close is separate from inspector draft resolution.
    try t.expect((try owner.request(&model, try dispatch.Request.capture(&model, .close))) == .confirm_close);
    _ = try owner.inspect(
        &model,
        try desktop.inspector_action.Action.capture(&owner.inspector, &model, .keep_close),
    );
    try t.expect(owner.close_requested == null and !owner.closed);
    _ = try owner.request(&model, try dispatch.Request.capture(&model, .close));
    const save = (try owner.inspect(&model, try desktop.inspector_action.Action.capture(&owner.inspector, &model, .save_close))).save_close;
    try t.expectError(error.StaleCloseRequest, owner.savedClose(&model, save));
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try model.save(t.io, tmp.dir);
    try t.expect((try owner.savedClose(&model, save)) == .closed);
    try t.expectError(error.EditorClosed, owner.request(&model, try dispatch.Request.capture(&model, .undo)));
}

test "stale pending editor completion preserves drafts and request for recovery" {
    const t = std.testing;
    const dispatch = desktop.editor_dispatch;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var owner = try dispatch.State.init(&model);
    defer owner.deinit();
    owner.inspector.mutate(.{ .tap_usage = 5 });
    try t.expectError(
        error.InvalidKey,
        owner.request(
            &model,
            try dispatch.Request.capture(&model, .{ .select = .{
                .index = model.selected.len,
                .extend = false,
            } }),
        ),
    );
    const action = try desktop.inspector_action.Action.capture(&owner.inspector, &model, .resolve_apply);
    _ = try owner.request(&model, try dispatch.Request.capture(&model, .undo));
    try model.rename("external change");
    const before = try model.id();
    try t.expectError(error.StaleInspectorAction, owner.inspect(&model, action));
    try t.expectError(error.StaleInspectorSession, owner.sync(&model));
    try t.expect(owner.inspector.dirty() and owner.pending != null);
    try t.expectEqualSlices(u8, &before, &(try model.id()));
    const recovery = try owner.recovery(&model);
    owner.inspector.mutate(.{ .tap_usage = 7 });
    try t.expectError(error.StaleEditorRecovery, owner.discardStale(&model, recovery));
    try t.expect(owner.inspector.dirty() and owner.pending != null);
    try owner.discardStale(&model, try owner.recovery(&model));
    try t.expect(!owner.inspector.dirty() and owner.pending == null);
    try t.expectEqualSlices(u8, &before, &(try model.id()));
}

test "physical key selection binds processing index document layer and selection" {
    const t = std.testing;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    const Action = desktop.key_selection.Action;
    const before = try model.id();
    const first = try Action.capture(&model, 3, false);
    try first.dispatch(&model);
    try t.expectEqual(@as(usize, 3), model.primary);
    try t.expect(model.selected[3] and !model.selected[0]);
    try t.expectError(error.StaleKeySelection, first.dispatch(&model));
    try (try Action.capture(&model, 4, true)).dispatch(&model);
    try t.expect(model.selected[3] and model.selected[4]);
    try (try Action.capture(&model, 3, true)).dispatch(&model);
    try t.expect(!model.selected[3] and model.selected[4]);
    try t.expectEqualSlices(u8, &before, &(try model.id()));
    try t.expectEqual(@as(usize, 0), model.undo_stack.items.len);
    const captured = try Action.capture(&model, 5, false);
    model.layer = 1;
    try t.expectError(error.StaleKeySelection, captured.dispatch(&model));
    model.layer = 0;
    try model.rename("later document");
    try t.expectError(error.StaleKeySelection, captured.dispatch(&model));
    try t.expectError(error.InvalidKey, Action.capture(&model, model.selected.len, false));
}

test "host palette owns Unicode previews and chord actions refuse stale drops" {
    const t = std.testing;
    const Translator = struct {
        pub fn keyToText(_: *@This(), chord: desktop.assignment.Chord) struct { data: [4]u8, len: usize } {
            return if (chord.tap_keycode == 4) .{
                .data = if (chord.tap_modifiers.left_alt) .{ 0xce, 0xbb, 0, 0 } else if (chord.tap_modifiers.left_shift) .{ 'A', 0, 0, 0 } else .{ 'a', 0, 0, 0 },
                .len = if (chord.tap_modifiers.left_alt) 2 else 1,
            } else .{ .data = @splat(0), .len = 0 };
        }
    };
    var translator: Translator = .{};
    var source_id = "Fixture source".*;
    var cache = try desktop.host_palette.Cache.init(t.allocator, .linux, &source_id, 7, &translator);
    defer cache.deinit();
    source_id[0] = 'X';
    try t.expectEqualStrings("Fixture source", cache.source_id);
    try t.expectEqualStrings("a", cache.caption(4, false, false));
    try t.expectEqualStrings("A", cache.caption(4, true, false));
    try t.expectEqualStrings("λ", cache.caption(4, false, true));
    try t.expectEqualStrings("λ", cache.caption(4, true, true));
    const symbols = desktop.labels.keycap_symbols;
    try t.expectEqualStrings(symbols.Symbol.space.text(), cache.caption(44, true, true));
    try t.expectEqualStrings(symbols.Symbol.windows.text(), cache.caption(227, false, false));
    const BadTranslator = struct {
        pub fn keyToText(_: *@This(), _: desktop.assignment.Chord) struct { data: [1]u8, len: usize } {
            return .{ .data = .{0xff}, .len = 1 };
        }
    };
    var bad: BadTranslator = .{};
    try t.expectError(
        error.InvalidPaletteTranslation,
        desktop.host_palette.Cache.init(t.allocator, .linux, "bad", 0, &bad),
    );
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    const action = try desktop.chord_action.Action.capture(&model, .{
        .tap_keycode = 5,
        .tap_modifiers = .{ .left_alt = true },
    });
    model.select(1, false);
    try t.expectError(error.StaleChordAction, action.drop(&model, 2, false));
    model.select(0, false);
    const dropped = try action.drop(&model, 2, false);
    try dropped.dispatch(&model);
    try t.expectEqual(@as(usize, 2), model.primary);
    try t.expectEqual(@as(u8, 5), model.action().?.tap_only.key_press.?.tap_keycode);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try t.expectError(error.StaleChordAction, action.dispatch(&model));
    try model.undo();
    const held = try (try desktop.chord_action.Action.capture(&model, .{ .tap_keycode = 4 })).drop(&model, null, true);
    const before = try model.id();
    try t.expectError(error.DropModifierKeyOnHold, held.dispatch(&model));
    try t.expectEqualSlices(u8, &before, &(try model.id()));
}

test "layer actions use stable IDs and reject stale document and selection" {
    const t = std.testing;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    const layers = desktop.layer_editor;
    const original = try model.id();
    const first = model.document().layers[0].id;
    const second = model.document().layers[1].id;
    const rename = try layers.capture(&model, .rename, second, "Renamed second");
    try layers.dispatch(&model, rename);
    try t.expectEqual(@as(usize, 0), model.layer);
    try t.expectEqualStrings("Renamed second", model.document().layers[1].name);
    try t.expectError(error.StaleLayerAction, layers.dispatch(&model, rename));
    try model.undo();
    try t.expectEqualSlices(u8, &original, &(try model.id()));
    const select = try layers.capture(&model, .select, second, "");
    try layers.dispatch(&model, select);
    try t.expectEqual(@as(usize, 1), model.layer);
    try t.expectError(error.StaleLayerAction, layers.dispatch(&model, rename));
    const duplicate = try layers.capture(&model, .duplicate, first, "");
    try layers.dispatch(&model, duplicate);
    const added = model.document().layers[model.layer];
    try t.expectEqualStrings("Base copy", added.name);
    try t.expectEqualDeep(model.document().layers[0].actions[0], added.actions[0]);
    try t.expect(added.id != first and added.id != second);
    const remove = try layers.capture(&model, .delete, added.id, "");
    try layers.dispatch(&model, remove);
    try t.expectEqual(template.snapshot.document.layers.len, model.document().layers.len);
    const base_delete = try layers.capture(&model, .delete, first, "");
    const before = try model.id();
    try t.expectError(error.LayerReferenced, layers.dispatch(&model, base_delete));
    try t.expectEqualSlices(u8, &before, &(try model.id()));
}

test "folder selection discards stale owners documents and late generations" {
    const t = std.testing;
    var state: desktop.folder_selection.State = .{};
    const snapshot: [32]u8 = @splat(1);
    const first = try state.begin(10, snapshot, .callback_source);
    try t.expectError(error.DialogAlreadyOpen, state.begin(11, snapshot, .project));
    try t.expect(state.discard(first));
    const second = try state.begin(11, snapshot, .project);
    try t.expect(!state.accept(first, 11, snapshot));
    try t.expect(!state.discard(first));
    try t.expect(state.pending != null);
    try t.expect(!state.accept(second, 12, snapshot));
    const third = try state.begin(11, snapshot, .callback_source);
    try t.expect(!state.accept(third, 11, @splat(2)));
    const fourth = try state.begin(11, snapshot, .callback_source);
    try t.expect(state.accept(fourth, 11, snapshot));
    try t.expect(!state.accept(fourth, 11, snapshot));
    state.generation = std.math.maxInt(u64);
    try t.expectError(error.DialogGenerationExhausted, state.begin(11, snapshot, .project));
}

test "callback preparation owns frozen input and refuses stale promotion" {
    const t = std.testing;
    const callbacks = desktop.callback_editor;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "custom.zig", .data = "// initial\n" });
    var ids = [_]u8{1};
    var request = try callbacks.Request.capture(&model, .attach, 0, "custom.zig", &ids, &.{});
    defer request.deinit();
    ids[0] = 2;
    var prepared = try request.prepare(t.allocator, t.io, tmp.dir);
    defer prepared.deinit();
    try t.expect(try prepared.promote(&model));
    try t.expectEqual(@as(u8, 1), model.document().callbacks[0].ids[0]);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try t.expectError(error.StaleCallbackAction, prepared.promote(&model));
    const attached = try model.id();
    try callbacks.checkout(&model, attached, t.io, tmp.dir, 0);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "callbacks/0/custom.zig", .data = "// edited\n" });
    // Checkout preserves the external edits.
    try callbacks.checkout(&model, attached, t.io, tmp.dir, 0);
    var check = try callbacks.Request.capture(&model, .check, 0, "", &.{}, &.{});
    defer check.deinit();
    var checked = try check.prepare(t.allocator, t.io, tmp.dir);
    defer checked.deinit();
    try t.expect(try checked.promote(&model));
    try t.expectEqualSlices(u8, &attached, &(try model.id()));
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    var refresh = try callbacks.Request.capture(&model, .refresh, 0, "", &.{}, &.{});
    defer refresh.deinit();
    var refreshed = try refresh.prepare(t.allocator, t.io, tmp.dir);
    defer refreshed.deinit();
    try model.rename("later edit");
    try t.expectError(error.StaleCallbackAction, refreshed.promote(&model));
    try t.expectError(error.StaleCallbackAction, callbacks.checkout(&model, attached, t.io, tmp.dir, 0));
    try model.undo();
    try t.expect(try refreshed.promote(&model));
    try t.expectEqualStrings("// edited\n", model.current.snapshot.sources[0].bytes);
    try model.undo();
    try t.expectEqualStrings("// initial\n", model.current.snapshot.sources[0].bytes);
    try t.expectError(error.InvalidCallback, callbacks.Request.capture(&model, .refresh, 1, "", &.{}, &.{}));
}

const desktop = @import("desktop-core");
const project = @import("project");
const jobs = @import("companion-jobs");
const options = @import("options");

test "combo editor commits stable IDs once and refuses invalid or stale rendered edits" {
    const t = std.testing;
    var loaded = try project.profiles.create(t.allocator, .eurmac);
    defer loaded.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, loaded.snapshot);
    defer model.deinit();
    var editor = try desktop.combo_editor.Session.init(&model);
    const before = try model.id();
    const history = model.undo_stack.items.len;
    editor.keys = .{ 0, 0 };
    try t.expectError(error.InvalidCombo, editor.dispatch(&model, editor.action(.save)));
    try t.expectEqualDeep(before, try model.id());
    editor.keys = .{ 0, 1 };
    const rendered = editor.action(.save);
    editor.timeout += 1;
    try t.expectError(error.StaleComboAction, editor.dispatch(&model, rendered));
    try editor.dispatch(&model, editor.action(.save));
    try t.expectEqual(history + 1, model.undo_stack.items.len);
    const index = editor.index.?;
    const combo = model.document().combos[index];
    try t.expectEqualStrings(model.document().key_ids[0], combo.key_ids[0]);
    try t.expectEqualStrings(model.document().key_ids[1], combo.key_ids[1]);
    try t.expectEqual(model.document().layers[0].id, combo.layer_id);
    try editor.pick(&model, index);
    const delete = editor.action(.delete);
    try editor.dispatch(&model, delete);
    try t.expect(editor.index == null);
    try model.undo();
    try t.expectError(error.StaleComboAction, editor.dispatch(&model, editor.action(.save)));
}

test "rendered mixed inspector intent rejects later staged fields and selection" {
    const t = std.testing;
    var loaded = try project.profiles.create(t.allocator, .eurmac);
    defer loaded.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, loaded.snapshot);
    defer model.deinit();
    model.select(10, false);
    var session = try desktop.inspector_session.Session.init(&model);
    defer session.deinit();
    session.mutate(.{ .tap_usage = 5 });
    const old = try desktop.inspector_action.Action.capture(&session, &model, .apply);
    try old.validate(&session, &model);
    session.mutate(.{ .tap_usage = 6 });
    try t.expectError(error.StaleInspectorAction, old.validate(&session, &model));
    const current = try desktop.inspector_action.Action.capture(&session, &model, .apply);
    try current.validate(&session, &model);
    try t.expect(try session.apply(&model));
    try t.expectError(error.StaleInspectorAction, current.validate(&session, &model));
    const after_apply = try desktop.inspector_action.Action.capture(&session, &model, .copy);
    model.select(11, false);
    try t.expectError(error.StaleInspectorAction, after_apply.validate(&session, &model));
}

test "typed drawer applies one explicit batch and rejects changed document or selection" {
    const t = std.testing;
    var loaded = try project.profiles.create(t.allocator, .eurmac);
    defer loaded.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, loaded.snapshot);
    defer model.deinit();
    model.select(10, false);
    model.select(11, true);
    var form = try desktop.action_form.Session.begin(t.allocator, &model);
    defer form.deinit();
    const before = try model.id();
    try t.expectEqual(desktop.action_form.Session.Status.current, try form.status(&model));
    try t.expect(!try form.apply(&model));
    try t.expectEqualDeep(before, try model.id());
    try t.expectEqual(@as(usize, 0), model.undo_stack.items.len);
    form.draft.tap.media_key = .VolumeUp;
    const chosen = form.draft.action();
    try t.expect(try form.apply(&model));
    try t.expectEqual(desktop.action_form.Session.Status.applied, try form.status(&model));
    try t.expectEqualDeep(chosen, model.document().layers[0].actions[10]);
    try t.expectEqualDeep(chosen, model.document().layers[0].actions[11]);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);
    try model.undo();
    try t.expectEqualDeep(before, try model.id());
    try t.expectError(error.ActionFormAlreadyApplied, form.apply(&model));
    var new_form = try desktop.action_form.Session.begin(t.allocator, &model);
    defer new_form.deinit();
    new_form.draft.tap.media_key = .VolumeDown;
    model.select(12, false);
    try t.expectEqual(desktop.action_form.Session.Status.stale_selection, try new_form.status(&model));
    try t.expectError(error.StaleActionFormSelection, new_form.apply(&model));
    try t.expectEqualDeep(before, try model.id());
    try model.rename("Changed outside the drawer");
    try t.expectEqual(desktop.action_form.Session.Status.stale_document, try new_form.status(&model));
    try t.expectError(error.StaleSession, new_form.apply(&model));
}

test "explicit desktop flash reaps an offline wrapper and retains diagnostics" {
    const t = std.testing;
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.fixture, t.allocator);
    defer t.allocator.free(fixture);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const tool = try std.fs.path.join(t.allocator, &.{ base, "tool" });
    defer t.allocator.free(tool);
    const artifact = try std.fs.path.join(t.allocator, &.{ base, "build.uf2" });
    defer t.allocator.free(artifact);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tool", .data = "offline tool bytes" });
    const lock = jobs.target_lock.fixture();
    var tools = try jobs.flash_inputs.Tools.capture(
        t.allocator,
        t.io,
        lock.firmware_revision,
        lock.firmware_source_digest,
        lock.source_kind,
        fixture,
        tool,
    );
    defer tools.deinit();
    const current: jobs.firmware.Inputs = .{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = "profile1".*,
        .identity_digest = @splat(5),
        .lock = lock,
    };
    var block: [512]u8 = @splat(0);
    for ([_]struct { usize, u32 }{
        .{ 0, 0x0a324655 },
        .{ 4, 0x9e5d5157 },
        .{ 8, 0x2000 },
        .{ 12, 0x10000000 },
        .{ 16, 256 },
        .{ 24, 1 },
        .{ 28, 0xe48bff56 },
        .{ 508, 0x0ab16f30 },
    }) |word| std.mem.writeInt(u32, block[word[0]..][0..4], word[1], .little);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.uf2", .data = &block });
    var manifest = try jobs.firmware.Manifest.complete(
        t.allocator,
        .succeeded,
        jobs.firmware.key(current),
        current,
        current,
        artifact,
        &block,
    );
    defer manifest.deinit();
    const request: jobs.flash_inputs.Request = .{ .captured = @splat(1), .current = @splat(1) };
    var frozen = try jobs.flash_inputs.freeze(
        t.allocator,
        t.io,
        tmp.dir,
        base,
        manifest,
        current,
        tools,
        request,
    );
    defer frozen.deinit();
    for ([_][]const u8{ "ok", "wait", "flood", "unique_bootsel" }) |serial| {
        var owner = desktop.flash_controller.Controller.init(t.allocator, .{
            .snapshot = request.current,
            .build_key = jobs.firmware.key(current),
        });
        defer owner.deinit();
        _ = try owner.dispatch(.prepare);
        _ = try owner.receive(.{ .prepared = owner.operation_id }, 0);
        _ = try owner.dispatch(.build);
        _ = try owner.receive(.{ .built = .{
            .operation_id = owner.operation_id,
            .build_key = owner.current.build_key,
        } }, 0);
        _ = try owner.dispatch(.freeze);
        _ = try owner.receive(.{ .frozen = .{ .operation_id = owner.operation_id, .artifact = .{
            .context = owner.current,
            .path = frozen.path,
            .uf2_hash = frozen.uf2_hash,
            .expected_identity = .{
                .board_id = "board_v1".*,
                .profile_id = current.profile_id,
                .digest = current.identity_digest,
            },
        } } }, 0);
        _ = try owner.dispatch(.{
            .select = if (std.mem.eql(u8, serial, "unique_bootsel")) .unique_bootsel else .{ .serial = serial },
        });
        const rendered = desktop.flash_presenter.view(&owner, null);
        try t.expect(rendered.can_confirm);
        const start = (try owner.dispatch(try rendered.intent(.confirm, null))).start_managed;
        try t.expectError(error.InvalidIntent, owner.dispatch(try rendered.intent(.confirm, null)));
        var runtime = desktop.flash_runtime.Runtime.init(t.allocator, t.io);
        defer runtime.deinit();
        try t.expect((try runtime.start(&owner, start, &frozen, current, "board_v1".*, 0)) == .none);
        if (std.mem.eql(u8, serial, "wait")) try t.expect(runtime.cancel(start.operation));
        var completion: ?desktop.flash_runtime.PollResult = null;
        for (0..1000) |_| {
            completion = try runtime.poll(&owner, 1);
            if (completion != null) break;
            try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
        }
        try t.expect(completion != null);
        var result = completion.?;
        defer result.deinit(t.allocator);
        try t.expect(result.failure == null);
        const diagnostics = desktop.flash_presenter.Diagnostics.fromResult(result.completion.?);
        try t.expectEqualStrings(result.completion.?.process.stderr, diagnostics.stderr);
        try t.expect(runtime.job == null);
        try t.expect(try runtime.poll(&owner, 2) == null);
        if (std.mem.eql(u8, serial, "wait")) {
            try t.expect(result.completion.?.cancelled);
            try t.expectEqualStrings("controlled-exit\n", result.completion.?.process.stderr);
        } else {
            try t.expect(result.completion.?.successful());
            try t.expect(result.effect == .watch_reconnect);
            try t.expectEqual(desktop.flash_controller.Phase.reconnecting, owner.phase);
            if (std.mem.eql(u8, serial, "flood")) try t.expect(result.completion.?.diagnostics_truncated);
        }
    }
}

test "managed desktop runtime has an idle lifecycle without spawning" {
    var runtime = desktop.flash_runtime.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    _ = &desktop.flash_runtime.Runtime.start;
    var controller = desktop.flash_controller.Controller.init(std.testing.allocator, .{
        .snapshot = @splat(1),
        .build_key = @splat(2),
    });
    defer controller.deinit();
    try std.testing.expect(try runtime.poll(&controller, 0) == null);
}

test "owned document edits invalidate desktop build intent without dispatching flash" {
    const gpa = std.testing.allocator;
    var template = try project.profiles.create(gpa, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(gpa, project.profiles.board, template.snapshot);
    defer model.deinit();
    const initial = try model.id();
    var controller = desktop.flash_controller.Controller.init(gpa, .{
        .snapshot = initial,
        .build_key = @splat(1),
    });
    defer controller.deinit();
    const effect = try controller.dispatch(.prepare);
    try std.testing.expect(effect == .prepare_tools);
    _ = try controller.receive(.{ .prepared = controller.operation_id }, 0);
    try model.rename("Combined desktop graph");
    const changed = try model.id();
    try std.testing.expect(!std.mem.eql(u8, &initial, &changed));
    _ = controller.observe(.{ .snapshot = changed, .build_key = @splat(2) });
    try std.testing.expectEqual(desktop.flash_controller.Phase.stale, controller.phase);
    try std.testing.expectError(error.InvalidIntent, controller.dispatch(.build));
    const serialized = try project.serialize(gpa, model.document());
    defer gpa.free(serialized);
    const parsed = try project.parse(gpa, serialized, null);
    defer project.deinit(gpa, parsed);
    try project.validate(parsed, model.board);
    // Shared owned-ZON helpers are analyzed in both owning modules in one graph.
    const record: jobs.flash_inputs.Record = .{
        .version = 999,
        .firmware_revision = "01a6368ca5f49a47ce770cd603cc98b90b8298de",
        .firmware_source_digest = @splat(0),
        .source_kind = .development,
        .wrapper_path = "/cache/wrapper",
        .wrapper_hash = @splat(0),
        .picotool_path = "/cache/picotool",
        .picotool_hash = @splat(0),
    };
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    try std.zon.stringify.serialize(record, .{}, &writer.writer);
    try std.testing.expectError(
        error.UnsupportedToolsVersion,
        jobs.flash_inputs.Tools.parse(gpa, writer.written()),
    );
}

test "build worker owns verified exports and accepts only the current editor preparation ticket" {
    const t = std.testing;
    const p = @import("project");
    var loaded = try p.profiles.create(t.allocator, .qwerty);
    defer loaded.deinit();
    var model = try desktop.model.Model.init(t.allocator, p.profiles.board, loaded.snapshot);
    defer model.deinit();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{} }" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const helper = try std.Io.Dir.cwd().realPathFileAlloc(t.io, @import("options").helper_path, t.allocator);
    defer t.allocator.free(helper);
    const distribution = std.fs.path.dirname(helper).?;
    const exported = try std.fs.path.join(t.allocator, &.{ root, ".zig-cache/export" });
    defer t.allocator.free(exported);
    const install = try std.fs.path.join(t.allocator, &.{ root, ".zig-cache/build" });
    defer t.allocator.free(install);
    var descriptor_text: std.Io.Writer.Allocating = .init(t.allocator);
    defer descriptor_text.deinit();
    try std.zon.stringify.serialize(jobs.application_bundle.Manifest{
        .id = jobs.firmware.digest("controlled release payload"),
        .firmware_revision = jobs.target_lock.fixture().firmware_revision,
        .wrapper_hash = @splat(1),
        .picotool_hash = @splat(2),
    }, .{}, &descriptor_text.writer);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "application.zon", .data = descriptor_text.written() });
    var application = try jobs.application_bundle.Bundle.open(t.allocator, t.io, root);
    defer application.deinit();
    const generated = try desktop.application_bundle.plan(
        t.allocator,
        application,
        root,
        "lk7",
        model.board.id,
    );
    defer p.owned_zon.free(t.allocator, generated);
    var config = generated.config;
    config.request.selection.compiler_path = helper;
    config.request.selection.compiler_distribution_path = distribution;
    config.request.selection.build_root = root;
    config.request.export_directory = exported;
    config.request.install_directory = install;
    config.request.timeout_ms = 15_000;
    var environment: std.process.Environ.Map = .init(t.allocator);
    defer environment.deinit();
    try environment.put("ZIGMKAY_BUILD_FIXTURE", "success");
    try t.expect(jobs.managed_build.isFirstBuild(t.allocator, t.io, config.request));
    var request = try desktop.build_worker.Request.capture(&model, config, &environment, 42);
    var owns_request = true;
    defer if (owns_request) request.deinit();
    const captured = request.captured;
    const worker = try desktop.build_worker.Owner.create(t.allocator, t.io, &request, 42);
    owns_request = false;
    defer worker.destroy();
    const completed = (try awaitWorker(worker)).result;
    var candidate = completed catch |err| {
        std.debug.print(
            "build worker failed: {s}; install directory: {s}; export directory: {s}\n",
            .{ @errorName(err), install, exported },
        );
        if (std.Io.Dir.cwd().openDir(t.io, install, .{ .iterate = true })) |directory| {
            var output = directory;
            defer output.close(t.io);
            var entries = output.iterate();
            while (entries.next(t.io) catch null) |entry| {
                std.debug.print("build output entry: {s} ({s})\n", .{ entry.name, @tagName(entry.kind) });
                if (entry.kind != .directory) continue;
                var child = output.openDir(t.io, entry.name, .{}) catch continue;
                defer child.close(t.io);
                for ([_][]const u8{ "build.stdout.log", "build.stderr.log" }) |name| {
                    const bytes = child.readFileAlloc(
                        t.io,
                        name,
                        t.allocator,
                        .limited(64 * 1024),
                    ) catch continue;
                    defer t.allocator.free(bytes);
                    std.debug.print("{s}/{s}: {s}\n", .{ entry.name, name, bytes });
                }
            }
        } else |_| {}
        return err;
    };
    defer candidate.deinit();
    try t.expect(!jobs.managed_build.isFirstBuild(t.allocator, t.io, config.request));
    var stale = candidate.ticket;
    stale.generation += 1;
    try t.expectError(error.StaleBuild, candidate.take(&model, stale));
    try model.rename("Edit after build capture");
    try t.expectError(error.StaleBuild, candidate.take(&model, candidate.ticket));
    try model.undo();
    var bundle_result = try candidate.takeBundle(&model, .{ .generation = 42, .snapshot = captured });
    defer bundle_result.deinit();
    const manifest = bundle_result.firmware;
    try bundle_result.runner.verifyFile(t.allocator, t.io, manifest.inputs);
    try t.expectEqual(captured, manifest.inputs.project_digest);
    try t.expectEqual(.bundled, manifest.audit_mode);
    try t.expectEqual(model.document().profile_id, manifest.inputs.profile_id);
    try t.expect(!std.mem.eql(u8, &manifest.inputs.source_digest, &@as([32]u8, @splat(0))));
    try t.expectError(error.BuildAlreadyCompleted, candidate.take(&model, candidate.ticket));
    // Snapshot revalidation is independent of package files and installation paths.
    var audit_request = try desktop.build_worker.Request.capture(&model, config, &environment, 44);
    defer audit_request.deinit();
    var fast_inputs = try audit_request.captureCurrentInputs(
        t.allocator,
        t.io,
        candidate.expected_export_tree,
    );
    defer fast_inputs.deinit();
    try t.expectEqualDeep(
        manifest.inputs.build_inputs_digest,
        fast_inputs.captured.inputs.build_inputs_digest,
    );
    try tmp.dir.writeFile(t.io, .{
        .sub_path = "build.zig.zon",
        .data = ".{ .dependencies = .{}, .name = .changed }",
    });
    var still_prepared = try audit_request.captureCurrentInputs(
        t.allocator,
        t.io,
        candidate.expected_export_tree,
    );
    defer still_prepared.deinit();
    try t.expectEqualDeep(fast_inputs.captured.receipt.digest(), still_prepared.captured.receipt.digest());
    try environment.put(
        "ZIGMKAY_BUILD_FIXTURE",
        if (@import("builtin").os.tag == .windows) "hang" else "spawn-hang",
    );
    const cancel_install = try std.fs.path.join(t.allocator, &.{ root, ".zig-cache/cancelled-build" });
    defer t.allocator.free(cancel_install);
    var cancel_config = config;
    cancel_config.request.install_directory = cancel_install;
    cancel_config.request.timeout_ms = 15_000;
    var cancel_request = try desktop.build_worker.Request.capture(&model, cancel_config, &environment, 43);
    var owns_cancel_request = true;
    defer if (owns_cancel_request) cancel_request.deinit();
    const cancelled = try desktop.build_worker.Owner.create(t.allocator, t.io, &cancel_request, 43);
    owns_cancel_request = false;
    var owns_cancelled = true;
    defer if (owns_cancelled) cancelled.destroy();
    const deadline = std.Io.Clock.awake.now(t.io).toMilliseconds() + 5000;
    while (true) {
        if (std.Io.Dir.cwd().openDir(t.io, cancel_install, .{ .iterate = true })) |directory| {
            defer directory.close(t.io);
            var iterator = directory.iterate();
            var ready = false;
            while (try iterator.next(t.io)) |entry| {
                if (entry.kind != .directory) continue;
                var child = try directory.openDir(t.io, entry.name, .{});
                defer child.close(t.io);
                if (child.statFile(t.io, "cancel-ready", .{})) |_| {
                    ready = true;
                } else |err| if (err != error.FileNotFound) return err;
            }
            if (ready) break;
        } else |err| if (err != error.FileNotFound) return err;
        if (std.Io.Clock.awake.now(t.io).toMilliseconds() > deadline) return error.WorkerDeadline;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    const cancellation = std.Io.Clock.awake.now(t.io);
    cancelled.destroy();
    owns_cancelled = false;
    try t.expect(cancellation.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds() < 5000);
}

test "practice cohorts ignore project renames and caption changes but distinguish translated routes" {
    const t = std.testing;
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    const before = try project.snapshot.identity(t.allocator, model.current.snapshot, model.board);
    try model.rename("Renamed project in another directory");
    const after = try project.snapshot.identity(t.allocator, model.current.snapshot, model.board);
    try t.expectEqualSlices(u8, &before.digest, &after.digest);
    var labels = try desktop.label_cache.LabelCache.init(t.allocator, 1, 2);
    defer labels.deinit();
    labels.entries[0].label = "a";
    const mapping = desktop.practice_context.mapping(&labels, "stable OS source");
    labels.entries[0].caption = "New display caption";
    try t.expectEqualSlices(u8, &mapping, &desktop.practice_context.mapping(&labels, "stable OS source"));
    labels.entries[0].label = "z";
    try t.expect(!std.mem.eql(u8, &mapping, &desktop.practice_context.mapping(&labels, "stable OS source")));
}
