const std = @import("std");

pub fn runner(b: *std.Build, name: []const u8, firmware: *std.Build.Module, profile: *std.Build.Module, protocol: *std.Build.Module, snapshot_id: ?[32]u8) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([32]u8, "snapshot_id", snapshot_id orelse @splat(0));
    options.addOption(bool, "verify_snapshot", snapshot_id != null);
    const module = b.createModule(.{
        .root_source_file = b.path("src/runner/main.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "zigmkay", .module = firmware }, .{ .name = "selected-profile", .module = profile }, .{ .name = "runner-protocol", .module = protocol } },
    });
    module.addOptions("snapshot-options", options);
    return b.addExecutable(.{ .name = name, .root_module = module });
}

/// The native processor runner of the frozen project export at the absolute
/// `export_path`, verified against its manifest. Part of the runtime closure.
pub fn projectRunner(b: *std.Build, export_path: []const u8, processor: *std.Build.Module, keycodes: *std.Build.Module, layout: *std.Build.Module, protocol: *std.Build.Module) *std.Build.Step.Compile {
    const selected = @import("../project/build_input.zig").load(b, export_path, processor, keycodes, layout) catch |err|
        std.debug.panic("Cannot verify native export: {t}", .{err});
    return runner(b, "project-runner", processor, selected.module, protocol, selected.snapshot_id);
}
