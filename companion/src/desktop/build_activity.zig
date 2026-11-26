//! The Build and Flash activity of one editor session: a bounded, in-memory
//! timeline (start, cache upkeep, warm-up, builds, Flash steps and errors)
//! and the compiler output of the last build. Pure: no filesystem, process
//! or device access, and nothing is persisted.
const std = @import("std");

pub const Kind = enum { info, ok, warn, err };

/// One timeline line, with its wall-clock time in milliseconds since the
/// Unix epoch.
pub const Entry = struct {
    at_ms: i64,
    kind: Kind,
    len: u8,
    bytes: [text_capacity]u8,

    pub fn text(self: *const Entry) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const text_capacity = 160;
pub const max_entries = 128;
/// The compiler output keeps the last 64 KiB of stderr followed by stdout.
pub const output_capacity = 64 * 1024;

/// What started a build, for the timeline and the status row.
pub const Trigger = enum {
    click,
    auto_build,
    flash,
    /// The background warm-up that fills the compiler cache.
    warmup,
    /// A Build click whose build the warm-up of the same layout became.
    warmup_adopted,

    pub fn describe(trigger: Trigger) []const u8 {
        return switch (trigger) {
            .click => "Build clicked",
            .auto_build => "Auto-build after a change",
            .flash => "for Flash",
            .warmup => "cache warm-up",
            .warmup_adopted => "warm-up adopted",
        };
    }
};

/// The compiler output of the last finished build, with its summary.
pub const Output = struct {
    /// Owned by the log's allocator; empty before the first build.
    text: []u8 = &.{},
    at_ms: i64 = 0,
    trigger: Trigger = .click,
    succeeded: bool = true,
    duration_ms: u64 = 0,
    errors: Errors = .{},
    /// Whether the start of the output was dropped to stay bounded.
    truncated: bool = false,
};

/// Compiler errors with a source location, such as `keymap.zig:12:5: error: …`.
pub const Errors = struct {
    count: u32 = 0,
    /// Every located error is in the exported layout source.
    keymap: bool = false,

    /// `1 error in the keymap`, `3 errors`.
    pub fn format(self: Errors, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d} {s}", .{ self.count, if (self.count == 1) "error" else "errors" });
        if (self.keymap) try writer.writeAll(" in the keymap");
    }
};

pub const Log = struct {
    entries: [max_entries]Entry = undefined,
    /// Index of the oldest entry.
    first: usize = 0,
    count: usize = 0,
    /// Seconds east of UTC for the clock times; set once at startup.
    utc_offset_s: i32 = 0,
    output: Output = .{},

    pub fn deinit(self: *Log, gpa: std.mem.Allocator) void {
        gpa.free(self.output.text);
        self.output = .{};
    }

    /// Appends a line, dropping the oldest when full. Longer text is cut at
    /// a UTF-8 boundary.
    pub fn add(self: *Log, at_ms: i64, kind: Kind, comptime fmt: []const u8, args: anytype) void {
        var buffer: [text_capacity]u8 = undefined;
        const written = std.fmt.bufPrint(&buffer, fmt, args) catch cut: {
            // bufPrint fills the buffer before it fails; keep that prefix.
            break :cut buffer[0..text_capacity];
        };
        const len = utf8Prefix(written, text_capacity);
        const index = (self.first + self.count) % max_entries;
        if (self.count == max_entries) {
            self.first = (self.first + 1) % max_entries;
        } else self.count += 1;
        self.entries[index] = .{ .at_ms = at_ms, .kind = kind, .len = @intCast(len), .bytes = undefined };
        @memcpy(self.entries[index].bytes[0..len], written[0..len]);
    }

    /// The entry `index` places after the oldest.
    pub fn at(self: *const Log, index: usize) *const Entry {
        return &self.entries[(self.first + index) % max_entries];
    }

    /// Replaces the compiler output with the tail of `stderr` and `stdout`.
    pub fn setOutput(self: *Log, gpa: std.mem.Allocator, stderr: []const u8, stdout: []const u8, summary: Output) !void {
        const separator = if (stderr.len != 0 and stdout.len != 0) "\n" else "";
        const total = stderr.len + separator.len + stdout.len;
        const keep = @min(total, output_capacity);
        const text = try gpa.alloc(u8, keep);
        var full: std.ArrayList(u8) = .initBuffer(text);
        // Copy the last `keep` bytes of stderr ++ separator ++ stdout.
        var skip = total - keep;
        for ([_][]const u8{ stderr, separator, stdout }) |part| {
            const dropped = @min(skip, part.len);
            skip -= dropped;
            full.appendSliceAssumeCapacity(part[dropped..]);
        }
        // Begin at a character boundary.
        const start = utf8Start(full.items);
        const owned = if (start == 0) text else trimmed: {
            defer gpa.free(text);
            break :trimmed try gpa.dupe(u8, text[start..]);
        };
        gpa.free(self.output.text);
        var output = summary;
        output.truncated = total > keep;
        output.errors = countErrors(owned);
        output.text = owned;
        self.output = output;
    }

    /// `HH:MM:SS` of `at_ms` in local time.
    pub fn clock(self: *const Log, buffer: *[8]u8, at_ms: i64) []const u8 {
        const local = @divFloor(at_ms, std.time.ms_per_s) + self.utc_offset_s;
        const day: u64 = @intCast(@mod(local, std.time.s_per_day));
        _ = std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ day / 3600, day / 60 % 60, day % 60 }) catch unreachable;
        return buffer;
    }

    /// The timeline, one `HH:MM:SS  text` line per entry.
    pub fn writeTimeline(self: *const Log, writer: *std.Io.Writer) !void {
        for (0..self.count) |index| {
            const entry = self.at(index);
            var time: [8]u8 = undefined;
            try writer.print("{s}  {s}\n", .{ self.clock(&time, entry.at_ms), entry.text() });
        }
    }

    /// The headline, the timeline and the compiler output, for the clipboard.
    pub fn writeDetails(self: *const Log, writer: *std.Io.Writer, headline: []const u8, detail: []const u8) !void {
        try writer.print("{s}\n", .{headline});
        if (detail.len != 0) try writer.print("{s}\n", .{detail});
        try writer.writeAll("\nActivity\n");
        try self.writeTimeline(writer);
        try writer.writeAll("\nCompiler output\n");
        if (self.output.text.len == 0) {
            try writer.writeAll("No build has finished in this session.\n");
            return;
        }
        var time: [8]u8 = undefined;
        try writeOutputSummary(self, writer, &time);
        try writer.writeAll("\n");
        try writer.writeAll(self.output.text);
        if (!std.mem.endsWith(u8, self.output.text, "\n")) try writer.writeAll("\n");
    }

    /// One line about the last build: when, why, and how it ended.
    pub fn writeOutputSummary(self: *const Log, writer: *std.Io.Writer, time: *[8]u8) !void {
        const output = self.output;
        try writer.print("{s} · {s} · ", .{ self.clock(time, output.at_ms), output.trigger.describe() });
        if (output.succeeded) {
            try writer.print("built in {f}", .{seconds(output.duration_ms)});
        } else {
            try writer.print("failed after {f}", .{seconds(output.duration_ms)});
            if (output.errors.count != 0) try writer.print(" · {f}", .{output.errors});
        }
        if (output.truncated) try writer.writeAll(" · last 64 KB");
    }
};

/// Formats milliseconds as `1.2 s`, `34 s` or `2 min 5 s`.
pub fn seconds(ms: u64) Seconds {
    return .{ .ms = ms };
}

pub const Seconds = struct {
    ms: u64,

    pub fn format(self: Seconds, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.ms < 10_000) return writer.print("{d}.{d} s", .{ self.ms / 1000, self.ms / 100 % 10 });
        const whole = (self.ms + 500) / 1000;
        if (whole < 60) return writer.print("{d} s", .{whole});
        return writer.print("{d} min {d} s", .{ whole / 60, whole % 60 });
    }
};

/// Formats a byte count as `64.5 KB`.
pub fn kilobytes(bytes: u64) Kilobytes {
    return .{ .bytes = bytes };
}

pub const Kilobytes = struct {
    bytes: u64,

    pub fn format(self: Kilobytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const tenths = (self.bytes * 10 + 512) / 1024;
        return writer.print("{d}.{d} KB", .{ tenths / 10, tenths % 10 });
    }
};

/// Counts compiler errors that name a source location, `path:line:column:
/// error:`; summary lines such as `error: the following command failed`
/// are not counted.
pub fn countErrors(text: []const u8) Errors {
    var result: Errors = .{ .keymap = true };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const marker = std.mem.indexOf(u8, line, ": error: ") orelse continue;
        const location = line[0..marker];
        // `<path>:<line>:<column>`
        const column_colon = std.mem.lastIndexOfScalar(u8, location, ':') orelse continue;
        const line_colon = std.mem.lastIndexOfScalar(u8, location[0..column_colon], ':') orelse continue;
        if (!allDigits(location[column_colon + 1 ..]) or !allDigits(location[line_colon + 1 .. column_colon])) continue;
        const path = location[0..line_colon];
        if (path.len == 0) continue;
        result.count += 1;
        if (!std.mem.eql(u8, std.fs.path.basename(path), "keymap.zig")) result.keymap = false;
    }
    if (result.count == 0) result.keymap = false;
    return result;
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The longest prefix of `text` of at most `limit` bytes that ends at a
/// character boundary.
fn utf8Prefix(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var end = limit;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

/// The first character boundary of `text`, skipping a cut-off sequence.
fn utf8Start(text: []const u8) usize {
    var start: usize = 0;
    while (start < text.len and start < 4 and text[start] & 0xC0 == 0x80) start += 1;
    return start;
}

const testing = std.testing;

test "the timeline keeps the newest entries with local clock times" {
    var log: Log = .{ .utc_offset_s = 3600 };
    // 18:42:40 UTC, 19:42:40 at UTC+1.
    const start: i64 = (18 * 3600 + 42 * 60 + 40) * 1000;
    log.add(start, .info, "App started · Zigmkay {s}", .{"0.3.0"});
    try testing.expectEqual(@as(usize, 1), log.count);
    var time: [8]u8 = undefined;
    try testing.expectEqualStrings("19:42:40", log.clock(&time, log.at(0).at_ms));
    try testing.expectEqualStrings("App started · Zigmkay 0.3.0", log.at(0).text());
    for (0..max_entries + 5) |index| log.add(start + @as(i64, @intCast(index)), .ok, "entry {d}", .{index});
    try testing.expectEqual(@as(usize, max_entries), log.count);
    try testing.expectEqualStrings("entry 5", log.at(0).text());
    var last: [16]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&last, "entry {d}", .{max_entries + 4}), log.at(max_entries - 1).text());
}

test "long lines are cut at a character boundary" {
    var log: Log = .{};
    var long: [200]u8 = undefined;
    for (0..100) |index| long[index * 2 ..][0..2].* = "ä".*;
    log.add(0, .warn, "{s}", .{&long});
    const text = log.at(0).text();
    try testing.expect(text.len <= text_capacity);
    try testing.expect(std.unicode.utf8ValidateSlice(text));
    try testing.expectEqual(@as(usize, 0), text.len % 2);
}

test "located compiler errors are counted and attributed to the keymap" {
    const keymap_only =
        \\/cache/exports/v2/ab12/keymap.zig:12:5: error: expected ',' after field
        \\    .{ .tap = .a }
        \\    ^
        \\error: the following command failed with 1 compilation errors:
    ;
    try testing.expectEqual(Errors{ .count = 1, .keymap = true }, countErrors(keymap_only));
    const mixed = keymap_only ++ "\n/zig/lib/std/fmt.zig:1:2: error: other\n";
    try testing.expectEqual(Errors{ .count = 2, .keymap = false }, countErrors(mixed));
    try testing.expectEqual(Errors{}, countErrors("error: unable to spawn zig: FileNotFound\n"));
    try testing.expectEqual(Errors{}, countErrors(""));
}

test "the compiler output keeps the bounded tail of stderr and stdout" {
    const gpa = testing.allocator;
    var log: Log = .{};
    defer log.deinit(gpa);
    try log.setOutput(gpa, "keymap.zig:1:1: error: bad", "done", .{ .succeeded = false, .duration_ms = 3100 });
    try testing.expectEqualStrings("keymap.zig:1:1: error: bad\ndone", log.output.text);
    try testing.expectEqual(@as(u32, 1), log.output.errors.count);
    try testing.expect(!log.output.truncated);

    const big = try gpa.alloc(u8, output_capacity + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    big[big.len - 1] = 'y';
    try log.setOutput(gpa, big, "", .{});
    try testing.expectEqual(@as(usize, output_capacity), log.output.text.len);
    try testing.expect(log.output.truncated);
    try testing.expectEqual(@as(u8, 'y'), log.output.text[log.output.text.len - 1]);

    // A tail that starts inside a multi-byte character drops its rest.
    const umlauts = try gpa.alloc(u8, output_capacity + 1);
    defer gpa.free(umlauts);
    for (0..umlauts.len / 2) |index| umlauts[index * 2 ..][0..2].* = "ä".*;
    umlauts[umlauts.len - 1] = '!';
    try log.setOutput(gpa, umlauts, "", .{});
    try testing.expect(std.unicode.utf8ValidateSlice(log.output.text));
}

test "details hold the timeline and the compiler output for the clipboard" {
    const gpa = testing.allocator;
    var log: Log = .{};
    defer log.deinit(gpa);
    log.add(1000, .info, "Build started · {s}", .{Trigger.auto_build.describe()});
    try log.setOutput(gpa, "keymap.zig:3:1: error: bad", "", .{ .at_ms = 2000, .trigger = .auto_build, .succeeded = false, .duration_ms = 1200 });
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try log.writeDetails(&writer, "Build failed", "1 error in the keymap");
    try testing.expectEqualStrings(
        \\Build failed
        \\1 error in the keymap
        \\
        \\Activity
        \\00:00:01  Build started · Auto-build after a change
        \\
        \\Compiler output
        \\00:00:02 · Auto-build after a change · failed after 1.2 s · 1 error in the keymap
        \\keymap.zig:3:1: error: bad
        \\
    , writer.buffered());
}

test "durations and sizes read naturally" {
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("1.2 s", try std.fmt.bufPrint(&buffer, "{f}", .{seconds(1234)}));
    try testing.expectEqualStrings("34 s", try std.fmt.bufPrint(&buffer, "{f}", .{seconds(33_700)}));
    try testing.expectEqualStrings("1 min 12 s", try std.fmt.bufPrint(&buffer, "{f}", .{seconds(72_000)}));
    try testing.expectEqualStrings("64.5 KB", try std.fmt.bufPrint(&buffer, "{f}", .{kilobytes(66_048)}));
}
