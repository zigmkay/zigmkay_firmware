//! Passive flash progress and diagnostics. Only the toolbar Flash action starts a job.
const std = @import("std");
const dvui = @import("dvui");
const policy = @import("flash-presenter");
const Controller = policy.controller.Controller;

pub const Input = struct {
    session_token: ?u32 = null,
    diagnostics: ?policy.Diagnostics = null,
    failure: ?anyerror = null,
    // These pointers are optional for older callers; persistent ownership is in the editor.
    close_requested: ?*bool = null,
    details_open: ?*bool = null,
};

/// The non-modal flash panel in the top-right corner, sized to fit the window.
fn panelWindow(src: std.builtin.SourceLocation) *dvui.FloatingWindowWidget {
    const screen = dvui.windowRect();
    const width = @max(@as(f32, 1), @min(@as(f32, 640), screen.w - 32));
    const height = @max(@as(f32, 1), @min(@as(f32, 510), screen.h - 32));
    return dvui.floatingWindow(src, .{ .modal = false }, .{
        .rect = .{ .x = @max(0, screen.w - width - 16), .y = @max(0, @min(80, screen.h - height)), .w = width, .h = height },
        .padding = .all(16),
        .background = true,
    });
}

/// Shown while the toolbar-triggered build has not yet created a flash session.
/// This panel only reports build progress; it never selects or accesses a device.
pub fn drawPending(failure: ?anyerror, building: bool, close: *bool) void {
    const window = panelWindow(@src());
    defer window.deinit();
    dvui.labelNoFmt(@src(), "FLASH", .{}, .{});
    if (failure) |err| {
        dvui.labelNoFmt(@src(), "Firmware build failed", .{}, .{});
        dvui.label(@src(), "Error: {s}", .{@errorName(err)}, .{});
        dvui.labelNoFmt(@src(), "The firmware was not flashed. Check the build output, then press Flash to try again.", .{}, .{});
    } else if (building) {
        dvui.labelNoFmt(@src(), "Building current firmware", .{}, .{});
        dvui.labelNoFmt(@src(), "Preparing the firmware before flashing. No device has been selected yet.", .{}, .{});
    } else {
        dvui.labelNoFmt(@src(), "Preparing firmware build", .{}, .{});
        dvui.labelNoFmt(@src(), "Waiting for the current firmware build to start.", .{}, .{});
    }
    if (dvui.button(@src(), "Hide", .{}, .{ .tag = "flash.pending.close" })) close.* = true;
}

pub fn draw(owner: *const Controller, input: Input) !?policy.controller.Intent {
    const state = policy.view(owner, input.session_token);
    const window = panelWindow(@src());
    defer window.deinit();
    const bounds = window.data().rect;
    dvui.labelNoFmt(@src(), "FLASH", .{}, .{});
    dvui.labelNoFmt(@src(), state.status, .{}, .{});
    dvui.labelNoFmt(@src(), state.detail, .{}, .{});
    if (owner.failure) |failure| dvui.label(@src(), "Failed at: {s}", .{@tagName(failure)}, .{});
    if (input.failure) |failure| dvui.label(@src(), "Error: {s}", .{@errorName(failure)}, .{});
    if (input.diagnostics) |diagnostics| {
        if (diagnostics.timed_out) dvui.labelNoFmt(@src(), "Timed out. Transfer outcome is uncertain.", .{}, .{});
        if (diagnostics.cancelled) dvui.labelNoFmt(@src(), "Cancelled. Device contents may have changed.", .{}, .{});
        if (diagnostics.truncated) dvui.labelNoFmt(@src(), "Job output was truncated. Copy diagnostics for what remains.", .{}, .{});
    }
    const terminal = switch (owner.phase) {
        .ready, .failed, .cancelled, .reconnect_timeout, .stale => true,
        else => false,
    };
    // Hiding is only a presentation change; it never cancels an active job.
    if (dvui.button(@src(), if (terminal) "Hide" else "Hide (keep running)", .{}, .{ .tag = "flash.panel.close" })) {
        if (input.close_requested) |close| close.* = true;
    }
    if (!terminal and state.can_cancel and dvui.button(@src(), "Cancel flash", .{}, .{ .tag = "flash.cancel" })) {
        return try state.intent(.cancel, null);
    }
    if (terminal) dvui.labelNoFmt(@src(), "Press Flash once to try again.", .{}, .{});
    const has_details = owner.artifact != null or owner.selected != null or input.failure != null or
        owner.failure != null or input.diagnostics != null;
    if (!has_details) return null;
    var local_details = false;
    const open = input.details_open orelse &local_details;
    if (dvui.button(@src(), if (open.*) "Hide details" else "Details / error output", .{}, .{ .tag = "flash.details" })) open.* = !open.*;
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
    if (dvui.button(@src(), "Copy full diagnostics", .{}, .{ .tag = "flash.copy" })) dvui.clipboardTextSet(report);
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
