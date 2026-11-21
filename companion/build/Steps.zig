//! Every top-level step of the root build. All of them exist in every
//! configuration, so `zig build -l` is stable; a step whose option is off
//! fails with a message naming the option.
const std = @import("std");
const Steps = @This();
const Step = std.Build.Step;

check: *Step,
@"test": *Step,
test_practice: *Step,
test_jobs: *Step,
test_desktop: *Step,
test_native: *Step,
run: *Step,
run_project: *Step,
bundle: *Step,
tools: *Step,
check_firmware: *Step,
check_firmware_defaults: *Step,
build_project: *Step,
hardware_tools: *Step,
analyze_keymap: *Step,

pub fn init(b: *std.Build) Steps {
    const steps: Steps = .{
        .check = b.step("check", "Compile every configured source, tool and test without running anything"),
        .@"test" = b.step("test", "Run all offline tests and check that every test block is compiled"),
        .test_practice = b.step("test-practice", "Run typing test, tutor control and application path tests"),
        .test_jobs = b.step("test-jobs", "Run subprocess, flash-job, traversal and release tooling tests"),
        .test_desktop = b.step("test-desktop", "Run SDL dummy/software GUI fixtures and GUI unit tests (-Ddesktop)"),
        .test_native = b.step("test-native", "Query the OS keyboard layout and install a hidden tray; never devices (-Ddesktop)"),
        .run = b.step("run", "Assemble and launch the editor with automatic keyboard monitoring (-Dbundle; pass -- --background for the companion)"),
        .run_project = b.step("run-project", "Run the explicit project create/validate/export command"),
        .bundle = b.step("bundle", "Assemble the self-contained offline application (-Dbundle)"),
        .tools = b.step("tools", "Install release, bundle check, catalog export and diagnostic utilities"),
        .check_firmware = b.step("check-firmware", "Compile generated, synthetic all-board and imported firmware; never flashes (-Dfirmware)"),
        .check_firmware_defaults = b.step("check-firmware-defaults", "Compile every board's actual default keymap; never flashes (-Dfirmware)"),
        .build_project = b.step("build-project", "Build a verified export into UF2 and native runner (-Dfirmware -Dproject-export -Dproject-board)"),
        .hardware_tools = b.step("hardware-tools", "Prepare the USB candidate UF2 and native HID client without running them (-Dfirmware -Ddesktop)"),
        .analyze_keymap = b.step("analyze-keymap", "Compile a captured keymap with the typed evaluator (-Dimport-root)"),
    };
    b.default_step = steps.check;
    return steps;
}

/// Make `step` fail with `message` when run.
pub fn unavailable(b: *std.Build, step: *Step, message: []const u8) void {
    step.dependOn(&b.addFail(message).step);
}
