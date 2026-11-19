//! The runtime build closure shipped inside the application bundle.
//!
//! The installed application compiles projects with the bundled Zig and the
//! bundled `build/` tree: `runtime/build.zig` as `build/build.zig`, a generated
//! `build/build.zig.zon`, and the source directories below. Every build helper
//! that `runtime/build.zig` uses must live inside these directories.
const std = @import("std");

/// Source root inside both this repository and the bundled `build/` tree.
pub const source_root = "src";

/// Directories below `source_root` that the runtime build compiles from.
pub const closure = [_][]const u8{ "project", "layout", "runner", "importer", "firmware" };

/// The bundled `build/build.zig.zon`: this package's identity with only the
/// firmware and microzig dependencies.
pub fn manifest(b: *std.Build) []const u8 {
    const root = @import("../build.zig.zon");
    var text: std.Io.Writer.Allocating = .init(b.allocator);
    std.zon.stringify.serialize(.{
        .name = root.name,
        .fingerprint = root.fingerprint,
        .version = root.version,
        .minimum_zig_version = root.minimum_zig_version,
        .dependencies = .{ .zigmkay_firmware = root.dependencies.zigmkay_firmware, .microzig = root.dependencies.microzig },
        .paths = .{ "build.zig", "build.zig.zon", source_root },
    }, .{}, &text.writer) catch @panic("Cannot write runtime manifest");
    return text.written();
}

/// The bundled `build/` tree in the build cache, plus `extra` repository
/// directories that tests read next to it.
pub fn tree(b: *std.Build, extra: []const []const u8) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("runtime/build.zig"), "build.zig");
    _ = files.add("build.zig.zon", manifest(b));
    for (closure) |name| {
        const path = b.fmt("{s}/{s}", .{ source_root, name });
        _ = files.addCopyDirectory(b.path(path), path, .{});
    }
    for (extra) |path| _ = files.addCopyDirectory(b.path(path), path, .{});
    return files.getDirectory();
}
