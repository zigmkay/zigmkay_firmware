//! Every `-D` option of the root build, the resolved application target and
//! the compiler pin. All options are registered here, before any lazy
//! dependency can stop configuration, so Zig never reports a supplied option
//! as unknown on a partial configure pass.
const std = @import("std");
const builtin = @import("builtin");
const Config = @This();

/// The only supported compiler. `.zigversion`, `mise.toml` and CI repeat it.
pub const zig_version = "0.17.0";

/// Configure a deliberately small graph for constrained CI jobs.
pub const Only = enum {
    /// Practice data, application paths, release tooling and subprocess
    /// contracts, without the firmware dependency or native bridges.
    practice,
    /// Only the symbolized artifact-publication diagnostic.
    diagnostic,
};

/// Application and host-tool target: the host, or the release baseline.
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
release: bool,
revision: []const u8,
macos_sdk: ?[]const u8,
/// DVUI, SDL3, tray and vector icons (`-Ddesktop`, implied by `-Dbundle`).
desktop: bool,
/// The microzig embedded graph (`-Dfirmware`, implied by `-Dbundle`).
firmware: bool,
/// The self-contained application (`-Dbundle`).
bundle: bool,
only: ?Only,
/// Applied to every test compilation; empty runs all tests.
test_filters: []const []const u8,
project_export: ?[]const u8,
project_board: ?[]const u8,
import_root: ?[]const u8,
import_module: []const u8,
candidate_project: ?[]const u8,
candidate_overlay_trigger: bool,
firmware_revision: []const u8,

pub fn init(b: *std.Build) Config {
    if (!std.mem.eql(u8, builtin.zig_version_string, zig_version))
        @panic("zigmkay_companion requires exactly Zig " ++ zig_version);
    const bundle = b.option(bool, "bundle", "Assemble the self-contained application (implies -Ddesktop and -Dfirmware)") orelse false;
    const release = b.option(bool, "release", "Use baseline CPUs and the supported preview OS minimums") orelse false;
    // The importer runs `analyze-keymap -Dnative-only` against this script and the bundled runtime build alike.
    const native_only = b.option(bool, "native-only", "Skip the embedded firmware graph, as in the bundled runtime build") orelse false;
    const config: Config = .{
        .target = if (release) releaseTarget(b) else b.graph.host,
        .optimize = b.standardOptimizeOption(.{}),
        .release = release,
        .revision = b.option([]const u8, "revision", "Source commit recorded in the package") orelse "development",
        .macos_sdk = b.option([]const u8, "macos-sdk", "Explicit macOS SDK path for release compilation"),
        .desktop = bundle or (b.option(bool, "desktop", "Configure the native GUI, tray and vector icons") orelse false),
        .firmware = !native_only and (bundle or (b.option(bool, "firmware", "Configure embedded firmware compilation (never flashes)") orelse false)),
        .bundle = bundle,
        .only = b.option(Only, "only", "Configure only a small offline subset"),
        .test_filters = b.option([]const []const u8, "test-filter", "Run only tests whose names contain this text") orelse &.{},
        .project_export = b.option([]const u8, "project-export", "Absolute frozen project export directory (build-project)"),
        .project_board = b.option([]const u8, "project-board", "Firmware board selector of the export (build-project)"),
        .import_root = b.option([]const u8, "import-root", "Absolute captured keymap source directory (analyze-keymap)"),
        .import_module = b.option([]const u8, "import-module", "Captured module relative to import-root (analyze-keymap)") orelse "src/keymap.zig",
        .candidate_project = b.option([]const u8, "candidate-project", "Absolute existing LK7 project to export read-only instead of the QWERTY fixture"),
        .candidate_overlay_trigger = b.option(bool, "candidate-overlay-trigger", "Prepare a test-only base W companion trigger in the cached candidate project") orelse false,
        .firmware_revision = b.option([]const u8, "firmware-revision", "Exact local firmware revision for the offline candidate inventory") orelse "missing",
    };
    if (config.only != null and (config.desktop or config.firmware))
        @panic("-Donly cannot be combined with -Ddesktop, -Dfirmware or -Dbundle");
    if (config.candidate_project) |path| if (!std.fs.path.isAbsolute(path))
        @panic("candidate-project must be an absolute explicit input path");
    return config;
}

/// Whether the firmware package and everything built on it is configured.
pub fn hostGraph(config: Config) bool {
    return config.only == null;
}

fn releaseTarget(b: *std.Build) std.Build.ResolvedTarget {
    const host = b.graph.host.result;
    return b.resolveTargetQuery(.{
        .cpu_arch = host.cpu.arch,
        .cpu_model = .baseline,
        .os_tag = host.os.tag,
        .abi = host.abi,
        .os_version_min = switch (host.os.tag) {
            .macos => .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } },
            .windows => .{ .windows = .win11_zn },
            .linux => .{ .semver = .{ .major = 5, .minor = 15, .patch = 0 } },
            else => @panic("Unsupported preview platform"),
        },
        .glibc_version = if (host.os.tag == .linux) .{ .major = 2, .minor = 35, .patch = 0 } else null,
    });
}
