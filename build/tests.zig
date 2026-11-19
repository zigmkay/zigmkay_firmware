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

/// An area, whether its option is on, and its static test-root inventory.
pub const Inventory = struct { Area, bool, []const []const u8 };

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
        }) });
        const run = b.addRunArtifact(tool);
        run.addDirectoryArg(b.path("."));
        for (inventories) |inventory| {
            const area, const configured, const roots = inventory;
            if (configured) {
                for (roots) |root| if (!s.hasRoot(area, root)) std.debug.panic("{t} test inventory lists unwired root {s}", .{ area, root });
                for (s.entries.items) |entry| if (entry.area == area and !listed(roots, entry.root))
                    std.debug.panic("{t} test root {s} is missing from its inventory", .{ area, entry.root });
            } else for (roots) |root| {
                run.addArg("--deferred");
                run.addFileArg(b.path(root));
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
    flash_session: [3]?*std.Build.Step.Run = @splat(null),
};

pub const ImportedExport = struct { selector: []const u8, export_root: std.Build.LazyPath };

const practice_files = [_][]const u8{ "practice.zig", "practice_view.zig", "practice_generator.zig", "practice_controller.zig" };
const desktop_files = [_][]const u8{ "try_state.zig", "flash_controller.zig", "auto_build.zig", "geometry.zig", "encoder_state.zig" };
const jobs_files = [_][]const u8{ "target_lock.zig", "firmware.zig", "source_digest.zig", "sidecar.zig", "flash_inputs.zig", "application_bundle.zig", "bundle_payload.zig", "runner_artifact.zig", "bootsel_transfer.zig" };
const project_desktop_files = [_][]const u8{ "startup_project.zig", "host_input.zig", "draft_input.zig", "action_form.zig", "profile_projects.zig", "model.zig" };
const label_files = [_][]const u8{ "keycap_symbols.zig", "labels.zig", "label_cache.zig", "physical_view.zig" };
const session_files = [_][]const u8{ "root.zig", "test_session.zig", "live_adapter.zig", "session_capture.zig" };
const import_fixtures = [_][]const u8{ "us", "de" };
const import_selectors = [_][]const u8{ "keycaprio_colemak_0_6", "keycaprio_colemak_0_7" };

/// Tests without the firmware package: typing tests, paths, jobs and release.
pub fn addCore(s: *Suite) Fixtures {
    const b = s.b;
    const steps = s.steps;
    const core = s.mods.core;
    for (practice_files) |name| _ = s.unit(steps.test_practice, .core, b.fmt("src/desktop/{s}", .{name}), &.{});
    _ = s.unit(steps.test_practice, .core, "src/platform/app_paths.zig", &.{});

    const release = b.createModule(.{ .root_source_file = b.path("tools/release.zig"), .target = s.cfg.target, .optimize = s.cfg.optimize, .imports = core.jobs_only });
    release.addOptions("release-options", core.release_options);
    _ = s.add(steps.test_jobs, .core, release);

    const helper = s.exe("job-fixture", "src/jobs/fixture.zig", &.{});
    const process = s.mods.root("src/jobs/test_process.zig", core.jobs_only);
    const process_options = b.addOptions();
    process_options.addOptionPath("helper_path", helper.getEmittedBin());
    process.addOptions("options", process_options);
    _ = s.add(steps.test_jobs, .core, process);
    _ = s.unit(steps.test_jobs, .core, "src/jobs/package_manifest.zig", core.jobs_deps);
    _ = s.unit(steps.test_jobs, .core, "src/jobs/source_files.zig", &.{});
    for (jobs_files) |name| _ = s.unit(steps.test_jobs, .core, b.fmt("src/jobs/{s}", .{name}), core.jobs_deps);
    _ = s.unit(steps.test_jobs, .core, "src/artifact/uf2.zig", &.{});
    _ = s.unit(steps.@"test", .core, "src/project/owned_zon.zig", &.{});

    const picotool = b.addOptions();
    picotool.addOptionPath("fixture", s.exe("picotool-job-fixture", "src/jobs/picotool_fixture.zig", &.{}).getEmittedBin());
    picotool.addOptionPath("helper_path", helper.getEmittedBin());
    // POSIX only: the cancellation tests use PIDs, and Windows flashes
    // through the BOOTSEL helper instead of picotool.
    if (s.cfg.target.result.os.tag != .windows) {
        picotool.addOptionPath("wrapper", s.exe("picotool-flash-offline", "src/jobs/picotool_flash.zig", &.{}).getEmittedBin());
        picotool.addOptionPath("picotool_fixture", s.exe("fake-picotool", "src/jobs/fake_picotool.zig", &.{}).getEmittedBin());
        const wrapper = s.mods.root("src/jobs/test_picotool_flash.zig", &.{});
        wrapper.addOptions("options", picotool);
        _ = s.add(steps.test_jobs, .core, wrapper);
    }
    const picotool_job = s.mods.root("src/jobs/test_picotool_job.zig", core.jobs_deps);
    picotool_job.addOptions("options", picotool);
    _ = s.add(steps.test_jobs, .core, picotool_job);

    for (desktop_files) |name| _ = s.unit(steps.@"test", .core, b.fmt("src/desktop/{s}", .{name}), core.jobs_only);
    _ = s.add(steps.@"test", .core, core.flash_presenter);
    _ = s.add(steps.@"test", .core, core.tray_lifecycle);
    _ = s.unit(steps.@"test", .core, "src/app/cli.zig", &.{});
    return .{ .picotool = picotool };
}

/// Tests on the firmware package's processor: project, catalog, runner,
/// session, import and input contracts.
pub fn addHost(s: *Suite, fixtures: *Fixtures) void {
    const b = s.b;
    const step = s.steps.@"test";
    const h = s.mods.host.?;

    addInput(s, h);
    _ = s.unit(step, .core, "tests/processor_contract.zig", h.processor_contract_deps);
    _ = s.unit(step, .core, "src/layout/root.zig", h.zigmkay_only);
    _ = s.add(step, .core, h.catalog);
    // The descriptors' tests compile only in the generated inventory.
    _ = s.addCopied(step, .core, h.defaults_test, "src/firmware/boards.zig");
    _ = s.add(step, .core, h.catalog_project);

    _ = s.unit(step, .core, "src/desktop/text.zig", h.text_deps);
    for (project_desktop_files) |name| _ = s.unit(step, .core, b.fmt("src/desktop/{s}", .{name}), h.project_only);
    for (label_files) |name| _ = s.unit(step, .core, b.fmt("src/desktop/{s}", .{name}), h.label_deps);
    _ = s.unit(step, .core, "src/desktop/flash_runtime.zig", h.flash_runtime_deps);
    _ = s.unit(step, .core, "src/desktop/event_history.zig", h.event_history_deps);
    _ = s.unit(step, .core, "src/desktop/inspector_session.zig", h.inspector_session_deps);
    _ = s.unit(step, .core, "src/desktop/live_keyboard.zig", h.live_keyboard_deps);
    const integration = s.mods.root("tests/desktop_integration.zig", h.desktop_integration_deps);
    integration.addOptions("options", fixtures.picotool);
    _ = s.add(step, .core, integration);
    _ = s.unit(step, .core, "tests/catalog_physical_view.zig", h.catalog_view_deps);
    _ = s.unit(step, .core, "tests/onboarding.zig", h.onboarding_deps);
    _ = s.unit(step, .core, "tests/keyboard_library.zig", h.onboarding_deps);
    fixtures.flash_session = .{
        s.unit(step, .core, "src/app/flash_session.zig", h.flash_session_deps),
        s.unit(step, .core, "src/app/flash_bootloader.zig", &.{}),
        s.unit(step, .core, "src/app/flash_fixture.zig", h.flash_fixture_deps),
    };

    // Nested analysis builds run against the bundled runtime closure, exactly
    // as the installed application does, with the repository's import fixtures.
    const importer_options = b.addOptions();
    importer_options.addOptionPathDirectory("repository", runtime.tree(b, &.{"tests/fixtures/import"}));
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
    for (session_files) |name| {
        const imports = if (std.mem.eql(u8, name, "root.zig")) h.session_deps else h.session_test_deps;
        _ = s.unit(step, .core, b.fmt("src/session/{s}", .{name}), imports);
    }
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
/// its real processor.
fn addCatalogProcessors(s: *Suite, h: Modules.Host) *Compile {
    const b = s.b;
    const exporter = s.mods.root("tools/catalog_export.zig", h.catalog_export_deps);
    const export_tool = b.addExecutable(.{ .name = "catalog-export", .root_module = exporter });
    s.steps.check.dependOn(&export_tool.step);
    for (fw_build.boards.entries, 0..) |board, index| {
        const generate = b.addRunArtifact(export_tool);
        generate.addArg(board.name);
        const directory = generate.addOutputDirectoryArg2(board.name, .{ .make_absolute = true });
        const generated = b.createModule(.{ .root_source_file = directory.path(b, "keymap.zig"), .imports = h.zigmkay_only });
        _ = s.unit(s.steps.@"test", .core, "tests/catalog_processor_contract.zig", &.{
            .{ .name = "generated-profile", .module = generated },
            .{ .name = "zigmkay", .module = h.zigmkay },
            .{ .name = "device-protocol", .module = h.protocol },
        });

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
        const options = b.addOptions();
        options.addOption(usize, "index", index);
        _ = s.unit(s.steps.@"test", .core, "tests/catalog_default_processor_contract.zig", &.{
            .{ .name = "generated-profile", .module = exported },
            .{ .name = "firmware-defaults", .module = h.defaults },
            .{ .name = "zigmkay", .module = h.zigmkay },
            .{ .name = "catalog-options", .module = options.createModule() },
        });
    }
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
/// compare their processor traces. Returns the exports for firmware checks.
fn addImportProcessors(s: *Suite, h: Modules.Host, importer_options: *std.Build.Step.Options) []const ImportedExport {
    const b = s.b;
    const tool = host(b, "import-fixture", "tools/import_fixture.zig", h.import_fixture_deps);
    tool.root_module.addOptions("build-options", importer_options);
    var result: std.ArrayList(ImportedExport) = .empty;
    for (import_fixtures) |name| for (import_selectors) |selector| {
        const run = b.addRunArtifact(tool);
        run.addDirectoryArg(b.path(b.fmt("tests/fixtures/import/{s}", .{name})));
        run.addArg(selector);
        const exported = run.addOutputDirectoryArg(b.fmt("imported-{s}-{s}", .{ name, selector })).path(b, "export");
        result.append(b.allocator, .{ .selector = selector, .export_root = exported }) catch @panic("OOM");
        const profile = importedProfile(b, exported, h.zigmkay, h.keycodes, h.layout);
        const original = b.createModule(.{ .root_source_file = b.path(b.fmt("tests/fixtures/import/{s}/src/keymap.zig", .{name})), .imports = &.{ .{ .name = "zigmkay", .module = h.zigmkay }, .{ .name = "zkeycodes", .module = h.keycodes } } });
        _ = s.add(s.steps.@"test", .core, b.createModule(.{ .root_source_file = b.path("tests/import_processor_contract.zig"), .target = b.graph.host, .imports = &.{
            .{ .name = "zigmkay", .module = h.zigmkay },
            .{ .name = "original-profile", .module = original },
            .{ .name = "generated-profile", .module = profile },
        } }));
        const imported_runner = runner_build.runner(b, b.fmt("imported-{s}-{s}-runner", .{ name, selector }), h.zigmkay, profile, h.runner_protocol, null);
        s.steps.@"test".dependOn(&imported_runner.step);
    };
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
