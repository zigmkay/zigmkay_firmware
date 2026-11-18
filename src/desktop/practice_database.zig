//! Practice schema and transactions over zqlite; existing database bytes remain compatible.
const std = @import("std");
const results = @import("practice_results.zig");
const timing = @import("practice_timing.zig");
const zqlite = @import("zqlite");
const c = zqlite.c;
pub const filename = "practice.sqlite3";
pub const max_payload_bytes = 16 * 1024 * 1024;
const application_id = 0x5a4d5052;

// Keep application diagnostics stable across the wrapper migration.
fn databaseError(err: anyerror) anyerror {
    const name = @errorName(err);
    if (std.mem.startsWith(u8, name, "Busy") or
        std.mem.startsWith(u8, name, "Locked")) return error.PracticeDatabaseBusy;
    if (std.mem.startsWith(u8, name, "Readonly") or
        err == error.ReadOnly or
        err == error.Perm) return error.PracticeDatabaseReadOnly;
    if (std.mem.startsWith(u8, name, "Ioerr") or
        err == error.IoErr or
        err == error.Full or
        err == error.CantOpen) return error.PracticeDatabaseIO;
    if (std.mem.startsWith(u8, name, "Constraint")) return error.PracticeRunCollision;
    return switch (err) {
        error.NoMem => error.OutOfMemory,
        error.Corrupt, error.NotADB => error.InvalidPracticeDatabase,
        else => error.PracticeDatabaseFailure,
    };
}

// The wrapper exposes SQLite's header for the online backup API.
fn check(code: c_int) !void {
    return switch (code & 0xff) {
        0 => {},
        5, 6 => error.PracticeDatabaseBusy,
        7 => error.OutOfMemory,
        8, 3 => error.PracticeDatabaseReadOnly,
        10, 13, 14 => error.PracticeDatabaseIO,
        11, 26 => error.InvalidPracticeDatabase,
        19 => error.PracticeRunCollision,
        else => error.PracticeDatabaseFailure,
    };
}

pub const Statement = struct {
    raw: zqlite.Stmt,
    retained: ?[]u8 = null,
    gpa: ?std.mem.Allocator = null,

    pub fn deinit(self: *Statement) void {
        self.raw.deinit();
        if (self.retained) |bytes| self.gpa.?.free(bytes);
    }

    pub fn step(self: *Statement) !bool {
        return self.raw.step() catch |err| return databaseError(err);
    }

    pub fn blob(self: *Statement, column: usize) ![]const u8 {
        if (self.raw.columnType(column) != .blob) return error.InvalidPracticeDatabase;
        if (self.raw.columnBytes(column) > max_payload_bytes) return error.InvalidPracticeDatabase;
        return self.raw.blob(column);
    }

    fn bindBlob(self: *Statement, index: usize, bytes: []const u8) !void {
        if (bytes.len > max_payload_bytes) return error.PracticeRecordTooLarge;
        // zqlite borrows blobs until finalization; callers retain the bytes.
        self.raw.bindValue(zqlite.blob(bytes), index - 1) catch |err| return databaseError(err);
    }

    fn integer(self: *Statement, index: usize, value: i64) !void {
        self.raw.bindValue(value, index - 1) catch |err| return databaseError(err);
    }

    fn bindNull(self: *Statement, index: usize) !void {
        self.raw.bindValue(@as(?i64, null), index - 1) catch |err| return databaseError(err);
    }
};

pub fn encode(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    try std.zon.stringify.serializeMaxDepth(value, .{}, &out.writer, 32);
    if (out.written().len > max_payload_bytes) return error.PracticeRecordTooLarge;
    return gpa.dupe(u8, out.written());
}

// Preserve the original indexed key for count-only and pre-curriculum records.
// Adding defaulted fields to the public model must not hide historical cohorts.
pub fn cohortKey(gpa: std.mem.Allocator, cohort: results.Cohort) ![]u8 {
    const base = .{
        .behavior = cohort.behavior,
        .mapping = cohort.mapping,
        .verified = cohort.verified,
        .source = cohort.source,
        .family = cohort.family,
        .preset = cohort.preset,
        .length = cohort.length,
        .assistance = cohort.assistance,
        .mode = cohort.mode,
        .metric_version = cohort.metric_version,
        .generation_version = cohort.generation_version,
        .lesson = cohort.lesson,
    };
    if (cohort.hints.policy != .full or cohort.hints.revealed) {
        return encode(gpa, .{
            .version = @as(u16, 3),
            .base = base,
            .curriculum = cohort.curriculum,
            .hints = cohort.hints,
        });
    }
    if (cohort.curriculum.version == 0) return encode(gpa, base);
    return encode(gpa, .{ .version = @as(u16, 2), .base = base, .curriculum = cohort.curriculum });
}

pub fn practiceKey(cohort: results.Cohort) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&cohort.behavior);
    hash.update(&cohort.mapping);
    hash.update(&.{ @backingInt(cohort.source), @backingInt(cohort.family) });
    return hash.finalResult();
}

fn sameRecord(gpa: std.mem.Allocator, bytes: []const u8, record: *const results.Record) !bool {
    const old = try decode(results.Record, gpa, bytes);
    try old.validate();
    return std.meta.eql(old, record.*);
}

pub fn decode(comptime T: type, gpa: std.mem.Allocator, bytes: []const u8) !T {
    if (bytes.len > max_payload_bytes) return error.PracticeRecordTooLarge;
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const value = try std.zon.parse.fromSlice(T, .{
        .gpa = gpa,
        .arena = gpa,
        .source = text,
        .diagnostics = &diagnostics,
    });
    try value.validate();
    return value;
}

test "schema one migration preserves old record bytes and default-field identity" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "old.sqlite3" });
    defer t.allocator.free(path);
    const record: results.Record = .{ .id = @splat(1) };
    const id = try encode(t.allocator, record.id);
    defer t.allocator.free(id);
    const old_bytes = try std.fmt.allocPrint(t.allocator, ".{{ .id = {s}, .cohort = .{{}} }}", .{id});
    defer t.allocator.free(old_bytes);
    {
        var db = try Database.open(t.allocator, t.io, path, false);
        defer db.deinit();
        try db.save(&record, null);
        var update = try db.prepare("UPDATE runs SET record=?1 WHERE id=?2");
        defer update.deinit();
        try update.bindBlob(1, old_bytes);
        try update.bindBlob(2, &record.id);
        _ = try update.step();
        try db.exec(
            "DROP INDEX runs_practice_chronological; " ++
                "ALTER TABLE runs DROP COLUMN practice_scope; " ++
                "ALTER TABLE events DROP COLUMN cue_visible; PRAGMA user_version=1",
        );
    }
    var migrated = try Database.open(t.allocator, t.io, path, false);
    defer migrated.deinit();
    try t.expectEqual(@as(i64, 3), try migrated.number("PRAGMA user_version"));
    try migrated.save(&record, null);
    var rows = try migrated.rowsFor(.{});
    defer rows.deinit();
    try t.expect(try rows.step());
    try t.expectEqualStrings(old_bytes, try rows.blob(1));
    var scoped = try migrated.rowsForPractice(.{});
    defer scoped.deinit();
    try t.expect(try scoped.step());
}

test "invalid legacy payload rolls back the complete scope migration" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "invalid-old.sqlite3" });
    defer t.allocator.free(path);
    {
        var db = try Database.open(t.allocator, t.io, path, false);
        defer db.deinit();
        const record: results.Record = .{ .id = @splat(1) };
        try db.save(&record, null);
        try db.exec(
            "UPDATE runs SET record=CAST('.{ .version=999 }' AS BLOB); " ++
                "DROP INDEX runs_practice_chronological; " ++
                "ALTER TABLE runs DROP COLUMN practice_scope; " ++
                "ALTER TABLE events DROP COLUMN cue_visible; PRAGMA user_version=1",
        );
    }
    try t.expectError(error.UnsupportedPracticeHistory, Database.open(t.allocator, t.io, path, false));
    var preserved = try Database.open(t.allocator, t.io, path, true);
    defer preserved.deinit();
    try t.expectEqual(@as(i64, 1), try preserved.number("PRAGMA user_version"));
    try t.expectEqual(
        @as(i64, 0),
        try preserved.number("SELECT count(*) FROM pragma_table_info('runs') WHERE name='practice_scope'"),
    );
    var rows = try preserved.rows();
    defer rows.deinit();
    try t.expect(try rows.step());
    try t.expectEqualStrings(".{ .version=999 }", try rows.blob(1));
}

test "older timing defaults remain idempotent without rewriting original payload bytes" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "old-timing.sqlite3" });
    defer t.allocator.free(path);
    var db = try Database.open(t.allocator, t.io, path, false);
    defer db.deinit();
    var recorder = timing.Recorder.init(t.allocator);
    defer recorder.deinit();
    recorder.reset(&.{'a'});
    recorder.record(.attempt, 100, 0, 0, 'a', .ordinary);
    var record: results.Record = .{
        .id = @splat(3),
        .timing_available = true,
        .matched = 1,
        .attempts = 1,
        .correct_attempts = 1,
        .stat_count = 1,
    };
    record.stats[0] = .{ .cp = 'a', .opportunities = 1 };
    try db.save(&record, recorder.payload());
    const old = ".{ .reference=.{97}, .events=.{ .{ .observed_us=100, .elapsed_us=0, .active_us=0, " ++
        ".kind=.attempt, .position=0, .expected=97, .typed=97, .correct=true, .eligibility=.first_input } } }";
    var update = try db.prepare("UPDATE runs SET timing=?1 WHERE id=?2");
    defer update.deinit();
    try update.bindBlob(1, old);
    try update.bindBlob(2, &record.id);
    _ = try update.step();
    try db.save(&record, recorder.payload());
    var rows = try db.rows();
    defer rows.deinit();
    try t.expect(try rows.step());
    try t.expectEqualStrings(old, try rows.blob(2));
}

/// Schema version 1 for a new database; later versions migrate from it.
const schema_v1 =
    "CREATE TABLE IF NOT EXISTS runs(" ++
    "id BLOB PRIMARY KEY CHECK(length(id)=16), timestamp INTEGER NOT NULL, " ++
    "record BLOB NOT NULL, timing BLOB, cohort BLOB NOT NULL) STRICT; " ++
    "CREATE INDEX IF NOT EXISTS runs_chronological ON runs(timestamp,id); " ++
    "CREATE INDEX IF NOT EXISTS runs_cohort_chronological ON runs(cohort,timestamp,id); " ++
    "CREATE TABLE IF NOT EXISTS events(" ++
    "run_id BLOB NOT NULL REFERENCES runs(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, " ++
    "elapsed_us INTEGER NOT NULL, active_us INTEGER NOT NULL, kind INTEGER NOT NULL, " ++
    "position INTEGER NOT NULL, expected INTEGER, typed INTEGER, batch INTEGER NOT NULL, " ++
    "input INTEGER NOT NULL, eligibility INTEGER NOT NULL, interval_us INTEGER, " ++
    "correct INTEGER NOT NULL, assistance INTEGER NOT NULL, observed_us INTEGER NOT NULL, " ++
    "clock INTEGER NOT NULL, PRIMARY KEY(run_id,ordinal)) STRICT; " ++
    "CREATE TABLE IF NOT EXISTS legacy_imports(id BLOB PRIMARY KEY, record BLOB NOT NULL) STRICT; " ++
    "PRAGMA application_id=0x5a4d5052; PRAGMA user_version=1;";

pub const Database = struct {
    connection: zqlite.Conn,
    gpa: std.mem.Allocator,
    readonly: bool,
    io: std.Io,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8, readonly: bool) !Database {
        if (!std.fs.path.isAbsolute(path) or
            std.mem.indexOfScalar(u8, path, 0) != null) return error.AbsolutePracticeDatabasePathRequired;
        const name = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(name);
        const connection = zqlite.open(
            name,
            if (readonly) zqlite.OpenFlags.ReadOnly else zqlite.OpenFlags.Create,
        ) catch |err| return databaseError(err);
        var self = Database{ .connection = connection, .gpa = gpa, .readonly = readonly, .io = io };
        errdefer self.deinit();
        self.connection.busyTimeout(1500) catch |err| return databaseError(err);
        try self.exec("PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON;");
        if (!readonly) try self.exec("BEGIN IMMEDIATE");
        errdefer if (!readonly) self.exec("ROLLBACK") catch {};
        const version = try self.number("PRAGMA user_version");
        const app = try self.number("PRAGMA application_id");
        if (!readonly and
            version == 0 and
            app == 0 and
            try self.number("SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'") == 0)
        {
            try self.exec(schema_v1);
        } else {
            if ((version != 1 and version != 2 and version != 3) or
                app != application_id) return error.UnsupportedPracticeDatabase;
            // BEGIN IMMEDIATE reserves the writer before inspecting the version.
            // A separate reader sees all committed WAL frames and none of our changes.
            if (!readonly and version < 3)
                self.backupBeforeMigration(path, version) catch return error.PracticeMigrationBackupFailed;
        }
        if (!readonly and version < 2) try self.migrateScope();
        if (!readonly and version < 3) {
            try self.exec(
                "ALTER TABLE events ADD COLUMN cue_visible INTEGER NOT NULL DEFAULT 0; PRAGMA user_version=3",
            );
        }
        if (!readonly) try self.exec("COMMIT");
        if (!readonly) {
            // Concurrent first opens can conflict while switching journal mode.
            // SQLite can return BUSY here without invoking its busy handler.
            var attempts: usize = 0;
            while (true) : (attempts += 1) {
                const result = c.sqlite3_exec(
                    self.connection.conn,
                    "PRAGMA journal_mode=WAL",
                    null,
                    null,
                    null,
                );
                if ((result == 5 or result == 6) and attempts < 3) {
                    _ = c.sqlite3_sleep(10);
                    continue;
                }
                try check(result);
                break;
            }
            try self.exec("PRAGMA synchronous=FULL");
        }
        return self;
    }

    pub fn deinit(self: *Database) void {
        self.connection.close();
    }

    pub fn currentSchema(self: *Database) !bool {
        return try self.number("PRAGMA user_version") == 3;
    }

    /// Reopen only when migration or a deliberate mutation actually needs a writer.
    pub fn makeWritable(self: *Database, io: std.Io, path: []const u8) !void {
        if (!self.readonly) return;
        const writable = try Database.open(self.gpa, io, path, false);
        self.deinit();
        self.* = writable;
    }

    fn backupBeforeMigration(self: *Database, path: []const u8, version: i64) anyerror!void {
        const directory = try std.fs.path.join(self.gpa, &.{ std.fs.path.dirname(path).?, "backups" });
        defer self.gpa.free(directory);
        try std.Io.Dir.cwd().createDirPath(self.io, directory);
        var nonce: [16]u8 = undefined;
        try std.Io.randomSecure(self.io, &nonce);
        const backup_path = try std.fmt.allocPrint(
            self.gpa,
            "{s}/schema-{d}-{s}.sqlite3",
            .{ directory, version, std.fmt.bytesToHex(nonce, .lower) },
        );
        defer self.gpa.free(backup_path);
        var source = try Database.open(self.gpa, self.io, path, true);
        defer source.deinit();
        try source.exportDatabase(self.io, backup_path);
        // Publication is exclusive and durable. Verify the standalone file before DDL.
        var backup = try Database.open(self.gpa, self.io, backup_path, true);
        defer backup.deinit();
        if (try backup.number("PRAGMA user_version") != version) return error.InvalidPracticeDatabase;
        var integrity = try backup.prepare("PRAGMA integrity_check");
        defer integrity.deinit();
        if (!try integrity.step() or
            !std.mem.eql(u8, integrity.raw.text(0), "ok")) return error.InvalidPracticeDatabase;
    }

    pub fn legacyImported(self: *Database, record: *const results.Record) !bool {
        var stmt = try self.prepare("SELECT record FROM legacy_imports WHERE id=?1");
        defer stmt.deinit();
        try stmt.bindBlob(1, &record.id);
        if (!try stmt.step()) return false;
        if (!try sameRecord(self.gpa, try stmt.blob(0), record)) return error.PracticeRunCollision;
        return true;
    }

    pub fn exec(self: *Database, sql: [:0]const u8) !void {
        self.connection.execNoArgs(sql) catch |err| return databaseError(err);
    }

    pub fn prepare(self: *Database, sql: [:0]const u8) !Statement {
        return .{ .raw = self.connection.prepare(sql) catch |err| return databaseError(err) };
    }

    fn number(self: *Database, sql: [:0]const u8) !i64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        if (!try stmt.step()) return error.InvalidPracticeDatabase;
        return stmt.raw.int(0);
    }

    pub fn rows(self: *Database) !Statement {
        return self.prepare("SELECT id,record,timing FROM runs ORDER BY timestamp DESC,id DESC");
    }

    pub fn eventCount(self: *Database) !usize {
        return std.math.cast(
            usize,
            try self.number("SELECT count(*) FROM events"),
        ) orelse error.InvalidPracticeDatabase;
    }

    pub fn runCount(self: *Database) !usize {
        return std.math.cast(
            usize,
            try self.number("SELECT count(*) FROM runs"),
        ) orelse error.InvalidPracticeDatabase;
    }

    pub fn rowsFor(self: *Database, cohort: results.Cohort) !Statement {
        const bytes = try cohortKey(self.gpa, cohort);
        errdefer self.gpa.free(bytes);
        var stmt = try self.prepare(
            "SELECT id,record,timing FROM runs WHERE cohort=?1 ORDER BY timestamp DESC,id DESC",
        );
        errdefer stmt.deinit();
        try stmt.bindBlob(1, bytes);
        stmt.retained = bytes;
        stmt.gpa = self.gpa;
        return stmt;
    }

    fn migrateScope(self: *Database) !void {
        try self.exec(
            "ALTER TABLE runs ADD COLUMN practice_scope BLOB; " ++
                "CREATE INDEX runs_practice_chronological ON runs(practice_scope,timestamp,id)",
        );
        var cursor = try self.rows();
        defer cursor.deinit();
        while (try cursor.step()) {
            const record = try decode(results.Record, self.gpa, try cursor.blob(1));
            try record.validate();
            if (!std.mem.eql(u8, &record.id, try cursor.blob(0))) return error.InvalidPracticeDatabase;
            const key = practiceKey(record.cohort);
            const cohort = try cohortKey(self.gpa, record.cohort);
            defer self.gpa.free(cohort);
            var update = try self.prepare("UPDATE runs SET practice_scope=?1,cohort=?2 WHERE id=?3");
            defer update.deinit();
            try update.bindBlob(1, &key);
            try update.bindBlob(2, cohort);
            try update.bindBlob(3, &record.id);
            _ = try update.step();
        }
        try self.exec("PRAGMA user_version=2");
    }

    pub fn rowsForPractice(self: *Database, cohort: results.Cohort) !Statement {
        const key = practiceKey(cohort);
        const bytes = try self.gpa.dupe(u8, &key);
        errdefer self.gpa.free(bytes);
        var stmt = try self.prepare(
            "SELECT id,record,timing FROM runs WHERE practice_scope=?1 ORDER BY timestamp DESC,id DESC",
        );
        errdefer stmt.deinit();
        try stmt.bindBlob(1, bytes);
        stmt.retained = bytes;
        stmt.gpa = self.gpa;
        return stmt;
    }

    fn put(self: *Database, record: *const results.Record, payload: ?timing.Payload) !void {
        try record.validate();
        if (payload) |p| try p.validate();
        if (record.timing_available != (payload != null)) return error.InvalidPracticeTiming;
        if (payload) |p| try validateTiming(record, p);
        const bytes = try encode(self.gpa, record.*);
        defer self.gpa.free(bytes);
        const samples = if (payload) |p| try encode(self.gpa, p) else null;
        defer if (samples) |b| self.gpa.free(b);
        var found = try self.prepare("SELECT record,timing FROM runs WHERE id=?1");
        defer found.deinit();
        try found.bindBlob(1, &record.id);
        if (try found.step()) return self.checkSameRun(&found, record, payload);
        const cohort = try cohortKey(self.gpa, record.cohort);
        defer self.gpa.free(cohort);
        const scope = practiceKey(record.cohort);
        var stmt = try self.prepare(
            "INSERT INTO runs(id,timestamp,record,timing,cohort,practice_scope) VALUES(?1,?2,?3,?4,?5,?6)",
        );
        defer stmt.deinit();
        try stmt.bindBlob(1, &record.id);
        try stmt.integer(2, record.timestamp);
        try stmt.bindBlob(3, bytes);
        if (samples) |b| try stmt.bindBlob(4, b) else try stmt.bindNull(4);
        try stmt.bindBlob(5, cohort);
        try stmt.bindBlob(6, &scope);
        _ = try stmt.step();
        if (payload) |p| for (p.events, 0..) |event, index| try self.insertEvent(record.id, index, event);
    }

    /// Rejects a timing payload that disagrees with the record it belongs to.
    fn validateTiming(record: *const results.Record, payload: timing.Payload) !void {
        if (record.cue_evidence != payload.cue_tracking) return error.InvalidPracticeTiming;
        if (record.cohort.assistance != .guided and
            payload.help_revealed and
            !record.cohort.hints.revealed) return error.InvalidPracticeTiming;
        if (record.timing_truncated != payload.truncated) return error.InvalidPracticeTiming;
        if ((record.status == .completed and payload.reference.len != record.matched) or
            record.matched > payload.reference.len) return error.InvalidPracticeTiming;
        var attempts: u64 = 0;
        var correct: u64 = 0;
        for (payload.events) |event| if (event.kind == .attempt) {
            attempts += 1;
            correct += @intFromBool(event.correct);
        };
        if (attempts > record.attempts or correct > record.correct_attempts) return error.InvalidPracticeTiming;
        if (!payload.truncated and (attempts != record.attempts or correct != record.correct_attempts))
            return error.InvalidPracticeTiming;
    }

    /// Saving a run again is accepted only with identical record and timing.
    fn checkSameRun(
        self: *Database,
        found: *Statement,
        record: *const results.Record,
        payload: ?timing.Payload,
    ) !void {
        if (!try sameRecord(self.gpa, try found.blob(0), record)) return error.PracticeRunCollision;
        const current = payload orelse return;
        if (found.raw.columnType(1) == .null) return error.PracticeRunCollision;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const old = try decode(timing.Payload, arena.allocator(), try found.blob(1));
        try old.validate();
        if (old.version != current.version or
            old.truncated != current.truncated or
            old.dropped != current.dropped or
            old.cue_tracking != current.cue_tracking or
            old.help_revealed != current.help_revealed or
            !std.mem.eql(u21, old.reference, current.reference) or
            old.events.len != current.events.len) return error.PracticeRunCollision;
        for (old.events, current.events) |old_event, event| {
            if (!std.meta.eql(old_event, event)) return error.PracticeRunCollision;
        }
    }

    fn insertEvent(self: *Database, id: [16]u8, index: usize, event: timing.Event) !void {
        var e = try self.prepare(
            "INSERT INTO events VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
        );
        defer e.deinit();
        try e.bindBlob(1, &id);
        try e.integer(2, @intCast(index));
        try e.integer(3, try microseconds(event.elapsed_us));
        try e.integer(4, try microseconds(event.active_us));
        try e.integer(5, @backingInt(event.kind));
        try e.integer(6, event.position);
        if (event.expected) |v| try e.integer(7, v) else try e.bindNull(7);
        if (event.typed) |v| try e.integer(8, v) else try e.bindNull(8);
        try e.integer(9, event.batch);
        try e.integer(10, @backingInt(event.input));
        try e.integer(11, @backingInt(event.eligibility));
        if (event.interval_us) |v| try e.integer(12, try microseconds(v)) else try e.bindNull(12);
        try e.integer(13, @intFromBool(event.correct));
        try e.integer(14, event.assistance);
        try e.integer(15, try microseconds(event.observed_us));
        try e.integer(16, @backingInt(event.clock));
        try e.integer(17, @intFromBool(event.cue_visible));
        _ = try e.step();
    }

    fn microseconds(value: u64) !i64 {
        return std.math.cast(i64, value) orelse error.InvalidPracticeTiming;
    }

    pub fn save(self: *Database, record: *const results.Record, payload: ?timing.Payload) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        try self.put(record, payload);
        try self.exec("COMMIT");
    }

    pub fn importLegacy(self: *Database, record: *const results.Record) !void {
        try record.validate();
        const bytes = try encode(self.gpa, record.*);
        defer self.gpa.free(bytes);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var old = try self.prepare("SELECT record FROM legacy_imports WHERE id=?1");
        defer old.deinit();
        try old.bindBlob(1, &record.id);
        if (try old.step()) {
            if (!try sameRecord(self.gpa, try old.blob(0), record)) return error.PracticeRunCollision;
        } else {
            try self.put(record, null);
            var receipt = try self.prepare("INSERT INTO legacy_imports VALUES(?1,?2)");
            defer receipt.deinit();
            try receipt.bindBlob(1, &record.id);
            try receipt.bindBlob(2, bytes);
            _ = try receipt.step();
        }
        try self.exec("COMMIT");
    }

    pub fn importDatabase(self: *Database, path: []const u8) !usize {
        var source = try Database.open(self.gpa, self.io, path, true);
        defer source.deinit();
        try source.exec("BEGIN");
        defer source.exec("ROLLBACK") catch {};
        var rows_stmt = try source.rows();
        defer rows_stmt.deinit();
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var count: usize = 0;
        while (try rows_stmt.step()) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const record = try decode(results.Record, arena.allocator(), try rows_stmt.blob(1));
            if (!std.mem.eql(u8, try rows_stmt.blob(0), &record.id)) return error.InvalidPracticeDatabase;
            const payload = if (rows_stmt.raw.columnType(2) == .null) null else try decode(
                timing.Payload,
                arena.allocator(),
                try rows_stmt.blob(2),
            );
            try self.put(&record, payload);
            count += 1;
        }
        try self.exec("COMMIT");
        return count;
    }

    pub fn timingFor(self: *Database, id: [16]u8, gpa: std.mem.Allocator) !?timing.Owned {
        var stmt = try self.prepare("SELECT timing FROM runs WHERE id=?1");
        defer stmt.deinit();
        try stmt.bindBlob(1, &id);
        if (!try stmt.step() or stmt.raw.columnType(0) == .null) return null;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const payload = try decode(timing.Payload, arena.allocator(), try stmt.blob(0));
        return .{ .arena = arena, .payload = payload };
    }

    pub fn clear(self: *Database) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        // Validate before deleting. Unknown/corrupt run payloads require deliberate handling.
        var stmt = try self.rows();
        defer stmt.deinit();
        while (try stmt.step()) {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            _ = try decode(results.Record, arena.allocator(), try stmt.blob(1));
            if (stmt.raw.columnType(2) != .null) {
                _ = try decode(
                    timing.Payload,
                    arena.allocator(),
                    try stmt.blob(2),
                );
            }
        }
        try self.exec("DELETE FROM runs");
        try self.exec("COMMIT");
        // Migration receipts survive clearing so retained legacy files cannot resurrect history.
    }

    pub fn exportDatabase(self: *Database, io: std.Io, path: []const u8) !void {
        if (!std.fs.path.isAbsolute(path)) return error.AbsolutePracticeDatabasePathRequired;
        var nonce: [16]u8 = undefined;
        try std.Io.randomSecure(io, &nonce);
        const temporary = try std.fmt.allocPrint(self.gpa, "{s}.tmp-{s}", .{
            path,
            std.fmt.bytesToHex(nonce, .lower),
        });
        defer self.gpa.free(temporary);
        const reserved = try std.Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true });
        reserved.close(io);
        defer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        const name = try self.gpa.dupeSentinel(u8, temporary, 0);
        defer self.gpa.free(name);
        const destination = zqlite.open(
            name,
            zqlite.OpenFlags.ReadWrite,
        ) catch |err| return databaseError(err);
        var opened = true;
        defer if (opened) destination.close();
        destination.busyTimeout(1500) catch |err| return databaseError(err);
        const backup = c.sqlite3_backup_init(
            destination.conn,
            "main",
            self.connection.conn,
            "main",
        ) orelse return error.PracticeDatabaseFailure;
        var finished = false;
        defer if (!finished) {
            _ = c.sqlite3_backup_finish(backup);
        };
        var retries: usize = 0;
        const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 15000;
        while (true) {
            if (std.Io.Clock.awake.now(io).toMilliseconds() > deadline) return error.PracticeDatabaseBusy;
            const code = c.sqlite3_backup_step(backup, 256);
            if (code == 101) break;
            if (code == 5 or code == 6) {
                if (retries == 30) return error.PracticeDatabaseBusy;
                retries += 1;
                try std.Io.sleep(io, .fromMilliseconds(50), .awake);
            } else try check(code);
        }
        const finish_code = c.sqlite3_backup_finish(backup);
        finished = true;
        try check(finish_code);
        // The backup copies page 1's WAL setting too. Make the published file
        // standalone so read-only rollback needs no writable journal siblings.
        destination.execNoArgs("PRAGMA journal_mode=DELETE") catch |err| return databaseError(err);
        destination.tryClose() catch |err| return databaseError(err);
        opened = false;
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{});
        defer atomic.deinit(io);
        // Stream the standalone backup into an unnamed file, then publish exclusively.
        var input = try std.Io.Dir.cwd().openFile(io, temporary, .{});
        defer input.close(io);
        var buffer: [8192]u8 = undefined;
        var reader = input.reader(io, &buffer);
        var out_buffer: [8192]u8 = undefined;
        var writer = atomic.file.writer(io, &out_buffer);
        _ = try reader.interface.streamRemaining(&writer.interface);
        try writer.interface.flush();
        try atomic.file.sync(io);
        try atomic.link(io);
    }
};

test "frozen schemas migrate once with a standalone WAL backup preserving record bytes and receipts" {
    const t = std.testing;
    for ([_]i64{ 1, 2 }) |version| {
        var temp = t.tmpDir(.{});
        defer temp.cleanup();
        const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        defer t.allocator.free(root);
        const path = try std.fs.path.join(t.allocator, &.{ root, filename });
        defer t.allocator.free(path);
        const name = try t.allocator.dupeSentinel(u8, path, 0);
        defer t.allocator.free(name);
        const writer = try zqlite.open(name, zqlite.OpenFlags.Create);
        defer writer.close();
        try writer.execNoArgs("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;");
        try writer.execNoArgs(@embedFile("fixtures/schema-v1.sql"));
        if (version == 2) try writer.execNoArgs(@embedFile("fixtures/schema-v2.sql"));
        const raw = @embedFile("fixtures/record-v1.zon");
        const record = try decode(results.Record, t.allocator, raw);
        {
            const insert = try writer.prepare(
                if (version == 2)
                    "INSERT INTO runs(id,timestamp,record,timing,cohort,practice_scope) VALUES(?1,42,?2,NULL,?3,?4)"
                else
                    "INSERT INTO runs(id,timestamp,record,timing,cohort) VALUES(?1,42,?2,NULL,?3)",
            );
            defer insert.deinit();
            const cohort = try cohortKey(t.allocator, record.cohort);
            defer t.allocator.free(cohort);
            const scope = practiceKey(record.cohort);
            try insert.bindValue(zqlite.blob(&record.id), 0);
            try insert.bindValue(zqlite.blob(raw), 1);
            try insert.bindValue(zqlite.blob(cohort), 2);
            if (version == 2) try insert.bindValue(zqlite.blob(&scope), 3);
            _ = try insert.step();
            try writer.execNoArgs("INSERT INTO legacy_imports SELECT id,record FROM runs");
        }
        // Keep the writer open: committed pages remain in its WAL during backup.
        {
            var db = try Database.open(t.allocator, t.io, path, false);
            defer db.deinit();
            try t.expect(try db.currentSchema());
            var practice_rows = try db.rowsForPractice(record.cohort);
            defer practice_rows.deinit();
            try t.expect(try practice_rows.step());
            try t.expectEqualStrings(raw, try practice_rows.blob(1));
        }
        var backups = try temp.dir.openDir(t.io, "backups", .{ .iterate = true });
        defer backups.close(t.io);
        var iterator = backups.iterate();
        const entry = (try iterator.next(t.io)).?;
        const backup_path = try std.fs.path.join(t.allocator, &.{ root, "backups", entry.name });
        defer t.allocator.free(backup_path);
        try t.expect(try iterator.next(t.io) == null);
        var backup = try Database.open(t.allocator, t.io, backup_path, true);
        defer backup.deinit();
        try t.expectEqual(version, try backup.number("PRAGMA user_version"));
        try t.expectEqual(@as(usize, 1), try backup.runCount());
        try t.expectEqual(@as(i64, 1), try backup.number("SELECT count(*) FROM legacy_imports"));
        var rows = try backup.rows();
        defer rows.deinit();
        try t.expect(try rows.step());
        try t.expectEqualStrings(raw, try rows.blob(1));
        try t.expectEqualSlices(u8, &record.id, try rows.blob(0));
        var again = try Database.open(t.allocator, t.io, path, false);
        defer again.deinit();
        var second = backups.iterate();
        _ = try second.next(t.io);
        try t.expect(try second.next(t.io) == null);
        // A standalone backup can be copied without its original WAL directory.
        const restored = try std.fs.path.join(t.allocator, &.{ root, "restored.sqlite3" });
        defer t.allocator.free(restored);
        try std.Io.Dir.cwd().copyFile(backup_path, .cwd(), restored, t.io, .{});
        var restored_db = try Database.open(t.allocator, t.io, restored, true);
        defer restored_db.deinit();
        try t.expectEqual(version, try restored_db.number("PRAGMA user_version"));
        try t.expectEqual(@as(usize, 1), try restored_db.runCount());
    }
}

test "backup publication failure leaves the old schema and bytes unchanged" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, filename });
    defer t.allocator.free(path);
    {
        var db = try Database.open(t.allocator, t.io, path, false);
        defer db.deinit();
        try db.exec("ALTER TABLE events DROP COLUMN cue_visible; PRAGMA user_version=2");
    }
    try temp.dir.writeFile(t.io, .{ .sub_path = "backups", .data = "a file blocks the backup directory" });
    try t.expectError(error.PracticeMigrationBackupFailed, Database.open(t.allocator, t.io, path, false));
    var preserved = try Database.open(t.allocator, t.io, path, true);
    defer preserved.deinit();
    try t.expectEqual(@as(i64, 2), try preserved.number("PRAGMA user_version"));
    try t.expectEqual(
        @as(i64, 0),
        try preserved.number("SELECT count(*) FROM pragma_table_info('events') WHERE name='cue_visible'"),
    );
}

test "concurrent upgrades reserve one writer and publish exactly one migration backup" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, filename });
    defer t.allocator.free(path);
    {
        const name = try t.allocator.dupeSentinel(u8, path, 0);
        defer t.allocator.free(name);
        const conn = try zqlite.open(name, zqlite.OpenFlags.Create);
        defer conn.close();
        try conn.execNoArgs(@embedFile("fixtures/schema-v1.sql"));
    }
    const Upgrade = struct {
        fn run(io: std.Io, database_path: []const u8) !void {
            var db = try Database.open(std.heap.page_allocator, io, database_path, false);
            defer db.deinit();
            if (!try db.currentSchema()) return error.InvalidPracticeDatabase;
        }
    };
    var first = try std.Io.concurrent(t.io, Upgrade.run, .{ t.io, path });
    defer first.cancel(t.io) catch {};
    var second = try std.Io.concurrent(t.io, Upgrade.run, .{ t.io, path });
    defer second.cancel(t.io) catch {};
    try first.await(t.io);
    try second.await(t.io);
    var backups = try temp.dir.openDir(t.io, "backups", .{ .iterate = true });
    defer backups.close(t.io);
    var iterator = backups.iterate();
    try t.expect(try iterator.next(t.io) != null);
    try t.expect(try iterator.next(t.io) == null);
}

test "standalone export includes raw timing; imports are idempotent and conflicts roll back" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const first = try std.fs.path.join(t.allocator, &.{ root, "a.sqlite3" });
    defer t.allocator.free(first);
    const second = try std.fs.path.join(t.allocator, &.{ root, "b.sqlite3" });
    defer t.allocator.free(second);
    const exported = try std.fs.path.join(t.allocator, &.{ root, "portable.sqlite3" });
    defer t.allocator.free(exported);
    var a = try Database.open(t.allocator, t.io, first, false);
    defer a.deinit();
    var r = timing.Recorder.init(t.allocator);
    defer r.deinit();
    r.reset(&.{'a'});
    r.record(.attempt, 100, 0, 0, 'a', .ordinary);
    r.record(.complete, 100, 0, 1, null, .ordinary);
    var record = results.Record{
        .id = @splat(1),
        .matched = 1,
        .attempts = 1,
        .correct_attempts = 1,
        .stat_count = 1,
        .timing_available = true,
    };
    record.stats[0] = .{ .cp = 'a', .opportunities = 1 };
    try a.save(&record, r.payload());
    try a.save(&record, r.payload());
    try a.exportDatabase(t.io, exported);
    try t.expectError(error.PathAlreadyExists, a.exportDatabase(t.io, exported));
    var b = try Database.open(t.allocator, t.io, second, false);
    defer b.deinit();
    try t.expectEqual(@as(usize, 1), try b.importDatabase(exported));
    try t.expectEqual(@as(usize, 1), try b.importDatabase(exported));
    var saved = (try b.timingFor(record.id, t.allocator)).?;
    defer saved.deinit();
    try t.expectEqual(@as(usize, 2), saved.payload.events.len);
    try t.expectEqual(@as(u21, 'a'), saved.payload.reference[0]);
    record.timestamp = 7;
    try t.expectError(error.PracticeRunCollision, b.save(&record, r.payload()));
    try t.expectEqual(@as(i64, 1), try b.number("SELECT count(*) FROM runs"));
    try b.clear();
    try t.expectEqual(@as(i64, 0), try b.number("SELECT count(*) FROM events"));
}

test "a conflicting import rolls back earlier rows and future databases remain untouched" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const source_path = try std.fs.path.join(t.allocator, &.{ root, "source.sqlite3" });
    defer t.allocator.free(source_path);
    const target_path = try std.fs.path.join(t.allocator, &.{ root, "target.sqlite3" });
    defer t.allocator.free(target_path);
    var source = try Database.open(t.allocator, t.io, source_path, false);
    defer source.deinit();
    var target = try Database.open(t.allocator, t.io, target_path, false);
    defer target.deinit();
    var conflict = results.Record{ .id = @splat(1) };
    try source.save(&conflict, null);
    conflict.timestamp = 99;
    try target.save(&conflict, null);
    const earlier = results.Record{ .id = @splat(2), .timestamp = 100 };
    try source.save(&earlier, null);
    try t.expectError(error.PracticeRunCollision, target.importDatabase(source_path));
    try t.expectEqual(@as(usize, 1), try target.runCount());
    try source.exec("PRAGMA user_version=999");
    try t.expectError(error.UnsupportedPracticeDatabase, target.importDatabase(source_path));
    try t.expectEqual(@as(usize, 1), try target.runCount());
    try t.expectEqual(@as(i64, 999), try source.number("PRAGMA user_version"));
}

test "native independent writers share a Unicode database and readonly handles cannot mutate it" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const Writer = struct {
        fn write(database_path: []const u8, id: u8) !void {
            var db = try Database.open(std.heap.page_allocator, std.testing.io, database_path, false);
            defer db.deinit();
            var record = results.Record{};
            record.id[0] = id;
            try db.save(&record, null);
        }
    };
    for (0..8) |round| {
        const name = try std.fmt.allocPrint(t.allocator, "practice café-{d}.sqlite3", .{round});
        defer t.allocator.free(name);
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        var a = try std.Io.concurrent(t.io, Writer.write, .{ path, @as(u8, 1) });
        defer a.cancel(t.io) catch {};
        var b = try std.Io.concurrent(t.io, Writer.write, .{ path, @as(u8, 2) });
        defer b.cancel(t.io) catch {};
        try a.await(t.io);
        try b.await(t.io);
        var read = try Database.open(t.allocator, t.io, path, true);
        defer read.deinit();
        try t.expectEqual(@as(usize, 2), try read.runCount());
        const record = results.Record{ .id = @splat(3) };
        try t.expectError(error.PracticeDatabaseReadOnly, read.save(&record, null));
    }
}
