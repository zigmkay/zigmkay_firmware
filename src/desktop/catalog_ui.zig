//! Add keyboard: the catalog of boards the pinned firmware can build, grouped
//! by hardware, with an explicit PCB revision confirmation.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const preview = @import("keyboard_preview.zig");
const page = @import("keyboards_ui.zig");
const catalog = desktop.library.catalog;

pub const View = struct {
    family: usize = 0,
    revision: usize = 0,
    filter: Filter = .all,
    search: [64]u8 = @splat(0),
    confirmed: bool = false,
};

pub const Filter = enum { all, small, large, encoders };

pub const Intent = union(enum) {
    none,
    back,
    toggle_theme,
    /// Continue with `catalog.entries[index]`.
    choose: usize,
};

const max_families = catalog.entries.len;

/// Hardware families in catalog order: entries that share a display name.
const Families = struct {
    first: [max_families]usize = undefined,
    len: usize = 0,

    fn init() Families {
        var families: Families = .{};
        for (catalog.entries, 0..) |entry, index| {
            const known = for (families.first[0..families.len]) |first| {
                if (std.mem.eql(u8, catalog.entries[first].display.name, entry.display.name)) break true;
            } else false;
            if (!known) {
                families.first[families.len] = index;
                families.len += 1;
            }
        }
        return families;
    }
};

/// The catalog entries of `family`, one per distinct revision.
fn revisions(family: usize, out: *[max_families]usize) []const usize {
    const name = catalog.entries[family].display.name;
    var len: usize = 0;
    for (catalog.entries, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.display.name, name)) continue;
        const known = for (out[0..len]) |seen| {
            if (std.mem.eql(u8, catalog.entries[seen].display.revision, entry.display.revision)) break true;
        } else false;
        if (!known) {
            out[len] = index;
            len += 1;
        }
    }
    return out[0..len];
}

fn keyRange(family: usize, buffer: []u8) []const u8 {
    var lowest: usize = std.math.maxInt(usize);
    var highest: usize = 0;
    var encoders: usize = 0;
    for (catalog.entries) |entry| {
        if (!std.mem.eql(u8, entry.display.name, catalog.entries[family].display.name)) continue;
        lowest = @min(lowest, entry.default_dimensions.key_count);
        highest = @max(highest, entry.default_dimensions.key_count);
        encoders = @max(encoders, entry.encoder_action_slots);
    }
    const keys = if (lowest == highest)
        std.fmt.bufPrint(buffer, "{d} keys", .{lowest}) catch ""
    else
        std.fmt.bufPrint(buffer, "{d}–{d} keys", .{ lowest, highest }) catch "";
    if (encoders == 0) return keys;
    return std.fmt.bufPrint(buffer[keys.len..], "{s} · {d} encoder directions", .{ keys, encoders }) catch keys;
}

fn matches(view: *const View, family: usize) bool {
    const entry = catalog.entries[family];
    const query = std.mem.sliceTo(&view.search, 0);
    if (query.len != 0 and !desktop.labels.containsIgnoreCase(entry.display.name, query)) return false;
    var found = false;
    for (catalog.entries) |candidate| {
        if (!std.mem.eql(u8, candidate.display.name, entry.display.name)) continue;
        const keys = candidate.default_dimensions.key_count;
        found = found or switch (view.filter) {
            .all => true,
            .small => keys >= 30 and keys <= 34,
            .large => keys >= 36,
            .encoders => candidate.encoder_action_slots != 0,
        };
    }
    return found;
}

pub fn draw(view: *View, theme: ui.Theme, light: bool, owned: ?*const desktop.library.Library) Intent {
    var intent: Intent = .none;
    if (page.bar(theme, &.{ "My Keyboards", "Add keyboard" }, light)) intent = .toggle_theme;
    if (ui.iconButton(theme, ui.control_icons.back, "Back to My Keyboards", "catalog.back", .{ .x = 1270, .y = 14, .w = 204, .h = 36 }, false)) intent = .back;
    const families = Families.init();
    if (view.family >= families.len) view.family = 0;
    drawList(view, theme, families);
    const family = families.first[view.family];
    var storage: [max_families]usize = undefined;
    const choices = revisions(family, &storage);
    if (view.revision >= choices.len) view.revision = 0;
    const entry_index = choices[view.revision];
    const entry = &catalog.entries[entry_index];

    page.panel(theme, .{ .x = 548, .y = 80, .w = 972, .h = 960 }, 2);
    page.text(theme, entry.display.name, .{ .x = 576, .y = 100, .w = 800, .h = 40 }, 28, theme.text, true, 1);
    var templates: [256]u8 = undefined;
    page.text(theme, templateLine(&templates, entry), .{ .x = 576, .y = 142, .w = 900, .h = 20 }, 14, theme.muted, false, 2);
    page.text(theme, "PCB revision", .{ .x = 576, .y = 184, .w = 200, .h = 16 }, 12, theme.muted, false, 3);
    var x: f32 = 576;
    for (choices, 0..) |choice, index| {
        const label = catalog.entries[choice].display.revision;
        const width = page.textWidth(label, 13) + 34;
        if (chip(theme, label, .{ .x = x, .y = 206, .w = width, .h = 32 }, index == view.revision, index)) {
            view.revision = index;
            view.confirmed = false;
        }
        x += width + 8;
    }
    var owned_text: [256]u8 = undefined;
    if (ownedLine(&owned_text, owned, entry.display.name)) |line| page.text(theme, line, .{ .x = x + 12, .y = 212, .w = 1490 - x, .h = 20 }, 12, theme.muted, false, 4);
    const well = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 576, .y = 258, .w = 916, .h = 420 },
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
    });
    well.deinit();
    preview.draw(theme, entry.geometry, .{ .x = 640, .y = 300, .w = 788, .h = 320 }, .{ .id = 7 });
    var dimensions: [160]u8 = undefined;
    const geometry_note = entry.fidelity.note();
    const detail = if (entry.encoder_action_slots == 0)
        std.fmt.bufPrint(&dimensions, "{d} keys · no encoders · {s}", .{ entry.default_dimensions.key_count, geometry_note }) catch ""
    else
        std.fmt.bufPrint(&dimensions, "{d} keys · {d} encoder directions · {s}", .{ entry.default_dimensions.key_count, entry.encoder_action_slots, geometry_note }) catch "";
    page.text(theme, detail, .{ .x = 592, .y = 648, .w = 880, .h = 18 }, 12, theme.muted, false, 5);

    const notice = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 576, .y = 700, .w = 916, .h = 140 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
    });
    notice.deinit();
    dvui.icon(@src(), "catalog.info", ui.control_icons.info, .{}, .{
        .color_text = .{ .color = theme.muted },
        .rect = .{ .x = 600, .y = 722, .w = 18, .h = 18 },
        .padding = .{},
        .margin = .{},
    });
    page.text(theme, "Check the revision on the back of your PCB", .{ .x = 628, .y = 720, .w = 840, .h = 22 }, 15, theme.text, true, 6);
    page.text(theme, "The key count alone does not identify a board. Builds use the firmware selector of this revision,", .{ .x = 628, .y = 748, .w = 840, .h = 20 }, 14, theme.muted, false, 7);
    page.text(theme, "so a wrong choice can produce firmware for the wrong wiring.", .{ .x = 628, .y = 768, .w = 840, .h = 20 }, 14, theme.muted, false, 8);
    var confirm: [192]u8 = undefined;
    const confirm_text = std.fmt.bufPrint(&confirm, "I confirm this is a {s}, PCB {s}", .{ entry.display.name, entry.display.revision }) catch "I confirm this hardware and PCB revision";
    var box = ui.options(theme, .{ .x = 628, .y = 800, .w = 820, .h = 24 }, 14);
    box.padding = .{};
    box.tag = "catalog.confirm";
    _ = dvui.checkbox(@src(), &view.confirmed, confirm_text, box);

    page.rule(theme, .{ .x = 548, .y = 964, .w = 972, .h = 1 }, 9);
    if (ui.iconButton(theme, null, "Cancel", "catalog.cancel", .{ .x = 576, .y = 984, .w = 110, .h = 40 }, false)) intent = .back;
    if (ui.iconButtonEnabled(theme, ui.control_icons.forward, "Continue to layout", "catalog.continue", .{ .x = 1284, .y = 984, .w = 208, .h = 40 }, true, view.confirmed)) intent = .{ .choose = entry_index };
    return intent;
}

fn drawList(view: *View, theme: ui.Theme, families: Families) void {
    page.panel(theme, .{ .x = 16, .y = 80, .w = 520, .h = 960 }, 1);
    page.text(theme, "Catalog", .{ .x = 40, .y = 96, .w = 300, .h = 26 }, 19, theme.text, true, 10);
    page.text(theme, "Every keyboard the pinned firmware can build", .{ .x = 40, .y = 122, .w = 460, .h = 18 }, 12, theme.muted, false, 11);
    var search = ui.options(theme, .{ .x = 40, .y = 148, .w = 472, .h = 38 }, 14);
    search.background = true;
    search.border = .all(1);
    search.corners = .all(8);
    search.padding = .{ .x = 12, .y = 9, .w = 12, .h = 9 };
    search.tag = "catalog.search";
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = &view.search }, .placeholder = "Search keyboards…" }, search);
    entry.deinit();
    const filters = [_]struct { Filter, []const u8, f32 }{ .{ .all, "All", 48 }, .{ .small, "30–34 keys", 96 }, .{ .large, "36+", 64 }, .{ .encoders, "Encoders", 86 } };
    var x: f32 = 40;
    for (filters, 0..) |filter, index| {
        if (chip(theme, filter[1], .{ .x = x, .y = 196, .w = filter[2], .h = 28 }, view.filter == filter[0], 100 + index)) view.filter = filter[0];
        x += filter[2] + 8;
    }
    var y: f32 = 240;
    var shown: usize = 0;
    for (families.first[0..families.len], 0..) |first, index| {
        if (!matches(view, first)) continue;
        const rect: dvui.Rect = .{ .x = 40, .y = y, .w = 472, .h = 72 };
        if (page.surface(theme, rect, page.indexed("catalog.family", index), index, index == view.family, false)) {
            if (view.family != index) {
                view.revision = 0;
                view.confirmed = false;
            }
            view.family = index;
        }
        const thumb = dvui.box(@src(), .{}, .{
            .id_extra = index,
            .rect = .{ .x = 52, .y = y + 10, .w = 96, .h = 52 },
            .background = true,
            .color_fill = .{ .color = theme.bg },
            .corners = .all(6),
            .padding = .{},
            .margin = .{},
        });
        thumb.deinit();
        preview.draw(theme, catalog.entries[first].geometry, .{ .x = 58, .y = y + 15, .w = 84, .h = 42 }, .{ .id = 200 + index });
        page.text(theme, catalog.entries[first].display.name, .{ .x = 162, .y = y + 16, .w = 330, .h = 20 }, 14, theme.text, true, 300 + index);
        var line: [128]u8 = undefined;
        page.text(theme, familyLine(&line, first), .{ .x = 162, .y = y + 38, .w = 330, .h = 18 }, 12, theme.muted, false, 400 + index);
        y += 81;
        shown += 1;
    }
    if (shown == 0) page.text(theme, "No keyboard matches", .{ .x = 40, .y = y, .w = 400, .h = 20 }, 14, theme.muted, false, 12);
    page.text(theme, "Missing a keyboard? Boards come from the pinned firmware catalog.", .{ .x = 40, .y = 1004, .w = 472, .h = 18 }, 12, theme.muted, false, 13);
}

/// "LK1 · LK2 · LK6 · LK7 · LK8 · 30–34 keys" for a family.
fn familyLine(buffer: []u8, family: usize) []const u8 {
    var storage: [max_families]usize = undefined;
    var writer: std.Io.Writer = .fixed(buffer);
    for (revisions(family, &storage)) |index| {
        const revision = catalog.entries[index].display.revision;
        // Revisions such as "38-key" only repeat the key count.
        if (std.mem.endsWith(u8, revision, "-key")) continue;
        writer.print("{s} · ", .{revision}) catch break;
    }
    var range: [64]u8 = undefined;
    writer.writeAll(keyRange(family, &range)) catch {};
    return writer.buffered();
}

fn templateLine(buffer: []u8, entry: *const catalog.Entry) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.writeAll("Firmware default: ") catch {};
    var first = true;
    for (catalog.entries) |candidate| {
        if (!std.mem.eql(u8, candidate.display.name, entry.display.name) or
            !std.mem.eql(u8, candidate.display.revision, entry.display.revision)) continue;
        writer.print("{s}{s}", .{ if (first) "" else ", ", candidate.display.template }) catch break;
        first = false;
    }
    if (std.mem.eql(u8, entry.selector, "lk7")) writer.writeAll(" · built-in QWERTY and EurKEY layouts") catch {};
    return writer.buffered();
}

fn ownedLine(buffer: []u8, owned: ?*const desktop.library.Library, name: []const u8) ?[]const u8 {
    const keyboards = owned orelse return null;
    var writer: std.Io.Writer = .fixed(buffer);
    var any = false;
    for (keyboards.keyboards) |keyboard| {
        if (!std.mem.eql(u8, keyboard.entry.display.name, name)) continue;
        writer.print("{s}PCB {s} with {d} {s}", .{
            if (any) ", " else "You have ",
            keyboard.entry.display.revision,
            keyboard.layouts.len,
            if (keyboard.layouts.len == 1) "layout" else "layouts",
        }) catch break;
        any = true;
    }
    return if (any) writer.buffered() else null;
}

/// A pill that toggles a choice.
pub fn chip(theme: ui.Theme, label: []const u8, rect: dvui.Rect, selected: bool, id: usize) bool {
    const clicked = dvui.button(@src(), "", .{}, .{
        .id_extra = id,
        .tag = page.indexed("catalog.chip", id),
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = if (selected) ui.mix(theme.panel, theme.accent, 0.16) else theme.control },
        .color_border = .{ .color = if (selected) theme.accent else theme.border },
        .border = .all(1),
        .corners = .all(rect.h / 2),
        .padding = .{},
        .margin = .{},
    });
    var opts = ui.options(theme, rect, 13);
    opts.padding = .{};
    opts.id_extra = id;
    dvui.labelNoFmt(@src(), label, .{ .align_x = 0.5, .align_y = 0.5 }, opts);
    return clicked;
}
