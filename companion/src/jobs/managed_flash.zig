//! Managed explicit intent. Build completion cannot construct or start this job.
const std = @import("std");
const inputs = @import("flash_inputs.zig");
const firmware = @import("firmware.zig");
const flash = @import("picotool_job.zig");

/// Keep at a stable address after start, as with the underlying owned Job.
pub const Job = struct {
    frozen: inputs.Frozen,
    process: flash.Job,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        frozen: inputs.Frozen,
        request: inputs.Request,
        selection: flash.Selection,
    ) !Job {
        return initWithDiscovery(gpa, io, frozen, request, selection, 30_000);
    }

    pub fn initWithDiscovery(
        gpa: std.mem.Allocator,
        io: std.Io,
        frozen: inputs.Frozen,
        request: inputs.Request,
        selection: flash.Selection,
        discovery_ms: u32,
    ) !Job {
        try request.validate();
        var tools = try inputs.Tools.clone(gpa, frozen.tools.record);
        errdefer tools.deinit();
        var owned = frozen;
        owned.path = try tools.arena.allocator().dupe(u8, frozen.path);
        owned.tools = tools;
        const process = try flash.Job.init(gpa, io, .{
            .wrapper = tools.record.wrapper_path,
            .picotool = tools.record.picotool_path,
            .firmware = owned.path,
            .expected_sha256 = owned.uf2_hash,
            .snapshot_id = request.captured,
            .selection = selection,
            .discovery_ms = discovery_ms,
            .backend = tools.record.backend,
        });
        return .{ .frozen = owned, .process = process };
    }

    /// The caller supplies the current editor/build state at the moment of intent.
    /// Revalidation happens before process spawn, including executable hashes.
    pub fn start(self: *Job, current: firmware.Inputs, request: inputs.Request) !void {
        if (!std.mem.eql(u8, &self.process.spec.snapshot_id, &request.captured)) return error.StaleFlashRequest;
        try self.frozen.verify(self.process.gpa, self.process.io, current, request);
        try self.process.start();
    }

    pub fn poll(self: *Job) ?anyerror!flash.Result {
        return self.process.poll();
    }

    pub fn requestCancel(self: *Job) void {
        self.process.requestCancel();
    }

    pub fn deinit(self: *Job) void {
        self.process.deinit();
        self.frozen.deinit();
        self.* = undefined;
    }
};
