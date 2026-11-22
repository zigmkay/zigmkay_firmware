//! Retained callback source sheet. Rendering reads no files and returns
//! explicit intents.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");

pub const Kind = enum { choose_root, attach, check, checkout, refresh, cancel, close };

pub const Action = struct {
    snapshot: [32]u8,
    kind: Kind,
    index: usize,
    root: [4096]u8,
    entry: [240]u8,
    ids: [1024]u8,
};

pub const View = struct {
    root: [4096]u8 = @splat(0),
    entry: [240]u8 = @splat(0),
    ids: [1024]u8 = @splat(0),
    index: usize = 0,
    busy: bool = false,

    /// Captures the current fields so the caller can detect edits made after drawing.
    pub fn action(self: View, snapshot: [32]u8, kind: Kind) Action {
        return .{ .snapshot = snapshot, .kind = kind, .index = self.index, .root = self.root, .entry = self.entry, .ids = self.ids };
    }
};

/// Requests `kind` when `clicked`, unless an earlier control already requested one.
fn offer(result: *?Action, view: *const View, snapshot: [32]u8, clicked: bool, kind: Kind) void {
    if (clicked and result.* == null) result.* = view.action(snapshot, kind);
}

const width: f32 = 900;
const margin: f32 = 28;
/// The top of the attached source list.
const list_top: f32 = 236;
const list_max: f32 = 308;

pub fn draw(view: *View, model: *const desktop.model.Model, theme: ui.Theme, diagnostic: []const u8) !?Action {
    const captured = try model.id();
    // The sheet grows with the attached sources, up to a scrolling list.
    const list_bottom = list_top + listHeight(model.document());
    const attach_y = list_bottom + 16;
    const footer_y = attach_y + 172;
    const height = footer_y + 84;
    const sheet = ui.sheet(@src(), theme, width, height, "callback.sheet");
    defer sheet.deinit();
    var result: ?Action = null;
    var muted = theme;
    muted.text = theme.muted;
    const explanation = "Callbacks are Zig source files you edit elsewhere. Zigmkay keeps a frozen copy until you refresh it.";
    offer(&result, view, captured, ui.sheetHeader(theme, width, "Callbacks", explanation, "callback.dismiss"), .close);

    ui.label(muted, "Source folder · where the callback files live, for attaching, checking and refreshing", .{ .x = margin, .y = 120, .w = 800, .h = 18 }, 12);
    field(theme, &view.root, "Choose the folder that holds your callback sources", "callback.root", .{ .x = margin, .y = 142, .w = 712, .h = 40 });
    const choose = ui.iconButton(theme, ui.control_icons.folder, "Choose…", "callback.choose", .{ .x = width - margin - 122, .y = 142, .w = 122, .h = 40 }, false);
    offer(&result, view, captured, choose, .choose_root);

    try drawAttached(view, model, theme, captured, &result, list_bottom);

    ui.divider(theme, .{ .x = margin, .y = attach_y, .w = width - 2 * margin, .h = 1 }, 2);
    ui.label(theme, "Attach a source file", .{ .x = margin, .y = attach_y + 16, .w = 400, .h = 22 }, 15);
    ui.label(muted, "Entry module", .{ .x = margin, .y = attach_y + 50, .w = 300, .h = 18 }, 12);
    field(theme, &view.entry, "callbacks.zig", "callback.entry", .{ .x = margin, .y = attach_y + 72, .w = 540, .h = 40 });
    ui.label(muted, "Custom IDs", .{ .x = 584, .y = attach_y + 50, .w = 288, .h = 18 }, 12);
    field(theme, &view.ids, "1–252, comma separated", "callback.ids", .{ .x = 584, .y = attach_y + 72, .w = width - margin - 584, .h = 40 });
    info(theme, "Attaching copies the entry module and every file it imports. Nothing is compiled or run.", attach_y + 130);

    ui.divider(theme, .{ .x = 0, .y = footer_y, .w = width, .h = 1 }, 1);
    const button_y = footer_y + 22;
    var status = theme;
    status.text = if (diagnostic.len != 0) theme.danger else theme.muted;
    const message = if (diagnostic.len != 0)
        diagnostic
    else if (view.busy)
        "Preparing the source snapshot · editing a field cancels its delivery"
    else
        "Sources are read only when you attach, check or refresh.";
    ui.label(status, message, .{ .x = margin, .y = button_y + 11, .w = width - 2 * margin - 290, .h = 18 }, 13);
    if (view.busy) {
        offer(&result, view, captured, ui.iconButton(theme, null, "Stop", "callback.cancel", .{ .x = width - margin - 276, .y = button_y, .w = 104, .h = 40 }, false), .cancel);
    } else {
        offer(&result, view, captured, ui.iconButton(theme, null, "Close", "callback.close", .{ .x = width - margin - 276, .y = button_y, .w = 104, .h = 40 }, false), .close);
    }
    const ready = !view.busy and std.mem.sliceTo(&view.entry, 0).len != 0 and std.mem.sliceTo(&view.ids, 0).len != 0;
    const attach = ui.iconButtonEnabled(theme, null, "Attach source", "callback.attach_source", .{ .x = width - margin - 160, .y = button_y, .w = 160, .h = 40 }, true, ready);
    offer(&result, view, captured, attach, .attach);
    return result;
}

/// A single-line text field in the sheet style.
fn field(theme: ui.Theme, buffer: []u8, placeholder: []const u8, tag: []const u8, bounds: dvui.Rect) void {
    var opts = ui.options(theme, bounds, 14);
    opts.background = true;
    opts.border = .all(1);
    opts.corners = .all(8);
    opts.padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 };
    opts.tag = tag;
    opts.id_extra = std.hash.Wyhash.hash(0, tag);
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer }, .placeholder = placeholder }, opts);
    entry.deinit();
}

fn info(theme: ui.Theme, text: []const u8, y: f32) void {
    dvui.icon(@src(), "callback.info", ui.control_icons.info, .{}, .{
        .id_extra = @intFromFloat(y),
        .rect = .{ .x = margin, .y = y + 2, .w = 15, .h = 15 },
        .color_text = .{ .color = theme.muted },
        .padding = .{},
        .margin = .{},
    });
    var muted = theme;
    muted.text = theme.muted;
    ui.label(muted, text, .{ .x = margin + 24, .y = y, .w = width - 2 * margin - 24, .h = 18 }, 12);
}

/// Callback IDs as ranges, such as "1–3, 10".
fn idRanges(ids: []const u8, buffer: []u8) []const u8 {
    var sorted: [256]u8 = undefined;
    const count = @min(ids.len, sorted.len);
    @memcpy(sorted[0..count], ids[0..count]);
    std.mem.sort(u8, sorted[0..count], {}, std.sort.asc(u8));
    var used: usize = 0;
    var index: usize = 0;
    while (index < count) {
        var end = index;
        while (end + 1 < count and sorted[end + 1] == sorted[end] + 1) end += 1;
        const separator = if (used == 0) "" else ", ";
        const part = if (end > index)
            std.fmt.bufPrint(buffer[used..], "{s}{d}–{d}", .{ separator, sorted[index], sorted[end] })
        else
            std.fmt.bufPrint(buffer[used..], "{s}{d}", .{ separator, sorted[index] });
        used += (part catch break).len;
        index = end + 1;
    }
    return buffer[0..used];
}

/// One card per callback source; attached sources offer their mirror actions.
/// The height of the attached source list: its cards, or the empty state.
fn listHeight(doc: anytype) f32 {
    if (doc.callbacks.len == 0) return 96;
    var total: f32 = 0;
    for (doc.callbacks) |callback| total += cardHeight(callback.kind == .attached) + 12;
    return @min(list_max, total - 12);
}

fn drawAttached(view: *View, model: *const desktop.model.Model, theme: ui.Theme, captured: [32]u8, result: *?Action, bottom: f32) !void {
    const doc = model.document();
    const arena = dvui.currentWindow().arena();
    var muted = theme;
    muted.text = theme.muted;
    ui.label(theme, "Attached sources", .{ .x = margin, .y = 204, .w = 400, .h = 22 }, 15);
    var all_ids: [256]u8 = undefined;
    var id_count: usize = 0;
    for (doc.callbacks) |callback| for (callback.ids) |id| {
        if (id_count < all_ids.len) all_ids[id_count] = id;
        id_count += 1;
    };
    var range_buffer: [512]u8 = undefined;
    const summary = try std.fmt.allocPrint(arena, "{d} {s} · IDs {s}", .{
        doc.callbacks.len,
        if (doc.callbacks.len == 1) "source" else "sources",
        if (id_count == 0) "none" else idRanges(all_ids[0..@min(id_count, all_ids.len)], &range_buffer),
    });
    var right = ui.options(muted, .{ .x = width - margin - 400, .y = 208, .w = 400, .h = 18 }, 12);
    right.padding = .{};
    right.background = false;
    dvui.labelNoFmt(@src(), summary, .{ .align_x = 1 }, right);
    const top = list_top;
    if (doc.callbacks.len == 0) {
        const empty = dvui.box(@src(), .{}, .{
            .rect = .{ .x = margin, .y = top, .w = width - 2 * margin, .h = 96 },
            .background = true,
            .color_fill = .{ .color = theme.bg },
            .color_border = .{ .color = theme.border },
            .border = .all(1),
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        empty.deinit();
        dvui.icon(@src(), "callback.empty", ui.control_icons.file, .{}, .{
            .rect = .{ .x = margin + 24, .y = top + 34, .w = 26, .h = 26 },
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
        ui.label(theme, "No callback source attached", .{ .x = margin + 66, .y = top + 26, .w = 700, .h = 20 }, 15);
        ui.label(muted, "Keys and combos can still send reserved companion signals. Attach a source below to add your own callbacks.", .{ .x = margin + 66, .y = top + 52, .w = 760, .h = 18 }, 12);
        return;
    }
    const scroll = dvui.scrollArea(@src(), .{}, .{
        .rect = .{ .x = margin, .y = top, .w = width - 2 * margin + 10, .h = bottom - top },
        .background = false,
        .padding = .{},
    });
    defer scroll.deinit();
    var total: f32 = 0;
    for (doc.callbacks) |callback| total += cardHeight(callback.kind == .attached) + 12;
    const content = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = width - 2 * margin, .h = total - 12 },
        .padding = .{},
        .margin = .{},
    });
    defer content.deinit();
    view.index = @min(view.index, doc.callbacks.len - 1);
    var y: f32 = 0;
    const card_w = width - 2 * margin;
    for (doc.callbacks, 0..) |callback, index| {
        const attached = callback.kind == .attached;
        const h = cardHeight(attached);
        const card = dvui.box(@src(), .{}, .{
            .id_extra = index,
            .rect = .{ .x = 0, .y = y, .w = card_w, .h = h },
            .background = true,
            .color_fill = .{ .color = theme.bg },
            .color_border = .{ .color = theme.border },
            .border = .all(1),
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        card.deinit();
        dvui.icon(@src(), "callback.file", ui.control_icons.file, .{}, .{
            .id_extra = index,
            .rect = .{ .x = 18, .y = y + 18, .w = 22, .h = 22 },
            .color_text = .{ .color = theme.text },
            .padding = .{},
            .margin = .{},
        });
        ui.label(theme, callback.binding, .{ .x = 52, .y = y + 14, .w = card_w - 380, .h = 20 }, 15);
        const detail = if (attached)
            try std.fmt.allocPrint(arena, "Entry module · {d} source {s} · frozen snapshot kept in the layout", .{
                callback.sources.len,
                if (callback.sources.len == 1) "file" else "files",
            })
        else
            "Imported with the keymap · registered by the firmware · read only";
        ui.label(muted, detail, .{ .x = 52, .y = y + 38, .w = card_w - 380, .h = 18 }, 12);
        idChips(theme, callback.ids, card_w - 18, y + 16, index);
        if (attached) {
            const row_y = y + 72;
            const actions = [_]struct { text: []const u8, icon: []const u8, kind: Kind, w: f32 }{
                .{ .text = "Check mirror", .icon = ui.control_icons.check, .kind = .check, .w = 150 },
                .{ .text = "Edit externally", .icon = ui.control_icons.external, .kind = .checkout, .w = 166 },
                .{ .text = "Refresh snapshot", .icon = ui.control_icons.refresh, .kind = .refresh, .w = 178 },
            };
            var x: f32 = 18;
            for (actions) |entry| {
                const tag = try std.fmt.allocPrint(arena, "callback.{s}.{d}", .{ @tagName(entry.kind), index });
                const clicked = ui.iconButtonEnabled(theme, entry.icon, entry.text, tag, .{ .x = x, .y = row_y, .w = entry.w, .h = 36 }, false, !view.busy);
                if (clicked and result.* == null) {
                    view.index = index;
                    result.* = view.action(captured, entry.kind);
                }
                x += entry.w + 10;
            }
            ui.label(muted, "Refreshing can be undone", .{ .x = x + 8, .y = row_y + 9, .w = 220, .h = 18 }, 12);
        }
        y += h + 12;
    }
}

fn cardHeight(attached: bool) f32 {
    return if (attached) 124 else 72;
}

/// The registered IDs as small round chips, right aligned at `right`.
fn idChips(theme: ui.Theme, ids: []const u8, right: f32, y: f32, card: usize) void {
    var x = right;
    const shown = @min(ids.len, 8);
    var index = shown;
    while (index > 0) {
        index -= 1;
        var digits: [4]u8 = undefined;
        const text = std.fmt.bufPrint(&digits, "{d}", .{ids[index]}) catch "?";
        const w: f32 = @max(28, 14 + 9 * @as(f32, @floatFromInt(text.len)));
        x -= w;
        var opts = ui.options(theme, .{ .x = x, .y = y, .w = w, .h = 24 }, 12);
        opts.id_extra = card * 300 + index;
        opts.background = true;
        opts.color_fill = .{ .color = theme.control };
        opts.corners = .all(12);
        opts.padding = .{};
        opts.font = ui.editorFont(text, 12).withWeight(.bold);
        dvui.labelNoFmt(@src(), text, .{ .align_x = 0.5, .align_y = 0.5 }, opts);
        x -= 6;
    }
    var muted = theme;
    muted.text = theme.muted;
    var label_opts = ui.options(muted, .{ .x = x - 90, .y = y + 3, .w = 84, .h = 18 }, 12);
    label_opts.padding = .{};
    label_opts.background = false;
    label_opts.id_extra = card;
    dvui.labelNoFmt(@src(), if (ids.len > shown) "Custom IDs …" else "Custom IDs", .{ .align_x = 1 }, label_opts);
}

/// Validate rendered fields again before capturing a worker-owned request.
pub fn validate(action: Action, view: View, model: *const desktop.model.Model) !void {
    if (!std.meta.eql(action, view.action(try model.id(), action.kind))) return error.StaleCallbackAction;
}

pub fn request(action: Action, view: View, model: *const desktop.model.Model) !desktop.callback_editor.Request {
    try validate(action, view, model);
    const kind: desktop.callback_editor.Kind = switch (action.kind) {
        .attach => .attach,
        .check => .check,
        .refresh => .refresh,
        else => return error.InvalidCallbackIntent,
    };
    var ids: [252]u8 = undefined;
    var count: usize = 0;
    if (kind == .attach) {
        var parts = std.mem.splitScalar(u8, std.mem.sliceTo(&action.ids, 0), ',');
        while (parts.next()) |part| {
            if (count == ids.len) return error.InvalidCallback;
            const id = try std.fmt.parseInt(u8, std.mem.trim(u8, part, " \t"), 10);
            if (id == 0 or id > 252 or std.mem.indexOfScalar(u8, ids[0..count], id) != null) return error.InvalidCallback;
            ids[count] = id;
            count += 1;
        }
    }
    return desktop.callback_editor.Request.capture(model, kind, action.index, std.mem.sliceTo(&action.entry, 0), ids[0..count], &.{});
}
