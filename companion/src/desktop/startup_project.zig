//! Caller-selected user startup preference, separate from editable project data.
const std = @import("std");
const Preference = struct { version: u8 = 1, project: []const u8 };
const filename = "startup-project.zon";

pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?[]u8 {
    const bytes = dir.readFileAlloc(io, filename, gpa, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    const pref = try @import("project").owned_zon.parse(Preference, gpa, text);
    defer @import("project").owned_zon.free(gpa, pref);
    if (pref.version != 1) return error.UnsupportedStartupPreferenceVersion;
    if (!std.fs.path.isAbsolute(pref.project) or
        pref.project.len >= 1024 or
        std.mem.indexOfScalar(u8, pref.project, 0) != null) return error.InvalidStartupProject;
    return try gpa.dupe(u8, pref.project);
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or
        path.len >= 1024 or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidStartupProject;
    // Never replace unsupported or corrupt saved preferences with defaults.
    const previous = try load(gpa, io, dir);
    defer if (previous) |value| gpa.free(value);
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    try std.zon.stringify.serialize(Preference{ .project = path }, .{}, &writer.writer);
    var file = try dir.createFileAtomic(io, filename, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, writer.written());
    try file.file.sync(io);
    try file.replace(io);
}

test "startup preference survives reopening and invalid updates preserve the previous project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try std.testing.expect(try load(gpa, io, temp.dir) == null);
    const path = try temp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    try save(gpa, io, temp.dir, path);
    try std.testing.expectError(error.InvalidStartupProject, save(gpa, io, temp.dir, "relative"));
    const restored = (try load(gpa, io, temp.dir)).?;
    defer gpa.free(restored);
    try std.testing.expectEqualStrings(path, restored);
}

test "saved personal layout is restored into a fresh editor model through the remembered path" {
    const Model = @import("model.zig").Model;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var project_dir = try temp.dir.createDirPathOpen(io, "personal", .{});
    defer project_dir.close(io);
    const p = @import("project");
    var original_template = try p.profiles.create(gpa, .eurmac);
    defer original_template.deinit();
    var original = try Model.init(gpa, p.profiles.board, original_template.snapshot);
    defer original.deinit();
    try original.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 9 } } });
    try original.save(io, project_dir);
    const path = try project_dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(path);
    try save(gpa, io, temp.dir, path);
    const restored_path = (try load(gpa, io, temp.dir)).?;
    defer gpa.free(restored_path);
    var restored_dir = try std.Io.Dir.cwd().openDir(io, restored_path, .{});
    defer restored_dir.close(io);
    var fresh_template = try p.profiles.create(gpa, .eurkey);
    defer fresh_template.deinit();
    var fresh = try Model.init(gpa, p.profiles.board, fresh_template.snapshot);
    defer fresh.deinit();
    try fresh.open(io, restored_dir);
    try std.testing.expectEqual(try original.id(), try fresh.id());
    try std.testing.expect(!fresh.dirty());
}

test "unsupported startup preferences are preserved byte-exact on save" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const future = ".{ .version = 2, .project = \"/personal/project\" }\n";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = future });
    try std.testing.expectError(
        error.UnsupportedStartupPreferenceVersion,
        save(std.testing.allocator, io, tmp.dir, "/another/project"),
    );
    const actual = try tmp.dir.readFileAlloc(io, filename, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(future, actual);
}
