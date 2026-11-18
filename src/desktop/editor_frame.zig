//! Native frame composition. Document dispatch happens after retained controls draw.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const toolbar = @import("toolbar-ui");
const layers = @import("layer-ui");
const keyboard = @import("keyboard-ui");
const host = @import("host-palette-ui");
const inspector = @import("inspector-ui");
const combos = @import("combo-ui");
const callbacks = @import("callback-ui");
const paths = @import("paths-ui");
const encoders = @import("encoder-ui");
const dispatch = desktop.editor_dispatch;

pub const Frame = struct {
    toolbar: toolbar.Frame,
    keyboard: keyboard.Frame,
    host: *const desktop.host_palette.Cache,
    paths: paths.Frame = .{},
};

/// Automatic saving of the open layout. The application saves once the draft
/// has rested for a moment and the editor is idle.
pub const Autosave = struct {
    /// The draft snapshot last seen and when it changed.
    observed: [32]u8 = @splat(0),
    changed_ms: u64 = 0,
    failed: bool = false,
    /// A layout to open once the current one is saved.
    queued: ?[4096]u8 = null,
};

pub const View = struct {
    scroll: dvui.ScrollInfo = .{ .horizontal = .auto },
    toolbar: toolbar.View = .{},
    layers: layers.View = .{},
    keyboard: keyboard.View = .{},
    host: host.View = .{},
    inspector: inspector.View = .{},
    modal: enum { none, combo, callback, paths, encoders } = .none,
    combo: ?desktop.combo_editor.Session = null,
    encoders: ?desktop.encoder_editor.Session = null,
    callback: callbacks.View = .{},
    paths: paths.View = .{},
    autosave: Autosave = .{},
    diagnostic: [512]u8 = @splat(0),

    pub fn report(self: *View, failure: anyerror) void {
        self.diagnostic = @splat(0);
        const name = @errorName(failure);
        const len = @min(name.len, self.diagnostic.len - 1);
        @memcpy(self.diagnostic[0..len], name[0..len]);
    }
};

/// What the frame asks the application to do. `layout` carries a command of the
/// layout menu in the editor head.
pub const Result = union(enum) {
    effect: dispatch.Effect,
    callback: callbacks.Action,
    paths: paths.Action,
    layout: toolbar.layout_menu.Command,
};

const none: Result = .{ .effect = .none };

/// What the panels requested this frame. At most one request is kept; earlier
/// panels win.
const Requests = struct {
    request: ?dispatch.Request = null,
    inspector: ?desktop.inspector_action.Action = null,
    recovery: ?dispatch.Recovery = null,

    fn offer(self: *Requests, request: dispatch.Request) void {
        if (self.request == null) self.request = request;
    }
};

const Modal = union(enum) {
    combo: combos.Result,
    callback: callbacks.Action,
    paths: paths.Action,
    encoders: encoders.Result,
};

pub fn draw(view: *View, owner: *dispatch.State, model: *desktop.model.Model, frame: Frame) !Result {
    var stale = false;
    owner.sync(model) catch |err| switch (err) {
        error.StaleInspectorSession => stale = true,
        else => return err,
    };
    const theme = ui.Theme.get(view.toolbar.light);
    dvui.themeSet(ui.dvuiTheme(dvui.currentWindow(), view.toolbar.light));
    const column = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{}, .margin = .{} });
    defer column.deinit();
    const diagnostic = std.mem.sliceTo(&view.diagnostic, 0);
    // Retained panels use a fixed design canvas. Scroll the canvas rather than
    // clipping controls when the host window is smaller than that design.
    const scroll = dvui.scrollArea(@src(), .{ .scroll_info = &view.scroll }, .{
        .expand = .both,
        .padding = .{},
        .border = .{},
        .background = false,
    });
    defer scroll.deinit();
    const canvas = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = 1536, .h = 1024 + desktop.geometry.status_height },
        .padding = .{},
        .margin = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
    });
    defer canvas.deinit();

    const requests = try drawPanels(view, owner, model, frame, theme, diagnostic, stale);
    const modal: ?Modal = switch (view.modal) {
        .none => null,
        .combo => if (try combos.draw(&view.combo.?, model, theme, diagnostic)) |result| .{ .combo = result } else null,
        .callback => if (try callbacks.draw(&view.callback, model, theme, diagnostic)) |action| .{ .callback = action } else null,
        .paths => if (try paths.draw(&view.paths, model, frame.paths, theme, diagnostic)) |action| .{ .paths = action } else null,
        .encoders => if (try encoders.draw(&view.encoders.?, model, theme, diagnostic)) |result| .{ .encoders = result } else null,
    };

    // Every document mutation below happens after drawing all retained controls.
    if (requests.recovery) |rendered| {
        try owner.discardStale(model, rendered);
        return none;
    }
    if (modal) |result| return applyModal(view, owner, model, result, stale);
    if (stale or view.modal != .none) return none;
    if (view.toolbar.command) |command| if (requests.request == null and requests.inspector == null) return .{ .layout = command };
    const effect = if (requests.inspector) |action|
        try owner.inspect(model, action)
    else if (requests.request) |captured|
        try owner.request(model, captured)
    else
        dispatch.Effect.none;
    if (effect == .open and try openModal(view, model, effect.open)) return none;
    return .{ .effect = effect };
}

fn drawPanels(
    view: *View,
    owner: *dispatch.State,
    model: *desktop.model.Model,
    frame: Frame,
    theme: ui.Theme,
    diagnostic: []const u8,
    stale: bool,
) !Requests {
    var requests: Requests = .{};
    var toolbar_frame = frame.toolbar;
    toolbar_frame.diagnostic = diagnostic;
    requests.request = try toolbar.draw(&view.toolbar, model, toolbar_frame);
    if (try layers.draw(&view.layers, model, theme)) |action| requests.offer(dispatch.Request.fromLayer(action, model));
    dropStaleHostDrag(view, model, frame.host);
    view.keyboard.drag = view.host.drag;
    if (try keyboard.draw(&view.keyboard, model, frame.keyboard, theme)) |action| switch (action) {
        .select => |selected| requests.offer(dispatch.Request.fromKey(selected)),
        .chord => |chord| {
            view.host.drag = null;
            requests.offer(dispatch.Request.fromChord(chord));
        },
        .combo, .encoders => |captured| if (requests.request == null) {
            var opened = dispatch.Request.fromKey(captured);
            opened.intent = .{ .open = if (action == .combo) .combo else .encoders };
            requests.request = opened;
        },
    };
    if (stale) {
        requests.recovery = try drawStaleRecovery(owner, model, theme);
    } else {
        view.inspector.pending = owner.pending != null;
        view.inspector.close_requested = owner.close_requested != null;
        view.inspector.drag_chord = if (view.host.drag) |drag| drag.chord else null;
        requests.inspector = try inspector.draw(&owner.inspector, model, &view.inspector, theme, view.toolbar.light);
        if (view.host.drag != null and view.inspector.drag_chord == null) view.host.drag = null;
    }
    if (try host.draw(&view.host, model, frame.host, theme)) |action| requests.offer(dispatch.Request.fromChord(action));
    const practice_open = launcher(theme, .testing, .{
        .title = "Try it out",
        .subtitle = "Practice typing this layout",
        .button = "Open tutor",
        .tag = "practice.open",
    });
    if (practice_open and requests.request == null) requests.request = try dispatch.Request.capture(model, .{ .open = .practice });
    const callbacks_open = launcher(theme, .callbacks, .{
        .title = "Callbacks",
        .subtitle = if (model.document().callbacks.len == 0)
            "No source attached"
        else
            "Source snapshot preserved",
        .button = "Manage",
        .tag = "callback.attach",
    });
    if (callbacks_open and requests.request == null) requests.request = try dispatch.Request.capture(model, .{ .open = .callback });
    return requests;
}

/// Validates a host-palette drag before either target panel sees it.
fn dropStaleHostDrag(view: *View, model: *desktop.model.Model, palette: *const desktop.host_palette.Cache) void {
    if (view.host.source_revision != null and view.host.source_revision.? != palette.revision) cancelHostDrag(view);
    if (view.host.drag) |drag| drag.validate(model) catch cancelHostDrag(view);
}

fn cancelHostDrag(view: *View) void {
    view.host.drag = null;
    if (dvui.dragName("key_chord")) dvui.dragEnd();
}

/// Replaces the inspector while its session is stale. Returns the recovery to
/// apply when the user discards the staged edits.
fn drawStaleRecovery(owner: *dispatch.State, model: *desktop.model.Model, theme: ui.Theme) !?dispatch.Recovery {
    const rendered = try owner.recovery(model);
    const box = ui.panel(theme, .inspector);
    defer box.deinit();
    dvui.label(@src(), "Project changed · staged edits are preserved", .{}, .{});
    for (owner.inspector.selected, 0..) |selected, index| if (selected) {
        var summary: [1024]u8 = undefined;
        const action = desktop.labels.action(owner.inspector.drafts[index], &summary);
        const line = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}: {s}", .{ owner.inspector.key_storage[index], action });
        ui.richLabel(line, theme.captionStyle(14, index), .{ .expand = .horizontal });
    };
    if (dvui.button(@src(), "Discard stale staged edits", .{}, .{})) return rendered;
    return null;
}

const Launcher = struct { title: []const u8, subtitle: []const u8, button: []const u8, tag: []const u8 };

/// A panel with a title, a subtitle and one button that opens another view.
fn launcher(theme: ui.Theme, which: desktop.geometry.Panel, content: Launcher) bool {
    const box = ui.panel(theme, which);
    defer box.deinit();
    ui.label(theme, content.title, .{ .x = 20, .y = 18, .w = 112, .h = 22 }, 15);
    var muted = theme;
    muted.text = theme.muted;
    ui.label(muted, content.subtitle, .{ .x = 20, .y = 52, .w = 206, .h = 18 }, 12);
    return ui.iconButton(theme, null, content.button, content.tag, .{ .x = 134, .y = 12, .w = 94, .h = 30 }, false);
}

fn ensureIdle(owner: *const dispatch.State) !void {
    if (owner.inspector.dirty() or owner.pending != null) return error.PendingEditorRequest;
}

fn applyModal(view: *View, owner: *dispatch.State, model: *desktop.model.Model, modal: Modal, stale: bool) !Result {
    switch (modal) {
        .combo => |result| try applySession(view, owner, model, stale, "combo", result),
        .encoders => |result| try applySession(view, owner, model, stale, "encoders", result),
        .callback => |action| {
            try callbacks.validate(action, view.callback, model);
            return try forwardAction(view, owner, stale, action, .{ .callback = action });
        },
        .paths => |action| {
            try paths.validate(action, view.paths, model);
            return try forwardAction(view, owner, stale, action, .{ .paths = action });
        },
    }
    return none;
}

/// Closes an editing session or dispatches its rendered action into the model.
fn applySession(
    view: *View,
    owner: *dispatch.State,
    model: *desktop.model.Model,
    stale: bool,
    comptime field: []const u8,
    result: anytype,
) !void {
    switch (result) {
        .close => {
            view.modal = .none;
            @field(view, field) = null;
        },
        .action => |rendered| {
            if (stale) return;
            try ensureIdle(owner);
            try @field(view, field).?.dispatch(model, rendered);
        },
    }
}

/// Closes the modal, or forwards its action to the application once no editor
/// request is outstanding. Cancellation is always forwarded.
fn forwardAction(view: *View, owner: *dispatch.State, stale: bool, action: anytype, forwarded: Result) !Result {
    if (action.kind == .close) {
        view.modal = .none;
        return none;
    }
    if (action.kind == .cancel) return forwarded;
    if (stale) return none;
    try ensureIdle(owner);
    return forwarded;
}

/// Opens the modal named by a dispatch effect. Returns false for effects that
/// the application handles.
fn openModal(view: *View, model: *desktop.model.Model, target: @FieldType(dispatch.Effect, "open")) !bool {
    switch (target) {
        .combo => {
            view.combo = try desktop.combo_editor.Session.init(model);
            view.modal = .combo;
        },
        .callback => view.modal = .callback,
        .paths => view.modal = .paths,
        .encoders => {
            view.encoders = try desktop.encoder_editor.Session.init(model);
            view.modal = .encoders;
        },
        else => return false,
    }
    return true;
}
