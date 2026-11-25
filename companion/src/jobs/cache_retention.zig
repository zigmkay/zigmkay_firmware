//! Bounded retention of the application cache directory. Only entries the
//! application recreates on demand are deleted, each by its exact name
//! pattern; unknown names, projects and preferences are never touched.
//!
//! Rules, below the cache root:
//!
//! * `builds/compiler-cache`: per-bundle `<64 hex>` caches of the earlier
//!   layout and shared `zig-<32 hex>` caches of other compilers are deleted;
//!   the current shared cache is dropped once it exceeds `compiler_cache_cap`.
//!   Shared caches are deleted only under an exclusive lease, so never while
//!   a build uses them.
//! * `builds/build-<32 hex>`: build outputs. Only the newest few are kept,
//!   with the one holding the accepted firmware.
//! * `exports/<format>/<64 hex>`: frozen project exports. The newest few and
//!   the accepted one are kept; other formats and the unversioned layout are
//!   deleted.
//! * `flash/<64 hex>.uf2`: frozen transfer copies. The newest few and the
//!   accepted one are kept; unsuffixed copies of the earlier layout go.
//! * `imports/{analysis,capture,download}-<32 hex>`: import scratch
//!   directories, newest few kept. The importer's compiler caches are dropped
//!   above `import_cache_cap`.
//! * `editor-environment`: the preparation cache of editors before the
//!   bundled toolchain; nothing creates it any more.
//! * `runtime/<64 hex>`: Windows payload extractions of other bundles.
//!
//! Anything modified within `grace` is kept: another running instance may be
//! using it. Failures are logged and skipped, never reported to the user.
const std = @import("std");
const compiler_cache = @import("compiler_cache.zig");

pub const Options = struct {
    /// Wall-clock time compared with modification times.
    now: std.Io.Timestamp,
    grace: std.Io.Duration = .fromSeconds(60 * 60),
    /// The shared compiler cache of the running bundle; null leaves every
    /// compiler cache alone.
    compiler_cache: ?compiler_cache.Name = null,
    /// A cold cache of one bundle is 200–350 MB. Zig never evicts, so updates
    /// add what changed; dropping the cache above this costs one cold build.
    compiler_cache_cap: u64 = 1024 * 1024 * 1024,
    /// One import's compiler caches are about 90 MB.
    import_cache_cap: u64 = 512 * 1024 * 1024,
    /// Directory name of the current export format, such as `v2`.
    export_format: []const u8,
    /// Lowercase hex id of the extracted Windows payload in use; null keeps
    /// `runtime` untouched.
    runtime: ?[64]u8 = null,
    keep: Keep = .{},
    keep_builds: usize = 5,
    keep_exports: usize = 10,
    keep_flash: usize = 5,
    keep_imports: usize = 5,
};

/// Entries referenced by the accepted build of this instance.
pub const Keep = struct {
    build: ?[]const u8 = null,
    export_name: ?[]const u8 = null,
    flash: ?[]const u8 = null,
};

pub const Report = struct {
    deleted: usize = 0,
    /// Bytes of deleted compiler caches, which dominate the total.
    compiler_cache_bytes: u64 = 0,
    failed: usize = 0,
};

pub fn clean(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, options: Options) Report {
    var cleaner: Cleaner = .{ .gpa = gpa, .io = io, .options = options };
    cleaner.run(root);
    return cleaner.report;
}

const Cleaner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    report: Report = .{},

    fn run(self: *Cleaner, root: std.Io.Dir) void {
        if (self.open(root, "builds")) |builds| {
            var dir = builds;
            defer dir.close(self.io);
            if (self.options.compiler_cache) |current| if (self.open(dir, compiler_cache.directory_name)) |caches| {
                var caches_dir = caches;
                defer caches_dir.close(self.io);
                self.compilerCaches(caches_dir, &current);
            };
            self.newest(dir, isBuildName, self.options.keep_builds, self.options.keep.build);
        }
        if (self.open(root, "exports")) |exports| {
            var dir = exports;
            defer dir.close(self.io);
            self.exportFormats(dir);
            if (self.open(dir, self.options.export_format)) |format| {
                var format_dir = format;
                defer format_dir.close(self.io);
                self.newest(format_dir, isDigestName, self.options.keep_exports, self.options.keep.export_name);
            }
        }
        if (self.open(root, "flash")) |flash| {
            var dir = flash;
            defer dir.close(self.io);
            self.newest(dir, isFlashName, self.options.keep_flash, self.options.keep.flash);
            self.stale(dir, isDigestName);
        }
        if (self.open(root, "imports")) |imports| {
            var dir = imports;
            defer dir.close(self.io);
            self.newest(dir, isImportName, self.options.keep_imports, null);
            self.importCaches(dir);
        }
        if (self.options.runtime) |current| if (self.open(root, "runtime")) |runtime| {
            var dir = runtime;
            defer dir.close(self.io);
            self.runtimes(dir, &current);
        };
        self.stale(root, isEditorEnvironment);
    }

    fn open(self: *Cleaner, parent: std.Io.Dir, name: []const u8) ?std.Io.Dir {
        return parent.openDir(self.io, name, .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) self.fail(name, err);
            return null;
        };
    }

    fn fail(self: *Cleaner, name: []const u8, err: anyerror) void {
        self.report.failed += 1;
        std.log.warn("cache cleanup skipped {s}: {t}", .{ name, err });
    }

    fn recent(self: *const Cleaner, mtime: std.Io.Timestamp) bool {
        return mtime.durationTo(self.options.now).nanoseconds < self.options.grace.nanoseconds;
    }

    fn delete(self: *Cleaner, dir: std.Io.Dir, name: []const u8) void {
        dir.deleteTree(self.io, name) catch |err| return self.fail(name, err);
        self.report.deleted += 1;
    }

    const Entry = struct { name: []const u8, mtime: std.Io.Timestamp };

    /// Matching entries, newest first.
    fn collect(self: *Cleaner, a: std.mem.Allocator, dir: std.Io.Dir, matches: *const fn ([]const u8) bool) ![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (!matches(entry.name)) continue;
            const stat = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                self.fail(entry.name, err);
                continue;
            };
            if (stat.kind == .sym_link) continue;
            try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .mtime = stat.mtime });
        }
        std.mem.sort(Entry, entries.items, {}, struct {
            fn newer(_: void, lhs: Entry, rhs: Entry) bool {
                return lhs.mtime.nanoseconds > rhs.mtime.nanoseconds;
            }
        }.newer);
        return entries.items;
    }

    /// Keeps the `count` newest matching entries, the referenced one and
    /// recent ones.
    fn newest(self: *Cleaner, dir: std.Io.Dir, matches: *const fn ([]const u8) bool, count: usize, keep: ?[]const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const entries = self.collect(arena.allocator(), dir, matches) catch |err| return self.fail("directory listing", err);
        for (entries, 0..) |entry, index| {
            if (index < count or self.recent(entry.mtime)) continue;
            if (keep) |name| if (std.mem.eql(u8, name, entry.name)) continue;
            self.delete(dir, entry.name);
        }
    }

    /// Deletes every matching entry that is not recent.
    fn stale(self: *Cleaner, dir: std.Io.Dir, matches: *const fn ([]const u8) bool) void {
        self.newest(dir, matches, 0, null);
    }

    fn exportFormats(self: *Cleaner, dir: std.Io.Dir) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const current = formatVersion(self.options.export_format) orelse return;
        const entries = self.collect(arena.allocator(), dir, isExportEntry) catch |err| return self.fail("exports", err);
        for (entries) |entry| {
            // A newer application may run beside this one; keep its format.
            if (formatVersion(entry.name)) |version| if (version >= current) continue;
            if (!self.recent(entry.mtime)) self.delete(dir, entry.name);
        }
    }

    fn compilerCaches(self: *Cleaner, dir: std.Io.Dir, current: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const entries = self.collect(a, dir, isCompilerCacheEntry) catch |err| return self.fail("compiler caches", err);
        for (entries) |entry| {
            if (std.mem.endsWith(u8, entry.name, trash_suffix)) {
                self.delete(dir, entry.name);
                continue;
            }
            if (compiler_cache.isLegacyName(entry.name)) {
                // Earlier versions held no lease; their own builds touch
                // these subdirectories.
                if (!self.touched(dir, entry.name)) self.deleteCompilerCache(dir, entry.name);
                continue;
            }
            if (std.mem.endsWith(u8, entry.name, ".lock")) {
                const cache = entry.name[0 .. entry.name.len - ".lock".len];
                // An orphaned lease of a deleted cache.
                if (!std.mem.eql(u8, cache, current) and !exists(self.io, dir, cache)) self.leased(dir, cache, false);
                continue;
            }
            if (std.mem.eql(u8, entry.name, current)) {
                const size = treeSize(self.io, dir, entry.name) catch |err| {
                    self.fail(entry.name, err);
                    continue;
                };
                if (size > self.options.compiler_cache_cap) {
                    std.log.info("compiler cache {s} holds {d} MB above the cap; the next build is cold", .{ entry.name, size / (1024 * 1024) });
                    self.leased(dir, entry.name, true);
                }
                continue;
            }
            self.leased(dir, entry.name, false);
        }
    }

    /// Whether an earlier-layout compiler recently wrote below `name`.
    fn touched(self: *Cleaner, dir: std.Io.Dir, name: []const u8) bool {
        for ([_][]const u8{ "", "global", "global/o", "global/tmp", "local", "local/o", "local/tmp" }) |sub| {
            var buffer: [128]u8 = undefined;
            const path = if (sub.len == 0) name else std.fmt.bufPrint(&buffer, "{s}/{s}", .{ name, sub }) catch continue;
            const stat = dir.statFile(self.io, path, .{ .follow_symlinks = false }) catch continue;
            if (self.recent(stat.mtime)) return true;
        }
        return false;
    }

    /// Deletes a shared cache and, unless `keep_lease`, its lease file, both
    /// under an exclusive lease.
    fn leased(self: *Cleaner, dir: std.Io.Dir, name: []const u8, keep_lease: bool) void {
        var lease = (compiler_cache.Lease.tryAcquire(self.io, dir, name) catch |err| return self.fail(name, err)) orelse {
            std.log.info("compiler cache {s} is in use; cleanup skipped it", .{name});
            return;
        };
        defer lease.release(self.io);
        if (exists(self.io, dir, name)) self.deleteCompilerCache(dir, name);
        if (keep_lease) return;
        var buffer: [@sizeOf(compiler_cache.Name) + 8]u8 = undefined;
        const lock = compiler_cache.lockName(&buffer, name) catch return;
        dir.deleteFile(self.io, lock) catch |err| self.fail(lock, err);
    }

    /// A cache is only ever used whole. Retire it with one rename, then
    /// delete the retired copy, which nothing reads; an interrupted deletion
    /// leaves only that copy for the next cleanup.
    fn deleteCompilerCache(self: *Cleaner, dir: std.Io.Dir, name: []const u8) void {
        const size = treeSize(self.io, dir, name) catch 0;
        var buffer: [80]u8 = undefined;
        const trash = std.fmt.bufPrint(&buffer, "{s}" ++ trash_suffix, .{name}) catch unreachable;
        dir.deleteTree(self.io, trash) catch |err| return self.fail(trash, err);
        dir.rename(name, dir, trash, self.io) catch |err| return self.fail(name, err);
        self.report.deleted += 1;
        self.report.compiler_cache_bytes += size;
        dir.deleteTree(self.io, trash) catch |err| self.fail(trash, err);
    }

    fn importCaches(self: *Cleaner, dir: std.Io.Dir) void {
        var total: u64 = 0;
        var newest_mtime: ?std.Io.Timestamp = null;
        var it = dir.iterate();
        while (it.next(self.io) catch |err| return self.fail("imports", err)) |entry| {
            const stat = dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch continue;
            if (newest_mtime == null or stat.mtime.nanoseconds > newest_mtime.?.nanoseconds) newest_mtime = stat.mtime;
            if (!isImportCacheName(entry.name)) continue;
            total += treeSize(self.io, dir, entry.name) catch |err| return self.fail(entry.name, err);
        }
        // Only while no import is under way.
        if (total <= self.options.import_cache_cap or (newest_mtime != null and self.recent(newest_mtime.?))) return;
        for (import_cache_names) |name| if (exists(self.io, dir, name)) self.delete(dir, name);
    }

    fn runtimes(self: *Cleaner, dir: std.Io.Dir, current: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const entries = self.collect(arena.allocator(), dir, isRuntimeEntry) catch |err| return self.fail("runtime", err);
        for (entries) |entry| {
            if (std.mem.startsWith(u8, entry.name, current)) continue;
            if (self.recent(entry.mtime)) continue;
            if (entry.name.len == 64) {
                // Without its completion marker a partly deleted payload is
                // extracted again instead of used.
                var buffer: [80]u8 = undefined;
                const marker = std.fmt.bufPrint(&buffer, "{s}/.complete", .{entry.name}) catch continue;
                dir.deleteFile(self.io, marker) catch |err| if (err != error.FileNotFound) {
                    self.fail(entry.name, err);
                    continue;
                };
            }
            self.delete(dir, entry.name);
        }
    }
};

const import_cache_names = [_][]const u8{ "compiler-global", "compiler-local" };

fn exists(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    _ = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// Bytes of the regular files below `name`, without following links.
pub fn treeSize(io: std.Io, parent: std.Io.Dir, name: []const u8) !u64 {
    const stat = try parent.statFile(io, name, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return stat.size;
    var dir = try parent.openDir(io, name, .{ .iterate = true });
    defer dir.close(io);
    var total: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| switch (entry.kind) {
        .directory => total += try treeSize(io, dir, entry.name),
        .file => total += (try dir.statFile(io, entry.name, .{ .follow_symlinks = false })).size,
        else => {},
    };
    return total;
}

fn hexSuffix(name: []const u8, head: []const u8, len: usize) bool {
    return name.len == head.len + len and std.mem.startsWith(u8, name, head) and
        compiler_cache.isLowerHex(name[head.len..]);
}

fn isBuildName(name: []const u8) bool {
    return hexSuffix(name, "build-", 32);
}

fn isDigestName(name: []const u8) bool {
    return hexSuffix(name, "", 64);
}

fn isFlashName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".uf2") and isDigestName(name[0 .. name.len - ".uf2".len]);
}

fn isImportName(name: []const u8) bool {
    return hexSuffix(name, "analysis-", 32) or hexSuffix(name, "capture-", 32) or hexSuffix(name, "download-", 32);
}

fn isImportCacheName(name: []const u8) bool {
    for (import_cache_names) |cache| if (std.mem.eql(u8, name, cache)) return true;
    return false;
}

fn isEditorEnvironment(name: []const u8) bool {
    return std.mem.eql(u8, name, "editor-environment");
}

fn formatVersion(name: []const u8) ?u32 {
    if (name.len < 2 or name[0] != 'v') return null;
    return std.fmt.parseInt(u32, name[1..], 10) catch null;
}

fn isExportEntry(name: []const u8) bool {
    return isDigestName(name) or formatVersion(name) != null;
}

const trash_suffix = ".trash";

fn isCompilerCacheEntry(name: []const u8) bool {
    if (compiler_cache.isLegacyName(name) or compiler_cache.isCacheName(name)) return true;
    if (std.mem.endsWith(u8, name, trash_suffix)) {
        const base = name[0 .. name.len - trash_suffix.len];
        return compiler_cache.isLegacyName(base) or compiler_cache.isCacheName(base);
    }
    return std.mem.endsWith(u8, name, ".lock") and compiler_cache.isCacheName(name[0 .. name.len - ".lock".len]);
}

fn isRuntimeEntry(name: []const u8) bool {
    if (isDigestName(name)) return true;
    for ([_][]const u8{ ".lock", ".unpacking" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix) and isDigestName(name[0 .. name.len - suffix.len])) return true;
    }
    return false;
}

// Tests build a cache tree in a temporary directory and date every matched
// entry explicitly relative to the current wall clock.

const testing = std.testing;
const day: i96 = 24 * 60 * 60 * std.time.ns_per_s;

inline fn rep(comptime len: usize, comptime char: u8) [len]u8 {
    return @splat(char);
}
var test_now: std.Io.Timestamp = undefined;

fn begin() testing.TmpDir {
    test_now = std.Io.Timestamp.now(testing.io, .real);
    return testing.tmpDir(.{ .iterate = true });
}

fn put(dir: std.Io.Dir, path: []const u8, age_days: i96) !void {
    const io = testing.io;
    if (std.mem.endsWith(u8, path, "/")) {
        try dir.createDirPath(io, path);
    } else {
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = path, .data = "cached" });
    }
    try age(dir, path, age_days);
}

fn age(dir: std.Io.Dir, path: []const u8, age_days: i96) !void {
    const stamp: std.Io.Timestamp = .{ .nanoseconds = test_now.nanoseconds - age_days * day };
    const times: std.Io.File.SetTimestampsOptions = .{
        .access_timestamp = .{ .new = stamp },
        .modify_timestamp = .{ .new = stamp },
    };
    const sub_path = std.mem.trimEnd(u8, path, "/");
    const stat = try dir.statFile(testing.io, sub_path, .{});
    if (stat.kind != .directory) {
        // Through the handle: setting times by path is not implemented on
        // Windows in Zig 0.17.
        const file = try dir.openFile(testing.io, sub_path, .{ .mode = .read_write });
        defer file.close(testing.io);
        return file.setTimestamps(testing.io, times);
    }
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try dir.setTimestamps(testing.io, sub_path, .{
        .access_timestamp = times.access_timestamp,
        .modify_timestamp = times.modify_timestamp,
    });
}

fn present(dir: std.Io.Dir, path: []const u8) bool {
    return exists(testing.io, dir, path);
}

fn testOptions() Options {
    return .{ .now = test_now, .export_format = "v2", .compiler_cache = compiler_cache.name(@splat(1)) };
}

test "build outputs keep the newest, the accepted and recent ones" {
    var tmp = begin();
    defer tmp.cleanup();
    var names: [8][6 + 32]u8 = undefined;
    var path: [96]u8 = undefined;
    for (&names, 0..) |*name, index| {
        name.* = ("build-" ++ rep(32, 'a')).*;
        name[6] = "0123456789abcdef"[index];
        try put(tmp.dir, try std.fmt.bufPrint(&path, "builds/{s}/firmware/project.uf2", .{name}), 0);
        // Index 0 is the oldest.
        try age(tmp.dir, try std.fmt.bufPrint(&path, "builds/{s}", .{name}), 30 - @as(i96, @intCast(index)));
    }
    try put(tmp.dir, "builds/notes.txt", 90);
    try put(tmp.dir, "builds/build-short/", 90);
    var opts = testOptions();
    opts.keep.build = &names[0];
    const report = clean(testing.allocator, testing.io, tmp.dir, opts);
    try testing.expectEqual(@as(usize, 2), report.deleted);
    try testing.expectEqual(@as(usize, 0), report.failed);
    for (names, 0..) |name, index| {
        const kept = index == 0 or index >= 3;
        try testing.expectEqual(kept, present(tmp.dir, try std.fmt.bufPrint(&path, "builds/{s}", .{&name})));
    }
    try testing.expect(present(tmp.dir, "builds/notes.txt"));
    try testing.expect(present(tmp.dir, "builds/build-short"));

    // Everything recent stays, however many there are.
    var earlier = testOptions();
    earlier.keep_builds = 0;
    earlier.now = .{ .nanoseconds = test_now.nanoseconds - 30 * day };
    try testing.expectEqual(@as(usize, 0), clean(testing.allocator, testing.io, tmp.dir, earlier).deleted);
}

test "compiler caches: legacy and foreign go, the current stays below the cap" {
    var tmp = begin();
    defer tmp.cleanup();
    const io = testing.io;
    const current = compiler_cache.name(@splat(1));
    const foreign = compiler_cache.name(@splat(2));
    const busy = compiler_cache.name(@splat(3));
    const legacy = rep(64, 'b');
    const legacy_active = rep(64, 'c');
    var path: [160]u8 = undefined;
    for ([_][]const u8{ &current, &foreign, &busy, &legacy, &legacy_active }) |name| {
        try put(tmp.dir, try std.fmt.bufPrint(&path, "builds/compiler-cache/{s}/global/o/x", .{name}), 40);
        try put(tmp.dir, try std.fmt.bufPrint(&path, "builds/compiler-cache/{s}/local/o/y", .{name}), 40);
        inline for (.{ "", "/global", "/global/o", "/local", "/local/o" }) |sub| {
            try age(tmp.dir, try std.fmt.bufPrint(&path, "builds/compiler-cache/{s}" ++ sub, .{name}), 40);
        }
    }
    // An earlier-layout build is still writing here.
    try age(tmp.dir, "builds/compiler-cache/" ++ legacy_active ++ "/local/o", 0);
    try put(tmp.dir, "builds/compiler-cache/README", 40);
    // An interrupted deletion of an earlier cleanup.
    try put(tmp.dir, "builds/compiler-cache/" ++ rep(64, 'e') ++ ".trash/global/o/z", 0);
    var caches = try tmp.dir.openDir(io, "builds/compiler-cache", .{});
    defer caches.close(io);
    var held = try compiler_cache.Lease.acquire(io, caches, &busy, .fromSeconds(1));
    defer held.release(io);
    var lock_buffer: [64]u8 = undefined;
    const orphan = try compiler_cache.lockName(&lock_buffer, &compiler_cache.name(@splat(4)));
    try put(caches, orphan, 40);
    var current_lease = try compiler_cache.Lease.acquire(io, caches, &current, .fromSeconds(1));
    current_lease.release(io);
    var current_lock_buffer: [64]u8 = undefined;
    const current_lock = try compiler_cache.lockName(&current_lock_buffer, &current);
    var foreign_lock_buffer: [64]u8 = undefined;
    const foreign_lock = try compiler_cache.lockName(&foreign_lock_buffer, &foreign);

    const report = clean(testing.allocator, io, tmp.dir, testOptions());
    try testing.expectEqual(@as(usize, 3), report.deleted);
    try testing.expectEqual(@as(usize, 0), report.failed);
    try testing.expectEqual(@as(u64, 4 * "cached".len), report.compiler_cache_bytes);
    try testing.expect(present(caches, &current));
    try testing.expect(present(caches, current_lock));
    try testing.expect(!present(caches, &foreign));
    try testing.expect(!present(caches, foreign_lock));
    try testing.expect(present(caches, &busy));
    try testing.expect(!present(caches, &legacy));
    try testing.expect(present(caches, &legacy_active));
    try testing.expect(!present(caches, orphan));
    try testing.expect(present(caches, "README"));
    try testing.expect(!present(caches, rep(64, 'e') ++ ".trash"));
    try testing.expect(!present(caches, &legacy ++ ".trash"));

    // Above the cap the current cache is dropped, but never while in use.
    var capped = testOptions();
    capped.compiler_cache_cap = 2;
    var building = try compiler_cache.Lease.acquire(io, caches, &current, .fromSeconds(1));
    try testing.expectEqual(@as(usize, 0), clean(testing.allocator, io, tmp.dir, capped).deleted);
    try testing.expect(present(caches, &current));
    building.release(io);
    try testing.expectEqual(@as(usize, 1), clean(testing.allocator, io, tmp.dir, capped).deleted);
    try testing.expect(!present(caches, &current));
    try testing.expect(present(caches, current_lock));
    // Without a known compiler no cache is touched.
    var unknown = testOptions();
    unknown.compiler_cache = null;
    try testing.expectEqual(@as(usize, 0), clean(testing.allocator, io, tmp.dir, unknown).deleted);
    try testing.expect(present(caches, &busy));
}

test "exports keep the current format's newest and accepted snapshots" {
    var tmp = begin();
    defer tmp.cleanup();
    var path: [128]u8 = undefined;
    for (0..4) |index| {
        var name = rep(64, 'd');
        name[0] = "0123"[index];
        try put(tmp.dir, try std.fmt.bufPrint(&path, "exports/v2/{s}/keymap.zig", .{&name}), 10);
        try age(tmp.dir, try std.fmt.bufPrint(&path, "exports/v2/{s}", .{&name}), 10 - @as(i96, @intCast(index)));
    }
    try put(tmp.dir, "exports/" ++ rep(64, 'e') ++ "/keymap.zig", 50);
    try age(tmp.dir, "exports/" ++ rep(64, 'e'), 50);
    try put(tmp.dir, "exports/v1/", 50);
    try put(tmp.dir, "exports/v3/", 50);
    try put(tmp.dir, "exports/mine/", 50);
    var opts = testOptions();
    opts.keep_exports = 2;
    opts.keep.export_name = "0" ++ rep(63, 'd');
    const report = clean(testing.allocator, testing.io, tmp.dir, opts);
    try testing.expectEqual(@as(usize, 3), report.deleted);
    try testing.expect(present(tmp.dir, "exports/v2/0" ++ rep(63, 'd')));
    try testing.expect(!present(tmp.dir, "exports/v2/1" ++ rep(63, 'd')));
    try testing.expect(present(tmp.dir, "exports/v2/2" ++ rep(63, 'd')));
    try testing.expect(present(tmp.dir, "exports/v2/3" ++ rep(63, 'd')));
    try testing.expect(!present(tmp.dir, "exports/" ++ rep(64, 'e')));
    try testing.expect(!present(tmp.dir, "exports/v1"));
    try testing.expect(present(tmp.dir, "exports/v3"));
    try testing.expect(present(tmp.dir, "exports/mine"));
}

test "flash copies, imports, editor environment and runtimes" {
    var tmp = begin();
    defer tmp.cleanup();
    var path: [160]u8 = undefined;
    for (0..3) |index| {
        var name = rep(64, 'f');
        name[0] = "012"[index];
        try put(tmp.dir, try std.fmt.bufPrint(&path, "flash/{s}.uf2", .{&name}), 10 - @as(i96, @intCast(index)));
        var nonce = rep(32, 'a');
        nonce[0] = "012"[index];
        try put(tmp.dir, try std.fmt.bufPrint(&path, "imports/capture-{s}/capture.zon", .{&nonce}), 10);
        try age(tmp.dir, try std.fmt.bufPrint(&path, "imports/capture-{s}", .{&nonce}), 10 - @as(i96, @intCast(index)));
    }
    try put(tmp.dir, "flash/" ++ rep(64, '9'), 30);
    try put(tmp.dir, "flash/firmware.uf2", 30);
    try put(tmp.dir, "imports/compiler-global/o/big", 30);
    try put(tmp.dir, "imports/compiler-local/o/big", 30);
    try age(tmp.dir, "imports/compiler-global", 30);
    try age(tmp.dir, "imports/compiler-local", 30);
    try put(tmp.dir, "editor-environment/packages/p", 40);
    try age(tmp.dir, "editor-environment", 40);
    inline for (.{ "1", "2" }) |id| {
        try put(tmp.dir, "runtime/" ++ rep(64, id[0]) ++ "/.complete", 20);
        try age(tmp.dir, "runtime/" ++ rep(64, id[0]), 20);
        try put(tmp.dir, "runtime/" ++ rep(64, id[0]) ++ ".lock", 20);
    }
    try put(tmp.dir, "projects/My Keyboards/project.zon", 400);

    var opts = testOptions();
    opts.keep_flash = 1;
    opts.keep_imports = 1;
    opts.keep.flash = "0" ++ rep(63, 'f') ++ ".uf2";
    // Without a runtime id and below the import cache cap, both stay.
    try testing.expectEqual(@as(usize, 5), clean(testing.allocator, testing.io, tmp.dir, opts).deleted);
    try testing.expect(present(tmp.dir, "flash/0" ++ rep(63, 'f') ++ ".uf2"));
    try testing.expect(!present(tmp.dir, "flash/1" ++ rep(63, 'f') ++ ".uf2"));
    try testing.expect(present(tmp.dir, "flash/2" ++ rep(63, 'f') ++ ".uf2"));
    try testing.expect(!present(tmp.dir, "flash/" ++ rep(64, '9')));
    try testing.expect(present(tmp.dir, "flash/firmware.uf2"));
    try testing.expect(!present(tmp.dir, "imports/capture-0" ++ rep(31, 'a')));
    try testing.expect(!present(tmp.dir, "imports/capture-1" ++ rep(31, 'a')));
    try testing.expect(present(tmp.dir, "imports/capture-2" ++ rep(31, 'a')));
    try testing.expect(present(tmp.dir, "imports/compiler-global"));
    try testing.expect(!present(tmp.dir, "editor-environment"));
    try testing.expect(present(tmp.dir, "runtime/" ++ rep(64, '2')));

    opts.runtime = rep(64, '1');
    opts.import_cache_cap = 2 * "cached".len - 1;
    try testing.expectEqual(@as(usize, 4), clean(testing.allocator, testing.io, tmp.dir, opts).deleted);
    try testing.expect(!present(tmp.dir, "imports/compiler-global"));
    try testing.expect(!present(tmp.dir, "imports/compiler-local"));
    try testing.expect(present(tmp.dir, "runtime/" ++ rep(64, '1')));
    try testing.expect(present(tmp.dir, "runtime/" ++ rep(64, '1') ++ ".lock"));
    try testing.expect(!present(tmp.dir, "runtime/" ++ rep(64, '2')));
    try testing.expect(!present(tmp.dir, "runtime/" ++ rep(64, '2') ++ ".lock"));
    try testing.expect(present(tmp.dir, "projects/My Keyboards/project.zon"));
    try testing.expectEqual(@as(usize, 0), clean(testing.allocator, testing.io, tmp.dir, opts).deleted);
}
