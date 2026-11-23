//! Offline test wiring for `check`, `test`, `test-practice` and `test-jobs`,
//! plus the shared helpers every area uses to add tests and GUI fixtures.
//! Nothing here accesses devices.
const std = @import("std");
const Config = @import("Config.zig");
const Modules = @import("Modules.zig");
const Steps = @import("Steps.zig");
const runtime = @import("runtime.zig");
const fw_build = @import("../src/firmware/build.zig");
const runner_build = @import("../src/runner/build.zig");
const Compile = std.Build.Step.Compile;
const Import = std.Build.Module.Import;

/// Which option configures a test root; `tests-reached` checks the roots of
/// unconfigured areas against their static inventory instead of binaries.
pub const Area = enum { core, desktop, firmware };

/// An area, whether its option is on, its wired test roots, and the source
/// files containing tests that are deferred when the area is unconfigured.
pub const Inventory = struct { Area, bool, []const []const u8, []const []const u8 };

/// Collects every test compilation so `check` compiles it and
/// `tests-reached` can read the binaries.
pub const Suite = struct {
    b: *std.Build,
    cfg: Config,
    mods: Modules,
    steps: Steps,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { area: Area, root: []const u8, compile: *Compile };

    /// Compile `module` as a test, run it for `step` and compile it for `check`.
    pub fn add(s: *Suite, step: *std.Build.Step, area: Area, module: *std.Build.Module) *std.Build.Step.Run {
        const source = module.root_source_file orelse @panic("Test root without a source file");
        return s.addTest(step, area, module, repositoryPath(s.b, source));
    }

    /// `add` for a generated module whose files are copies of the repository
    /// directory that holds `copied_from`; `tests-reached` credits that directory.
    pub fn addCopied(s: *Suite, step: *std.Build.Step, area: Area, module: *std.Build.Module, copied_from: []const u8) *std.Build.Step.Run {
        return s.addTest(step, area, module, copied_from);
    }

    fn addTest(s: *Suite, step: *std.Build.Step, area: Area, module: *std.Build.Module, root: []const u8) *std.Build.Step.Run {
        const compile = s.b.addTest(.{ .root_module = module, .filters = s.cfg.test_filters });
        s.steps.check.dependOn(&compile.step);
        const run = s.b.addRunArtifact(compile);
        step.dependOn(&run.step);
        s.entries.append(s.b.allocator, .{ .area = area, .root = root, .compile = compile }) catch @panic("OOM");
        return run;
    }

    /// An application-target executable, such as a subprocess fixture.
    pub fn exe(s: *Suite, name: []const u8, path: []const u8, imports: []const Import) *Compile {
        return s.b.addExecutable(.{ .name = name, .root_module = s.mods.root(path, imports) });
    }

    /// `add` for a new root module at `path` with `imports`.
    pub fn unit(s: *Suite, step: *std.Build.Step, area: Area, path: []const u8, imports: []const Import) *std.Build.Step.Run {
        return s.add(step, area, s.mods.root(path, imports));
    }

    /// Add the `tests-reached` guard to `step`. `deferred` lists the test
    /// roots of each unconfigured area; a configured area's roots must equal
    /// its inventory, so the inventory cannot drift from the wiring.
    pub fn guard(s: *Suite, step: *std.Build.Step, inventories: []const Inventory) void {
        // Name filters remove tests from the binaries.
        if (s.cfg.test_filters.len != 0) return;
        const b = s.b;
        const tool = b.addExecutable(.{ .name = "tests-reached", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tests_reached.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }) });
        const run = b.addRunArtifact(tool);
        run.addDirectoryArg(b.path("."));
        for (inventories) |inventory| {
            const area, const configured, const roots, const deferred_files = inventory;
            if (configured) {
                for (roots) |root| if (!s.hasRoot(area, root)) std.debug.panic("{t} test inventory lists unwired root {s}", .{ area, root });
                for (s.entries.items) |entry| if (entry.area == area and !listed(roots, entry.root))
                    std.debug.panic("{t} test root {s} is missing from its inventory", .{ area, entry.root });
            } else for (deferred_files) |file| {
                run.addArg("--deferred");
                run.addFileArg(b.path(file));
            }
        }
        for (s.entries.items) |entry| {
            if (entry.area != .core and !inventoryConfigured(inventories, entry.area)) continue;
            run.addFileArg(b.path(entry.root));
            run.addArtifactArg(entry.compile);
        }
        step.dependOn(&run.step);
    }

    fn hasRoot(s: *Suite, area: Area, root: []const u8) bool {
        for (s.entries.items) |entry| if (entry.area == area and std.mem.eql(u8, entry.root, root)) return true;
        return false;
    }
};

fn inventoryConfigured(inventories: []const Inventory, area: Area) bool {
    for (inventories) |inventory| if (inventory[0] == area) return inventory[1];
    return false;
}

fn listed(roots: []const []const u8, root: []const u8) bool {
    for (roots) |item| if (std.mem.eql(u8, item, root)) return true;
    return false;
}

/// The root's repository path with `/` separators, as the inventories list
/// it; modules store Windows source paths with `\`.
fn repositoryPath(b: *std.Build, source: std.Build.LazyPath) []const u8 {
    const path: []u8 = switch (source) {
        .src_path => |path| b.allocator.dupe(u8, path.sub_path) catch @panic("OOM"),
        else => @panic("Test roots must be repository files"),
    };
    std.mem.replaceScalar(u8, path, '\\', '/');
    return path;
}

/// Run `exe` with `args` under SDL's dummy video and software renderer: no
/// window, GPU or device.
pub fn addGuiFixture(b: *std.Build, exe: *Compile, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.addArgs(args);
    headless(run);
    return run;
}

/// Select SDL's dummy video driver and software renderer for `run`.
pub fn headless(run: *std.Build.Step.Run) void {
    run.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    run.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
}

/// Executables that test runs drive as subprocesses.
pub const Fixtures = struct {
    /// Options shared by the jobs, picotool and desktop integration tests.
    picotool: *std.Build.Step.Options,
    /// The basic native runner the GUI draft fixture drives.
    runner: ?*Compile = null,
    /// The catalog board exporter (`tools/catalog_export.zig`).
    catalog_export: ?*Compile = null,
    /// Exported projects of the pinned import fixtures, for firmware checks.
    imports: []const ImportedExport = &.{},
    /// Application flash admission tests, also part of `test-desktop`.
    app_tests: ?*std.Build.Step.Run = null,
};

pub const ImportedExport = struct { selector: []const u8, export_root: std.Build.LazyPath };

const import_fixtures = [_][]const u8{ "us", "de" };
const import_selectors = [_][]const u8{ "keycaprio_colemak_0_6", "keycaprio_colemak_0_7" };

/// Tests without the firmware package: typing tests, paths, jobs and release.
pub fn addCore(s: *Suite) Fixtures {
    const b = s.b;
    const steps = s.steps;
    const core = s.mods.core;
    _ = s.unit(steps.test_practice, .core, "src/desktop/test_practice_all.zig", &.{});
    _ = s.unit(steps.test_practice, .core, "src/platform/app_paths.zig", &.{});

    const release = b.createModule(.{ .root_source_file = b.path("tools/release.zig"), .target = s.cfg.target, .optimize = s.cfg.optimize, .imports = core.jobs_only });
    release.addOptions("release-options", core.release_options);
    _ = s.add(steps.test_jobs, .core, release);

    const helper = s.exe("job-fixture", "src/jobs/fixture.zig", &.{});
    const picotool = b.addOptions();
    picotool.addOptionPath("fixture", s.exe("picotool-job-fixture", "src/jobs/picotool_fixture.zig", &.{}).getEmittedBin());
    picotool.addOptionPath("helper_path", helper.getEmittedBin());
    // POSIX only: the cancellation tests use PIDs, and Windows flashes
    // through the BOOTSEL helper instead of picotool.
    if (s.cfg.target.result.os.tag != .windows) {
        const flash = flashPicotool(b, s.cfg);
        picotool.addOptionPath("wrapper", b.addExecutable(.{ .name = "picotool-flash-offline", .root_module = flash }).getEmittedBin());
        picotool.addOptionPath("picotool_fixture", s.exe("fake-picotool", "src/jobs/fake_picotool.zig", &.{}).getEmittedBin());
        const wrapper = s.mods.root("src/jobs/test_picotool_flash.zig", &.{.{ .name = "flash-picotool", .module = flash }});
        wrapper.addOptions("options", picotool);
        _ = s.add(steps.test_jobs, .core, wrapper);
    }
    const jobs_all = s.mods.root("src/jobs/test_all.zig", core.jobs_deps);
    jobs_all.addOptions("options", picotool);
    _ = s.add(steps.test_jobs, .core, jobs_all);
    _ = s.unit(steps.test_jobs, .core, "src/artifact/uf2.zig", &.{});

    _ = s.unit(steps.@"test", .core, "src/project/owned_zon.zig", &.{});
    _ = s.unit(steps.@"test", .core, "src/desktop/test_core_all.zig", core.jobs_only);
    _ = s.add(steps.@"test", .core, core.flash_presenter);
    return .{ .picotool = picotool };
}

/// Tests on the firmware package's processor: project, catalog, runner,
/// session, import and input contracts.
pub fn addHost(s: *Suite, fixtures: *Fixtures) void {
    const b = s.b;
    const step = s.steps.@"test";
    const h = s.mods.host.?;

    addInput(s, h);
    _ = s.unit(step, .core, "src/layout/root.zig", h.zigmkay_only);
    _ = s.add(step, .core, h.catalog);
    // The descriptors' tests compile only in the generated inventory.
    _ = s.addCopied(step, .core, h.defaults_test, "src/firmware/boards.zig");
    _ = s.add(step, .core, h.catalog_project);

    _ = s.unit(step, .core, "src/desktop/test_host_all.zig", h.desktop_host_test_deps);
    const integration = s.mods.root("tests/test_host_all.zig", h.host_integration_test_deps);
    integration.addOptions("options", fixtures.picotool);
    _ = s.add(step, .core, integration);
    fixtures.app_tests = s.unit(step, .core, "src/app/test_all.zig", h.app_test_deps);

    // The simulated learner is compiled by `check` but runs only on request.
    const offline_translator = b.createModule(.{ .root_source_file = b.path("src/app/OfflineTranslator.zig"), .imports = &.{.{ .name = "zkeymap", .module = h.keymap }} });
    _ = s.unit(s.steps.test_tutor_learner, .core, "tests/tutor_learner.zig", &.{
        .{ .name = "desktop-core", .module = h.desktop_core },
        .{ .name = "catalog", .module = h.catalog },
        .{ .name = "catalog-project", .module = h.catalog_project },
        .{ .name = "offline-translator", .module = offline_translator },
    });

    // Nested analysis builds run against the bundled runtime closure, exactly
    // as the installed application does, with the repository's import fixtures.
    const importer_options = b.addOptions();
    importer_options.addOptionPathDirectory("repository", runtime.tree(b, b.dependency("zigmkay_firmware", .{}), &.{"tests/fixtures/import"}));
    importer_options.addOption([]const u8, "compiler", b.graph.zig_exe);
    // Absolute: the nested build runs in the runtime tree, not in this repository.
    importer_options.addOption([]const u8, "packages", b.pathJoin(&.{ b.root.toString(b.allocator) catch @panic("OOM"), "zig-pkg" }));
    importer_options.addOptionPathUntracked("compiler_cache", .{ .relative = .{ .base = .global_cache } });
    const importer = s.mods.root("src/importer/root.zig", h.importer_deps);
    importer.addOptions("test-options", importer_options);
    _ = s.add(step, .core, importer);

    fixtures.catalog_export = addCatalogProcessors(s, h);
    fixtures.runner = addRunner(s, h);
    fixtures.imports = addImportProcessors(s, h, importer_options);
    addProject(s, h);

    _ = s.unit(step, .core, "src/platform/test_native_hid.zig", h.native_hid_only);
    _ = s.unit(step, .core, "src/firmware/protocol.zig", h.zigmkay_only);
    _ = s.unit(step, .core, "src/session/root.zig", h.session_deps);
    _ = s.unit(step, .core, "src/session/test_all.zig", h.session_test_deps);
}

fn addInput(s: *Suite, h: Modules.Host) void {
    const b = s.b;
    const step = s.steps.@"test";
    const input = h.input_tests;
    _ = s.add(step, .core, input.portable);
    _ = s.add(step, .core, input.us_fixture);
    _ = s.add(step, .core, input.hid_tables);
    const smoke = b.addExecutable(.{ .name = "input-source-native-check", .root_module = s.mods.root("src/input/native_smoke.zig", input.smoke_deps) });
    _ = smoke.getEmittedBin();
    s.steps.check.dependOn(&smoke.step);
    // The OS layout is queried only by the explicit `test-native` step.
    _ = s.add(s.steps.test_native, .core, input.native);
}

/// Export every selected board, synthetic and default, and compare it with
/// its real processor in two consolidated test binaries (one synthetic, one
/// default) instead of 28 separate binaries.
fn addCatalogProcessors(s: *Suite, h: Modules.Host) *Compile {
    const b = s.b;
    const export_tool = host(b, "catalog-export", "tools/catalog_export.zig", h.catalog_export_deps);
    s.steps.check.dependOn(&export_tool.step);

    var index_source: std.ArrayList(u8) = .empty;
    index_source.appendSlice(b.allocator, "pub const profiles = .{\n") catch @panic("OOM");
    for (fw_build.boards.entries, 0..) |_, index| {
        index_source.appendSlice(b.allocator, b.fmt("    @import(\"profile_{d}\"),\n", .{index})) catch @panic("OOM");
    }
    index_source.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const index_file = b.addWriteFiles().add("profiles.zig", index_source.items);

    const synthetic_profiles = b.createModule(.{ .root_source_file = index_file });
    const default_profiles = b.createModule(.{ .root_source_file = index_file });

    for (fw_build.boards.entries, 0..) |board, index| {
        const generate = b.addRunArtifact(export_tool);
        generate.addArg(board.name);
        const directory = generate.addOutputDirectoryArg2(board.name, .{ .make_absolute = true });
        const generated = b.createModule(.{ .root_source_file = directory.path(b, "keymap.zig"), .imports = h.zigmkay_only });
        synthetic_profiles.addImport(b.fmt("profile_{d}", .{index}), generated);

        const default_generate = b.addRunArtifact(export_tool);
        default_generate.addArg(board.name);
        const default_directory = default_generate.addOutputDirectoryArg2(b.fmt("default-{s}", .{board.name}), .{ .make_absolute = true });
        default_generate.addArg("--default");
        const exported = b.createModule(.{ .root_source_file = default_directory.path(b, "keymap.zig"), .imports = h.zigmkay_only });
        // Callback-free defaults never import this module.
        exported.addImport("callback_0", b.createModule(.{
            .root_source_file = default_directory.path(b, b.fmt("callback_0/{s}", .{board.default_keymap})),
            .imports = &.{ .{ .name = "zigmkay", .module = h.zigmkay }, .{ .name = "zkeycodes", .module = h.keycodes } },
        }));
        default_profiles.addImport(b.fmt("profile_{d}", .{index}), exported);
    }

    _ = s.unit(s.steps.@"test", .core, "tests/catalog_processor_contract.zig", &.{
        .{ .name = "zigmkay", .module = h.zigmkay },
        .{ .name = "device-protocol", .module = h.protocol },
        .{ .name = "generated-profiles", .module = synthetic_profiles },
    });
    _ = s.unit(s.steps.@"test", .core, "tests/catalog_default_processor_contract.zig", &.{
        .{ .name = "firmware-defaults", .module = h.defaults },
        .{ .name = "zigmkay", .module = h.zigmkay },
        .{ .name = "generated-profiles", .module = default_profiles },
    });
    return export_tool;
}

/// The real-processor subprocess matrix. Returns the basic runner.
fn addRunner(s: *Suite, h: Modules.Host) *Compile {
    const b = s.b;
    const basic_profile = b.createModule(.{ .root_source_file = runnerFixture(s, h, "runner-fixture", null), .imports = h.zigmkay_only });
    const basic = runner_build.runner(b, "keymap-test", h.zigmkay, basic_profile, h.runner_protocol, null);
    const rejected = runner_build.runner(b, "reject-zero-snapshot", h.zigmkay, basic_profile, h.runner_protocol, @as([32]u8, @splat(0)));
    rejected.expect_errors = .{ .contains = "Export snapshot identity mismatch" };
    s.steps.@"test".dependOn(&rejected.step);
    s.steps.check.dependOn(&rejected.step);
    const invalid = b.addExecutable(.{ .name = "invalid-runner-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/runner/invalid_fixture.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "runner-protocol", .module = h.runner_protocol }, .{ .name = "test-profile", .module = basic_profile }, .{ .name = "zigmkay", .module = h.zigmkay } },
    }) });
    const action_profile = b.createModule(.{ .root_source_file = runnerFixture(s, h, "runner-actions", "all-actions"), .imports = &.{ .{ .name = "zigmkay", .module = h.zigmkay }, .{ .name = "callback_0", .module = h.runner_callback_fixture } } });
    const registered_profile = b.createModule(.{ .root_source_file = runnerFixture(s, h, "runner-registered", "danish"), .imports = &.{ .{ .name = "zigmkay", .module = h.zigmkay }, .{ .name = "callback_0", .module = h.profile } } });
    const options = b.addOptions();
    options.addOptionPath("runner_path", basic.getEmittedBin());
    options.addOptionPath("invalid_runner_path", invalid.getEmittedBin());
    options.addOptionPath("action_runner_path", runner_build.runner(b, "action-runner", h.zigmkay, action_profile, h.runner_protocol, null).getEmittedBin());
    options.addOptionPath("registered_runner_path", runner_build.runner(b, "registered-runner", h.zigmkay, registered_profile, h.runner_protocol, null).getEmittedBin());
    const tests = b.createModule(.{ .root_source_file = b.path("src/runner/test_runner.zig"), .target = b.graph.host, .imports = h.runner_test_deps });
    tests.addImport("test-profile", basic_profile);
    tests.addOptions("options", options);
    _ = s.add(s.steps.@"test", .core, tests);
    return basic;
}

fn runnerFixture(s: *Suite, h: Modules.Host, name: []const u8, mode: ?[]const u8) std.Build.LazyPath {
    const run = s.b.addRunArtifact(host(s.b, name, "src/runner/fixture.zig", h.keymap_project));
    const source = run.addOutputFileArg("keymap.zig");
    if (mode) |arg| run.addArg(arg);
    return source;
}

/// Convert the pinned import fixtures through the production importer and
/// compare their processor traces in one consolidated test binary.
fn addImportProcessors(s: *Suite, h: Modules.Host, importer_options: *std.Build.Step.Options) []const ImportedExport {
    const b = s.b;
    const tool = host(b, "import-fixture", "tools/import_fixture.zig", h.import_fixture_deps);
    tool.root_module.addOptions("build-options", importer_options);
    var result: std.ArrayList(ImportedExport) = .empty;
    var index_source: std.ArrayList(u8) = .empty;
    index_source.appendSlice(b.allocator, "pub const pairs = .{\n") catch @panic("OOM");
    for (import_fixtures, 0..) |_, fi| for (import_selectors, 0..) |_, si| {
        const idx = fi * import_selectors.len + si;
        index_source.appendSlice(b.allocator, b.fmt("    .{{ .original = @import(\"original_{d}\"), .profile = @import(\"profile_{d}\") }},\n", .{ fi, idx })) catch @panic("OOM");
    };
    index_source.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const pairs_mod = b.createModule(.{ .root_source_file = b.addWriteFiles().add("imported_pairs.zig", index_source.items) });
    var idx: usize = 0;
    for (import_fixtures, 0..) |name, fi| {
        const original = b.createModule(.{ .root_source_file = b.path(b.fmt("tests/fixtures/import/{s}/src/keymap.zig", .{name})), .imports = &.{ .{ .name = "zigmkay", .module = h.zigmkay }, .{ .name = "zkeycodes", .module = h.keycodes } } });
        pairs_mod.addImport(b.fmt("original_{d}", .{fi}), original);
        for (import_selectors) |selector| {
            const run = b.addRunArtifact(tool);
            run.addDirectoryArg(b.path(b.fmt("tests/fixtures/import/{s}", .{name})));
            run.addArg(selector);
            const exported = run.addOutputDirectoryArg(b.fmt("imported-{s}-{s}", .{ name, selector })).path(b, "export");
            result.append(b.allocator, .{ .selector = selector, .export_root = exported }) catch @panic("OOM");
            const profile = importedProfile(b, exported, h.zigmkay, h.keycodes, h.layout);
            pairs_mod.addImport(b.fmt("profile_{d}", .{idx}), profile);
            if (!s.cfg.firmware_subset or idx == 0) {
                const imported_runner = runner_build.runner(b, b.fmt("imported-{s}-{s}-runner", .{ name, selector }), h.zigmkay, profile, h.runner_protocol, null);
                s.steps.@"test".dependOn(&imported_runner.step);
            }
            idx += 1;
        }
    }
    _ = s.add(s.steps.@"test", .core, b.createModule(.{
        .root_source_file = b.path("tests/import_processor_contract.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "zigmkay", .module = h.zigmkay },
            .{ .name = "imported-profiles", .module = pairs_mod },
        },
    }));
    return result.items;
}

/// The keymap module of an imported project export, with its paired callback.
pub fn importedProfile(b: *std.Build, root: std.Build.LazyPath, processor: *std.Build.Module, keycodes: *std.Build.Module, layout: *std.Build.Module) *std.Build.Module {
    const imports: []const Import = &.{ .{ .name = "zigmkay", .module = processor }, .{ .name = "zkeycodes", .module = keycodes }, .{ .name = "layout-model", .module = layout } };
    const profile = b.createModule(.{ .root_source_file = root.path(b, "keymap.zig"), .imports = imports });
    profile.addImport("callback_0", b.createModule(.{ .root_source_file = root.path(b, "callback_0/src/keymap.zig"), .imports = imports }));
    return profile;
}

/// Project schema, historical callbacks and deterministic export compilation.
fn addProject(s: *Suite, h: Modules.Host) void {
    const b = s.b;
    const step = s.steps.@"test";
    const project = s.mods.root("src/project/root.zig", h.project_deps);
    project.addAnonymousImport("rollercole-source", .{ .root_source_file = h.rollercole_source });
    _ = s.add(step, .core, project);
    const historical = s.mods.root("src/project/test_historical_callbacks.zig", h.project_only);
    historical.addAnonymousImport("historical-rollercole-source", .{ .root_source_file = b.path("tests/fixtures/historical/rollercole-0.16.zig.txt") });
    _ = s.add(step, .core, historical);
    const generator = b.addExecutable(.{ .name = "export-compile-fixture", .root_module = s.mods.root("src/project/export_fixture.zig", h.keymap_project) });
    const exported = b.createModule(.{ .root_source_file = b.addRunArtifact(generator).addOutputFileArg("keymap.zig"), .imports = h.zigmkay_only });
    _ = s.unit(step, .core, "src/project/export_compile_test.zig", &.{
        .{ .name = "generated-profile", .module = exported },
        .{ .name = "zigmkay", .module = h.zigmkay },
        .{ .name = "device-protocol", .module = h.protocol },
    });
}

/// A host-target executable used as a test fixture or generator.
pub fn host(b: *std.Build, name: []const u8, path: []const u8, imports: []const Import) *Compile {
    return b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = b.graph.host,
        .imports = imports,
    }) });
}

/// The firmware's picotool flash wrapper, which the bundle ships as
/// `tools/picotool_flash`, built for the application target.
pub fn flashPicotool(b: *std.Build, cfg: Config) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.dependency("zigmkay_firmware", .{}).path("zigmkay/tools/flash_picotool.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,
    });
}
