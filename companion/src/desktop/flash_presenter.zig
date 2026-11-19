//! UI policy over the controller. Rendering cannot dispatch a hardware effect.
const std = @import("std");
pub const controller = @import("flash-controller");
pub const Action = enum { prepare, build, freeze, select, confirm, cancel, reset };

pub fn blocksAutoBuild(phase: ?controller.Phase) bool {
    return if (phase) |value| switch (value) {
        .idle, .ready, .failed, .cancelled, .reconnect_timeout, .stale => false,
        else => true,
    } else false;
}

test "completed and invalidated Flash sessions allow the next automatic build" {
    const t = std.testing;
    for ([_]controller.Phase{
        .ready,
        .failed,
        .cancelled,
        .reconnect_timeout,
        .stale,
    }) |phase| try t.expect(!blocksAutoBuild(phase));
    for ([_]controller.Phase{
        .preparing,
        .building,
        .frozen,
        .awaiting_confirmation,
        .verifying,
        .rebooting,
        .reconnecting,
        .cancelling,
    }) |phase| try t.expect(blocksAutoBuild(phase));
}

pub fn showErrorWindow(phase: ?controller.Phase, failure: ?anyerror) bool {
    return failure != null or phase == .failed or phase == .reconnect_timeout;
}

test "normal flash progress and success never open a window" {
    const t = std.testing;
    for (std.enums.values(controller.Phase)) |phase| {
        try t.expectEqual(phase == .failed or phase == .reconnect_timeout, showErrorWindow(phase, null));
    }
    try t.expect(!showErrorWindow(null, null));
    try t.expect(showErrorWindow(null, error.BuildFailed));
}

/// Borrowed from an owned runtime completion; keep that completion alive while
/// drawing. No parsing of diagnostic text is used to change transfer phases.
pub const Diagnostics = struct {
    stdout: []const u8,
    stderr: []const u8,
    cancelled: bool,
    timed_out: bool,
    truncated: bool,

    pub fn fromResult(result: anytype) Diagnostics {
        return .{
            .stdout = result.process.stdout,
            .stderr = result.process.stderr,
            .cancelled = result.cancelled,
            .timed_out = result.timed_out,
            .truncated = result.diagnostics_truncated,
        };
    }
};

pub const View = struct {
    phase: controller.Phase,
    operation_id: u64,
    selection_revision: u64,
    uf2_hash: ?controller.Digest,
    previous_session_token: ?u32,
    can_prepare: bool,
    can_build: bool,
    can_freeze: bool,
    can_select: bool,
    can_confirm: bool,
    can_cancel: bool,
    can_reset: bool,
    status: []const u8,
    detail: []const u8,

    pub fn enabled(self: View, action: Action) bool {
        return switch (action) {
            .prepare => self.can_prepare,
            .build => self.can_build,
            .freeze => self.can_freeze,
            .select => self.can_select,
            .confirm => self.can_confirm,
            .cancel => self.can_cancel,
            .reset => self.can_reset,
        };
    }

    /// Confirm binds the exact rendered artifact and operation. The controller
    /// independently rejects stale views after edits or a new operation.
    pub fn intent(self: View, action: Action, selection: ?controller.Selection) !controller.Intent {
        if (!self.enabled(action)) return error.DisabledAction;
        return switch (action) {
            .prepare => .prepare,
            .build => .build,
            .freeze => .freeze,
            .select => .{ .select = selection orelse return error.SelectionRequired },
            .confirm => .{ .confirm = .{
                .operation_id = self.operation_id,
                .uf2_hash = self.uf2_hash orelse return error.ArtifactRequired,
                .selection_revision = self.selection_revision,
                .previous_session_token = self.previous_session_token,
            } },
            .cancel => .cancel,
            .reset => .reset,
        };
    }
};

pub fn view(owner: *const controller.Controller, session_token: ?u32) View {
    const phase = owner.phase;
    const busy = switch (phase) {
        .preparing, .building, .freezing, .verifying, .rebooting, .reconnecting, .cancelling => true,
        else => false,
    };
    const fresh = if (owner.captured) |captured| std.meta.eql(captured, owner.current) else false;
    return .{
        .phase = phase,
        .operation_id = owner.operation_id,
        .selection_revision = owner.selection_revision,
        .uf2_hash = if (owner.artifact) |artifact| artifact.uf2_hash else null,
        .previous_session_token = session_token,
        .can_prepare = !busy,
        .can_build = phase == .prepared and fresh,
        .can_freeze = phase == .built and fresh,
        .can_select = (phase == .frozen or phase == .awaiting_confirmation) and fresh,
        .can_confirm = phase == .awaiting_confirmation and fresh and owner.artifact != null and owner.selected != null,
        .can_cancel = switch (phase) {
            .idle, .cancelled, .stale, .cancelling => false,
            else => true,
        },
        .can_reset = !busy and phase != .idle,
        .status = switch (phase) {
            .idle => "Ready to flash",
            .preparing => "Preparing flash tools",
            .prepared => "Tools ready · building next",
            .building => "Building firmware",
            .built => "Build complete · checking firmware",
            .freezing => "Freezing the verified artifact",
            .frozen => "Firmware checked · selecting BOOTSEL target",
            .awaiting_confirmation => "Target selected · starting transfer",
            .verifying => "Transferring checked firmware; result pending",
            .rebooting => "Reboot requested; waiting for the flash job to finish",
            .reconnecting => "Flash job finished; waiting for a matching live device",
            .ready => "Matching firmware reconnected",
            .cancelling => "Cancelling; waiting for the flash job to exit",
            .cancelled => "Operation cancelled; check device state before retrying",
            .stale => "Project changed; this artifact cannot be flashed",
            .failed => "Operation failed; see details below",
            .reconnect_timeout => "Flash job finished, but matching firmware did not reconnect in time",
        },
        .detail = switch (phase) {
            .idle => "Press Flash once in the toolbar to start. The transfer uses exactly one BOOTSEL device; multiple devices are rejected.",
            .preparing, .prepared, .building, .built, .freezing => "Preparing the current project. No device has been changed yet.",
            .frozen => "The artifact is frozen. The next step is handled automatically for this Flash request.",
            .awaiting_confirmation => if (owner.selected != null and std.meta.activeTag(owner.selected.?) == .unique_bootsel)
                "Using exactly one RPI-RP2 BOOTSEL device. Multiple devices are rejected. BOOTSEL is not the live keyboard identity."
            else
                "Using the selected BOOTSEL target. Waiting for the managed transfer to start.",
            .verifying => "Verification has not been confirmed yet. Do not disconnect the device.",
            .rebooting => "The transfer is still in progress; reboot is not live reconnection.",
            .reconnecting => if (owner.transfer_backend == .windows_bootsel) "Copy completed without flash read-back. Live identity is still unconfirmed." else "The flash tool completed. Live identity is still unconfirmed.",
            .ready => "A new coherent live session matches the expected firmware identity.",
            .cancelling => "Cancellation is pending until the managed job exits. Device contents may already have changed.",
            .cancelled => "Cancellation does not restore the previous firmware.",
            .stale => "Prepare and build again to use the changed project.",
            .failed => "Do not assume the previous firmware is intact; inspect the error and device state.",
            .reconnect_timeout => "The device may have flashed successfully. Check its connection and identity before retrying.",
        },
    };
}

test "flash progress keeps job verification distinct from live identity" {
    const t = std.testing;
    var owner = controller.Controller.init(t.allocator, .{ .snapshot = @splat(1), .build_key = @splat(2) });
    defer owner.deinit();
    owner.phase = .verifying;
    try t.expect(std.mem.indexOf(u8, view(&owner, null).detail, "not been confirmed") != null);
    owner.phase = .rebooting;
    try t.expect(std.mem.indexOf(u8, view(&owner, null).detail, "not live reconnection") != null);
    owner.phase = .reconnecting;
    try t.expect(std.mem.indexOf(u8, view(&owner, null).detail, "unconfirmed") != null);
    owner.phase = .reconnect_timeout;
    try t.expect(std.mem.indexOf(u8, view(&owner, null).detail, "may have flashed successfully") != null);
    owner.phase = .cancelling;
    try t.expect(!view(&owner, null).can_confirm);
    try t.expect(std.mem.indexOf(u8, view(&owner, null).detail, "already have changed") != null);
}

test "one-device BOOTSEL selection requires a separate confirmation and states its uncertainty" {
    const t = std.testing;
    var owner = controller.Controller.init(t.allocator, .{ .snapshot = @splat(1), .build_key = @splat(2) });
    defer owner.deinit();
    _ = try owner.dispatch(.prepare);
    _ = try owner.receive(.{ .prepared = owner.operation_id }, 0);
    _ = try owner.dispatch(.build);
    _ = try owner.receive(.{ .built = .{
        .operation_id = owner.operation_id,
        .build_key = owner.current.build_key,
    } }, 0);
    _ = try owner.dispatch(.freeze);
    _ = try owner.receive(.{ .frozen = .{ .operation_id = owner.operation_id, .artifact = .{
        .context = owner.current,
        .path = "/cache/frozen.uf2",
        .uf2_hash = @splat(3),
        .expected_identity = .{ .board_id = "board_v1".*, .profile_id = "profile1".*, .digest = @splat(4) },
    } } }, 0);
    const before = view(&owner, null);
    try t.expect(before.can_select);
    try t.expect(!before.can_confirm);
    _ = try owner.dispatch(try before.intent(.select, .unique_bootsel));
    const after = view(&owner, null);
    try t.expect(after.can_confirm);
    try t.expect(std.mem.indexOf(u8, after.detail, "exactly one RPI-RP2 BOOTSEL") != null);
    try t.expect(std.mem.indexOf(u8, after.detail, "not the live keyboard identity") != null);
    try t.expectEqual(controller.Selection.unique_bootsel, owner.selected.?);
    try t.expectEqual(controller.Phase.awaiting_confirmation, owner.phase);
}

test "rendered flash confirmation is stale after a new operation and never inferred from a build" {
    const t = std.testing;
    var owner = controller.Controller.init(t.allocator, .{ .snapshot = @splat(1), .build_key = @splat(2) });
    defer owner.deinit();
    try t.expectError(error.DisabledAction, view(&owner, null).intent(.confirm, null));
    _ = try owner.dispatch(.prepare);
    try t.expect(!view(&owner, null).can_prepare);
    _ = try owner.receive(.{ .prepared = owner.operation_id }, 0);
    _ = try owner.dispatch(try view(&owner, null).intent(.build, null));
    _ = try owner.receive(.{ .built = .{
        .operation_id = owner.operation_id,
        .build_key = owner.current.build_key,
    } }, 0);
    try t.expect(!view(&owner, null).can_confirm);
    _ = try owner.dispatch(try view(&owner, null).intent(.freeze, null));
    _ = try owner.receive(.{ .frozen = .{ .operation_id = owner.operation_id, .artifact = .{
        .context = owner.current,
        .path = "/cache/fixture.uf2",
        .uf2_hash = @splat(3),
        .expected_identity = .{ .board_id = "board_v1".*, .profile_id = "profile1".*, .digest = @splat(4) },
    } } }, 0);
    try t.expectError(error.SelectionRequired, view(&owner, null).intent(.select, null));
    _ = try owner.dispatch(try view(&owner, null).intent(.select, .{ .serial = "chosen" }));
    const rendered = view(&owner, 10);
    const confirm = try rendered.intent(.confirm, null);
    try t.expectEqual(@as(?u32, 10), confirm.confirm.previous_session_token);
    _ = try owner.dispatch(.prepare);
    _ = try owner.receive(.{ .prepared = owner.operation_id }, 0);
    _ = try owner.dispatch(.build);
    _ = try owner.receive(.{ .built = .{
        .operation_id = owner.operation_id,
        .build_key = owner.current.build_key,
    } }, 0);
    _ = try owner.dispatch(.freeze);
    _ = try owner.receive(.{ .frozen = .{ .operation_id = owner.operation_id, .artifact = .{
        .context = owner.current,
        .path = "/cache/new.uf2",
        .uf2_hash = @splat(3),
        .expected_identity = .{ .board_id = "board_v1".*, .profile_id = "profile1".*, .digest = @splat(4) },
    } } }, 0);
    _ = try owner.dispatch(.{ .select = .{ .serial = "chosen" } });
    try t.expectError(error.StaleConfirmation, owner.dispatch(confirm));
}
