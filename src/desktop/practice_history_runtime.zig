//! Serialized background persistence. Failed records remain queued for Retry.
const std = @import("std");
const history = @import("practice_history.zig");
const results = @import("practice_results.zig");
const timing = @import("practice_timing.zig");

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: ?[]u8 = null,
    worker: ?*history.Worker = null,
    sequence: u64 = 0,
    queue: []results.Record = &.{},
    queued: usize = 0,
    timings: [16]?timing.Owned = @splat(null),
    writing: bool = false,
    clearing: bool = false,
    data: history.Query = .{},
    cohort: results.Cohort = .{},
    requested_cohort: results.Cohort = .{},
    error_value: ?anyerror = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, data_path: ?[]const u8) !Runtime {
        const queue = try gpa.alloc(results.Record, 16);
        errdefer gpa.free(queue);
        @memset(queue, .{});
        return .{
            .gpa = gpa,
            .io = io,
            .queue = queue,
            .path = if (data_path) |path| try std.fs.path.join(gpa, &.{ path, "typing-practice" }) else null,
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.worker) |worker| {
            if (worker.future) |*future| {
                const outcome = future.await(self.io);
                if (outcome) |value| {
                    var completed_data = value;
                    completed_data.deinit();
                    if (self.clearing) self.discardQueue();
                    if (self.writing) {
                        self.popQueue();
                    }
                } else |err| std.log.err("Practice history shutdown: {s}", .{@errorName(err)});
                worker.future = null;
            }
            worker.destroy();
            self.worker = null;
        }
        // Final shutdown is outside rendering. Drain all completed runs rather
        // than dropping a run queued while another write was in progress.
        if (self.path) |path| {
            for (self.queue[0..self.queued], 0..) |record, index| {
                var final_request = history.Request.init(self.gpa, path, record.cohort) catch |err| {
                    std.log.err("Practice history shutdown: {s}", .{@errorName(err)});
                    break;
                };
                defer final_request.deinit();
                final_request.record = record;
                if (self.timings[index]) |owned| final_request.timing = owned.payload;
                var final_data = final_request.prepare(self.gpa, self.io) catch |err| {
                    std.log.err("Practice history shutdown: {s}", .{@errorName(err)});
                    break;
                };
                final_data.deinit();
            }
            self.gpa.free(path);
        }
        self.discardQueue();
        self.data.deinit();
        self.gpa.free(self.queue);
    }

    pub fn enqueue(self: *Runtime, record: results.Record) !void {
        return self.enqueueWithTiming(record, null);
    }

    pub fn enqueueWithTiming(self: *Runtime, record: results.Record, payload: ?timing.Payload) !void {
        for (self.queue[0..self.queued]) |old| if (std.mem.eql(u8, &old.id, &record.id)) return;
        if (self.queued == self.queue.len) return error.PracticeSaveQueueFull;
        self.timings[self.queued] = if (payload) |value| try timing.Owned.clone(self.gpa, value) else null;
        self.queue[self.queued] = record;
        self.queued += 1;
    }

    fn popQueue(self: *Runtime) void {
        if (self.timings[0]) |*owned| owned.deinit();
        self.queued -= 1;
        std.mem.copyForwards(results.Record, self.queue[0..self.queued], self.queue[1 .. self.queued + 1]);
        std.mem.copyForwards(?timing.Owned, self.timings[0..self.queued], self.timings[1 .. self.queued + 1]);
        self.timings[self.queued] = null;
    }

    fn discardQueue(self: *Runtime) void {
        while (self.queued != 0) self.popQueue();
    }

    pub fn poll(self: *Runtime) void {
        if (self.worker) |worker| {
            if (worker.poll()) |event| {
                defer worker.destroy();
                self.worker = null;
                const data = event.result catch |err| {
                    self.error_value = err;
                    return;
                };
                if (self.clearing) self.discardQueue();
                self.data.deinit();
                self.data = data;
                self.cohort = self.requested_cohort;
                self.error_value = null;
                if (self.writing) {
                    self.popQueue();
                }
            }
        }
    }

    pub fn request(
        self: *Runtime,
        cohort: results.Cohort,
        before: ?results.Record,
        clearing: bool,
        retry: bool,
        current_id: ?[16]u8,
    ) !void {
        if (self.worker != null) return;
        if (self.error_value != null and !retry and !clearing) return;
        const path = self.path orelse return error.PracticeStorageUnavailable;
        var work_request = try history.Request.init(self.gpa, path, cohort);
        errdefer work_request.deinit();
        self.clearing = clearing;
        self.writing = !clearing and self.queued > 0;
        if (self.writing) {
            work_request.record = self.queue[0];
            if (self.timings[0]) |owned| {
                var copy = owned.payload;
                copy.reference = try work_request.arena.allocator().dupe(u21, copy.reference);
                copy.events = try work_request.arena.allocator().dupe(timing.Event, copy.events);
                work_request.timing = copy;
            }
        }
        work_request.before = before;
        work_request.current_id = current_id;
        work_request.clearing = clearing;
        self.sequence += 1;
        self.worker = try history.Worker.create(self.gpa, self.io, &work_request, self.sequence);
        self.requested_cohort = cohort;
        self.error_value = null;
    }

    pub fn transfer(self: *Runtime, cohort: results.Cohort, path: []const u8, importing: bool) !void {
        if (self.worker != null or self.queued != 0) return error.PracticeWritesPending;
        const root = self.path orelse return error.PracticeStorageUnavailable;
        if (!std.fs.path.isAbsolute(path)) return error.AbsolutePracticeDatabasePathRequired;
        var request_value = try history.Request.init(self.gpa, root, cohort);
        errdefer request_value.deinit();
        request_value.transfer = if (importing) .import_database else .export_database;
        request_value.transfer_path = try request_value.arena.allocator().dupe(u8, path);
        self.clearing = false;
        self.writing = false;
        self.sequence += 1;
        self.worker = try history.Worker.create(self.gpa, self.io, &request_value, self.sequence);
        self.requested_cohort = cohort;
        self.error_value = null;
    }
};

/// Polls `runtime` until its background worker finishes, failing after five seconds.
fn finishWorker(runtime: *Runtime) !void {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (runtime.worker != null) {
        runtime.poll();
        if (std.Io.Clock.awake.now(io).toMilliseconds() > deadline) return error.PracticeWorkerDeadline;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}

test "background saves drain once retries retain IDs and reopening restores completed runs" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var runtime = try Runtime.init(t.allocator, t.io, root);
    defer runtime.deinit();
    var record: results.Record = .{};
    record.id[0] = 7;
    try runtime.enqueue(record);
    try runtime.enqueue(record);
    try t.expectEqual(@as(usize, 1), runtime.queued);
    try runtime.request(.{}, null, false, false, record.id);
    try finishWorker(&runtime);
    try t.expect(runtime.error_value == null);
    try t.expectEqual(@as(usize, 0), runtime.queued);
    try t.expect(runtime.data.contains_requested);
    try t.expectEqual(@as(usize, 1), runtime.data.progress.?.count);
    try t.expectEqual(record.id, runtime.data.requested_record.?.id);
    var reopened = try Runtime.init(t.allocator, t.io, root);
    defer reopened.deinit();
    try reopened.request(.{}, null, false, false, null);
    try finishWorker(&reopened);
    try t.expectEqual(@as(usize, 1), reopened.data.total);
    // An unwritable storage route preserves the queued record for explicit retry.
    const valid = runtime.path.?;
    runtime.path = try std.fs.path.join(t.allocator, &.{ root, "not a directory" });
    defer {
        t.allocator.free(runtime.path.?);
        runtime.path = valid;
    }
    try temp.dir.writeFile(t.io, .{ .sub_path = "not a directory", .data = "preserve this file" });
    record.id[0] = 8;
    try runtime.enqueue(record);
    try runtime.request(.{}, null, false, false, record.id);
    try finishWorker(&runtime);
    try t.expect(runtime.error_value != null);
    try t.expectEqual(@as(usize, 1), runtime.queued);
}

test "queue limits and failed deliberate clearing retain pending records" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var runtime = try Runtime.init(t.allocator, t.io, root);
    defer runtime.deinit();
    for (0..16) |index| {
        var record: results.Record = .{};
        record.id[0] = @intCast(index);
        try runtime.enqueue(record);
    }
    var extra: results.Record = .{};
    extra.id[0] = 20;
    try t.expectError(error.PracticeSaveQueueFull, runtime.enqueue(extra));
    var directory = try std.Io.Dir.cwd().createDirPathOpen(t.io, runtime.path.?, .{});
    defer directory.close(t.io);
    try directory.writeFile(t.io, .{
        .sub_path = "00000000000000000000000000000000.zon",
        .data = ".{ .version = 999 }",
    });
    runtime.error_value = error.PracticeSaveQueueFull;
    try runtime.request(.{}, null, true, false, null);
    try finishWorker(&runtime);
    try t.expect(runtime.error_value != null);
    try t.expectEqual(@as(usize, 16), runtime.queued);
    // Explicit fixture cleanup prevents shutdown from trying to publish over
    // the intentionally future record. No pending ID was removed by the failure.
    runtime.queued = 0;
}

test "queued timing is frozen across new exercises; migration and clear do not resurrect old files" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var runtime = try Runtime.init(t.allocator, t.io, root);
    defer runtime.deinit();
    var directory = try std.Io.Dir.cwd().createDirPathOpen(t.io, runtime.path.?, .{
        .open_options = .{ .iterate = true },
    });
    defer directory.close(t.io);
    var legacy = results.Record{ .id = @splat(7) };
    try history.save(t.allocator, t.io, directory, &legacy);
    var recorder = timing.Recorder.init(t.allocator);
    defer recorder.deinit();
    recorder.reset(&.{'a'});
    recorder.record(.attempt, 100, 0, 0, 'a', .ordinary);
    recorder.record(.complete, 100, 0, 1, null, .ordinary);
    var record = results.Record{
        .id = @splat(9),
        .timing_available = true,
        .matched = 1,
        .attempts = 1,
        .correct_attempts = 1,
        .stat_count = 1,
    };
    record.stats[0] = .{ .cp = 'a', .opportunities = 1 };
    try runtime.enqueueWithTiming(record, recorder.payload());
    recorder.reset(&.{'z'});
    try runtime.request(.{}, null, false, false, record.id);
    try finishWorker(&runtime);
    try t.expect(runtime.error_value == null);
    try t.expectEqual(@as(usize, 2), runtime.data.database_runs);
    try t.expectEqual(@as(u21, 'a'), runtime.data.timing.?.payload.reference[0]);
    try t.expectEqual(@as(usize, 0), runtime.data.analysis.?.eligible);
    const db_path = try std.fs.path.join(t.allocator, &.{ runtime.path.?, "practice.sqlite3" });
    defer t.allocator.free(db_path);
    var db = try @import("practice_database.zig").Database.open(t.allocator, t.io, db_path, true);
    defer db.deinit();
    var saved = (try db.timingFor(record.id, t.allocator)).?;
    defer saved.deinit();
    try t.expectEqual(@as(u21, 'a'), saved.payload.reference[0]);
    try runtime.request(.{}, null, true, false, null);
    try finishWorker(&runtime);
    try t.expect(runtime.error_value == null);
    try t.expectEqual(@as(usize, 0), runtime.data.database_runs);
    try t.expect(runtime.data.timing == null and runtime.data.analysis == null);
    try runtime.request(.{}, null, false, false, null);
    try finishWorker(&runtime);
    try t.expectEqual(@as(usize, 0), runtime.data.database_runs);
    var count: usize = 0;
    var entries = directory.iterate();
    while (try entries.next(t.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".zon")) count += 1;
    }
    try t.expectEqual(@as(usize, 1), count);
    legacy.timestamp = 1;
    try t.expectError(error.PracticeRunCollision, history.save(t.allocator, t.io, directory, &legacy));
}

test "curriculum resumes across reopen without merging stage or assistance cohorts" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var runtime = try Runtime.init(t.allocator, t.io, root);
    defer runtime.deinit();
    var record: results.Record = .{ .id = @splat(3), .cohort = .{ .curriculum = .{ .version = 1 } } };
    try runtime.enqueue(record);
    try runtime.request(.{}, null, false, false, null);
    try finishWorker(&runtime);
    try t.expect(runtime.error_value == null);
    try t.expectEqual(@as(usize, 0), runtime.data.total);
    try t.expectEqual(record.id, runtime.data.latest_curriculum.?.id);
    var reopened = try Runtime.init(t.allocator, t.io, root);
    defer reopened.deinit();
    try reopened.request(record.cohort, null, false, false, null);
    try finishWorker(&reopened);
    try t.expect(reopened.error_value == null);
    try t.expectEqual(@as(usize, 1), reopened.data.total);
    record.cohort.assistance = .hidden;
    record.id = @splat(4);
    record.timestamp = 1;
    try reopened.enqueue(record);
    try reopened.request(record.cohort, null, false, false, null);
    try finishWorker(&reopened);
    try t.expectEqual(@as(usize, 1), reopened.data.total);
    try t.expectEqual(record.id, reopened.data.latest_curriculum.?.id);
}
