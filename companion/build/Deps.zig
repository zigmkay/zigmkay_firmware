//! Every external package of the root build. Lazy packages are requested only
//! when the configured options need them; a missing one stops configuration
//! with `error.LazyDependencyNeeded` after all of them have been requested, so
//! Zig fetches them together and configures again.
const std = @import("std");
const Config = @import("Config.zig");
const Deps = @This();

/// The firmware's microzig build API with the RP2xxx port.
const MicroBuildApi = @import("zigmkay_firmware").keyboards.MicroBuild;
/// `MicroBuildApi` once Zig has fetched its lazy RP2xxx port, else `void`.
/// Use `microBuild`, never this type, to reach it.
pub const MicroBuild = if (portsFetched(MicroBuildApi)) MicroBuildApi else void;

/// `zigmkay_firmware`, the firmware of this repository: processor, keycodes
/// and board sources (absent under `-Donly`).
firmware: ?*std.Build.Dependency = null,
dvui: ?*std.Build.Dependency = null,
ztray: ?*std.Build.Dependency = null,
svg2tvg: ?*std.Build.Dependency = null,
icons: ?*std.Build.Dependency = null,
/// Inter, the editor font on every host, with a real bold face.
inter: ?*std.Build.Dependency = null,
/// The prebuilt picotool shipped with non-Windows bundles, from the firmware's pin.
picotool: ?*std.Build.Dependency = null,
micro: if (MicroBuild == void) void else ?*MicroBuild = if (MicroBuild == void) {} else null,

pub fn init(b: *std.Build, cfg: Config) error{LazyDependencyNeeded}!Deps {
    var deps: Deps = .{};
    var missing = false;
    if (cfg.hostGraph()) deps.firmware = b.dependency("zigmkay_firmware", .{});
    if (cfg.desktop) {
        deps.dvui = lazy(b, &missing, "dvui", .{
            .target = cfg.target,
            .optimize = cfg.optimize,
            .backend = .sdl3,
            .freetype = true,
            .@"tiny-file-dialogs" = false,
            .@"tree-sitter" = false,
            .tvg = true,
            .accesskit = .off,
        });
        deps.ztray = lazy(b, &missing, "ztray", .{ .target = cfg.target, .optimize = cfg.optimize });
        deps.svg2tvg = lazy(b, &missing, "svg2tvg", .{ .target = cfg.target, .optimize = cfg.optimize });
        deps.icons = lazy(b, &missing, "icons", .{ .target = cfg.target, .optimize = cfg.optimize });
        deps.inter = lazy(b, &missing, "inter", .{});
    }
    if (cfg.bundle and cfg.target.result.os.tag != .windows)
        deps.picotool = zigmkay(b).builder.dependency("picotool", .{ .target = cfg.target, .optimize = cfg.optimize });
    if (cfg.firmware) {
        // `init` requests the lazy port packages and, until Zig has fetched
        // them, returns `?noreturn`.
        const micro = MicroBuildApi.init(b, zigmkay(b).builder.dependency("microzig", .{}));
        if (comptime MicroBuild == void) {
            missing = true;
        } else {
            deps.micro = micro;
            if (micro == null) missing = true;
        }
    }
    if (missing) return error.LazyDependencyNeeded;
    return deps;
}

/// The configured microzig build. Inline so that, while microzig is not yet
/// fetched, a caller's `orelse return` leaves the rest of its body unanalyzed.
pub inline fn microBuild(deps: Deps) ?*MicroBuild {
    if (comptime MicroBuild == void) return null;
    return deps.micro;
}

fn lazy(b: *std.Build, missing: *bool, name: []const u8, args: anytype) ?*std.Build.Dependency {
    const dep = b.lazyDependency(name, args);
    if (dep == null) missing.* = true;
    return dep;
}

/// The firmware's zigmkay package, which pins microzig and picotool.
fn zigmkay(b: *std.Build) *std.Build.Dependency {
    return b.dependency("zigmkay_firmware", .{}).builder.dependency("zigmkay", .{});
}

/// Whether microzig sees every selected port package: until Zig has fetched
/// them, `init` returns `?noreturn` and `ports` lacks their board APIs.
fn portsFetched(comptime Api: type) bool {
    const Return = @typeInfo(@TypeOf(Api.init)).@"fn".return_type.?;
    return @typeInfo(Return).optional.child != noreturn;
}
