//! Native compile/link evidence only. No run step and no active layout queries.
const std = @import("std");
const desktop = @import("desktop-core");
const physical_ui = @import("physical-ui");
const zkeymap = @import("zkeymap");

const FixtureTranslator = struct {
    pub fn keyToText(_: *@This(), _: zkeymap.KeyCodeFire) zkeymap.TextResult {
        return .{ .data = .{ 'a', 0, 0, 0 }, .len = 1 };
    }
};

pub fn main() void {}

export fn desktopPathsCompileProbe(view: *@import("paths-ui").View, model: *const desktop.model.Model) void {
    const paths = @import("paths-ui");
    if (paths.draw(view, model, .{}, @import("editor-ui").Theme.get(false), "") catch null) |action| {
        var request = paths.request(action, view.*, model, null) catch return;
        request.deinit();
    }
}

export fn desktopEditorFrameCompileProbe(
    view: *@import("editor-frame-ui").View,
    owner: *desktop.editor_dispatch.State,
    model: *desktop.model.Model,
    frame: *const @import("editor-frame-ui").Frame,
) void {
    _ = @import("editor-frame-ui").draw(view, owner, model, frame.*) catch null;
}

export fn desktopToolbarCompileProbe(
    view: *@import("toolbar-ui").View,
    model: *const desktop.model.Model,
    frame: *const @import("toolbar-ui").Frame,
) void {
    _ = @import("toolbar-ui").draw(view, model, frame.*) catch null;
}

export fn desktopKeyboardCompileProbe(
    view: *@import("keyboard-ui").View,
    model: *const desktop.model.Model,
    frame: *const @import("keyboard-ui").Frame,
) void {
    _ = @import("keyboard-ui").draw(
        view,
        model,
        frame.*,
        @import("editor-ui").Theme.get(false),
    ) catch null;
}

export fn desktopHostPaletteSourceCompileProbe(
    allocator: *const std.mem.Allocator,
    source: *@import("input-source").Source,
) void {
    var cache = desktop.host_palette.Cache.init(
        allocator.*,
        desktop.labels.running_host,
        source.id(),
        1,
        source,
    ) catch return;
    cache.deinit();
}

export fn desktopHostPaletteCompileProbe(
    view: *@import("host-palette-ui").View,
    model: *const desktop.model.Model,
    cache: *const desktop.host_palette.Cache,
) void {
    _ = @import("host-palette-ui").draw(view, model, cache, @import("editor-ui").Theme.get(false)) catch null;
}

export fn desktopLayerCompileProbe(view: *@import("layer-ui").View, model: *const desktop.model.Model) void {
    _ = @import("layer-ui").draw(view, model, @import("editor-ui").Theme.get(false)) catch null;
}

export fn physicalViewCompileProbe(allocator: *const std.mem.Allocator) void {
    probe(allocator.*) catch {};
}

fn probe(gpa: std.mem.Allocator) !void {
    var labels = try desktop.label_cache.LabelCache.init(gpa, 1, 1);
    defer labels.deinit();
    labels.entries[0].caption = "Unicode caption æλ";
    const geometry = [_]@import("layout-model").physical_layout.Key{.{
        .id = 500,
        .key_index = 0,
        .x = 0,
        .y = 0,
        .rotation = 15,
        .hand = .neutral,
    }};
    var output: [1]desktop.physical_view.DrawKey = undefined;
    const plan = try desktop.physical_view.plan(
        &output,
        &geometry,
        &labels,
        0,
        .{},
        .{ .w = 200, .h = 100 },
        .{ .pressed = &.{true}, .targets = &.{true} },
    );
    try physical_ui.draw(0, plan, .{});
    if (@import("desktop-audit-options").vectors) {
        output[0].content.caption = null;
        output[0].content.icon = @import("icon-resources").gui_icon;
        output[0].content.icon_name = "command";
        output[0].content.hold_mods = .{ .left_gui = true };
        try physical_ui.draw(0, plan, .{ .gui_icon = @import("icon-resources").gui_icon });
    }
    try physical_ui.drawLayerGrid(10, 15, 100, 1);
    var template = try @import("project").profiles.create(gpa, .qwerty);
    defer template.deinit();
    var log_labels = try desktop.label_cache.LabelCache.init(
        gpa,
        template.snapshot.document.layers.len,
        template.snapshot.document.key_ids.len,
    );
    defer log_labels.deinit();
    var log = physical_ui.log.LogComponent{};
    log.record(.{ .pressed = true, .key_index = 0, .layer = 0, .modifiers = .{} }, 1000);
    try log.draw(template.snapshot.document, &log_labels, 300, 200, 1);
    var encoder_document = template.snapshot.document;
    encoder_document.encoders = &.{.{ .key_press = .{ .tap_keycode = 4 } }};
    var translator = FixtureTranslator{};
    const icon_resolver = if (@import("desktop-audit-options").vectors) @import("icon-resources").resolver() else null;
    var encoders = try desktop.label_cache.buildEncoderCache(
        gpa,
        &translator,
        encoder_document,
        icon_resolver,
    );
    defer encoders.deinit();
    var encoder = physical_ui.encoder.EncoderComponent{};
    try encoder.handleSignal(0, encoders.action_count, 1000);
    try encoder.draw(0, &encoders, .{}, 1001, 100, 100, 50, 1);
    encoder.reset();
    var tutor = desktop.practice_controller.Controller.init(@splat(1));
    _ = try tutor.start(true, null, 0);
    var tutor_view = @import("practice-ui").View{};
    const tutor_input: @import("practice-ui").Input = .{ .now_us = 1000, .fixture = true, .frame = .{
        .source = .draft,
        .labels = &labels,
        .geometry = &geometry,
        .profile = "Offline fixture",
        .pressed = &.{false},
    } };
    const result = try @import("practice-ui").draw(
        &tutor,
        &tutor_view,
        @import("editor-ui").Theme.get(false),
        .{ .w = 1100, .h = 800 },
        tutor_input,
    );
    if (result.action) |action| {
        _ = try @import("practice-ui").apply(
            &tutor,
            &tutor_view,
            action,
            tutor_input,
        );
    }
}

export fn desktopDraftInputCompileProbe(
    router: *@import("desktop-core").draft_input.Router,
    tutor: *@import("desktop-core").practice_controller.Controller,
    event: *const @import("dvui_backend").c.SDL_Event,
) void {
    _ = @import("native-draft-input").route(router, tutor, event);
}

export fn desktopFreeCompanionCompileProbe(
    frame: *const desktop.live_keyboard.Frame,
    keys: [*]const @import("layout-model").physical_layout.Key,
    count: usize,
) void {
    @import("practice-ui").drawFreeCompanion(
        frame.*,
        keys[0..count],
        @import("editor-ui").Theme.get(false),
        .{ .w = 1000, .h = 400 },
        .{},
    ) catch {};
}

export fn desktopActionFormCompileProbe(
    draft: *desktop.action_form.Draft,
    document: *const @import("project").Document,
) void {
    @import("action-form-ui").draw(draft, document.*) catch {};
}

export fn desktopActionDrawerCompileProbe(
    session: *desktop.action_form.Session,
    model: *const desktop.model.Model,
) void {
    _ = @import("action-drawer-ui").draw(
        session,
        model,
        @import("editor-ui").Theme.get(false),
        .{ .w = 600, .h = 700 },
    ) catch {};
}

export fn desktopInspectorCompileProbe(
    session: *desktop.inspector_session.Session,
    model: *const desktop.model.Model,
    view: *@import("inspector-ui").View,
) void {
    _ = @import("inspector-ui").draw(
        session,
        model,
        view,
        @import("editor-ui").Theme.get(false),
        false,
    ) catch null;
}

export fn desktopComboCompileProbe(
    session: *desktop.combo_editor.Session,
    model: *const desktop.model.Model,
) void {
    _ = @import("combo-ui").draw(session, model, @import("editor-ui").Theme.get(false), "") catch null;
}

export fn desktopCallbackCompileProbe(
    view: *@import("callback-ui").View,
    model: *const desktop.model.Model,
) void {
    const callback = @import("callback-ui");
    if (callback.draw(view, model, @import("editor-ui").Theme.get(false), "") catch null) |action| {
        var request = callback.request(action, view.*, model) catch return;
        request.deinit();
    }
}
