//! Explicit offline catalog export (synthetic, or actual with --default).
//! Output must be an owned cache directory;
//! the existing exporter preserves differing files and writes the manifest last.
const std = @import("std");
const adapter = @import("catalog-project");
const project = @import("project");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 and args.len != 4) return error.Usage;
    const use_default = args.len == 4 and std.mem.eql(u8, args[3], "--default");
    if (args.len == 4 and !use_default) return error.Usage;
    var board = try adapter.OwnedBoard.init(gpa, args[1]);
    defer board.deinit();
    var fixture = if (use_default) try adapter.createDefault(gpa, board) else try adapter.createSynthetic(gpa, board);
    defer fixture.deinit();
    try std.Io.Dir.cwd().createDirPath(init.io, args[2]);
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
    defer dir.close(init.io);
    const manifest = try project.exporter.write(gpa, init.io, dir, fixture.snapshot, board.board);
    defer project.exporter.freeManifest(gpa, manifest);
}
