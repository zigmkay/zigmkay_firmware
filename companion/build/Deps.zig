//! Every external package of the root build. Lazy packages are requested only
//! when the configured options need them; a missing one stops configuration
//! with `error.LazyDependencyNeeded` after all of them have been requested, so
//! Zig fetches them together and configures again.
const std = @import("std");
const Config = @import("Config.zig");
const Deps = @This();

/// The firmware's microzig build API with the RP2xxx port.
pub const MicroBuild = @import("zigmkay_firmware").keyboards.MicroBuild;

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
    if (missing) return error.LazyDependencyNeeded;
    return deps;
}

/// microzig, pinned by the firmware's zigmkay package.
pub fn microzig(b: *std.Build) *std.Build.Dependency {
    return zigmkay(b).builder.dependency("microzig", .{});
}

fn lazy(b: *std.Build, missing: *bool, name: []const u8, args: anytype) ?*std.Build.Dependency {
    return b.dependencyLazy(name, args) catch {
        missing.* = true;
        return null;
    };
}

/// The firmware's zigmkay package, which pins microzig and picotool.
fn zigmkay(b: *std.Build) *std.Build.Dependency {
    return b.dependency("zigmkay_firmware", .{}).builder.dependency("zigmkay", .{});
}
