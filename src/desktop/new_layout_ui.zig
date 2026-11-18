//! New layout: one page that picks a starting point on the left and shows the
//! result on exactly this keyboard on the right, before anything is written.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const preview = @import("keyboard_preview.zig");
const page = @import("keyboards_ui.zig");
const chip = @import("catalog_ui.zig").chip;
const new_layout = desktop.new_layout;
const library = desktop.library;
const catalog = library.catalog;

pub const Start = enum { template, duplicate, blank, git };

pub const View = struct {
    /// The target keyboard, an index into the catalog.
    entry: usize = 0,
    start: Start = .template,
    template: usize = 0,
    /// The layout to duplicate, an index into the library's layouts.
    duplicate: ?usize = null,
    /// The layer shown in the preview.
    layer: usize = 0,
    name: [129]u8 = @splat(0),
    /// Whether the name was typed rather than suggested.
    named: bool = false,
};

pub const Intent = enum { none, back, create, import_git, toggle_theme };

/// The candidate start point, or null when nothing is chosen yet.
pub fn start(view: *const View, owned: ?*const library.Library) ?new_layout.Start {
    var buffer: new_layout.Templates = undefined;
    switch (view.start) {
        .template => {
            const list = new_layout.templates(&catalog.entries[view.entry], &buffer);
            if (list.len == 0) return null;
            return .{ .template = list[@min(view.template, list.len - 1)] };
        },
        .duplicate => {
            const layouts = (owned orelse return null).layouts;
            const index = view.duplicate orelse return null;
            return if (index < layouts.len) .{ .duplicate = layouts[index].path } else null;
        },
        .blank => return .blank,
        .git => return null,
    }
}

/// A key identifying the start point, to notice when the candidate is stale.
pub fn key(view: *const View, owned: ?*const library.Library) u64 {
    var hash: std.hash.Wyhash = .init(0);
    hash.update(std.mem.asBytes(&view.entry));
    const chosen = start(view, owned) orelse return 0;
    switch (chosen) {
        .template => |template| {
            hash.update(template.selector);
            hash.update(template.label);
        },
        .duplicate => |path| hash.update(path),
        .blank => hash.update("blank"),
    }
    return hash.final() | 1;
}

/// The name suggested for a start point.
fn suggestedName(buffer: []u8, chosen: ?new_layout.Start, owned: ?*const library.Library, view: *const View) []const u8 {
    const value = chosen orelse return "";
    return switch (value) {
        .template => |template| blk: {
            const end = std.mem.indexOf(u8, template.label, " · ") orelse template.label.len;
            break :blk template.label[0..end];
        },
        .duplicate => std.fmt.bufPrint(buffer, "{s} copy", .{owned.?.layouts[view.duplicate.?].name}) catch "Copy",
        .blank => "Blank layout",
    };
}

pub const Context = struct {
    library: ?*const library.Library,
    candidate: ?*const new_layout.Candidate,
    failure: []const u8 = "",
    collection: []const u8 = "",
    busy: bool = false,
    light: bool = false,
};

pub fn draw(view: *View, theme: ui.Theme, context: Context) Intent {
    const entry = &catalog.entries[view.entry];
    var intent: Intent = .none;
    if (page.bar(theme, &.{ entry.display.name, "New layout" }, context.light)) intent = .toggle_theme;
    if (ui.iconButton(theme, ui.control_icons.back, "Back to My Keyboards", "new_layout.back", .{ .x = 1270, .y = 14, .w = 204, .h = 36 }, false)) intent = .back;
    const before = key(view, context.library);
    drawStart(view, theme, context, &intent);
    if (key(view, context.library) != before) view.layer = 0;
    if (!view.named) {
        var buffer: [160]u8 = undefined;
        const suggested = suggestedName(&buffer, start(view, context.library), context.library, view);
        view.name = @splat(0);
        @memcpy(view.name[0..@min(suggested.len, 128)], suggested[0..@min(suggested.len, 128)]);
    }
    drawPreview(view, theme, entry, context);
    return intent;
}

const options = [_]struct { Start, []const u8, []const u8, []const u8 }{
    .{ .template, "Template", "Firmware default or a built-in layout for this keyboard", ui.control_icons.template },
    .{ .duplicate, "Duplicate a layout", "From this keyboard or another revision, compared first", ui.control_icons.duplicate },
    .{ .blank, "Blank", "One empty Base layer; assign every key yourself", ui.control_icons.blank },
    .{ .git, "Import from Git", "A Zig keymap from a repository or folder", ui.control_icons.git },
};

fn drawStart(view: *View, theme: ui.Theme, context: Context, intent: *Intent) void {
    page.panel(theme, .{ .x = 16, .y = 80, .w = 520, .h = 960 }, 1);
    page.text(theme, "Start from", .{ .x = 40, .y = 100, .w = 300, .h = 26 }, 19, theme.text, true, 1);
    for (options, 0..) |option, index| {
        const y = 138 + @as(f32, @floatFromInt(index)) * 73;
        const selected = view.start == option[0];
        if (page.surface(theme, .{ .x = 40, .y = y, .w = 472, .h = 63 }, page.indexed("new_layout.start", index), index, selected, false)) {
            view.start = option[0];
            if (option[0] == .duplicate and view.duplicate == null and context.library != null and context.library.?.layouts.len != 0) view.duplicate = 0;
        }
        radio(theme, .{ .x = 58, .y = y + 23, .w = 16, .h = 16 }, selected, index);
        dvui.icon(@src(), "start.icon", option[3], .{}, .{
            .id_extra = index,
            .color_text = .{ .color = theme.text },
            .rect = .{ .x = 86, .y = y + 22, .w = 18, .h = 18 },
            .padding = .{},
            .margin = .{},
        });
        page.text(theme, option[1], .{ .x = 114, .y = y + 12, .w = 380, .h = 20 }, 14, theme.text, true, 10 + index);
        page.text(theme, option[2], .{ .x = 114, .y = y + 33, .w = 390, .h = 18 }, 12, theme.muted, false, 20 + index);
    }
    const section_y: f32 = 440;
    switch (view.start) {
        .template => templateChips(view, theme, section_y),
        .duplicate => duplicateList(view, theme, context.library, section_y),
        .blank => page.text(theme, "Every key starts unassigned. Add layers and keys in the editor.", .{ .x = 40, .y = section_y, .w = 470, .h = 20 }, 13, theme.muted, false, 30),
        .git => {
            page.text(theme, "Capture a repository or folder, then compare its keymap", .{ .x = 40, .y = section_y, .w = 470, .h = 20 }, 13, theme.muted, false, 31);
            page.text(theme, "with this keyboard before anything is created.", .{ .x = 40, .y = section_y + 20, .w = 470, .h = 20 }, 13, theme.muted, false, 32);
            if (ui.iconButton(theme, ui.control_icons.git, "Continue to import", "new_layout.import", .{ .x = 40, .y = section_y + 54, .w = 200, .h = 38 }, true)) intent.* = .import_git;
        },
    }
    if (view.start != .git) drawName(view, theme, context, intent);
}

fn radio(theme: ui.Theme, rect: dvui.Rect, selected: bool, id: usize) void {
    const ring = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .color_border = .{ .color = if (selected) theme.accent else theme.muted },
        .border = .all(1.5),
        .corners = .all(rect.w / 2),
        .padding = .{},
        .margin = .{},
    });
    ring.deinit();
    if (!selected) return;
    const dot = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = .{ .x = rect.x + 4, .y = rect.y + 4, .w = rect.w - 8, .h = rect.h - 8 },
        .background = true,
        .color_fill = .{ .color = theme.accent },
        .corners = .all(rect.w / 2),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();
}

fn templateChips(view: *View, theme: ui.Theme, top: f32) void {
    page.text(theme, "Template", .{ .x = 40, .y = top, .w = 200, .h = 16 }, 12, theme.muted, false, 40);
    var buffer: new_layout.Templates = undefined;
    const list = new_layout.templates(&catalog.entries[view.entry], &buffer);
    var x: f32 = 40;
    var y: f32 = top + 24;
    for (list, 0..) |template, index| {
        const width = page.textWidth(template.label, 13) + 34;
        if (x + width > 512) {
            x = 40;
            y += 40;
        }
        if (chip(theme, template.label, .{ .x = x, .y = y, .w = width, .h = 32 }, index == view.template, 300 + index)) view.template = index;
        x += width + 8;
    }
}

fn duplicateList(view: *View, theme: ui.Theme, owned: ?*const library.Library, top: f32) void {
    page.text(theme, "Layout to copy", .{ .x = 40, .y = top, .w = 200, .h = 16 }, 12, theme.muted, false, 41);
    const layouts = if (owned) |value| value.layouts else &.{};
    if (layouts.len == 0) {
        page.text(theme, "No layouts yet", .{ .x = 40, .y = top + 26, .w = 300, .h = 20 }, 13, theme.muted, false, 42);
        return;
    }
    const area = dvui.scrollArea(@src(), .{}, .{ .rect = .{ .x = 36, .y = top + 22, .w = 480, .h = 230 }, .background = false, .padding = .{}, .margin = .{} });
    defer area.deinit();
    const rows = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = 470, .h = @as(f32, @floatFromInt(layouts.len)) * 50 }, .padding = .{}, .margin = .{} });
    defer rows.deinit();
    const target = &catalog.entries[view.entry];
    for (layouts, 0..) |layout, index| {
        const y = @as(f32, @floatFromInt(index)) * 50;
        if (page.surface(theme, .{ .x = 4, .y = y, .w = 468, .h = 44 }, page.indexed("new_layout.copy", index), 500 + index, view.duplicate == index, false)) view.duplicate = index;
        page.text(theme, layout.name, .{ .x = 18, .y = y + 5, .w = 300, .h = 18 }, 13, theme.text, true, 600 + index);
        var line: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(&line, "{s} · PCB {s}", .{ layout.entry.display.name, layout.entry.display.revision }) catch "";
        page.text(theme, detail, .{ .x = 18, .y = y + 23, .w = 300, .h = 16 }, 11, theme.muted, false, 700 + index);
        if (!library.sameHardware(layout.entry, target))
            page.pill(theme, "other revision", .{ .x = 350, .y = y + 12, .w = 108, .h = 20 }, ui.mix(theme.panel, ui.color(0xF59E0B), 0.15), null, ui.color(0xF59E0B), 800 + index);
    }
}

fn drawName(view: *View, theme: ui.Theme, context: Context, intent: *Intent) void {
    page.text(theme, "Name", .{ .x = 40, .y = 720, .w = 200, .h = 16 }, 12, theme.muted, false, 50);
    var field = ui.options(theme, .{ .x = 40, .y = 740, .w = 472, .h = 40 }, 14);
    field.background = true;
    field.border = .all(1);
    field.corners = .all(8);
    field.padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 };
    field.tag = "new_layout.name";
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.name } }, field);
    if (entry.text_changed) view.named = true;
    entry.deinit();
    var directory: [128]u8 = undefined;
    const Free = struct {
        pub fn contains(_: @This(), _: []const u8) bool {
            return false;
        }
    };
    const slug = new_layout.directoryName(&directory, std.mem.sliceTo(&view.name, 0), Free{});
    var buffer: [256]u8 = undefined;
    const saved = std.fmt.bufPrint(&buffer, "Saved in {s} · keyboards/{s}", .{
        if (context.collection.len != 0) std.fs.path.basename(context.collection) else "My Keyboards",
        slug,
    }) catch "";
    page.text(theme, saved, .{ .x = 40, .y = 788, .w = 472, .h = 18 }, 12, theme.muted, false, 51);
    page.rule(theme, .{ .x = 16, .y = 964, .w = 520, .h = 1 }, 52);
    if (ui.iconButton(theme, null, "Cancel", "new_layout.cancel", .{ .x = 40, .y = 984, .w = 110, .h = 40 }, false)) intent.* = .back;
    const ready = context.candidate != null and context.failure.len == 0 and !context.busy and
        std.mem.trim(u8, std.mem.sliceTo(&view.name, 0), " ").len != 0;
    if (ui.iconButtonEnabled(theme, ui.control_icons.add, "Create layout", "new_layout.create", .{ .x = 342, .y = 984, .w = 170, .h = 40 }, true, ready)) intent.* = .create;
}

fn drawPreview(view: *View, theme: ui.Theme, entry: *const catalog.Entry, context: Context) void {
    page.panel(theme, .{ .x = 548, .y = 80, .w = 972, .h = 960 }, 2);
    page.text(theme, "Preview", .{ .x = 576, .y = 100, .w = 300, .h = 26 }, 19, theme.text, true, 60);
    var title: [192]u8 = undefined;
    const on = std.fmt.bufPrint(&title, "On {s} · PCB {s}", .{ entry.display.name, entry.display.revision }) catch "";
    page.text(theme, on, .{ .x = 900, .y = 104, .w = 592, .h = 18 }, 12, theme.muted, false, 61);
    const well = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 576, .y = 140, .w = 916, .h = 420 },
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
    });
    well.deinit();
    if (view.start == .git) {
        page.text(theme, "The comparison with this keyboard follows the import.", .{ .x = 600, .y = 340, .w = 868, .h = 20 }, 14, theme.muted, false, 62);
        preview.draw(theme, entry.geometry, .{ .x = 640, .y = 180, .w = 788, .h = 140 }, .{ .id = 3 });
        return;
    }
    const candidate = context.candidate orelse {
        const message = if (context.failure.len != 0) context.failure else "Choose a starting point";
        page.text(theme, message, .{ .x = 600, .y = 340, .w = 868, .h = 20 }, 14, if (context.failure.len != 0) ui.color(0xF06B73) else theme.muted, false, 63);
        return;
    };
    const doc = candidate.snapshot.document;
    if (view.layer >= doc.layers.len) view.layer = 0;
    var unmatched: ?[]const bool = null;
    var storage: [256]bool = undefined;
    if (candidate.report) |report| if (report.origin.len <= storage.len) {
        for (report.origin, storage[0..report.origin.len]) |slot, *flag| flag.* = slot == null;
        unmatched = storage[0..report.origin.len];
    };
    preview.draw(theme, candidate.board.entry.geometry, .{ .x = 630, .y = 180, .w = 808, .h = 340 }, .{
        .captions = candidate.captions[view.layer],
        .missing = unmatched,
        .layer = view.layer,
        .id = 4,
    });
    page.text(theme, "Layers", .{ .x = 576, .y = 584, .w = 200, .h = 16 }, 12, theme.muted, false, 64);
    var x: f32 = 576;
    var y: f32 = 606;
    for (doc.layers, 0..) |layer, index| {
        const width = page.textWidth(layer.name, 13) + 40;
        if (x + width > 1492) {
            x = 576;
            y += 38;
        }
        if (layerChip(theme, layer.name, .{ .x = x, .y = y, .w = width, .h = 30 }, index, index == view.layer)) view.layer = index;
        x += width + 8;
    }
    summary(theme, candidate, entry, context.failure, y + 56);
}

fn layerChip(theme: ui.Theme, name: []const u8, rect: dvui.Rect, index: usize, selected: bool) bool {
    const color = ui.layerColor(theme, index);
    const clicked = dvui.button(@src(), "", .{}, .{
        .id_extra = index,
        .tag = page.indexed("new_layout.layer", index),
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = if (selected) ui.mix(theme.panel, color, 0.22) else theme.control },
        .color_border = .{ .color = if (selected) color else theme.border },
        .border = .all(1),
        .corners = .all(rect.h / 2),
        .padding = .{},
        .margin = .{},
    });
    const dot = dvui.box(@src(), .{}, .{
        .id_extra = index,
        .rect = .{ .x = rect.x + 12, .y = rect.y + rect.h / 2 - 4, .w = 8, .h = 8 },
        .background = true,
        .color_fill = .{ .color = color },
        .corners = .all(4),
        .padding = .{},
        .margin = .{},
    });
    dot.deinit();
    page.text(theme, name, .{ .x = rect.x + 26, .y = rect.y, .w = rect.w - 30, .h = rect.h }, 13, theme.text, false, 900 + index);
    return clicked;
}

/// Counts, fit and what a copy from other hardware loses.
fn summary(theme: ui.Theme, candidate: *const new_layout.Candidate, entry: *const catalog.Entry, failure: []const u8, top: f32) void {
    const doc = candidate.snapshot.document;
    const box = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 576, .y = top, .w = 916, .h = 160 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
    var counts: [192]u8 = undefined;
    const line = std.fmt.bufPrint(&counts, "{d} keys · {d} {s} · {d} {s}{s}", .{
        doc.key_ids.len,
        doc.layers.len,
        if (doc.layers.len == 1) "layer" else "layers",
        doc.combos.len,
        if (doc.combos.len == 1) "combo" else "combos",
        if (doc.callbacks.len != 0) " · callbacks" else "",
    }) catch "";
    page.text(theme, line, .{ .x = 600, .y = top + 18, .w = 868, .h = 24 }, 17, theme.text, true, 70);
    var row: usize = 0;
    var buffer: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buffer, "Fits {s} PCB {s} exactly", .{ entry.display.name, entry.display.revision }) catch "";
    if (failure.len != 0) {
        note(theme, row, top, .danger, failure);
        row += 1;
    } else if (candidate.report) |report| {
        if (report.exact()) {
            note(theme, row, top, .ok, name);
            row += 1;
        } else {
            var lost: [192]u8 = undefined;
            if (report.missingCount() != 0) {
                note(theme, row, top, .warning, std.fmt.bufPrint(&lost, "{d} of {d} keys have no counterpart here; their actions are left out", .{ report.missingCount(), report.source_keys }) catch "");
                row += 1;
            }
            const unassigned = report.target_keys - report.matched;
            if (unassigned != 0) {
                note(theme, row, top, .warning, std.fmt.bufPrint(&lost, "{d} keys of this keyboard start unassigned (outlined)", .{unassigned}) catch "");
                row += 1;
            }
            if (report.combos_dropped != 0) {
                note(theme, row, top, .warning, std.fmt.bufPrint(&lost, "{d} combos use a dropped key and are left out", .{report.combos_dropped}) catch "");
                row += 1;
            }
            if (report.source_encoders != report.target_encoders and row < 3) {
                note(theme, row, top, .warning, std.fmt.bufPrint(&lost, "Encoder directions: {d} → {d}", .{ report.source_encoders, report.target_encoders }) catch "");
                row += 1;
            }
        }
        if (row < 4) {
            const method = if (report.match == .key_id) "Keys matched by key ID." else "Keys matched by firmware key index; rows can shift between revisions.";
            note(theme, row, top, .info, method);
            row += 1;
        }
    } else {
        note(theme, row, top, .ok, name);
        row += 1;
    }
    if (doc.callbacks.len != 0 and row < 4) note(theme, row, top, .info, "Callback source is copied byte-for-byte; layers it needs keep their positions.");
}

const Tone = enum { ok, warning, danger, info };

fn note(theme: ui.Theme, row: usize, top: f32, tone: Tone, message: []const u8) void {
    const y = top + 54 + @as(f32, @floatFromInt(row)) * 24;
    const tint = switch (tone) {
        .ok => ui.color(0x6EC59A),
        .warning => ui.color(0xF59E0B),
        .danger => ui.color(0xF06B73),
        .info => theme.muted,
    };
    const icon = switch (tone) {
        .ok => ui.control_icons.saved,
        .warning, .danger => ui.control_icons.warning,
        .info => ui.control_icons.info,
    };
    dvui.icon(@src(), "summary.icon", icon, .{}, .{
        .id_extra = row,
        .color_text = .{ .color = tint },
        .rect = .{ .x = 600, .y = y + 2, .w = 16, .h = 16 },
        .padding = .{},
        .margin = .{},
    });
    page.text(theme, message, .{ .x = 626, .y = y, .w = 850, .h = 20 }, 14, if (tone == .info) theme.muted else tint, false, 80 + row);
}
