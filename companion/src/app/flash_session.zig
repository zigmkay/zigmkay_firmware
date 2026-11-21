//! Owned offline flash admission and explicitly confirmed managed transfer.
//! The caller renders the presenter view and supplies a fresh model and
//! generation at every boundary.
const std = @import("std");
const project = @import("project");
const desktop = @import("desktop-core");
const jobs = @import("companion-jobs");

const preparation = desktop.flash_preparation;
const Context = desktop.flash_controller.Context;
const Effect = desktop.flash_controller.Effect;

/// How long the transfer waits for a BOOTSEL drive: first for the HID
/// request, then for the user to enter BOOTSEL manually.
pub const DiscoveryWait = struct {
    pub const hid_ms: u32 = 5000;
    pub const manual_ms: u32 = 30_000;

    pub fn remaining(start: u64, delay: u32, now: u64) u32 {
        return @intCast((@as(u64, delay) + manual_ms) -| (now -| start));
    }

    pub fn needsManual(start: u64, delay: u32, now: u64, discovered: bool) bool {
        return !discovered and now -| start >= delay;
    }
};

fn logElapsed(io: std.Io, comptime format: []const u8, start: std.Io.Timestamp) void {
    std.log.info(format, .{start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds()});
}

pub const Session = struct {
    tools: jobs.flash_inputs.Tools,
    request: desktop.build_worker.Request,
    expected_export_tree: jobs.firmware.Digest,
    admitted: desktop.build_worker.Request.CurrentInputs,
    snapshot: [32]u8,
    generation: u64,
    owner: desktop.flash_controller.Controller,
    runtime: desktop.flash_runtime.Runtime,
    prepared: ?preparation.Prepared = null,
    completion: ?desktop.flash_runtime.PollResult = null,
    reconnect: ?@FieldType(Effect, "watch_reconnect") = null,
    discovery_started: ?u64 = null,
    guidance_delay_ms: u32 = 5000,

    pub fn status(self: *const Session, allocator: std.mem.Allocator, now: u64) ![]const u8 {
        if (self.owner.phase == .verifying) if (self.discovery_started) |start| {
            const discovered = if (self.runtime.job) |job| job.process.discovery_complete.load(.acquire) else false;
            if (DiscoveryWait.needsManual(start, self.guidance_delay_ms, now, discovered)) {
                const remaining = (DiscoveryWait.remaining(start, self.guidance_delay_ms, now) + 999) / 1000;
                return std.fmt.allocPrint(allocator, "Keyboard not in BOOTSEL yet. Hold BOOTSEL while reconnecting USB; " ++
                    "keep only this keyboard connected. Waiting {d}s; flashing continues automatically once detected.", .{remaining});
            }
        };
        return self.view(null).status;
    }

    /// Takes ownership of `tools` and `request` on success only; on error the
    /// caller still owns both and must deinit them. The manifest stays owned
    /// by the caller. Admission recaptures disk provenance with the configured
    /// audit mode, synchronously on the calling thread.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        snapshot: [32]u8,
        generation: u64,
        manifest: jobs.firmware.Manifest,
        request: desktop.build_worker.Request,
        expected_export_tree: jobs.firmware.Digest,
        tools: jobs.flash_inputs.Tools,
    ) !Session {
        if (generation == 0 or generation != request.generation) return error.StaleFlashRequest;
        if (!std.mem.eql(u8, &snapshot, &request.captured) or !std.mem.eql(u8, &request.file.board.id, &request.config.board_id))
            return error.StaleFlashRequest;
        {
            const verify_start = std.Io.Clock.awake.now(io);
            defer logElapsed(io, "flash session init tool_verify_ms={d}", verify_start);
            try tools.verify(gpa, io);
        }
        const capture_start = std.Io.Clock.awake.now(io);
        var inputs = request.captureCurrentInputs(gpa, io, expected_export_tree) catch |err| {
            logElapsed(io, "flash session init capture_ms={d}", capture_start);
            return err;
        };
        logElapsed(io, "flash session init capture_ms={d}", capture_start);
        errdefer inputs.deinit();
        if (!std.mem.eql(u8, &manifest.build_key, &jobs.firmware.key(inputs.captured.inputs))) return error.StaleBuild;
        const context: Context = .{ .snapshot = snapshot, .build_key = manifest.build_key };
        return .{
            .tools = tools,
            .request = request,
            .expected_export_tree = expected_export_tree,
            .admitted = inputs,
            .snapshot = snapshot,
            .generation = generation,
            .owner = desktop.flash_controller.Controller.init(gpa, context),
            .runtime = desktop.flash_runtime.Runtime.init(gpa, io),
        };
    }

    pub fn deinit(self: *Session) void {
        self.runtime.deinit(); // Cancels and joins an active managed job.
        if (self.completion) |*result| result.deinit(self.owner.gpa);
        if (self.prepared) |*value| value.deinit();
        self.owner.deinit();
        self.admitted.deinit();
        self.tools.deinit();
        self.request.deinit();
        self.* = undefined;
    }

    fn current(self: *const Session) !jobs.firmware.Inputs {
        const file = self.request.file;
        if (!std.mem.eql(u8, &self.admitted.board_id, &file.board.id) or
            !std.mem.eql(u8, &self.admitted.profile_id, &file.loaded.snapshot.document.profile_id)) return error.StaleFlashRequest;
        const inputs = self.admitted.captured.inputs;
        const context: Context = .{ .snapshot = self.snapshot, .build_key = jobs.firmware.key(inputs) };
        if (!std.meta.eql(context, self.owner.current)) return error.StaleBuild;
        return inputs;
    }

    pub fn matchesModel(self: *const Session, model: *const desktop.model.Model, generation: u64) !bool {
        const snapshot = try model.id();
        return generation == self.generation and std.mem.eql(u8, &snapshot, &self.snapshot) and
            std.mem.eql(u8, &model.board.id, &self.request.config.board_id);
    }

    /// Cheap frame-thread invalidation. Does not recapture disk inputs; callers
    /// still must run admission before subsequent stages.
    pub fn observe(self: *Session, model: *const desktop.model.Model, generation: u64) !Effect {
        const snapshot = try model.id();
        const changed = generation != self.generation or !std.mem.eql(u8, &snapshot, &self.snapshot) or
            !std.mem.eql(u8, &model.board.id, &self.request.config.board_id);
        var context = self.owner.current;
        if (changed) {
            context.snapshot = snapshot;
            // Generation/board changes can retain the same digest: force a
            // distinct context so the old artifact is never confirmable.
            if (std.mem.eql(u8, &context.snapshot, &self.owner.current.snapshot)) context.build_key[0] ^= 1;
        }
        const effect = self.owner.observe(context);
        if (effect == .cancel_managed) _ = self.runtime.cancel(effect.cancel_managed);
        if (effect == .stop_reconnect) self.reconnect = null;
        return effect;
    }

    pub fn view(self: *const Session, session_token: ?u32) desktop.flash_presenter.View {
        return desktop.flash_presenter.view(&self.owner, session_token);
    }

    pub fn prepare(self: *Session, now: u64) !void {
        _ = try self.current();
        const effect = try self.owner.dispatch(.prepare);
        if (self.prepared) |*old| old.deinit();
        self.prepared = null;
        self.reconnect = null;
        if (self.completion) |*old| old.deinit(self.owner.gpa);
        self.completion = null;
        _ = try self.owner.receive(.{ .prepared = effect.prepare_tools.id }, now);
    }

    /// The accepted build is supplied by the caller; this bridge never starts a
    /// compiler as a side effect of rendering or selecting a target.
    pub fn built(self: *Session, manifest: jobs.firmware.Manifest, now: u64) !void {
        const inputs = try self.current();
        if (!std.mem.eql(u8, &manifest.build_key, &jobs.firmware.key(inputs))) return error.StaleBuild;
        const effect = try self.owner.dispatch(.build);
        _ = try self.owner.receive(.{ .built = .{ .operation_id = effect.build.id, .build_key = manifest.build_key } }, now);
    }

    pub fn freeze(self: *Session, manifest: jobs.firmware.Manifest, cache: std.Io.Dir, cache_path: []const u8, now: u64) !void {
        const phase_start = std.Io.Clock.awake.now(self.runtime.io);
        defer logElapsed(self.runtime.io, "flash session freeze_ms={d}", phase_start);
        const inputs = try self.current();
        const file = self.request.file;
        const canonical = try project.snapshot.identity(self.owner.gpa, file.loaded.snapshot, file.board);
        const identity: desktop.flash_controller.Identity = .{
            .board_id = file.board.id,
            .profile_id = file.loaded.snapshot.document.profile_id,
            .digest = canonical.digest,
        };
        const context: Context = .{ .snapshot = self.snapshot, .build_key = jobs.firmware.key(inputs) };
        const effect = try self.owner.dispatch(.freeze);
        const id = effect.freeze.id;
        var value = preparation.compose(
            self.owner.gpa,
            self.runtime.io,
            cache,
            cache_path,
            manifest,
            inputs,
            effect.freeze.context,
            context,
            file.board.id,
            identity,
            self.tools,
        ) catch |err| {
            _ = try self.owner.receive(.{ .failed = .{ .operation_id = id, .stage = .freeze } }, now);
            return err;
        };
        errdefer value.deinit();
        _ = try self.owner.receive(.{ .frozen = .{ .operation_id = id, .artifact = value.artifact } }, now);
        if (self.prepared) |*old| old.deinit();
        self.prepared = value;
    }

    /// Manual BOOTSEL is deliberately not inferred from a connected HID device.
    pub fn selectUniqueBootsel(self: *Session) !void {
        _ = try self.owner.dispatch(try self.view(null).intent(.select, .unique_bootsel));
    }

    /// `rendered` must be the view actually displayed to the user. This method
    /// is the sole transfer start; no preparation or selection can start it.
    pub fn confirm(
        self: *Session,
        rendered: desktop.flash_presenter.View,
        model: *const desktop.model.Model,
        generation: u64,
        now: u64,
    ) !void {
        if (self.discovery_started == null) self.discovery_started = now;
        self.runtime.discovery_ms = @max(1, DiscoveryWait.remaining(self.discovery_started.?, self.guidance_delay_ms, now));
        const phase_start = std.Io.Clock.awake.now(self.runtime.io);
        const preflight = blk: {
            defer logElapsed(self.runtime.io, "flash session confirm_preflight_ms={d}", phase_start);
            if (!try self.matchesModel(model, generation)) return error.StaleFlashRequest;
            const inputs = try self.current();
            const value = if (self.prepared) |*owned| owned else return error.ArtifactRequired;
            const intent = try rendered.intent(.confirm, null);
            const effect = try self.owner.dispatch(intent);
            break :blk .{ .inputs = inputs, .value = value, .effect = effect };
        };
        const start = preflight.effect.start_managed;
        _ = try self.runtime.start(&self.owner, start, &preflight.value.frozen, preflight.inputs, model.board.id, now);
        if (self.runtime.last_error) |err| return err;
    }

    /// Retain completed diagnostics until a new preparation or session teardown.
    /// Cancellation stays joined: the controller settles only after job exit.
    pub fn poll(self: *Session, now: u64) !Effect {
        if (try self.runtime.poll(&self.owner, now)) |result| {
            if (self.completion) |*old| old.deinit(self.owner.gpa);
            self.completion = result;
            self.applyEffect(result.effect);
            return result.effect;
        }
        const effect = self.owner.tick(now);
        self.applyEffect(effect);
        return effect;
    }

    fn applyEffect(self: *Session, effect: Effect) void {
        switch (effect) {
            .watch_reconnect => |watch| self.reconnect = watch,
            .stop_reconnect => self.reconnect = null,
            else => {},
        }
    }

    /// A coherent newly negotiated live session must be supplied by the caller;
    /// this bridge does not poll or probe HID devices.
    pub fn reconnected(self: *Session, token: u32, coherent: bool, identity: desktop.flash_controller.Identity, now: u64) !Effect {
        const watch = self.reconnect orelse return error.NotWatchingReconnect;
        const effect = try self.owner.receive(.{ .reconnected = .{
            .operation_id = watch.operation.id,
            .session_token = token,
            .coherent = coherent,
            .identity = identity,
        } }, now);
        self.applyEffect(effect);
        return effect;
    }

    pub fn cancel(self: *Session) !Effect {
        const effect = try self.owner.dispatch(.cancel);
        if (effect == .cancel_managed) _ = self.runtime.cancel(effect.cancel_managed);
        self.applyEffect(effect);
        return effect;
    }
};

test "manual BOOTSEL guidance starts at five seconds and expires thirty seconds later" {
    const t = std.testing;
    try t.expect(!DiscoveryWait.needsManual(100, 5000, 5099, false));
    try t.expect(DiscoveryWait.needsManual(100, 5000, 5100, false));
    try t.expect(!DiscoveryWait.needsManual(100, 5000, 5100, true));
    try t.expectEqual(@as(u32, 30_000), DiscoveryWait.remaining(100, 5000, 5100));
    try t.expectEqual(@as(u32, 1), DiscoveryWait.remaining(100, 5000, 35_099));
    try t.expectEqual(@as(u32, 0), DiscoveryWait.remaining(100, 5000, 35_100));
    try t.expect(DiscoveryWait.needsManual(100, 0, 100, false));
    try t.expectEqual(@as(u32, 30_000), DiscoveryWait.remaining(100, 0, 100));
}

test "offline controller state needs selection and rendered confirmation" {
    var owner = desktop.flash_controller.Controller.init(std.testing.allocator, .{ .snapshot = @splat(1), .build_key = @splat(2) });
    defer owner.deinit();
    try std.testing.expectError(error.DisabledAction, desktop.flash_presenter.view(&owner, null).intent(.confirm, null));
    const preparing = try owner.dispatch(.prepare);
    _ = try owner.receive(.{ .prepared = preparing.prepare_tools.id }, 0);
    const building = try owner.dispatch(.build);
    _ = try owner.receive(.{ .built = .{ .operation_id = building.build.id, .build_key = owner.current.build_key } }, 0);
    const freezing = try owner.dispatch(.freeze);
    _ = try owner.receive(.{ .frozen = .{ .operation_id = freezing.freeze.id, .artifact = .{
        .context = owner.current,
        .path = "/cache/offline.uf2",
        .uf2_hash = @splat(3),
        .expected_identity = .{ .board_id = "board_v1".*, .profile_id = "profile1".*, .digest = @splat(4) },
    } } }, 0);
    try std.testing.expect(!desktop.flash_presenter.view(&owner, null).can_confirm);
    _ = try owner.dispatch(try desktop.flash_presenter.view(&owner, null).intent(.select, .unique_bootsel));
    const rendered = desktop.flash_presenter.view(&owner, null);
    try std.testing.expect(rendered.can_confirm);
    const stale = owner.observe(.{ .snapshot = @splat(9), .build_key = @splat(2) });
    try std.testing.expectEqual(.none, std.meta.activeTag(stale));
    try std.testing.expectError(error.DisabledAction, desktop.flash_presenter.view(&owner, null).intent(.confirm, null));
    try std.testing.expectError(error.InvalidIntent, owner.dispatch(try rendered.intent(.confirm, null)));
}

test "failed or pending build cannot confirm and accepted rendered intent starts once" {
    var owner = desktop.flash_controller.Controller.init(std.testing.allocator, .{ .snapshot = @splat(1), .build_key = @splat(2) });
    defer owner.deinit();
    const preparing = try owner.dispatch(.prepare);
    _ = try owner.receive(.{ .prepared = preparing.prepare_tools.id }, 0);
    const building = try owner.dispatch(.build);
    try std.testing.expectError(error.DisabledAction, desktop.flash_presenter.view(&owner, null).intent(.confirm, null));
    _ = try owner.receive(.{ .failed = .{ .operation_id = building.build.id, .stage = .build } }, 1);
    try std.testing.expectError(error.DisabledAction, desktop.flash_presenter.view(&owner, null).intent(.confirm, null));
}

test "empty runtime polling never starts a managed transfer" {
    var runtime = desktop.flash_runtime.Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var owner = desktop.flash_controller.Controller.init(std.testing.allocator, .{ .snapshot = @splat(1), .build_key = @splat(2) });
    defer owner.deinit();
    try std.testing.expect(try runtime.poll(&owner, 0) == null);
    try std.testing.expect(runtime.job == null);
}
