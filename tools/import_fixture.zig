//! Converts pinned local fixtures through production capture/analyze/prepare/commit.
const std = @import("std");
const importer = @import("keymap-importer");
const p = @import("project");
const options = @import("build-options");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) return error.Usage;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", a);
    const output = try std.fs.path.resolve(a, &.{ cwd, args[3] });
    const source = try std.fs.path.resolve(a, &.{ cwd, args[1] });
    const cache = try std.fs.path.join(a, &.{ output, "cache" });
    var captured = try importer.inspect(init.gpa, init.io, source, "src/keymap.zig", cache);
    defer captured.deinit();
    var analyzed = try importer.analyze(init.gpa, init.io, captured, .{ .compiler = options.compiler, .build_root = options.repository, .cache = cache, .packages = options.packages, .global_cache = options.compiler_cache }, init.environ_map);
    defer analyzed.deinit();
    var prepared = try importer.prepare(init.gpa, init.io, captured, analyzed, args[2], "Pinned imported profile", "fixture1".*);
    defer prepared.deinit();
    const destination = try std.fs.path.join(a, &.{ output, "project" });
    try importer.commit(init.gpa, init.io, prepared, captured, destination);
    var project_dir = try std.Io.Dir.cwd().openDir(init.io, destination, .{});
    defer project_dir.close(init.io);
    var loaded = try p.snapshot.load(init.gpa, init.io, project_dir, prepared.board.board);
    defer loaded.deinit();
    var export_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, try std.fs.path.join(a, &.{ output, "export" }), .{});
    defer export_dir.close(init.io);
    const manifest = try p.exporter.write(init.gpa, init.io, export_dir, loaded.snapshot, prepared.board.board);
    defer p.exporter.freeManifest(init.gpa, manifest);
}
