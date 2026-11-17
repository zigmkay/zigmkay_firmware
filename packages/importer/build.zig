const std = @import("std");
pub fn add(b: *std.Build, processor: *std.Build.Module, keycodes: *std.Build.Module, model: *std.Build.Module) void {
    const step = b.step("analyze-keymap", "Compile only a captured keymap with the application-owned typed evaluator");
    const root = b.option([]const u8, "import-root", "Absolute captured source directory") orelse return;
    const entry = b.option([]const u8, "import-module", "Selected relative Zig module") orelse "src/keymap.zig";
    if (!std.fs.path.isAbsolute(root) or !@import("../project/src/portable_path.zig").valid(entry, 512) or !std.mem.endsWith(u8, entry, ".zig")) @panic("Invalid captured module path");
    const selected = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ root, entry }) }, .imports = &.{ .{ .name = "zigmkay", .module = processor }, .{ .name = "zkeycodes", .module = keycodes }, .{ .name = "layout-model", .module = model } } });
    const evaluator = b.addExecutable(.{ .name = "keymap-analyzer", .root_module = b.createModule(.{ .root_source_file = b.path("packages/importer/src/evaluate.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "selected-keymap", .module = selected }, .{ .name = "layout-model", .module = model }, .{ .name = "zigmkay", .module = processor } } }) });
    step.dependOn(&b.addInstallArtifact(evaluator, .{}).step);
}
