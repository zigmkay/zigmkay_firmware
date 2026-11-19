const std = @import("std");
const p = @import("keymap-project");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.Usage;
    if (std.mem.eql(u8, args[1], "create")) {
        if (args.len != 4) return error.Usage;
        const profile = std.meta.stringToEnum(p.profiles.Profile, args[2]) orelse return error.UnknownProfile;
        var project = try p.profiles.create(gpa, profile);
        defer project.deinit();
        try std.Io.Dir.cwd().createDirPath(io, args[3]);
        var dir = try std.Io.Dir.cwd().openDir(io, args[3], .{});
        defer dir.close(io);
        if (dir.access(io, "project.zon", .{})) |_| return error.ProjectAlreadyExists else |err| if (err != error.FileNotFound) return err;
        try p.snapshot.save(gpa, io, dir, project.snapshot, p.profiles.board);
        return;
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[2], .{});
    defer dir.close(io);
    var project = try p.snapshot.load(gpa, io, dir, p.profiles.board);
    defer project.deinit();
    // Loading validates schema and source hashes. Export checks callback ABI
    // and import closure separately, so old source remains inspectable.
    if (std.mem.eql(u8, args[1], "export")) {
        if (args.len != 4) return error.Usage;
        try std.Io.Dir.cwd().createDirPath(io, args[3]);
        var target = try std.Io.Dir.cwd().openDir(io, args[3], .{});
        defer target.close(io);
        const manifest = try p.exporter.write(gpa, io, target, project.snapshot, p.profiles.board);
        p.exporter.freeManifest(gpa, manifest);
    } else if (!std.mem.eql(u8, args[1], "validate")) return error.Usage;
    const identity = try p.snapshot.identity(gpa, project.snapshot, p.profiles.board);
    std.debug.print("Validated LK7 profile: {s}; identity {s}\n", .{
        project.snapshot.document.name,
        std.fmt.bytesToHex(identity.digest, .lower),
    });
}
