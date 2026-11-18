//! Explicit controller effects to the accepted provenance-verifying job.
const std = @import("std");
const jobs = @import("companion-jobs");
const controller = @import("flash-controller");
pub const Start = @FieldType(controller.Effect, "start_managed");

/// Metadata-only view for preflight. This does not represent accepted provenance.
pub const ArtifactView = struct {
    path: []const u8,
    build_key: controller.Digest,
    uf2_hash: controller.Digest,

    pub fn fromFrozen(frozen: *const jobs.flash_inputs.Frozen) ArtifactView {
        return .{ .path = frozen.path, .build_key = frozen.build_key, .uf2_hash = frozen.uf2_hash };
    }
};

pub fn preflight(
    owner: *const controller.Controller,
    effect: Start,
    actual: ArtifactView,
    current: jobs.firmware.Inputs,
    board_id: [8]u8,
) !void {
    if (owner.phase != .verifying or effect.operation.id != owner.operation_id) return error.StaleOperation;
    if (!std.meta.eql(effect.operation.context, owner.current) or
        owner.captured == null or
        !std.meta.eql(effect.operation.context, owner.captured.?)) return error.StaleOperation;
    if (!std.meta.eql(effect.frozen.context, owner.current)) return error.StaleArtifact;
    const artifact = owner.artifact orelse return error.StaleArtifact;
    if (!std.meta.eql(artifact.context, effect.frozen.context) or
        !std.meta.eql(artifact.expected_identity, effect.frozen.expected_identity) or
        !std.mem.eql(u8, artifact.path, effect.frozen.path) or
        !std.mem.eql(u8, &artifact.uf2_hash, &effect.frozen.uf2_hash)) return error.StaleArtifact;
    const selected = owner.selected orelse return error.InvalidSelection;
    if (std.meta.activeTag(selected) != std.meta.activeTag(effect.selection)) return error.InvalidSelection;
    switch (selected) {
        .unique_bootsel => {},
        .serial => |serial| if (!std.mem.eql(u8, serial, effect.selection.serial)) return error.InvalidSelection,
        .bus_address => |address| if (!std.meta.eql(address, effect.selection.bus_address)) return error.InvalidSelection,
    }
    if (!std.fs.path.isAbsolute(actual.path) or
        std.mem.indexOfScalar(u8, actual.path, 0) != null or
        !std.mem.eql(u8, actual.path, effect.frozen.path)) return error.StaleArtifact;
    if (!std.mem.eql(u8, &actual.uf2_hash, &effect.frozen.uf2_hash)) return error.StaleArtifact;
    if (!std.mem.eql(u8, &actual.build_key, &owner.current.build_key) or
        !std.mem.eql(u8, &actual.build_key, &jobs.firmware.key(current))) return error.StaleBuild;
    const expected = effect.frozen.expected_identity;
    if (!std.mem.eql(u8, &expected.board_id, &board_id) or
        !std.mem.eql(u8, &expected.profile_id, &current.profile_id) or
        !std.mem.eql(u8, &expected.digest, &current.identity_digest)) return error.IdentityMismatch;
}

pub const PollResult = struct {
    effect: controller.Effect,
    completion: ?jobs.picotool_job.Result = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *PollResult, gpa: std.mem.Allocator) void {
        if (self.completion) |*result| result.deinit(gpa);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    job: ?*jobs.managed_flash.Job = null,
    operation: ?controller.Operation = null,
    last_error: ?anyerror = null,
    discovery_ms: u32 = 35_000,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Runtime {
        return .{ .gpa = gpa, .io = io };
    }

    fn release(self: *Runtime) void {
        if (self.job) |job| {
            job.deinit();
            self.gpa.destroy(job);
        }
        self.job = null;
        self.operation = null;
    }

    /// Teardown requests wrapper cancellation and waits through managed Job.deinit.
    pub fn deinit(self: *Runtime) void {
        self.release();
        self.* = undefined;
    }

    fn begin(
        self: *Runtime,
        owner: *controller.Controller,
        effect: Start,
        frozen: *const jobs.flash_inputs.Frozen,
        current: jobs.firmware.Inputs,
        board_id: [8]u8,
    ) !void {
        try preflight(owner, effect, ArtifactView.fromFrozen(frozen), current, board_id);
        // The metadata view is not provenance: bind the actual owned frozen
        // record to the controller artifact before Job.start verifies its bytes.
        if (!std.mem.eql(u8, &frozen.build_key, &effect.frozen.context.build_key) or
            !std.mem.eql(u8, &frozen.uf2_hash, &effect.frozen.uf2_hash) or
            !std.mem.eql(u8, frozen.path, effect.frozen.path)) return error.StaleArtifact;
        const request: jobs.flash_inputs.Request = .{
            .captured = effect.operation.context.snapshot,
            .current = owner.current.snapshot,
        };
        const job = try self.gpa.create(jobs.managed_flash.Job);
        errdefer self.gpa.destroy(job);
        job.* = try jobs.managed_flash.Job.initWithDiscovery(
            self.gpa,
            self.io,
            frozen.*,
            request,
            effect.selection,
            self.discovery_ms,
        );
        errdefer job.deinit();
        try job.start(current, request);
        self.job = job;
        self.operation = effect.operation;
    }

    /// Called only for an explicit start_managed effect. All provenance is
    /// checked again by Job.start before its asynchronous process can spawn.
    pub fn start(
        self: *Runtime,
        owner: *controller.Controller,
        effect: Start,
        frozen: *const jobs.flash_inputs.Frozen,
        current: jobs.firmware.Inputs,
        board_id: [8]u8,
        now: u64,
    ) !controller.Effect {
        if (self.job != null) return error.Busy;
        self.last_error = null;
        self.begin(owner, effect, frozen, current, board_id) catch |err| {
            self.last_error = err;
            return owner.receive(.{ .failed = .{
                .operation_id = effect.operation.id,
                .stage = .managed_job,
            } }, now);
        };
        return .none;
    }

    pub fn cancel(self: *Runtime, operation: controller.Operation) bool {
        const active = self.operation orelse return false;
        if (!std.meta.eql(active, operation)) return false;
        self.job.?.requestCancel();
        return true;
    }

    /// Completion is transferred once. Caller owns diagnostic bytes and must
    /// deinit PollResult using this runtime's allocator, even for stale results.
    pub fn poll(self: *Runtime, owner: *controller.Controller, now: u64) !?PollResult {
        const job = self.job orelse return null;
        const completed = job.poll() orelse return null;
        const id = self.operation.?.id;
        defer self.release();
        var result = completed catch |err| {
            self.last_error = err;
            return .{
                .effect = try owner.receive(.{ .failed = .{
                    .operation_id = id,
                    .stage = .managed_job,
                } }, now),
                .failure = err,
            };
        };
        errdefer result.deinit(self.gpa);
        return .{
            .effect = try owner.receive(.{ .managed_result = .{
                .operation_id = id,
                .result = &result,
            } }, now),
            .completion = result,
        };
    }
};

test "preflight binds current identity artifact operation and owned serial without accepting provenance" {
    const t = std.testing;
    const input: jobs.firmware.Inputs = .{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = "profile1".*,
        .identity_digest = @splat(4),
        .lock = jobs.target_lock.fixture(),
    };
    var owner = controller.Controller.init(t.allocator, .{
        .snapshot = @splat(5),
        .build_key = jobs.firmware.key(input),
    });
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
        .path = "/cache/artifact.uf2",
        .uf2_hash = @splat(6),
        .expected_identity = .{
            .board_id = "board_v1".*,
            .profile_id = input.profile_id,
            .digest = input.identity_digest,
        },
    } } }, 0);
    var serial = "chosen".*;
    _ = try owner.dispatch(.{ .select = .{ .serial = &serial } });
    serial[0] = 'x';
    const effect = (try owner.dispatch(.{ .confirm = .{
        .operation_id = owner.operation_id,
        .uf2_hash = @splat(6),
        .selection_revision = owner.selection_revision,
    } })).start_managed;
    try t.expectEqualStrings("chosen", effect.selection.serial);
    const view: ArtifactView = .{
        .path = effect.frozen.path,
        .build_key = owner.current.build_key,
        .uf2_hash = effect.frozen.uf2_hash,
    };
    try preflight(&owner, effect, view, input, "board_v1".*);
    try t.expectError(error.IdentityMismatch, preflight(&owner, effect, view, input, "board_v2".*));
    var changed = view;
    changed.path = "/cache/other.uf2";
    try t.expectError(error.StaleArtifact, preflight(&owner, effect, changed, input, "board_v1".*));
    changed = view;
    changed.uf2_hash[0] ^= 1;
    try t.expectError(error.StaleArtifact, preflight(&owner, effect, changed, input, "board_v1".*));
    var wrong = effect;
    wrong.operation.id += 1;
    try t.expectError(error.StaleOperation, preflight(&owner, wrong, view, input, "board_v1".*));
    wrong = effect;
    wrong.selection = .{ .serial = "other" };
    try t.expectError(error.InvalidSelection, preflight(&owner, wrong, view, input, "board_v1".*));
    var newer = input;
    newer.source_digest[0] ^= 1;
    try t.expectError(error.StaleBuild, preflight(&owner, effect, view, newer, "board_v1".*));
    var changed_context = effect;
    changed_context.frozen.context.snapshot[0] ^= 1;
    try t.expectError(error.StaleArtifact, preflight(&owner, changed_context, view, input, "board_v1".*));
    changed_context = effect;
    changed_context.frozen.expected_identity.board_id[0] ^= 1;
    try t.expectError(error.StaleArtifact, preflight(&owner, changed_context, view, input, "board_v1".*));
}

test "offline flash preparation composition" {
    _ = @import("flash_preparation.zig");
}

test "runtime declarations compile and empty cancellation polling teardown do not spawn" {
    _ = &Runtime.start;
    var runtime = Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var owner = controller.Controller.init(std.testing.allocator, .{
        .snapshot = @splat(1),
        .build_key = @splat(2),
    });
    defer owner.deinit();
    try std.testing.expect(!runtime.cancel(.{ .id = 1, .context = owner.current }));
    try std.testing.expect(try runtime.poll(&owner, 0) == null);
}
