//! Zigmkay companion build. Builds and tests never access devices; flashing
//! and other hardware mutations are separate, explicit tasks.
//!
//!   zig build check test                 offline compile and test (default: check)
//!   zig build test-practice -Donly=practice
//!   zig build test-desktop -Ddesktop     SDL dummy/software GUI fixtures
//!   zig build check-firmware -Dfirmware  embedded compilation, never flashed
//!   zig build bundle tools -Dbundle      self-contained application
//!
//! `build/Config.zig` lists every option, `build/Steps.zig` every step and
//! `build/Modules.zig` the module graph. `build/runtime.zig` names the build
//! closure shipped in the application, whose own entry is `runtime/build.zig`.
const std = @import("std");
const Config = @import("build/Config.zig");
const Deps = @import("build/Deps.zig");
const Modules = @import("build/Modules.zig");
const Steps = @import("build/Steps.zig");
const tests = @import("build/tests.zig");
const gui = @import("build/gui.zig");
const firmware = @import("build/firmware.zig");
const bundle = @import("build/bundle.zig");
const tools = @import("build/tools.zig");
const native = @import("build/native.zig");

pub fn build(b: *std.Build) !void {
    @setEvalBranchQuota(100_000);
    const cfg = Config.init(b);
    const steps = Steps.init(b);
    disableUnconfigured(b, cfg, steps);
    const deps = try Deps.init(b, cfg);
    const mods = Modules.init(b, cfg, deps);
    var suite: tests.Suite = .{ .b = b, .cfg = cfg, .mods = mods, .steps = steps };

    if (cfg.only == .diagnostic) {
        _ = tools.add(&suite, null);
        return;
    }
    var fixtures = tests.addCore(&suite);
    if (mods.host != null) tests.addHost(&suite, &fixtures);
    const utilities = tools.add(&suite, fixtures.catalog_export);
    if (cfg.only != null) return;
    steps.@"test".dependOn(steps.test_practice);
    steps.@"test".dependOn(steps.test_jobs);

    const app = if (mods.gui != null) gui.add(&suite, fixtures) else null;
    if (cfg.firmware) firmware.add(&suite, deps, fixtures);
    if (cfg.bundle) bundle.add(&suite, deps, app.?, utilities.bootsel);
    if (cfg.macos_sdk) |sdk| if (app) |exe| native.sdkPaths(b, exe.root_module, sdk);

    suite.guard(steps.@"test", &.{
        .{ .desktop, cfg.desktop, &gui.test_roots },
        .{ .firmware, cfg.firmware, &firmware.test_roots },
    });
}

/// Give every step whose option is off a failure that names the option.
fn disableUnconfigured(b: *std.Build, cfg: Config, steps: Steps) void {
    if (cfg.only) |only| {
        const message = b.fmt("this step is unavailable with -Donly={t}", .{only});
        for ([_]*std.Build.Step{ steps.check, steps.@"test", steps.test_desktop, steps.test_native, steps.run, steps.bundle, steps.check_firmware, steps.check_firmware_defaults, steps.build_project, steps.hardware_tools }) |step|
            Steps.unavailable(b, step, message);
        if (only == .diagnostic) for ([_]*std.Build.Step{ steps.test_practice, steps.test_jobs }) |step|
            Steps.unavailable(b, step, message);
        return;
    }
    if (!cfg.desktop) {
        Steps.unavailable(b, steps.test_desktop, "test-desktop requires -Ddesktop");
        Steps.unavailable(b, steps.test_native, "test-native requires -Ddesktop for the native tray fixture");
        Steps.unavailable(b, steps.hardware_tools, "hardware-tools requires -Dfirmware -Ddesktop");
    }
    if (!cfg.firmware) {
        for ([_]*std.Build.Step{ steps.check_firmware, steps.check_firmware_defaults, steps.build_project }) |step|
            Steps.unavailable(b, step, b.fmt("{s} requires -Dfirmware", .{step.name}));
        if (cfg.desktop) Steps.unavailable(b, steps.hardware_tools, "hardware-tools requires -Dfirmware -Ddesktop");
    }
    if (!cfg.bundle) {
        Steps.unavailable(b, steps.bundle, "bundle requires -Dbundle");
        Steps.unavailable(b, steps.run, "run launches the assembled application and requires -Dbundle");
    }
}
