test {
    _ = @import("child_job.zig");
    _ = @import("package_manifest.zig");
    _ = @import("source_files.zig");
    _ = @import("target_lock.zig");
    _ = @import("firmware.zig");
    _ = @import("source_digest.zig");
    _ = @import("sidecar.zig");
    _ = @import("flash_inputs.zig");
    _ = @import("application_bundle.zig");
    _ = @import("bundle_payload.zig");
    _ = @import("bootsel_transfer.zig");
    _ = @import("picotool_job.zig");
    _ = @import("test_process.zig");
    _ = @import("test_picotool_job.zig");
    _ = @import("compiler_cache.zig");
    _ = @import("cache_retention.zig");
    _ = @import("managed_build.zig");
}
