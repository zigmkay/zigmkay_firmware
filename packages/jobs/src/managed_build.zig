//! Owned explicit build lifecycle. Bundled compilation and artifact promotion are separate.
const std = @import("std");
const jobs = @import("root.zig");
const zon = @import("owned-zon");
pub const Request = struct {
    pub const Bundled = struct {
        inputs: jobs.firmware.Inputs,
        receipt: jobs.build_context.Receipt,
    };
    native_only: bool = false,
    payload_executable: ?[]const u8 = null,
    payload_root: ?[]const u8 = null,
    /// Identity supplied by the installed application descriptor.
    bundled: Bundled,
    source_cache: ?[]const u8 = null,
    selection: jobs.build_context.Selection,
    export_directory: []const u8,
    expected_export_tree: jobs.firmware.Digest,
    install_directory: []const u8,
    development_firmware: ?[]const u8 = null,
    // Cold builds compile the shipped build runner, native runner and firmware.
    // Hosted Windows runners can exceed five minutes without being hung.
    timeout_ms: u32 = 900_000,
};
fn compilerCacheDirectory(a: std.mem.Allocator, request: Request) ![]u8 {
    return std.fs.path.join(a, &.{ request.install_directory, "compiler-cache", &std.fmt.bytesToHex(request.bundled.receipt.bundle_id, .lower) });
}
/// A single small completion marker, read only when a build is requested.
pub fn isFirstBuild(gpa: std.mem.Allocator, io: std.Io, request: Request) bool {
    const path = compilerCacheDirectory(gpa, request) catch return true;
    defer gpa.free(path);
    var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch return true;
    defer directory.close(io);
    _ = directory.statFile(io, "built", .{}) catch return true;
    return false;
}
/// Stable address from start through completion/cancellation.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    request: Request,
    captured: jobs.build_context.Captured,
    command: jobs.firmware.Command,
    process: jobs.Job,
    install_name: []const u8,
    completed: bool = false,
    accepted: bool = false,
    runner_completed: bool = false,
    finish_verified: bool = false,
    finish_verified_key: jobs.firmware.Digest = @splat(0),
    finish_verified_receipt: jobs.build_context.Receipt = undefined,
    finish_verified_at_ms: i64 = 0,
    pub fn init(gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, request: Request) !Job {
        const phase_start = std.Io.Clock.awake.now(io);
        defer std.log.info("build phase init_capture_ms={d}", .{phase_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds()});
        if (request.timeout_ms == 0) return error.InvalidBuildDeadline;
        if (request.payload_executable) |executable| try jobs.bundle_payload.materialize(gpa, io, executable, request.payload_root orelse return error.InvalidBundlePath);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const owned = try zon.clone(arena.allocator(), request);
        try verifyExport(gpa, io, owned);
        var captured = blk: {
            const bundled = owned.bundled;
            var captured_arena: std.heap.ArenaAllocator = .init(gpa);
            errdefer captured_arena.deinit();
            const copied = try zon.clone(captured_arena.allocator(), bundled.inputs);
            break :blk jobs.build_context.Captured{
                .arena = captured_arena,
                .inputs = copied,
                .receipt = bundled.receipt,
            };
        };
        errdefer captured.deinit();
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const install_name = try std.fmt.allocPrint(arena.allocator(), "build-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
        const install_path = try std.fs.path.join(arena.allocator(), &.{ owned.install_directory, install_name });
        var command = try jobs.firmware.Command.init(gpa, captured.inputs, owned.selection.compiler_path, owned.selection.build_root, owned.export_directory, install_path, owned.development_firmware);
        errdefer command.deinit();
        if (owned.native_only) {
            const args = try command.arena.allocator().alloc([]const u8, command.argv.len + 1);
            @memcpy(args[0..command.argv.len], command.argv);
            args[4] = "build-runner";
            args[command.argv.len] = "-Dnative-only=true";
            command.argv = args;
        }
        var selected_environment = try environment.clone(gpa);
        defer selected_environment.deinit();
        const compiler_cache = try compilerCacheDirectory(arena.allocator(), owned);
        try selected_environment.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(arena.allocator(), &.{ compiler_cache, "global" }));
        for ([_][]const u8{ "ZIG_LOCAL_CACHE_DIR", "ZIG_LOCAL_PKG_DIR", "ZIG_LIBC", "ZIG_LIBC_PATH", "ZIG_BUILD_RUNNER", "ZIG_EXECUTABLE" }) |name| _ = selected_environment.swapRemove(name);
        // Zig's system package mode reads supplied package directories and
        // refuses fetching missing packages during the managed build. Graphs
        // without external sources receive an empty output-local package path.
        const a = command.arena.allocator();
        const package_absolute = if (owned.source_cache) |cache| try std.fs.path.join(a, &.{ cache, "p" }) else try std.fs.path.join(a, &.{ install_path, "empty-packages" });
        // Zig 0.17 resolves nested path dependencies against this spelling.
        // An absolute system package path makes those dependencies invalid.
        const package_path = try std.fs.path.relativeAlloc(a, command.cwd, &selected_environment, command.cwd, package_absolute);
        try selected_environment.put("ZIG_LIB_DIR", try std.fs.path.join(a, &.{ owned.selection.compiler_distribution_path, "lib" }));
        {
            const args = try a.alloc([]const u8, command.argv.len + 2);
            @memcpy(args[0..command.argv.len], command.argv);
            args[9] = try std.fs.path.join(a, &.{ compiler_cache, "local" });
            args[command.argv.len] = "--system";
            args[command.argv.len + 1] = package_path;
            command.argv = args;
        }
        const process = try jobs.Job.init(gpa, io, .{ .argv = command.argv, .cwd = command.cwd, .snapshot_id = command.build_key, .timeout_ms = owned.timeout_ms, .environ_map = &selected_environment, .isolated_group = @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi });
        return .{ .arena = arena, .gpa = gpa, .io = io, .request = owned, .captured = captured, .command = command, .process = process, .install_name = install_name };
    }
    pub fn start(self: *Job, current: jobs.firmware.Inputs) !void {
        if (self.completed) return error.BuildAlreadyCompleted;
        if (self.process.started) return error.JobAlreadyStarted;
        if (!std.mem.eql(u8, &self.command.build_key, &jobs.firmware.key(current))) return error.StaleBuild;
        const phase_start = std.Io.Clock.awake.now(self.io);
        try verifyExport(self.gpa, self.io, self.request);
        std.log.info("build phase start_recheck_ms={d}", .{phase_start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds()});
        var output = try std.Io.Dir.cwd().createDirPathOpen(self.io, self.request.install_directory, .{});
        defer output.close(self.io);
        try output.createDir(self.io, self.install_name, .default_dir);
        try self.process.start();
    }
    pub fn poll(self: *Job) ?anyerror!jobs.Result {
        return self.process.poll();
    }
    /// Read/verify bytes only after successful bounded process completion.
    /// Caller owns the returned manifest and explicitly promotes it if still current.
    pub fn finish(self: *Job, result: jobs.Result, current: jobs.firmware.Inputs) !jobs.firmware.Manifest {
        if (self.completed or self.process.future != null or !self.process.started) return error.BuildNotCompleted;
        self.completed = true;
        self.finish_verified = false;
        if (!std.mem.eql(u8, &result.snapshot_id, &self.command.build_key)) return error.StaleBuild;
        if (!result.successful()) return error.BuildFailed;
        if (!std.mem.eql(u8, &jobs.firmware.key(current), &self.command.build_key)) return error.StaleBuild;
        const phase_start = std.Io.Clock.awake.now(self.io);
        try verifyExport(self.gpa, self.io, self.request);
        std.log.info("build phase finish_recheck_ms={d}", .{phase_start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds()});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, self.command.uf2_path, self.gpa, .limited(16 * 1024 * 1024));
        defer self.gpa.free(bytes);
        var manifest = try jobs.firmware.Manifest.complete(self.gpa, .succeeded, self.command.build_key, self.captured.inputs, current, self.command.uf2_path, bytes);
        manifest.audit_mode = .bundled;
        // Informational only: losing this marker must never reject a valid build.
        self.noteWarmCache() catch {};
        self.accepted = true;
        self.finish_verified_key = jobs.firmware.key(current);
        self.finish_verified_receipt = self.captured.receipt;
        self.finish_verified_at_ms = std.Io.Clock.awake.now(self.io).toMilliseconds();
        self.finish_verified = true;
        return manifest;
    }
    fn noteWarmCache(self: *Job) !void {
        const path = try compilerCacheDirectory(self.gpa, self.request);
        defer self.gpa.free(path);
        var directory = try std.Io.Dir.cwd().createDirPathOpen(self.io, path, .{});
        defer directory.close(self.io);
        try directory.writeFile(self.io, .{ .sub_path = "built", .data = "" });
    }
    /// The existing build-project command also installs the native processor runner.
    /// It is accepted only after successful firmware completion from this same job.
    pub fn finishRunner(self: *Job, current: jobs.firmware.Inputs) !jobs.runner_artifact.Manifest {
        if (!self.accepted or !self.finish_verified or self.runner_completed) return error.RunnerBuildNotCompleted;
        self.runner_completed = true;
        self.finish_verified = false;
        const phase_start = std.Io.Clock.awake.now(self.io);
        defer std.log.info("build phase runner_finalization_ms={d}", .{phase_start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds()});
        if (!std.mem.eql(u8, &jobs.firmware.key(current), &self.finish_verified_key) or
            !std.mem.eql(u8, &self.finish_verified_key, &self.command.build_key) or
            !std.meta.eql(self.finish_verified_receipt, self.captured.receipt) or
            std.Io.Clock.awake.now(self.io).toMilliseconds() - self.finish_verified_at_ms > 1000) return error.StaleBuild;
        const output = std.fs.path.dirname(std.fs.path.dirname(self.command.uf2_path).?).?;
        const executable = "project-runner" ++ if (@import("builtin").os.tag == .windows) ".exe" else "";
        const path = try std.fs.path.join(self.gpa, &.{ output, "bin", executable });
        defer self.gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(jobs.runner_artifact.max_bytes));
        defer self.gpa.free(bytes);
        return jobs.runner_artifact.Manifest.complete(self.gpa, .succeeded, jobs.runner_artifact.key(self.captured.inputs, jobs.runner_artifact.native_target), self.captured.inputs, current, path, bytes);
    }
    /// Native-only completion has its own successful process and freshness gate;
    /// no UF2 file is read or required.
    pub fn finishNativeRunner(self: *Job, result: jobs.Result, current: jobs.firmware.Inputs) !jobs.runner_artifact.Manifest {
        if (!self.request.native_only or self.completed or self.process.future != null or !self.process.started) return error.RunnerBuildNotCompleted;
        self.completed = true;
        if (!result.successful()) return error.BuildFailed;
        if (!std.mem.eql(u8, &result.snapshot_id, &self.command.build_key) or !std.mem.eql(u8, &jobs.firmware.key(current), &self.command.build_key)) return error.StaleBuild;
        try verifyExport(self.gpa, self.io, self.request);
        const output = std.fs.path.dirname(std.fs.path.dirname(self.command.uf2_path).?).?;
        const path = try std.fs.path.join(self.gpa, &.{ output, "bin", "project-runner" ++ if (@import("builtin").os.tag == .windows) ".exe" else "" });
        defer self.gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(jobs.runner_artifact.max_bytes));
        defer self.gpa.free(bytes);
        return jobs.runner_artifact.Manifest.complete(self.gpa, .succeeded, jobs.runner_artifact.key(current, jobs.runner_artifact.native_target), self.captured.inputs, current, path, bytes);
    }
    pub fn cancel(self: *Job) void {
        self.process.cancel();
        self.completed = true;
        self.accepted = false;
        self.finish_verified = false;
    }
    pub fn deinit(self: *Job) void {
        self.process.deinit();
        self.command.deinit();
        self.captured.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};
fn verifyExport(gpa: std.mem.Allocator, io: std.Io, request: Request) !void {
    if (!std.fs.path.isAbsolute(request.export_directory)) return error.InvalidBuildPath;
    var dir = try std.Io.Dir.cwd().openDir(io, request.export_directory, .{ .iterate = true });
    defer dir.close(io);
    const actual = try jobs.source_digest.treeDigest(gpa, io, dir);
    if (!std.mem.eql(u8, &actual, &request.expected_export_tree)) return error.ExportedSourceChanged;
}
