//! Passive flash progress and diagnostics. Only the toolbar Flash action starts a job.
const std = @import("std");
const dvui = @import("dvui");
const ui = @import("editor-ui");
const policy = @import("flash-presenter");
const Controller = policy.controller.Controller;

pub const Input = struct {
    session_token: ?u32 = null,
    diagnostics: ?policy.Diagnostics = null,
    failure: ?anyerror = null,
    // These pointers are optional for older callers; persistent ownership is in the editor.
    close_requested: ?*bool = null,
    details_open: ?*bool = null,
    light: bool = false,
};

/// The non-modal flash panel in the top-right corner, sized to fit the window.
fn panelWindow(src: std.builtin.SourceLocation, theme: ui.Theme, preferred_height: f32) *dvui.FloatingWindowWidget {
    const screen = dvui.windowRect();
    const width = @max(@as(f32, 1), @min(@as(f32, 600), screen.w - 32));
    const height = @max(@as(f32, 1), @min(preferred_height, screen.h - 32));
    return dvui.floatingWindow(src, .{ .modal = false }, .{
        .rect = .{ .x = @max(0, screen.w - width - 24), .y = @max(0, @min(108, screen.h - height)), .w = width, .h = height },
        .padding = .{ .x = 20, .y = 16, .w = 20, .h = 16 },
        .background = true,
        .color_fill = .{ .color = theme.panel },
        .color_text = .{ .color = theme.text },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(12),
        .tag = "flash.panel",
    });
}

/// A line of wrapped text in the editor font.
fn paragraph(value: []const u8, size: f32, tint: dvui.Color, bold: bool, id: usize) void {
    var font = ui.editorFont(value, size);
    if (bold) font = font.withWeight(.bold);
    const layout = dvui.textLayout(@src(), .{ .break_lines = true }, .{
        .id_extra = id,
        .expand = .horizontal,
        .background = false,
        .font = font,
        .color_text = .{ .color = tint },
        .padding = .{},
        .margin = .{ .y = 2, .h = 4 },
    });
    layout.addText(value, .{});
    layout.deinit();
}

fn heading(theme: ui.Theme) void {
    paragraph("Flash", 18, theme.text, true, 1);
}

fn action(theme: ui.Theme, label: []const u8, tag: []const u8, danger: bool) bool {
    return dvui.button(@src(), label, .{}, .{
        .tag = tag,
        .id_extra = std.hash.Wyhash.hash(0, tag),
        .font = ui.editorFont(label, 14),
        .background = true,
        .color_fill = .{ .color = if (danger) ui.mix(theme.panel, theme.danger, 0.08) else theme.control },
        .color_text = .{ .color = if (danger) theme.danger else theme.text },
        .color_border = .{ .color = if (danger) ui.mix(theme.panel, theme.danger, 0.55) else theme.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{ .x = 14, .y = 8, .w = 14, .h = 8 },
        .margin = .{ .w = 8, .y = 6 },
    });
}

/// Shown while the toolbar-triggered build has not yet created a flash session.
/// This panel only reports build progress; it never selects or accesses a device.
pub fn drawPending(failure: ?anyerror, building: bool, close: *bool, light: bool) void {
    const theme = ui.Theme.get(light);
    const window = panelWindow(@src(), theme, 210);
    defer window.deinit();
    heading(theme);
    if (failure) |err| {
        paragraph("Firmware build failed", 15, theme.danger, true, 2);
        var buffer: [128]u8 = undefined;
        paragraph(std.fmt.bufPrint(&buffer, "Error: {s}", .{@errorName(err)}) catch "Error", 13, theme.text, false, 3);
        paragraph("The firmware was not flashed. Check the build output, then press Flash to try again.", 13, theme.muted, false, 4);
    } else if (building) {
        paragraph("Building current firmware", 15, theme.text, true, 2);
        paragraph("Preparing the firmware before flashing. No device has been selected yet.", 13, theme.muted, false, 4);
    } else {
        paragraph("Preparing firmware build", 15, theme.text, true, 2);
        paragraph("Waiting for the current firmware build to start.", 13, theme.muted, false, 4);
    }
    if (action(theme, "Hide", "flash.pending.close", false)) close.* = true;
}

pub fn draw(owner: *const Controller, input: Input) !?policy.controller.Intent {
    const state = policy.view(owner, input.session_token);
    const theme = ui.Theme.get(input.light);
    const window = panelWindow(@src(), theme, 510);
    defer window.deinit();
    const bounds = window.data().rect;
    heading(theme);
    const failed = owner.failure != null or input.failure != null;
    paragraph(state.status, 15, if (failed) theme.danger else theme.text, true, 2);
    paragraph(state.detail, 13, theme.muted, false, 3);
    var buffer: [160]u8 = undefined;
    if (owner.failure) |failure| paragraph(std.fmt.bufPrint(&buffer, "Failed at: {s}", .{@tagName(failure)}) catch "Failed", 13, theme.text, false, 4);
    var error_buffer: [160]u8 = undefined;
    if (input.failure) |failure| paragraph(std.fmt.bufPrint(&error_buffer, "Error: {s}", .{@errorName(failure)}) catch "Error", 13, theme.text, false, 5);
    if (input.diagnostics) |diagnostics| {
        if (diagnostics.timed_out) paragraph("Timed out. Transfer outcome is uncertain.", 13, theme.warning, false, 6);
        if (diagnostics.cancelled) paragraph("Cancelled. Device contents may have changed.", 13, theme.warning, false, 7);
        if (diagnostics.truncated) paragraph("Job output was truncated. Copy diagnostics for what remains.", 13, theme.muted, false, 8);
    }
    const terminal = switch (owner.phase) {
        .ready, .failed, .cancelled, .reconnect_timeout, .stale => true,
        else => false,
    };
    if (terminal) paragraph("Press Flash once to try again.", 13, theme.muted, false, 9);
    const buttons = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4 } });
    // Hiding is only a presentation change; it never cancels an active job.
    if (action(theme, if (terminal) "Hide" else "Hide (keep running)", "flash.panel.close", false)) {
        if (input.close_requested) |close| close.* = true;
    }
    if (!terminal and state.can_cancel and action(theme, "Cancel flash", "flash.cancel", true)) {
        buttons.deinit();
        return try state.intent(.cancel, null);
    }
    const has_details = owner.artifact != null or owner.selected != null or input.failure != null or
        owner.failure != null or input.diagnostics != null;
    if (!has_details) {
        buttons.deinit();
        return null;
    }
    var local_details = false;
    const open = input.details_open orelse &local_details;
    if (action(theme, if (open.*) "Hide details" else "Details and error output", "flash.details", false)) open.* = !open.*;
    buttons.deinit();
    // Errors remain visible even when the optional details toggle is closed.
    if (open.* or input.failure != null or owner.phase == .failed or owner.phase == .reconnect_timeout) {
        try drawDetails(owner, input, bounds);
    }
    return null;
}

fn drawDetails(owner: *const Controller, input: Input, bounds: dvui.Rect) !void {
    const details_y = @max(@as(f32, 0), @min(@as(f32, 174), bounds.h - 17));
    const area = dvui.scrollArea(@src(), .{}, .{
        .rect = .{
            .x = 0,
            .y = details_y,
            .w = @max(@as(f32, 1), bounds.w - 32),
            .h = @max(@as(f32, 1), bounds.h - details_y - 16),
        },
    });
    defer area.deinit();
    if (owner.artifact) |artifact| {
        const identity = artifact.expected_identity;
        dvui.labelNoFmt(@src(), "Frozen artifact", .{}, .{});
        showLines(artifact.path, 0);
        dvui.label(@src(), "SHA-256: {s}", .{std.fmt.bytesToHex(artifact.uf2_hash, .lower)}, .{});
        dvui.label(@src(), "Expected board: {s} / profile: {s}", .{ &identity.board_id, &identity.profile_id }, .{});
        dvui.label(@src(), "Expected identity: {s}", .{std.fmt.bytesToHex(identity.digest, .lower)}, .{});
    }
    if (owner.selected) |selection| showSelection(selection);
    if (input.failure) |failure| dvui.label(@src(), "Error: {s}", .{@errorName(failure)}, .{});
    if (input.diagnostics) |diagnostics| {
        dvui.labelNoFmt(@src(), "Job output", .{}, .{});
        if (diagnostics.cancelled) dvui.labelNoFmt(@src(), "Cancelled; device contents may have changed.", .{}, .{});
        if (diagnostics.timed_out) dvui.labelNoFmt(@src(), "Timed out; transfer outcome is uncertain.", .{}, .{});
        if (diagnostics.truncated) dvui.labelNoFmt(@src(), "Output truncated by job limit; some details are missing.", .{}, .{});
        dvui.labelNoFmt(@src(), "Error output:", .{}, .{});
        showLines(diagnostics.stderr, 1);
        dvui.labelNoFmt(@src(), "Standard output:", .{}, .{});
        showLines(diagnostics.stdout, 2);
    }
    const report = try reportText(dvui.currentWindow().arena(), owner, input);
    if (action(ui.Theme.get(input.light), "Copy full diagnostics", "flash.copy", false)) dvui.clipboardTextSet(report);
}

/// One allocation keeps the whole bounded job output intact for clipboard use;
/// visible output is split into lines only for layout, never truncated here.
fn reportText(allocator: std.mem.Allocator, owner: *const Controller, input: Input) ![]const u8 {
    const state = policy.view(owner, input.session_token);
    const diagnostics: policy.Diagnostics = input.diagnostics orelse .{
        .stdout = "",
        .stderr = "",
        .cancelled = false,
        .timed_out = false,
        .truncated = false,
    };
    const artifact = owner.artifact;
    const hash_bytes = if (artifact) |value| std.fmt.bytesToHex(value.uf2_hash, .lower) else @as([64]u8, @splat(0));
    const hash: []const u8 = if (artifact != null) &hash_bytes else "none";
    return std.fmt.allocPrint(allocator,
        \\Flash: {s}
        \\{s}
        \\Stage: {s}
        \\Error: {s}
        \\Artifact: {s}
        \\SHA-256: {s}
        \\Cancelled: {}  Timed out: {}  Output truncated: {}
        \\
        \\Error output:
        \\{s}
        \\
        \\Standard output:
        \\{s}
        \\
    , .{
        state.status,
        state.detail,
        if (owner.failure) |failure| @tagName(failure) else "none",
        if (input.failure) |failure| @errorName(failure) else "none",
        if (artifact) |value| value.path else "none",
        hash,
        diagnostics.cancelled,
        diagnostics.timed_out,
        diagnostics.truncated,
        diagnostics.stderr,
        diagnostics.stdout,
    });
}

fn showLines(text: []const u8, section: usize) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        dvui.labelNoFmt(@src(), if (line.len == 0) " " else line, .{}, .{ .id_extra = section * 1_000_000 + index });
    }
}

fn showSelection(selection: policy.controller.Selection) void {
    switch (selection) {
        .unique_bootsel => {
            const text = "Target: exactly one RPI-RP2 BOOTSEL device. Multiple devices are rejected; this is not the live HID identity.";
            dvui.labelNoFmt(@src(), text, .{}, .{});
        },
        .serial => |serial| dvui.label(@src(), "BOOTSEL serial: {s} (not live HID identity)", .{serial}, .{}),
        .bus_address => |address| dvui.label(
            @src(),
            "BOOTSEL bus {d}, address {d} (not live HID identity)",
            .{ address.bus, address.address },
            .{},
        ),
    }
}
