const std = @import("std");
const contract = @import("build_contract.zig");
pub const Selected = struct { module: *std.Build.Module, snapshot_id: [32]u8, manifest: contract.Manifest };

pub fn portablePath(path: []const u8) bool {
    return @import("export_inventory.zig").portablePath(path);
}

/// Shared selector used by host runner and firmware; hashes all files before adding modules.
pub fn load(
    b: *std.Build,
    path: []const u8,
    firmware: *std.Build.Module,
    keycodes: *std.Build.Module,
    model: *std.Build.Module,
) !Selected {
    const io = b.graph.io;
    const gpa = b.allocator;
    var inventory = try @import("export_inventory.zig").read(@import("owned_zon.zig"), gpa, io, path);
    defer inventory.deinit();
    const manifest = try @import("owned_zon.zig").clone(gpa, inventory.manifest);
    const captured = b.addWriteFiles();
    for (inventory.files) |file| _ = captured.add(file.path, file.bytes);
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "zigmkay", .module = firmware },
        .{ .name = "zkeycodes", .module = keycodes },
        .{ .name = "layout-model", .module = model },
    };
    const module = b.createModule(.{
        .root_source_file = captured.getDirectory().path(b, manifest.keymap),
        .imports = imports,
    });
    try listed(manifest, manifest.keymap);
    for (manifest.callbacks, 0..) |callback, index| {
        if (!portablePath(callback.entry)) return error.InvalidExportPath;
        try listed(manifest, callback.entry);
        const handler = b.createModule(.{
            .root_source_file = captured.getDirectory().path(b, callback.entry),
            .imports = imports,
        });
        module.addImport(b.fmt("callback_{d}", .{index}), handler);
    }
    return .{ .module = module, .snapshot_id = manifest.snapshot_id, .manifest = manifest };
}

fn listed(manifest: contract.Manifest, path: []const u8) !void {
    for (manifest.files) |file| if (std.mem.eql(u8, file.path, path)) return;
    return error.UnlistedExportFile;
}
