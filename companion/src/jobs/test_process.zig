const std = @import("std");
const jobs = @import("companion-jobs");

test "asynchronous jobs own explicit environment before caller mutation" {
    const gpa = std.testing.allocator;
    var environment = std.process.Environ.Map.init(gpa);
    defer environment.deinit();
    try environment.put("ZIGMKAY_JOB_FIXTURE", "captured");
    var job = try jobs.Job.init(gpa, std.testing.io, .{
        .argv = &.{ @import("options").helper_path, "environment" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .environ_map = &environment,
    });
    defer job.deinit();
    try environment.put("ZIGMKAY_JOB_FIXTURE", "changed");
    var result = try jobs.run(gpa, std.testing.io, job.spec);
    defer result.deinit(gpa);
    try std.testing.expect(result.successful());
    try std.testing.expectEqualStrings("captured", result.process.stdout);
}

test "direct argv preserves literal arguments and snapshot freshness" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const exe = @import("options").helper_path;
    const spec = jobs.Spec{
        .argv = &.{ exe, "literal;$(not-a-shell)" },
        .cwd = ".",
        .snapshot_id = @splat(1),
        .timeout_ms = 1000,
    };
    var result = try jobs.run(gpa, io, spec);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("literal;$(not-a-shell)", result.process.stdout);
    try std.testing.expect(result.successful());
    try std.testing.expect(!result.fresh(@splat(2)));
}

test "crashed subprocess returns unsuccessful status" {
    const gpa = std.testing.allocator;
    var crashed = try jobs.run(gpa, std.testing.io, .{
        .argv = &.{ @import("options").helper_path, "crash" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .timeout_ms = 1000,
    });
    defer crashed.deinit(gpa);
    try std.testing.expect(!crashed.successful());
}

test "output limit terminates a flooding subprocess" {
    try std.testing.expectError(error.StreamTooLong, jobs.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ @import("options").helper_path, "flood" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .timeout_ms = 1000,
    }));
}

test "timeout terminates a silent subprocess" {
    try std.testing.expectError(error.Timeout, jobs.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ @import("options").helper_path, "hang" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .timeout_ms = 50,
    }));
}

test "explicit cancellation joins a running job and prevents restart" {
    const io = std.testing.io;
    var job = try jobs.Job.init(std.testing.allocator, io, .{
        .argv = &.{ @import("options").helper_path, "hang" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .timeout_ms = 10000,
    });
    defer job.deinit();
    try job.start();
    try std.Io.sleep(io, .fromMilliseconds(30), .awake);
    try std.testing.expect(job.poll() == null);
    job.cancel();
    try std.testing.expect(job.future == null);
    try std.testing.expectError(error.JobAlreadyStarted, job.start());
}

test "timeout cleanup joins pending reads after both streams produce output" {
    for (0..4) |_| try std.testing.expectError(error.Timeout, jobs.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ @import("options").helper_path, "output-hang" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .timeout_ms = 200,
    }));
}

test "completed jobs transfer result ownership once and cannot restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var argument = [_]u8{ 'o', 'w', 'n', 'e', 'd' };
    var job = try jobs.Job.init(gpa, io, .{
        .argv = &.{ @import("options").helper_path, &argument },
        .cwd = ".",
        .snapshot_id = @splat(9),
    });
    defer job.deinit();
    argument[0] = 'x';
    try job.start();
    try std.testing.expectError(error.JobAlreadyStarted, job.start());
    const start = std.Io.Clock.awake.now(io);
    var result = while (true) {
        if (job.poll()) |completion| break try completion;
        if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds > 5 * std.time.ns_per_s)
            return error.TestJobDidNotComplete;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    };
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("owned", result.process.stdout);
    try std.testing.expect(result.fresh(@splat(9)));
    try std.testing.expect(job.poll() == null);
    try std.testing.expectError(error.JobAlreadyStarted, job.start());
}

test "watchdog covers children that close both output pipes before hanging" {
    try std.testing.expectError(error.Timeout, jobs.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ @import("options").helper_path, "closed-hang" },
        .cwd = ".",
        .snapshot_id = @splat(0),
        .timeout_ms = 50,
    }));
}

test "runner session exchanges bounded literal frames and rejects multiline input" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session = try gpa.create(jobs.Session);
    defer gpa.destroy(session);
    session.* = .{};
    defer session.stop(io);
    try session.start(io, &.{ @import("options").helper_path, "echo" });
    const reply = try session.request(gpa, io, "literal;$(not-a-shell)", 1000);
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("literal;$(not-a-shell)", reply);
    const maximum: [4096]u8 = @splat('x');
    const maximum_reply = try session.request(gpa, io, &maximum, 1000);
    defer gpa.free(maximum_reply);
    try std.testing.expectEqualSlices(u8, &maximum, maximum_reply);
    try std.testing.expectError(error.InvalidInputFrame, session.request(gpa, io, "one\ntwo", 1000));
    try std.testing.expect(session.child == null);
}

test "hung runner session timeout terminates the child and clears session state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const session = try gpa.create(jobs.Session);
    defer gpa.destroy(session);
    session.* = .{};
    defer session.stop(io);
    try session.start(io, &.{ @import("options").helper_path, "hang" });
    try std.testing.expectError(error.Timeout, session.request(gpa, io, null, 30));
    try std.testing.expect(session.child == null);
}

test "artifact freshness includes compiler target optimization and dependency inputs" {
    var input = jobs.ArtifactInput{
        .snapshot_id = @splat(1),
        .build_inputs_digest = @splat(2),
        .zig_version = "0.17.0",
        .target = "native",
        .optimize = "Debug",
    };
    const original = jobs.artifactKey(input);
    input.zig_version = "future";
    try std.testing.expect(!std.mem.eql(u8, &original, &jobs.artifactKey(input)));
    input.zig_version = "0.17.0";
    input.target = "thumb-freestanding-eabi";
    try std.testing.expect(!std.mem.eql(u8, &original, &jobs.artifactKey(input)));
    input.target = "native";
    input.optimize = "ReleaseSafe";
    try std.testing.expect(!std.mem.eql(u8, &original, &jobs.artifactKey(input)));
    input.optimize = "Debug";
    input.build_inputs_digest = @splat(3);
    try std.testing.expect(!std.mem.eql(u8, &original, &jobs.artifactKey(input)));
}
