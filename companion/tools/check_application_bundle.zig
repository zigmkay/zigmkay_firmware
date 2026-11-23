//! Build a catalog project through the same bundled context used by the editor.
const std = @import("std");
const desktop = @import("desktop-core");
const project = @import("project");
const catalog = @import("catalog-project");
const jobs = @import("companion-jobs");

/// Representative boards covering every keymap/callback/side/encoder variant
/// for fast PR bundle checks without duplicating identical board families.
const representative_boards = [_][]const u8{
    "lk8",
    "dasbob",
    "molekula",
};

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    // toSlice requires an arena: Windows returns a view into a larger allocation.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.Usage;
    var resources = (if (@import("builtin").os.tag == .windows)
        jobs.application_bundle.Bundle.fromExecutable(a, init.io, args[1], args[2])
    else
        jobs.application_bundle.Bundle.open(a, init.io, args[1])) catch |err| {
        std.log.err("Unable to open application bundle '{s}': {t}", .{ args[1], err });
        return err;
    };
    defer resources.deinit();
    if (std.mem.eql(u8, args[3], "all")) {
        for (@import("catalog-inventory").entries) |entry| try check(
            init,
            resources,
            args[2],
            entry.selector,
        );
        try checkImports(init, resources, args[2], false);
    } else if (std.mem.eql(u8, args[3], "representative")) {
        for (representative_boards) |selector| try check(
            init,
            resources,
            args[2],
            selector,
        );
        try checkImports(init, resources, args[2], true);
    } else if (std.mem.eql(u8, args[3], "imports")) {
        try checkImports(init, resources, args[2], false);
    } else try check(init, resources, args[2], args[3]);
}

fn checkImports(
    init: std.process.Init,
    resources: jobs.application_bundle.Bundle,
    cache: []const u8,
    comptime representative_only: bool,
) !void {
    const importer = desktop.onboarding.importer;
    const a = init.arena.allocator();
    if (resources.executable) |exe| {
        try jobs.bundle_payload.materialize(
            init.gpa,
            init.io,
            exe,
            resources.root,
        );
    }
    var nonce: [16]u8 = undefined;
    init.io.random(&nonce);
    const root_path = try std.fmt.allocPrint(
        a,
        "{s}/import-check-{s}",
        .{ cache, std.fmt.bytesToHex(nonce, .lower) },
    );
    var root = try std.Io.Dir.cwd().createDirPathOpen(init.io, root_path, .{});
    defer root.close(init.io);
    const exe_suffix = if (@import("builtin").os.tag == .windows) ".exe" else "";
    // Share the global Zig cache already populated by firmware builds so
    // `analyze-keymap` does not recompile the Zig standard library cold.
    const shared_global_cache = try std.fs.path.join(a, &.{
        cache,
        "builds",
        "compiler-cache",
        &std.fmt.bytesToHex(resources.manifest.id, .lower),
        "global",
    });
    inline for (.{ "us", "de" }) |name| {
        if (comptime representative_only and !std.mem.eql(u8, name, "us")) continue;
        const source_path = try std.fs.path.join(a, &.{ root_path, name });
        try writeImportFixture(
            init.io,
            source_path,
            @embedFile("import-" ++ name),
            @embedFile("import-" ++ name ++ "-manifest"),
        );
        var captured = try importer.inspect(init.gpa, init.io, source_path, null, root_path);
        defer captured.deinit();
        var analyzed = try importer.analyze(init.gpa, init.io, captured, .{
            .compiler = try resources.path(a, "toolchain/zig" ++ exe_suffix),
            .build_root = try resources.path(a, "build"),
            .packages = try resources.path(a, "dependencies/p"),
            .cache = try std.fs.path.join(a, &.{ cache, "import-tools" }),
            .global_cache = shared_global_cache,
        }, init.environ_map);
        defer analyzed.deinit();
        const selectors: []const []const u8 = if (representative_only)
            &.{"keycaprio_colemak_0_7"}
        else
            &.{ "keycaprio_colemak_0_6", "keycaprio_colemak_0_7" };
        for (selectors) |selector| {
            var prepared = try importer.prepare(
                init.gpa,
                init.io,
                captured,
                analyzed,
                selector,
                "Offline import fixture",
                "fixture1".*,
            );
            defer prepared.deinit();
            const destination = try std.fmt.allocPrint(a, "{s}/{s}-{s}", .{ root_path, name, selector });
            try importer.commit(init.gpa, init.io, prepared, captured, destination);
            var dir = try std.Io.Dir.cwd().openDir(init.io, destination, .{});
            defer dir.close(init.io);
            var reopened = try project.snapshot.load(init.gpa, init.io, dir, prepared.board.board);
            defer reopened.deinit();
            var model = try desktop.model.Model.init(init.gpa, prepared.board.board, reopened.snapshot);
            defer model.deinit();
            const plan = try desktop.application_bundle.plan(
                init.gpa,
                resources,
                cache,
                selector,
                prepared.board.board.id,
            );
            defer project.owned_zon.free(init.gpa, plan);
            var firmware_request = try desktop.build_worker.Request.capture(
                &model,
                plan.config,
                init.environ_map,
                2,
            );
            defer firmware_request.deinit();
            var built = try firmware_request.prepare(init.gpa, init.io);
            defer built.deinit();
            var bundle = try built.takeBundle(&model, .{ .generation = 2, .snapshot = try model.id() });
            defer bundle.deinit();
            std.log.info(
                "Offline bundled import, native tutor and firmware passed: {s} / {s}",
                .{ name, selector },
            );
        }
    }
}

fn writeImportFixture(io: std.Io, path: []const u8, keymap: []const u8, manifest: []const u8) !void {
    var source = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer source.close(io);
    try source.createDirPath(io, "src");
    try source.writeFile(io, .{ .sub_path = "src/keymap.zig", .data = keymap });
    try source.writeFile(io, .{ .sub_path = "build.zig.zon", .data = manifest });
}

fn check(
    init: std.process.Init,
    resources: jobs.application_bundle.Bundle,
    cache: []const u8,
    selector: []const u8,
) !void {
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
