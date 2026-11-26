//! Owned explicit build lifecycle. Bundled compilation and artifact promotion are separate.
const std = @import("std");
const jobs = @import("root.zig");
const zon = @import("owned-zon");

pub const Request = struct {
    pub const Bundled = struct {
        inputs: jobs.firmware.Inputs,
        receipt: jobs.build_context.Receipt,
    };

    payload_executable: ?[]const u8 = null,
    payload_root: ?[]const u8 = null,
    /// Identity supplied by the installed application descriptor.
    bundled: Bundled,
    source_cache: ?[]const u8 = null,
    selection: jobs.build_context.Selection,
    export_directory: []const u8,
    expected_export_tree: jobs.firmware.Digest,
    install_directory: []const u8,
    /// Digest of the bundled compiler. Bundles with the same compiler share
    /// one compiler cache; without it the cache stays private to the bundle.
    compiler_identity: ?jobs.firmware.Digest = null,
    /// `zig build -j`; null selects the interactive value for this host.
    parallelism: ?u16 = null,
    // Cold builds compile the shipped build runner, host tools and the
    // firmware. Hosted Windows runners have two to four cores, so they build
    // with -j2 or -j3 and can exceed five minutes without being hung.
    timeout_ms: u32 = 900_000,

    pub fn compilerIdentity(self: Request) jobs.firmware.Digest {
        return self.compiler_identity orelse self.bundled.receipt.bundle_id;
    }

    pub fn compilerCache(self: Request, a: std.mem.Allocator) !jobs.compiler_cache.Layout {
        return .init(a, self.install_directory, self.compilerIdentity());
    }
};

/// A single small completion marker, read only when a build is requested.
pub fn isFirstBuild(gpa: std.mem.Allocator, io: std.Io, request: Request) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const layout = request.compilerCache(arena.allocator()) catch return true;
    return jobs.compiler_cache.isFirstBuild(io, layout, request.bundled.receipt.bundle_id);
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
    compiler_cache: jobs.compiler_cache.Layout,
    /// Held from start until deinit: one compiler per cache at a time, and
    /// cleanup never deletes the cache under it.
    lease: ?jobs.compiler_cache.Lease = null,
    completed: bool = false,
    accepted: bool = false,
    finish_verified: bool = false,
    finish_verified_key: jobs.firmware.Digest = @splat(0),
    finish_verified_receipt: jobs.build_context.Receipt = undefined,
    finish_verified_at_ms: i64 = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
        request: Request,
    ) !Job {
        const phase_start = std.Io.Clock.awake.now(io);
        defer std.log.info("build phase init_capture_ms={d}", .{
            phase_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds(),
        });
        if (request.timeout_ms == 0) return error.InvalidBuildDeadline;
        if (request.payload_executable) |executable| {
            const payload_root = request.payload_root orelse return error.InvalidBundlePath;
            try jobs.bundle_payload.materialize(gpa, io, executable, payload_root);
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const owned = try zon.clone(arena.allocator(), request);
        try verifyExport(gpa, io, owned);
        var captured = try captureBundled(gpa, owned.bundled);
        errdefer captured.deinit();
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const install_name = try std.fmt.allocPrint(
            arena.allocator(),
            "build-{s}",
            .{std.fmt.bytesToHex(nonce, .lower)},
        );
        const install_path = try std.fs.path.join(arena.allocator(), &.{
            owned.install_directory,
            install_name,
        });
        var command = try jobs.firmware.Command.init(
            gpa,
            captured.inputs,
            owned.selection.compiler_path,
            owned.selection.build_root,
            owned.export_directory,
            install_path,
        );
        errdefer command.deinit();
        var selected_environment = try environment.clone(gpa);
        defer selected_environment.deinit();
        const compiler_cache = try owned.compilerCache(arena.allocator());
        try selected_environment.put("ZIG_GLOBAL_CACHE_DIR", try compiler_cache.global(arena.allocator()));
        for ([_][]const u8{
            "ZIG_LOCAL_CACHE_DIR",
            "ZIG_LOCAL_PKG_DIR",
            "ZIG_LIBC",
            "ZIG_LIBC_PATH",
            "ZIG_BUILD_RUNNER",
            "ZIG_EXECUTABLE",
        }) |name| _ = selected_environment.swapRemove(name);
        const a = command.arena.allocator();
        const package_path = try systemPackagePath(
            a,
            owned,
            command.cwd,
            install_path,
            &selected_environment,
        );
        try selected_environment.put(
            "ZIG_LIB_DIR",
            try std.fs.path.join(a, &.{ owned.selection.compiler_distribution_path, "lib" }),
        );
        const args = try extendArgv(&command, &.{ "--system", package_path });
        args[jobs.firmware.Command.cache_dir_arg] = try compiler_cache.local(a);
        args[jobs.firmware.Command.jobs_arg] = try std.fmt.allocPrint(a, "-j{d}", .{
            owned.parallelism orelse jobs.compiler_cache.hostParallelism(false),
        });
        const os = @import("builtin").os.tag;
        const process = try jobs.Job.init(gpa, io, .{
            .argv = command.argv,
            .cwd = command.cwd,
            .snapshot_id = command.build_key,
            .timeout_ms = owned.timeout_ms,
            .environ_map = &selected_environment,
            .isolated_group = os != .windows and os != .wasi,
        });
        return .{
            .arena = arena,
            .gpa = gpa,
            .io = io,
            .request = owned,
            .captured = captured,
            .command = command,
            .process = process,
            .install_name = install_name,
            .compiler_cache = compiler_cache,
        };
    }

    pub fn start(self: *Job, current: jobs.firmware.Inputs) !void {
        if (self.completed) return error.BuildAlreadyCompleted;
        if (self.process.started) return error.JobAlreadyStarted;
        if (!std.mem.eql(u8, &self.command.build_key, &jobs.firmware.key(current))) return error.StaleBuild;
        const phase_start = std.Io.Clock.awake.now(self.io);
        try verifyExport(self.gpa, self.io, self.request);
        std.log.info("build phase start_recheck_ms={d}", .{
            phase_start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds(),
        });
        var output = try std.Io.Dir.cwd().createDirPathOpen(self.io, self.request.install_directory, .{});
        defer output.close(self.io);
        try output.createDir(self.io, self.install_name, .default_dir);
        var root = try std.Io.Dir.cwd().createDirPathOpen(self.io, self.compiler_cache.root, .{});
        defer root.close(self.io);
        // Waits while a background warm-up or another instance compiles.
        self.lease = try .acquire(self.io, root, &self.compiler_cache.name, .fromMilliseconds(self.request.timeout_ms));
        errdefer if (self.lease) |*lease| {
            lease.release(self.io);
            self.lease = null;
        };
        try self.process.start();
    }

    pub fn poll(self: *Job) ?anyerror!jobs.Result {
        return self.process.poll();
    }

    pub fn wait(self: *Job) anyerror!jobs.Result {
        return self.process.wait();
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
        std.log.info("build phase finish_recheck_ms={d}", .{
            phase_start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds(),
        });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.command.uf2_path,
            self.gpa,
            .limited(16 * 1024 * 1024),
        );
        defer self.gpa.free(bytes);
        var manifest = try jobs.firmware.Manifest.complete(
            self.gpa,
            .succeeded,
            self.command.build_key,
            self.captured.inputs,
            current,
            self.command.uf2_path,
            bytes,
        );
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
        try jobs.compiler_cache.noteBuilt(self.io, self.compiler_cache, self.captured.receipt.bundle_id);
    }

    pub fn cancel(self: *Job) void {
        self.process.cancel();
        self.completed = true;
        self.accepted = false;
        self.finish_verified = false;
    }

    pub fn deinit(self: *Job) void {
        self.process.deinit();
        if (self.lease) |*lease| lease.release(self.io);
        self.command.deinit();
        self.captured.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

fn captureBundled(gpa: std.mem.Allocator, bundled: Request.Bundled) !jobs.build_context.Captured {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const inputs = try zon.clone(arena.allocator(), bundled.inputs);
    return .{ .arena = arena, .inputs = inputs, .receipt = bundled.receipt };
}

/// Appends `extra` to the command's arguments and returns the new, mutable
/// argument list, which the command now uses.
fn extendArgv(command: *jobs.firmware.Command, extra: []const []const u8) ![][]const u8 {
    const original = command.argv;
    const args = try command.arena.allocator().alloc([]const u8, original.len + extra.len);
    @memcpy(args[0..original.len], original);
    @memcpy(args[original.len..], extra);
    command.argv = args;
    return args;
}

/// Zig's system package mode reads supplied package directories and refuses
/// fetching missing packages during the managed build. Graphs without external
/// sources receive an empty output-local package path.
fn systemPackagePath(
    a: std.mem.Allocator,
    request: Request,
    cwd: []const u8,
    install_path: []const u8,
    environment: *const std.process.Environ.Map,
) ![]const u8 {
    const absolute = if (request.source_cache) |cache|
        try std.fs.path.join(a, &.{ cache, "p" })
    else
        try std.fs.path.join(a, &.{ install_path, "empty-packages" });
    // Zig 0.17 resolves nested path dependencies against this spelling.
    // An absolute system package path makes those dependencies invalid.
    return std.fs.path.relativeAlloc(a, cwd, environment, cwd, absolute);
}

fn verifyExport(gpa: std.mem.Allocator, io: std.Io, request: Request) !void {
    if (!std.fs.path.isAbsolute(request.export_directory)) return error.InvalidBuildPath;
    var dir = try std.Io.Dir.cwd().openDir(io, request.export_directory, .{ .iterate = true });
    defer dir.close(io);
    const actual = try jobs.source_digest.treeDigest(gpa, io, dir);
    if (!std.mem.eql(u8, &actual, &request.expected_export_tree)) return error.ExportedSourceChanged;
}
