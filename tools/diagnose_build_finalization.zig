//! Offline reproduction of post-build artifact publication. No compiler or devices.
const std = @import("std");
const jobs = @import("companion-jobs");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedOutputDirectory;
    var output = try std.Io.Dir.cwd().createDirPathOpen(io, args[1], .{});
    defer output.close(io);
    var lock = jobs.target_lock.fixture();
    lock.source_kind = .published;
    const inputs: jobs.firmware.Inputs = .{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = @splat(4),
        .identity_digest = @splat(5),
        .lock = lock,
    };
    var bytes: [512]u8 = @splat(0);
    for ([_]struct { usize, u32 }{
        .{ 0, 0x0a324655 },
        .{ 4, 0x9e5d5157 },
        .{ 8, 0x2000 },
        .{ 12, 0x10000000 },
        .{ 16, 256 },
        .{ 24, 1 },
        .{ 28, 0xe48bff56 },
        .{ 508, 0x0ab16f30 },
    }) |entry|
        std.mem.writeInt(u32, bytes[entry[0]..][0..4], entry[1], .little);
    try output.writeFile(io, .{ .sub_path = "project.uf2", .data = &bytes });
    const firmware_path = try output.realPathFileAlloc(io, "project.uf2", a);
    defer a.free(firmware_path);
    const executable = try std.process.executablePathAlloc(io, a);
    defer a.free(executable);
    const runner_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        executable,
        a,
        .limited(jobs.runner_artifact.max_bytes),
    );
    defer a.free(runner_bytes);
    std.log.info("diagnostic: creating firmware manifest", .{});
    var firmware = try jobs.firmware.Manifest.complete(
        a,
        .succeeded,
        jobs.firmware.key(inputs),
        inputs,
        inputs,
        firmware_path,
        &bytes,
    );
    defer {
        std.log.info("diagnostic: freeing firmware manifest", .{});
        firmware.deinit();
    }
    std.log.info("diagnostic: creating runner manifest", .{});
    var runner = try jobs.runner_artifact.Manifest.complete(
        a,
        .succeeded,
        jobs.runner_artifact.key(inputs, jobs.runner_artifact.native_target),
        inputs,
        inputs,
        executable,
        runner_bytes,
    );
    defer {
        std.log.info("diagnostic: freeing runner manifest", .{});
        runner.deinit();
    }
    std.log.info("diagnostic: saving lock", .{});
    try jobs.sidecar.saveLock(a, io, output, lock, .create);
    std.log.info("diagnostic: saving receipt", .{});
    try jobs.sidecar.saveReceipt(a, io, output, .{
        .bundle_id = @splat(6),
        .lock_digest = lock.digest(),
    }, .create);
    std.log.info("diagnostic: freezing runner", .{});
    var cache = try output.createDirPathOpen(io, "runners", .{});
    defer cache.close(io);
    var frozen = try jobs.runner_artifact.freeze(a, io, cache, runner, inputs);
    defer {
        std.log.info("diagnostic: freeing frozen runner", .{});
        frozen.deinit();
    }
    std.log.info("diagnostic: saving runner sidecar", .{});
    try jobs.sidecar.saveRunner(a, io, output, frozen, .create);
    std.log.info("diagnostic: saving firmware sidecar", .{});
    try jobs.sidecar.saveManifest(a, io, output, firmware, .create);
    std.log.info("diagnostic: verifying frozen runner", .{});
    try frozen.verifyFile(a, io, inputs);
    std.log.info("diagnostic: checking read-only attributes and cache reuse", .{});
    if (@import("builtin").os.tag == .windows) {
        // Zig 0.17's Windows stat reports .default_file permissions rather
        // than the queried attributes. Check the native information directly.
        const windows = std.os.windows;
        const file = try std.Io.Dir.cwd().openFile(io, frozen.record.path, .{});
        defer file.close(io);
        var information: windows.FILE.BASIC_INFORMATION = undefined;
        var status_block: windows.IO_STATUS_BLOCK = undefined;
        const status = windows.ntdll.NtQueryInformationFile(
            file.handle,
            &status_block,
            &information,
            @sizeOf(@TypeOf(information)),
            .Basic,
        );
        if (status != .SUCCESS) return windows.unexpectedStatus(status);
        if (!information.FileAttributes.READONLY) return error.RunnerNotReadOnly;
    }
    var reused = try jobs.runner_artifact.freeze(a, io, cache, runner, inputs);
    defer reused.deinit();
    try reused.verifyFile(a, io, inputs);
    std.log.info("diagnostic: publication complete; entering cleanup", .{});
}
