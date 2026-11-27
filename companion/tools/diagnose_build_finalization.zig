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
    std.log.info("diagnostic: saving lock", .{});
    try jobs.sidecar.saveLock(a, io, output, lock, .create);
    std.log.info("diagnostic: saving receipt", .{});
    try jobs.sidecar.saveReceipt(a, io, output, .{
        .bundle_id = @splat(6),
        .lock_digest = lock.digest(),
    }, .create);
    std.log.info("diagnostic: saving firmware sidecar", .{});
    try jobs.sidecar.saveManifest(a, io, output, firmware, .create);
    std.log.info("diagnostic: publication complete; entering cleanup", .{});
}
