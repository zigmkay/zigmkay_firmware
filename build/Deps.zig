//! Every external package of the root build. Lazy packages are requested only
//! when the configured options need them; a missing one stops configuration
//! with `error.LazyDependencyNeeded` after all of them have been requested, so
//! Zig fetches them together and configures again.
const std = @import("std");
const Config = @import("Config.zig");
const Deps = @This();

/// The microzig build API with the RP2xxx port, or `void` until Zig has
/// fetched microzig.
const MicroBuildApi = if (microzigBuild()) |mz| mz.MicroBuild(.{ .rp2xxx = true }) else void;
/// `MicroBuildApi` once Zig has also fetched its lazy RP2xxx port, else
/// `void`. Use `microBuild`, never this type, to reach it.
pub const MicroBuild = if (MicroBuildApi != void and portsFetched(MicroBuildApi)) MicroBuildApi else void;

/// `zigmkay_firmware`: processor, keycodes and board sources (absent under `-Donly`).
firmware: ?*std.Build.Dependency = null,
dvui: ?*std.Build.Dependency = null,
ztray: ?*std.Build.Dependency = null,
svg2tvg: ?*std.Build.Dependency = null,
icons: ?*std.Build.Dependency = null,
/// Inter, the editor font on every host, with a real bold face.
inter: ?*std.Build.Dependency = null,
/// The prebuilt picotool shipped with non-Windows bundles.
picotool: ?*std.Build.Dependency = null,
micro: if (MicroBuild == void) void else ?*MicroBuild = if (MicroBuild == void) {} else null,

pub fn init(b: *std.Build, cfg: Config) error{LazyDependencyNeeded}!Deps {
    var deps: Deps = .{};
    var missing = false;
    if (cfg.hostGraph()) deps.firmware = lazy(b, &missing, "zigmkay_firmware", .{});
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
        deps.picotool = lazy(b, &missing, "picotool", .{ .target = cfg.target, .optimize = cfg.optimize });
    if (cfg.firmware) {
        const dependency = lazy(b, &missing, "microzig", .{});
        if (b.lazyImport(Deps, "microzig") == null) missing = true;
        // `init` also requests the lazy port packages and, until Zig has
        // fetched them, returns `?noreturn`.
        if (MicroBuildApi != void) if (dependency) |dep| {
            const micro = MicroBuildApi.init(b, dep);
            if (comptime MicroBuild == void) {
                missing = true;
            } else {
                deps.micro = micro;
                if (micro == null) missing = true;
            }
        };
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

/// The comptime half of `std.Build.lazyImport`: microzig's build.zig once
/// fetched. Reading it here lets `MicroBuild` be a field type.
fn microzigBuild() ?type {
    const deps = @import("root").dependencies;
    const hash = comptime for (deps.root_deps) |dep| {
        if (std.mem.eql(u8, dep[0], "microzig")) break dep[1];
    } else @compileError("build.zig.zon does not declare microzig");
    inline for (@typeInfo(deps.packages).@"struct".decl_names) |name| {
        if (comptime std.mem.eql(u8, name, hash)) {
            const package = @field(deps.packages, name);
            if (@hasDecl(package, "available") and !package.available) return null;
            return package.build_zig;
        }
    }
    return null;
}

/// Whether microzig sees every selected port package: until Zig has fetched
/// them, `init` returns `?noreturn` and `ports` lacks their board APIs.
fn portsFetched(comptime Api: type) bool {
    const Return = @typeInfo(@TypeOf(Api.init)).@"fn".return_type.?;
    return @typeInfo(Return).optional.child != noreturn;
}
