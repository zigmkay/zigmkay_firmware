//! Build a catalog project through the same bundled context used by the editor.
const std = @import("std");
const desktop = @import("desktop-core");
const project = @import("project");
const catalog = @import("catalog-project");
const jobs = @import("companion-jobs");
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    // toSlice requires an arena: Windows returns a view into a larger allocation.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.Usage;
    var resources = if (@import("builtin").os.tag == .windows)
        try jobs.application_bundle.Bundle.fromExecutable(a, init.io, args[1], args[2])
    else
        try jobs.application_bundle.Bundle.open(a, init.io, args[1]);
    defer resources.deinit();
    if (std.mem.eql(u8, args[3], "all")) {
        for (@import("catalog-inventory").entries) |entry| try check(init, resources, args[2], entry.selector);
        try checkImports(init, resources, args[2]);
    } else if (std.mem.eql(u8, args[3], "imports")) {
        try checkImports(init, resources, args[2]);
    } else try check(init, resources, args[2], args[3]);
}
fn checkImports(init: std.process.Init, resources: jobs.application_bundle.Bundle, cache: []const u8) !void {
    const importer = desktop.onboarding.importer;
    const a = init.arena.allocator();
    if (resources.executable) |exe| try jobs.bundle_payload.materialize(init.gpa, init.io, exe, resources.root);
    var nonce: [16]u8 = undefined;
    init.io.random(&nonce);
    const root_path = try std.fmt.allocPrint(a, "{s}/import-check-{s}", .{ cache, std.fmt.bytesToHex(nonce, .lower) });
    var root = try std.Io.Dir.cwd().createDirPathOpen(init.io, root_path, .{});
    defer root.close(init.io);
    inline for (.{ "us", "de" }) |name| {
        const source_path = try std.fs.path.join(a, &.{ root_path, name });
        var source = try std.Io.Dir.cwd().createDirPathOpen(init.io, source_path, .{});
        defer source.close(init.io);
        try source.createDirPath(init.io, "src");
        try source.writeFile(init.io, .{ .sub_path = "src/keymap.zig", .data = @embedFile("import-" ++ name) });
        try source.writeFile(init.io, .{ .sub_path = "build.zig.zon", .data = @embedFile("import-" ++ name ++ "-manifest") });
        var captured = try importer.inspect(init.gpa, init.io, source_path, null, root_path);
        defer captured.deinit();
        var analyzed = try importer.analyze(init.gpa, init.io, captured, .{ .compiler = try resources.path(a, "toolchain/zig" ++ if (@import("builtin").os.tag == .windows) ".exe" else ""), .build_root = try resources.path(a, "build"), .packages = try resources.path(a, "dependencies/p"), .cache = try std.fs.path.join(a, &.{ cache, "import-tools" }) }, init.environ_map);
        defer analyzed.deinit();
        for ([_][]const u8{ "keycaprio_colemak_0_6", "keycaprio_colemak_0_7" }) |selector| {
            var prepared = try importer.prepare(init.gpa, init.io, captured, analyzed, selector, "Offline import fixture", "fixture1".*);
            defer prepared.deinit();
            const destination = try std.fmt.allocPrint(a, "{s}/{s}-{s}", .{ root_path, name, selector });
            try importer.commit(init.gpa, init.io, prepared, captured, destination);
            var dir = try std.Io.Dir.cwd().openDir(init.io, destination, .{});
            defer dir.close(init.io);
            var reopened = try project.snapshot.load(init.gpa, init.io, dir, prepared.board.board);
            defer reopened.deinit();
            var model = try desktop.model.Model.init(init.gpa, prepared.board.board, reopened.snapshot);
            defer model.deinit();
            const plan = try desktop.application_bundle.plan(init.gpa, resources, cache, selector, prepared.board.board.id);
            defer project.owned_zon.free(init.gpa, plan);
            var config = plan.config;
            config.request.native_only = true;
            var runner_request = try desktop.build_worker.Request.capture(&model, config, init.environ_map, 1);
            defer runner_request.deinit();
            var native = try runner_request.prepare(init.gpa, init.io);
            defer native.deinit();
            if (native.manifest != null) return error.NativeTutorBuiltFirmware;
            const runner = native.runner orelse return error.RunnerArtifactNotPrepared;
            var tutor = desktop.practice_controller.Controller.init(try model.id());
            _ = try tutor.choose(.{ .source = .draft }, 0);
            var runtime = desktop.runner_runtime.Runtime.init(init.gpa, init.io, 1, true);
            defer runtime.deinit();
            try runtime.apply(&tutor, try tutor.start(true, try model.id(), 0), runner, &model, 0);
            runtime.router.focused = true;
            runtime.router.owns_practice_input = true;
            for (0..5000) |tick| {
                try runtime.poll(&tutor, &model, tick * 1000);
                if (runtime.router.runner_running) break;
                try std.Io.sleep(init.io, .fromMilliseconds(1), .awake);
            }
            if (!runtime.router.runner_running) return error.ImportedTutorDidNotStart;
            _ = try runtime.route(&tutor, &model, .{ .key = .{ .window = 1, .scancode = 20, .down = true } }, 6_000_000);
            _ = try runtime.route(&tutor, &model, .{ .key = .{ .window = 1, .scancode = 20, .down = false } }, 6_001_000);
            for (0..5000) |tick| {
                try runtime.poll(&tutor, &model, 6_002_000 + tick * 1000);
                if (tutor.session.attempts != 0) break;
                try std.Io.sleep(init.io, .fromMilliseconds(1), .awake);
            }
            if (tutor.session.attempts == 0) return error.ImportedTutorDidNotReceiveText;
            try runtime.apply(&tutor, tutor.pause(12_000_000), runner, &model, 12_000_000);
            var firmware_request = try desktop.build_worker.Request.capture(&model, plan.config, init.environ_map, 2);
            defer firmware_request.deinit();
            var built = try firmware_request.prepare(init.gpa, init.io);
            defer built.deinit();
            var bundle = try built.takeBundle(&model, .{ .generation = 2, .snapshot = try model.id() });
            defer bundle.deinit();
            std.log.info("Offline bundled import, native tutor and firmware passed: {s} / {s}", .{ name, selector });
        }
    }
}
fn check(init: std.process.Init, resources: jobs.application_bundle.Bundle, cache: []const u8, selector: []const u8) !void {
    std.log.info("Offline bundle build starting: {s}", .{selector});
    const a = init.gpa;
    var board = try catalog.OwnedBoard.init(a, selector);
    defer board.deinit();
    var source = try catalog.createDefault(a, board);
    defer source.deinit();
    var model = try desktop.model.Model.init(a, board.board, source.snapshot);
    defer model.deinit();
    const plan = try desktop.application_bundle.plan(a, resources, cache, selector, board.board.id);
    defer project.owned_zon.free(a, plan);
    var request = try desktop.build_worker.Request.capture(&model, plan.config, init.environ_map, 1);
    defer request.deinit();
    var candidate = try request.prepare(a, init.io);
    defer candidate.deinit();
    var result = try candidate.takeBundle(&model, .{ .generation = 1, .snapshot = request.captured });
    defer result.deinit();
    try result.runner.verifyFile(a, init.io, result.firmware.inputs);
    std.log.info("Offline bundle build passed: {s}", .{selector});
}
