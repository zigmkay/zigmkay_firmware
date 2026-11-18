const std = @import("std");
const flash = @import("picotool_job.zig");
const options = @import("options");
const t = std.testing;

fn spec(wrapper: []const u8, file: []const u8, hash: [32]u8, serial: []const u8) flash.Spec {
    return .{
        .wrapper = wrapper,
        .picotool = "/unused fake tool",
        .firmware = file,
        .expected_sha256 = hash,
        .snapshot_id = @splat(7),
        .selection = .{ .serial = serial },
        .discovery_ms = 100,
        .command_ms = 100,
    };
}

fn wait(job: *flash.Job) !flash.Result {
    for (0..1000) |_| {
        if (job.poll()) |value| return value;
        try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
    }
    return error.FixtureTimeout;
}

test "invalid paths selection and budgets fail without process execution" {
    var input = spec("/unused wrapper", "relative", @splat(0), "ok");
    try t.expectError(error.AbsolutePathRequired, flash.Job.init(t.allocator, t.io, input));
    input.firmware = "/absolute";
    input.selection = .{ .bus_address = .{ .bus = 1, .address = 0 } };
    try t.expectError(error.InvalidSelection, flash.Job.init(t.allocator, t.io, input));
    input.selection = .{ .serial = "ok" };
    input.firmware = "/contains\x00nul";
    try t.expectError(error.InvalidPath, flash.Job.init(t.allocator, t.io, input));
    input.firmware = "/absolute";
    input.selection = .{ .serial = "contains\x00nul" };
    try t.expectError(error.InvalidSelection, flash.Job.init(t.allocator, t.io, input));
    input.selection = .{ .serial = "ok" };
    input.command_ms = 0;
    try t.expectError(error.InvalidBudget, flash.Job.init(t.allocator, t.io, input));
}

test "frozen digest literal arguments bounded output freshness and controlled cancellation" {
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.fixture, t.allocator);
    defer t.allocator.free(fixture);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "artifact ; $.uf2", .data = "offline fixture" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "artifact ; $.uf2", t.allocator);
    defer t.allocator.free(path);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("offline fixture", &hash, .{});
    var bad = try flash.Job.init(t.allocator, t.io, spec(fixture, path, @splat(0), "ok"));
    defer bad.deinit();
    try t.expectError(error.HashMismatch, bad.start());
    var job = try flash.Job.init(t.allocator, t.io, spec(fixture, path, hash, "literal ; $(nothing)"));
    defer job.deinit();
    try job.start();
    var result = try wait(&job);
    defer result.deinit(t.allocator);
    try t.expect(result.successful());
    try t.expect(result.fresh(@splat(7)));
    try t.expect(!result.fresh(@splat(8)));
    const expected = try std.fmt.allocPrint(
        t.allocator,
        "/unused fake tool\n{s}\n--sha256\n{s}\n--discovery-ms\n100\n--command-ms\n100\n--cancel-stdin\n--serial\nliteral ; $(nothing)\n",
        .{ path, std.fmt.bytesToHex(hash, .lower) },
    );
    defer t.allocator.free(expected);
    try t.expectEqualStrings(expected, result.process.stdout);
    var selected = spec(fixture, path, hash, "unused");
    selected.selection = .{ .bus_address = .{ .bus = 255, .address = 127 } };
    var bus_job = try flash.Job.init(t.allocator, t.io, selected);
    defer bus_job.deinit();
    try bus_job.start();
    var bus_result = try wait(&bus_job);
    defer bus_result.deinit(t.allocator);
    try t.expect(bus_result.successful());
    try t.expect(std.mem.endsWith(u8, bus_result.process.stdout, "--bus\n255\n--address\n127\n"));
    var flood = try flash.Job.init(t.allocator, t.io, spec(fixture, path, hash, "flood"));
    defer flood.deinit();
    try flood.start();
    var flooded = try wait(&flood);
    defer flooded.deinit(t.allocator);
    try t.expect(flooded.successful());
    try t.expect(flooded.diagnostics_truncated);
    try t.expectEqual(flash.output_limit, flooded.process.stdout.len);
    try t.expectEqual(flash.output_limit, flooded.process.stderr.len);
    var cancelled = try flash.Job.init(t.allocator, t.io, spec(fixture, path, hash, "wait"));
    defer cancelled.deinit();
    try cancelled.start();
    cancelled.requestCancel();
    var stopped = try wait(&cancelled);
    defer stopped.deinit(t.allocator);
    try t.expect(stopped.cancelled);
    try t.expect(!stopped.successful());
    try t.expectEqualStrings("controlled-exit\n", stopped.process.stderr);
    var timeout = try flash.Job.init(t.allocator, t.io, spec(fixture, path, hash, "wait"));
    defer timeout.deinit();
    try timeout.start();
    var expired = try wait(&timeout);
    defer expired.deinit(t.allocator);
    try t.expect(expired.timed_out);
    try t.expect(!expired.successful());
    try t.expectEqualStrings("controlled-exit\n", expired.process.stderr);
}

test "wrapper controlled cancellation reaps its direct fake picotool child" {
    if (!@hasDecl(options, "wrapper") or
        !@hasDecl(options, "picotool_fixture") or
        @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const wrapper = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.wrapper, t.allocator);
    defer t.allocator.free(wrapper);
    const picotool = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.picotool_fixture, t.allocator);
    defer t.allocator.free(picotool);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var block: [512]u8 = @splat(0);
    const offsets = [_]usize{ 0, 4, 8, 12, 16, 20, 24, 28, 508 };
    const values = [_]u32{ 0x0a324655, 0x9e5d5157, 0x2000, 0x10000000, 256, 0, 1, 0xe48bff56, 0x0ab16f30 };
    for (offsets, values) |offset, value| std.mem.writeInt(u32, block[offset..][0..4], value, .little);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "firmware.uf2", .data = &block });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const artifact = try std.fs.path.join(t.allocator, &.{ root, "firmware.uf2" });
    defer t.allocator.free(artifact);
    const pidfile = try std.fs.path.join(t.allocator, &.{ root, "child.pid" });
    defer t.allocator.free(pidfile);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&block, &hash, .{});
    for ([_][]const u8{ "ok", "bad-load", "bad-reboot", "absent", "failure", "ambiguous", "hang" }) |mode| {
        var input = spec(wrapper, artifact, hash, mode);
        input.picotool = picotool;
        input.discovery_ms = 1000;
        input.command_ms = 2000;
        var job = try flash.Job.init(t.allocator, t.io, input);
        defer job.deinit();
        try job.start();
        var result = try wait(&job);
        defer result.deinit(t.allocator);
        if (std.mem.eql(u8, mode, "ok") and !result.successful()) {
            std.debug.print(
                "wrapper success fixture failed: term={any} cancelled={any} timeout={any} stderr={s}\n",
                .{ result.process.term, result.cancelled, result.timed_out, result.process.stderr },
            );
        }
        try t.expectEqual(std.mem.eql(u8, mode, "ok"), result.successful());
        if (result.successful()) {
            try t.expect(
                std.mem.indexOf(u8, result.process.stderr, "reboot-complete") != null,
            );
        }
    }
    for ([_][]const u8{ "hang", "hang-load" }) |mode| {
        const serial = try std.fmt.allocPrint(t.allocator, "{s}|{s}", .{ mode, pidfile });
        defer t.allocator.free(serial);
        var input = spec(wrapper, artifact, hash, serial);
        input.picotool = picotool;
        input.discovery_ms = 10000;
        input.command_ms = 10000;
        var job = try flash.Job.init(t.allocator, t.io, input);
        defer job.deinit();
        try job.start();
        var pid: ?std.posix.pid_t = null;
        for (0..300) |_| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(
                t.io,
                pidfile,
                t.allocator,
                .limited(32),
            ) catch |err| {
                if (err != error.FileNotFound) return err;
                try std.Io.sleep(t.io, .fromMilliseconds(10), .awake);
                continue;
            };
            defer t.allocator.free(bytes);
            if (bytes.len != 0) {
                pid = try std.fmt.parseInt(std.posix.pid_t, bytes, 10);
                break;
            }
        }
        try t.expect(pid != null);
        job.requestCancel();
        var result = try wait(&job);
        defer result.deinit(t.allocator);
        try t.expect(result.cancelled);
        try t.expect(!result.successful());
        try t.expectError(error.ProcessNotFound, std.posix.kill(pid.?, @fromBackingInt(@intCast(0))));
        try std.Io.Dir.cwd().deleteFile(t.io, pidfile);
    }
}

test "managed dispatch revalidates owned tools and frozen bytes before starting" {
    const managed = @import("managed_flash.zig");
    const inputs = @import("flash_inputs.zig");
    const firmware = @import("firmware.zig");
    const target = @import("target_lock.zig");
    const fixture = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.fixture, t.allocator);
    defer t.allocator.free(fixture);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const picotool = try std.fs.path.join(t.allocator, &.{ base, "tool" });
    defer t.allocator.free(picotool);
    const artifact = try std.fs.path.join(t.allocator, &.{ base, "build.uf2" });
    defer t.allocator.free(artifact);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tool", .data = "offline tool bytes" });
    const lock = target.fixture();
    var tools = try inputs.Tools.capture(
        t.allocator,
        t.io,
        lock.firmware_revision,
        lock.firmware_source_digest,
        lock.source_kind,
        fixture,
        picotool,
    );
    defer tools.deinit();
    const current: firmware.Inputs = .{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = @splat(4),
        .identity_digest = @splat(5),
        .lock = lock,
    };
    var block: [512]u8 = @splat(0);
    for ([_]struct { usize, u32 }{
        .{ 0, 0x0a324655 },
        .{ 4, 0x9e5d5157 },
        .{ 8, 0x2000 },
        .{ 12, 0x10000000 },
        .{ 16, 256 },
        .{ 24, 1 },
        .{ 28, 0xe48bff56 },
        .{ 508, 0x0ab16f30 },
    }) |word| std.mem.writeInt(u32, block[word[0]..][0..4], word[1], .little);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build.uf2", .data = &block });
    var manifest = try firmware.Manifest.complete(
        t.allocator,
        .succeeded,
        firmware.key(current),
        current,
        current,
        artifact,
        &block,
    );
    defer manifest.deinit();
    const request: inputs.Request = .{ .captured = @splat(1), .current = @splat(1) };
    var frozen = try inputs.freeze(t.allocator, t.io, tmp.dir, base, manifest, current, tools, request);
    defer frozen.deinit();
    var job = try managed.Job.init(t.allocator, t.io, frozen, request, .{ .serial = "ok" });
    defer job.deinit();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tool", .data = "edited tool bytes" });
    try t.expectError(error.PicotoolChanged, job.start(current, request));
    try t.expect(!job.process.started);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tool", .data = "offline tool bytes" });
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = frozen.path, .data = "edited frozen bytes" });
    try t.expectError(error.ArtifactChanged, job.start(current, request));
    try t.expect(!job.process.started);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = frozen.path, .data = &block });
    try t.expectError(
        error.StaleFlashRequest,
        job.start(current, .{ .captured = @splat(1), .current = @splat(2) }),
    );
    try t.expect(!job.process.started);
    try job.start(current, request);
    var result = try wait(&job.process);
    defer result.deinit(t.allocator);
    try t.expect(result.successful());
}
