const std = @import("std");
pub const application_bundle = @import("application_bundle.zig");
pub const bundle_payload = @import("bundle_payload.zig");
pub const source_files = @import("source_files.zig");
pub const firmware = @import("firmware.zig");
pub const target_lock = @import("target_lock.zig");
pub const source_digest = @import("source_digest.zig");
pub const package_manifest = @import("package_manifest.zig");
pub const sidecar = @import("sidecar.zig");
pub const flash_inputs = @import("flash_inputs.zig");
pub const picotool_job = @import("picotool_job.zig");
pub const managed_flash = @import("managed_flash.zig");
pub const managed_build = @import("managed_build.zig");
pub const build_context = @import("build_context.zig");
pub const runner_artifact = @import("runner_artifact.zig");
pub const output_limit = 1024 * 1024;
pub const SnapshotId = [32]u8;

pub const Spec = struct {
    argv: []const []const u8,
    cwd: []const u8,
    snapshot_id: SnapshotId,
    timeout_ms: u32 = 60_000,
    /// Explicit replacement environment; null preserves inheritance.
    environ_map: ?*const std.process.Environ.Map = null,
    /// POSIX build subprocesses and their descendants share one owned group.
    isolated_group: bool = false,
};

pub const Result = struct {
    process: std.process.RunResult,
    snapshot_id: SnapshotId,
    elapsed_ns: i96,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.process.stdout);
        gpa.free(self.process.stderr);
        self.* = undefined;
    }

    pub fn successful(self: Result) bool {
        return switch (self.process.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    pub fn fresh(self: Result, current: SnapshotId) bool {
        return std.mem.eql(u8, &self.snapshot_id, &current);
    }
};

fn execute(gpa: std.mem.Allocator, io: std.Io, spec: Spec) anyerror!std.process.RunResult {
    const posix_groups = comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi;
    if (!posix_groups and spec.isolated_group) return error.ProcessGroupUnavailable;
    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(spec.timeout_ms),
        .clock = .awake,
    } };
    const deadline = timeout.toDeadline(io);
    var child = try std.process.spawn(io, .{
        .argv = spec.argv,
        .cwd = .{ .path = spec.cwd },
        .environ_map = spec.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (posix_groups and spec.isolated_group) 0 else null,
    });
    var reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(gpa, io, reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    var succeeded = false;
    defer {
        // Close the producer before joining pending pipe reads. In particular,
        // a cancelled outer build worker must not await a hung producer here.
        if (comptime posix_groups) {
            if (!succeeded and spec.isolated_group) if (child.id) |id| {
                _ = std.posix.system.kill(-id, std.posix.SIG.KILL);
            };
        }
        if (comptime @import("builtin").os.tag == .windows) {
            if (!succeeded) stopWindowsProducerAndReads(&child);
            reader.deinit();
            if (!succeeded) std.log.info("Windows subprocess cleanup: reads joined; closing handles", .{});
            child.kill(io);
            if (!succeeded) std.log.info("Windows subprocess cleanup: complete", .{});
        } else {
            child.kill(io);
            reader.deinit();
        }
    }
    while (reader.fill(4096, deadline)) |_| {
        if (reader.reader(0).buffered().len > output_limit or
            reader.reader(1).buffered().len > output_limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    succeeded = true;
    return .{ .stdout = stdout, .stderr = stderr, .term = term };
}

/// Child.kill also closes the pipes. Keep them open until MultiReader has
/// consumed the cancellation APCs and released its read buffers. Zig 0.17's
/// Windows batchCancel waits for an APC before submitting cancellation itself,
/// so request cancellation here before entering that wait.
fn stopWindowsProducerAndReads(child: *std.process.Child) void {
    const windows = std.os.windows;
    const Api = struct {
        // Zig 0.17 has no CancelIoEx binding. A null request cancels all reads
        // on this owned pipe; buffers must still be joined before release.
        extern "kernel32" fn CancelIoEx(windows.HANDLE, ?*anyopaque) callconv(.winapi) windows.BOOL;
    };
    if (child.id) |handle| {
        std.log.info("Windows subprocess cleanup: terminating producer", .{});
        const status = windows.ntdll.NtTerminateProcess(handle, @fromBackingInt(@intCast(1)));
        switch (status) {
            .SUCCESS, .PROCESS_IS_TERMINATING => {},
            // A process that has already exited may reject termination. The
            // normal Child.kill below still owns reaping and handle closure.
            .ACCESS_DENIED => {},
            else => std.log.warn("Windows subprocess termination status: {t}", .{status}),
        }
    }
    std.log.info("Windows subprocess cleanup: requesting pipe cancellation", .{});
    for ([_]?std.Io.File{ child.stdout, child.stderr }) |optional_file| {
        if (optional_file) |file| {
            if (!Api.CancelIoEx(file.handle, null).toBool()) {
                const status = windows.GetLastError();
                if (status != .NOT_FOUND) std.log.warn("Windows pipe cancellation status: {t}", .{status});
            }
        }
    }
    std.log.info("Windows subprocess cleanup: joining pending reads", .{});
}

fn expire(io: std.Io, milliseconds: u32) anyerror!void {
    try std.Io.sleep(io, .fromMilliseconds(milliseconds), .awake);
}

/// Runs argv directly, concurrently drains stdout/stderr, and kills/reaps on timeout/cancel.
/// Includes a watchdog around wait too, even if a hung child closes its output pipes.
pub fn run(gpa: std.mem.Allocator, io: std.Io, spec: Spec) !Result {
    const start = std.Io.Clock.awake.now(io);
    const Completion = union(enum) { process: anyerror!std.process.RunResult, timeout: anyerror!void };
    var buffer: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &buffer);
    defer {
        while (select.cancel()) |pending| if (pending == .process) {
            if (pending.process) |result| {
                gpa.free(result.stdout);
                gpa.free(result.stderr);
            } else |_| {}
        };
    }
    try select.concurrent(.process, execute, .{ gpa, io, spec });
    try select.concurrent(.timeout, expire, .{ io, spec.timeout_ms });
    const completed = try select.await();
    switch (completed) {
        .timeout => |status| {
            try status;
            return error.Timeout;
        },
        .process => |status| return .{
            .process = try status,
            .snapshot_id = spec.snapshot_id,
            .elapsed_ns = start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds,
        },
    }
}

/// Stable-address owner for one asynchronous job. All args/cwd are copied before start.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    spec: Spec,
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(anyerror!Result) = null,
    started: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, spec: Spec) !Job {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const args = try a.alloc([]const u8, spec.argv.len);
        for (spec.argv, args) |arg, *dest| dest.* = try a.dupe(u8, arg);
        const cwd = try a.dupe(u8, spec.cwd);
        var copied = spec;
        copied.argv = args;
        copied.cwd = cwd;
        if (spec.environ_map) |environment| {
            const owned_environment = try a.create(std.process.Environ.Map);
            owned_environment.* = try environment.clone(a);
            copied.environ_map = owned_environment;
        }
        return .{ .arena = arena, .gpa = gpa, .io = io, .spec = copied };
    }

    fn work(self: *Job) anyerror!Result {
        defer self.done.store(true, .release);
        return run(self.gpa, self.io, self.spec);
    }

    pub fn start(self: *Job) !void {
        if (self.started) return error.JobAlreadyStarted;
        self.future = try std.Io.concurrent(self.io, work, .{self});
        self.started = true;
    }

    pub fn poll(self: *Job) ?anyerror!Result {
        if (self.future == null or !self.done.load(.acquire)) return null;
        const result = self.future.?.await(self.io);
        self.future = null;
        return result;
    }

    /// Blocks until the started job completes, polling every millisecond.
    pub fn wait(self: *Job) anyerror!Result {
        while (true) {
            if (self.poll()) |result| return result;
            try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
    }

    pub fn cancel(self: *Job) void {
        if (self.future) |*future| {
            if (future.cancel(self.io)) |result| {
                var owned = result;
                owned.deinit(self.gpa);
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

/// One runner pipe session. A stable-address owner serializes requests; timeouts kill it.
/// No response or input can grow without a bound. Reset means stop and spawn a new process.
pub const Session = struct {
    pub const reply_limit = 1024 * 1024;
    child: ?std.process.Child = null,
    buffer: [reply_limit + 1]u8 = undefined,
    reader: ?std.Io.File.Reader = null,

    pub fn start(self: *Session, io: std.Io, argv: []const []const u8) !void {
        if (self.child != null) return error.SessionAlreadyStarted;
        self.child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        self.reader = self.child.?.stdout.?.readerStreaming(io, &self.buffer);
    }

    fn exchange(self: *Session, gpa: std.mem.Allocator, io: std.Io, frame: ?[]const u8) anyerror![]u8 {
        if (frame) |line| {
            if (line.len > 4096 or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidInputFrame;
            try self.child.?.stdin.?.writeStreamingAll(io, line);
            try self.child.?.stdin.?.writeStreamingAll(io, "\n");
        }
        const line = try self.reader.?.interface.takeDelimiter('\n') orelse return error.RunnerExited;
        return gpa.dupe(u8, line);
    }

    pub fn request(
        self: *Session,
        gpa: std.mem.Allocator,
        io: std.Io,
        frame: ?[]const u8,
        timeout_ms: u32,
    ) ![]u8 {
        if (self.child == null) return error.SessionNotStarted;
        errdefer self.stop(io);
        const Completion = union(enum) { reply: anyerror![]u8, timeout: anyerror!void };
        var buffer: [2]Completion = undefined;
        var select = std.Io.Select(Completion).init(io, &buffer);
        defer {
            while (select.cancel()) |pending| if (pending == .reply) {
                if (pending.reply) |bytes| gpa.free(bytes) else |_| {}
            };
        }
        try select.concurrent(.reply, exchange, .{ self, gpa, io, frame });
        try select.concurrent(.timeout, expire, .{ io, timeout_ms });
        const completed = try select.await();
        return switch (completed) {
            .reply => |result| try result,
            .timeout => |status| blk: {
                try status;
                break :blk error.Timeout;
            },
        };
    }

    pub fn stop(self: *Session, io: std.Io) void {
        if (self.child) |*child| child.kill(io);
        self.child = null;
        self.reader = null;
    }
};

pub const ArtifactInput = struct {
    snapshot_id: SnapshotId,
    build_inputs_digest: [32]u8,
    zig_version: []const u8,
    target: []const u8,
    optimize: []const u8,
};

/// Separate from telemetry identity: compiler/dependency/target changes invalidate artifacts.
pub fn artifactKey(input: ArtifactInput) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-artifact-v1\x00");
    hash.update(&input.snapshot_id);
    hash.update(&input.build_inputs_digest);
    for ([_][]const u8{ input.zig_version, input.target, input.optimize }) |field| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, field.len, .little);
        hash.update(&length);
        hash.update(field);
    }
    return hash.finalResult();
}
