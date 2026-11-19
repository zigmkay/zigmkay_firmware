//! Import from Git: capture and analyze a keymap, then compare it side by side
//! with the chosen keyboard before anything is created.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const ui = @import("editor-ui");
const preview = @import("keyboard_preview.zig");
const page = @import("keyboards_ui.zig");
const catalog = desktop.library.catalog;
const Comparison = desktop.import_compare.Comparison;

pub const Intent = enum { none, back, toggle_theme, choose_source, inspect, analyze, module, target, create };

pub const Context = struct {
    location: *[4096]u8,
    name: *[129]u8,
    module: *usize,
    selector: *usize,
    source: ?*const desktop.onboarding.importer.Captured,
    /// Whether the captured source still matches the fields.
    inspected: bool,
    analyzed: bool,
    comparison: ?*const Comparison,
    failure: []const u8 = "",
    host_source: []const u8 = "",
    collection: []const u8 = "",
    busy: bool = false,
    light: bool = false,
};

pub fn draw(theme: ui.Theme, context: Context) !Intent {
    var intent: Intent = .none;
    if (page.bar(theme, &.{ "My Keyboards", "Import from Git" }, context.light)) intent = .toggle_theme;
    if (ui.iconButton(theme, ui.control_icons.back, "Back to My Keyboards", "import.back", .{ .x = 1270, .y = 14, .w = 204, .h = 36 }, false)) intent = .back;
    try drawSource(theme, context, &intent);
    if (context.comparison) |comparison| {
        try drawComparison(theme, context, comparison, &intent);
    } else drawSteps(theme, context);
    return intent;
}

fn drawSource(theme: ui.Theme, context: Context, intent: *Intent) !void {
    var field = ui.options(theme, .{ .x = 16, .y = 80, .w = 960, .h = 40 }, 14);
    field.background = true;
    field.border = .all(1);
    field.corners = .all(8);
    field.padding = .{ .x = 40, .y = 10, .w = 12, .h = 10 };
    field.tag = "import.location";
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = context.location }, .placeholder = "https://github.com/owner/repository or a local folder" }, field);
    entry.deinit();
    dvui.icon(@src(), "import.git", ui.control_icons.git, .{}, .{
        .color_text = .{ .color = theme.muted },
        .rect = .{ .x = 28, .y = 91, .w = 18, .h = 18 },
        .padding = .{},
        .margin = .{},
    });
    if (ui.iconButtonEnabled(theme, ui.control_icons.open, "Folder…", "import.folder", .{ .x = 986, .y = 80, .w = 120, .h = 40 }, false, !context.busy)) intent.* = .choose_source;
    if (context.analyzed and context.inspected) {
        var buffer: [96]u8 = undefined;
        const commit = if (context.source) |source| if (source.provenance.commit) |value| value[0..@min(7, value.len)] else "local folder" else "sample";
        const label = std.fmt.bufPrint(&buffer, "Analyzed · {s}", .{commit}) catch "Analyzed";
        page.pill(theme, label, .{ .x = 1116, .y = 80, .w = 236, .h = 40 }, ui.mix(theme.panel, theme.success, 0.16), null, theme.success, 1);
        if (ui.iconButtonEnabled(theme, ui.control_icons.refresh, "Analyze again", "import.analyze", .{ .x = 1362, .y = 80, .w = 158, .h = 40 }, false, !context.busy)) intent.* = .analyze;
    } else if (context.inspected) {
        if (ui.iconButtonEnabled(theme, ui.control_icons.forward, "Analyze keymap", "import.analyze", .{ .x = 1116, .y = 80, .w = 404, .h = 40 }, true, !context.busy)) intent.* = .analyze;
    } else {
        const ready = context.location[0] != 0 and !context.busy;
        if (ui.iconButtonEnabled(theme, ui.control_icons.forward, "Capture source", "import.inspect", .{ .x = 1116, .y = 80, .w = 404, .h = 40 }, true, ready)) intent.* = .inspect;
    }
    const source = context.source orelse return;
    var x: f32 = 16;
    if (source.candidates.len > 1) {
        var opts = ui.options(theme, .{ .x = 16, .y = 130, .w = 280, .h = 32 }, 13);
        opts.background = true;
        opts.border = .all(1);
        opts.tag = "import.module";
        if (dvui.dropdown(@src(), source.candidates, .{ .choice = context.module }, .{}, opts)) intent.* = .module;
        x = 310;
    } else {
        page.text(theme, source.provenance.entry, .{ .x = 16, .y = 136, .w = 280, .h = 20 }, 13, theme.text, true, 2);
        x = 310;
    }
    var buffer: [256]u8 = undefined;
    const note = std.fmt.bufPrint(&buffer, "{d} of {d} keymap {s} · {d} source files captured · build scripts and callbacks are never run", .{
        context.module.* + 1,
        @max(1, source.candidates.len),
        if (source.candidates.len == 1) "module" else "modules",
        source.provenance.sources.len,
    }) catch "";
    page.text(theme, note, .{ .x = x, .y = 136, .w = 1200, .h = 20 }, 12, theme.muted, false, 3);
}

/// Before analysis: what happens, in order.
fn drawSteps(theme: ui.Theme, context: Context) void {
    page.panel(theme, .{ .x = 16, .y = 176, .w = 1504, .h = 400 }, 1);
    page.text(theme, "Bring a Zig keymap over", .{ .x = 48, .y = 210, .w = 900, .h = 30 }, 22, theme.text, true, 10);
    page.text(theme, "Nothing is created until you confirm the comparison.", .{ .x = 48, .y = 240, .w = 900, .h = 20 }, 14, theme.muted, false, 11);
    const Step = struct { title: []const u8, icon: []const u8, text: []const u8 };
    const steps = [_]Step{
        .{ .title = "Capture", .icon = ui.control_icons.git, .text = "Paste a public GitHub URL, optionally ending in /tree/<ref>, or choose a local folder. The ref resolves to an immutable commit." },
        .{ .title = "Analyze", .icon = ui.control_icons.search, .text = "The selected module is evaluated with the pinned firmware and Zig 0.17.0. Repository build scripts and callbacks never run." },
        .{ .title = "Compare", .icon = ui.control_icons.transfer, .text = "The found keymap appears next to your keyboard. Keys without a counterpart are outlined, and differences are listed." },
        .{ .title = "Create", .icon = ui.control_icons.add, .text = "A new layout is added to your collection. The original repository is never changed." },
    };
    const gap: f32 = 16;
    const card_w = (1504 - 64 - gap * 3) / 4;
    for (steps, 0..) |step, index| {
        const x = 48 + @as(f32, @floatFromInt(index)) * (card_w + gap);
        const y: f32 = 284;
        const card = dvui.box(@src(), .{}, .{
            .id_extra = index,
            .rect = .{ .x = x, .y = y, .w = card_w, .h = 236 },
            .background = true,
            .color_fill = .{ .color = theme.bg },
            .color_border = .{ .color = theme.border },
            .border = .all(1),
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        card.deinit();
        const badge = dvui.box(@src(), .{}, .{
            .id_extra = index,
            .rect = .{ .x = x + 20, .y = y + 20, .w = 40, .h = 40 },
            .background = true,
            .color_fill = .{ .color = ui.mix(theme.panel, theme.accent, 0.16) },
            .corners = .all(10),
            .padding = .{},
            .margin = .{},
        });
        badge.deinit();
        dvui.icon(@src(), "import.step", step.icon, .{}, .{
            .id_extra = index,
            .rect = .{ .x = x + 30, .y = y + 30, .w = 20, .h = 20 },
            .color_text = .{ .color = theme.accent },
            .padding = .{},
            .margin = .{},
        });
        var number: [16]u8 = undefined;
        page.text(theme, std.fmt.bufPrint(&number, "Step {d}", .{index + 1}) catch "", .{ .x = x + 20, .y = y + 76, .w = 200, .h = 16 }, 12, theme.muted, false, 20 + index);
        page.text(theme, step.title, .{ .x = x + 20, .y = y + 96, .w = card_w - 40, .h = 24 }, 18, theme.text, true, 30 + index);
        const body = dvui.textLayout(@src(), .{ .break_lines = true }, .{
            .id_extra = index,
            .rect = .{ .x = x + 20, .y = y + 130, .w = card_w - 40, .h = 96 },
            .background = false,
            .font = ui.editorFont(step.text, 14),
            .color_text = .{ .color = theme.muted },
            .padding = .{},
            .margin = .{},
        });
        body.addText(step.text, .{});
        body.deinit();
    }
    if (context.failure.len != 0) page.text(theme, context.failure, .{ .x = 48, .y = 536, .w = 1400, .h = 20 }, 14, theme.danger, false, 40);
}

fn drawComparison(theme: ui.Theme, context: Context, comparison: *const Comparison, intent: *Intent) !void {
    const report = comparison.report;
    const source = comparison.source_entry;
    page.panel(theme, .{ .x = 16, .y = 176, .w = 746, .h = 470 }, 1);
    page.text(theme, "Found in repository", .{ .x = 40, .y = 196, .w = 400, .h = 26 }, 19, theme.text, true, 50);
    var buffer: [192]u8 = undefined;
    const found = std.fmt.bufPrint(&buffer, "{d} keys · {d} layers · {d} combos{s} · drawn on {s} {s}", .{
        report.source_keys,
        report.layers,
        report.combos + report.combos_dropped,
        if (comparison.callbacks) " · callbacks" else "",
        source.display.name,
        source.display.revision,
    }) catch "";
    page.text(theme, found, .{ .x = 40, .y = 224, .w = 700, .h = 18 }, 12, theme.muted, false, 51);
    well(theme, .{ .x = 40, .y = 252, .w = 698, .h = 370 }, 1);
    preview.draw(theme, source.geometry, .{ .x = 70, .y = 290, .w = 638, .h = 300 }, .{
        .captions = comparison.source_captions,
        .missing = report.missing,
        .id = 20,
    });

    page.panel(theme, .{ .x = 774, .y = 176, .w = 746, .h = 470 }, 2);
    page.text(theme, "Your keyboard", .{ .x = 798, .y = 196, .w = 300, .h = 26 }, 19, theme.text, true, 52);
    const arena = dvui.currentWindow().arena();
    const names = try arena.alloc([]const u8, catalog.entries.len);
    for (catalog.entries, names) |entry, *name| name.* = try std.fmt.allocPrint(arena, "{s} · PCB {s} · {s}", .{ entry.display.name, entry.display.revision, entry.display.template });
    var opts = ui.options(theme, .{ .x = 1156, .y = 190, .w = 340, .h = 34 }, 13);
    opts.background = true;
    opts.border = .all(1);
    opts.tag = "import.target";
    if (dvui.dropdown(@src(), names, .{ .choice = context.selector }, .{}, opts)) intent.* = .target;
    const target = comparison.target_entry;
    var line: [160]u8 = undefined;
    const geometry = target.fidelity.note();
    page.text(theme, std.fmt.bufPrint(&line, "{d} keys · {s}", .{ report.target_keys, geometry }) catch "", .{ .x = 798, .y = 224, .w = 340, .h = 18 }, 12, theme.muted, false, 53);
    well(theme, .{ .x = 798, .y = 252, .w = 698, .h = 370 }, 2);
    preview.draw(theme, target.geometry, .{ .x = 828, .y = 290, .w = 638, .h = 300 }, .{ .captions = comparison.target_captions, .id = 21 });

    differences(theme, comparison, context.host_source);

    page.text(theme, "Layout name", .{ .x = 16, .y = 884, .w = 200, .h = 16 }, 12, theme.muted, false, 60);
    var field = ui.options(theme, .{ .x = 16, .y = 904, .w = 520, .h = 40 }, 14);
    field.background = true;
    field.border = .all(1);
    field.corners = .all(8);
    field.padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 };
    field.tag = "import.name";
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = context.name } }, field);
    entry.deinit();
    var saved: [256]u8 = undefined;
    page.text(theme, std.fmt.bufPrint(&saved, "Saved in {s} · keyboards/, with the source kept in .import", .{if (context.collection.len != 0) std.fs.path.basename(context.collection) else "My Keyboards"}) catch "", .{ .x = 556, .y = 914, .w = 900, .h = 20 }, 12, theme.muted, false, 61);
    page.rule(theme, .{ .x = 0, .y = 962, .w = page.canvas_width, .h = 1 }, 62);
    if (ui.iconButton(theme, null, "Back", "import.cancel", .{ .x = 16, .y = 984, .w = 120, .h = 40 }, false)) intent.* = .back;
    var label: [64]u8 = undefined;
    const create = std.fmt.bufPrint(&label, "Create layout with {d} keys", .{report.target_keys}) catch "Create layout";
    const ready = !context.busy and std.mem.trim(u8, std.mem.sliceTo(context.name, 0), " ").len != 0;
    if (ui.iconButtonEnabled(theme, null, create, "import.create", .{ .x = 1280, .y = 984, .w = 240, .h = 40 }, true, ready)) intent.* = .create;
}

fn well(theme: ui.Theme, rect: dvui.Rect, id: usize) void {
    const box = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = rect,
        .background = true,
        .color_fill = .{ .color = theme.bg },
        .corners = .all(10),
        .padding = .{},
        .margin = .{},
    });
    box.deinit();
}

/// Keys, layers, combos, callbacks and encoders before anything is created.
fn differences(theme: ui.Theme, comparison: *const Comparison, host_source: []const u8) void {
    const report = comparison.report;
    const exact = report.exact();
    const amber = theme.warning;
    const green = theme.success;
    const tint = if (exact) green else amber;
    const box = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 16, .y = 660, .w = 1504, .h = 204 },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, tint, 0.1) },
        .color_border = .{ .color = ui.mix(theme.border, tint, 0.5) },
        .border = .all(1),
        .corners = .all(12),
        .padding = .{},
        .margin = .{},
        .tag = "import.differences",
    });
    box.deinit();
    dvui.icon(@src(), "differences", if (exact) ui.control_icons.saved else ui.control_icons.warning, .{}, .{
        .color_text = .{ .color = tint },
        .rect = .{ .x = 40, .y = 682, .w = 20, .h = 20 },
        .padding = .{},
        .margin = .{},
    });
    var buffer: [256]u8 = undefined;
    const target = comparison.target_entry;
    const headline = if (exact)
        std.fmt.bufPrint(&buffer, "Fits {s} PCB {s} exactly", .{ target.display.name, target.display.revision }) catch ""
    else if (report.missingCount() != 0)
        std.fmt.bufPrint(&buffer, "{d} keys have no counterpart on {s} PCB {s}", .{ report.missingCount(), target.display.name, target.display.revision }) catch ""
    else
        std.fmt.bufPrint(&buffer, "{s} PCB {s} differs from the found keymap", .{ target.display.name, target.display.revision }) catch "";
    page.text(theme, headline, .{ .x = 70, .y = 680, .w = 1400, .h = 24 }, 17, tint, true, 70);
    var detail: [256]u8 = undefined;
    const explanation = if (report.missingCount() != 0)
        std.fmt.bufPrint(&detail, "Keys outlined dashed red on the left are left out; their actions stay in the import record. {d} keys of your keyboard start unassigned.", .{report.target_keys - report.matched}) catch ""
    else if (exact)
        "Every key, layer, combo and encoder direction carries over."
    else
        std.fmt.bufPrint(&detail, "{d} keys of your keyboard start unassigned.", .{report.target_keys - report.matched}) catch "";
    page.text(theme, explanation, .{ .x = 70, .y = 710, .w = 1420, .h = 20 }, 14, theme.text, false, 71);
    const method = if (report.match == .key_id) "Keys are matched by key ID." else "Keys are matched by firmware key index, so rows can shift between revisions: check the right side before you create.";
    page.text(theme, method, .{ .x = 70, .y = 734, .w = 1420, .h = 20 }, 14, theme.muted, false, 72);

    var chips: [5][96]u8 = undefined;
    const layer_text = std.fmt.bufPrint(&chips[0], "{d} layers kept", .{report.layers}) catch "";
    const combo_text = if (report.combos_dropped == 0)
        std.fmt.bufPrint(&chips[1], "{d} combos kept", .{report.combos}) catch ""
    else
        std.fmt.bufPrint(&chips[1], "{d} combos → {d} · {d} use a dropped key", .{ report.combos + report.combos_dropped, report.combos, report.combos_dropped }) catch "";
    const callback_text = if (comparison.callbacks) "Callbacks · source kept byte-exact" else "No callbacks";
    const encoder_text = if (report.source_encoders == 0 and report.target_encoders == 0)
        "Encoders: none"
    else
        std.fmt.bufPrint(&chips[3], "Encoder directions {d} → {d}", .{ report.source_encoders, report.target_encoders }) catch "";
    const key_text = std.fmt.bufPrint(&chips[4], "{d} of {d} keys matched", .{ report.matched, report.source_keys }) catch "";
    const items = [_]struct { []const u8, bool }{
        .{ layer_text, true },
        .{ combo_text, report.combos_dropped == 0 },
        .{ callback_text, true },
        .{ encoder_text, report.source_encoders == report.target_encoders },
        .{ key_text, report.missingCount() == 0 },
    };
    var x: f32 = 70;
    for (items, 0..) |item, index| {
        const width = page.textWidth(item[0], 12) + 28;
        page.pill(theme, item[0], .{ .x = x, .y = 768, .w = width, .h = 28 }, if (item[1]) ui.mix(theme.panel, green, 0.14) else ui.mix(theme.panel, amber, 0.16), null, if (item[1]) green else amber, 80 + index);
        x += width + 10;
    }
    var hint: [192]u8 = undefined;
    page.text(theme, std.fmt.bufPrint(&hint, "Host layout hint: {s} · your OS input settings stay unchanged", .{host_source}) catch "", .{ .x = 70, .y = 820, .w = 1400, .h = 18 }, 12, theme.muted, false, 73);
}
