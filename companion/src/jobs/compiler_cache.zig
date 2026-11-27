//! Zig compiler cache shared by every application bundle that ships the same
//! compiler for the same host. Zig's cache is content-addressed and safe for
//! concurrent compilers, so a bundle update reuses the host tools and build
//! runner it did not change. A build holds the cache's lease while its
//! compiler runs, so the builds of every instance take turns instead of
//! competing for the same work, and cleanup, which only tries the lease,
//! never deletes files a running compiler uses.
//!
//! Layout below `<install directory>/compiler-cache`:
//!
//!     zig-<32 hex>/global          ZIG_GLOBAL_CACHE_DIR
//!     zig-<32 hex>/local           --cache-dir
//!     zig-<32 hex>/built-<64 hex>  a bundle's completed-build marker
//!     zig-<32 hex>.lock            lease file
//!
//! Earlier versions kept one cache per bundle in `<64 hex>` directories.
const std = @import("std");
const builtin = @import("builtin");
const Digest = [32]u8;

pub const directory_name = "compiler-cache";
pub const prefix = "zig-";
pub const Name = [prefix.len + 32]u8;

/// What makes compiled artifacts incompatible: the compiler and the host
/// it runs on. The bundled firmware sources, packages and keymaps are inputs
/// Zig hashes itself.
pub fn key(compiler_identity: Digest) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-compiler-cache-v1\x00");
    hash.update(&compiler_identity);
    inline for (.{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi) }) |part| {
        hash.update(part);
        hash.update("\x00");
    }
    return hash.finalResult();
}

pub fn name(compiler_identity: Digest) Name {
    const digest = key(compiler_identity);
    var result: Name = undefined;
    @memcpy(result[0..prefix.len], prefix);
    result[prefix.len..].* = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return result;
}

/// Whether `entry` names a shared cache directory, without the lease suffix.
pub fn isCacheName(entry: []const u8) bool {
    return entry.len == @sizeOf(Name) and std.mem.startsWith(u8, entry, prefix) and
        isLowerHex(entry[prefix.len..]);
}

/// A per-bundle directory of the earlier layout.
pub fn isLegacyName(entry: []const u8) bool {
    return entry.len == 64 and isLowerHex(entry);
}

pub fn isLowerHex(text: []const u8) bool {
    for (text) |char| switch (char) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Paths of one shared cache. `root` is `<install directory>/compiler-cache`.
pub const Layout = struct {
    root: []const u8,
    name: Name,

    pub fn init(a: std.mem.Allocator, install_directory: []const u8, compiler_identity: Digest) !Layout {
        return .{
            .root = try std.fs.path.join(a, &.{ install_directory, directory_name }),
            .name = name(compiler_identity),
        };
    }

    pub fn directory(self: *const Layout, a: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(a, &.{ self.root, &self.name });
    }

    pub fn global(self: *const Layout, a: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(a, &.{ self.root, &self.name, "global" });
    }

    pub fn local(self: *const Layout, a: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(a, &.{ self.root, &self.name, "local" });
    }
};

fn markerName(bundle_id: Digest) [6 + 64]u8 {
    var result: [6 + 64]u8 = undefined;
    @memcpy(result[0..6], "built-");
    result[6..].* = std.fmt.bytesToHex(bundle_id, .lower);
    return result;
}

/// True until this bundle completed a build into the shared cache. Another
/// bundle's build already warmed most of it, but the firmware itself is then
/// still compiled once, so the first-build hint stays conservative.
pub fn isFirstBuild(io: std.Io, layout: Layout, bundle_id: Digest) bool {
    var root = std.Io.Dir.cwd().openDir(io, layout.root, .{}) catch return true;
    defer root.close(io);
    var directory = root.openDir(io, &layout.name, .{}) catch return true;
    defer directory.close(io);
    _ = directory.statFile(io, &markerName(bundle_id), .{}) catch return true;
    return false;
}

pub fn noteBuilt(io: std.Io, layout: Layout, bundle_id: Digest) !void {
    var root = try std.Io.Dir.cwd().createDirPathOpen(io, layout.root, .{});
    defer root.close(io);
    var directory = try root.createDirPathOpen(io, &layout.name, .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = &markerName(bundle_id), .data = "" });
}

/// An exclusive OS file lock on `<name>.lock` beside a cache directory. The
/// lock dies with its process.
pub const Lease = struct {
    file: std.Io.File,

    /// Waits while another build or cleanup holds the lease, checking
    /// cancellation between attempts.
    pub fn acquire(io: std.Io, root: std.Io.Dir, cache_name: []const u8, timeout: std.Io.Duration) !Lease {
        const start = std.Io.Clock.awake.now(io);
        while (true) {
            if (try tryAcquire(io, root, cache_name)) |lease| return lease;
            if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds > timeout.nanoseconds) return error.Timeout;
            try std.Io.sleep(io, .fromMilliseconds(50), .awake);
        }
    }

    /// Null while a build holds the cache.
    pub fn tryAcquire(io: std.Io, root: std.Io.Dir, cache_name: []const u8) !?Lease {
        var buffer: [@sizeOf(Name) + 8]u8 = undefined;
        const path = try lockName(&buffer, cache_name);
        // Read access lets `stat` compare the locked file with the one on disk;
        // Windows refuses it on a write-only handle.
        const file = try root.createFile(io, path, .{ .truncate = false, .read = true });
        errdefer file.close(io);
        if (!try file.tryLock(io, .exclusive)) {
            file.close(io);
            return null;
        }
        // Cleanup unlinks the lease file of a deleted cache. A lock taken on
        // an unlinked file guards nothing, so retry on the current file.
        const held = try file.stat(io);
        const current = root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (current == null or current.?.inode != held.inode) {
            file.close(io);
            return tryAcquire(io, root, cache_name);
        }
        return .{ .file = file };
    }

    pub fn release(self: *Lease, io: std.Io) void {
        self.file.close(io);
        self.* = undefined;
    }
};

pub fn lockName(buffer: []u8, cache_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}.lock", .{cache_name});
}

/// Concurrent build steps for `zig build -j`. Interactive builds use all
/// cores but one, leaving one for the editor; the background warm-up uses
/// half of them. Two is the floor of slow hosted runners, and more than
/// twelve steps never run at once in the firmware graph.
pub fn parallelism(cpu_count: usize, background: bool) u16 {
    const cores = @max(cpu_count, 1);
    const wanted = if (background) cores / 2 else cores - 1;
    return @intCast(std.math.clamp(wanted, 2, 12));
}

/// Platform-aware parallelism for `zig build -j`. Windows builds run at most
/// eight steps at once: with twelve, Zig 0.17's LLVM backend sporadically
/// failed (exit code 5, broken bitcode) on a 24-thread laptop, while two made
/// a cold warm-up on a 16-thread laptop take 7.5 minutes instead of 1.5.
pub fn parallelismFor(os: std.Target.Os.Tag, cpu_count: usize, background: bool) u16 {
    const count = parallelism(cpu_count, background);
    return if (os == .windows) @min(count, windows_limit) else count;
}

const windows_limit = 8;

pub fn hostParallelism(background: bool) u16 {
    return parallelismFor(builtin.os.tag, std.Thread.getCpuCount() catch 2, background);
}

test "the cache key separates compilers and keeps a stable name" {
    const a = name(@splat(1));
    const b = name(@splat(2));
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expectEqualSlices(u8, &a, &name(@splat(1)));
    try std.testing.expect(isCacheName(&a));
    try std.testing.expect(!isCacheName("zig-123"));
    try std.testing.expect(!isCacheName("zig-GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"));
    try std.testing.expect(isLegacyName(&std.fmt.bytesToHex(@as(Digest, @splat(7)), .lower)));
    try std.testing.expect(!isLegacyName(&a));
}

test "parallelism leaves a core to the editor and bounds the warm-up" {
    try std.testing.expectEqual(@as(u16, 2), parallelism(1, false));
    try std.testing.expectEqual(@as(u16, 2), parallelism(2, false));
    try std.testing.expectEqual(@as(u16, 3), parallelism(4, false));
    try std.testing.expectEqual(@as(u16, 7), parallelism(8, false));
    try std.testing.expectEqual(@as(u16, 12), parallelism(15, false));
    try std.testing.expectEqual(@as(u16, 12), parallelism(64, false));
    try std.testing.expectEqual(@as(u16, 2), parallelism(2, true));
    try std.testing.expectEqual(@as(u16, 4), parallelism(8, true));
    try std.testing.expectEqual(@as(u16, 7), parallelism(15, true));
    try std.testing.expectEqual(@as(u16, 8), parallelismFor(.windows, 24, false));
    try std.testing.expectEqual(@as(u16, 8), parallelismFor(.windows, 24, true));
    try std.testing.expectEqual(@as(u16, 8), parallelismFor(.windows, 16, true));
    try std.testing.expectEqual(@as(u16, 3), parallelismFor(.windows, 4, false));
    try std.testing.expectEqual(@as(u16, 12), parallelismFor(.linux, 24, false));
    try std.testing.expectEqual(@as(u16, 12), parallelismFor(.macos, 24, false));
    try std.testing.expect(hostParallelism(false) >= 2);
}

test "first-build markers are per bundle inside the shared cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const layout = try Layout.init(arena.allocator(), root, @splat(3));
    try std.testing.expect(isFirstBuild(io, layout, @splat(4)));
    try noteBuilt(io, layout, @splat(4));
    try std.testing.expect(!isFirstBuild(io, layout, @splat(4)));
    // An application update with the same compiler shares the directory.
    try std.testing.expect(isFirstBuild(io, layout, @splat(5)));
    const other = try Layout.init(arena.allocator(), root, @splat(6));
    try std.testing.expect(isFirstBuild(io, other, @splat(4)));
}

test "a lease excludes other builds and cleanup until released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const cache_name = name(@splat(1));
    var building = try Lease.acquire(io, tmp.dir, &cache_name, .fromSeconds(1));
    try std.testing.expect((try Lease.tryAcquire(io, tmp.dir, &cache_name)) == null);
    try std.testing.expectError(error.Timeout, Lease.acquire(io, tmp.dir, &cache_name, .fromMilliseconds(120)));
    // Another compiler's cache is independent.
    var other = (try Lease.tryAcquire(io, tmp.dir, &name(@splat(2)))).?;
    other.release(io);
    building.release(io);
    var cleanup = (try Lease.tryAcquire(io, tmp.dir, &cache_name)).?;
    // Cleanup unlinks the lock file of a deleted cache; the next lease is
    // taken on a new file, not on the unlinked one.
    var lock_buffer: [64]u8 = undefined;
    try tmp.dir.deleteFile(io, try lockName(&lock_buffer, &cache_name));
    var next = (try Lease.tryAcquire(io, tmp.dir, &cache_name)).?;
    next.release(io);
    cleanup.release(io);
}
