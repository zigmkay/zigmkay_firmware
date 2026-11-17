//! Build integration for pinned local sources. Never downloads friend repositories.
const std = @import("std");
pub const Fixture = struct { selector: []const u8, export_root: std.Build.LazyPath };
pub fn add(b: *std.Build, importer: *std.Build.Module, project: *std.Build.Module, processor: *std.Build.Module, keycodes: *std.Build.Module, model: *std.Build.Module, protocol: *std.Build.Module) []const Fixture {
    const step = b.step("test-import-processors", "Compare imported taps holds combos paired callbacks and compile native runners");
    const tool = b.addExecutable(.{ .name = "import-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tools/import_fixture.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "keymap-importer", .module = importer }, .{ .name = "project", .module = project } } }) });
    tool.root_module.addImport("build-options", importer.import_table.get("test-options").?);
    const result = b.allocator.alloc(Fixture, 4) catch @panic("OOM");
    var index: usize = 0;
    for ([_][]const u8{ "us", "de" }) |name| for ([_][]const u8{ "keycaprio_colemak_0_6", "keycaprio_colemak_0_7" }) |selector| {
        const run = b.addRunArtifact(tool);
        run.addDirectoryArg(b.path(b.fmt("tests/fixtures/import/{s}", .{name})));
        run.addArg(selector);
        const output = run.addOutputDirectoryArg(b.fmt("imported-{s}-{s}", .{ name, selector }));
        const exported = output.path(b, "export");
        result[index] = .{ .selector = selector, .export_root = exported };
        index += 1;
        const profile = module(b, exported, processor, keycodes, model);
        const original = b.createModule(.{ .root_source_file = b.path(b.fmt("tests/fixtures/import/{s}/src/keymap.zig", .{name})), .imports = &.{ .{ .name = "zigmkay", .module = processor }, .{ .name = "zkeycodes", .module = keycodes } } });
        const trace = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/import_processor_contract.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "zigmkay", .module = processor }, .{ .name = "original-profile", .module = original }, .{ .name = "generated-profile", .module = profile } } }) });
        step.dependOn(&b.addRunArtifact(trace).step);
        const runner = @import("../runner/build.zig").runner(b, b.fmt("imported-{s}-{s}-runner", .{ name, selector }), processor, profile, protocol, null);
        step.dependOn(&runner.step);
    };
    return result;
}
pub fn module(b: *std.Build, root: std.Build.LazyPath, processor: *std.Build.Module, keycodes: *std.Build.Module, model: *std.Build.Module) *std.Build.Module {
    const imports: []const std.Build.Module.Import = &.{ .{ .name = "zigmkay", .module = processor }, .{ .name = "zkeycodes", .module = keycodes }, .{ .name = "layout-model", .module = model } };
    const profile = b.createModule(.{ .root_source_file = root.path(b, "keymap.zig"), .imports = imports });
    const callback = b.createModule(.{ .root_source_file = root.path(b, "callback_0/src/keymap.zig"), .imports = imports });
    profile.addImport("callback_0", callback);
    return profile;
}
