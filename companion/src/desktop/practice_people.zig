//! Personal Tutor profiles: several people practise on one computer, each
//! with their own letters, statistics, streak, daily goal, settings and
//! history. Everything of a person lives under
//! `<app_data>/tutor/people/<id>/`, with one `profiles/<layout hash>/`
//! directory per layout type (`practice_storage.zig`). The small index
//! `<app_data>/tutor/people.zon` names the people and the current one.
//!
//! Builds before personal profiles kept the layout directories directly in
//! `<app_data>/tutor/profiles/`. `load` moves them, one layout directory at
//! a time with an atomic rename, to the oldest person, "Me" on a first
//! start. An interrupted move leaves every layout either at its old or at
//! its new place, and the next start finishes it.
const std = @import("std");

pub const schema_version: u32 = 1;
pub const index_path = "tutor/people.zon";
pub const index_dir = "tutor";
pub const index_filename = "people.zon";
pub const corrupt_index_filename = "people.zon.corrupt";
/// Where builds before personal profiles kept the layout directories.
pub const legacy_profiles_path = "tutor/profiles";
pub const max_index_bytes: usize = 64 * 1024;

pub const max_people: usize = 12;
/// Names are trimmed and hold at most this many characters.
pub const max_name_chars: usize = 24;
pub const max_name_bytes: usize = max_name_chars * 4;
/// Colours a person can pick; the UI maps them to theme colours.
pub const colour_count: u8 = 5;
/// The name of the first person, who takes over existing progress.
pub const first_name = "Me";

pub const PersistedPerson = struct {
    id: u32,
    name: []const u8,
    colour: u8 = 0,
    /// UTC seconds; 0 is unknown.
    created: u64 = 0,
    last_used: u64 = 0,
};

pub const IndexFile = struct {
    schema_version: u32 = schema_version,
    current: u32 = 0,
    /// Ids are never reused, so a new person never finds old files.
    next_id: u32 = 1,
    people: []const PersistedPerson = &.{},
};

pub const Person = struct {
    id: u32,
    name_buf: [max_name_bytes]u8 = undefined,
    name_len: u8 = 0,
    colour: u8 = 0,
    created: u64 = 0,
    last_used: u64 = 0,

    pub fn name(self: *const Person) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn setName(self: *Person, value: []const u8) void {
        const n = @min(value.len, max_name_bytes);
        @memcpy(self.name_buf[0..n], value[0..n]);
        self.name_len = @intCast(n);
    }

    /// The first character of the name, upper-cased when it is ASCII.
    pub fn initial(self: *const Person, buf: *[4]u8) []const u8 {
        const text = self.name();
        if (text.len == 0) return "?";
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        const n = @min(len, text.len);
        @memcpy(buf[0..n], text[0..n]);
        if (n == 1) buf[0] = std.ascii.toUpper(buf[0]);
        return buf[0..n];
    }
};

pub const NameProblem = enum {
    empty,
    too_long,
    taken,

    pub fn text(self: NameProblem) []const u8 {
        return switch (self) {
            .empty => "Enter a name.",
            .too_long => std.fmt.comptimePrint("Use at most {d} characters.", .{max_name_chars}),
            .taken => "Another profile has this name.",
        };
    }
};

pub const NameCheck = union(enum) {
    ok: []const u8,
    problem: NameProblem,
};

/// The trimmed name, or why it cannot be used next to `others`: empty,
/// longer than `max_name_chars`, or another person's name in any case.
pub fn checkNameAmong(raw: []const u8, others: []const []const u8) NameCheck {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .problem = .empty };
    const chars = std.unicode.utf8CountCodepoints(trimmed) catch return .{ .problem = .too_long };
    if (chars > max_name_chars or trimmed.len > max_name_bytes) return .{ .problem = .too_long };
    for (others) |other| if (std.ascii.eqlIgnoreCase(other, trimmed)) return .{ .problem = .taken };
    return .{ .ok = trimmed };
}

/// What the person menu says about someone's progress on one layout type.
pub const Summary = struct {
    /// Whether they have practised this layout type at all.
    started: bool,
    unlocked: usize = 0,
    letters: usize = 0,
    /// UTC day of their last practice; 0 is unknown.
    last_day: u32 = 0,
    streak_days: u32 = 0,
};

/// "16/26 letters · 5-day streak", "7/26 letters · practised yesterday" or
/// "Not started on this layout".
pub fn summaryText(buf: []u8, summary: Summary, utc_now_sec: u64) []const u8 {
    if (!summary.started) return "Not started on this layout";
    const today: u64 = utc_now_sec / 86_400;
    const head = std.fmt.bufPrint(buf, "{d}/{d} letters", .{ summary.unlocked, summary.letters }) catch return "";
    const rest = buf[head.len..];
    const tail = if (summary.streak_days >= 2)
        std.fmt.bufPrint(rest, " · {d}-day streak", .{summary.streak_days})
    else if (summary.last_day == 0 or utc_now_sec == 0 or today < summary.last_day)
        return head
    else switch (today - summary.last_day) {
        0 => std.fmt.bufPrint(rest, " · practised today", .{}),
        1 => std.fmt.bufPrint(rest, " · practised yesterday", .{}),
        else => |days| std.fmt.bufPrint(rest, " · practised {d} days ago", .{days}),
    };
    return buf[0 .. head.len + (tail catch return head).len];
}

pub const People = struct {
    items: [max_people]Person = undefined,
    len: usize = 0,
    current: u32 = 0,
    next_id: u32 = 1,

    pub fn slice(self: *const People) []const Person {
        return self.items[0..self.len];
    }

    pub fn find(self: *const People, id: u32) ?*const Person {
        for (self.items[0..self.len]) |*p| if (p.id == id) return p;
        return null;
    }

    fn findMut(self: *People, id: u32) ?*Person {
        for (self.items[0..self.len]) |*p| if (p.id == id) return p;
        return null;
    }

    pub fn currentPerson(self: *const People) ?*const Person {
        return self.find(self.current);
    }

    /// The trimmed name, or why it cannot be used. `except` is the person
    /// being renamed, who may keep their own name.
    pub fn checkName(self: *const People, raw: []const u8, except: ?u32) NameCheck {
        var others: [max_people][]const u8 = undefined;
        var len: usize = 0;
        for (self.slice()) |*p| {
            if (except != null and p.id == except.?) continue;
            others[len] = p.name();
            len += 1;
        }
        return checkNameAmong(raw, others[0..len]);
    }

    /// Adds a person and returns their id. The caller switches to them.
    pub fn add(self: *People, raw_name: []const u8, colour: u8, now_sec: u64) !u32 {
        if (self.len == max_people) return error.TooManyPeople;
        const name = switch (self.checkName(raw_name, null)) {
            .ok => |n| n,
            .problem => return error.InvalidName,
        };
        const id = self.next_id;
        self.next_id +|= 1;
        var person: Person = .{ .id = id, .colour = colour % colour_count, .created = now_sec, .last_used = now_sec };
        person.setName(name);
        self.items[self.len] = person;
        self.len += 1;
        return id;
    }

    pub fn rename(self: *People, id: u32, raw_name: []const u8, colour: u8) !void {
        const name = switch (self.checkName(raw_name, id)) {
            .ok => |n| n,
            .problem => return error.InvalidName,
        };
        const person = self.findMut(id) orelse return error.UnknownPerson;
        person.setName(name);
        person.colour = colour % colour_count;
    }

    /// Removes a person from the index; their files go with `deleteData`.
    /// The last person cannot be removed. A removed current person hands
    /// over to the most recently used one left.
    pub fn remove(self: *People, id: u32) !void {
        if (self.len <= 1) return error.LastPerson;
        const index = for (self.items[0..self.len], 0..) |p, i| {
            if (p.id == id) break i;
        } else return error.UnknownPerson;
        std.mem.copyForwards(Person, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
        self.len -= 1;
        if (self.current == id) {
            var best = &self.items[0];
            for (self.items[0..self.len]) |*p| if (p.last_used > best.last_used) {
                best = p;
            };
            self.current = best.id;
        }
    }

    pub fn select(self: *People, id: u32, now_sec: u64) !void {
        const person = self.findMut(id) orelse return error.UnknownPerson;
        self.current = id;
        if (now_sec > 0) person.last_used = now_sec;
    }

    /// A colour nobody uses yet, for a new person.
    pub fn freeColour(self: *const People) u8 {
        var used: u8 = 0;
        for (self.slice()) |p| used |= @as(u8, 1) << @intCast(p.colour % colour_count);
        for (0..colour_count) |c| if (used & (@as(u8, 1) << @intCast(c)) == 0) return @intCast(c);
        return @intCast(self.len % colour_count);
    }

    /// The oldest person: the one existing progress belongs to.
    pub fn oldest(self: *const People) ?u32 {
        var best: ?u32 = null;
        for (self.slice()) |p| if (best == null or p.id < best.?) {
            best = p.id;
        };
        return best;
    }

    /// Keeps the index usable whatever the file said: unique ids, names,
    /// a current person and ids that are never reused. Returns whether
    /// anything changed.
    fn normalize(self: *People) bool {
        var changed = false;
        var write: usize = 0;
        for (0..self.len) |i| {
            const p = self.items[i];
            const dup = for (self.items[0..write]) |q| {
                if (q.id == p.id) break true;
            } else false;
            if (p.id == 0 or dup) {
                changed = true;
                continue;
            }
            self.items[write] = p;
            const person = &self.items[write];
            if (person.name_len == 0) {
                fallbackName(person);
                changed = true;
            }
            if (person.colour >= colour_count) {
                person.colour %= colour_count;
                changed = true;
            }
            write += 1;
        }
        self.len = write;
        for (self.slice()) |p| if (self.next_id <= p.id) {
            self.next_id = p.id +| 1;
            changed = true;
        };
        if (self.find(self.current) == null) {
            self.current = if (self.len > 0) self.items[0].id else 0;
            changed = true;
        }
        return changed;
    }
};

fn fallbackName(person: *Person) void {
    var buf: [32]u8 = undefined;
    person.setName(std.fmt.bufPrint(&buf, "Profile {d}", .{person.id}) catch "Profile");
}

/// `tutor/people/<id>`, the directory of a person relative to the
/// application data directory.
pub fn personRelPath(id: u32, buf: *[48]u8) []const u8 {
    return std.fmt.bufPrint(buf, "tutor/people/{d}", .{id}) catch unreachable;
}

pub const Loaded = struct {
    people: People,
    /// Layout directories moved from the old place in this load.
    migrated: usize = 0,
    /// Layout directories left at the old place because the person already
    /// has one for that layout.
    left_behind: usize = 0,
    /// The index was unreadable and was rebuilt from the person directories.
    recovered_from_corrupt: bool = false,
};

/// Reads the people index, creating it (and the first person, "Me") when
/// there is none, and moves progress from before personal profiles to the
/// oldest person. Safe to run on every start; a second run changes nothing.
pub fn load(gpa: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir, now_sec: u64) !Loaded {
    var result: Loaded = .{ .people = .{} };
    var found = false;
    var dirty = false;
    if (data_dir.readFileAlloc(io, index_path, gpa, .limited(max_index_bytes))) |bytes| {
        defer gpa.free(bytes);
        if (parseIndex(gpa, bytes, &result.people)) {
            found = true;
        } else |_| {
            data_dir.rename(index_path, data_dir, index_dir ++ "/" ++ corrupt_index_filename, io) catch {};
            result.recovered_from_corrupt = true;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        // A transient read failure must not let a fresh index replace it.
        else => return err,
    }

    if (!found) {
        // A move that wrote no index yet, or a lost index: the person
        // directories are still there.
        try scanPeople(io, data_dir, &result.people);
        dirty = true;
    }
    if (result.people.normalize()) dirty = true;
    if (result.people.len == 0) {
        _ = try result.people.add(first_name, 0, now_sec);
        result.people.current = result.people.items[0].id;
        dirty = true;
    }
    // The first person keeps the name a rebuilt index cannot know.
    if (!found) {
        if (result.people.find(result.people.oldest().?)) |p| if (std.mem.startsWith(u8, p.name(), "Profile ")) {
            result.people.findMut(p.id).?.setName(first_name);
        };
    }
    // The index goes first: a crash before the move then still names the
    // person the old progress belongs to.
    if (dirty) try save(gpa, io, data_dir, &result.people);

    const owner = result.people.oldest().?;
    const moved = try migrateLegacy(io, data_dir, owner);
    result.migrated = moved.moved;
    result.left_behind = moved.left;
    return result;
}

fn parseIndex(gpa: std.mem.Allocator, bytes: []const u8, out: *People) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const source = try arena.allocator().dupeSentinel(u8, bytes, 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const parsed = try std.zon.parse.fromSlice(IndexFile, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    });
    if (parsed.schema_version == 0 or parsed.schema_version > schema_version) return error.UnsupportedPeopleIndex;
    out.* = .{ .current = parsed.current, .next_id = @max(parsed.next_id, 1) };
    for (parsed.people) |saved| {
        if (out.len == max_people) break;
        var person: Person = .{
            .id = saved.id,
            .colour = saved.colour,
            .created = saved.created,
            .last_used = saved.last_used,
        };
        const trimmed = std.mem.trim(u8, saved.name, " \t\r\n");
        person.setName(trimmed[0..@min(trimmed.len, max_name_bytes)]);
        out.items[out.len] = person;
        out.len += 1;
    }
}

/// Fills `out` with one person per numbered directory in `tutor/people`.
fn scanPeople(io: std.Io, data_dir: std.Io.Dir, out: *People) !void {
    out.* = .{};
    var dir = data_dir.openDir(io, "tutor/people", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var ids: [max_people]u32 = undefined;
    var len: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const id = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        if (id == 0 or len == ids.len) continue;
        ids[len] = id;
        len += 1;
    }
    std.mem.sortUnstable(u32, ids[0..len], {}, std.sort.asc(u32));
    for (ids[0..len]) |id| {
        var person: Person = .{ .id = id, .colour = @intCast(out.len % colour_count) };
        fallbackName(&person);
        out.items[out.len] = person;
        out.len += 1;
        out.next_id = @max(out.next_id, id +| 1);
    }
    if (out.len > 0) out.current = out.items[0].id;
}

const MoveResult = struct { moved: usize = 0, left: usize = 0 };

/// Moves every layout directory of `tutor/profiles` into the person's
/// `profiles` directory, each with one atomic rename, and removes the old
/// directory once it is empty. A layout the person already has stays where
/// it is.
fn migrateLegacy(io: std.Io, data_dir: std.Io.Dir, owner: u32) !MoveResult {
    var legacy = data_dir.openDir(io, legacy_profiles_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer legacy.close(io);
    var rel_buf: [48]u8 = undefined;
    var person_dir = try data_dir.createDirPathOpen(io, personRelPath(owner, &rel_buf), .{});
    defer person_dir.close(io);
    var target = try person_dir.createDirPathOpen(io, "profiles", .{});
    defer target.close(io);

    var result: MoveResult = .{};
    // Renaming while iterating can skip entries; collect the names first.
    var names: [64][65]u8 = undefined;
    var name_lens: [64]u8 = undefined;
    var more = true;
    while (more) {
        var count: usize = 0;
        more = false;
        var it = legacy.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory or entry.name.len > 64) continue;
            if (target.access(io, entry.name, .{})) |_| {
                continue;
            } else |err| if (err != error.FileNotFound) return err;
            if (count == names.len) {
                more = true;
                break;
            }
            @memcpy(names[count][0..entry.name.len], entry.name);
            name_lens[count] = @intCast(entry.name.len);
            count += 1;
        }
        for (names[0..count], name_lens[0..count]) |*buf, len| {
            try legacy.rename(buf[0..len], target, buf[0..len], io);
            result.moved += 1;
        }
        if (count == 0) more = false;
    }
    var it = legacy.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) result.left += 1;
    }
    if (result.left == 0) data_dir.deleteDir(io, legacy_profiles_path) catch {};
    return result;
}

/// Atomically writes the index (temp file, sync, replace).
pub fn save(gpa: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir, people: *const People) !void {
    var persisted: [max_people]PersistedPerson = undefined;
    for (people.slice(), persisted[0..people.len]) |*p, *dst| dst.* = .{
        .id = p.id,
        .name = p.name(),
        .colour = p.colour,
        .created = p.created,
        .last_used = p.last_used,
    };
    const file: IndexFile = .{
        .current = people.current,
        .next_id = people.next_id,
        .people = persisted[0..people.len],
    };
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    try std.zon.stringify.serialize(file, .{ .whitespace = true }, &writer.writer);
    try writer.writer.writeByte('\n');

    var dir = try data_dir.createDirPathOpen(io, index_dir, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, index_filename, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, writer.written());
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Deletes all files of a person. Call it after the index without them was
/// saved, so a crash leaves an unused directory rather than a person
/// without files; ids are never reused.
pub fn deleteData(io: std.Io, data_dir: std.Io.Dir, id: u32) !void {
    var rel_buf: [48]u8 = undefined;
    try data_dir.deleteTree(io, personRelPath(id, &rel_buf));
}

// ---------------------------------------------------------------------------
// Tests (std.testing.tmpDir; never the user's data)
// ---------------------------------------------------------------------------

const storage = @import("practice_storage.zig");

/// `state.zon` of one layout exactly as the build before personal profiles
/// saved it under `tutor/profiles/<hash>`.
const legacy_state =
    \\.{
    \\    .schema_version = 3,
    \\    .language = .en,
    \\    .board_id = "keycaprio_colemak_0_7",
    \\    .layout_key_hash = "9a1f",
    \\    .host_layout = "com.apple.keylayout.US",
    \\    .active_stage = 2,
    \\    .target_wpm = 25,
    \\    .guidance_mode = .guided,
    \\    .error_mode = .forgive,
    \\    .daily_goal_minutes = 15,
    \\    .daily_active_seconds = 540,
    \\    .daily_utc_day = 20410,
    \\    .streak_days = 5,
    \\    .unlocked_count = 16,
    \\    .letter_order = .word_forming,
    \\    .unlocked_letters = "esrtnohadicklgup",
    \\    .rounds_since_unlock = 3,
    \\    .total_rounds = 87,
    \\    .focus_cp = 112,
    \\    .focus_history = .{.{ .ema_ms = 520.5, .confidence = 0.7 }},
    \\    .key_stats = .{ .{
    \\        .cp = 101,
    \\        .ema_ms = 301.25,
    \\        .ema_acc = 0.9666667,
    \\        .samples = 412,
    \\        .acc_initialized = true,
    \\        .recent_hits = 1073741822,
    \\        .recent_len = 30,
    \\        .mastered = true,
    \\    }, .{
    \\        .cp = 112,
    \\        .ema_ms = 520.5,
    \\        .ema_acc = 0.9,
    \\        .samples = 31,
    \\        .acc_initialized = true,
    \\        .recent_hits = 1073479679,
    \\        .recent_len = 30,
    \\        .mastered = false,
    \\    } },
    \\    .bigrams = .{.{
    \\        .prev = 112,
    \\        .cur = 114,
    \\        .ema_ms = 725.5,
    \\        .samples = 9,
    \\    }},
    \\    .known_positions = .{},
    \\    .boards_seen = .{},
    \\    .tap_hold_stats = .{.{
    \\        .cp = 100,
    \\        .holds = 3,
    \\        .reason_bits = .{ 0, 0, 0, 0, 0 },
    \\        .recent_len = 30,
    \\        .total = 140,
    \\        .reasons = .{ 0, 0, 0, 0, 0 },
    \\        .ema_ms = 95.5,
    \\        .tapping_term_ms = 200,
    \\    }},
    \\}
    \\
;

const legacy_runs =
    \\{"utc_timestamp":1763400000,"stage":2,"wpm":31.5,"accuracy":97.1,"active_seconds":38.0,"focus_key":112,"unlocked_char":null,"top_weak_keys":[112,105],"top_weak_bigrams":[[112,114]],"weak_spot":null,"newly_green":[]}
    \\{"utc_timestamp":1763400090,"stage":2,"wpm":33.0,"accuracy":96.4,"active_seconds":36.5,"focus_key":112,"unlocked_char":null,"top_weak_keys":[112],"top_weak_bigrams":[],"weak_spot":[112,114],"newly_green":[107],"tap_hold_decisions":40,"accidental_holds":1,"accidental_taps":0,"near_holds":2,"top_accidental_hold":[100,1],"top_accidental_tap":null}
    \\
;

const legacy_hash: [32]u8 = @splat(0x9a);

fn writeLegacy(io: std.Io, data_dir: std.Io.Dir, hash: [32]u8) !void {
    const hex = std.fmt.bytesToHex(hash, .lower);
    var buf: [128]u8 = undefined;
    var dir = try data_dir.createDirPathOpen(io, try std.fmt.bufPrint(&buf, "tutor/profiles/{s}", .{&hex}), .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = storage.state_filename, .data = legacy_state });
    try dir.writeFile(io, .{ .sub_path = storage.runs_filename, .data = legacy_runs });
}

fn openPerson(io: std.Io, data_dir: std.Io.Dir, id: u32) !std.Io.Dir {
    var buf: [48]u8 = undefined;
    return data_dir.openDir(io, personRelPath(id, &buf), .{});
}

/// The legacy fixture's progress, read through the person's directory.
fn expectLegacyProgress(io: std.Io, data_dir: std.Io.Dir, id: u32) !void {
    const t = std.testing;
    var person = try openPerson(io, data_dir, id);
    defer person.close(io);
    var loaded = try storage.loadState(t.allocator, io, person, legacy_hash);
    defer loaded.deinit();
    try t.expect(loaded.existed and !loaded.recovered_from_corrupt);
    const s = loaded.state;
    try t.expectEqual(@as(u32, 87), s.total_rounds);
    try t.expectEqual(@as(u32, 5), s.streak_days);
    try t.expectEqualStrings("esrtnohadicklgup", s.unlocked_letters);
    try t.expectApproxEqAbs(@as(f32, 25), s.target_wpm, 0.001);
    try t.expectEqual(@as(usize, 2), s.key_stats.len);
    try t.expectEqual(@as(u32, 412), s.key_stats[0].samples);
    try t.expect(s.key_stats[0].mastered);
    try t.expectEqual(@as(usize, 1), s.tap_hold_stats.len);
    try t.expectEqual(@as(u32, 140), s.tap_hold_stats[0].total);
    // Saves without the setting keep refreshes on.
    try t.expect(s.refresh_slipped);
    var runs = try storage.loadRuns(t.allocator, io, person, legacy_hash);
    defer runs.deinit();
    try t.expectEqual(@as(usize, 2), runs.runs.len);
    try t.expectEqual(@as(usize, 0), runs.skipped_lines);
    try t.expectEqual(@as(u16, 40), runs.runs[1].tap_hold_decisions);
}

test "a first start moves today's progress to the person Me, and a second start changes nothing" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeLegacy(t.io, tmp.dir, legacy_hash);
    const other: [32]u8 = @splat(0x22);
    try writeLegacy(t.io, tmp.dir, other);

    const first = try load(t.allocator, t.io, tmp.dir, 1_763_500_000);
    try t.expectEqual(@as(usize, 1), first.people.len);
    const me = first.people.currentPerson().?;
    try t.expectEqualStrings("Me", me.name());
    try t.expectEqual(@as(usize, 2), first.migrated);
    try t.expectEqual(@as(usize, 0), first.left_behind);
    try expectLegacyProgress(t.io, tmp.dir, me.id);
    // The old directory is gone once everything moved.
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, legacy_profiles_path, .{}));

    const second = try load(t.allocator, t.io, tmp.dir, 1_763_600_000);
    try t.expectEqual(@as(usize, 0), second.migrated);
    try t.expectEqual(@as(usize, 1), second.people.len);
    try t.expectEqual(me.id, second.people.current);
    try t.expectEqualStrings("Me", second.people.currentPerson().?.name());
    try expectLegacyProgress(t.io, tmp.dir, me.id);
}

test "an interrupted move is completed by the next start" {
    const t = std.testing;
    // 1. The index was written, then the app stopped before anything moved.
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        var people: People = .{};
        _ = try people.add("Me", 0, 1);
        people.current = people.items[0].id;
        try save(t.allocator, t.io, tmp.dir, &people);
        try writeLegacy(t.io, tmp.dir, legacy_hash);
        const loaded = try load(t.allocator, t.io, tmp.dir, 2);
        try t.expectEqual(@as(usize, 1), loaded.migrated);
        try expectLegacyProgress(t.io, tmp.dir, people.items[0].id);
    }
    // 2. One layout moved, the other did not, and no index was written yet.
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try writeLegacy(t.io, tmp.dir, legacy_hash);
        const other: [32]u8 = @splat(0x22);
        try writeLegacy(t.io, tmp.dir, other);
        var person = try tmp.dir.createDirPathOpen(t.io, "tutor/people/1/profiles", .{});
        defer person.close(t.io);
        const hex = std.fmt.bytesToHex(legacy_hash, .lower);
        var buf: [96]u8 = undefined;
        try tmp.dir.rename(try std.fmt.bufPrint(&buf, "tutor/profiles/{s}", .{&hex}), person, &hex, t.io);

        const loaded = try load(t.allocator, t.io, tmp.dir, 3);
        try t.expectEqual(@as(usize, 1), loaded.people.len);
        try t.expectEqualStrings("Me", loaded.people.currentPerson().?.name());
        try t.expectEqual(@as(u32, 1), loaded.people.current);
        try t.expectEqual(@as(usize, 1), loaded.migrated);
        try expectLegacyProgress(t.io, tmp.dir, 1);
        var moved_other = try openPerson(t.io, tmp.dir, 1);
        defer moved_other.close(t.io);
        var other_state = try storage.loadState(t.allocator, t.io, moved_other, other);
        defer other_state.deinit();
        try t.expectEqual(@as(u32, 87), other_state.state.total_rounds);
        try t.expectError(error.FileNotFound, tmp.dir.access(t.io, legacy_profiles_path, .{}));
    }
    // 3. Everything moved but the index was never written.
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try writeLegacy(t.io, tmp.dir, legacy_hash);
        _ = try load(t.allocator, t.io, tmp.dir, 4);
        try tmp.dir.deleteFile(t.io, index_path);
        const again = try load(t.allocator, t.io, tmp.dir, 5);
        try t.expectEqualStrings("Me", again.people.currentPerson().?.name());
        try expectLegacyProgress(t.io, tmp.dir, again.people.current);
    }
}

test "a layout the person already has stays at the old place" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeLegacy(t.io, tmp.dir, legacy_hash);
    _ = try load(t.allocator, t.io, tmp.dir, 1);
    // An older build wrote the same layout again at the old place.
    try writeLegacy(t.io, tmp.dir, legacy_hash);
    const loaded = try load(t.allocator, t.io, tmp.dir, 2);
    try t.expectEqual(@as(usize, 0), loaded.migrated);
    try t.expectEqual(@as(usize, 1), loaded.left_behind);
    try tmp.dir.access(t.io, legacy_profiles_path, .{});
    try expectLegacyProgress(t.io, tmp.dir, 1);
}

test "people are added, renamed, switched and deleted with their files" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var loaded = try load(t.allocator, t.io, tmp.dir, 100);
    const people = &loaded.people;
    try t.expectEqual(@as(usize, 1), people.len);
    try t.expectEqual(@as(usize, 0), loaded.migrated);

    try t.expectEqual(NameCheck{ .problem = .empty }, people.checkName("   ", null));
    try t.expectEqual(NameCheck{ .problem = .taken }, people.checkName(" me ", null));
    try t.expectEqual(NameCheck{ .problem = .too_long }, people.checkName("abcdefghijklmnopqrstuvwxyz", null));
    try t.expectEqualStrings("Jürgen", people.checkName("  Jürgen ", null).ok);
    // Renaming to one's own name is fine.
    try t.expectEqualStrings("ME", people.checkName("ME", people.current).ok);

    const lisa = try people.add(" Lisa ", people.freeColour(), 200);
    try t.expect(lisa != people.items[0].id);
    try t.expectEqual(@as(u8, 1), people.find(lisa).?.colour);
    try people.select(lisa, 210);
    try people.rename(people.items[0].id, "Conny", 0);
    try t.expectError(error.InvalidName, people.rename(lisa, "conny", 1));
    try save(t.allocator, t.io, tmp.dir, people);

    // Lisa's progress is her own.
    var buf: [48]u8 = undefined;
    var lisa_dir = try tmp.dir.createDirPathOpen(t.io, personRelPath(lisa, &buf), .{});
    try storage.saveState(t.allocator, t.io, lisa_dir, legacy_hash, .{ .total_rounds = 4 });
    lisa_dir.close(t.io);

    const reread = try load(t.allocator, t.io, tmp.dir, 300);
    try t.expectEqual(@as(usize, 2), reread.people.len);
    try t.expectEqual(lisa, reread.people.current);
    try t.expectEqualStrings("Conny", reread.people.find(1).?.name());
    try t.expectEqualStrings("Lisa", reread.people.currentPerson().?.name());
    try t.expectEqual(@as(u64, 210), reread.people.currentPerson().?.last_used);

    // The last person stays; deleting the current one hands over.
    try people.remove(lisa);
    try t.expectEqual(@as(u32, 1), people.current);
    try t.expectError(error.LastPerson, people.remove(1));
    try save(t.allocator, t.io, tmp.dir, people);
    try deleteData(t.io, tmp.dir, lisa);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, personRelPath(lisa, &buf), .{}));
    // A new person never gets Lisa's id back.
    const next = try people.add("Sam", 2, 400);
    try t.expect(next > lisa);
}

test "an unreadable index is backed up and rebuilt from the person directories" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeLegacy(t.io, tmp.dir, legacy_hash);
    _ = try load(t.allocator, t.io, tmp.dir, 1);
    try tmp.dir.createDirPath(t.io, "tutor/people/4");
    try tmp.dir.writeFile(t.io, .{ .sub_path = index_path, .data = ".{ .people = !!" });
    const loaded = try load(t.allocator, t.io, tmp.dir, 2);
    try t.expect(loaded.recovered_from_corrupt);
    try t.expectEqual(@as(usize, 2), loaded.people.len);
    try t.expectEqualStrings("Me", loaded.people.find(1).?.name());
    try t.expectEqualStrings("Profile 4", loaded.people.find(4).?.name());
    try t.expectEqual(@as(u32, 5), loaded.people.next_id);
    try tmp.dir.access(t.io, "tutor/" ++ corrupt_index_filename, .{});
    try expectLegacyProgress(t.io, tmp.dir, 1);
}

test "the person menu summarises progress on the bound layout" {
    const t = std.testing;
    var buf: [96]u8 = undefined;
    const day: u32 = 20_400;
    const now: u64 = @as(u64, day) * 86_400 + 3600;
    try t.expectEqualStrings("16/26 letters · 5-day streak", summaryText(&buf, .{ .started = true, .unlocked = 16, .letters = 26, .last_day = day, .streak_days = 5 }, now));
    try t.expectEqualStrings("7/26 letters · practised yesterday", summaryText(&buf, .{ .started = true, .unlocked = 7, .letters = 26, .last_day = day - 1, .streak_days = 1 }, now));
    try t.expectEqualStrings("7/26 letters · practised today", summaryText(&buf, .{ .started = true, .unlocked = 7, .letters = 26, .last_day = day, .streak_days = 1 }, now));
    try t.expectEqualStrings("7/26 letters · practised 9 days ago", summaryText(&buf, .{ .started = true, .unlocked = 7, .letters = 26, .last_day = day - 9 }, now));
    try t.expectEqualStrings("6/26 letters", summaryText(&buf, .{ .started = true, .unlocked = 6, .letters = 26 }, now));
    try t.expectEqualStrings("Not started on this layout", summaryText(&buf, .{ .started = false }, now));
}
