//! Runs one cache retention pass off the editor thread. The owner copies its
//! inputs; cancelling it at quit leaves at most a retired compiler cache that
//! the next pass deletes.
const std = @import("std");
const jobs = @import("companion-jobs");
const retention = jobs.cache_retention;

pub const Owner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    options: retention.Options,
    future: ?std.Io.Future(retention.Report) = null,
    done: std.atomic.Value(bool) = .init(false),

    pub fn create(gpa: std.mem.Allocator, io: std.Io, root: []const u8, options: retention.Options) !*Owner {
        const self = try gpa.create(Owner);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .root = undefined, .options = options };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.root = try a.dupe(u8, root);
        self.options.export_format = try a.dupe(u8, options.export_format);
        inline for (.{ "build", "export_name", "flash" }) |field| {
            if (@field(options.keep, field)) |name| @field(self.options.keep, field) = try a.dupe(u8, name);
        }
        self.future = try std.Io.concurrent(io, run, .{self});
        return self;
    }

    fn run(self: *Owner) retention.Report {
        defer self.done.store(true, .release);
        const start = std.Io.Clock.awake.now(self.io);
        var root = std.Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) std.log.warn("cache cleanup skipped: {t}", .{err});
            return .{};
        };
        defer root.close(self.io);
        const report = retention.clean(self.gpa, self.io, root, self.options);
        std.log.info("cache cleanup deleted {d} entries, {d} MB of compiler caches, in {d} ms", .{
            report.deleted,
            report.compiler_cache_bytes / (1024 * 1024),
            start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds(),
        });
        return report;
    }

    pub fn poll(self: *Owner) ?retention.Report {
        if (self.future == null or !self.done.load(.acquire)) return null;
        const report = self.future.?.await(self.io);
        self.future = null;
        return report;
    }

    pub fn destroy(self: *Owner) void {
        if (self.future) |*future| _ = future.cancel(self.io);
        self.arena.deinit();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }
};

test "a background pass cleans the cache root and reports once" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "editor-environment/packages");
    const old: std.Io.Timestamp = .{ .nanoseconds = std.Io.Timestamp.now(io, .real).nanoseconds - 2 * 24 * 60 * 60 * std.time.ns_per_s };
    try tmp.dir.setTimestamps(io, "editor-environment", .{ .modify_timestamp = .{ .new = old } });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var keep = "build-0123".*;
    const owner = try Owner.create(std.testing.allocator, io, root, .{
        .now = std.Io.Timestamp.now(io, .real),
        .export_format = "v2",
        .keep = .{ .build = &keep },
    });
    defer owner.destroy();
    keep[0] = 'X';
    const report = while (true) {
        if (owner.poll()) |value| break value;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    };
    try std.testing.expectEqual(@as(usize, 1), report.deleted);
    try std.testing.expectEqualStrings("build-0123", owner.options.keep.build.?);
    try std.testing.expect(owner.poll() == null);
    _ = tmp.dir.statFile(io, "editor-environment", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestExpectedDeletion;
}
