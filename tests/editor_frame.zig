//! Explicit SDL dummy/software interaction fixture. No native input source/devices.
const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const project = @import("project");
const catalog = @import("catalog");
const editor = @import("editor-frame-ui");
const zkeymap = @import("zkeymap");

test "save completion accepts newer edits and export paths but rejects a changed destination" {
    const t = std.testing;
    const paths = @import("paths-ui");
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var view: paths.View = .{};
    @memcpy(view.project[0..8], "/project");
    const save = view.action(try model.id(), .save);
    const open = view.action(try model.id(), .open);
    try model.rename("Newer edit");
    view.exported[0] = 'x';
    try paths.validateCompletion(save, view, &model);
    try t.expectError(error.StaleProjectAction, paths.validateCompletion(open, view, &model));
    view.project[1] = 'x';
    try t.expectError(error.StaleProjectAction, paths.validateCompletion(save, view, &model));
}

/// Maps HID usages a–z to their letters; nothing else produces text.
const Fixture = struct {
    pub fn keyToText(_: *@This(), input: zkeymap.KeyCodeFire) zkeymap.TextResult {
        var result: zkeymap.TextResult = .{};
        if (input.tap_keycode >= 4 and input.tap_keycode <= 29) {
            result.data[0] = 'a' + input.tap_keycode - 4;
            result.len = 1;
        }
        return result;
    }
};

/// Screen rectangles of tagged widgets after one frame, for clicking in the next.
const Observed = struct {
    result: editor.Result,
    key3: dvui.Rect.Physical,
    key4: dvui.Rect.Physical,
    host_b: dvui.Rect.Physical,
    callbacks: dvui.Rect.Physical,
    crumb: dvui.Rect.Physical,
    menu_export: ?dvui.Rect.Physical,
    paths_close: ?dvui.Rect.Physical,
    encoder_close: ?dvui.Rect.Physical,
    pending_keep: ?dvui.Rect.Physical,
    pending_discard: ?dvui.Rect.Physical,
    callback_close: ?dvui.Rect.Physical,
    hold3: ?dvui.Rect.Physical,
    hold_shift: ?dvui.Rect.Physical,
    autofire: ?dvui.Rect.Physical,
    editor_close: ?dvui.Rect.Physical,
    /// The halves of the turned LK7 thumb key 31.
    tap31: ?dvui.Rect.Physical,
    hold31: ?dvui.Rect.Physical,
};

fn tagged(name: []const u8) ?dvui.Rect.Physical {
    return if (dvui.tagGet(name)) |tag| tag.rect else null;
}

const Harness = struct {
    native: *Backend,
    window: *dvui.Window,
    view: *editor.View,
    owner: *desktop.editor_dispatch.State,
    model: *desktop.model.Model,
    labels: *const desktop.label_cache.LabelCache,
    host: *const desktop.host_palette.Cache,

    /// Draws one editor frame, first clicking the center of `click` if given.
    fn frame(self: Harness, click: ?dvui.Rect.Physical) !Observed {
        try self.window.begin(self.native.nanoTime());
        errdefer _ = self.window.end(.{ .manage_backend = false }) catch {};
        if (click) |rect| {
            _ = try self.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 } });
            _ = try self.window.addEventMouseButton(.left, .press);
            _ = try self.window.addEventMouseButton(.left, .release);
        }
        const doc = self.model.document();
        const result = try editor.draw(self.view, self.owner, self.model, .{
            .toolbar = .{ .keyboard_name = "LK7", .connection = "Injected fixture" },
            .keyboard = .{
                .snapshot = try self.model.id(),
                .board_id = doc.board_id,
                .physical_layout = doc.physical_layout,
                .geometry = catalog.find("lk7").?.geometry,
                .labels = self.labels,
                .board_name = "LK7",
                .fidelity = "Curated schematic",
            },
            .host = self.host,
        });
        const observed: Observed = .{
            .result = result,
            .key3 = tagged("key.select.3") orelse return error.MissingKeyTag,
            .key4 = tagged("key.select.4") orelse return error.MissingKeyTag,
            .host_b = tagged("os.key.5") orelse return error.MissingHostTag,
            .callbacks = tagged("callback.attach") orelse return error.MissingCallbackTag,
            .crumb = tagged("layout.crumb") orelse return error.MissingLayoutTag,
            .menu_export = tagged("layout.menu.export"),
            .paths_close = tagged("file.close"),
            .encoder_close = tagged("encoder.close"),
            .pending_keep = tagged("pending.keep"),
            .pending_discard = tagged("pending.discard"),
            .callback_close = tagged("callback.close"),
            .hold3 = tagged("key.hold.3"),
            .hold_shift = tagged("key.editor.modifier.hold.1"),
            .autofire = tagged("key.editor.autofire"),
            .editor_close = tagged("key.editor.close"),
            .tap31 = tagged("key.select.31"),
            .hold31 = tagged("key.hold.31"),
        };
        _ = try self.window.end(.{ .manage_backend = false });
        self.native.renderPresent();
        return observed;
    }
};

test "composed editor handles selection pending keep/discard callback close and host assignment" {
    const t = std.testing;
    // The build runner pins dummy/software. Refuse accidentally interactive runs.
    const driver = std.c.getenv("SDL_VIDEODRIVER") orelse return error.DummyVideoRequired;
    if (!std.mem.eql(u8, std.mem.span(driver), "dummy")) return error.DummyVideoRequired;
    var native = try Backend.initWindow(.{
        .io = t.io,
        .size = .{ .w = 1536, .h = 1024 },
        .vsync = false,
        .title = "Zigmkay offline editor fixture",
        .hidden = true,
        .persist_window_geometry = false,
    });
    defer native.deinit();
    var window = try dvui.Window.init(@src(), t.allocator, native.backend(), .{});
    defer window.deinit();
    var template = try project.profiles.create(t.allocator, .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(t.allocator, project.profiles.board, template.snapshot);
    defer model.deinit();
    var owner = try desktop.editor_dispatch.State.init(&model);
    defer owner.deinit();
    var fixture: Fixture = .{};
    var labels = try desktop.label_cache.buildProjectCache(t.allocator, &fixture, model.document());
    defer labels.deinit();
    var host = try desktop.host_palette.Cache.init(t.allocator, .macos, "Injected fixture", 1, &fixture);
    defer host.deinit();
    var view: editor.View = .{};
    const harness: Harness = .{
        .native = &native,
        .window = &window,
        .view = &view,
        .owner = &owner,
        .model = &model,
        .labels = &labels,
        .host = &host,
    };

    var observed = try harness.frame(null);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.key3);
    try t.expectEqual(@as(usize, 3), model.primary);
    // Refresh selection ownership before staging a draft.
    observed = try harness.frame(null);
    owner.inspector.mutate(.{ .tap_usage = 7 });
    observed = try harness.frame(observed.key4);
    try t.expect(observed.result.effect == .pending);
    try t.expectEqual(@as(usize, 3), model.primary);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.pending_keep orelse return error.MissingPendingTag);
    try t.expect(owner.pending == null and owner.inspector.dirty());
    observed = try harness.frame(observed.key4);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.pending_discard orelse return error.MissingPendingTag);
    try t.expectEqual(@as(usize, 4), model.primary);
    try t.expectEqual(@as(usize, 0), model.undo_stack.items.len);

    observed = try harness.frame(observed.callbacks);
    try t.expect(view.modal == .callback);
    observed = try harness.frame(null);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.callback_close orelse return error.MissingModalTag);
    try t.expect(view.modal == .none);
    observed = try harness.frame(null);
    // The layout menu opens from the crumb and asks to export.
    observed = try harness.frame(observed.crumb);
    try t.expect(view.toolbar.menu_open);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.menu_export orelse return error.MissingLayoutMenuTag);
    try t.expect(observed.result == .layout and observed.result.layout == .export_source);
    view.modal = .paths;
    observed = try harness.frame(null);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.paths_close orelse return error.MissingModalTag);
    try t.expect(view.modal == .none);

    observed = try harness.frame(null);
    _ = try harness.frame(observed.host_b);
    try t.expectEqual(@as(u8, 5), model.action().?.tap_only.key_press.?.tap_keycode);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);

    view.toolbar.light = true;
    _ = try harness.frame(null);
    try t.expect(!window.theme.dark);
    view.toolbar.light = false;
    _ = try harness.frame(null);
    try t.expect(window.theme.dark);

    view.encoders = try desktop.encoder_editor.Session.init(&model);
    view.modal = .encoders;
    observed = try harness.frame(null);
    observed = try harness.frame(null);
    _ = try harness.frame(observed.encoder_close orelse return error.MissingModalTag);
    try t.expect(view.modal == .none and view.encoders == null);
    try t.expectEqual(@as(usize, 1), model.undo_stack.items.len);

    // The hold half opens the hold editor, and its edits apply at once.
    observed = try harness.frame(null);
    observed = try harness.frame(observed.hold3 orelse return error.MissingKeyTag);
    try t.expectEqual(@as(usize, 3), model.primary);
    try t.expect(view.key_editor.open == .hold);
    observed = try harness.frame(null);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.hold_shift orelse return error.MissingEditorTag);
    try t.expect(model.action().?.tap_hold.hold.hold_modifiers.left_shift);
    try t.expectEqual(@as(usize, 2), model.undo_stack.items.len);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.autofire orelse return error.MissingEditorTag);
    try t.expect(model.action().? == .tap_with_autofire);
    try t.expectEqual(@as(usize, 3), model.undo_stack.items.len);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.editor_close orelse return error.MissingEditorTag);
    try t.expect(view.key_editor.open == null);

    // The closed popover covers the thumbs until the next frame.
    observed = try harness.frame(null);
    // A turned thumb key takes clicks only on its turned halves. Key 31 turns
    // 10 degrees clockwise; this point near the top-right corner of its
    // upright tap half lies outside the turned half, and selects nothing.
    const box = observed.tap31 orelse return error.MissingKeyTag;
    observed = try harness.frame(.{ .x = box.x + box.w * 0.909, .y = box.y + box.h * 0.139, .w = 0, .h = 0 });
    try t.expect(model.primary != 31 and view.key_editor.open == null);
    observed = try harness.frame(observed.hold31 orelse return error.MissingKeyTag);
    try t.expectEqual(@as(usize, 31), model.primary);
    try t.expect(view.key_editor.open == .hold);
    observed = try harness.frame(null);
    observed = try harness.frame(observed.editor_close orelse return error.MissingEditorTag);
    try t.expect(view.key_editor.open == null);

    // A laptop-sized viewport must expose the lower action after scrolling.
    try t.expect(Backend.c.SDL_SetWindowSize(native.window, 1152, 600));
    _ = try harness.frame(null);
    try t.expect(view.scroll.virtual_size.h >= 1024);
    try t.expect(view.scroll.viewport.h < view.scroll.virtual_size.h);
    view.scroll.scrollToOffset(.vertical, std.math.floatMax(f32));
    observed = try harness.frame(null);
    try t.expect(observed.callbacks.y >= 0 and observed.callbacks.y + observed.callbacks.h <= 600);
    _ = try harness.frame(observed.callbacks);
    try t.expect(view.modal == .callback);
}
