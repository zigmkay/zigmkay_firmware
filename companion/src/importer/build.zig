//! Build glue for the captured-keymap evaluator. Part of the runtime closure:
//! `runtime/build.zig` and the repository build both use it.
const std = @import("std");

/// Declare `analyze-keymap` with its `-Dimport-root` and `-Dimport-module`
/// options, as the bundled runtime build exposes them.
pub fn add(b: *std.Build, processor: *std.Build.Module, keycodes: *std.Build.Module, model: *std.Build.Module) void {
    const step = b.step("analyze-keymap", "Compile only a captured keymap with the application-owned typed evaluator");
    const root = b.option([]const u8, "import-root", "Absolute captured source directory") orelse return;
    const entry = b.option([]const u8, "import-module", "Selected relative Zig module") orelse "src/keymap.zig";
    step.dependOn(&b.addInstallArtifact(analyzer(b, processor, keycodes, model, root, entry), .{}).step);
}

/// The typed evaluator for the captured module `entry` below the absolute
/// `root`. Panics on an invalid captured path.
pub fn analyzer(b: *std.Build, processor: *std.Build.Module, keycodes: *std.Build.Module, model: *std.Build.Module, root: []const u8, entry: []const u8) *std.Build.Step.Compile {
    if (!std.fs.path.isAbsolute(root) or !@import("../project/portable_path.zig").valid(entry, 512) or !std.mem.endsWith(u8, entry, ".zig")) @panic("Invalid captured module path");
    const selected = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ root, entry }) }, .imports = &.{ .{ .name = "zigmkay", .module = processor }, .{ .name = "zkeycodes", .module = keycodes }, .{ .name = "layout-model", .module = model } } });
    return b.addExecutable(.{ .name = "keymap-analyzer", .root_module = b.createModule(.{ .root_source_file = b.path("src/importer/evaluate.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "selected-keymap", .module = selected }, .{ .name = "layout-model", .module = model }, .{ .name = "zigmkay", .module = processor } } }) });
}
