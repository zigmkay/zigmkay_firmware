//! Lightweight native persistence for the adaptive typing tutor:
//! atomic `state.zon` snapshots and append-only `runs.jsonl` history under
//! `<app_data>/tutor/profiles/<profile_hash>/`. Zero SQLite or C dependencies.
const std = @import("std");
const layout_profile = @import("practice_layout_profile.zig");
const model = @import("practice_model.zig");

/// 2 replaced the layout-diff key positions with known positions and board snapshots.
/// 3 made forgiving input the default; a schema 2 `stop_on_error` was never
/// chosen by the user and loads as `forgive`.
pub const schema_version: u32 = 3;
/// The oldest schema that still loads; its missing fields take their defaults.
pub const min_schema_version: u32 = 2;
pub const state_filename = "state.zon";
pub const corrupt_backup_filename = "state.zon.corrupt";
pub const runs_filename = "runs.jsonl";
pub const max_state_bytes: usize = 256 * 1024;
pub const max_runs_bytes: usize = 16 * 1024 * 1024;

pub const GuidanceMode = enum(u8) {
    guided,
    on_hesitation,
    free,
};

pub const ErrorMode = enum(u8) {
    stop_on_error,
    flow_backspace,
    forgive,
};

pub const PersistedKeyStat = struct {
    cp: u32,
    ema_ms: f32,
    ema_acc: f32,
    samples: u32,
    acc_initialized: bool = true,
    recent_hits: u32 = 0,
    recent_len: u8 = 0,
};

pub const PersistedFocusSample = struct {
    ema_ms: f32,
    confidence: f32,
};

pub const PersistedBigram = struct {
    prev: u32,
    cur: u32,
    ema_ms: f32,
    samples: u32,
};

pub const PersistedSeenKey = struct {
    board: u64,
    key_index: u16,
    combo_key_index: ?u16 = null,
    layer_key_index: ?u16 = null,
};

/// A position at which the statistics of `cp` count as valid; one
/// character can have several, oldest first.
pub const PersistedKnownPosition = struct {
    cp: u32,
    layer: u8,
    slot: u16,
    shift: bool,
    combo_slot: ?u16 = null,
    seen: ?PersistedSeenKey = null,
};

pub const PersistedBoardLayer = struct {
    layer: u8,
    /// Single-character tap label per key; 0 is none.
    labels: []const u32,
};

pub const PersistedBoard = struct {
    board_id: []const u8,
    key_count: u16,
    layers: []const PersistedBoardLayer = &.{},
};

pub const ProfileState = struct {
    schema_version: u32 = schema_version,
    language: model.Language = .en,
    board_id: []const u8 = "",
    layout_key_hash: []const u8 = "",
    host_layout: []const u8 = "default",

    active_stage: u8 = 1,
    target_wpm: f32 = 20.0,
    guidance_mode: GuidanceMode = .guided,
    error_mode: ErrorMode = .forgive,
    daily_goal_minutes: u16 = 15,
    daily_active_seconds: u32 = 0,
    daily_utc_day: u32 = 0,
    streak_days: u32 = 0,

    unlocked_count: u16 = 0,
    rounds_since_unlock: u32 = 0,
    total_rounds: u32 = 0,
    focus_cp: ?u32 = null,
    focus_history: []const PersistedFocusSample = &.{},
    key_stats: []const PersistedKeyStat = &.{},
    bigrams: []const PersistedBigram = &.{},
    known_positions: []const PersistedKnownPosition = &.{},
    /// Keyboards that known positions were last seen on, oldest first.
    boards_seen: []const PersistedBoard = &.{},
};

pub const LoadedState = struct {
    arena: std.heap.ArenaAllocator,
    state: ProfileState,
    existed: bool = false,
    recovered_from_corrupt: bool = false,

    pub fn deinit(self: *LoadedState) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const RunRecord = struct {
    utc_timestamp: u64,
    stage: u8,
    wpm: f32,
    accuracy: f32,
    active_seconds: f32,
    focus_key: ?u32 = null,
    unlocked_char: ?u32 = null,
    top_weak_keys: []const u32 = &.{},
    top_weak_bigrams: []const [2]u32 = &.{},
    /// The letter pair a weak-spot lesson was built around.
    weak_spot: ?[2]u32 = null,
    /// Keys that turned green in the lesson.
    newly_green: []const u32 = &.{},
};

pub const LoadedRuns = struct {
    arena: std.heap.ArenaAllocator,
    runs: []const RunRecord,
    skipped_lines: usize = 0,

    pub fn deinit(self: *LoadedRuns) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Formats the relative profile directory path `<app_data>/tutor/profiles/<profile_hash>`.
pub fn profileRelPath(profile_hash: [32]u8, buf: *[96]u8) []const u8 {
    const hex = std.fmt.bytesToHex(profile_hash, .lower);
    return std.fmt.bufPrint(buf, "tutor/profiles/{s}", .{&hex}) catch unreachable;
}

/// Updates daily active seconds and day streak across UTC calendar days.
pub fn recordDailyPractice(state: *ProfileState, utc_timestamp_sec: u64, active_seconds: u32) void {
    const today: u32 = @intCast(utc_timestamp_sec / 86_400);
    if (state.daily_utc_day == 0) {
        state.daily_utc_day = today;
        state.daily_active_seconds = active_seconds;
        if (active_seconds > 0) state.streak_days = 1;
        return;
    }
    if (today == state.daily_utc_day) {
        state.daily_active_seconds +|= active_seconds;
        if (state.streak_days == 0 and active_seconds > 0) state.streak_days = 1;
        return;
    }
    if (today == state.daily_utc_day + 1) {
        state.daily_utc_day = today;
        state.daily_active_seconds = active_seconds;
        if (active_seconds > 0) state.streak_days +|= 1;
        return;
    }
    if (today > state.daily_utc_day + 1) {
        state.daily_utc_day = today;
        state.daily_active_seconds = active_seconds;
        state.streak_days = if (active_seconds > 0) 1 else 0;
    }
}

pub const DailyView = struct { active_seconds: u32, streak_days: u32 };

/// The daily goal progress and streak as of `utc_now_sec`, without mutating
/// `state`: a stored day that is not today has no active seconds yet, and a
/// streak lapses once a whole UTC day was skipped. `utc_now_sec == 0` means
/// the clock is unknown and returns the stored values.
pub fn dailyView(state: ProfileState, utc_now_sec: u64) DailyView {
    if (utc_now_sec == 0 or state.daily_utc_day == 0) {
        return .{ .active_seconds = state.daily_active_seconds, .streak_days = state.streak_days };
    }
    const today = utc_now_sec / 86_400;
    if (today == state.daily_utc_day) {
        return .{ .active_seconds = state.daily_active_seconds, .streak_days = state.streak_days };
    }
    const lapsed = today > @as(u64, state.daily_utc_day) + 1;
    return .{ .active_seconds = 0, .streak_days = if (lapsed) 0 else state.streak_days };
}

/// Atomically writes `state.zon` (create dirs -> temp file -> sync -> atomic replace).
pub fn saveState(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    profile_hash: [32]u8,
    state: ProfileState,
) !void {
    var rel_buf: [96]u8 = undefined;
    const rel = profileRelPath(profile_hash, &rel_buf);
    var dir = try base_dir.createDirPathOpen(io, rel, .{});
    defer dir.close(io);

    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    try std.zon.stringify.serializeMaxDepth(state, .{ .whitespace = true }, &writer.writer, 16);
    try writer.writer.writeByte('\n');

    var atomic = try dir.createFileAtomic(io, state_filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, writer.written());
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Loads `state.zon` for a profile. Missing directory/file returns clean defaults.
/// Corrupt or unsupported schema files are backed up to `state.zon.corrupt` and
/// cleanly reset without failing.
pub fn loadState(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    profile_hash: [32]u8,
) !LoadedState {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var rel_buf: [96]u8 = undefined;
    const rel = profileRelPath(profile_hash, &rel_buf);
    var dir = base_dir.openDir(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .state = .{}, .existed = false },
        else => return err,
    };
    defer dir.close(io);

    const bytes = dir.readFileAlloc(io, state_filename, gpa, .limited(max_state_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .state = .{}, .existed = false },
        // Oversized content is a content problem; back it up like a parse failure.
        error.StreamTooLong => {
            backupCorrupt(io, dir);
            return .{ .arena = arena, .state = .{}, .existed = true, .recovered_from_corrupt = true };
        },
        // A transient read failure (sharing violation, permissions) must not
        // rename a good file or let a fresh state be saved over it.
        else => return err,
    };
    defer gpa.free(bytes);

    const terminated = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(terminated);

    var diag: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice(ProfileState, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source = terminated,
        .diagnostics = &diag,
    }) catch {
        backupCorrupt(io, dir);
        return .{ .arena = arena, .state = .{}, .existed = true, .recovered_from_corrupt = true };
    };
    if (parsed.schema_version < min_schema_version or parsed.schema_version > schema_version or
        parsed.active_stage < 1 or parsed.active_stage > 6)
    {
        backupCorrupt(io, dir);
        return .{ .arena = arena, .state = .{}, .existed = true, .recovered_from_corrupt = true };
    }
    return .{ .arena = arena, .state = parsed, .existed = true, .recovered_from_corrupt = false };
}

fn backupCorrupt(io: std.Io, dir: std.Io.Dir) void {
    dir.rename(state_filename, dir, corrupt_backup_filename, io) catch {};
}

/// Appends one compact JSON line to `runs.jsonl`.
pub fn appendRun(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    profile_hash: [32]u8,
    record: RunRecord,
) !void {
    var rel_buf: [96]u8 = undefined;
    const rel = profileRelPath(profile_hash, &rel_buf);
    var dir = try base_dir.createDirPathOpen(io, rel, .{});
    defer dir.close(io);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(record, .{ .whitespace = .minified }, &out.writer);
    try out.writer.writeByte('\n');

    // Windows needs read access on the handle to stat it for the append offset.
    var file = try dir.createFile(io, runs_filename, .{ .truncate = false, .read = true });
    defer file.close(io);
    var end_pos = (try file.stat(io)).size;
    if (end_pos > 0) {
        // A crash can leave a partial last line; terminate it so this record
        // stays on its own line instead of being merged into the fragment.
        var last: [1]u8 = undefined;
        if (try file.readPositionalAll(io, &last, end_pos - 1) == 1 and last[0] != '\n') {
            try file.writePositionalAll(io, "\n", end_pos);
            end_pos += 1;
        }
    }
    try file.writePositionalAll(io, out.written(), end_pos);
}

/// Reads all valid rounds from `runs.jsonl`. Ignores a truncated or malformed trailing line.
pub fn loadRuns(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    profile_hash: [32]u8,
) !LoadedRuns {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var rel_buf: [96]u8 = undefined;
    const rel = profileRelPath(profile_hash, &rel_buf);
    var dir = base_dir.openDir(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .runs = &.{} },
        else => return err,
    };
    defer dir.close(io);

    const bytes = dir.readFileAlloc(io, runs_filename, gpa, .limited(max_runs_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .runs = &.{} },
        else => return err,
    };
    defer gpa.free(bytes);

    var list: std.ArrayList(RunRecord) = .empty;
    var skipped: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(RunRecord, a, line, .{
            .ignore_unknown_fields = true,
        }) catch {
            skipped += 1;
            continue;
        };
        try list.append(a, parsed);
    }

    return .{
        .arena = arena,
        .runs = try list.toOwnedSlice(a),
        .skipped_lines = skipped,
    };
}

/// Clears persisted state and history for a profile.
pub fn resetProfile(
    io: std.Io,
    base_dir: std.Io.Dir,
    profile_hash: [32]u8,
) !void {
    var rel_buf: [96]u8 = undefined;
    const rel = profileRelPath(profile_hash, &rel_buf);
    var dir = base_dir.openDir(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    for ([_][]const u8{ state_filename, corrupt_backup_filename, runs_filename }) |name| {
        dir.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

/// Populates a `LearningModel` from persisted `ProfileState`. Nothing is reset
/// when keys moved; `LearningModel.adoptPositions` takes over the layout.
pub fn hydrateLearningModel(
    state: ProfileState,
    profile: *const layout_profile.LayoutProfile,
    learning: *model.LearningModel,
) void {
    const initial_unlocked = if (state.unlocked_count > 0)
        @max(@as(usize, state.unlocked_count), profile.zone1_len)
    else
        profile.zone1_len;

    learning.* = model.LearningModel.init(
        profile.unlockSlice(),
        initial_unlocked,
        .{
            .language = state.language,
            .target_wpm = state.target_wpm,
        },
    );
    learning.rounds_since_unlock = state.rounds_since_unlock;
    learning.total_rounds = state.total_rounds;

    for (state.key_stats) |ks| {
        if (ks.cp > std.math.maxInt(u21)) continue;
        const slot = learning.getOrAddStat(@intCast(ks.cp)) orelse break;
        slot.* = .{
            .cp = @intCast(ks.cp),
            .ema_ms = ks.ema_ms,
            .ema_acc = ks.ema_acc,
            .samples = ks.samples,
            .acc_initialized = ks.acc_initialized,
            .recent_hits = ks.recent_hits & ((@as(u32, 1) << model.accuracy_window) - 1),
            .recent_len = @min(ks.recent_len, model.accuracy_window),
        };
    }
    for (state.bigrams) |bg| {
        if (bg.prev > std.math.maxInt(u21) or bg.cur > std.math.maxInt(u21)) continue;
        if (learning.bigram_len >= model.max_bigrams) break;
        learning.bigrams[learning.bigram_len] = .{
            .prev = @intCast(bg.prev),
            .cur = @intCast(bg.cur),
            .ema_ms = bg.ema_ms,
            .samples = bg.samples,
        };
        learning.bigram_len += 1;
    }

    if (state.focus_cp) |fcp| {
        if (fcp <= std.math.maxInt(u21)) {
            learning.focus_cp = @intCast(fcp);
            const hlen = @min(state.focus_history.len, model.focus_history_capacity);
            for (0..hlen) |i| {
                learning.focus_history[i] = .{
                    .ema_ms = state.focus_history[i].ema_ms,
                    .confidence = state.focus_history[i].confidence,
                };
            }
            learning.focus_history_len = hlen;
        }
    }

    for (state.known_positions) |p| {
        if (p.cp > std.math.maxInt(u21)) continue;
        if (learning.known_len >= model.max_known_positions) break;
        learning.known[learning.known_len] = .{
            .pos = .{
                .cp = @intCast(p.cp),
                .layer = p.layer,
                .slot = p.slot,
                .shift = p.shift,
                .combo_slot = p.combo_slot,
            },
            .seen = if (p.seen) |s| .{
                .board = s.board,
                .key_index = s.key_index,
                .combo_key_index = s.combo_key_index,
                .layer_key_index = s.layer_key_index,
            } else null,
        };
        learning.known_len += 1;
    }

    if (learning.focus_cp == null) {
        learning.focus_cp = learning.computeFocusKey();
    }
}

/// Restores the keyboard snapshots of a profile, dropping malformed entries.
pub fn hydrateBoards(state: ProfileState, boards: *model.BoardSnapshots) void {
    boards.* = .{};
    const first = state.boards_seen.len -| model.max_board_snapshots;
    for (state.boards_seen[first..]) |saved| {
        if (saved.board_id.len == 0 or saved.key_count == 0) continue;
        const board = boards.use(saved.board_id, saved.key_count);
        for (saved.layers) |layer| {
            var row: [layout_profile.max_keys]u21 = @splat(0);
            const n = @min(layer.labels.len, board.key_count);
            for (layer.labels[0..n], row[0..n]) |cp, *dst| {
                dst.* = if (cp <= std.math.maxInt(u21)) @intCast(cp) else 0;
            }
            _ = board.setLayer(layer.layer, row[0..board.key_count]);
        }
    }
}

/// Captures an arena-backed `ProfileState` snapshot from the live model + profile + settings.
pub fn buildProfileState(
    arena: std.mem.Allocator,
    base_settings: ProfileState,
    learning: *const model.LearningModel,
    profile: *const layout_profile.LayoutProfile,
    boards: *const model.BoardSnapshots,
    board_id: []const u8,
    host_layout: []const u8,
) !ProfileState {
    const hash_hex = std.fmt.bytesToHex(profile.positions_digest, .lower);
    const stats = try arena.alloc(PersistedKeyStat, learning.stat_len);
    for (0..learning.stat_len) |i| {
        const s = learning.stats[i];
        stats[i] = .{
            .cp = s.cp,
            .ema_ms = s.ema_ms,
            .ema_acc = s.ema_acc,
            .samples = s.samples,
            .acc_initialized = s.acc_initialized,
            .recent_hits = s.recent_hits,
            .recent_len = s.recent_len,
        };
    }

    const focus_hist = try arena.alloc(PersistedFocusSample, learning.focus_history_len);
    for (0..learning.focus_history_len) |i| {
        focus_hist[i] = .{
            .ema_ms = learning.focus_history[i].ema_ms,
            .confidence = learning.focus_history[i].confidence,
        };
    }

    const bgs = try arena.alloc(PersistedBigram, learning.bigram_len);
    for (0..learning.bigram_len) |i| {
        const b = learning.bigrams[i];
        bgs[i] = .{
            .prev = b.prev,
            .cur = b.cur,
            .ema_ms = b.ema_ms,
            .samples = b.samples,
        };
    }

    // Only practised characters need their positions; the rest follow the layout.
    var known_len: usize = 0;
    for (learning.knownSlice()) |entry| {
        if (learning.hasData(entry.pos.cp)) known_len += 1;
    }
    const known_out = try arena.alloc(PersistedKnownPosition, known_len);
    var known_i: usize = 0;
    for (learning.knownSlice()) |entry| {
        if (!learning.hasData(entry.pos.cp)) continue;
        known_out[known_i] = .{
            .cp = entry.pos.cp,
            .layer = entry.pos.layer,
            .slot = entry.pos.slot,
            .shift = entry.pos.shift,
            .combo_slot = entry.pos.combo_slot,
            .seen = if (entry.seen) |s| .{
                .board = s.board,
                .key_index = s.key_index,
                .combo_key_index = s.combo_key_index,
                .layer_key_index = s.layer_key_index,
            } else null,
        };
        known_i += 1;
    }

    // Keep the keyboards that a saved position was last seen on.
    var boards_out: std.ArrayList(PersistedBoard) = .empty;
    for (boards.slice()) |*board| {
        const referenced = for (known_out) |k| {
            if (k.seen) |s| if (s.board == board.hash) break true;
        } else false;
        if (!referenced) continue;
        const layers = try arena.alloc(PersistedBoardLayer, board.layer_len);
        for (layers, 0..) |*dst, i| {
            const labels = try arena.alloc(u32, board.key_count);
            for (labels, board.labels[i][0..board.key_count]) |*out, cp| out.* = cp;
            dst.* = .{ .layer = board.layers[i], .labels = labels };
        }
        try boards_out.append(arena, .{
            .board_id = try arena.dupe(u8, board.idSlice()),
            .key_count = board.key_count,
            .layers = layers,
        });
    }

    var state = base_settings;
    state.schema_version = schema_version;
    state.language = learning.config.language;
    state.target_wpm = learning.config.target_wpm;
    state.board_id = try arena.dupe(u8, board_id);
    state.layout_key_hash = try arena.dupe(u8, &hash_hex);
    state.host_layout = try arena.dupe(u8, host_layout);
    state.unlocked_count = @intCast(learning.unlocked_count);
    state.rounds_since_unlock = learning.rounds_since_unlock;
    state.total_rounds = learning.total_rounds;
    state.focus_cp = if (learning.focus_cp) |f| @as(u32, f) else null;
    state.focus_history = focus_hist;
    state.key_stats = stats;
    state.bigrams = bgs;
    state.known_positions = known_out;
    state.boards_seen = try boards_out.toOwnedSlice(arena);
    return state;
}

// ---------------------------------------------------------------------------
// Unit tests (using std.testing.tmpDir)
// ---------------------------------------------------------------------------

test "state.zon roundtrip, atomic overwrite, corrupt recovery and reset" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const hash: [32]u8 = @splat(0xab);

    // Missing profile returns clean defaults
    var initial = try loadState(t.allocator, t.io, tmp.dir, hash);
    defer initial.deinit();
    try t.expect(!initial.existed);
    try t.expect(!initial.recovered_from_corrupt);
    try t.expectEqual(model.Language.en, initial.state.language);
    try t.expectEqual(ErrorMode.forgive, initial.state.error_mode);

    // Save full state and verify roundtrip
    const saved_stats = [_]PersistedKeyStat{
        .{ .cp = 'a', .ema_ms = 240.5, .ema_acc = 0.98, .samples = 30 },
        .{ .cp = 's', .ema_ms = 310.0, .ema_acc = 0.92, .samples = 18 },
    };
    const saved_hist = [_]PersistedFocusSample{
        .{ .ema_ms = 360.0, .confidence = 0.50 },
        .{ .ema_ms = 330.0, .confidence = 0.65 },
    };
    const saved_known = [_]PersistedKnownPosition{
        .{ .cp = 'a', .layer = 0, .slot = 10, .shift = false },
        .{ .cp = 'z', .layer = 0, .slot = 11, .shift = false, .seen = .{ .board = 7, .key_index = 3 } },
        .{ .cp = 'z', .layer = 1, .slot = 12, .shift = false, .combo_slot = 13, .seen = .{ .board = 8, .key_index = 4, .combo_key_index = 5, .layer_key_index = 30 } },
    };
    const saved_boards = [_]PersistedBoard{.{
        .board_id = "keycaprio_34",
        .key_count = 4,
        .layers = &.{ .{ .layer = 0, .labels = &.{ 'q', 'w', 0, 'z' } }, .{ .layer = 1, .labels = &.{ '1', '2', '3', '4' } } },
    }};
    const state: ProfileState = .{
        .language = .en,
        .board_id = "keycaprio_34",
        .layout_key_hash = "deadbeef",
        .host_layout = "en-US",
        .active_stage = 2,
        .target_wpm = 45.0,
        .guidance_mode = .on_hesitation,
        .error_mode = .stop_on_error,
        .daily_goal_minutes = 20,
        .daily_active_seconds = 360,
        .daily_utc_day = 20_000,
        .streak_days = 4,
        .unlocked_count = 9,
        .rounds_since_unlock = 1,
        .total_rounds = 12,
        .focus_cp = 's',
        .focus_history = &saved_hist,
        .key_stats = &saved_stats,
        .known_positions = &saved_known,
        .boards_seen = &saved_boards,
    };
    try saveState(t.allocator, t.io, tmp.dir, hash, state);

    var loaded = try loadState(t.allocator, t.io, tmp.dir, hash);
    defer loaded.deinit();
    try t.expect(loaded.existed);
    try t.expect(!loaded.recovered_from_corrupt);
    try t.expectEqual(model.Language.en, loaded.state.language);
    try t.expectEqualStrings("keycaprio_34", loaded.state.board_id);
    try t.expectEqual(@as(u8, 2), loaded.state.active_stage);
    try t.expectApproxEqAbs(@as(f32, 45.0), loaded.state.target_wpm, 0.01);
    try t.expectEqual(GuidanceMode.on_hesitation, loaded.state.guidance_mode);
    try t.expectEqual(@as(u32, 4), loaded.state.streak_days);
    try t.expectEqual(@as(usize, 2), loaded.state.key_stats.len);
    try t.expectEqual(@as(usize, 2), loaded.state.focus_history.len);
    try t.expectEqual(@as(usize, 3), loaded.state.known_positions.len);
    try t.expectEqual(@as(?u16, 13), loaded.state.known_positions[2].combo_slot);
    try t.expectEqual(@as(?u16, 30), loaded.state.known_positions[2].seen.?.layer_key_index);
    try t.expectEqual(@as(usize, 1), loaded.state.boards_seen.len);
    try t.expectEqual(@as(u32, 'z'), loaded.state.boards_seen[0].layers[0].labels[3]);
    var boards: model.BoardSnapshots = .{};
    hydrateBoards(loaded.state, &boards);
    const board = boards.find(model.boardHash("keycaprio_34")).?;
    try t.expectEqualSlices(u21, &.{ '1', '2', '3', '4' }, board.layerLabels(1).?);
    try t.expect(board.layerLabels(2) == null);

    // Atomic overwrite preserves new state cleanly
    var updated = state;
    updated.total_rounds = 13;
    try saveState(t.allocator, t.io, tmp.dir, hash, updated);
    var reloaded = try loadState(t.allocator, t.io, tmp.dir, hash);
    defer reloaded.deinit();
    try t.expectEqual(@as(u32, 13), reloaded.state.total_rounds);

    // Corrupt state.zon recovers cleanly and backs up corrupt file
    var rel_buf: [96]u8 = undefined;
    const rel = profileRelPath(hash, &rel_buf);
    var pdir = try tmp.dir.openDir(t.io, rel, .{});
    defer pdir.close(t.io);
    try pdir.writeFile(t.io, .{ .sub_path = state_filename, .data = ".{ .corrupt = !!!" });

    var recovered = try loadState(t.allocator, t.io, tmp.dir, hash);
    defer recovered.deinit();
    try t.expect(recovered.recovered_from_corrupt);
    try t.expectEqual(@as(u32, 0), recovered.state.total_rounds);
    try pdir.access(t.io, corrupt_backup_filename, .{});

    // Reset clears profile files cleanly
    try resetProfile(t.io, tmp.dir, hash);
    var after_reset = try loadState(t.allocator, t.io, tmp.dir, hash);
    defer after_reset.deinit();
    try t.expect(!after_reset.existed);
}

test "runs.jsonl append, multi-round readback, and recovery from truncated final line" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const hash: [32]u8 = @splat(0x22);
    try appendRun(t.allocator, t.io, tmp.dir, hash, .{
        .utc_timestamp = 1_700_000_000,
        .stage = 1,
        .wpm = 34.5,
        .accuracy = 97.2,
        .active_seconds = 32.0,
        .focus_key = 'f',
        .top_weak_keys = &.{ 'f', 'd' },
        .top_weak_bigrams = &.{.{ 'd', 'f' }},
    });
    try appendRun(t.allocator, t.io, tmp.dir, hash, .{
        .utc_timestamp = 1_700_000_060,
        .stage = 2,
        .wpm = 38.0,
        .accuracy = 98.5,
        .active_seconds = 35.0,
        .focus_key = 'e',
        .unlocked_char = 'e',
        .top_weak_keys = &.{'e'},
        .top_weak_bigrams = &.{.{ 't', 'e' }},
    });

    // Simulate a crash leaving a truncated trailing line in runs.jsonl
    var rel_buf: [96]u8 = undefined;
    var pdir = try tmp.dir.openDir(t.io, profileRelPath(hash, &rel_buf), .{});
    defer pdir.close(t.io);
    {
        var file = try pdir.createFile(t.io, runs_filename, .{ .truncate = false, .read = true });
        defer file.close(t.io);
        const end = (try file.stat(t.io)).size;
        try file.writePositionalAll(t.io, "{\"utc_timestamp\":1700000120,\"stage\":2,\"wpm\":", end);
    }

    {
        var loaded = try loadRuns(t.allocator, t.io, tmp.dir, hash);
        defer loaded.deinit();
        try t.expectEqual(@as(usize, 2), loaded.runs.len);
        try t.expectEqual(@as(usize, 1), loaded.skipped_lines);
        try t.expectApproxEqAbs(@as(f32, 34.5), loaded.runs[0].wpm, 0.01);
        try t.expectEqual(@as(?u32, 'e'), loaded.runs[1].unlocked_char);
        try t.expectEqual(@as(u32, 'f'), loaded.runs[0].top_weak_keys[0]);
    }

    // The next round after the crash lands on its own line and survives.
    try appendRun(t.allocator, t.io, tmp.dir, hash, .{
        .utc_timestamp = 1_700_000_180,
        .stage = 3,
        .wpm = 40.0,
        .accuracy = 99.0,
        .active_seconds = 30.0,
    });
    var after = try loadRuns(t.allocator, t.io, tmp.dir, hash);
    defer after.deinit();
    try t.expectEqual(@as(usize, 3), after.runs.len);
    try t.expectEqual(@as(usize, 1), after.skipped_lines);
    try t.expectEqual(@as(u8, 3), after.runs[2].stage);
}

test "dailyView rolls daily seconds and lapses the streak without mutating state" {
    const t = std.testing;
    const day: u32 = 20_000;
    const st: ProfileState = .{ .daily_utc_day = day, .daily_active_seconds = 840, .streak_days = 4 };
    const same = dailyView(st, @as(u64, day) * 86_400 + 100);
    try t.expectEqual(@as(u32, 840), same.active_seconds);
    try t.expectEqual(@as(u32, 4), same.streak_days);
    const next = dailyView(st, @as(u64, day + 1) * 86_400 + 100);
    try t.expectEqual(@as(u32, 0), next.active_seconds);
    try t.expectEqual(@as(u32, 4), next.streak_days);
    const skipped = dailyView(st, @as(u64, day + 2) * 86_400 + 100);
    try t.expectEqual(@as(u32, 0), skipped.active_seconds);
    try t.expectEqual(@as(u32, 0), skipped.streak_days);
    const unknown = dailyView(st, 0);
    try t.expectEqual(@as(u32, 840), unknown.active_seconds);
}

test "daily goal, UTC streak rollover, and moved keys keeping their statistics" {
    const t = std.testing;
    var st: ProfileState = .{};
    const day0: u64 = 20_000 * 86_400 + 3600;
    recordDailyPractice(&st, day0, 120);
    try t.expectEqual(@as(u32, 120), st.daily_active_seconds);
    try t.expectEqual(@as(u32, 1), st.streak_days);

    // Same UTC day accumulates
    recordDailyPractice(&st, day0 + 600, 80);
    try t.expectEqual(@as(u32, 200), st.daily_active_seconds);
    try t.expectEqual(@as(u32, 1), st.streak_days);

    // Next UTC day rolls over daily seconds and increments streak
    recordDailyPractice(&st, day0 + 86_400, 90);
    try t.expectEqual(@as(u32, 90), st.daily_active_seconds);
    try t.expectEqual(@as(u32, 2), st.streak_days);

    // Skipping a day resets streak to 1
    recordDailyPractice(&st, day0 + 3 * 86_400, 60);
    try t.expectEqual(@as(u32, 60), st.daily_active_seconds);
    try t.expectEqual(@as(u32, 1), st.streak_days);

    // A moved key keeps its statistics through hydrateLearningModel.
    var profile: layout_profile.LayoutProfile = .{
        .unlock_len = 2,
        .zone1_len = 2,
        .key_position_len = 2,
    };
    profile.unlock_order[0] = 'a';
    profile.unlock_order[1] = 's';
    profile.key_positions[0] = .{ .cp = 'a', .layer = 0, .slot = 10, .shift = false };
    profile.key_positions[1] = .{ .cp = 's', .layer = 0, .slot = 12, .shift = false }; // moved from 11 -> 12

    const persisted: ProfileState = .{
        .unlocked_count = 2,
        .key_stats = &.{
            .{ .cp = 'a', .ema_ms = 220.0, .ema_acc = 0.99, .samples = 24 },
            .{ .cp = 's', .ema_ms = 230.0, .ema_acc = 0.98, .samples = 24 },
        },
        .known_positions = &.{
            .{ .cp = 'a', .layer = 0, .slot = 10, .shift = false },
            .{ .cp = 's', .layer = 0, .slot = 11, .shift = false },
        },
    };

    var learning: model.LearningModel = undefined;
    hydrateLearningModel(persisted, &profile, &learning);
    try t.expectEqual(@as(u32, 24), learning.getStat('a').?.samples);
    try t.expectEqual(@as(u32, 24), learning.getStat('s').?.samples);
    var current: [2]model.KnownPosition = undefined;
    for (profile.keyPositionSlice(), &current) |pos, *dst| dst.* = .{ .pos = pos };
    _ = learning.adoptPositions(&current);
    var moved: [4]u21 = undefined;
    try t.expectEqualSlices(u21, &.{'s'}, learning.unconfirmedMoves(&current, &moved));
    try t.expectEqual(@as(u32, 24), learning.getStat('s').?.samples);
}

test "a schema 1 state.zon is backed up and starts over" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const hash: [32]u8 = @splat(0x31);
    var rel_buf: [96]u8 = undefined;
    var dir = try tmp.dir.createDirPathOpen(t.io, profileRelPath(hash, &rel_buf), .{});
    defer dir.close(t.io);
    try dir.writeFile(t.io, .{ .sub_path = state_filename, .data =
        \\.{ .schema_version = 1, .total_rounds = 9, .key_positions = .{ .{ .cp = 97, .layer = 0, .slot = 1, .shift = false } } }
        \\
    });
    var loaded = try loadState(t.allocator, t.io, tmp.dir, hash);
    defer loaded.deinit();
    try t.expect(loaded.recovered_from_corrupt);
    try t.expectEqual(@as(u32, 0), loaded.state.total_rounds);
    try dir.access(t.io, corrupt_backup_filename, .{});
}

test "saved state keeps practised positions and the keyboards they were seen on" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var learning = model.LearningModel.init("az", 2, .{});
    learning.getOrAddStat('z').?.* = .{ .cp = 'z', .ema_ms = 250, .ema_acc = 1, .samples = 22, .acc_initialized = true };
    var boards: model.BoardSnapshots = .{};
    for (0..model.max_board_snapshots + 2) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "board-{d}", .{i}) catch unreachable;
        _ = boards.use(id, 3).setLayer(0, &.{ 'a', 'z', 0 });
    }
    try t.expectEqual(model.max_board_snapshots, boards.len);
    try t.expect(boards.find(model.boardHash("board-0")) == null);
    const newest = model.boardHash("board-9");
    _ = learning.adoptPositions(&.{
        .{ .pos = .{ .cp = 'a', .layer = 0, .slot = 1, .shift = false }, .seen = .{ .board = newest, .key_index = 0 } },
        .{ .pos = .{ .cp = 'z', .layer = 0, .slot = 2, .shift = false }, .seen = .{ .board = newest, .key_index = 1 } },
    });
    const profile: layout_profile.LayoutProfile = .{};
    const state = try buildProfileState(arena.allocator(), .{}, &learning, &profile, &boards, "board-9", "en-US");
    // The unpractised 'a' follows the layout and is not saved.
    try t.expectEqual(@as(usize, 1), state.known_positions.len);
    try t.expectEqual(@as(u32, 'z'), state.known_positions[0].cp);
    try t.expectEqual(@as(usize, 1), state.boards_seen.len);
    try t.expectEqualStrings("board-9", state.boards_seen[0].board_id);
}
