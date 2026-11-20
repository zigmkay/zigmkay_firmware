//! The runtime build closure shipped inside the application bundle.
//!
//! The installed application compiles projects with the bundled Zig and the
//! bundled `build/` tree: `runtime/build.zig` as `build/build.zig`, a generated
//! `build/build.zig.zon`, the source directories below and the firmware
//! package in `build/firmware/`. Every build helper that `runtime/build.zig`
//! uses must live inside these directories.
const std = @import("std");

/// Source root inside both this repository and the bundled `build/` tree.
pub const source_root = "src";

/// Directories below `source_root` that the runtime build compiles from.
pub const closure = [_][]const u8{ "project", "layout", "runner", "importer", "firmware" };

/// Where the bundled `build/` tree keeps the firmware package.
pub const firmware_root = "firmware";

/// The firmware package's `.paths`, copied to `firmware_root`. Its manifest
/// pins microzig and picotool, which the bundle ships as packages.
pub const firmware_paths: []const []const u8 = &@import("zigmkay_firmware").manifest.paths;

/// File types copied from the firmware directories, so build outputs in custom
/// prefixes and other local files stay out of the bundle.
pub const firmware_extensions = [_][]const u8{ ".zig", ".zon", ".hjson" };

/// Directory names that never belong to the firmware's sources, including
/// `keyboards/local/`, the git-ignored folder of personal keymaps.
pub const skipped = [_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg", "local" };

/// The bundled `build/build.zig.zon`: this package's identity with only the
/// firmware dependency.
pub fn manifest(b: *std.Build) []const u8 {
    const root = @import("../build.zig.zon");
    var text: std.Io.Writer.Allocating = .init(b.allocator);
    std.zon.stringify.serialize(.{
        .name = root.name,
        .fingerprint = root.fingerprint,
        .version = root.version,
        .minimum_zig_version = root.minimum_zig_version,
        .dependencies = .{ .zigmkay_firmware = .{ .path = firmware_root } },
        .paths = .{ "build.zig", "build.zig.zon", source_root },
    }, .{}, &text.writer) catch @panic("Cannot write runtime manifest");
    return text.written();
}

/// The bundled `build/` tree in the build cache, plus `extra` repository
/// directories that tests read next to it.
pub fn tree(b: *std.Build, firmware: *std.Build.Dependency, extra: []const []const u8) std.Build.LazyPath {
    const files = b.addWriteFiles();
    for (firmware_paths) |path| copySources(files, firmware, path);
    _ = files.addCopyFile(b.path("runtime/build.zig"), "build.zig");
    _ = files.add("build.zig.zon", manifest(b));
    for (closure) |name| {
        const path = b.fmt("{s}/{s}", .{ source_root, name });
        _ = files.addCopyDirectory(b.path(path), path, .{});
    }
    for (extra) |path| _ = files.addCopyDirectory(b.path(path), path, .{});
    return files.getDirectory();
}

/// Copy `path` of the firmware package to `firmware_root`: listed files, and
/// the `firmware_extensions` files of listed directories without caches.
fn copySources(files: *std.Build.Step.WriteFile, firmware: *std.Build.Dependency, path: []const u8) void {
    const b = files.step.owner;
    const io = b.graph.io;
    const root = firmware.builder.root;
    const stat = root.statFile(io, path) catch |err| std.debug.panic("Cannot read firmware '{s}': {t}", .{ path, err });
    if (stat.kind != .directory) {
        _ = files.addCopyFile(firmware.path(path), b.fmt("{s}/{s}", .{ firmware_root, path }));
        return;
    }
    b.dependOnDirectoryContents(firmware.path(path));
    var dir = root.openDir(io, path, .{ .iterate = true }) catch |err| std.debug.panic("Cannot open firmware '{s}': {t}", .{ path, err });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("Cannot list firmware '{s}': {t}", .{ path, err })) |entry| {
        if (for (skipped) |name| {
            if (std.mem.eql(u8, entry.name, name)) break true;
        } else false) continue;
        if (entry.kind != .directory and for (firmware_extensions) |extension| {
            if (std.mem.endsWith(u8, entry.name, extension)) break false;
        } else true) continue;
        copySources(files, firmware, b.fmt("{s}/{s}", .{ path, entry.name }));
    }
}
