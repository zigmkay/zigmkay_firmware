//! The Export Zig source sheet. Project files save automatically; source and
//! filesystem IO stay with the caller.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const project = @import("project");
const ui = @import("editor-ui");

pub const Kind = enum { choose_project, choose_export, open, open_discard, save, export_zig, reveal_export, restore, overlay, cancel, close };

pub const Action = struct { snapshot: [32]u8, kind: Kind, project: [4096]u8, exported: [4096]u8 };

pub const View = struct {
    project: [4096]u8 = @splat(0),
    exported: [4096]u8 = @splat(0),

    /// Captures the current fields so the caller can detect edits made after drawing.
    pub fn action(self: View, snapshot: [32]u8, kind: Kind) Action {
        return .{ .snapshot = snapshot, .kind = kind, .project = self.project, .exported = self.exported };
    }
};

pub const Frame = struct {
    exported: ?[32]u8 = null,
    can_choose: bool = false,
    busy: bool = false,
    /// The keyboard and PCB revision of the layout.
    keyboard: []const u8 = "",
};

/// Requests `kind` when `clicked`, unless an earlier control already requested one.
fn offer(result: *?Action, view: *const View, snapshot: [32]u8, clicked: bool, kind: Kind) void {
    if (clicked and result.* == null) result.* = view.action(snapshot, kind);
}

const width: f32 = 900;
const height: f32 = 560;

pub fn draw(view: *View, model: *const desktop.model.Model, frame: Frame, theme: ui.Theme, diagnostic: []const u8) !?Action {
    const captured = try model.id();
    const doc = model.document();
    const sheet = ui.sheet(@src(), theme, width, height, "file.paths");
    defer sheet.deinit();
    var result: ?Action = null;
    var muted = theme;
    muted.text = theme.muted;
    ui.label(theme, "Export Zig source", .{ .x = 28, .y = 26, .w = 600, .h = 30 }, 22);
    ui.label(muted, "Writes this layout as a firmware keymap folder. Existing different files are kept; nothing is flashed.", .{ .x = 28, .y = 62, .w = 820, .h = 20 }, 14);
    offer(&result, view, captured, ui.iconButton(theme, ui.control_icons.remove, "", "file.close", .{ .x = width - 58, .y = 22, .w = 30, .h = 30 }, false), .close);

    ui.label(muted, "Layout", .{ .x = 28, .y = 104, .w = 200, .h = 16 }, 12);
    summaryCard(theme, doc, frame.keyboard);

    ui.label(muted, "Destination folder", .{ .x = 28, .y = 214, .w = 300, .h = 16 }, 12);
    var field = ui.options(theme, .{ .x = 28, .y = 232, .w = 712, .h = 40 }, 14);
    field.background = true;
    field.border = .all(1);
    field.corners = .all(8);
    field.padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 };
    field.tag = "file.export_directory";
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.exported } }, field);
    entry.deinit();
    const choose = ui.iconButtonEnabled(theme, ui.control_icons.folder, "Choose…", "file.choose_export", .{ .x = 750, .y = 232, .w = 122, .h = 40 }, false, frame.can_choose);
    offer(&result, view, captured, choose, .choose_export);

    ui.label(muted, "Checks", .{ .x = 28, .y = 302, .w = 200, .h = 16 }, 12);
    try drawChecks(theme, doc, frame, captured);
    if (diagnostic.len != 0) {
        var failure = theme;
        failure.text = ui.color(0xF06B73);
        ui.label(failure, diagnostic, .{ .x = 28, .y = 440, .w = 844, .h = 20 }, 13);
    }

    const footer = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 0, .y = height - 92, .w = width, .h = 1 },
        .background = true,
        .color_fill = .{ .color = theme.border },
        .padding = .{},
        .margin = .{},
    });
    footer.deinit();
    const reveal = ui.iconButtonEnabled(theme, ui.control_icons.open, "Show exported", "file.reveal_export", .{ .x = 28, .y = height - 68, .w = 168, .h = 40 }, false, frame.exported != null);
    offer(&result, view, captured, reveal, .reveal_export);
    if (frame.busy) {
        offer(&result, view, captured, ui.iconButton(theme, null, "Stop", "file.cancel", .{ .x = width - 256, .y = height - 68, .w = 104, .h = 40 }, false), .cancel);
    } else {
        offer(&result, view, captured, ui.iconButton(theme, null, "Cancel", "file.dismiss", .{ .x = width - 256, .y = height - 68, .w = 104, .h = 40 }, false), .close);
    }
    const exported = ui.iconButtonEnabled(theme, ui.control_icons.export_source, "Export", "file.export", .{ .x = width - 142, .y = height - 68, .w = 114, .h = 40 }, true, !frame.busy);
    offer(&result, view, captured, exported, .export_zig);
    return result;
}

/// The layout as one line: its name and what it contains.
fn summaryCard(theme: ui.Theme, doc: project.Document, keyboard: []const u8) void {
    const card = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 28, .y = 122, .w = 844, .h = 64 },
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
    });
    card.deinit();
    dvui.icon(@src(), "export.keyboard", ui.control_icons.keyboard, .{}, .{
        .color_text = .{ .color = ui.layerColor(theme, 0) },
        .rect = .{ .x = 48, .y = 142, .w = 24, .h = 24 },
        .padding = .{},
        .margin = .{},
    });
    var bold = theme;
    bold.text = theme.text;
    ui.label(bold, doc.name, .{ .x = 88, .y = 133, .w = 760, .h = 20 }, 15);
    var muted = theme;
    muted.text = theme.muted;
    var buffer: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&buffer, "{s} · {d} layers · {d} {s} · {s}", .{
        keyboard,
        doc.layers.len,
        doc.combos.len,
        if (doc.combos.len == 1) "combo" else "combos",
        if (doc.callbacks.len == 0) "no callbacks" else "callback source attached",
    }) catch doc.name;
    ui.label(muted, detail, .{ .x = 88, .y = 157, .w = 760, .h = 18 }, 12);
}

/// Recovery and layer reachability, and whether the last export is current.
fn drawChecks(theme: ui.Theme, doc: project.Document, frame: Frame, captured: [32]u8) !void {
    const advisory = try project.assessment.assess(doc);
    var unreachable_count: usize = 0;
    for (doc.layers, 0..) |_, index| {
        if (!advisory.reachable[index]) unreachable_count += 1;
    }
    var buffer: [128]u8 = undefined;
    const layers = if (unreachable_count == 0)
        "Every layer reachable from Base"
    else
        std.fmt.bufPrint(&buffer, "{d} layers have no declarative path from Base", .{unreachable_count}) catch "Some layers are unreachable";
    check(theme, 0, advisory.recovery_found, if (advisory.recovery_found) "Recovery combo reachable from Base" else "No declarative recovery action found");
    check(theme, 1, unreachable_count == 0, layers);
    if (advisory.callbacks_require_review) check(theme, 2, false, "Callback source needs review before flashing");
    const state = if (frame.exported) |id|
        (if (std.mem.eql(u8, &id, &captured)) "Last export matches this layout" else "Last export is older than this layout")
    else
        "Not exported in this session";
    info(theme, if (advisory.callbacks_require_review) 3 else 2, state);
}

fn check(theme: ui.Theme, row: usize, passed: bool, text: []const u8) void {
    const y = 322 + @as(f32, @floatFromInt(row)) * 28;
    const tint = if (passed) ui.color(0x6EC59A) else ui.color(0xF59E0B);
    dvui.icon(@src(), "export.check", if (passed) ui.control_icons.saved else ui.control_icons.warning, .{}, .{
        .id_extra = row,
        .color_text = .{ .color = tint },
        .rect = .{ .x = 28, .y = y + 2, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
    ui.label(theme, text, .{ .x = 54, .y = y, .w = 800, .h = 20 }, 14);
}

fn info(theme: ui.Theme, row: usize, text: []const u8) void {
    const y = 322 + @as(f32, @floatFromInt(row)) * 28;
    dvui.icon(@src(), "export.info", ui.control_icons.info, .{}, .{
        .color_text = .{ .color = theme.muted },
        .rect = .{ .x = 28, .y = y + 2, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
    var muted = theme;
    muted.text = theme.muted;
    ui.label(muted, text, .{ .x = 54, .y = y, .w = 800, .h = 20 }, 14);
}

pub fn validate(action: Action, view: View, model: *const desktop.model.Model) !void {
    if (!std.meta.eql(action, view.action(try model.id(), action.kind))) return error.StaleProjectAction;
}

/// A completed save acknowledges disk IO for the same path, independently of edits.
pub fn validateCompletion(action: Action, view: View, model: *const desktop.model.Model) !void {
    if (action.kind != .save) return validate(action, view, model);
    if (!std.meta.eql(action.project, view.project)) return error.StaleProjectAction;
}

pub fn request(
    action: Action,
    view: View,
    model: *const desktop.model.Model,
    selected_board: ?project.Board,
) !desktop.project_files.Request {
    try validate(action, view, model);
    const target = std.mem.sliceTo(&action.project, 0);
    const board = selected_board orelse model.board;
    return switch (action.kind) {
        .open => desktop.project_files.Request.openForBoard(model, target, board),
        .open_discard => desktop.project_files.Request.openDiscardConfirmed(model, target, board),
        .save => desktop.project_files.Request.capture(model, .save, target),
        .export_zig => desktop.project_files.Request.capture(model, .export_zig, std.mem.sliceTo(&action.exported, 0)),
        else => error.InvalidProjectIntent,
    };
}
