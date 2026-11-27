//! Retained editor head: the Keyboard › Layout breadcrumb, the work flow and
//! the document controls, over explicit layout inventory and build capabilities.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
pub const layout_menu = @import("layout_menu.zig");
const dispatch = desktop.editor_dispatch;
const flow = desktop.build_flash_state;
const activity = desktop.build_activity;

/// Where the open layout stands relative to its saved project.
pub const Save = enum {
    saved,
    /// Edited; an automatic save follows shortly.
    pending,
    saving,
    failed,
    /// Not saved automatically, such as before a project is chosen.
    manual,
};

pub const Frame = struct {
    keyboard_name: []const u8,
    connection: []const u8,
    /// The layouts of this keyboard, for the layout menu.
    layouts: []const layout_menu.Choice = &.{},
    save: Save = .saved,
    /// The status row, the Build and Flash buttons and the Details headline.
    state: flow.State = .{},
    /// The session's Build and Flash timeline and the last compiler output.
    activity: ?*const activity.Log = null,
    diagnostic: []const u8 = "",
    now_ms: u64 = 0,
    /// Whether the head may animate: the window is shown and focused.
    animate: bool = false,
};

pub const Tab = enum { activity, output };

/// When a button took its current style, for its motion.
pub const Motion = struct {
    style: ?flow.Style = null,
    since_ms: u64 = 0,
};

pub const View = struct {
    light: bool = false,
    auto_build: bool = false,
    details_open: bool = false,
    details_tab: Tab = .activity,
    /// Details already switched to the compiler output for this failure.
    output_shown: bool = false,
    build_motion: Motion = .{},
    flash_motion: Motion = .{},
    /// Whether the layout menu is open.
    menu_open: bool = false,
    /// The layout menu command chosen this frame, for the application.
    command: ?layout_menu.Command = null,
    /// The layout crumb is a name field while renaming.
    renaming: bool = false,
    rename_frames: u8 = 0,
    rename: [129]u8 = @splat(0),
};

/// Captures `intent` when `clicked`, unless an earlier control already requested one.
fn offer(result: *?dispatch.Request, model: *const desktop.model.Model, clicked: bool, intent: dispatch.Intent) !void {
    if (clicked and result.* == null) result.* = try dispatch.Request.capture(model, intent);
}

/// The head reads Keyboard › Layout, then the order of work: build, flash.
/// Saving is automatic; undo, redo and the theme sit at the right edge.
pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame) !?dispatch.Request {
    const theme = ui.Theme.get(view.light);
    const icons = ui.control_icons;
    const box = ui.panel(theme, .toolbar);
    defer box.deinit();
    const width = box.data().contentRect().w;
    var result: ?dispatch.Request = null;
    view.command = null;
    ui.label(theme, "Zigmkay", .{ .x = 24, .y = 17, .w = 110, .h = 30 }, 23);
    const keyboards = ui.iconButton(theme, icons.keyboard, frame.keyboard_name, "keyboard.collection", .{ .x = 140, .y = 14, .w = 196, .h = 36 }, false);
    try offer(&result, model, keyboards, .{ .open = .keyboards });
    flowArrow(theme, 340);
    const crumb: dvui.Rect = .{ .x = 360, .y = 14, .w = 240, .h = 36 };
    if (view.renaming) {
        try offer(&result, model, drawRename(view, theme, crumb), .{ .rename_layout = view.rename });
    } else if (layout_menu.draw(theme, crumb, model.document().name, frame.layouts, undoHint(), &view.menu_open)) |command| {
        if (command == .rename) startRename(view, model.document().name) else view.command = command;
    }
    drawSave(theme, frame.save);
    const state = frame.state;
    const motion: Clock = .{ .now_ms = frame.now_ms, .animate = frame.animate };
    // Clicking a working step opens Details instead of starting it again.
    const build = flowButton(theme, state.build, "firmware.build", .{ .x = 816, .y = 14, .w = 132, .h = 36 }, &view.build_motion, motion);
    if (build and state.build.style == .working) view.details_open = true else try offer(&result, model, build, .build);
    flowArrow(theme, 952);
    const flash = flowButton(theme, state.flash, "firmware.inspect", .{ .x = 972, .y = 14, .w = 132, .h = 36 }, &view.flash_motion, motion);
    if (flash and state.flash.style == .working) view.details_open = true else try offer(&result, model, flash, .flash);
    const right = width - 16;
    const undo = ui.iconButtonEnabled(theme, icons.undo, "", "edit.undo", .{ .x = right - 132, .y = 14, .w = 36, .h = 36 }, false, model.undo_stack.items.len != 0);
    try offer(&result, model, undo, .undo);
    const redo = ui.iconButtonEnabled(theme, icons.redo, "", "edit.redo", .{ .x = right - 90, .y = 14, .w = 36, .h = 36 }, false, model.redo_stack.items.len != 0);
    try offer(&result, model, redo, .redo);
    const theme_icon = if (view.light) icons.dark else icons.light;
    if (ui.iconButton(theme, theme_icon, "", "theme.toggle", .{ .x = right - 36, .y = 14, .w = 36, .h = 36 }, false)) {
        view.light = !view.light;
    }
    drawActivity(view, theme, frame, width, motion);
    motion.schedule(state, view);
    return result;
}

fn undoHint() []const u8 {
    return if (@import("builtin").os.tag == .macos)
        "Changes save automatically · ⌘Z undoes"
    else
        "Changes save automatically · Ctrl+Z undoes";
}

fn startRename(view: *View, name: []const u8) void {
    view.rename = @splat(0);
    const len = @min(name.len, view.rename.len - 1);
    @memcpy(view.rename[0..len], name[0..len]);
    view.renaming = true;
    view.rename_frames = 0;
}

/// The layout name as a field. Enter renames; leaving the field cancels.
fn drawRename(view: *View, theme: ui.Theme, bounds: dvui.Rect) bool {
    var opts = ui.options(theme, bounds, 15);
    opts.tag = "layout.rename";
    opts.border = .all(1.5);
    opts.color_border = .{ .color = theme.accent };
    opts.corners = .all(8);
    opts.padding = .{ .x = 12, .y = 8, .w = 12, .h = 8 };
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.rename } }, opts);
    const id = entry.data().id;
    const entered = entry.enter_pressed;
    entry.deinit();
    if (view.rename_frames == 0) dvui.focusWidget(id, null, null);
    view.rename_frames +|= 1;
    const name = std.mem.sliceTo(&view.rename, 0);
    if (entered or (view.rename_frames > 2 and dvui.focusedWidgetId() != id)) view.renaming = false;
    return entered and name.len != 0;
}

/// Whether the layout is saved, shown as a quiet note next to the breadcrumb.
fn drawSave(theme: ui.Theme, save: Save) void {
    const text, const tint, const icon: ?[]const u8 = switch (save) {
        .saved => .{ "Saved", theme.success, ui.control_icons.saved },
        .pending => .{ "Edited", theme.muted, null },
        .saving => .{ "Saving…", theme.muted, null },
        .failed => .{ "Save failed · see Details", theme.danger, ui.control_icons.warning },
        .manual => return,
    };
    var x: f32 = 616;
    if (icon) |bytes| {
        dvui.icon(@src(), "save.state", bytes, .{}, .{
            .color_text = .{ .color = tint },
            .rect = .{ .x = x, .y = 25, .w = 14, .h = 14 },
            .padding = .{},
            .margin = .{},
        });
        x += 20;
    }
    var muted = theme;
    muted.text = if (save == .failed) tint else theme.muted;
    var opts = ui.options(muted, .{ .x = x, .y = 22, .w = 190, .h = 20 }, 12);
    opts.padding = .{};
    opts.tag = "file.save_state";
    dvui.labelNoFmt(@src(), text, .{ .align_y = 0.5 }, opts);
}

/// The chevron between the steps of the work flow.
fn flowArrow(theme: ui.Theme, x: f32) void {
    dvui.icon(@src(), "flow", ui.control_icons.next, .{}, .{
        .id_extra = @intFromFloat(x),
        .color_text = .{ .color = theme.muted },
        .rect = .{ .x = x, .y = 24, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
}

// Motion ----------------------------------------------------------------------

/// The frame time of the head and whether it may move. Motion is a pure
/// function of the time, so a fixture with a fixed time draws a fixed frame.
const Clock = struct {
    now_ms: u64,
    animate: bool,

    /// About 30 frames per second for the short pulse of a next step.
    const frame_us = 33_000;
    /// Work that can last minutes sweeps at ten frames per second: every
    /// frame redraws the whole editor, which at 30 frames per second kept a
    /// full core busy on Windows while the compiler needed it.
    const work_frame_us = 100_000;
    /// The background warm-up only tints its button, four times a second.
    const warmup_frame_us = 250_000;
    /// The next step pulses this long after it became the next step, then
    /// keeps a steady highlight.
    const pulse_ms = 7200;
    const glow_period_ms = 2400;

    /// 0 to 1 along a repeating cycle of `period_ms`.
    fn phase(self: Clock, period_ms: u64) f32 {
        return @as(f32, @floatFromInt(self.now_ms % period_ms)) / @as(f32, @floatFromInt(period_ms));
    }

    /// Strength of the glow of a next step: a slow pulse at first, then a
    /// steady highlight. Without animation the steady one.
    fn glow(self: Clock, since_ms: u64) f32 {
        const steady = 0.55;
        const elapsed = self.now_ms -| since_ms;
        if (!self.animate or elapsed >= pulse_ms) return steady;
        const wave = @cos(@as(f32, @floatFromInt(elapsed % glow_period_ms)) / glow_period_ms * std.math.tau);
        return 0.5 + 0.5 * wave;
    }

    /// Wakes the next frame: soon while something moves, once a second
    /// while a counter runs unseen, never when everything rests.
    fn schedule(self: Clock, state: flow.State, view: *const View) void {
        const pulsing = (state.build.style == .next and self.now_ms -| view.build_motion.since_ms < pulse_ms) or
            (state.flash.style == .next and self.now_ms -| view.flash_motion.since_ms < pulse_ms);
        const id = dvui.parentGet().extendId(@src(), 0);
        if (self.animate and state.working()) {
            dvui.timer(id, if (state.tone == .preparing) warmup_frame_us else work_frame_us);
        } else if (self.animate and pulsing) {
            dvui.timer(id, frame_us);
        } else if (state.working()) {
            dvui.timer(id, 1_000_000);
        }
    }
};

// Build and Flash buttons ------------------------------------------------------

const Palette = struct {
    fill: dvui.Color,
    border: dvui.Color,
    text: dvui.Color,
    /// The colour of a sweeping light, if the style has one.
    sweep: ?dvui.Color = null,
    sweep_period_ms: u64 = 1600,
};

fn palette(theme: ui.Theme, style: flow.Style) Palette {
    const white = ui.color(0xFFFFFF);
    return switch (style) {
        .idle => .{ .fill = theme.control, .border = theme.border, .text = theme.text },
        .off => .{
            .fill = ui.mix(theme.panel, theme.control, 0.55),
            .border = ui.mix(theme.panel, theme.border, 0.7),
            .text = ui.mix(theme.panel, theme.muted, 0.6),
        },
        .next => .{ .fill = theme.accent, .border = theme.accent, .text = white },
        .working, .queued => .{
            .fill = ui.mix(theme.panel, theme.accent, 0.2),
            .border = ui.mix(theme.panel, theme.accent, 0.7),
            .text = ui.mix(theme.text, theme.accent, 0.35),
            .sweep = ui.mix(white, theme.accent, 0.35),
        },
        .preparing => .{
            .fill = ui.mix(theme.panel, theme.warning, 0.08),
            .border = ui.mix(theme.panel, theme.warning, 0.4),
            .text = ui.mix(theme.muted, theme.warning, 0.45),
            .sweep = theme.warning,
            .sweep_period_ms = 2200,
        },
        .done => .{
            .fill = ui.mix(theme.panel, theme.success, 0.14),
            .border = ui.mix(theme.panel, theme.success, 0.5),
            .text = ui.mix(theme.text, theme.success, 0.55),
        },
        .failed => .{
            .fill = ui.mix(theme.panel, theme.danger, 0.13),
            .border = ui.mix(theme.panel, theme.danger, 0.55),
            .text = ui.mix(theme.text, theme.danger, 0.7),
        },
    };
}

fn iconBytes(icon: flow.Icon) []const u8 {
    return switch (icon) {
        .build => ui.control_icons.build,
        .flash => ui.control_icons.flash,
        .check => ui.control_icons.check,
        .warning => ui.control_icons.warning,
    };
}

/// One step of the work flow in its state's style; returns whether it was
/// clicked. A disabled step keeps its style but ignores clicks.
fn flowButton(theme: ui.Theme, button: flow.Button, tag: []const u8, r: dvui.Rect, motion: *Motion, clock: Clock) bool {
    if (motion.style != button.style) {
        motion.style = button.style;
        motion.since_ms = clock.now_ms;
    }
    const id = std.hash.Wyhash.hash(0, tag);
    const colors = palette(theme, button.style);
    var opts = ui.options(theme, r, 15);
    opts.tag = tag;
    opts.id_extra = id;
    opts.background = true;
    opts.border = .all(1);
    opts.corners = .all(8);
    opts.padding = .{};
    opts.color_fill = .{ .color = colors.fill };
    opts.color_border = .{ .color = colors.border };
    opts.color_text = .{ .color = colors.text };
    if (button.style == .next) opts.box_shadow = .{
        .color = theme.accent,
        .offset = .{},
        .shrink = -3,
        .fade = 5,
        .alpha = 0.5 * clock.glow(motion.since_ms),
    };
    var data: dvui.WidgetData = undefined;
    opts.data_out = &data;
    var clicked = false;
    if (button.enabled) {
        clicked = dvui.button(@src(), "", .{}, opts);
    } else {
        const box = dvui.box(@src(), .{}, opts);
        box.deinit();
    }
    if (colors.sweep) |light| if (clock.animate) sweep(r, id, light, clock.phase(colors.sweep_period_ms), if (button.style == .preparing) 0.22 else 0.3);
    const font = ui.editorFont(button.label, 15);
    const icon_size: f32 = 18;
    const gap: f32 = 8;
    const text_w = font.textSize(button.label).w;
    var x = r.x + (r.w - icon_size - gap - text_w) / 2;
    dvui.icon(@src(), tag, iconBytes(button.icon), .{}, .{
        .id_extra = id,
        .color_text = .{ .color = colors.text },
        .rect = .{ .x = x, .y = r.y + (r.h - icon_size) / 2, .w = icon_size, .h = icon_size },
        .padding = .{},
        .margin = .{},
    });
    x += icon_size + gap;
    const slack = font.size * 0.5;
    dvui.labelNoFmt(@src(), button.label, .{ .align_x = 0.5, .align_y = 0.5 }, .{
        .id_extra = id,
        .rect = .{ .x = x - slack, .y = r.y, .w = text_w + slack * 2, .h = r.h },
        .font = font,
        .color_text = .{ .color = colors.text },
        .padding = .{},
        .margin = .{},
    });
    if (button.tooltip.len != 0) tooltip(theme, data.borderRectScale().r, button.tooltip, id);
    return clicked;
}

/// A soft band of light crossing `r` from left to right once per period.
fn sweep(r: dvui.Rect, id: u64, light: dvui.Color, phase: f32, strength: f32) void {
    // The band is 40% of the width and starts and ends outside the button.
    const center = -0.2 + phase * 1.4;
    // dvui scales a gradient fill by its first stop's alpha, so the ramp
    // starts opaque far outside the button and fades out long before it.
    const stops = [_]dvui.Gradient.Stop{
        .{ .color = light, .offset = -1000 },
        .{ .color = light.opacity(0), .offset = center - 0.2 },
        .{ .color = light.opacity(strength), .offset = center },
        .{ .color = light.opacity(0), .offset = center + 0.2 },
    };
    const band = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = r,
        .background = true,
        .color_fill = .{ .gradient = .{ .linear = .{ .stops = &stops, .angle_degrees = 0 } } },
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
    });
    band.deinit();
}

fn tooltip(theme: ui.Theme, active: dvui.Rect.Physical, text: []const u8, id: u64) void {
    dvui.tooltip(@src(), .{ .active_rect = active, .position = .vertical, .delay = 450_000 }, "{s}", .{text}, .{
        .id_extra = id,
        .font = ui.editorFont(text, 12),
        .color_text = .{ .color = theme.text },
        .color_fill = .{ .color = theme.panel },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(6),
    });
}

// The status row ---------------------------------------------------------------

fn drawActivity(view: *View, theme: ui.Theme, frame: Frame, width: f32, clock: Clock) void {
    var state = frame.state;
    // Other editor failures, such as a failed save, still need attention.
    if (frame.diagnostic.len != 0 and (state.tone == .ready or state.tone == .next)) {
        state.tone = .failed;
        state.message = "Needs attention · open Details";
        state.hint = "";
        state.progress = .none;
    }
    if (state.show_output and !view.output_shown) view.details_tab = .output;
    view.output_shown = state.show_output;
    const row = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 16, .y = 64, .w = width - 32, .h = 36 },
        .padding = .{},
        .margin = .{},
        .tag = "editor.activity",
    });
    defer row.deinit();
    const row_width = width - 32;
    ui.divider(theme, .{ .x = 0, .y = 0, .w = row_width, .h = 1 }, 0xac71);
    drawMark(theme, state.tone, .{ .x = 4, .y = 7 }, 22, clock);
    const controls_x = row_width - 470;
    const font = ui.editorFont(state.message, 14);
    const space = controls_x - 40;
    const message_width = @min(font.textSize(state.message).w + 2, space);
    var label_options = ui.options(theme, .{ .x = 30, .y = 6, .w = message_width, .h = 26 }, 14);
    label_options.font = font;
    label_options.padding = .{};
    label_options.tag = "editor.activity.message";
    dvui.labelNoFmt(@src(), state.message, .{ .align_y = 0.5, .ellipsize = true }, label_options);
    var x = 30 + message_width + 14;
    if (state.progress != .none and x + 120 < controls_x) {
        drawProgress(theme, state.progress, .{ .x = x, .y = 16, .w = 120, .h = 4 }, clock);
        x += 120 + 14;
    }
    var muted = theme;
    muted.text = theme.muted;
    if (state.hint.len != 0 and x + 40 < controls_x) {
        var hint_options = ui.options(muted, .{ .x = x, .y = 9, .w = controls_x - 20 - x, .h = 20 }, 12);
        hint_options.font = ui.editorFont(state.hint, 12);
        hint_options.padding = .{};
        hint_options.tag = "editor.activity.hint";
        dvui.labelNoFmt(@src(), state.hint, .{ .align_y = 0.5, .ellipsize = true }, hint_options);
    }
    ui.label(muted, frame.connection, .{ .x = controls_x, .y = 10, .w = 220, .h = 20 }, 12);
    var auto_options = ui.options(theme, .{ .x = row_width - 220, .y = 8, .w = 120, .h = 22 }, 13);
    auto_options.padding = .{};
    auto_options.tag = "firmware.auto_build";
    _ = dvui.checkbox(@src(), &view.auto_build, "Auto-build", auto_options);
    if (ui.iconButton(theme, if (view.details_open) null else ui.control_icons.expand, "Details", "editor.activity.details", .{ .x = row_width - 92, .y = 5, .w = 92, .h = 26 }, false)) {
        view.details_open = !view.details_open;
    }
    if (view.details_open) drawDetails(view, theme, frame, state, clock);
}

/// The status mark in a square of `size` at `at`: a dot, a spinner, a
/// pulsing dot while the caches are prepared, or a warning mark.
fn drawMark(theme: ui.Theme, tone: flow.Tone, at: dvui.Point, size: f32, clock: Clock) void {
    const center: dvui.Point = .{ .x = at.x + size / 2, .y = at.y + size / 2 };
    switch (tone) {
        .failed => dvui.icon(@src(), "activity.failed", ui.control_icons.warning, .{}, .{
            .rect = .{ .x = center.x - 8, .y = center.y - 8, .w = 16, .h = 16 },
            .color_text = .{ .color = theme.danger },
            .padding = .{},
            .margin = .{},
        }),
        .busy => {
            const bounds: dvui.Rect = .{ .x = at.x, .y = at.y, .w = size, .h = size };
            const track = dvui.box(@src(), .{}, .{
                .rect = bounds,
                .padding = .{},
                .margin = .{},
                .border = .all(3),
                .corners = .all(size / 2),
                .color_border = .{ .color = theme.control },
            });
            track.deinit();
            if (clock.animate) {
                dvui.spinner(@src(), .{
                    .rect = bounds,
                    .min_size_content = .{ .w = size, .h = size },
                    .padding = .{},
                    .margin = .{},
                    .color_text = .{ .color = theme.accent },
                });
            } else dot(center, 4, theme.accent);
        },
        else => {
            const tint = switch (tone) {
                .ready => theme.success,
                .next => theme.accent,
                .preparing => theme.warning,
                else => theme.muted,
            };
            // The orange dot breathes between full and a third of its strength.
            const alpha: f32 = if (tone == .preparing and clock.animate)
                0.675 + 0.325 * @cos(clock.phase(1600) * std.math.tau)
            else
                1;
            dot(center, 4.5, tint.opacity(alpha));
        },
    }
}

fn dot(center: dvui.Point, radius: f32, tint: dvui.Color) void {
    const mark = dvui.box(@src(), .{}, .{
        .rect = .{ .x = center.x - radius, .y = center.y - radius, .w = radius * 2, .h = radius * 2 },
        .background = true,
        .color_fill = .{ .color = tint },
        .corners = .all(radius),
        .padding = .{},
        .margin = .{},
    });
    mark.deinit();
}

/// A thin bar: the estimated share of the warm-up, or a band that keeps
/// crossing it while no estimate exists.
fn drawProgress(theme: ui.Theme, progress: flow.Progress, r: dvui.Rect, clock: Clock) void {
    const track = dvui.box(@src(), .{}, .{
        .rect = r,
        .background = true,
        .color_fill = .{ .color = theme.control },
        .corners = .all(r.h / 2),
        .padding = .{},
        .margin = .{},
        .tag = "editor.activity.progress",
    });
    defer track.deinit();
    const start: f32, const share: f32 = switch (progress) {
        .none => return,
        .fraction => |fraction| .{ 0, fraction },
        .indeterminate => .{ if (clock.animate) clock.phase(1800) * 1.3 - 0.3 else 0.35, 0.3 },
    };
    const left = std.math.clamp(start, 0, 1);
    const right = std.math.clamp(start + share, 0, 1);
    if (right <= left) return;
    const fill = dvui.box(@src(), .{}, .{
        .rect = .{ .x = left * r.w, .y = 0, .w = (right - left) * r.w, .h = r.h },
        .background = true,
        .color_fill = .{ .color = theme.warning },
        .corners = .all(r.h / 2),
        .padding = .{},
        .margin = .{},
    });
    fill.deinit();
}

// Details ------------------------------------------------------------------------

const details_width: f32 = 640;
const details_height: f32 = 500;

fn drawDetails(view: *View, theme: ui.Theme, frame: Frame, state: flow.State, clock: Clock) void {
    const w = details_width;
    const h = details_height;
    const scale = dvui.parentGet().screenRectScale(.{}).s / dvui.windowNaturalScale();
    const screen = dvui.windowRect();
    var window = ui.frameOptions(theme.panel, 12, "editor.activity.details_panel");
    window.rect = .{ .x = @max(8, screen.w - (w + 24) * scale), .y = 108 * scale, .w = w * scale, .h = h * scale };
    window.color_text = .{ .color = theme.text };
    window.box_shadow = .{ .offset = .{ .x = 0, .y = 8 }, .fade = 24, .alpha = 0.3 };
    const popup = dvui.floatingWindow(@src(), .{ .modal = false, .resize = .none }, window);
    defer popup.deinit();
    defer ui.frameBorder(theme, window.rect.?.w, window.rect.?.h, 12);
    var muted = theme;
    muted.text = theme.muted;
    ui.label(theme, "Build and Flash activity", .{ .x = 20, .y = 18, .w = w - 80, .h = 26 }, 18);
    if (ui.iconButton(theme, ui.control_icons.remove, "", "editor.activity.dismiss", .{ .x = w - 48, .y = 16, .w = 30, .h = 30 }, false)) view.details_open = false;

    drawMark(theme, state.tone, .{ .x = 18, .y = 59 }, 20, clock);
    var strong = theme;
    strong.text = if (state.tone == .failed) theme.danger else theme.text;
    // An editor failure outside Build and Flash, such as a failed save.
    const attention = frame.diagnostic.len != 0 and state.tone == .failed and
        state.build.style != .failed and state.flash.style != .failed;
    const headline = if (attention) "Needs attention" else state.headline;
    var headline_options = ui.options(strong, .{ .x = 48, .y = 58, .w = w - 68, .h = 22 }, 15);
    headline_options.padding = .{};
    headline_options.font = headline_options.font.?.withWeight(.bold);
    headline_options.tag = "editor.activity.headline";
    dvui.labelNoFmt(@src(), headline, .{ .align_y = 0.5, .ellipsize = true }, headline_options);
    const detail = if (attention) frame.diagnostic else state.detail;
    paragraph(muted, detail, .{ .x = 48, .y = 82, .w = w - 68, .h = 36 }, 12);

    drawSteps(theme, state.steps, w);
    drawTabs(view, theme);
    const log_rect: dvui.Rect = .{ .x = 20, .y = 232, .w = w - 40, .h = h - 232 - 72 };
    switch (view.details_tab) {
        .activity => drawTimeline(theme, frame.activity, log_rect),
        .output => drawOutput(theme, frame.activity, log_rect),
    }
    if (ui.iconButton(theme, ui.control_icons.copy, "Copy details", "editor.activity.copy", .{ .x = 20, .y = h - 56, .w = 150, .h = 36 }, false)) {
        copyDetails(frame.activity, headline, detail);
    }
    if (ui.iconButton(theme, null, "Close", "editor.activity.close", .{ .x = w - 20 - 100, .y = h - 56, .w = 100, .h = 36 }, false)) view.details_open = false;
}

/// Wrapping text in `bounds`, cut at its bottom edge.
fn paragraph(theme: ui.Theme, text: []const u8, bounds: dvui.Rect, size: f32) void {
    const layout = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .rect = bounds,
        .background = false,
        .font = ui.editorFont(text, size),
        .color_text = .{ .color = theme.text },
        .padding = .{},
        .margin = .{},
    });
    layout.addText(text, .{});
    layout.deinit();
}

fn copyDetails(log: ?*const activity.Log, headline: []const u8, detail: []const u8) void {
    var text: std.Io.Writer.Allocating = .init(dvui.currentWindow().arena());
    if (log) |value| {
        value.writeDetails(&text.writer, headline, detail) catch return;
    } else {
        text.writer.print("{s}\n{s}\n", .{ headline, detail }) catch return;
    }
    dvui.clipboardTextSet(text.written());
}

fn drawTabs(view: *View, theme: ui.Theme) void {
    const tabs = [_]struct { Tab, []const u8, []const u8, f32 }{
        .{ .activity, "Activity", "editor.activity.tab.activity", 84 },
        .{ .output, "Compiler output", "editor.activity.tab.output", 132 },
    };
    var x: f32 = 20;
    for (tabs) |tab| {
        const selected = view.details_tab == tab[0];
        var opts = ui.options(theme, .{ .x = x, .y = 196, .w = tab[3], .h = 28 }, 13);
        opts.tag = tab[2];
        opts.id_extra = std.hash.Wyhash.hash(0, tab[2]);
        opts.font = ui.editorFont(tab[1], 13);
        opts.corners = .all(6);
        opts.padding = .{};
        opts.border = .all(if (selected) 1 else 0);
        opts.background = selected;
        opts.color_fill = .{ .color = if (selected) theme.control else theme.panel };
        opts.color_text = .{ .color = if (selected) theme.text else theme.muted };
        if (dvui.button(@src(), tab[1], .{}, opts)) view.details_tab = tab[0];
        x += tab[3] + 6;
    }
}

fn logBox(theme: ui.Theme, r: dvui.Rect, tag: []const u8) *dvui.BoxWidget {
    return dvui.box(@src(), .{}, .{
        .rect = r,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{ .x = 12, .y = 8, .w = 4, .h = 8 },
        .margin = .{},
        .tag = tag,
    });
}

fn monoFont() dvui.Font {
    // Matches the 12-point editor text: editor sizes scale by 0.76 for dvui.
    return dvui.Font.theme(.mono).withSize(12 * 0.76);
}

fn kindColor(theme: ui.Theme, kind: activity.Kind) dvui.Color {
    return switch (kind) {
        .info => theme.text,
        .ok => theme.success,
        .warn => theme.warning,
        .err => theme.danger,
    };
}

/// The session timeline: muted times, the lead of each line in its colour.
fn drawTimeline(theme: ui.Theme, log: ?*const activity.Log, r: dvui.Rect) void {
    const box = logBox(theme, r, "editor.activity.timeline");
    defer box.deinit();
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = .{} });
    defer scroll.deinit();
    const text = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .expand = .horizontal,
        .background = false,
        .font = monoFont(),
        .color_text = .{ .color = theme.text },
        .padding = .{},
    });
    defer text.deinit();
    const entries = log orelse {
        text.addText("Nothing has happened in this session yet.", .{});
        return;
    };
    if (entries.count == 0) text.addText("Nothing has happened in this session yet.", .{});
    for (0..entries.count) |index| {
        const entry = entries.at(index);
        var time: [8]u8 = undefined;
        if (index != 0) text.addText("\n", .{});
        text.addText(entries.clock(&time, entry.at_ms), .{ .color_text = .{ .color = theme.muted } });
        text.addText("  ", .{});
        const line = entry.text();
        const lead_end = if (entry.kind == .info) 0 else std.mem.indexOf(u8, line, " · ") orelse line.len;
        if (lead_end != 0) text.addText(line[0..lead_end], .{ .color_text = .{ .color = kindColor(theme, entry.kind) } });
        text.addText(line[lead_end..], .{});
    }
}

/// The last build's compiler output under a one-line summary.
fn drawOutput(theme: ui.Theme, log: ?*const activity.Log, r: dvui.Rect) void {
    const box = logBox(theme, r, "editor.activity.output");
    defer box.deinit();
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .background = false, .padding = .{} });
    defer scroll.deinit();
    const text = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .expand = .horizontal,
        .background = false,
        .font = monoFont(),
        .color_text = .{ .color = theme.text },
        .padding = .{},
    });
    defer text.deinit();
    const output = if (log) |value| value.output else activity.Output{};
    if (output.text.len == 0 and output.at_ms == 0) {
        text.addText("No build has finished in this session.", .{ .color_text = .{ .color = theme.muted } });
        return;
    }
    var summary: std.Io.Writer.Allocating = .init(dvui.currentWindow().arena());
    var time: [8]u8 = undefined;
    log.?.writeOutputSummary(&summary.writer, &time) catch {};
    text.addText(summary.written(), .{ .color_text = .{ .color = if (output.succeeded) theme.muted else theme.danger } });
    text.addText("\n\n", .{});
    if (output.text.len == 0) {
        text.addText("The compiler printed nothing.", .{ .color_text = .{ .color = theme.muted } });
        return;
    }
    // Located errors stand out; everything else stays plain.
    var lines = std.mem.splitScalar(u8, output.text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) text.addText("\n", .{});
        first = false;
        const located = std.mem.indexOf(u8, line, ": error: ") != null;
        text.addText(line, if (located) .{ .color_text = .{ .color = theme.danger } } else .{});
    }
}

/// Caches › Build › Flash › Reconnect as dots on a line; the current step is ringed.
fn drawSteps(theme: ui.Theme, state: [flow.step_names.len]flow.Step, w: f32) void {
    const count = flow.step_names.len;
    const left: f32 = 70;
    const right = w - 70;
    const y: f32 = 146;
    const spacing = (right - left) / @as(f32, @floatFromInt(count - 1));
    for (0..count - 1) |index| {
        const x = left + spacing * @as(f32, @floatFromInt(index));
        const line: dvui.Rect = .{ .x = x + 10, .y = y - 1, .w = spacing - 20, .h = 2 };
        ui.divider(theme, line, 40 + index);
        if (state[index] == .done and state[index + 1] != .pending) {
            const done = dvui.box(@src(), .{}, .{
                .id_extra = index,
                .rect = line,
                .background = true,
                .color_fill = .{ .color = theme.success },
                .padding = .{},
                .margin = .{},
            });
            done.deinit();
        }
    }
    for (flow.step_names, state, 0..) |name, step, index| {
        const x = left + spacing * @as(f32, @floatFromInt(index));
        const tint = switch (step) {
            .pending => theme.border,
            .active => if (index == 0) theme.warning else theme.accent,
            .done => theme.success,
            .failed => theme.danger,
        };
        const size: f32 = if (step == .active or step == .failed) 16 else 12;
        const mark = dvui.box(@src(), .{}, .{
            .id_extra = index,
            .rect = .{ .x = x - size / 2, .y = y - size / 2, .w = size, .h = size },
            .background = true,
            .color_fill = .{ .color = if (step == .active) theme.panel else tint },
            .color_border = .{ .color = tint },
            .border = .all(if (step == .active) 3 else 0),
            .corners = .all(size / 2),
            .padding = .{},
            .margin = .{},
        });
        mark.deinit();
        var caption = theme;
        caption.text = if (step == .pending) theme.muted else if (step == .failed) theme.danger else theme.text;
        var opts = ui.options(caption, .{ .x = x - 60, .y = y + 14, .w = 120, .h = 18 }, 13);
        opts.padding = .{};
        opts.background = false;
        opts.id_extra = index;
        if (step != .pending) opts.font = opts.font.?.withWeight(.bold);
        dvui.labelNoFmt(@src(), name, .{ .align_x = 0.5 }, opts);
    }
}
