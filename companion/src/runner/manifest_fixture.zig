//! Explicit offline fixture descriptor; production provenance is not inferred here.
const std = @import("std");
const p = @import("project");
const jobs = @import("companion-jobs");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    var loaded = try p.profiles.create(init.gpa, .eurkey);
    defer loaded.deinit();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[1], init.gpa);
    defer init.gpa.free(executable);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        executable,
        init.gpa,
        .limited(jobs.runner_artifact.max_bytes),
    );
    defer init.gpa.free(bytes);
    const identity = try p.snapshot.identity(init.gpa, loaded.snapshot, p.profiles.board);
    const inputs = jobs.firmware.Inputs{
        .project_digest = try p.snapshot.projectDigest(init.gpa, loaded.snapshot, p.profiles.board),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = loaded.snapshot.document.profile_id,
        .identity_digest = identity.digest,
        .lock = jobs.target_lock.fixture(),
    };
    var manifest = try jobs.runner_artifact.Manifest.complete(
        init.gpa,
        .succeeded,
        jobs.runner_artifact.key(inputs, jobs.runner_artifact.native_target),
        inputs,
        inputs,
        executable,
        bytes,
    );
    defer manifest.deinit();
    const encoded = try manifest.serialize(init.gpa);
    defer init.gpa.free(encoded);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = encoded });
}
