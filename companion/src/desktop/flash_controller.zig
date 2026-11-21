//! Pure desktop flash intents. Effects are requests to the accepted managed job
//! adapter; this reducer never builds, discovers devices or executes hardware.
const std = @import("std");
const jobs = @import("companion-jobs");
pub const Digest = jobs.SnapshotId;
pub const Selection = jobs.picotool_job.Selection;
pub const Context = struct { snapshot: Digest, build_key: Digest };
pub const Identity = struct { board_id: [8]u8, profile_id: [8]u8, digest: [16]u8 };

pub const Frozen = struct {
    context: Context,
    path: []const u8,
    uf2_hash: Digest,
    expected_identity: Identity,
};

pub const Phase = enum {
    idle,
    preparing,
    prepared,
    building,
    built,
    freezing,
    frozen,
    awaiting_confirmation,
    verifying,
    rebooting,
    reconnecting,
    ready,
    cancelling,
    cancelled,
    stale,
    failed,
    reconnect_timeout,
};

pub const Failure = enum { preparation, build, freeze, managed_job, timeout, identity };
pub const Operation = struct { id: u64, context: Context };

pub const Effect = union(enum) {
    none,
    prepare_tools: Operation,
    build: Operation,
    freeze: Operation,
    start_managed: struct { operation: Operation, frozen: Frozen, selection: Selection },
    cancel_work: Operation,
    /// Call managed_flash.Job.requestCancel, then keep polling until it exits.
    cancel_managed: Operation,
    watch_reconnect: struct { operation: Operation, expected: Identity, deadline: u64 },
    stop_reconnect: Operation,
};

pub const Intent = union(enum) {
    prepare,
    build,
    freeze,
    select: Selection,
    /// An explicit user action bound to the rendered operation and artifact.
    /// For unique_bootsel the confirmation display must clearly state the
    /// assumption that exactly one RPI-RP2 BOOTSEL keyboard is connected.
    /// It is not a separate permission prompt or background-build completion.
    confirm: struct {
        operation_id: u64,
        uf2_hash: Digest,
        selection_revision: u64,
        previous_session_token: ?u32 = null,
    },
    cancel,
    reset,
};

pub const Event = union(enum) {
    prepared: u64,
    built: struct { operation_id: u64, build_key: Digest },
    frozen: struct { operation_id: u64, artifact: Frozen },
    /// Managed-job failure means start failed or the owned child was reaped;
    /// never emit it merely because cancellation has been requested.
    failed: struct { operation_id: u64, stage: Failure },
    /// Optional trusted adapter progress only. The accepted wrapper currently
    /// reports a combined load/verify/reboot result, so an ordinary bridge does
    /// not emit this event or infer it from diagnostic text.
    verification_finished: u64,
    managed_result: struct { operation_id: u64, result: *const jobs.picotool_job.Result },
    /// Bridge from a newly negotiated, coherent live Session. Identity must be
    /// the complete canonical artifact identity, not just a board or caption.
    reconnected: struct { operation_id: u64, session_token: u32, coherent: bool, identity: Identity },
};

/// Owns selected serial and frozen path. Returned effects borrow these strings
/// until the next mutating call; managed Job.init must clone them immediately.
/// The adapter still owns all tools/provenance/UF2 verification and process I/O.
pub const Controller = struct {
    gpa: std.mem.Allocator,
    current: Context,
    captured: ?Context = null,
    operation_id: u64 = 0,
    phase: Phase = .idle,
    failure: ?Failure = null,
    transfer_backend: jobs.flash_inputs.Backend = .picotool,
    artifact: ?Frozen = null,
    selected: ?Selection = null,
    /// Presenter must capture this alongside the displayed selection and pass it
    /// back with confirm; changing selection invalidates previously rendered intents.
    selection_revision: u64 = 0,
    previous_session_token: ?u32 = null,
    reconnect_deadline: u64 = 0,
    reconnect_timeout_ms: u32 = 10_000,
    reconnect_binding_prepared: bool = false,
    stale_after_cancel: bool = false,

    pub fn init(gpa: std.mem.Allocator, context: Context) Controller {
        return .{ .gpa = gpa, .current = context };
    }

    pub fn deinit(self: *Controller) void {
        self.clearOwned();
        self.* = undefined;
    }

    fn clearSelection(self: *Controller) void {
        if (self.selected) |selected| {
            switch (selected) {
                .serial => |serial| self.gpa.free(serial),
                .bus_address, .unique_bootsel => {},
            }
        }
        self.selected = null;
    }

    fn clearOwned(self: *Controller) void {
        self.clearSelection();
        if (self.artifact) |artifact| self.gpa.free(artifact.path);
        self.artifact = null;
    }

    fn operation(self: *const Controller) Operation {
        return .{ .id = self.operation_id, .context = self.captured.? };
    }

    fn fresh(self: *const Controller) bool {
        return if (self.captured) |captured| std.meta.eql(captured, self.current) else false;
    }

    fn managedActive(self: *const Controller) bool {
        return self.phase == .verifying or self.phase == .rebooting or self.phase == .cancelling;
    }

    fn backgroundActive(self: *const Controller) bool {
        return self.phase == .preparing or self.phase == .building or self.phase == .freezing;
    }

    pub fn observe(self: *Controller, context: Context) Effect {
        if (std.meta.eql(context, self.current)) return .none;
        self.current = context;
        if (self.captured == null or self.phase == .idle) return .none;
        if (self.managedActive()) {
            self.stale_after_cancel = true;
            if (self.phase == .cancelling) return .none;
            self.phase = .cancelling;
            return .{ .cancel_managed = self.operation() };
        }
        const was_background = self.backgroundActive();
        const was_reconnecting = self.phase == .reconnecting;
        self.phase = .stale;
        if (was_background) return .{ .cancel_work = self.operation() };
        if (was_reconnecting) return .{ .stop_reconnect = self.operation() };
        return .none;
    }

    pub fn dispatch(self: *Controller, intent: Intent) !Effect {
        switch (intent) {
            .prepare => {
                if (self.managedActive() or self.backgroundActive() or self.phase == .reconnecting) return error.Busy;
                if (self.operation_id == std.math.maxInt(u64)) return error.OperationExhausted;
                self.clearOwned();
                self.operation_id += 1;
                self.captured = self.current;
                self.failure = null;
                self.stale_after_cancel = false;
                self.previous_session_token = null;
                self.reconnect_binding_prepared = false;
                self.phase = .preparing;
                return .{ .prepare_tools = self.operation() };
            },
            .build => {
                if (self.phase != .prepared or !self.fresh()) return error.InvalidIntent;
                self.phase = .building;
                return .{ .build = self.operation() };
            },
            .freeze => {
                if (self.phase != .built or !self.fresh()) return error.InvalidIntent;
                self.phase = .freezing;
                return .{ .freeze = self.operation() };
            },
            .select => |selection| {
                if ((self.phase != .frozen and self.phase != .awaiting_confirmation) or
                    !self.fresh()) return error.InvalidIntent;
                if (self.selection_revision == std.math.maxInt(u64)) return error.SelectionRevisionExhausted;
                const owned: Selection = switch (selection) {
                    .bus_address => |address| blk: {
                        if (address.address == 0 or address.address > 127) return error.InvalidSelection;
                        break :blk selection;
                    },
                    .serial => |serial| blk: {
                        if (serial.len == 0 or std.mem.indexOfScalar(u8, serial, 0) != null)
                            return error.InvalidSelection;
                        break :blk .{ .serial = try self.gpa.dupe(u8, serial) };
                    },
                    .unique_bootsel => .unique_bootsel,
                };
                self.clearSelection();
                self.selected = owned;
                self.selection_revision += 1;
                self.phase = .awaiting_confirmation;
                return .none;
            },
            .confirm => |confirmation| {
                if (self.phase != .awaiting_confirmation or !self.fresh()) return error.InvalidIntent;
                if (confirmation.operation_id != self.operation_id or
                    confirmation.selection_revision != self.selection_revision or
                    !std.mem.eql(
                        u8,
                        &confirmation.uf2_hash,
                        &self.artifact.?.uf2_hash,
                    )) return error.StaleConfirmation;
                self.previous_session_token = confirmation.previous_session_token;
                self.phase = .verifying;
                return .{ .start_managed = .{
                    .operation = self.operation(),
                    .frozen = self.artifact.?,
                    .selection = self.selected.?,
                } };
            },
            .cancel => {
                if (self.phase == .idle or
                    self.phase == .cancelled or
                    self.phase == .stale or
                    self.phase == .cancelling) return .none;
                if (self.managedActive()) {
                    self.phase = .cancelling;
                    self.stale_after_cancel = false;
                    return .{ .cancel_managed = self.operation() };
                }
                const was_background = self.backgroundActive();
                const was_reconnecting = self.phase == .reconnecting;
                self.phase = .cancelled;
                if (was_background) return .{ .cancel_work = self.operation() };
                if (was_reconnecting) return .{ .stop_reconnect = self.operation() };
                return .none;
            },
            .reset => {
                if (self.managedActive() or self.backgroundActive() or self.phase == .reconnecting) return error.Busy;
                self.clearOwned();
                self.captured = null;
                self.failure = null;
                self.phase = .idle;
                return .none;
            },
        }
    }

    pub fn receive(self: *Controller, event: Event, now: u64) !Effect {
        switch (event) {
            .prepared => |id| {
                if (id != self.operation_id or self.phase != .preparing or !self.fresh()) return .none;
                self.phase = .prepared;
            },
            .built => |built| {
                if (built.operation_id != self.operation_id or self.phase != .building or !self.fresh()) return .none;
                if (!std.mem.eql(u8, &built.build_key, &self.captured.?.build_key)) {
                    self.phase = .stale;
                    return error.StaleBuild;
                }
                self.phase = .built;
            },
            .frozen => |frozen| {
                if (frozen.operation_id != self.operation_id or self.phase != .freezing or !self.fresh()) return .none;
                try self.acceptArtifact(frozen.artifact);
            },
            .failed => |failed| {
                if (failed.operation_id != self.operation_id) return .none;
                self.fail(failed.stage);
            },
            .verification_finished => |id| {
                if (id != self.operation_id or self.phase != .verifying or !self.fresh()) return .none;
                self.phase = .rebooting;
            },
            .managed_result => |completed| {
                if (completed.operation_id != self.operation_id or !self.managedActive()) return .none;
                return self.finishTransfer(completed.result, now);
            },
            .reconnected => |reconnected| {
                if (reconnected.operation_id != self.operation_id or
                    self.phase != .reconnecting or
                    !self.fresh()) return .none;
                if (now >= self.reconnect_deadline) return self.tick(now);
                if (!reconnected.coherent or
                    reconnected.session_token == 0 or
                    reconnected.session_token == self.previous_session_token) return .none;
                if (!std.meta.eql(reconnected.identity, self.artifact.?.expected_identity)) {
                    self.failure = .identity;
                    return .none;
                }
                self.phase = .ready;
                self.failure = null;
                return .{ .stop_reconnect = self.operation() };
            },
        }
        return .none;
    }

    /// Takes an owned copy of the frozen artifact if it matches the captured build.
    fn acceptArtifact(self: *Controller, artifact: Frozen) !void {
        if (!std.meta.eql(artifact.context, self.captured.?)) {
            self.phase = .stale;
            return error.StaleArtifact;
        }
        if (!std.fs.path.isAbsolute(artifact.path) or std.mem.indexOfScalar(u8, artifact.path, 0) != null) {
            self.phase = .failed;
            self.failure = .freeze;
            return error.InvalidArtifactPath;
        }
        var owned = artifact;
        owned.path = try self.gpa.dupe(u8, artifact.path);
        self.artifact = owned;
        self.phase = .frozen;
    }

    /// Records a failure reported for the stage that is currently running.
    fn fail(self: *Controller, stage: Failure) void {
        if (stage == .managed_job and self.phase == .cancelling) {
            self.phase = if (self.stale_after_cancel) .stale else .cancelled;
            return;
        }
        if (!self.fresh()) return;
        const applies = switch (stage) {
            .preparation => self.phase == .preparing,
            .build => self.phase == .building,
            .freeze => self.phase == .freezing,
            .managed_job => self.managedActive(),
            .timeout, .identity => false,
        };
        if (!applies) return;
        self.failure = stage;
        self.phase = if (self.phase == .cancelling) .cancelled else .failed;
    }

    /// Completes the managed transfer and starts waiting for the keyboard.
    fn finishTransfer(self: *Controller, result: *const jobs.picotool_job.Result, now: u64) Effect {
        if (self.phase == .cancelling) {
            self.phase = if (self.stale_after_cancel) .stale else .cancelled;
            return .none;
        }
        if (!self.fresh() or !std.mem.eql(u8, &result.snapshot_id, &self.captured.?.snapshot)) {
            self.phase = .stale;
            return .none;
        }
        if (!result.successful()) {
            self.failure = if (result.timed_out) .timeout else .managed_job;
            self.phase = if (result.cancelled) .cancelled else .failed;
            return .none;
        }
        // Backend completion is transfer evidence, never HID readiness.
        self.transfer_backend = result.backend;
        self.phase = .reconnecting;
        self.reconnect_deadline = now +| self.reconnect_timeout_ms;
        return .{ .watch_reconnect = .{
            .operation = self.operation(),
            .expected = self.artifact.?.expected_identity,
            .deadline = self.reconnect_deadline,
        } };
    }

    pub fn tick(self: *Controller, now: u64) Effect {
        if (self.phase != .reconnecting or now < self.reconnect_deadline) return .none;
        self.phase = .reconnect_timeout;
        self.failure = .timeout;
        return .{ .stop_reconnect = self.operation() };
    }
};

const test_context: Context = .{ .snapshot = @splat(1), .build_key = @splat(2) };

test "reconnect binding is owned by each flash session even when operation IDs repeat" {
    var first = Controller.init(std.testing.allocator, test_context);
    defer first.deinit();
    _ = try first.dispatch(.prepare);
    first.reconnect_binding_prepared = true;
    var second = Controller.init(std.testing.allocator, test_context);
    defer second.deinit();
    _ = try second.dispatch(.prepare);
    try std.testing.expectEqual(first.operation_id, second.operation_id);
    try std.testing.expect(!second.reconnect_binding_prepared);
}

const test_identity: Identity = .{
    .board_id = "board_v1".*,
    .profile_id = "profile1".*,
    .digest = @splat(3),
};

fn reachFrozen(controller: *Controller) !void {
    try std.testing.expectEqual(.prepare_tools, std.meta.activeTag(try controller.dispatch(.prepare)));
    _ = try controller.receive(.{ .prepared = controller.operation_id }, 0);
    try std.testing.expectEqual(Phase.prepared, controller.phase);
    _ = try controller.dispatch(.build);
    _ = try controller.receive(.{ .built = .{
        .operation_id = controller.operation_id,
        .build_key = controller.current.build_key,
    } }, 0);
    try std.testing.expectEqual(Phase.built, controller.phase);
    _ = try controller.dispatch(.freeze);
    _ = try controller.receive(.{ .frozen = .{ .operation_id = controller.operation_id, .artifact = .{
        .context = controller.current,
        .path = "/cache/frozen.uf2",
        .uf2_hash = @splat(4),
        .expected_identity = test_identity,
    } } }, 0);
    try std.testing.expectEqual(Phase.frozen, controller.phase);
}

fn confirm(controller: *Controller) !Effect {
    _ = try controller.dispatch(.{ .select = .{ .bus_address = .{ .bus = 1, .address = 2 } } });
    return controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = controller.artifact.?.uf2_hash,
        .selection_revision = controller.selection_revision,
        .previous_session_token = 10,
    } });
}

fn successfulResult() jobs.picotool_job.Result {
    return .{
        .process = .{ .term = .{ .exited = 0 }, .stdout = &.{}, .stderr = &.{} },
        .snapshot_id = test_context.snapshot,
        .cancelled = false,
        .timed_out = false,
        .diagnostics_truncated = false,
    };
}

test "prepare build freeze and selection never flash without exact explicit confirmation" {
    var controller = Controller.init(std.testing.allocator, test_context);
    defer controller.deinit();
    try std.testing.expectEqual(Phase.idle, controller.phase);
    try std.testing.expectError(error.InvalidIntent, controller.dispatch(.build));
    try reachFrozen(&controller);
    var serial = [_]u8{ 'a', 'b', 'c' };
    _ = try controller.dispatch(.{ .select = .{ .serial = &serial } });
    serial[0] = 'x';
    try std.testing.expectEqualStrings("abc", controller.selected.?.serial);
    try std.testing.expectError(error.StaleConfirmation, controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id + 1,
        .uf2_hash = @splat(4),
        .selection_revision = controller.selection_revision,
    } }));
    try std.testing.expectError(error.StaleConfirmation, controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = @splat(5),
        .selection_revision = controller.selection_revision,
    } }));
    const effect = try controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = @splat(4),
        .selection_revision = controller.selection_revision,
    } });
    try std.testing.expectEqual(.start_managed, std.meta.activeTag(effect));
    try std.testing.expectEqual(Phase.verifying, controller.phase);
    try std.testing.expectError(error.InvalidIntent, controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = @splat(4),
        .selection_revision = controller.selection_revision,
    } }));
}

test "unique BOOTSEL selection requires explicit confirmation and is never automatic" {
    var controller = Controller.init(std.testing.allocator, test_context);
    defer controller.deinit();
    try reachFrozen(&controller);
    try std.testing.expect(controller.selected == null);
    try std.testing.expectError(error.InvalidIntent, controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = @splat(4),
        .selection_revision = controller.selection_revision,
    } }));
    _ = try controller.dispatch(.{ .select = .unique_bootsel });
    try std.testing.expectEqual(Phase.awaiting_confirmation, controller.phase);
    try std.testing.expectError(error.StaleConfirmation, controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id + 1,
        .uf2_hash = @splat(4),
        .selection_revision = controller.selection_revision,
    } }));
    const effect = try controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = @splat(4),
        .selection_revision = controller.selection_revision,
    } });
    try std.testing.expectEqual(.start_managed, std.meta.activeTag(effect));
    try std.testing.expectEqual(Selection.unique_bootsel, effect.start_managed.selection);
}

test "reselection invalidates rendered unique BOOTSEL confirmation" {
    var controller = Controller.init(std.testing.allocator, test_context);
    defer controller.deinit();
    try reachFrozen(&controller);
    _ = try controller.dispatch(.{ .select = .unique_bootsel });
    const rendered_revision = controller.selection_revision;
    _ = try controller.dispatch(.{ .select = .{ .serial = "keyboard-2" } });
    try std.testing.expect(controller.selection_revision != rendered_revision);
    try std.testing.expectError(error.StaleConfirmation, controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = @splat(4),
        .selection_revision = rendered_revision,
    } }));
    try std.testing.expectEqual(Phase.awaiting_confirmation, controller.phase);
    const effect = try controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = @splat(4),
        .selection_revision = controller.selection_revision,
    } });
    try std.testing.expectEqualStrings("keyboard-2", effect.start_managed.selection.serial);
}

test "managed transfer completion requires fresh full-identity live reconnection before ready" {
    var controller = Controller.init(std.testing.allocator, test_context);
    defer controller.deinit();
    try reachFrozen(&controller);
    _ = try confirm(&controller);
    _ = try controller.receive(.{ .verification_finished = controller.operation_id }, 0);
    try std.testing.expectEqual(Phase.rebooting, controller.phase);
    const result = successfulResult();
    const effect = try controller.receive(.{ .managed_result = .{
        .operation_id = controller.operation_id,
        .result = &result,
    } }, 100);
    try std.testing.expectEqual(.watch_reconnect, std.meta.activeTag(effect));
    try std.testing.expectEqual(Phase.reconnecting, controller.phase);
    _ = try controller.receive(.{ .reconnected = .{
        .operation_id = controller.operation_id,
        .session_token = 10,
        .coherent = true,
        .identity = test_identity,
    } }, 101);
    try std.testing.expectEqual(Phase.reconnecting, controller.phase);
    var wrong = test_identity;
    wrong.profile_id = "otherone".*;
    _ = try controller.receive(.{ .reconnected = .{
        .operation_id = controller.operation_id,
        .session_token = 11,
        .coherent = true,
        .identity = wrong,
    } }, 102);
    try std.testing.expectEqual(Phase.reconnecting, controller.phase);
    try std.testing.expectEqual(Failure.identity, controller.failure.?);
    _ = try controller.receive(.{ .reconnected = .{
        .operation_id = controller.operation_id,
        .session_token = 11,
        .coherent = false,
        .identity = test_identity,
    } }, 103);
    try std.testing.expectEqual(Phase.reconnecting, controller.phase);
    _ = try controller.receive(.{ .reconnected = .{
        .operation_id = controller.operation_id,
        .session_token = 11,
        .coherent = true,
        .identity = test_identity,
    } }, 104);
    try std.testing.expectEqual(Phase.ready, controller.phase);
}

test "Windows copy completion rejects incorrect live firmware identity" {
    const t = std.testing;
    var controller = Controller.init(t.allocator, test_context);
    defer controller.deinit();
    try reachFrozen(&controller);
    _ = try controller.dispatch(.{ .select = .unique_bootsel });
    _ = try controller.dispatch(.{ .confirm = .{
        .operation_id = controller.operation_id,
        .uf2_hash = @splat(4),
        .selection_revision = controller.selection_revision,
    } });
    var result = successfulResult();
    result.backend = .windows_bootsel;
    _ = try controller.receive(.{ .managed_result = .{
        .operation_id = controller.operation_id,
        .result = &result,
    } }, 100);
    try t.expectEqual(Phase.reconnecting, controller.phase);
    try t.expectEqual(jobs.flash_inputs.Backend.windows_bootsel, controller.transfer_backend);
    var wrong = test_identity;
    wrong.digest[0] ^= 1;
    _ = try controller.receive(.{ .reconnected = .{
        .operation_id = controller.operation_id,
        .session_token = 11,
        .coherent = true,
        .identity = wrong,
    } }, 101);
    try t.expectEqual(Phase.reconnecting, controller.phase);
    _ = try controller.receive(.{ .reconnected = .{
        .operation_id = controller.operation_id,
        .session_token = 11,
        .coherent = true,
        .identity = test_identity,
    } }, 102);
    try t.expectEqual(Phase.ready, controller.phase);
}

test "edits cancel managed work and successful late results cannot restore authorization" {
    var controller = Controller.init(std.testing.allocator, test_context);
    defer controller.deinit();
    try reachFrozen(&controller);
    _ = try confirm(&controller);
    const effect = controller.observe(.{ .snapshot = @splat(9), .build_key = @splat(8) });
    try std.testing.expectEqual(.cancel_managed, std.meta.activeTag(effect));
    try std.testing.expectEqual(Phase.cancelling, controller.phase);
    try std.testing.expectError(error.Busy, controller.dispatch(.prepare));
    const result = successfulResult();
    _ = try controller.receive(.{ .managed_result = .{
        .operation_id = controller.operation_id,
        .result = &result,
    } }, 0);
    try std.testing.expectEqual(Phase.stale, controller.phase);
    const old_id = controller.operation_id;
    _ = try controller.dispatch(.prepare);
    _ = try controller.receive(.{ .prepared = old_id }, 1);
    try std.testing.expectEqual(Phase.preparing, controller.phase);
    _ = try controller.receive(.{ .managed_result = .{ .operation_id = old_id, .result = &result } }, 2);
    try std.testing.expectEqual(Phase.preparing, controller.phase);
}

test "cancellation reaps before retry and reconnect timeout never flashes again" {
    var controller = Controller.init(std.testing.allocator, test_context);
    defer controller.deinit();
    try reachFrozen(&controller);
    _ = try confirm(&controller);
    _ = try controller.dispatch(.cancel);
    try std.testing.expectEqual(Phase.cancelling, controller.phase);
    try std.testing.expectEqual(.none, std.meta.activeTag(try controller.dispatch(.cancel)));
    const result = successfulResult();
    _ = try controller.receive(.{ .managed_result = .{
        .operation_id = controller.operation_id,
        .result = &result,
    } }, 0);
    try std.testing.expectEqual(Phase.cancelled, controller.phase);
    try reachFrozen(&controller);
    _ = try confirm(&controller);
    _ = try controller.receive(.{ .managed_result = .{
        .operation_id = controller.operation_id,
        .result = &result,
    } }, 100);
    try std.testing.expectEqual(Phase.reconnecting, controller.phase);
    try std.testing.expectEqual(
        .none,
        std.meta.activeTag(controller.tick(100 + controller.reconnect_timeout_ms - 1)),
    );
    try std.testing.expectEqual(
        .stop_reconnect,
        std.meta.activeTag(controller.tick(100 + controller.reconnect_timeout_ms)),
    );
    try std.testing.expectEqual(Phase.reconnect_timeout, controller.phase);
    try std.testing.expectEqual(.none, std.meta.activeTag(controller.tick(1_000_000)));
}
