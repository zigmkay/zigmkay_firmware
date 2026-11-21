//! Owned, correlated offline runner sessions. Output commands are data only.
const std = @import("std");
const jobs = @import("companion-jobs");
const wire = @import("runner-protocol");
const zon = @import("owned-zon");

pub const Reply = struct {
    allocator: std.mem.Allocator,
    value: wire.Output,

    /// UI consumers must compare their current draft before promoting a reply.
    pub fn fresh(self: Reply, current: [32]u8) bool {
        return std.mem.eql(u8, &self.value.snapshot_id, &current);
    }

    pub fn deinit(self: *Reply) void {
        zon.free(self.allocator, self.value);
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: jobs.Session = .{},
    snapshot_id: [32]u8,
    sequence: u64 = 0,
    time_us: u64 = 0,

    /// Heap allocation keeps the pipe reader's address stable throughout its
    /// lifetime. Starting this explicitly selected executable is code execution.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        expected: [32]u8,
        timeout_ms: u32,
    ) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .allocator = gpa, .io = io, .snapshot_id = expected };
        errdefer self.destroy();
        try self.session.start(io, argv);
        var greeting = try self.receive(null, timeout_ms);
        defer greeting.deinit();
        if (greeting.value.sequence != 0 or greeting.value.state != .ready) return error.InvalidRunnerGreeting;
        return self;
    }

    fn receive(self: *Client, frame: ?[]const u8, timeout_ms: u32) !Reply {
        errdefer self.session.stop(self.io);
        const bytes = try self.session.request(self.allocator, self.io, frame, timeout_ms);
        defer self.allocator.free(bytes);
        if (bytes.len > wire.max_response_bytes) return error.RunnerResponseTooLarge;
        const text = try self.allocator.dupeSentinel(u8, bytes, 0);
        defer self.allocator.free(text);
        const output = try zon.parse(wire.Output, self.allocator, text);
        errdefer zon.free(self.allocator, output);
        if (output.version != wire.version) return error.UnsupportedRunnerVersion;
        if (!std.mem.eql(u8, &output.snapshot_id, &self.snapshot_id)) return error.RunnerSnapshotMismatch;
        if (output.commands.len > wire.max_events or
            output.events.len > wire.max_events or
            output.signals.len > wire.max_events) return error.RunnerEventLimit;
        return .{ .allocator = self.allocator, .value = output };
    }

    /// The client owns correlation numbers. Failed/reset/stopped replies retain
    /// their diagnostics for the caller and close the process before returning.
    pub fn step(self: *Client, command: wire.Command, time_us: u64, timeout_ms: u32) !Reply {
        if (self.session.child == null) return error.RunnerNotRunning;
        errdefer self.session.stop(self.io);
        if (time_us < self.time_us) return error.InvalidRunnerTime;
        if (self.sequence == std.math.maxInt(u64)) return error.RunnerSequenceExhausted;
        const sequence = self.sequence + 1;
        var encoded: std.Io.Writer.Allocating = .init(self.allocator);
        defer encoded.deinit();
        try std.zon.stringify.serializeMaxDepth(
            wire.Input{ .sequence = sequence, .time_us = time_us, .command = command },
            .{ .whitespace = false },
            &encoded.writer,
            16,
        );
        var reply = try self.receive(encoded.written(), timeout_ms);
        errdefer reply.deinit();
        if (reply.value.sequence != sequence) return error.RunnerSequenceMismatch;
        const expected: @TypeOf(reply.value.state) = switch (command) {
            .reset => .restart_required,
            .stop => .stopped,
            else => .processed,
        };
        if (reply.value.state != expected and reply.value.state != .failed) return error.InvalidRunnerState;
        self.sequence = sequence;
        self.time_us = time_us;
        if (reply.value.state != .processed) self.session.stop(self.io);
        return reply;
    }

    pub fn destroy(self: *Client) void {
        self.session.stop(self.io);
        const gpa = self.allocator;
        self.* = undefined;
        gpa.destroy(self);
    }
};
