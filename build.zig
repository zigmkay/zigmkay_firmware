const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    @setEvalBranchQuota(100_000);
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0"))
        @panic("zigmkay_companion requires exactly Zig 0.17.0");
    // Register command-line options before lazy dependencies can suspend setup.
    const application_bundle = b.option(bool, "application-bundle", "Include the compiler, firmware closure and prebuilt flash tools") orelse false;
    const native_only = b.option(bool, "native-only", "Skip embedded preparation for native tools") orelse false;
    const selected_export = b.option([]const u8, "project-export", "Absolute frozen project export directory");
    const selected_board = b.option([]const u8, "project-board", "Authoritative selected firmware board selector");
    const prepare_firmware = b.option(bool, "firmware-check", "Prepare downstream embedded build dependencies") orelse false;
    const prepare_imports = b.option(bool, "import-check", "Compile the pinned import firmware matrix") orelse false;
    const prepare_catalog = b.option(bool, "catalog-check", "Prepare all-board synthetic project firmware matrix explicitly") orelse false;
    const actual_defaults = b.option(bool, "catalog-defaults", "Compile actual selected defaults instead of synthetic catalog fixtures") orelse false;

    const check = b.step("check", "Compile downstream processor contract without device access");
    b.default_step = check;
    const tests = b.step("test", "Run offline downstream processor contract tests");
    const app_paths_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/platform/src/app_paths.zig"),
        .target = b.graph.host,
    }) });
    const app_paths_step = b.step("test-app-paths", "Validate installed resources and user-storage migration policy offline");
    app_paths_step.dependOn(&b.addRunArtifact(app_paths_tests).step);
    tests.dependOn(app_paths_step);
    check.dependOn(&app_paths_tests.step);
    const desktop_dependencies = b.step("check-desktop-dependencies", "Compile the pinned desktop GUI/tray graph without launching it");
    var desktop_graph: ?@import("packages/platform/desktop_build.zig").Graph = null;
    var desktop_app: ?*std.Build.Step.Compile = null;
    const owned_zon = b.addModule("owned-zon", .{ .root_source_file = b.path("packages/project/src/owned_zon.zig") });
    const uf2_module = b.addModule("firmware-uf2", .{ .root_source_file = b.path("packages/artifact/src/uf2.zig") });
    const jobs_imports: []const std.Build.Module.Import = &.{ .{ .name = "owned-zon", .module = owned_zon }, .{ .name = "firmware-uf2", .module = uf2_module } };
    const jobs = b.addModule("companion-jobs", .{ .root_source_file = b.path("packages/jobs/src/root.zig"), .imports = jobs_imports });
    const finalization_diagnostic = b.addExecutable(.{
        .name = "diagnose-build-finalization",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/diagnose_build_finalization.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .strip = false,
            .imports = &.{.{ .name = "companion-jobs", .module = jobs }},
        }),
    });
    const diagnostic_step = b.step("build-finalization-diagnostic", "Build the symbolized offline artifact publication reproduction");
    diagnostic_step.dependOn(&b.addInstallArtifact(finalization_diagnostic, .{}).step);
    if (b.option(bool, "finalization-diagnostic-only", "Configure only the offline artifact publication diagnostic") orelse false) return;
    const flash_controller = b.addModule("flash-controller", .{ .root_source_file = b.path("packages/desktop/src/flash_controller.zig"), .imports = &.{.{ .name = "companion-jobs", .module = jobs }} });
    const tray_lifecycle = b.addModule("tray-lifecycle", .{ .root_source_file = b.path("packages/desktop/src/tray_lifecycle.zig"), .target = b.graph.host });
    const flash_presenter = b.addModule("flash-presenter", .{ .root_source_file = b.path("packages/desktop/src/flash_presenter.zig"), .target = b.graph.host, .imports = &.{.{ .name = "flash-controller", .module = flash_controller }} });
    const desktop_geometry = b.addModule("desktop-geometry", .{ .root_source_file = b.path("packages/desktop/src/geometry.zig") });
    const desktop_tests_step = b.step("test-desktop-core", "Validate practice and explicit flash intents without GUI or devices");
    const zqlite = b.dependency("zqlite", .{
        .target = b.graph.host,
        .sqlite3 = @as([]const []const u8, &.{
            "-std=c99",                     "-DSQLITE_THREADSAFE=1",     "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0", "-DSQLITE_ENABLE_API_ARMOR", "-DSQLITE_MAX_LENGTH=33554432", "-DSQLITE_MAX_SQL_LENGTH=65536",
        }),
    }).module("zqlite");
    if (b.graph.host.result.os.tag == .windows) zqlite.linkSystemLibrary("advapi32", .{});
    const practice_data_tests = b.step("test-practice-data", "Validate timing, database portability and legacy migration without firmware or devices");
    for ([_][]const u8{ "practice_generator.zig", "practice_results.zig", "practice_history.zig", "practice_history_runtime.zig", "practice_timing.zig", "practice_database.zig", "practice_progress.zig", "practice_analysis.zig", "practice_curriculum.zig", "practice_help.zig", "practice_retention.zig" }) |name| {
        const practice_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("packages/desktop/src/{s}", .{name})),
            .target = b.graph.host,
        }) });
        if (std.mem.indexOf(u8, name, "history") != null or std.mem.eql(u8, name, "practice_database.zig")) practice_tests.root_module.addImport("zqlite", zqlite);
        const run_practice = b.addRunArtifact(practice_tests);
        desktop_tests_step.dependOn(&run_practice.step);
        practice_data_tests.dependOn(&run_practice.step);
        check.dependOn(&practice_tests.step);
    }
    if (b.option(bool, "practice-data-only", "Build only offline practice data contracts without the firmware graph") orelse false) {
        tests.dependOn(practice_data_tests);
        return;
    }

    for ([_][]const u8{ "practice.zig", "practice_view.zig", "practice_controller.zig", "try_state.zig", "flash_controller.zig", "auto_build.zig", "geometry.zig", "encoder_state.zig" }) |file| {
        const desktop_test = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("packages/desktop/src/{s}", .{file})),
            .target = b.graph.host,
            .imports = &.{.{ .name = "companion-jobs", .module = jobs }},
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(desktop_test).step);
        check.dependOn(&desktop_test.step);
    }
    tests.dependOn(desktop_tests_step);
    const flash_presenter_tests = b.addTest(.{ .root_module = flash_presenter });
    desktop_tests_step.dependOn(&b.addRunArtifact(flash_presenter_tests).step);
    check.dependOn(&flash_presenter_tests.step);
    const tray_lifecycle_tests = b.addTest(.{ .root_module = tray_lifecycle });
    desktop_tests_step.dependOn(&b.addRunArtifact(tray_lifecycle_tests).step);
    check.dependOn(&tray_lifecycle_tests.step);
    if (b.option(bool, "desktop-dependencies", "Compile native desktop dependencies") orelse false) {
        const vectors = b.option(bool, "desktop-vectors", "Enable TinyVG rendering and icons") orelse false;
        desktop_graph = @import("packages/platform/desktop_build.zig").check(b, desktop_dependencies, flash_presenter, tray_lifecycle, vectors);
    } else desktop_dependencies.dependOn(&b.addFail("Pass desktop-dependencies=true to compile the native GUI").step);
    const job_fixture = b.addExecutable(.{ .name = "job-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("packages/jobs/src/fixture.zig"),
        .target = b.graph.host,
    }) });
    const job_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/jobs/src/test_process.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "companion-jobs", .module = jobs }},
    }) });
    // Keep the bundle's process-lifecycle gate independent of imported firmware
    // tests and Flash-tool fixtures. The complete test-jobs target stays intact.
    const subprocess_tests = b.addTest(.{
        .root_module = job_tests.root_module,
        .filters = &.{"test_process."},
    });
    const job_options = b.addOptions();
    job_options.addOptionPath("helper_path", job_fixture.getEmittedBin());
    job_tests.root_module.addOptions("options", job_options);
    const subprocess_step = b.step("test-subprocess", "Run isolated subprocess lifecycle regressions offline");
    subprocess_step.dependOn(&b.addRunArtifact(subprocess_tests).step);
    const jobs_step = b.step("test-jobs", "Run bounded subprocess, runner session and traversal regressions offline");
    const package_manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/jobs/src/package_manifest.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "owned-zon", .module = owned_zon }, .{ .name = "firmware-uf2", .module = uf2_module } },
        }),
        .filters = &.{ "literal dependency manifests", "manifest data" },
    });
    jobs_step.dependOn(&b.addRunArtifact(package_manifest_tests).step);
    jobs_step.dependOn(&b.addRunArtifact(job_tests).step);
    const traversal_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/jobs/src/source_files.zig"),
        .target = b.graph.host,
    }) });
    jobs_step.dependOn(&b.addRunArtifact(traversal_tests).step);
    check.dependOn(&job_tests.step);
    check.dependOn(&traversal_tests.step);
    tests.dependOn(jobs_step);
    for ([_][]const u8{ "target_lock.zig", "firmware.zig", "source_digest.zig", "sidecar.zig", "flash_inputs.zig", "application_bundle.zig", "bundle_payload.zig", "runner_artifact.zig" }) |file| {
        const artifact = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("packages/jobs/src/{s}", .{file})),
            .target = b.graph.host,
            .imports = jobs_imports,
        }) });
        check.dependOn(&artifact.step);
        jobs_step.dependOn(&b.addRunArtifact(artifact).step);
    }
    const picotool_fixture = b.addExecutable(.{ .name = "picotool-job-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("packages/jobs/src/picotool_fixture.zig"),
        .target = b.graph.host,
    }) });
    const picotool_job_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/jobs/src/test_picotool_job.zig"),
        .target = b.graph.host,
        .imports = jobs_imports,
    }) });
    const picotool_job_options = b.addOptions();
    picotool_job_options.addOptionPath("fixture", picotool_fixture.getEmittedBin());
    picotool_job_options.addOptionPath("helper_path", job_fixture.getEmittedBin());
    picotool_job_tests.root_module.addOptions("options", picotool_job_options);
    check.dependOn(&picotool_job_tests.step);
    const test_picotool = b.step("test-picotool", "Run offline prepared-tool, frozen-artifact and controlled flash-job checks");
    test_picotool.dependOn(&b.addRunArtifact(picotool_job_tests).step);
    jobs_step.dependOn(test_picotool);
    const uf2_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/artifact/src/uf2.zig"),
        .target = b.graph.host,
    }) });
    check.dependOn(&uf2_tests.step);
    test_picotool.dependOn(&b.addRunArtifact(uf2_tests).step);
    const firmware = b.lazyDependency("zigmkay_firmware", .{}) orelse return;
    const api = b.lazyImport(@This(), "zigmkay_firmware") orelse return;
    if (@hasDecl(api, "flash_wrapper_contract_version") and api.flash_wrapper_contract_version == 1) {
        const wrapper_fixture = b.addExecutable(.{ .name = "firmware-wrapper-offline", .root_module = b.createModule(.{
            .root_source_file = firmware.path("zigmkay/tools/picotool_flash.zig"),
            .target = b.graph.host,
        }) });
        const tool_fixture = b.addExecutable(.{ .name = "firmware-picotool-offline", .root_module = b.createModule(.{
            .root_source_file = firmware.path("zigmkay/tools/picotool_fixture.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }) });
        picotool_job_options.addOptionPath("wrapper", wrapper_fixture.getEmittedBin());
        picotool_job_options.addOptionPath("picotool_fixture", tool_fixture.getEmittedBin());
    }
    const keycode_module = b.createModule(.{ .root_source_file = firmware.path("zkeycodes/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }} });
    @import("packages/keymap/build.zig").tests(b, firmware.module("zigmkay"), keycode_module, tests, check);
    const model = b.addModule("layout-model", .{
        .root_source_file = b.path("packages/layout-model/src/root.zig"),
        .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }},
    });
    @import("packages/importer/build.zig").add(b, firmware.module("zigmkay"), keycode_module, model);
    const processor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/processor_contract.zig"),
        .target = b.graph.host,
        .imports = &.{ .{ .name = "zigmkay", .module = firmware.module("zigmkay") }, .{ .name = "layout-model", .module = model } },
    }) });
    check.dependOn(&processor_tests.step);
    tests.dependOn(&b.addRunArtifact(processor_tests).step);
    const model_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/layout-model/src/root.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }},
    }) });
    check.dependOn(&model_tests.step);
    tests.dependOn(&b.addRunArtifact(model_tests).step);
    const catalog_tests = b.step("test-catalog", "Validate every selected firmware default and schematic geometry offline");
    const physical = b.createModule(.{ .root_source_file = b.path("packages/catalog/src/lk7_physical_layout.zig"), .imports = &.{.{ .name = "layout-model", .module = model }} });
    if (@hasDecl(api, "default_keymap_catalog_version")) {
        const defaults = firmware.module("default-keymaps");
        const catalog = b.addModule("catalog", .{ .root_source_file = b.path("packages/catalog/src/root.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "firmware-defaults", .module = defaults }, .{ .name = "layout-model", .module = model }, .{ .name = "lk7-physical", .module = physical } } });
        for (api.boards.entries, 0..) |board, index|
            catalog.addAnonymousImport(b.fmt("default-source-{d}", .{index}), .{ .root_source_file = firmware.path(b.fmt("keyboards/{s}", .{board.default_keymap})) });
        catalog.addAnonymousImport("janbeelte-shared-source", .{ .root_source_file = firmware.path("keyboards/my_keyboards/janbeelte/keymap_shared.zig") });
        const artifact = b.addTest(.{ .root_module = catalog });
        check.dependOn(&artifact.step);
        catalog_tests.dependOn(&b.addRunArtifact(artifact).step);
        tests.dependOn(catalog_tests);
    } else catalog_tests.dependOn(&b.addFail("Catalog requires the boundary board inventory; use the explicit local override until publication").step);
    const session_tests = b.step("test-session", "Run migrated session reducer regressions against firmware-owned codec");
    const runner_tests = b.step("test-runner", "Run extracted real-processor subprocess regression matrix offline");
    const project_build = b.step("build-project", "Build an explicit verified export into UF2 and native runner without device access");
    const hardware_client = b.step("prepare-hardware-client", "Compile/install explicit native HID acceptance client without device access");
    var project_module: ?*std.Build.Module = null;
    var import_fixtures: []const @import("packages/importer/fixtures.zig").Fixture = &.{};
    if (@hasDecl(api, "device_protocol_version")) {
        const protocol = b.addModule("device-protocol", .{
            .root_source_file = b.path("packages/firmware-adapter/src/protocol.zig"),
            .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }},
        });
        const keycodes = if (@hasDecl(api, "default_keymap_catalog_version")) firmware.module("default-keymaps").import_table.get("zkeycodes").? else b.createModule(.{ .root_source_file = firmware.path("zkeycodes/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }} });
        const input_source = @import("packages/input-source/build.zig").publish(b, b.path("packages/input-source"), keycodes, b.graph.host);
        tests.dependOn(input_source.tests);
        desktop_dependencies.dependOn(input_source.native_check);
        const text_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/text.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "layout-model", .module = model }, .{ .name = "input-source", .module = input_source.source } },
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(text_tests).step);
        check.dependOn(&text_tests.step);
        const default_profile = if (@hasDecl(api, "default_keymap_catalog_version")) b.createModule(.{
            .root_source_file = b.path("packages/firmware-adapter/src/curated_profile.zig"),
            .imports = &.{.{ .name = "firmware-defaults", .module = firmware.module("default-keymaps") }},
        }) else b.createModule(.{ .root_source_file = firmware.path("keyboards/my_keyboards/rollercole/shared_keymap_3x5_2.zig"), .imports = &.{ .{ .name = "zigmkay", .module = firmware.module("zigmkay") }, .{ .name = "zkeycodes", .module = keycodes } } });
        const project_imports: []const std.Build.Module.Import = &.{ .{ .name = "layout-model", .module = model }, .{ .name = "device-protocol", .module = protocol }, .{ .name = "rollercole-profile", .module = default_profile }, .{ .name = "lk7-physical", .module = physical }, .{ .name = "owned-zon", .module = owned_zon } };
        const project = b.addModule("project", .{ .root_source_file = b.path("packages/project/src/root.zig"), .imports = project_imports });
        project_module = project;
        const startup_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/startup_project.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "project", .module = project }},
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(startup_tests).step);
        check.dependOn(&startup_tests.step);
        const host_input_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/host_input.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "project", .module = project }},
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(host_input_tests).step);
        check.dependOn(&host_input_tests.step);
        const draft_input_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/draft_input.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "project", .module = project }},
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(draft_input_tests).step);
        check.dependOn(&draft_input_tests.step);
        const action_form_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/action_form.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "project", .module = project }},
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(action_form_tests).step);
        check.dependOn(&action_form_tests.step);
        const profile_preferences_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/profile_projects.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "project", .module = project }},
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(profile_preferences_tests).step);
        check.dependOn(&profile_preferences_tests.step);
        const label_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/labels.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "project", .module = project }, .{ .name = "layout-model", .module = model }, .{ .name = "zkeymap", .module = input_source.module }, .{ .name = "zkeycodes", .module = keycodes } },
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(label_tests).step);
        check.dependOn(&label_tests.step);
        const label_cache_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/label_cache.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "project", .module = project }, .{ .name = "layout-model", .module = model }, .{ .name = "zkeymap", .module = input_source.module }, .{ .name = "zkeycodes", .module = keycodes } },
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(label_cache_tests).step);
        check.dependOn(&label_cache_tests.step);
        const physical_view_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/physical_view.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "project", .module = project }, .{ .name = "layout-model", .module = model }, .{ .name = "zkeymap", .module = input_source.module }, .{ .name = "zkeycodes", .module = keycodes } },
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(physical_view_tests).step);
        check.dependOn(&physical_view_tests.step);
        const flash_runtime_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/flash_runtime.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "companion-jobs", .module = jobs }, .{ .name = "flash-controller", .module = flash_controller } },
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(flash_runtime_tests).step);
        check.dependOn(&flash_runtime_tests.step);
        const desktop_core = b.addModule("desktop-core", .{
            .root_source_file = b.path("packages/desktop/src/root.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "project", .module = project }, .{ .name = "layout-model", .module = model }, .{ .name = "zkeymap", .module = input_source.module }, .{ .name = "zkeycodes", .module = keycodes }, .{ .name = "input-source", .module = input_source.source }, .{ .name = "companion-jobs", .module = jobs } },
        });
        desktop_core.addImport("zqlite", zqlite);
        desktop_core.addImport("flash-controller", flash_controller);
        desktop_core.addImport("desktop-geometry", desktop_geometry);
        desktop_core.addImport("flash-presenter", flash_presenter);
        desktop_core.addImport("tray-lifecycle", tray_lifecycle);
        desktop_core.addImport("device-protocol", protocol);
        const event_history_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/event_history.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "device-protocol", .module = protocol }},
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(event_history_tests).step);
        check.dependOn(&event_history_tests.step);
        if (desktop_graph) |graph| {
            const physical_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/components/layout.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-fonts", .module = graph.fonts }, .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "layout-model", .module = model }, .{ .name = "zkeymap", .module = input_source.module } },
            });
            physical_ui.addImport("project", project);
            const physical_probe = b.addExecutable(.{ .name = "desktop-physical-smoke", .root_module = b.createModule(.{
                .root_source_file = b.path("tools/desktop_physical_smoke.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "physical-ui", .module = physical_ui }, .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "layout-model", .module = model } },
            }) });
            _ = physical_probe.getEmittedBin();
            physical_probe.root_module.addImport("project", project);
            physical_probe.root_module.addImport("zkeymap", input_source.module);
            physical_probe.root_module.addImport("input-source", input_source.source);
            const practice_ui = b.addModule("practice-ui", .{
                .root_source_file = b.path("packages/desktop/src/practice_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "physical-ui", .module = physical_ui }, .{ .name = "layout-model", .module = model } },
            });
            physical_probe.root_module.addImport("practice-ui", practice_ui);
            const action_form_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/action_form_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "project", .module = project }, .{ .name = "layout-model", .module = model } },
            });
            physical_probe.root_module.addImport("action-form-ui", action_form_ui);
            const action_drawer_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/action_drawer_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "action-form-ui", .module = action_form_ui } },
            });
            physical_probe.root_module.addImport("action-drawer-ui", action_drawer_ui);
            const inspector_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/inspector_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "editor-fonts", .module = graph.fonts }, .{ .name = "project", .module = project } },
            });
            physical_probe.root_module.addImport("inspector-ui", inspector_ui);
            const combo_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/combo_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "action-form-ui", .module = action_form_ui } },
            });
            physical_probe.root_module.addImport("combo-ui", combo_ui);
            const encoder_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/encoder_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "action-form-ui", .module = action_form_ui } },
            });
            const callback_ui = b.addModule("callback-ui", .{
                .root_source_file = b.path("packages/desktop/src/callback_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui } },
            });
            physical_probe.root_module.addImport("callback-ui", callback_ui);
            const layer_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/layer_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "project", .module = project } },
            });
            physical_probe.root_module.addImport("layer-ui", layer_ui);
            const host_palette_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/host_palette_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "editor-fonts", .module = graph.fonts } },
            });
            physical_probe.root_module.addImport("host-palette-ui", host_palette_ui);
            const keyboard_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/keyboard_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "editor-fonts", .module = graph.fonts }, .{ .name = "layout-model", .module = model } },
            });
            physical_probe.root_module.addImport("keyboard-ui", keyboard_ui);
            const toolbar_ui = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/toolbar_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui } },
            });
            physical_probe.root_module.addImport("toolbar-ui", toolbar_ui);
            const paths_ui = b.addModule("paths-ui", .{
                .root_source_file = b.path("packages/desktop/src/paths_ui.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "project", .module = project }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui } },
            });
            physical_probe.root_module.addImport("paths-ui", paths_ui);
            const editor_frame = b.addModule("editor-frame-ui", .{
                .root_source_file = b.path("packages/desktop/src/editor_frame.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "paths-ui", .module = paths_ui }, .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "toolbar-ui", .module = toolbar_ui }, .{ .name = "layer-ui", .module = layer_ui }, .{ .name = "keyboard-ui", .module = keyboard_ui }, .{ .name = "host-palette-ui", .module = host_palette_ui }, .{ .name = "inspector-ui", .module = inspector_ui }, .{ .name = "combo-ui", .module = combo_ui }, .{ .name = "callback-ui", .module = callback_ui } },
            });
            physical_probe.root_module.addImport("editor-frame-ui", editor_frame);
            editor_frame.addImport("encoder-ui", encoder_ui);
            if (b.modules.get("catalog")) |catalog| {
                const frame_tests = b.addTest(.{ .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/editor_frame.zig"),
                    .target = b.graph.host,
                    .imports = &.{ .{ .name = "paths-ui", .module = paths_ui }, .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "project", .module = project }, .{ .name = "catalog", .module = catalog }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "dvui_backend", .module = graph.backend }, .{ .name = "editor-frame-ui", .module = editor_frame }, .{ .name = "zkeymap", .module = input_source.module } },
                }) });
                const run_frames = b.addRunArtifact(frame_tests);
                run_frames.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
                run_frames.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
                b.step("test-editor-frame", "Run explicit offline SDL dummy/software editor interaction fixtures").dependOn(&run_frames.step);
            }
            const draft_input_native = b.addModule("native-draft-input", .{
                .root_source_file = b.path("packages/desktop/src/draft_input_native.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "dvui_backend", .module = graph.backend } },
            });
            physical_probe.root_module.addImport("native-draft-input", draft_input_native);
            physical_probe.root_module.addImport("dvui_backend", graph.backend);
            physical_probe.root_module.addImport("editor-ui", graph.ui);
            const physical_options = b.addOptions();
            physical_options.addOption(bool, "vectors", graph.icons != null);
            physical_probe.root_module.addOptions("desktop-audit-options", physical_options);
            if (graph.icons) |icons| {
                physical_probe.root_module.addImport("desktop-icons", icons);
                const resources = b.createModule(.{
                    .root_source_file = b.path("packages/desktop/src/icon_resources.zig"),
                    .target = b.graph.host,
                    .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "icons", .module = icons }, .{ .name = "svg2tvg", .module = graph.vectors.? } },
                });
                physical_probe.root_module.addImport("icon-resources", resources);
                const resource_tests = b.addTest(.{ .root_module = resources });
                b.step("test-desktop-icon-resources", "Validate every retained icon mapping and owned resolver without a GUI").dependOn(&b.addRunArtifact(resource_tests).step);
            }
            desktop_dependencies.dependOn(&physical_probe.step);
            const key_renderer_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/components/key.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-fonts", .module = graph.fonts }, .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "layout-model", .module = model }, .{ .name = "zkeymap", .module = input_source.module } },
            }) });
            const renderer_tests = b.step("test-desktop-renderers", "Run retained pure key-renderer fixtures with explicit desktop source inputs");
            renderer_tests.dependOn(&b.addRunArtifact(key_renderer_tests).step);
        }
        const desktop_integration_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/desktop_integration.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "project", .module = project }, .{ .name = "companion-jobs", .module = jobs } },
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(desktop_integration_tests).step);
        desktop_integration_tests.root_module.addOptions("options", picotool_job_options);
        check.dependOn(&desktop_integration_tests.step);
        const editor_model_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/model.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "project", .module = project }},
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(editor_model_tests).step);
        check.dependOn(&editor_model_tests.step);
        const inspector_session_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/desktop/src/inspector_session.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "project", .module = project }, .{ .name = "layout-model", .module = model } },
        }) });
        desktop_tests_step.dependOn(&b.addRunArtifact(inspector_session_tests).step);
        check.dependOn(&inspector_session_tests.step);
        if (b.modules.get("catalog")) |catalog| {
            const catalog_view_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/catalog_physical_view.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "catalog", .module = catalog } },
            }) });
            desktop_tests_step.dependOn(&b.addRunArtifact(catalog_view_tests).step);
            check.dependOn(&catalog_view_tests.step);
            const catalog_project = b.addModule("catalog-project", .{
                .root_source_file = b.path("packages/firmware-adapter/src/catalog_project.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "catalog", .module = catalog }, .{ .name = "project", .module = project }, .{ .name = "layout-model", .module = model } },
            });
            const adapter_tests = b.addTest(.{ .root_module = catalog_project });
            const importer = b.addModule("keymap-importer", .{ .root_source_file = b.path("packages/importer/src/root.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "project", .module = project }, .{ .name = "catalog-project", .module = catalog_project }, .{ .name = "catalog", .module = catalog }, .{ .name = "layout-model", .module = model }, .{ .name = "companion-jobs", .module = jobs } } });
            desktop_core.addImport("keymap-importer", importer);
            const onboarding_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/onboarding.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "project", .module = project } } }) });
            const onboarding_step = b.step("test-onboarding", "Validate all-board project creation, portable collections and cancellation offline");
            onboarding_step.dependOn(&b.addRunArtifact(onboarding_tests).step);
            check.dependOn(&onboarding_tests.step);
            tests.dependOn(onboarding_step);
            const importer_tests = b.addTest(.{ .root_module = importer });
            const importer_options = b.addOptions();
            importer_options.addOption([]const u8, "repository", b.root.toString(b.allocator) catch @panic("OOM"));
            importer_options.addOption([]const u8, "compiler", b.graph.zig_exe);
            importer_options.addOptionPathUntracked("packages", b.path("zig-pkg"));
            importer_options.addOptionPathUntracked("compiler_cache", .{ .relative = .{ .base = .global_cache } });
            importer.addOptions("test-options", importer_options);
            const import_tests = b.step("test-import", "Validate one-way import, archive bounds and destination ownership offline");
            import_tests.dependOn(&b.addRunArtifact(importer_tests).step);
            tests.dependOn(import_tests);
            check.dependOn(&importer_tests.step);
            const bundle_check = b.addExecutable(.{ .name = "check-application-bundle", .root_module = b.createModule(.{
                .root_source_file = b.path("tools/check_application_bundle.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "project", .module = project }, .{ .name = "catalog-project", .module = catalog_project }, .{ .name = "companion-jobs", .module = jobs }, .{ .name = "catalog-inventory", .module = catalog } },
            }) });
            for ([_][]const u8{ "us", "de" }) |name| {
                bundle_check.root_module.addAnonymousImport(b.fmt("import-{s}", .{name}), .{ .root_source_file = b.path(b.fmt("tests/fixtures/import/{s}/src/keymap.zig", .{name})) });
                bundle_check.root_module.addAnonymousImport(b.fmt("import-{s}-manifest", .{name}), .{ .root_source_file = b.path(b.fmt("tests/fixtures/import/{s}/build.zig.zon", .{name})) });
            }
            const install_check = b.addInstallArtifact(bundle_check, .{});
            b.step("build-bundle-check", "Build the offline application acceptance utility").dependOn(&install_check.step);
            const flash_session_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("apps/desktop/flash_session.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "companion-jobs", .module = jobs }, .{ .name = "project", .module = project } },
            }) });
            const flash_session_step = b.step("test-desktop-flash-session", "Test offline editor flash admission and confirmation gates");
            flash_session_step.dependOn(&b.addRunArtifact(flash_session_tests).step);
            const bootloader_gate_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("apps/desktop/flash_bootloader.zig"),
                .target = b.graph.host,
            }) });
            flash_session_step.dependOn(&b.addRunArtifact(bootloader_gate_tests).step);
            const flash_dispatch_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("apps/desktop/flash_fixture.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "project", .module = project } },
            }) });
            flash_session_step.dependOn(&b.addRunArtifact(flash_dispatch_tests).step);
            tests.dependOn(flash_session_step);
            check.dependOn(&flash_session_tests.step);
            check.dependOn(&bootloader_gate_tests.step);
            check.dependOn(&flash_dispatch_tests.step);
            if (desktop_graph) |graph| {
                const onboarding_ui = b.createModule(.{ .root_source_file = b.path("packages/desktop/src/onboarding_ui.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "project", .module = project }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "editor-ui", .module = graph.ui } } });
                const onboarding_state_tests = b.addTest(.{ .root_module = onboarding_ui });
                b.step("test-onboarding-state", "Reject stale wizard settings and project ownership without filesystem publication").dependOn(&b.addRunArtifact(onboarding_state_tests).step);
                const installed_paths = b.createModule(.{ .root_source_file = b.path("packages/platform/src/app_paths.zig"), .target = b.graph.host });
                const app = b.addExecutable(.{ .name = "zigmkay-companion", .root_module = b.createModule(.{
                    .root_source_file = b.path("apps/desktop/main.zig"),
                    .target = b.graph.host,
                    .imports = &.{ .{ .name = "callback-ui", .module = b.modules.get("callback-ui").? }, .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "project", .module = project }, .{ .name = "catalog-project", .module = catalog_project }, .{ .name = "dvui", .module = graph.dvui }, .{ .name = "dvui_backend", .module = graph.backend }, .{ .name = "native-events", .module = graph.events }, .{ .name = "folder-dialog", .module = graph.folder_dialog }, .{ .name = "editor-fonts", .module = graph.fonts }, .{ .name = "editor-frame-ui", .module = b.modules.get("editor-frame-ui").? }, .{ .name = "paths-ui", .module = b.modules.get("paths-ui").? }, .{ .name = "input-source", .module = input_source.source }, .{ .name = "zkeymap", .module = input_source.module } },
                }) });
                app.root_module.addImport("companion-jobs", jobs);
                const assemble_step = b.step("bundle-application", "Assemble the complete offline application");
                if (application_bundle) {
                    // The firmware root forwards this output before its lazy
                    // tool dependency exists on a clean machine. Resolve the
                    // tool package first and let Zig finish acquisition.
                    const flash_dep = firmware.builder.dependency("zigmkay", .{ .@"flash-tools" = true });
                    if (b.graph.needed_lazy_dependencies.count() != 0) return;
                    // Configure every supported target so Zig acquires build-time
                    // lazy inputs before the offline resource closure is copied.
                    const mz = b.lazyImport(@This(), "microzig") orelse return;
                    const mz_dep = b.lazyDependency("microzig", .{}) orelse return;
                    const MicroBuild = mz.MicroBuild(.{ .rp2xxx = true });
                    const mb = MicroBuild.init(b, mz_dep) orelse return;
                    const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
                    for (api.boards.entries) |board| {
                        const item = api.addKeyboardFirmware(b, mb, &target, .safe, b.fmt("bundle-contract-{s}", .{board.name}), board, .{
                            .keyboards = firmware.path("keyboards"),
                            .processor = firmware.path("zigmkay/src/root.zig"),
                            .keycodes = firmware.path("zkeycodes/root.zig"),
                            .companion_enabled = true,
                        }, null);
                        _ = item.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } });
                    }
                    const assembler = b.addExecutable(.{ .name = "assemble-application", .root_module = b.createModule(.{
                        .root_source_file = b.path("tools/assemble_application.zig"),
                        .target = b.graph.host,
                        .imports = &.{.{ .name = "companion-jobs", .module = jobs }},
                    }) });
                    const manifest = @import("build.zig.zon");
                    var manifest_text: std.Io.Writer.Allocating = .init(b.allocator);
                    std.zon.stringify.serialize(.{
                        .name = manifest.name,
                        .fingerprint = manifest.fingerprint,
                        .version = manifest.version,
                        .minimum_zig_version = manifest.minimum_zig_version,
                        .dependencies = .{ .zigmkay_firmware = manifest.dependencies.zigmkay_firmware, .microzig = manifest.dependencies.microzig },
                        .paths = .{ "build.zig", "build.zig.zon", "packages" },
                    }, .{}, &manifest_text.writer) catch @panic("Cannot write runtime manifest");
                    const pins = b.addOptions();
                    pins.addOption([]const []const u8, "license_hashes", &.{ manifest.dependencies.dvui.hash, manifest.dependencies.ztray.hash, manifest.dependencies.zqlite.hash, manifest.dependencies.svg2tvg.hash, manifest.dependencies.icons.hash });
                    pins.addOption([]const u8, "manifest", manifest_text.written());
                    pins.addOption([]const u8, "firmware_hash", manifest.dependencies.zigmkay_firmware.hash);
                    pins.addOption([]const u8, "microzig_hash", manifest.dependencies.microzig.hash);
                    pins.addOption([]const u8, "firmware_revision", manifest.dependencies.zigmkay_firmware.url[std.mem.lastIndexOfScalar(u8, manifest.dependencies.zigmkay_firmware.url, '#').? + 1 ..]);
                    assembler.root_module.addOptions("bundle-pins", pins);
                    const assemble = b.addRunArtifact(assembler);
                    assemble.has_side_effects = true;
                    assemble.addDirectoryArg2(b.path("."), .{ .make_absolute = true });
                    assemble.addFileArg2(.zig_exe, .{ .make_absolute = true });
                    assemble.addDirectoryArg2(b.path("zig-pkg"), .{ .make_absolute = true });
                    const application = assemble.addOutputDirectoryArg2("Zigmkay.app", .{ .make_absolute = true });
                    assemble.addArtifactArg(app);
                    assemble.addArtifactArg(flash_dep.artifact("picotool_flash"));
                    assemble.addFileArg2(flash_dep.namedLazyPath("picotool"), .{ .make_absolute = true });
                    if (b.graph.host.result.os.tag == .windows) {
                        assemble_step.dependOn(&b.addInstallFile(application.path(b, "Zigmkay.exe"), "Zigmkay.exe").step);
                    } else {
                        const install_bundle = b.addInstallDirectory(.{ .source_dir = application, .install_dir = .prefix, .install_subdir = "Zigmkay.app" });
                        assemble_step.dependOn(&install_bundle.step);
                    }
                } else assemble_step.dependOn(&b.addFail("Pass application-bundle=true to assemble the complete application").step);

                app.root_module.addImport("flash-ui", b.createModule(.{ .root_source_file = b.path("packages/desktop/src/flash_ui.zig"), .imports = &.{ .{ .name = "dvui", .module = graph.dvui }, .{ .name = "flash-presenter", .module = flash_presenter } } }));
                app.root_module.addImport("app-paths", installed_paths);
                app.root_module.addImport("native-tray", graph.tray);
                const companion_ui = b.createModule(.{
                    .root_source_file = b.path("packages/desktop/src/companion_ui.zig"),
                    .target = b.graph.host,
                    .imports = &.{ .{ .name = "dvui", .module = graph.dvui }, .{ .name = "desktop-core", .module = desktop_core }, .{ .name = "layout-model", .module = model }, .{ .name = "editor-ui", .module = graph.ui }, .{ .name = "editor-fonts", .module = graph.fonts } },
                });
                app.root_module.addImport("companion-ui", companion_ui);
                const companion_window = b.createModule(.{ .root_source_file = b.path("packages/platform/src/companion_window.zig"), .target = b.graph.host, .imports = &.{.{ .name = "dvui_backend", .module = graph.backend }} });
                app.root_module.addImport("companion-window", companion_window);
                const overlay_tests = b.addTest(.{ .root_module = companion_window });
                b.step("test-companion-placement", "Validate optional overlay bounds without creating a window").dependOn(&b.addRunArtifact(overlay_tests).step);
                app.root_module.addImport("onboarding-ui", onboarding_ui);
                desktop_app = app;
                app.root_module.addImport("practice-ui", b.modules.get("practice-ui").?);
                app.root_module.addImport("editor-ui", graph.ui);
                app.root_module.addImport("native-draft-input", b.modules.get("native-draft-input").?);
                b.step("build-desktop", "Compile the native companion without launching or accessing devices").dependOn(&app.step);
                const installed_executable: std.Build.LazyPath = .{ .relative = .{ .base = .install_prefix, .sub_path = if (b.graph.host.result.os.tag == .windows) "Zigmkay.exe" else "Zigmkay.app/Contents/MacOS/zigmkay-companion" } };
                const run_desktop = std.Build.Step.Run.create(b, "run bundled editor");
                run_desktop.addFileArg2(installed_executable, .{ .make_absolute = true });
                run_desktop.step.dependOn(assemble_step);
                run_desktop.addPassthruArgs();
                b.step("run-desktop", "Launch the native editor with automatic keyboard monitoring; flashing remains explicit").dependOn(&run_desktop.step);
                const run_companion = std.Build.Step.Run.create(b, "run bundled companion");
                run_companion.addFileArg2(installed_executable, .{ .make_absolute = true });
                run_companion.step.dependOn(assemble_step);
                run_companion.addArg("--background");
                b.step("run-companion", "Start the resident companion with windows hidden and automatic keyboard monitoring").dependOn(&run_companion.step);
                b.step("build-companion", "Compile the resident companion entry point without launching").dependOn(&app.step);
                const launch_fixture = b.addRunArtifact(app);
                launch_fixture.addArgs(&.{ "--offline-frames", "3" });
                launch_fixture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
                launch_fixture.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
                b.step("test-desktop-launch", "Launch bounded dummy/software frames without native source or device access").dependOn(&launch_fixture.step);
                for ([_]struct { flag: []const u8, frames: []const u8, step: []const u8 }{ .{ .flag = "--offline-onboarding-frames", .frames = "24", .step = "test-desktop-onboarding" }, .{ .flag = "--offline-catalog-frames", .frames = "56", .step = "test-desktop-catalog" } }) |fixture| {
                    const run = b.addRunArtifact(app);
                    run.addArgs(&.{ fixture.flag, fixture.frames });
                    run.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
                    run.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
                    b.step(fixture.step, "Validate keyboard onboarding/catalog native UI without devices").dependOn(&run.step);
                }
                const status_fixture = b.addRunArtifact(app);
                status_fixture.addArgs(&.{ "--offline-status-frames", "24" });
                status_fixture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
                status_fixture.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
                b.step("test-desktop-status", "Check editor activity bounds and capture build, Flash and error states offline").dependOn(&status_fixture.step);
                const practice_fixture = b.addRunArtifact(app);
                practice_fixture.addArgs(&.{ "--offline-practice-frames", "3" });
                practice_fixture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
                practice_fixture.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
                b.step("test-desktop-practice", "Route injected OS text through bounded dummy/software tutor frames").dependOn(&practice_fixture.step);
                const rundown_fixture = b.addRunArtifact(app);
                rundown_fixture.addArgs(&.{ "--offline-rundown-frames", "20" });
                rundown_fixture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
                rundown_fixture.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
                const rundown_step = b.step("test-desktop-rundown", "Exercise tutor results, scope variants and assistance; capture offline screenshots in cache");
                rundown_step.dependOn(&rundown_fixture.step);
                const companion_fixture = b.addRunArtifact(app);
                companion_fixture.addArgs(&.{ "--offline-companion-frames", "9" });
                companion_fixture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
                companion_fixture.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
                b.step("test-desktop-companion", "Verify independent companion close and resident draft retention without installing a tray or accessing hardware").dependOn(&companion_fixture.step);
                const source_refresh_fixture = b.addRunArtifact(app);
                source_refresh_fixture.addArgs(&.{ "--offline-source-refresh-frames", "3" });
                source_refresh_fixture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
                source_refresh_fixture.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
                b.step("test-desktop-source-refresh", "Verify translated running captions, draft isolation and atomic replacement without native source or device access").dependOn(&source_refresh_fixture.step);
                const tray_fixture = b.addRunArtifact(app);
                tray_fixture.addArgs(&.{ "--native-tray-frames", "3" });
                b.step("test-native-tray", "Explicit bounded native tray install/menu/shutdown with a hidden window and no device access").dependOn(&tray_fixture.step);
            }
            check.dependOn(&adapter_tests.step);
            catalog_tests.dependOn(&b.addRunArtifact(adapter_tests).step);
            const catalog_export = b.addExecutable(.{ .name = "catalog-export", .root_module = b.createModule(.{
                .root_source_file = b.path("tools/catalog_export.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "catalog-project", .module = catalog_project }, .{ .name = "project", .module = project } },
            }) });
            check.dependOn(&catalog_export.step);
            const catalog_processors = b.step("test-catalog-processors", "Export every selected board and exercise every index through its real processor offline");
            const default_processors = b.step("test-catalog-defaults", "Export actual defaults and compare selected real-processor output, layers and callbacks offline");
            for (api.boards.entries, 0..) |board, index| {
                const generate = b.addRunArtifact(catalog_export);
                generate.addArg(board.name);
                const directory = generate.addOutputDirectoryArg2(board.name, .{ .make_absolute = true });
                const generated_profile = b.createModule(.{
                    .root_source_file = directory.path(b, "keymap.zig"),
                    .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }},
                });
                const processor = b.addTest(.{ .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/catalog_processor_contract.zig"),
                    .target = b.graph.host,
                    .imports = &.{ .{ .name = "generated-profile", .module = generated_profile }, .{ .name = "zigmkay", .module = firmware.module("zigmkay") } },
                }) });
                catalog_processors.dependOn(&b.addRunArtifact(processor).step);
                const default_generate = b.addRunArtifact(catalog_export);
                default_generate.addArg(board.name);
                const default_directory = default_generate.addOutputDirectoryArg2(b.fmt("default-{s}", .{board.name}), .{ .make_absolute = true });
                default_generate.addArg("--default");
                const exported_default = b.createModule(.{
                    .root_source_file = default_directory.path(b, "keymap.zig"),
                    .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }},
                });
                const callback = b.createModule(.{
                    .root_source_file = default_directory.path(b, b.fmt("callback_0/{s}", .{board.default_keymap})),
                    .imports = &.{ .{ .name = "zigmkay", .module = firmware.module("zigmkay") }, .{ .name = "zkeycodes", .module = keycodes } },
                });
                // Callback-free defaults never import this lazy module.
                exported_default.addImport("callback_0", callback);
                const options = b.addOptions();
                options.addOption(usize, "index", index);
                const default_test = b.addTest(.{ .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/catalog_default_processor_contract.zig"),
                    .target = b.graph.host,
                    .imports = &.{ .{ .name = "generated-profile", .module = exported_default }, .{ .name = "firmware-defaults", .module = firmware.module("default-keymaps") }, .{ .name = "zigmkay", .module = firmware.module("zigmkay") }, .{ .name = "catalog-options", .module = options.createModule() } },
                }) });
                default_processors.dependOn(&b.addRunArtifact(default_test).step);
            }
            tests.dependOn(catalog_processors);
            tests.dependOn(default_processors);
            const export_run = b.addRunArtifact(catalog_export);
            export_run.addPassthruArgs();
            b.step("export-catalog-fixture", "Explicit synthetic indexed board export; no physical mapping claim").dependOn(&export_run.step);
        }
        const runner_protocol = b.addModule("runner-protocol", .{
            .root_source_file = b.path("packages/runner/src/protocol.zig"),
            .imports = &.{ .{ .name = "zigmkay", .module = firmware.module("zigmkay") }, .{ .name = "owned-zon", .module = owned_zon } },
        });
        const processor_fixture = @import("packages/runner/build.zig").tests(b, runner_tests, check, firmware.module("zigmkay"), project, default_profile, jobs, runner_protocol, owned_zon);
        const native_step = b.step("build-runner", "Build a native tutor runner without preparing embedded firmware");
        if (b.modules.get("keymap-importer")) |importer| import_fixtures = @import("packages/importer/fixtures.zig").add(b, importer, project, firmware.module("zigmkay"), keycodes, model, runner_protocol);
        if (native_only and selected_export != null) {
            const selected = @import("packages/project/src/build_input.zig").load(b, selected_export.?, firmware.module("zigmkay"), keycodes, model) catch |err| @panic(@errorName(err));
            const native_runner = @import("packages/runner/build.zig").runner(b, "project-runner", firmware.module("zigmkay"), selected.module, runner_protocol, selected.snapshot_id);
            native_step.dependOn(&b.addInstallArtifact(native_runner, .{}).step);
        } else native_step.dependOn(&b.addFail("build-runner requires native-only=true and an absolute project-export").step);
        if (desktop_app) |app| {
            const manifest_fixture = b.addExecutable(.{ .name = "runner-manifest-fixture", .root_module = b.createModule(.{
                .root_source_file = b.path("packages/runner/src/manifest_fixture.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "project", .module = project }, .{ .name = "companion-jobs", .module = jobs } },
            }) });
            const prepare_manifest = b.addRunArtifact(manifest_fixture);
            prepare_manifest.addArtifactArg(processor_fixture);
            const runner_manifest = prepare_manifest.addOutputFileArg("runner-manifest.zon");
            const draft_fixture = b.addRunArtifact(app);
            draft_fixture.addArgs(&.{ "--offline-draft-frames", "600" });
            draft_fixture.addFileArg2(runner_manifest, .{ .make_absolute = true });
            draft_fixture.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
            draft_fixture.setEnvironmentVariable("SDL_RENDER_DRIVER", "software");
            b.step("test-desktop-draft", "Run explicit SDL dummy draft scoring through the real native processor").dependOn(&draft_fixture.step);
        }
        tests.dependOn(runner_tests);
        project.addAnonymousImport("rollercole-source", .{ .root_source_file = firmware.path("keyboards/my_keyboards/rollercole/shared_keymap_3x5_2.zig") });
        const cli = b.addExecutable(.{ .name = "keymap-project", .root_module = b.createModule(.{
            .root_source_file = b.path("packages/project/src/main.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "keymap-project", .module = project }},
        }) });
        check.dependOn(&cli.step);
        const cli_run = b.addRunArtifact(cli);
        cli_run.addPassthruArgs();
        b.step("run-project", "Explicit project create/validate/export command").dependOn(&cli_run.step);
        const project_test_module = b.createModule(.{ .root_source_file = b.path("packages/project/src/root.zig"), .target = b.graph.host, .imports = project_imports });
        project_test_module.addAnonymousImport("rollercole-source", .{ .root_source_file = firmware.path("keyboards/my_keyboards/rollercole/shared_keymap_3x5_2.zig") });
        const project_tests = b.addTest(.{ .root_module = project_test_module });
        check.dependOn(&project_tests.step);
        const project_step = b.step("test-project", "Test schema, source snapshots, deterministic export and actual processor");
        project_step.dependOn(&b.addRunArtifact(project_tests).step);
        const historical_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/project/src/test_historical_callbacks.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "project", .module = project }},
        }) });
        historical_tests.root_module.addAnonymousImport("historical-rollercole-source", .{ .root_source_file = b.path("tests/fixtures/historical/rollercole-0.16.zig.txt") });
        check.dependOn(&historical_tests.step);
        project_step.dependOn(&b.addRunArtifact(historical_tests).step);
        tests.dependOn(project_step);
        const generator = b.addExecutable(.{ .name = "export-compile-fixture", .root_module = b.createModule(.{
            .root_source_file = b.path("packages/project/src/export_fixture.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "keymap-project", .module = project }},
        }) });
        const exported = b.addRunArtifact(generator).addOutputFileArg("keymap.zig");
        const exported_profile = b.createModule(.{ .root_source_file = exported, .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }} });
        const export_test = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/project/src/export_compile_test.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "generated-profile", .module = exported_profile }, .{ .name = "zigmkay", .module = firmware.module("zigmkay") }, .{ .name = "device-protocol", .module = protocol } },
        }) });
        project_step.dependOn(&b.addRunArtifact(export_test).step);
        const imports: []const std.Build.Module.Import = &.{ .{ .name = "layout-model", .module = model }, .{ .name = "device-protocol", .module = protocol } };
        const session = b.addModule("session", .{ .root_source_file = b.path("packages/session/src/root.zig"), .imports = imports });
        {
            desktop_core.addImport("session", session);
            const live_frame_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("packages/desktop/src/live_keyboard.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "session", .module = session }, .{ .name = "device-protocol", .module = protocol }, .{ .name = "layout-model", .module = model }, .{ .name = "project", .module = project }, .{ .name = "zkeymap", .module = desktop_core.import_table.get("zkeymap").? }, .{ .name = "zkeycodes", .module = desktop_core.import_table.get("zkeycodes").? } },
            }) });
            desktop_tests_step.dependOn(&b.addRunArtifact(live_frame_tests).step);
            check.dependOn(&live_frame_tests.step);
        }
        const live = b.addModule("live-adapter", .{ .root_source_file = b.path("packages/session/src/live_adapter.zig"), .imports = &.{
            .{ .name = "device-protocol", .module = protocol }, .{ .name = "companion-model", .module = session },
        } });
        const native = b.addModule("native-hid", .{ .root_source_file = b.path("packages/platform/src/native_hid.zig"), .imports = &.{.{ .name = "live-adapter", .module = live }} });
        if (desktop_app) |app| {
            app.root_module.addImport("native-hid", native);
            app.root_module.addImport("live-adapter", live);
        }
        if (b.option(bool, "native-hid", "Prepare pinned SDL native acceptance dependencies") orelse false) {
            const dvui = @import("packages/platform/desktop_build.zig").dependency(b, false) orelse return;
            const probe = b.addExecutable(.{ .name = "usb-acceptance", .root_module = b.createModule(.{
                .root_source_file = b.path("tools/usb_acceptance.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "native-hid", .module = native },
                    .{ .name = "live-adapter", .module = live },
                    .{ .name = "device-protocol", .module = protocol },
                    .{ .name = "dvui_backend", .module = dvui.module("sdl3") },
                },
            }) });
            hardware_client.dependOn(&b.addInstallArtifact(probe, .{}).step);
        } else hardware_client.dependOn(&b.addFail("Pass -Dnative-hid=true to prepare the native client; preparation never runs it").step);
        const native_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/platform/src/test_native_hid.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "native-hid", .module = native }},
        }) });
        check.dependOn(&native_tests.step);
        session_tests.dependOn(&b.addRunArtifact(native_tests).step);
        for ([_][]const u8{ "root.zig", "test_legacy.zig", "test_session.zig", "live_adapter.zig", "session_capture.zig" }) |file| {
            const module = b.createModule(.{ .root_source_file = b.path(b.fmt("packages/session/src/{s}", .{file})), .target = b.graph.host, .imports = imports });
            if (!std.mem.eql(u8, file, "root.zig")) module.addImport("companion-model", session);
            const artifact = b.addTest(.{ .root_module = module });
            check.dependOn(&artifact.step);
            session_tests.dependOn(&b.addRunArtifact(artifact).step);
        }
        tests.dependOn(session_tests);
    } else {
        runner_tests.dependOn(&b.addFail("Runner acceptance requires the explicit local boundary override until S12 publication").step);
        hardware_client.dependOn(&b.addFail("Native acceptance requires firmware-owned codec; use the explicit --fork development override").step);
        session_tests.dependOn(&b.addFail("Pinned EuroZig candidate lacks the firmware-owned codec; use the explicit documented --fork development override").step);
    }
    const firmware_check = b.step("firmware-check", "Compile generated LK7, split and encoder keymaps (explicit preparation)");
    const catalog_firmware = b.step("catalog-firmware-check", "Compile all selected boards with schema-1 synthetic indexed exports offline");
    const imported_firmware = b.step("import-firmware-check", "Compile both pinned imports for Keycaprio 0.6 and 0.7 without devices");
    const candidate = b.step("prepare-usb-candidate", "Prepare offline LK7 telemetry UF2 and identity/hash inventory");
    if (prepare_firmware) {
        if (@hasDecl(api, "addKeyboardFirmware")) {
            const mz = b.lazyImport(@This(), "microzig") orelse return;
            const mz_dep = b.lazyDependency("microzig", .{}) orelse return;
            const MicroBuild = mz.MicroBuild(.{ .rp2xxx = true });
            const mb = MicroBuild.init(b, mz_dep) orelse return;
            const target = mb.ports.rp2xxx.boards.raspberrypi.pico.*;
            if (prepare_imports) {
                for (import_fixtures) |fixture| {
                    const board = api.boards.find(fixture.selector).?;
                    const item = api.addKeyboardFirmware(b, mb, &target, .ReleaseSafe, "imported", board, .{ .keyboards = firmware.path("keyboards"), .processor = firmware.path("zigmkay/src/root.zig"), .keycodes = firmware.path("zkeycodes/root.zig"), .companion_enabled = true }, null);
                    const processor = item.exe.root_module.import_table.get("zigmkay").?;
                    const keycodes = item.exe.root_module.import_table.get("zkeycodes").?;
                    const embedded_model = b.createModule(.{ .root_source_file = b.path("packages/layout-model/src/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = processor }} });
                    const selected = @import("packages/importer/fixtures.zig").module(b, fixture.export_root, processor, keycodes, embedded_model);
                    selected.addImport("microzig", item.core_mod);
                    item.add_app_import("keymap", selected, .{});
                    imported_firmware.dependOn(&item.exe.step);
                }
            }
            if (prepare_catalog) {
                const catalog_project = b.modules.get("catalog-project") orelse @panic("Catalog firmware check requires the board inventory");
                const exporter = b.addExecutable(.{ .name = "catalog-firmware-export", .root_module = b.createModule(.{
                    .root_source_file = b.path("tools/catalog_export.zig"),
                    .target = b.graph.host,
                    .imports = &.{ .{ .name = "catalog-project", .module = catalog_project }, .{ .name = "project", .module = project_module.? } },
                }) });
                const matrix = b.addWriteFiles();
                for (api.boards.entries) |board| {
                    const generate = b.addRunArtifact(exporter);
                    generate.addArg(board.name);
                    const directory = generate.addOutputDirectoryArg2(board.name, .{ .make_absolute = true });
                    if (actual_defaults) generate.addArg("--default");
                    const item = api.addKeyboardFirmware(b, mb, &target, .ReleaseSafe, b.fmt("catalog-{s}", .{board.name}), board, .{
                        .keyboards = firmware.path("keyboards"),
                        .processor = firmware.path("zigmkay/src/root.zig"),
                        .keycodes = firmware.path("zkeycodes/root.zig"),
                        .companion_enabled = true,
                    }, directory.path(b, "keymap.zig"));
                    if (actual_defaults) {
                        const callback = b.createModule(.{
                            .root_source_file = directory.path(b, b.fmt("callback_0/{s}", .{board.default_keymap})),
                            .imports = &.{ .{ .name = "zigmkay", .module = item.exe.root_module.import_table.get("zigmkay").? }, .{ .name = "zkeycodes", .module = item.exe.root_module.import_table.get("zkeycodes").? } },
                        });
                        item.exe.root_module.import_table.get("keymap").?.addImport("callback_0", callback);
                    }
                    _ = matrix.addCopyFile(item.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } }), b.fmt("{s}.uf2", .{board.name}));
                }
                catalog_firmware.dependOn(&matrix.step);
            } else catalog_firmware.dependOn(&b.addFail("Pass catalog-check=true and firmware-check=true to prepare the all-board matrix").step);
            if (b.option(bool, "project-build", "Compile an explicitly verified project export") orelse false) {
                const export_path = selected_export orelse @panic("project-build requires project-export");
                const board_name = selected_board orelse @panic("project-build requires project-board");
                const board = api.boards.find(board_name) orelse @panic("Unknown firmware board selector");
                const selector = @import("packages/project/src/build_input.zig");
                const keycodes = b.createModule(.{ .root_source_file = firmware.path("zkeycodes/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }} });
                const native_selected = selector.load(b, export_path, firmware.module("zigmkay"), keycodes, model) catch |err| @panic(b.fmt("Cannot verify native export: {s}", .{@errorName(err)}));
                const sources: api.FirmwareSources = .{
                    .keyboards = firmware.path("keyboards"),
                    .processor = firmware.path("zigmkay/src/root.zig"),
                    .keycodes = firmware.path("zkeycodes/root.zig"),
                    .companion_enabled = true,
                };
                const item = api.addKeyboardFirmware(b, mb, &target, .ReleaseSafe, "project", board, sources, null);
                const embedded_processor = item.exe.root_module.import_table.get("zigmkay").?;
                const embedded_keycodes = item.exe.root_module.import_table.get("zkeycodes").?;
                const embedded_model = b.createModule(.{ .root_source_file = b.path("packages/layout-model/src/root.zig"), .imports = &.{.{ .name = "zigmkay", .module = embedded_processor }} });
                const embedded_selected = selector.load(b, export_path, embedded_processor, embedded_keycodes, embedded_model) catch |err| @panic(b.fmt("Cannot verify embedded export: {s}", .{@errorName(err)}));
                embedded_selected.module.addImport("microzig", item.core_mod);
                item.add_app_import("keymap", embedded_selected.module, .{});
                const install = b.addInstallFile(item.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } }), "firmware/project.uf2");
                project_build.dependOn(&install.step);
                const native_runner = @import("packages/runner/build.zig").runner(b, "project-runner", firmware.module("zigmkay"), native_selected.module, b.modules.get("runner-protocol").?, native_selected.snapshot_id);
                project_build.dependOn(&b.addInstallArtifact(native_runner, .{}).step);
            } else project_build.dependOn(&b.addFail("Pass project-build=true with absolute project-export and project-board inputs").step);
            const generated = b.addWriteFiles();
            const artifacts = b.addWriteFiles();
            const project_generator = b.addExecutable(.{ .name = "export-board-fixture", .root_module = b.createModule(.{
                .root_source_file = b.path("packages/project/src/board_export_fixture.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "keymap-project", .module = project_module orelse @panic("Firmware check requires the firmware-owned codec") }},
            }) });
            const project_export = b.addRunArtifact(project_generator);
            const project_directory = project_export.addOutputDirectoryArg("project");
            const exported_project = project_directory.path(b, "keymap.zig");
            if (b.option([]const u8, "candidate-project", "Absolute existing LK7 project to export read-only instead of the QWERTY fixture")) |path| {
                if (!std.fs.path.isAbsolute(path)) @panic("candidate-project must be an absolute explicit input path");
                project_export.addDirectoryArg(.{ .cwd_relative = path });
                if (b.option(bool, "candidate-overlay-trigger", "Prepare a test-only base W companion trigger in the cached project copy") orelse false) project_export.addArg("--overlay-trigger");
            }
            const native_profile = b.createModule(.{ .root_source_file = exported_project, .imports = &.{.{ .name = "zigmkay", .module = firmware.module("zigmkay") }} });
            const project_processor = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("tests/project_processor_contract.zig"),
                .target = b.graph.host,
                .imports = &.{ .{ .name = "zigmkay", .module = firmware.module("zigmkay") }, .{ .name = "generated-project", .module = native_profile } },
            }) });
            firmware_check.dependOn(&b.addRunArtifact(project_processor).step);
            for ([_]struct { name: []const u8, keys: usize, encoders: usize }{
                .{ .name = "lk7", .keys = 34, .encoders = 0 },
                .{ .name = "dasbob", .keys = 36, .encoders = 0 },
                .{ .name = "encoder_demo", .keys = 1, .encoders = 2 },
            }) |fixture| {
                const source = generated.add(b.fmt("{s}/keymap.zig", .{fixture.name}), b.fmt(
                    \\const core = @import("zigmkay").core;
                    \\pub const keymap = [2][{d}]?core.KeyDef{{ @splat(.{{ .tap_only = .{{ .key_press = .{{ .tap_keycode = 4 }} }} }}), @splat(null) }};
                    \\pub const combos = [_]core.Combo2Def{{}};
                    \\fn onEvent(_: core.ProcessorEvent, _: *core.LayerActivations, _: *core.OutputCommandQueue) void {{}}
                    \\pub const custom_functions: core.CustomFunctions = .{{ .on_event = onEvent }};
                    \\pub const encoder_actions: [{d}]core.EncoderAction = @splat(.{{ .tap = .{{ .media_key = .VolumeDown }} }});
                    \\pub fn identity(comptime protocol: type) protocol.Identity {{
                    \\    @setEvalBranchQuota(500000);
                    \\    return protocol.computeIdentity(.{{ .board_id = .{{'f','i','x','t','u','r','e',0}}, .profile_id = .{{'o','b','s','e','r','v','e',0}},
                    \\        .dimensions = .{{ .key_count = {d}, .layer_count = 2 }},
                    \\        .keys = @as(*const [{d}]?core.KeyDef, @ptrCast(&keymap)),
                    \\        .sides = &@as([{d}]core.Side, @splat(.X)), .combos = &combos,
                    \\        .encoders = &encoder_actions, .callbacks = &.{{}} }}) catch unreachable;
                    \\}}
                    \\
                , .{ fixture.keys, fixture.encoders, fixture.keys, fixture.keys * 2, fixture.keys }));
                var sources: api.FirmwareSources = .{
                    .keyboards = firmware.path("keyboards"),
                    .processor = firmware.path("zigmkay/src/root.zig"),
                    .keycodes = firmware.path("zkeycodes/root.zig"),
                };
                if (@hasField(api.FirmwareSources, "companion_enabled")) sources.companion_enabled = true;
                const item = api.addKeyboardFirmware(b, mb, &target, .ReleaseSafe, b.fmt("generated-{s}", .{fixture.name}), api.boards.find(fixture.name).?, sources, if (std.mem.eql(u8, fixture.name, "lk7")) exported_project else source);
                // Generate a real UF2 in the build cache; no flash dispatch.
                const uf2 = item.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2040 } });
                _ = artifacts.addCopyFile(uf2, b.fmt("{s}.uf2", .{fixture.name}));
                firmware_check.dependOn(&artifacts.step);
                if (std.mem.eql(u8, fixture.name, "lk7")) {
                    const candidate_module = b.createModule(.{
                        .root_source_file = b.path("tools/usb_candidate.zig"),
                        .target = b.graph.host,
                        .imports = &.{ .{ .name = "generated-profile", .module = native_profile }, .{ .name = "zigmkay", .module = firmware.module("zigmkay") } },
                    });
                    const inventory = b.addExecutable(.{ .name = "usb-candidate", .root_module = candidate_module });
                    const inventory_run = b.addRunArtifact(inventory);
                    inventory_run.addFileArg(uf2);
                    const manifest = inventory_run.addOutputFileArg("candidate.zon");
                    inventory_run.addArg(b.option([]const u8, "firmware-revision", "Exact local EuroZig revision for offline candidate inventory") orelse "missing");
                    candidate.dependOn(&inventory_run.step);
                    candidate.dependOn(&b.addInstallFile(manifest, "acceptance/candidate.zon").step);
                    candidate.dependOn(&b.addInstallFile(uf2, "acceptance/candidate.uf2").step);
                    candidate.dependOn(&b.addInstallDirectory(.{ .source_dir = project_directory, .install_dir = .prefix, .install_subdir = "acceptance/project" }).step);
                    b.addNamedLazyPath("usb-candidate-manifest", manifest);
                    b.addNamedLazyPath("usb-candidate-uf2", uf2);
                    const inventory_tests = b.addTest(.{ .root_module = candidate_module });
                    firmware_check.dependOn(&b.addRunArtifact(inventory_tests).step);
                }
            }
        } else {
            project_build.dependOn(&b.addFail("Pinned EuroZig candidate lacks the downstream board API; use the explicit documented --fork development override").step);
            firmware_check.dependOn(&b.addFail("Pinned EuroZig candidate lacks the downstream board API; use the explicit documented --fork development override").step);
            candidate.dependOn(&b.addFail("Pinned EuroZig candidate lacks the downstream board API; use the explicit documented --fork development override").step);
        }
    } else {
        catalog_firmware.dependOn(&b.addFail("All-board firmware checks require explicit firmware-check=true preparation").step);
        project_build.dependOn(&b.addFail("Project build requires explicit firmware-check=true dependency preparation").step);
        firmware_check.dependOn(&b.addFail("Pass -Dfirmware-check=true to explicitly prepare embedded build dependencies").step);
        candidate.dependOn(&b.addFail("Pass -Dfirmware-check=true and -Dfirmware-revision=<full local commit> to prepare an offline candidate").step);
    }
    const compatibility = b.step("check-compatibility", "Require accepted firmware and host compatibility gates");
    compatibility.dependOn(&b.addFail("Firmware PR review, physical board mapping, managed provenance and desktop/native release gates remain pending").step);
}
