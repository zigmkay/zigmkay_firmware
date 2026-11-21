//! Bind shipped resources to a selected board. This does not execute any tools.
const std = @import("std");
const worker = @import("build_worker.zig");
const jobs = @import("companion-jobs");
pub const Bundle = jobs.application_bundle.Bundle;

pub fn plan(
    gpa: std.mem.Allocator,
    bundle: Bundle,
    cache: []const u8,
    selector: []const u8,
    board: [8]u8,
) !worker.Plan {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const id = bundle.manifest.id;
    const lock: jobs.target_lock.Lock = .{
        .firmware_revision = bundle.manifest.firmware_revision,
        .firmware_source_digest = id,
        .source_kind = .published,
        .dependency_digest = id,
        .compiler_digest = id,
        .compiler_bundle_digest = id,
        .board = selector,
        .board_mapping_digest = jobs.firmware.digest(&board),
    };
    const receipt: jobs.build_context.Receipt = .{ .lock_digest = lock.digest(), .bundle_id = id };
    return @import("project").owned_zon.clone(gpa, worker.Plan{ .config = .{
        .board_id = board,
        .build_board = selector,
        .request = .{
            .payload_executable = bundle.executable,
            .payload_root = bundle.root,
            .bundled = .{ .inputs = .{
                .project_digest = @splat(0),
                .source_digest = @splat(0),
                .build_inputs_digest = id,
                .profile_id = @splat(0),
                .identity_digest = @splat(0),
                .lock = lock,
            }, .receipt = receipt },
            .source_cache = try bundle.path(a, "dependencies"),
            .selection = .{
                .lock = lock,
                .compiler_path = try bundle.path(
                    a,
                    "toolchain/zig" ++ if (@import("builtin").os.tag == .windows) ".exe" else "",
                ),
                .compiler_distribution_path = try bundle.path(a, "toolchain"),
                .build_root = try bundle.path(a, "build"),
                .project_digest = @splat(0),
                .exported_source_digest = @splat(0),
                .profile_id = @splat(0),
                .identity_digest = @splat(0),
            },
            .export_directory = try std.fs.path.join(a, &.{ cache, "exports" }),
            .expected_export_tree = @splat(0),
            .install_directory = try std.fs.path.join(a, &.{ cache, "builds" }),
        },
    } });
}

pub fn tools(gpa: std.mem.Allocator, bundle: Bundle) !jobs.flash_inputs.Tools {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    return jobs.flash_inputs.Tools.clone(gpa, .{
        .version = bundle.manifest.version,
        .backend = bundle.manifest.backend,
        .firmware_revision = bundle.manifest.firmware_revision,
        .firmware_source_digest = bundle.manifest.id,
        .source_kind = .published,
        .wrapper_path = try bundle.path(
            a,
            if (bundle.manifest.backend == .windows_bootsel) "tools/bootsel-transfer.exe" else "tools/picotool_flash" ++ if (@import("builtin").os.tag == .windows) ".exe" else "",
        ),
        .wrapper_hash = bundle.manifest.wrapper_hash,
        .picotool_path = try bundle.path(
            a,
            if (bundle.manifest.backend == .windows_bootsel) "tools/bootsel-transfer.exe" else "tools/picotool" ++ if (@import("builtin").os.tag == .windows) ".exe" else "",
        ),
        .picotool_hash = bundle.manifest.picotool_hash,
    });
}
