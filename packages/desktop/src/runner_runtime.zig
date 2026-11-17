//! Explicit draft processor lifetime and correlated tutor output; no hardware.
const std = @import("std");
const p = @import("project");
const jobs = @import("companion-jobs");
const runner = @import("runner-async");
const control = @import("practice_controller.zig");
const draft = @import("draft_input.zig");
const host = @import("host_input.zig");
const output = @import("practice_output.zig");
const Model = @import("model.zig").Model;
pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    owner: ?*runner.Owner = null,
    operation: ?control.Operation = null,
    prepared_snapshot: ?control.Digest = null,
    mapping: ?std.heap.ArenaAllocator = null,
    router: draft.Router,
    text: @import("text.zig").Text,
    active_layers: u16 = 1,
    highest_layer: u4 = 0,
    modifiers: u8 = 0,
    pub fn init(gpa: std.mem.Allocator, io: std.Io, window: u32, fixture: bool) Runtime {
        return .{ .gpa = gpa, .io = io, .router = .{ .window = window }, .text = .init(fixture) };
    }
    fn release(self: *Runtime) void {
        if (self.owner) |owner| owner.destroy();
        self.owner = null;
        self.operation = null;
        self.router.runner_running = false;
        self.router.mapping = null;
        if (self.mapping) |*arena| arena.deinit();
        self.mapping = null;
        self.text.clear();
        self.active_layers = 1;
        self.highest_layer = 0;
        self.modifiers = 0;
    }
    pub fn deinit(self: *Runtime) void {
        self.release();
        self.text.deinit();
        self.* = undefined;
    }
    pub fn fail(self: *Runtime, tutor: *control.Controller, failure: anyerror, now: u64) void {
        self.release();
        _ = tutor.pause(now);
        tutor.runner_state = .failed;
        tutor.failure = failure;
    }
    fn selected(self: *Runtime, artifact: ?jobs.runner_artifact.Manifest, model: *const Model, operation: control.Operation) !jobs.runner_artifact.Manifest {
        const manifest = artifact orelse return error.RunnerArtifactNotPrepared;
        const current = try model.id();
        if (!std.mem.eql(u8, &current, &operation.snapshot) or !std.mem.eql(u8, &manifest.record.inputs.project_digest, &current) or !std.mem.eql(u8, &manifest.record.inputs.profile_id, &model.document().profile_id)) return error.StaleBuild;
        try manifest.verifyFile(self.gpa, self.io, manifest.record.inputs);
        return manifest;
    }
    fn start(self: *Runtime, tutor: *const control.Controller, artifact: ?jobs.runner_artifact.Manifest, model: *const Model, operation: control.Operation) !void {
        if (!std.meta.eql(operation, tutor.operation()) or tutor.runner_state != .running or tutor.session.source != .draft) return error.StaleOperation;
        self.release();
        const manifest = try self.selected(artifact, model, operation);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        var legacy: [34]u32 = undefined;
        const codes: []const u32 = if (host.lk7(model.document())) |value| blk: {
            legacy = value;
            break :blk &legacy;
        } else |err| switch (err) {
            error.HostMappingUnavailable => try @import("keymap-importer").hostScancodes(arena.allocator(), model.document()),
            else => return err,
        };
        const binding = try p.owned_zon.clone(arena.allocator(), host.Binding{ .board_id = model.document().board_id, .key_ids = model.document().key_ids, .scancodes = codes });
        try self.router.installMapping(binding, model.document(), operation.snapshot);
        errdefer self.router.mapping = null;
        const owner = try runner.Owner.createVerified(self.gpa, self.io, manifest, manifest.record.inputs, .{ .generation = operation.generation, .snapshot = operation.snapshot }, model.document().key_ids.len, model.document().encoders.len, 5000);
        self.mapping = arena;
        self.owner = owner;
        self.operation = operation;
        self.prepared_snapshot = operation.snapshot;
    }
    pub fn apply(self: *Runtime, tutor: *control.Controller, effect: control.Effect, artifact: ?jobs.runner_artifact.Manifest, model: *const Model, now: u64) !void {
        _ = now;
        if (effect.reset_text) self.text.clear();
        switch (effect.runner) {
            .none => {},
            .stop => |operation| {
                self.release();
                _ = tutor.stopped(operation, self.prepared_snapshot);
            },
            .stop_then_prepare => |replacement| {
                self.release();
                _ = try self.selected(artifact, model, replacement.operation);
                self.prepared_snapshot = replacement.operation.snapshot;
                if (!tutor.prepared(replacement.operation, true)) return error.StaleOperation;
            },
            .stop_then_start => |replacement| try self.start(tutor, artifact, model, replacement.operation),
            .start => |operation| try self.start(tutor, artifact, model, operation),
        }
    }
    pub fn poll(self: *Runtime, tutor: *control.Controller, model: *const Model, now: u64) !void {
        if (self.text.refresh() and tutor.active and tutor.session.source == .draft) try self.apply(tutor, tutor.pause(now), null, model, now);
        const owner = self.owner orelse return;
        const operation = self.operation orelse return error.StaleOperation;
        const current = try model.id();
        if (!std.meta.eql(operation, tutor.operation()) or !std.mem.eql(u8, &current, &operation.snapshot)) {
            try self.apply(tutor, tutor.observe(current, now), null, model, now);
            self.release();
            return;
        }
        const event = owner.poll(.{ .generation = operation.generation, .snapshot = operation.snapshot }) orelse {
            if (owner.state == .running and owner.future == null and owner.queue.items.len == 0) try owner.input(.advance, now);
            return;
        };
        switch (event) {
            .ready => self.router.runner_running = true,
            .failed => |failure| return failure.failure,
            .reply => |reply| {
                var value = reply.output;
                defer value.deinit();
                if (value.value.state != .processed) return error.RunnerStopped;
                if (value.value.highest_layer >= model.document().layers.len) return error.RunnerLayerMismatch;
                self.active_layers = value.value.active_layers;
                self.highest_layer = value.value.highest_layer;
                self.modifiers = value.value.modifiers;
                const consumed = output.consume(tutor, &self.text, operation, value.value.snapshot_id, value.value.sequence, value.value.commands, now);
                if (consumed.failure) |failure| return failure;
                try self.apply(tutor, consumed.effect, null, model, now);
            },
        }
    }
    pub fn route(self: *Runtime, tutor: *control.Controller, model: *const Model, event: draft.Event, now: u64) !bool {
        if (self.operation) |operation| {
            const current = try model.id();
            if (!std.mem.eql(u8, &current, &operation.snapshot)) {
                try self.apply(tutor, tutor.observe(current, now), null, model, now);
                self.release();
                return false;
            }
        }
        switch (self.router.route(tutor, event)) {
            .pass => return false,
            .consumed => return true,
            .pause, .release_input => {
                try self.apply(tutor, tutor.pause(now), null, model, now);
                return event == .key;
            },
            .key => |key| {
                const owner = self.owner orelse return error.RunnerNotRunning;
                try owner.input(if (key.down) .{ .key_down = key.index } else .{ .key_up = key.index }, now);
                return true;
            },
        }
    }
};
