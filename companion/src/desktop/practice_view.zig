//! Presentation rules shared by the animated tutor and native acceptance checks.
const std = @import("std");
const Session = @import("practice.zig").Session;
pub const Range = struct { start: usize, end: usize };

pub fn whitespace(cp: u21) bool {
    return cp == ' ' or cp == '\n' or cp == '\t';
}

/// Keep a mistake in view until it is corrected, rather than moving past it.
pub fn focus(session: *const Session) usize {
    for (session.typed[0..@min(session.len, session.reference_len)], 0..) |cp, i| {
        if (cp != session.reference[i]) return i;
    }
    return @min(session.len, session.reference_len);
}

pub fn word(reference: []const u21, index: usize) Range {
    if (index >= reference.len) return .{ .start = reference.len, .end = reference.len };
    if (whitespace(reference[index])) return .{ .start = index, .end = index + 1 };
    var start = index;
    var end = index + 1;
    while (start > 0 and !whitespace(reference[start - 1])) start -= 1;
    while (end < reference.len and !whitespace(reference[end])) end += 1;
    return .{ .start = start, .end = end };
}

/// Word-wrap English; preserve Zig line structure, wrapping only long lines.
pub fn lines(reference: []const u21, columns: usize, buffer: []Range) []Range {
    var count: usize = 0;
    var start: usize = 0;
    while (start < reference.len and count < buffer.len) {
        var end = start;
        while (end < reference.len and reference[end] != '\n' and end - start < @max(1, columns)) end += 1;
        if (end < reference.len and reference[end] != '\n') {
            var split = end;
            while (split > start and reference[split - 1] != ' ') split -= 1;
            if (split > start) end = split;
        } else if (end < reference.len) end += 1;
        buffer[count] = .{ .start = start, .end = end };
        count += 1;
        start = end;
    }
    return buffer[0..count];
}

pub fn currentLine(ranges: []const Range, index: usize) usize {
    for (ranges, 0..) |range, i| if (index < range.end) return i;
    return ranges.len -| 1;
}

pub fn glyph(cp: u21, explicit_space: bool, buffer: *[4]u8) []const u8 {
    return switch (cp) {
        ' ' => if (explicit_space) "␣" else " ",
        '\n' => "↵",
        '\t' => "⇥",
        else => buffer[0 .. std.unicode.utf8Encode(cp, buffer) catch 0],
    };
}

test "word focus follows Unicode, whitespace, mistakes and correction" {
    var s: Session = .{};
    try s.load("The café.\n", .os);
    try std.testing.expectEqualDeep(
        Range{ .start = 0, .end = 3 },
        word(s.reference[0..s.reference_len], focus(&s)),
    );
    try s.insert("Thx", 0, false);
    try std.testing.expectEqual(@as(usize, 2), focus(&s));
    s.backspace();
    try s.insert("e ", 10, false);
    try std.testing.expectEqualDeep(
        Range{ .start = 4, .end = 9 },
        word(s.reference[0..s.reference_len], focus(&s)),
    );
    try s.insert("café.", 20, false);
    try std.testing.expectEqualDeep(
        Range{ .start = 9, .end = 10 },
        word(s.reference[0..s.reference_len], focus(&s)),
    );
}

test "wrapped context covers every character including indentation and newline" {
    var s: Session = .{};
    try s.load("a long word\n    return value;\n", .os);
    var buffer: [32]Range = undefined;
    const result = lines(s.reference[0..s.reference_len], 8, &buffer);
    var next: usize = 0;
    for (result) |range| {
        try std.testing.expectEqual(next, range.start);
        try std.testing.expect(range.end > range.start);
        next = range.end;
    }
    try std.testing.expectEqual(s.reference_len, next);
    try std.testing.expectEqual(@as(usize, 1), currentLine(result, 7));
}
