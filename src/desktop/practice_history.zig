//! SQLite practice history, legacy import and bounded background query results.
//! Current-schema refreshes use read-only connections and one consistent snapshot.
const std = @import("std");
const results = @import("practice_results.zig");
const database = @import("practice_database.zig");
const timing = @import("practice_timing.zig");
const progress = @import("practice_progress.zig");
const analysis = @import("practice_analysis.zig");
const retention = @import("practice_retention.zig");
pub const Record = results.Record;
pub const max_record_bytes = 512 * 1024;

pub const Query = struct {
    all: results.Aggregate = .{},
    recent: results.Aggregate = .{},
    page: []Record = &.{},
    page_count: usize = 0,
    rejected: usize = 0,
    total: usize = 0,
    requested_id: ?[16]u8 = null,
    contains_requested: bool = false,
    oldest_recent: ?Record = null,
    recent_ids: [10][16]u8 = @splat(@splat(0)),
    recent_count: usize = 0,
    progress: ?*progress.Summary = null,
    progress_allocator: std.mem.Allocator = std.heap.page_allocator,
    requested_record: ?Record = null,
    latest_curriculum: ?Record = null,
    timing: ?timing.Owned = null,
    analysis: ?*analysis.Summary = null,
    retention: ?*retention.Summary = null,
    database_runs: usize = 0,
    database_events: usize = 0,
    exported: bool = false,
    imported: ?usize = null,

    pub fn deinit(self: *Query) void {
        if (self.page.len != 0) self.progress_allocator.free(self.page);
        self.page = &.{};
        if (self.progress) |value| self.progress_allocator.destroy(value);
        if (self.timing) |*value| value.deinit();
        if (self.analysis) |value| self.progress_allocator.destroy(value);
        if (self.retention) |value| self.progress_allocator.destroy(value);
        self.progress = null;
        self.timing = null;
        self.analysis = null;
        self.retention = null;
    }

    /// Records the newest scored runs, ordered newest first.
    fn setRecent(self: *Query, newest: []const Record) !void {
        for (newest, 0..) |*record, index| {
            try self.recent.add(record);
            self.recent_ids[index] = record.id;
        }
        self.recent_count = newest.len;
        if (newest.len == 10) self.oldest_recent = newest[9];
    }
};

pub fn newer(a: Record, b: Record) bool {
    return if (a.timestamp == b.timestamp) std.mem.order(u8, &a.id, &b.id) == .gt else a.timestamp > b.timestamp;
}

fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Record {
    const terminated = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(terminated);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const record = try std.zon.parse.fromSlice(Record, .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = terminated,
        .diagnostics = &diagnostics,
    });
    try record.validate();
    return record;
}

fn filename(id: [16]u8, buffer: *[36]u8) []const u8 {
    const hex = std.fmt.bytesToHex(id, .lower);
    @memcpy(buffer[0..32], &hex);
    @memcpy(buffer[32..], ".zon");
    return buffer;
}

pub fn save(gpa: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, record: *const Record) !void {
    try record.validate();
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try std.zon.stringify.serializeMaxDepth(record.*, .{}, &encoded.writer, 32);
    if (encoded.written().len > max_record_bytes) return error.PracticeRecordTooLarge;
    var name: [36]u8 = undefined;
    var atomic = try directory.createFileAtomic(io, filename(record.id, &name), .{});
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded.written());
    try atomic.file.sync(io);
    atomic.link(io) catch |err| {
        if (err != error.PathAlreadyExists) return err;
        const old = try directory.readFileAlloc(io, &name, gpa, .limited(max_record_bytes));
        defer gpa.free(old);
        if (!std.mem.eql(u8, old, encoded.written())) return error.PracticeRunCollision;
    };
}

/// Each page uses a frozen exclusive upper boundary. New writes cannot make
/// older pages duplicate runs. All-history aggregation still includes every run.
pub fn query(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    cohort: results.Cohort,
    before: ?Record,
) !Query {
    return queryTracked(gpa, io, directory, cohort, before, null);
}

fn queryTracked(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    cohort: results.Cohort,
    before: ?Record,
    current_id: ?[16]u8,
) !Query {
    var output: Query = .{ .requested_id = current_id, .progress_allocator = gpa };
    errdefer output.deinit();
    output.page = try gpa.alloc(Record, 10);
    @memset(output.page, .{});
    var newest: [10]Record = @splat(.{});
    var newest_count: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!isRecordFile(entry)) continue;
        const bytes = directory.readFileAlloc(io, entry.name, gpa, .limited(max_record_bytes)) catch {
            output.rejected += 1;
            continue;
        };
        defer gpa.free(bytes);
        const record = parse(gpa, bytes) catch {
            output.rejected += 1;
            continue;
        };
        var name: [36]u8 = undefined;
        if (!std.mem.eql(u8, entry.name, filename(record.id, &name))) {
            output.rejected += 1;
            continue;
        }
        if (!std.meta.eql(record.cohort, cohort)) continue;
        output.total += 1;
        if (current_id) |id| {
            if (std.mem.eql(u8, &id, &record.id)) {
                output.contains_requested = true;
            }
        }
        try output.all.add(&record);
        if (record.scored) insert(&newest, &newest_count, record);
        if (before) |boundary| if (!newer(boundary, record)) continue;
        insert(output.page, &output.page_count, record);
    }
    try output.setRecent(newest[0..newest_count]);
    return output;
}

fn insert(page: []Record, count: *usize, record: Record) void {
    var index: usize = 0;
    while (index < count.* and !newer(record, page[index])) : (index += 1) {}
    if (index >= 10) return;
    const end = @min(count.*, 9);
    var dest = end;
    while (dest > index) : (dest -= 1) page[dest] = page[dest - 1];
    page[index] = record;
    count.* = @min(count.* + 1, 10);
}

/// Explicit clearing first validates every named result. Corrupt/future files
/// are retained and require deliberate user handling rather than silent loss.
pub fn clear(gpa: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !void {
    var iterator = directory.iterate();
    var names: std.ArrayList([36]u8) = .empty;
    defer names.deinit(gpa);
    while (try iterator.next(io)) |entry| {
        if (!isRecordFile(entry)) continue;
        const bytes = try directory.readFileAlloc(io, entry.name, gpa, .limited(max_record_bytes));
        defer gpa.free(bytes);
        const record = try parse(gpa, bytes);
        var name: [36]u8 = undefined;
        if (!std.mem.eql(u8, entry.name, filename(record.id, &name))) return error.InvalidPracticeHistory;
        try names.append(gpa, name);
    }
    for (names.items) |name| try directory.deleteFile(io, &name);
}

pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    captured: [32]u8 = @splat(0),
    cohort: results.Cohort,
    record: ?Record = null,
    before: ?Record = null,
    clearing: bool = false,
    current_id: ?[16]u8 = null,
    timing: ?timing.Payload = null,
    transfer: enum { none, export_database, import_database } = .none,
    transfer_path: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, path: []const u8, cohort: results.Cohort) !Request {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const owned_path = try arena.allocator().dupe(u8, path);
        return .{ .arena = arena, .path = owned_path, .cohort = cohort };
    }

    pub fn deinit(self: *Request) void {
        self.arena.deinit();
    }

    pub fn prepare(self: *Request, gpa: std.mem.Allocator, io: std.Io) !Query {
        const directory = try self.openDirectory(io) orelse return .{};
        defer directory.close(io);
        const root = try directory.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(root);
        const path = try std.fs.path.join(gpa, &.{ root, database.filename });
        defer gpa.free(path);
        const existing = directory.openFile(io, database.filename, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |file| file.close(io);
        const writes = self.record != null or self.transfer != .none or self.clearing;
        if (existing == null and !writes and !try hasRecordFiles(io, directory)) return .{};
        const mutating = self.record != null or self.clearing or self.transfer == .import_database;
        var db = try database.Database.open(gpa, io, path, existing != null and !mutating);
        defer db.deinit();
        if (!try db.currentSchema()) try db.makeWritable(io, path);
        const rejected = try importLegacyFiles(gpa, io, directory, &db, path);
        if (self.clearing) {
            if (rejected != 0) return error.InvalidPracticeHistory;
            try db.clear();
        }
        if (self.record) |*record| try db.save(record, self.timing);

        var output: Query = .{
            .requested_id = self.current_id,
            .rejected = rejected,
            .progress_allocator = gpa,
        };
        errdefer output.deinit();
        output.page = try gpa.alloc(Record, 10);
        @memset(output.page, .{});
        output.progress = try gpa.create(progress.Summary);
        output.progress.?.* = .{};
        output.retention = try gpa.create(retention.Summary);
        output.retention.?.* = .{ .now = @intCast(std.Io.Clock.real.now(io).toNanoseconds()) };
        output.progress.?.today = @divFloor(
            @as(i64, @intCast(std.Io.Clock.real.now(io).toNanoseconds())),
            progress.day_ns,
        );
        switch (self.transfer) {
            .none => {},
            .export_database => {
                try db.exportDatabase(io, self.transfer_path);
                output.exported = true;
            },
            .import_database => output.imported = try db.importDatabase(self.transfer_path),
        }
        try db.exec("BEGIN");
        defer db.exec("ROLLBACK") catch {};
        output.database_runs = try db.runCount();
        try self.collectCohortRuns(gpa, &db, &output);
        // Raw payloads are decoded one at a time on this background worker.
        // The GUI receives only bounded derived character timing summaries.
        for (output.progress.?.points[0..output.progress.?.count]) |*point| {
            if (!point.timing) continue;
            if (try db.timingFor(point.id, gpa)) |value| {
                var owned = value;
                defer owned.deinit();
                try point.enrich(gpa, owned.payload);
            }
        }
        output.database_events = try db.eventCount();
        try self.collectPracticeRuns(gpa, &db, &output);
        if (output.requested_record) |record| {
            if (record.timing_available) {
                output.timing = try db.timingFor(record.id, gpa);
                if (output.timing) |owned| output.analysis = try analysis.analyze(gpa, owned.payload);
            }
        }
        return output;
    }

    /// Returns null for a missing history that this request only reads:
    /// only a completed save or a transfer creates the directory.
    fn openDirectory(self: *const Request, io: std.Io) !?std.Io.Dir {
        const cwd = std.Io.Dir.cwd();
        if (self.record != null or self.transfer != .none) {
            return try cwd.createDirPathOpen(io, self.path, .{ .open_options = .{ .iterate = true } });
        }
        return cwd.openDir(io, self.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    /// Aggregates the stored runs of the requested cohort into `output`.
    fn collectCohortRuns(
        self: *const Request,
        gpa: std.mem.Allocator,
        db: *database.Database,
        output: *Query,
    ) !void {
        var rows = try db.rowsFor(self.cohort);
        defer rows.deinit();
        var newest: [10]Record = @splat(.{});
        var newest_count: usize = 0;
        while (try rows.step()) {
            const record = parse(gpa, try rows.blob(1)) catch |err| {
                if (err == error.UnsupportedPracticeHistory) return err;
                output.rejected += 1;
                continue;
            };
            if (!std.mem.eql(u8, try rows.blob(0), &record.id)) {
                output.rejected += 1;
                continue;
            }
            if (!std.meta.eql(record.cohort, self.cohort)) continue;
            output.total += 1;
            if (self.current_id) |id| {
                if (std.mem.eql(u8, &id, &record.id)) {
                    output.contains_requested = true;
                    output.requested_record = record;
                }
            }
            output.progress.?.add(&record);
            try output.all.add(&record);
            if (record.scored) insert(&newest, &newest_count, record);
            if (self.before) |boundary| if (!newer(boundary, record)) continue;
            insert(output.page, &output.page_count, record);
        }
        try output.setRecent(newest[0..newest_count]);
    }

    /// Feeds retention and the latest curriculum run from every run of the
    /// same practice, across verification and assistance variants.
    fn collectPracticeRuns(
        self: *const Request,
        gpa: std.mem.Allocator,
        db: *database.Database,
        output: *Query,
    ) !void {
        var rows = try db.rowsForPractice(self.cohort);
        defer rows.deinit();
        while (try rows.step()) {
            const candidate = parse(gpa, try rows.blob(1)) catch |err| {
                if (err == error.UnsupportedPracticeHistory) return err;
                continue;
            };
            if (!std.mem.eql(u8, &candidate.id, try rows.blob(0))) continue;
            if (!std.meta.eql(database.practiceKey(candidate.cohort), database.practiceKey(self.cohort))) continue;
            if (candidate.cohort.verified == self.cohort.verified) output.retention.?.add(&candidate);
            if (output.latest_curriculum == null and
                candidate.cohort.curriculum.version == 1 and
                candidate.scored and
                candidate.status == .completed and
                candidate.cohort.mode == .normal)
            {
                output.latest_curriculum = candidate;
            }
        }
    }
};

fn isRecordFile(entry: std.Io.Dir.Entry) bool {
    return entry.kind == .file and entry.name.len == 36 and std.mem.endsWith(u8, entry.name, ".zon");
}

fn hasRecordFiles(io: std.Io, directory: std.Io.Dir) !bool {
    var entries = directory.iterate();
    var found = false;
    while (try entries.next(io)) |entry| {
        if (isRecordFile(entry)) found = true;
    }
    return found;
}

/// Imports legacy ZON record files into the database once. Returns the
/// number of files that were rejected as unreadable, misnamed or colliding.
fn importLegacyFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    db: *database.Database,
    path: []const u8,
) !usize {
    var rejected: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!isRecordFile(entry)) continue;
        const bytes = directory.readFileAlloc(io, entry.name, gpa, .limited(max_record_bytes)) catch {
            rejected += 1;
            continue;
        };
        defer gpa.free(bytes);
        const legacy = parse(gpa, bytes) catch |err| {
            if (err == error.UnsupportedPracticeHistory) return err;
            rejected += 1;
            continue;
        };
        var name: [36]u8 = undefined;
        if (!std.mem.eql(u8, entry.name, filename(legacy.id, &name))) {
            rejected += 1;
            continue;
        }
        const imported = db.legacyImported(&legacy) catch |err| switch (err) {
            error.PracticeRunCollision => {
                rejected += 1;
                continue;
            },
            else => return err,
        };
        if (imported) continue;
        try db.makeWritable(io, path);
        db.importLegacy(&legacy) catch |err| switch (err) {
            error.PracticeRunCollision => rejected += 1,
            else => return err,
        };
    }
    return rejected;
}

pub const Worker = @import("owned_worker.zig").Owner(Request, Query, error.InvalidPracticeGeneration);

test "frozen legacy ZON imports unchanged and unsupported current payloads remain visible as errors" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const raw = @embedFile("fixtures/record-v1.zon");
    const record = try parse(t.allocator, raw);
    var name: [36]u8 = undefined;
    try temp.dir.writeFile(t.io, .{ .sub_path = filename(record.id, &name), .data = raw });
    var request = try Request.init(t.allocator, root, .{});
    defer request.deinit();
    var loaded = try request.prepare(t.allocator, t.io);
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 1), loaded.database_runs);
    const path = try std.fs.path.join(t.allocator, &.{ root, database.filename });
    defer t.allocator.free(path);
    var db = try database.Database.open(t.allocator, t.io, path, false);
    defer db.deinit();
    try db.exec("UPDATE runs SET record=CAST('.{ .version=999 }' AS BLOB)");
    try t.expectError(error.UnsupportedPracticeHistory, request.prepare(t.allocator, t.io));
    try t.expectEqual(@as(usize, 1), try db.runCount());
}

test "immutable publication restart pages cohorts weighted history and corrupt preservation" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var record: Record = .{ .matched = 2, .stat_count = 1, .attempts = 3, .correct_attempts = 2 };
    record.stats[0] = .{ .cp = ';', .opportunities = 2, .misses = 1 };
    for (0..12) |index| {
        record.id[0] = @intCast(index);
        record.timestamp = @intCast(index);
        try save(t.allocator, t.io, temp.dir, &record);
        try save(t.allocator, t.io, temp.dir, &record);
    }
    var first = try query(t.allocator, t.io, temp.dir, .{}, null);
    defer first.deinit();
    try t.expectEqual(@as(u64, 12), first.all.runs);
    try t.expectEqual(@as(u64, 10), first.recent.runs);
    try t.expectEqual(@as(usize, 10), first.recent_count);
    try t.expectEqual(@as(u8, 11), first.recent_ids[0][0]);
    try t.expectEqual(@as(u8, 2), first.recent_ids[9][0]);
    try t.expectEqual(@as(i64, 11), first.page[0].timestamp);
    var second = try query(t.allocator, t.io, temp.dir, .{}, first.page[9]);
    defer second.deinit();
    try t.expectEqual(@as(usize, 2), second.page_count);
    // Paging old runs must retain the newest baseline membership, rather than
    // treating every requested historical ID as part of the recent ten.
    try t.expectEqual(first.recent_ids, second.recent_ids);
    record.cohort.assistance = .hidden;
    record.id[0] = 40;
    try save(t.allocator, t.io, temp.dir, &record);
    var again = try query(t.allocator, t.io, temp.dir, .{}, null);
    defer again.deinit();
    try t.expectEqual(@as(u64, 12), again.all.runs);
    record.cohort.assistance = .guided;
    try t.expectError(error.PracticeRunCollision, save(t.allocator, t.io, temp.dir, &record));
    var corrupt_name: [36]u8 = undefined;
    try temp.dir.writeFile(t.io, .{
        .sub_path = filename(@splat(99), &corrupt_name),
        .data = ".{ .version = 999 }",
    });
    var partial = try query(t.allocator, t.io, temp.dir, .{}, null);
    defer partial.deinit();
    try t.expectEqual(@as(usize, 1), partial.rejected);
    if (clear(t.allocator, t.io, temp.dir)) |_| return error.ExpectedHistoryPreservation else |_| {}
    var retained = try query(t.allocator, t.io, temp.dir, .{}, null);
    defer retained.deinit();
    try t.expectEqual(@as(u64, 12), retained.all.runs);
    try temp.dir.deleteFile(t.io, &corrupt_name);
    try clear(t.allocator, t.io, temp.dir);
    var empty = try query(t.allocator, t.io, temp.dir, .{}, null);
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.total);
}

test "history refresh stays read-only while another instance holds the writer lock" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var request = try Request.init(t.allocator, root, .{});
    defer request.deinit();
    // An existing empty directory must not create a database merely for viewing.
    var empty = try request.prepare(t.allocator, t.io);
    defer empty.deinit();
    try t.expectError(error.FileNotFound, temp.dir.openFile(t.io, database.filename, .{}));
    const record: Record = .{ .id = @splat(9) };
    try save(t.allocator, t.io, temp.dir, &record);
    var migrated = try request.prepare(t.allocator, t.io);
    defer migrated.deinit();
    const path = try std.fs.path.join(t.allocator, &.{ root, database.filename });
    defer t.allocator.free(path);
    var writer = try database.Database.open(t.allocator, t.io, path, false);
    defer writer.deinit();
    try writer.exec("BEGIN IMMEDIATE");
    defer writer.exec("ROLLBACK") catch {};
    // The retained legacy file is already imported and must not force a writer.
    var queried = try request.prepare(t.allocator, t.io);
    defer queried.deinit();
    try t.expectEqual(@as(usize, 1), queried.database_runs);
    try t.expectEqual(@as(usize, 1), queried.total);
}

test "native Unicode directories atomic interruption and independent writers preserve prior runs" {
    const t = std.testing;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var directory = try temp.dir.createDirPathOpen(
        t.io,
        "practice data café",
        .{ .open_options = .{ .iterate = true } },
    );
    defer directory.close(t.io);
    const Writer = struct {
        fn write(io: std.Io, dir: std.Io.Dir, id: u8) !void {
            var record: Record = .{};
            record.id[0] = id;
            try save(std.heap.page_allocator, io, dir, &record);
        }
    };
    var first = try std.Io.concurrent(t.io, Writer.write, .{ t.io, directory, @as(u8, 1) });
    var second = try std.Io.concurrent(t.io, Writer.write, .{ t.io, directory, @as(u8, 2) });
    try first.await(t.io);
    try second.await(t.io);
    var interrupted = try directory.createFileAtomic(t.io, "00000000000000000000000000000000.zon", .{});
    defer interrupted.deinit(t.io);
    try interrupted.file.writeStreamingAll(t.io, "unfinished result");
    var restored = try query(t.allocator, t.io, directory, .{}, null);
    defer restored.deinit();
    try t.expectEqual(@as(usize, 2), restored.total);
    try t.expectEqual(@as(usize, 0), restored.rejected);
    try directory.writeFile(t.io, .{ .sub_path = "project.zon", .data = "unrelated project is preserved" });
    try clear(t.allocator, t.io, directory);
    const project = try directory.readFileAlloc(t.io, "project.zon", t.allocator, .limited(100));
    defer t.allocator.free(project);
    try t.expectEqualStrings("unrelated project is preserved", project);
}
