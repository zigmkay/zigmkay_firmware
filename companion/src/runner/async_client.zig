//! Stable-address UI owner. Explicit executable input; no preparation or devices.
const std = @import("std");
const client = @import("runner-client");
const wire = @import("runner-protocol");
const jobs = @import("companion-jobs");
pub const Ticket = struct { generation: u64, snapshot: [32]u8 };
pub const State = enum { starting, running, stopped, failed, stale };

pub const Event = union(enum) {
    ready: Ticket,
    reply: struct { ticket: Ticket, output: client.Reply },
    failed: struct { ticket: Ticket, failure: anyerror },
};

const Request = struct { command: wire.Command, time_us: u64 };
const Completion = union(enum) { started: *client.Client, reply: client.Reply };

pub const Owner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    ticket: Ticket,
    timeout_ms: u32,
    encoder_count: usize,
    pressed: []bool,
    state: State = .starting,
    peer: ?*client.Client = null,
    future: ?std.Io.Future(anyerror!Completion) = null,
    done: std.atomic.Value(bool) = .init(false),
    pending: Request = .{ .command = .advance, .time_us = 0 },
    queue: std.ArrayList(Request) = .empty,
    time_us: u64 = 0,
    pub const queue_limit = 128;

    pub fn createVerified(
        gpa: std.mem.Allocator,
        io: std.Io,
        manifest: jobs.runner_artifact.Manifest,
        current: jobs.firmware.Inputs,
        ticket: Ticket,
        key_count: usize,
        encoder_count: usize,
        timeout_ms: u32,
    ) !*Owner {
        if (!std.mem.eql(u8, &ticket.snapshot, &manifest.record.inputs.project_digest))
            return error.RunnerSnapshotMismatch;
        try manifest.verifyFile(gpa, io, current);
        return create(gpa, io, &.{manifest.record.path}, ticket, key_count, encoder_count, timeout_ms);
    }

    /// The caller has already accepted executable provenance. Arguments are
    /// copied before asynchronous startup; greeting and replies remain bounded.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        ticket: Ticket,
        key_count: usize,
        encoder_count: usize,
        timeout_ms: u32,
    ) !*Owner {
        if (argv.len == 0 or !std.fs.path.isAbsolute(argv[0])) return error.AbsoluteRunnerRequired;
        if (key_count == 0 or
            key_count > 127 or
            encoder_count > 256 or
            timeout_ms == 0) return error.InvalidRunnerDimensions;
        const self = try gpa.create(Owner);
        errdefer gpa.destroy(self);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const args = try arena.allocator().alloc([]const u8, argv.len);
        for (args, argv) |*owned, arg| owned.* = try arena.allocator().dupe(u8, arg);
        const pressed = try arena.allocator().alloc(bool, key_count);
        @memset(pressed, false);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = arena,
            .argv = args,
            .ticket = ticket,
            .timeout_ms = timeout_ms,
            .encoder_count = encoder_count,
            .pressed = pressed,
        };
        self.future = try std.Io.concurrent(io, startWorker, .{self});
        return self;
    }

    fn startWorker(self: *Owner) anyerror!Completion {
        defer self.done.store(true, .release);
        return .{
            .started = try client.Client.create(
                self.gpa,
                self.io,
                self.argv,
                self.ticket.snapshot,
                self.timeout_ms,
            ),
        };
    }

    fn stepWorker(self: *Owner) anyerror!Completion {
        defer self.done.store(true, .release);
        return .{
            .reply = try self.peer.?.step(self.pending.command, self.pending.time_us, self.timeout_ms),
        };
    }

    fn clearCompletion(completion: Completion) void {
        switch (completion) {
            .started => |peer| peer.destroy(),
            .reply => |value| {
                var owned = value;
                owned.deinit();
            },
        }
    }

    /// Cancellation joins the outstanding exchange before destroying its peer.
    /// No worker can still access the owner when this returns.
    pub fn stop(self: *Owner) void {
        if (self.future) |*future| {
            if (future.cancel(self.io)) |completion| clearCompletion(completion) else |_| {}
            self.future = null;
        }
        if (self.peer) |peer| peer.destroy();
        self.peer = null;
        self.queue.clearRetainingCapacity();
        @memset(self.pressed, false);
        self.state = .stopped;
    }

    pub fn destroy(self: *Owner) void {
        self.stop();
        self.queue.deinit(self.gpa);
        self.arena.deinit();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    pub fn input(self: *Owner, command: wire.Command, time_us: u64) !void {
        if (self.state != .running) return error.RunnerNotRunning;
        if (self.queue.items.len >= queue_limit) return error.InputQueueFull;
        if (time_us < self.time_us) return error.InvalidRunnerTime;
        switch (command) {
            .key_down => |index| if (index >= self.pressed.len or self.pressed[index]) return error.InvalidKeyDown,
            .key_up => |index| if (index >= self.pressed.len or !self.pressed[index]) return error.InvalidKeyUp,
            .encoder => |index| if (index >= self.encoder_count) return error.InvalidEncoder,
            else => {},
        }
        try self.queue.append(self.gpa, .{ .command = command, .time_us = time_us });
        // Commit local state only once allocation and validation have succeeded.
        switch (command) {
            .key_down => |index| self.pressed[index] = true,
            .key_up => |index| self.pressed[index] = false,
            else => {},
        }
        self.time_us = time_us;
    }

    /// Reserve the entire batch before changing local held state. A blur cannot
    /// leave only some releases queued because capacity/allocation ran out.
    pub fn releaseHeld(self: *Owner, time_us: u64) !void {
        if (self.state != .running) return error.RunnerNotRunning;
        if (time_us < self.time_us) return error.InvalidRunnerTime;
        const count = std.mem.count(bool, self.pressed, &.{true});
        if (count > queue_limit - self.queue.items.len) return error.InputQueueFull;
        try self.queue.ensureUnusedCapacity(self.gpa, count);
        for (self.pressed, 0..) |*down, index| if (down.*) {
            self.queue.appendAssumeCapacity(.{
                .command = .{ .key_up = @intCast(index) },
                .time_us = time_us,
            });
            down.* = false;
        };
        self.time_us = time_us;
    }

    fn fail(self: *Owner, failure: anyerror) Event {
        self.stop();
        self.state = .failed;
        return .{ .failed = .{ .ticket = self.ticket, .failure = failure } };
    }

    /// One owned event per poll. Caller frees reply output after consumption.
    /// Ticket mismatch joins/reaps without promoting any stale output.
    pub fn poll(self: *Owner, current: Ticket) ?Event {
        if (!std.meta.eql(current, self.ticket)) {
            self.stop();
            self.state = .stale;
            return null;
        }
        if (self.future != null and self.done.load(.acquire)) {
            const result = self.future.?.await(self.io);
            self.future = null;
            const completion = result catch |failure| return self.fail(failure);
            switch (completion) {
                .started => |peer| {
                    self.peer = peer;
                    self.state = .running;
                    return .{ .ready = self.ticket };
                },
                .reply => |reply| {
                    if (reply.value.state != .processed) {
                        self.stop();
                        self.state = if (reply.value.state == .failed) .failed else .stopped;
                    }
                    return .{ .reply = .{ .ticket = self.ticket, .output = reply } };
                },
            }
        }
        if (self.state == .running and self.future == null and self.queue.items.len > 0) {
            self.pending = self.queue.orderedRemove(0);
            self.done.store(false, .release);
            self.future = std.Io.concurrent(self.io, stepWorker, .{self}) catch |failure| return self.fail(failure);
        }
        return null;
    }
};
