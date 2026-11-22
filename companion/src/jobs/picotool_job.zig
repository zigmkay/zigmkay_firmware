//! Controlled picotool_flash wrapper job. This module never transfers firmware itself.
const std = @import("std");
pub const output_limit = 64 * 1024;

/// unique_bootsel delegates zero/multiple-device handling to the wrapper's
/// picotool-info discovery; it must only follow explicit user confirmation.
pub const Selection = union(enum) {
    bus_address: struct { bus: u8, address: u8 },
    serial: []const u8,
    unique_bootsel,
};

pub const Spec = struct {
    backend: @import("flash_inputs.zig").Backend = .picotool,
    wrapper: []const u8,
    picotool: []const u8,
    firmware: []const u8,
    expected_sha256: [32]u8,
    snapshot_id: [32]u8,
    selection: Selection,
    discovery_ms: u32 = 30_000,
    command_ms: u32 = 60_000,
};

pub const Result = struct {
    backend: @import("flash_inputs.zig").Backend = .picotool,
    process: std.process.RunResult,
    snapshot_id: [32]u8,
    cancelled: bool,
    timed_out: bool,
    diagnostics_truncated: bool,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.process.stdout);
        gpa.free(self.process.stderr);
        self.* = undefined;
    }

    pub fn successful(self: Result) bool {
        return self.process.term.success() and !self.cancelled and !self.timed_out;
    }

    pub fn fresh(self: Result, current: [32]u8) bool {
        return std.mem.eql(u8, &self.snapshot_id, &current);
    }
};

/// Stable-address owner. Cancellation does not cancel the collection future or kill
/// the wrapper: EOF asks it to reap picotool, and we then await its exit.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    spec: Spec,
    argv: []const []const u8,
    child: ?std.process.Child = null,
    future: ?std.Io.Future(anyerror!Result) = null,
    done: std.atomic.Value(bool) = .init(false),
    requested: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    started: bool = false,
    discovery_complete: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, spec: Spec) !Job {
        for ([_][]const u8{ spec.wrapper, spec.picotool, spec.firmware }) |p| {
            if (!std.fs.path.isAbsolute(p)) return error.AbsolutePathRequired;
            if (std.mem.indexOfScalar(u8, p, 0) != null) return error.InvalidPath;
        }
        if (spec.discovery_ms == 0 or
            spec.discovery_ms > 3_600_000 or
            spec.command_ms == 0 or
            spec.command_ms > 3_600_000) return error.InvalidBudget;
        switch (spec.selection) {
            .bus_address => |s| if (s.address == 0 or s.address > 127) {
                return error.InvalidSelection;
            },
            .serial => |s| if (s.len == 0 or std.mem.indexOfScalar(u8, s, 0) != null) {
                return error.InvalidSelection;
            },
            .unique_bootsel => {},
        }
        if (spec.backend == .windows_bootsel and
            spec.selection != .unique_bootsel) return error.UnsupportedBootselSelection;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var copied = spec;
        copied.wrapper = try a.dupe(u8, spec.wrapper);
        copied.picotool = try a.dupe(u8, spec.picotool);
        copied.firmware = try a.dupe(u8, spec.firmware);
        var args: std.ArrayList([]const u8) = .empty;
        const digest = std.fmt.bytesToHex(spec.expected_sha256, .lower);
        try args.append(a, copied.wrapper);
        if (spec.backend == .picotool) try args.append(a, copied.picotool);
        try args.appendSlice(a, &.{
            copied.firmware,
            "--sha256",
            try a.dupe(u8, &digest),
            "--discovery-ms",
            try std.fmt.allocPrint(a, "{d}", .{spec.discovery_ms}),
            "--command-ms",
            try std.fmt.allocPrint(a, "{d}", .{spec.command_ms}),
            "--cancel-stdin",
        });
        switch (spec.selection) {
            .bus_address => |s| try args.appendSlice(a, &.{
                "--bus",
                try std.fmt.allocPrint(a, "{d}", .{s.bus}),
                "--address",
                try std.fmt.allocPrint(a, "{d}", .{s.address}),
            }),
            .serial => |s| {
                copied.selection = .{ .serial = try a.dupe(u8, s) };
                try args.appendSlice(a, &.{ "--serial", copied.selection.serial });
            },
            .unique_bootsel => {}, // No selector: wrapper must reject ambiguity and retry absence.
        }
        return .{ .arena = arena, .gpa = gpa, .io = io, .spec = copied, .argv = try args.toOwnedSlice(a) };
    }

    pub fn start(self: *Job) !void {
        if (self.started) return error.JobAlreadyStarted;
        if (self.requested.load(.acquire)) return error.FlashCancelled;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.spec.firmware,
            self.gpa,
            .limited(16 * 1024 * 1024),
        );
        defer self.gpa.free(bytes);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        if (!std.mem.eql(u8, &hash, &self.spec.expected_sha256)) return error.HashMismatch;
        self.child = try std.process.spawn(self.io, .{
            .argv = self.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        // If scheduling fails, EOF still requests controlled cleanup.
        self.future = std.Io.concurrent(self.io, work, .{self}) catch |err| {
            self.child.?.stdin.?.close(self.io);
            self.child.?.stdin = null;
            _ = self.child.?.wait(self.io) catch {};
            self.child = null;
            return err;
        };
        self.started = true;
    }

    fn monitor(self: *Job, stdin: std.Io.File) anyerror!void {
        defer stdin.close(self.io);
        const start_time = std.Io.Clock.awake.now(self.io);
        const command_count: i96 = if (self.spec.backend == .windows_bootsel) 1 else 3;
        const budget: i96 = (@as(i96, self.spec.discovery_ms) + command_count * @as(i96, self.spec.command_ms) + 1000) * std.time.ns_per_ms;
        while (!self.requested.load(.acquire)) {
            if (start_time.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds >= budget) {
                self.timed_out.store(true, .release);
                return;
            }
            try std.Io.sleep(self.io, .fromMilliseconds(10), .awake);
        }
    }

    fn work(self: *Job) anyerror!Result {
        defer self.done.store(true, .release);
        const stdin = self.child.?.stdin.?;
        self.child.?.stdin = null;
        var watcher = std.Io.concurrent(self.io, monitor, .{ self, stdin }) catch |err| {
            stdin.close(self.io);
            _ = self.child.?.wait(self.io) catch {};
            self.child = null;
            return err;
        };
        defer _ = watcher.cancel(self.io) catch {};
        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(
            self.gpa,
            self.io,
            buffer.toStreams(),
            &.{ self.child.?.stdout.?, self.child.?.stderr.? },
        );
        defer reader.deinit();
        var outputs: [2]std.ArrayList(u8) = .{ .empty, .empty };
        errdefer for (&outputs) |*o| o.deinit(self.gpa);
        var truncated = false;
        var read_error: ?anyerror = null;
        while (true) {
            reader.fill(4096, .none) catch |err| {
                if (err != error.EndOfStream) read_error = err;
                break;
            };
            for (&outputs, 0..) |*o, i| {
                const r = reader.reader(i);
                const available = r.buffered();
                const keep = @min(available.len, output_limit - o.items.len);
                // Allocation failures also require controlled cancellation/reap.
                o.appendSlice(self.gpa, available[0..keep]) catch |err| {
                    read_error = err;
                    self.requested.store(true, .release);
                };
                if (keep < available.len) truncated = true;
                // Presentation only: never authorizes a transfer or a retry.
                if (i == 1 and
                    std.mem.indexOf(
                        u8,
                        o.items,
                        "phase: load-verify",
                    ) != null) self.discovery_complete.store(true, .release);
                r.toss(available.len);
            }
        }
        reader.checkAnyError() catch |err| {
            read_error = err;
        };
        if (read_error != null) self.requested.store(true, .release);
        const term = try self.child.?.wait(self.io);
        self.child = null;
        if (read_error) |err| return err;
        const stdout = try outputs[0].toOwnedSlice(self.gpa);
        errdefer self.gpa.free(stdout);
        const stderr = try outputs[1].toOwnedSlice(self.gpa);
        const helper_timeout = self.spec.backend == .windows_bootsel and term == .exited and term.exited == 3;
        return .{
            .backend = self.spec.backend,
            .process = .{ .term = term, .stdout = stdout, .stderr = stderr },
            .snapshot_id = self.spec.snapshot_id,
            .cancelled = self.requested.load(.acquire),
            .timed_out = self.timed_out.load(.acquire) or helper_timeout,
            .diagnostics_truncated = truncated,
        };
    }

    pub fn poll(self: *Job) ?anyerror!Result {
        if (self.future == null or !self.done.load(.acquire)) return null;
        const result = self.future.?.await(self.io);
        self.future = null;
        return result;
    }

    /// Nonblocking request; poll retains the cancelled wrapper diagnostics.
    pub fn requestCancel(self: *Job) void {
        self.requested.store(true, .release);
    }

    pub fn cancel(self: *Job) void {
        if (self.future) |*future| {
            self.requestCancel();
            if (future.await(self.io)) |value| {
                var result = value;
                result.deinit(self.gpa);
            } else |_| {}
            self.future = null;
        }
    }

    pub fn deinit(self: *Job) void {
        self.cancel();
        self.arena.deinit();
        self.* = undefined;
    }
};

test "unique BOOTSEL emits no selector arguments for wrapper discovery" {
    var job = try Job.init(std.testing.allocator, std.testing.io, .{
        .wrapper = "/fake/wrapper",
        .picotool = "/fake/picotool",
        .firmware = "/fake/artifact.uf2",
        .expected_sha256 = @splat(0),
        .snapshot_id = @splat(0),
        .selection = .unique_bootsel,
    });
    defer job.deinit();
    for (job.argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "--serial"));
        try std.testing.expect(!std.mem.eql(u8, arg, "--bus"));
        try std.testing.expect(!std.mem.eql(u8, arg, "--address"));
    }
    try std.testing.expectEqualStrings("--cancel-stdin", job.argv[job.argv.len - 1]);
}

test "Windows backend invokes only the helper and refuses picotool selectors" {
    var spec: Spec = .{
        .backend = .windows_bootsel,
        .wrapper = "/helper",
        .picotool = "/unused",
        .firmware = "/frozen.uf2",
        .expected_sha256 = @splat(0),
        .snapshot_id = @splat(0),
        .selection = .unique_bootsel,
    };
    var job = try Job.init(std.testing.allocator, std.testing.io, spec);
    defer job.deinit();
    try std.testing.expectEqualStrings("/helper", job.argv[0]);
    try std.testing.expectEqualStrings("/frozen.uf2", job.argv[1]);
    spec.selection = .{ .serial = "unsupported" };
    try std.testing.expectError(
        error.UnsupportedBootselSelection,
        Job.init(std.testing.allocator, std.testing.io, spec),
    );
}
