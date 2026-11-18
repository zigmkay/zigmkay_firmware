//! Host system paths for native C code: Linux system directories and an
//! explicit macOS SDK.
const std = @import("std");

/// Search the host's native Linux library and include directories, after the
/// target's bundled libc headers. Explicit release OS/glibc minimums disable
/// Zig's automatic native paths, while pkg-config omits standard directories.
pub fn linuxPaths(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const host = b.graph.host.result;
    if (host.os.tag != .linux or target.result.os.tag != .linux or
        host.cpu.arch != target.result.cpu.arch or host.abi != target.result.abi) return;
    const paths = std.zig.system.NativePaths.detect(b.allocator, b.graph.io, &host, &b.graph.environ_map) catch
        @panic("Unable to detect native Linux paths");
    for (paths.lib_dirs.items) |path| {
        if (directoryExists(b, path)) module.addLibraryPath(.{ .cwd_relative = path });
    }
    for (paths.include_dirs.items) |path| {
        if (directoryExists(b, path)) module.addAfterIncludePath(.{ .cwd_relative = path });
    }
}

/// Add the SDK's headers, libraries and frameworks to `root` and every module
/// it reaches. Call it after the module's import graph is complete.
pub fn sdkPaths(b: *std.Build, root: *std.Build.Module, sdk: []const u8) void {
    var seen: std.AutoHashMap(*std.Build.Module, void) = .init(b.allocator);
    addSdk(b, root, sdk, &seen);
}

fn addSdk(b: *std.Build, module: *std.Build.Module, sdk: []const u8, seen: *std.AutoHashMap(*std.Build.Module, void)) void {
    const item = seen.getOrPut(module) catch @panic("OOM");
    if (item.found_existing) return;
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    for (module.import_table.values()) |imported| addSdk(b, imported, sdk, seen);
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |step| addSdk(b, step.root_module, sdk, seen),
        else => {},
    };
}

fn directoryExists(b: *std.Build, path: []const u8) bool {
    const dir = std.Io.Dir.cwd().openDir(b.graph.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => std.debug.panic("Unable to open native Linux directory '{s}': {t}", .{ path, err }),
    };
    dir.close(b.graph.io);
    return true;
}
