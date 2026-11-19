//! Offline composition of an accepted build and the managed flash input boundary.
const std = @import("std");
const jobs = @import("companion-jobs");
const controller = @import("flash-controller");

pub const Prepared = struct {
    frozen: jobs.flash_inputs.Frozen,
    artifact: controller.Frozen,

    pub fn deinit(self: *Prepared) void {
        self.frozen.deinit();
        self.* = undefined;
    }
};

/// The returned artifact path borrows the owned Frozen; keep Prepared alive until
/// the controller has received and copied its frozen event.
/// `captured` is the context of the accepted build, while `current_context` is
/// independently obtained from the current model, not reconstructed from it.
/// The caller must also independently capture `current` from the selected
/// project/build inputs and `identity` from the canonical board/profile model;
/// this function cannot establish their provenance from caller-supplied values.
pub fn compose(
    gpa: std.mem.Allocator,
    io: std.Io,
    cache: std.Io.Dir,
    cache_path: []const u8,
    manifest: jobs.firmware.Manifest,
    current: jobs.firmware.Inputs,
    captured: controller.Context,
    current_context: controller.Context,
    board_id: [8]u8,
    identity: controller.Identity,
    tools: jobs.flash_inputs.Tools,
) !Prepared {
    if (!std.mem.eql(u8, &captured.snapshot, &current_context.snapshot)) return error.StaleFlashRequest;
    const build_key = jobs.firmware.key(current);
    if (!std.mem.eql(u8, &captured.build_key, &build_key) or
        !std.mem.eql(u8, &current_context.build_key, &build_key) or
        !std.mem.eql(u8, &manifest.build_key, &build_key)) return error.StaleBuild;
    if (!std.mem.eql(u8, &identity.board_id, &board_id) or
        !std.mem.eql(u8, &identity.profile_id, &current.profile_id) or
        !std.mem.eql(u8, &identity.digest, &current.identity_digest)) return error.IdentityMismatch;
    const freeze_start = std.Io.Clock.awake.now(io);
    defer std.log.info(
        "flash preparation artifact_freeze_ms={d}",
        .{freeze_start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds()},
    );
    var frozen = try jobs.flash_inputs.freeze(gpa, io, cache, cache_path, manifest, current, tools, .{
        .captured = captured.snapshot,
        .current = current_context.snapshot,
    });
    errdefer frozen.deinit();
    return .{ .artifact = .{
        .context = current_context,
        .path = frozen.path,
        .uf2_hash = frozen.uf2_hash,
        .expected_identity = identity,
    }, .frozen = frozen };
}

fn fixtureUf2() [512]u8 {
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
    }) |word| std.mem.writeInt(u32, bytes[word[0]..][0..4], word[1], .little);
    return bytes;
}

test "compose freezes accepted build for controller and rejects independent drift" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const wrapper = try std.fs.path.join(gpa, &.{ base, "wrapper" });
    defer gpa.free(wrapper);
    const picotool = try std.fs.path.join(gpa, &.{ base, "picotool" });
    defer gpa.free(picotool);
    const artifact = try std.fs.path.join(gpa, &.{ base, "build.uf2" });
    defer gpa.free(artifact);
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "wrapper bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "picotool", .data = "picotool bytes" });
    const lock = jobs.target_lock.fixture();
    var tools = try jobs.flash_inputs.Tools.capture(
        gpa,
        io,
        lock.firmware_revision,
        lock.firmware_source_digest,
        lock.source_kind,
        wrapper,
        picotool,
    );
    defer tools.deinit();
    const input: jobs.firmware.Inputs = .{
        .project_digest = @splat(1),
        .source_digest = @splat(2),
        .build_inputs_digest = @splat(3),
        .profile_id = "profile1".*,
        .identity_digest = @splat(4),
        .lock = lock,
    };
    const bytes = fixtureUf2();
    try tmp.dir.writeFile(io, .{ .sub_path = "build.uf2", .data = &bytes });
    var manifest = try jobs.firmware.Manifest.complete(
        gpa,
        .succeeded,
        jobs.firmware.key(input),
        input,
        input,
        artifact,
        &bytes,
    );
    defer manifest.deinit();
    const context: controller.Context = .{ .snapshot = @splat(5), .build_key = jobs.firmware.key(input) };
    const identity: controller.Identity = .{
        .board_id = "board_v1".*,
        .profile_id = input.profile_id,
        .digest = input.identity_digest,
    };
    var prepared = try compose(
        gpa,
        io,
        tmp.dir,
        base,
        manifest,
        input,
        context,
        context,
        identity.board_id,
        identity,
        tools,
    );
    defer prepared.deinit();
    var owner = controller.Controller.init(gpa, context);
    defer owner.deinit();
    _ = try owner.dispatch(.prepare);
    _ = try owner.receive(.{ .prepared = owner.operation_id }, 0);
    _ = try owner.dispatch(.build);
    _ = try owner.receive(.{ .built = .{
        .operation_id = owner.operation_id,
        .build_key = context.build_key,
    } }, 0);
    _ = try owner.dispatch(.freeze);
    _ = try owner.receive(.{ .frozen = .{
        .operation_id = owner.operation_id,
        .artifact = prepared.artifact,
    } }, 0);
    try std.testing.expectEqual(controller.Phase.frozen, owner.phase);
    try std.testing.expectEqualStrings(prepared.frozen.path, owner.artifact.?.path);
    const request: jobs.flash_inputs.Request = .{
        .captured = context.snapshot,
        .current = owner.current.snapshot,
    };
    try prepared.frozen.verify(gpa, io, input, request);
    try std.testing.expectError(
        error.StaleFlashRequest,
        prepared.frozen.verify(gpa, io, input, .{ .captured = context.snapshot, .current = @splat(9) }),
    );
    var stale_context = context;
    stale_context.snapshot[0] ^= 1;
    try std.testing.expectError(
        error.StaleFlashRequest,
        compose(
            gpa,
            io,
            tmp.dir,
            base,
            manifest,
            input,
            context,
            stale_context,
            identity.board_id,
            identity,
            tools,
        ),
    );
    stale_context = context;
    stale_context.build_key[0] ^= 1;
    try std.testing.expectError(
        error.StaleBuild,
        compose(
            gpa,
            io,
            tmp.dir,
            base,
            manifest,
            input,
            context,
            stale_context,
            identity.board_id,
            identity,
            tools,
        ),
    );
    var changed = input;
    changed.source_digest[0] ^= 1;
    try std.testing.expectError(
        error.StaleBuild,
        compose(
            gpa,
            io,
            tmp.dir,
            base,
            manifest,
            changed,
            context,
            context,
            identity.board_id,
            identity,
            tools,
        ),
    );
    try std.testing.expectError(
        error.IdentityMismatch,
        compose(gpa, io, tmp.dir, base, manifest, input, context, context, "board_v2".*, identity, tools),
    );
    var wrong_identity = identity;
    wrong_identity.profile_id[0] ^= 1;
    try std.testing.expectError(
        error.IdentityMismatch,
        compose(
            gpa,
            io,
            tmp.dir,
            base,
            manifest,
            input,
            context,
            context,
            identity.board_id,
            wrong_identity,
            tools,
        ),
    );
    wrong_identity = identity;
    wrong_identity.digest[0] ^= 1;
    try std.testing.expectError(
        error.IdentityMismatch,
        compose(
            gpa,
            io,
            tmp.dir,
            base,
            manifest,
            input,
            context,
            context,
            identity.board_id,
            wrong_identity,
            tools,
        ),
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "tampered" });
    try std.testing.expectError(
        error.WrapperChanged,
        compose(
            gpa,
            io,
            tmp.dir,
            base,
            manifest,
            input,
            context,
            context,
            identity.board_id,
            identity,
            tools,
        ),
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "wrapper", .data = "wrapper bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.uf2", .data = "tampered" });
    try std.testing.expectError(
        error.ArtifactChanged,
        compose(
            gpa,
            io,
            tmp.dir,
            base,
            manifest,
            input,
            context,
            context,
            identity.board_id,
            identity,
            tools,
        ),
    );
    try prepared.frozen.verify(gpa, io, input, request);
    try tmp.dir.writeFile(io, .{
        .sub_path = std.fs.path.basename(prepared.frozen.path),
        .data = "tampered",
    });
    try std.testing.expectError(error.ArtifactChanged, prepared.frozen.verify(gpa, io, input, request));
}
