//! The multi-line text field of Test layout: a small UTF-8 editor with a
//! cursor, a selection, soft-wrapped rows, undo and redo. It knows nothing
//! about dvui; the view hands it keys and the width of its rows.
//!
//! Positions are byte offsets on codepoint boundaries. Lines end at `\n`;
//! rows are the soft-wrapped pieces of a line the view draws. Columns count
//! codepoints, each one cell of the monospace view.
const std = @import("std");

/// The most text the field holds; typing and pasting stop there.
pub const capacity = 8 * 1024;
/// Undo steps kept; older ones are forgotten first.
pub const max_edits = 100;
/// Bytes of removed and inserted text the undo steps may keep, enough to undo
/// clearing a full field.
const pool_capacity = 2 * capacity;

pub const Platform = enum {
    /// ⌘ edits and jumps to line ends, ⌥ jumps words.
    mac,
    /// Ctrl edits and jumps words, Home/End and Ctrl+Home/End jump.
    pc,

    pub fn native() Platform {
        return if (@import("builtin").os.tag.isDarwin()) .mac else .pc;
    }
};

pub const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
    command: bool = false,

    pub fn any(self: Mods) bool {
        return self.shift or self.alt or self.control or self.command;
    }
};

/// The keys the field tells apart; others keep their name for the telemetry.
pub const Code = enum {
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    backspace,
    delete,
    enter,
    tab,
    escape,
    a,
    c,
    v,
    x,
    y,
    z,
    insert,
    other,
};

pub const Key = struct {
    code: Code,
    mods: Mods = .{},
};

pub const Op = enum {
    char_left,
    char_right,
    word_left,
    word_right,
    line_start,
    line_end,
    row_up,
    row_down,
    page_up,
    page_down,
    text_start,
    text_end,
    backspace,
    delete,
    delete_word_left,
    delete_word_right,
    delete_to_line_start,
    delete_to_line_end,
    newline,
    indent,
    select_all,
    copy,
    cut,
    paste,
    undo,
    redo,
    release,

    pub fn moves(self: Op) bool {
        return @backingInt(self) <= @backingInt(Op.text_end);
    }
};

pub const Command = struct {
    op: Op,
    /// Moves extend the selection instead of collapsing it.
    select: bool = false,

    /// A short name for the telemetry, such as "select word left".
    pub fn label(self: Command) []const u8 {
        return switch (self.op) {
            .char_left => if (self.select) "select left" else "left",
            .char_right => if (self.select) "select right" else "right",
            .word_left => if (self.select) "select word left" else "word left",
            .word_right => if (self.select) "select word right" else "word right",
            .line_start => if (self.select) "select to line start" else "line start",
            .line_end => if (self.select) "select to line end" else "line end",
            .row_up => if (self.select) "select up" else "up",
            .row_down => if (self.select) "select down" else "down",
            .page_up => if (self.select) "select page up" else "page up",
            .page_down => if (self.select) "select page down" else "page down",
            .text_start => if (self.select) "select to text start" else "text start",
            .text_end => if (self.select) "select to text end" else "text end",
            .backspace => "delete left",
            .delete => "delete right",
            .delete_word_left => "delete word left",
            .delete_word_right => "delete word right",
            .delete_to_line_start => "delete to line start",
            .delete_to_line_end => "delete to line end",
            .newline => "new line",
            .indent => "four spaces",
            .select_all => "select all",
            .copy => "copy",
            .cut => "cut",
            .paste => "paste",
            .undo => "undo",
            .redo => "redo",
            .release => "leave the field",
        };
    }
};

/// The editor command of `key`, or null for a key the field only shows.
pub fn commandFor(key: Key, platform: Platform) ?Command {
    const m = key.mods;
    const shift = m.shift;
    // The modifier that edits and jumps furthest: ⌘ on macOS, Ctrl elsewhere.
    const primary = switch (platform) {
        .mac => m.command and !m.control,
        .pc => m.control and !m.command,
    };
    const plain = !m.alt and !m.control and !m.command;
    return switch (key.code) {
        .left, .right => {
            const left = key.code == .left;
            const op: Op = switch (platform) {
                .mac => if (m.command and !m.alt and !m.control)
                    (if (left) .line_start else .line_end)
                else if (m.alt and !m.command and !m.control)
                    (if (left) .word_left else .word_right)
                else if (plain) (if (left) .char_left else .char_right) else return null,
                .pc => if (m.control and !m.alt and !m.command)
                    (if (left) .word_left else .word_right)
                else if (plain) (if (left) .char_left else .char_right) else return null,
            };
            return .{ .op = op, .select = shift };
        },
        .up, .down => {
            const up = key.code == .up;
            if (platform == .mac and m.command and !m.control)
                return .{ .op = if (up) .text_start else .text_end, .select = shift };
            if (m.command or m.control) return null;
            return .{ .op = if (up) .row_up else .row_down, .select = shift };
        },
        .home, .end => {
            const home = key.code == .home;
            if (primary) return .{ .op = if (home) .text_start else .text_end, .select = shift };
            if (m.alt or m.control or m.command) return null;
            return .{ .op = if (home) .line_start else .line_end, .select = shift };
        },
        .page_up, .page_down => {
            if (m.alt or m.control or m.command) return null;
            return .{ .op = if (key.code == .page_up) .page_up else .page_down, .select = shift };
        },
        .backspace => switch (platform) {
            .mac => if (m.command and !m.alt and !m.control)
                .{ .op = .delete_to_line_start }
            else if (m.alt and !m.command and !m.control)
                .{ .op = .delete_word_left }
            else if (plain) .{ .op = .backspace } else null,
            .pc => if (m.control and shift and !m.alt)
                .{ .op = .delete_to_line_start }
            else if (m.control and !m.alt)
                .{ .op = .delete_word_left }
            else if (plain) .{ .op = .backspace } else null,
        },
        .delete => switch (platform) {
            .mac => if (m.command and !m.alt and !m.control)
                .{ .op = .delete_to_line_end }
            else if (m.alt and !m.command and !m.control)
                .{ .op = .delete_word_right }
            else if (plain) .{ .op = .delete } else null,
            .pc => if (m.control and shift and !m.alt)
                .{ .op = .delete_to_line_end }
            else if (m.control and !m.alt)
                .{ .op = .delete_word_right }
            else if (plain and shift)
                .{ .op = .cut }
            else if (plain) .{ .op = .delete } else null,
        },
        .enter => if (plain) .{ .op = .newline } else null,
        .tab => if (!m.any()) .{ .op = .indent } else null,
        .escape => if (!m.any()) .{ .op = .release } else null,
        .a => if (primary and !shift and !m.alt) .{ .op = .select_all } else null,
        .c => if (primary and !shift and !m.alt) .{ .op = .copy } else null,
        .x => if (primary and !shift and !m.alt) .{ .op = .cut } else null,
        .v => if (primary and !shift and !m.alt) .{ .op = .paste } else null,
        .z => if (primary and !m.alt) .{ .op = if (shift) .redo else .undo } else null,
        .y => if (platform == .pc and primary and !shift and !m.alt) .{ .op = .redo } else null,
        .insert => if (platform == .pc and m.control and !shift and !m.alt)
            .{ .op = .copy }
        else if (platform == .pc and shift and !m.control and !m.alt)
            .{ .op = .paste }
        else
            null,
        .other => null,
    };
}

/// Writes `key` as the telemetry shows it, such as "⌥⇧←" on macOS or
/// "Ctrl+Shift+Left" elsewhere. `name` names keys the field does not know.
pub fn comboText(buffer: []u8, key: Key, name: []const u8, platform: Platform) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const m = key.mods;
    const glyph: []const u8 = switch (key.code) {
        .left => if (platform == .mac) "←" else "Left",
        .right => if (platform == .mac) "→" else "Right",
        .up => if (platform == .mac) "↑" else "Up",
        .down => if (platform == .mac) "↓" else "Down",
        .home => "Home",
        .end => "End",
        .page_up => "Page Up",
        .page_down => "Page Down",
        .backspace => if (platform == .mac) "⌫" else "Backspace",
        .delete => if (platform == .mac) "⌦" else "Delete",
        .enter => if (platform == .mac) "↩" else "Enter",
        .tab => if (platform == .mac) "⇥" else "Tab",
        .escape => "Esc",
        .insert => "Insert",
        .a, .c, .v, .x, .y, .z, .other => name,
    };
    switch (platform) {
        // Apple's order: Control, Option, Shift, Command.
        .mac => {
            if (m.control) writer.writeAll("⌃") catch {};
            if (m.alt) writer.writeAll("⌥") catch {};
            if (m.shift) writer.writeAll("⇧") catch {};
            if (m.command) writer.writeAll("⌘") catch {};
            writer.writeAll(glyph) catch {};
        },
        .pc => {
            if (m.control) writer.writeAll("Ctrl+") catch {};
            if (m.command) writer.writeAll("Win+") catch {};
            if (m.alt) writer.writeAll("Alt+") catch {};
            if (m.shift) writer.writeAll("Shift+") catch {};
            writer.writeAll(glyph) catch {};
        },
    }
    return writer.buffered();
}

/// One soft-wrapped piece of a line: bytes `[start, end)`. A row that a wrap
/// ends continues at `end`; the last row of a line ends before its `\n`.
pub const Row = struct {
    start: usize,
    end: usize,
    /// The line goes on in the next row.
    wrapped: bool,
};

/// Splits text into rows of at most `columns` codepoints, breaking after the
/// last space that fits, or inside a word longer than a row.
pub const Rows = struct {
    text: []const u8,
    columns: usize,
    at: usize = 0,
    done: bool = false,

    pub fn init(text: []const u8, columns: usize) Rows {
        return .{ .text = text, .columns = @max(1, columns) };
    }

    pub fn next(self: *Rows) ?Row {
        if (self.done) return null;
        const start = self.at;
        var end = start;
        var count: usize = 0;
        var last_break: ?usize = null;
        while (end < self.text.len and self.text[end] != '\n') {
            if (count == self.columns) {
                const split = last_break orelse end;
                const cut = if (split > start) split else end;
                self.at = cut;
                return .{ .start = start, .end = cut, .wrapped = true };
            }
            const step = codepointLen(self.text, end);
            if (self.text[end] == ' ') last_break = end + step;
            end += step;
            count += 1;
        }
        if (end < self.text.len) {
            self.at = end + 1;
        } else {
            self.done = true;
        }
        return .{ .start = start, .end = end, .wrapped = false };
    }
};

fn codepointLen(text: []const u8, at: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
    return @min(n, text.len - at);
}

/// The number of codepoints in `bytes`.
pub fn codepoints(bytes: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) : (count += 1) at += codepointLen(bytes, at);
    return count;
}

/// The byte offset `column` codepoints into `bytes`, or its end.
fn advance(bytes: []const u8, column: usize) usize {
    var at: usize = 0;
    var count: usize = 0;
    while (at < bytes.len and count < column) : (count += 1) at += codepointLen(bytes, at);
    return at;
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}

/// Where the cursor is, 1-based, with the column in codepoints.
pub const LineColumn = struct { line: usize, column: usize };

/// Where the view puts a position: its row and column there.
pub const Place = struct { row: usize, column: usize };

const EditKind = enum { typing, deleting_left, deleting_right, other };

const Edit = struct {
    at: usize,
    removed_off: usize,
    removed_len: usize,
    inserted_off: usize,
    inserted_len: usize,
    cursor_before: usize,
    anchor_before: usize,
    cursor_after: usize,
    kind: EditKind,
};

pub const Editor = struct {
    buffer: [capacity]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    /// The other end of the selection; equal to `cursor` when none.
    anchor: usize = 0,
    /// The column vertical moves aim for, kept across short rows.
    goal_column: ?usize = null,
    /// The first row the view shows.
    top_row: usize = 0,
    /// The last insertion did not fit and was cut short.
    full: bool = false,

    edits: [max_edits]Edit = undefined,
    edit_len: usize = 0,
    /// Edits applied; the ones after it can be redone.
    done: usize = 0,
    pool: [pool_capacity]u8 = undefined,
    pool_len: usize = 0,
    /// The next typing or deletion may join the latest undo step.
    joinable: bool = false,

    pub fn text(self: *const Editor) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn selectionStart(self: *const Editor) usize {
        return @min(self.cursor, self.anchor);
    }

    pub fn selectionEnd(self: *const Editor) usize {
        return @max(self.cursor, self.anchor);
    }

    pub fn hasSelection(self: *const Editor) bool {
        return self.cursor != self.anchor;
    }

    pub fn selected(self: *const Editor) []const u8 {
        return self.buffer[self.selectionStart()..self.selectionEnd()];
    }

    pub fn lineColumn(self: *const Editor) LineColumn {
        const before = self.buffer[0..self.cursor];
        const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |nl| nl + 1 else 0;
        return .{
            .line = std.mem.count(u8, before, "\n") + 1,
            .column = codepoints(before[line_start..]) + 1,
        };
    }

    /// Replaces the text, forgetting the history; for fixtures.
    pub fn setText(self: *Editor, value: []const u8) void {
        self.* = .{};
        _ = self.insert(value);
        self.edit_len = 0;
        self.done = 0;
        self.pool_len = 0;
        self.joinable = false;
    }

    /// Selects `[anchor, cursor)` (byte offsets); for fixtures.
    pub fn select(self: *Editor, anchor: usize, cursor: usize) void {
        self.anchor = self.boundary(@min(anchor, self.len));
        self.cursor = self.boundary(@min(cursor, self.len));
        self.goal_column = null;
        self.joinable = false;
    }

    /// Empties the field; undo brings the text back.
    pub fn clear(self: *Editor) void {
        if (self.len == 0) return;
        self.replace(0, self.len, "", .other);
        self.top_row = 0;
        self.full = false;
    }

    /// Types `value` over the selection. Returns false when the field is full
    /// and the text was cut short or dropped.
    pub fn insert(self: *Editor, value: []const u8) bool {
        var clean: [capacity]u8 = undefined;
        const room = capacity - (self.len - (self.selectionEnd() - self.selectionStart()));
        const sanitized = sanitize(&clean, value, room);
        self.full = sanitized.cut;
        if (sanitized.text.len == 0) return !sanitized.cut;
        const single = codepoints(sanitized.text) == 1 and sanitized.text[0] != '\n';
        self.replace(self.selectionStart(), self.selectionEnd(), sanitized.text, if (single) .typing else .other);
        return !sanitized.cut;
    }

    /// Runs `command` in a view of `view` cells. Copy and cut leave the
    /// clipboard to the caller, who reads `selected()` first; paste types
    /// `clipboard`.
    pub fn run(self: *Editor, command: Command, view: View, clipboard: []const u8) void {
        const op = command.op;
        if (op != .row_up and op != .row_down and op != .page_up and op != .page_down) self.goal_column = null;
        if (op.moves()) {
            self.joinable = false;
            self.move(op, command.select, view);
            self.reveal(view);
            return;
        }
        switch (op) {
            .backspace => self.deleteLeft(.char),
            .delete => self.deleteRight(.char),
            .delete_word_left => self.deleteLeft(.word),
            .delete_word_right => self.deleteRight(.word),
            .delete_to_line_start => self.deleteLeft(.line),
            .delete_to_line_end => self.deleteRight(.line),
            .newline => _ = self.insert("\n"),
            .indent => _ = self.insert("    "),
            .select_all => {
                self.joinable = false;
                self.anchor = 0;
                self.cursor = self.len;
            },
            .copy => self.joinable = false,
            .cut => {
                self.joinable = false;
                if (self.hasSelection()) self.replace(self.selectionStart(), self.selectionEnd(), "", .other);
            },
            .paste => {
                self.joinable = false;
                _ = self.insert(clipboard);
                self.joinable = false;
            },
            .undo => self.undo(),
            .redo => self.redo(),
            .release => {},
            else => unreachable,
        }
        self.reveal(view);
    }

    /// The width and height of the view in cells.
    pub const View = struct {
        columns: usize,
        rows: usize,
    };

    const Reach = enum { char, word, line };

    fn deleteLeft(self: *Editor, reach: Reach) void {
        if (self.hasSelection()) return self.replace(self.selectionStart(), self.selectionEnd(), "", .other);
        if (self.cursor == 0) return;
        const from = switch (reach) {
            .char => self.previous(self.cursor),
            .word => self.wordLeft(self.cursor),
            .line => line: {
                const start = self.lineStart(self.cursor);
                break :line if (start == self.cursor) self.cursor - 1 else start;
            },
        };
        self.replace(from, self.cursor, "", if (reach == .char) .deleting_left else .other);
    }

    fn deleteRight(self: *Editor, reach: Reach) void {
        if (self.hasSelection()) return self.replace(self.selectionStart(), self.selectionEnd(), "", .other);
        if (self.cursor == self.len) return;
        const to = switch (reach) {
            .char => self.following(self.cursor),
            .word => self.wordRight(self.cursor),
            .line => line: {
                const end = self.lineEnd(self.cursor);
                break :line if (end == self.cursor) self.cursor + 1 else end;
            },
        };
        self.replace(self.cursor, to, "", if (reach == .char) .deleting_right else .other);
    }

    fn move(self: *Editor, op: Op, extend: bool, view: View) void {
        const collapsing = !extend and self.hasSelection();
        const target: usize = switch (op) {
            .char_left => if (collapsing) self.selectionStart() else self.previous(self.cursor),
            .char_right => if (collapsing) self.selectionEnd() else self.following(self.cursor),
            .word_left => self.wordLeft(self.cursor),
            .word_right => self.wordRight(self.cursor),
            .line_start => self.lineStart(self.cursor),
            .line_end => self.lineEnd(self.cursor),
            .text_start => 0,
            .text_end => self.len,
            .row_up => self.vertical(view.columns, -1),
            .row_down => self.vertical(view.columns, 1),
            .page_up => self.vertical(view.columns, -@as(isize, @intCast(@max(1, view.rows -| 1)))),
            .page_down => self.vertical(view.columns, @intCast(@max(1, view.rows -| 1))),
            else => unreachable,
        };
        self.cursor = target;
        if (!extend) self.anchor = target;
    }

    /// The position `delta` rows away at the goal column. Past the first or
    /// last row it goes to the text's start or end.
    fn vertical(self: *Editor, columns: usize, delta: isize) usize {
        const here = self.place(self.cursor, columns);
        const goal = self.goal_column orelse here.column;
        self.goal_column = goal;
        if (delta < 0 and here.row < @abs(delta)) return if (here.row == 0) 0 else self.positionAt(0, goal, columns);
        const row: usize = if (delta < 0) here.row - @abs(delta) else here.row + @as(usize, @intCast(delta));
        if (delta > 0 and row >= self.rowCount(columns)) {
            const last = self.rowCount(columns) - 1;
            return if (here.row == last) self.len else self.positionAt(last, goal, columns);
        }
        return self.positionAt(row, goal, columns);
    }

    /// The row and column where the view draws position `at`.
    pub fn place(self: *const Editor, at: usize, columns: usize) Place {
        var rows = Rows.init(self.text(), columns);
        var index: usize = 0;
        var last: Place = .{ .row = 0, .column = 0 };
        while (rows.next()) |row| : (index += 1) {
            if (at < row.start) break;
            last = .{ .row = index, .column = codepoints(self.buffer[row.start..@min(at, row.end)]) };
            // A wrapped row's end is the next row's start.
            if (at < row.end or (at == row.end and !row.wrapped)) return last;
        }
        return last;
    }

    /// The position at `column` of `row`, kept before a wrapped row's break.
    pub fn positionAt(self: *const Editor, row_index: usize, column: usize, columns: usize) usize {
        var rows = Rows.init(self.text(), columns);
        var index: usize = 0;
        var last: Row = .{ .start = 0, .end = 0, .wrapped = false };
        while (rows.next()) |row| : (index += 1) {
            last = row;
            if (index == row_index) break;
        }
        const bytes = self.buffer[last.start..last.end];
        var at = last.start + advance(bytes, column);
        if (last.wrapped and at == last.end and at > last.start) at = self.previous(at);
        return at;
    }

    pub fn rowCount(self: *const Editor, columns: usize) usize {
        var rows = Rows.init(self.text(), columns);
        var count: usize = 0;
        while (rows.next()) |_| count += 1;
        return count;
    }

    /// Scrolls so the cursor's row is in view.
    pub fn reveal(self: *Editor, view: View) void {
        const visible = @max(1, view.rows);
        const row = self.place(self.cursor, view.columns).row;
        if (row < self.top_row) self.top_row = row;
        if (row >= self.top_row + visible) self.top_row = row + 1 - visible;
        self.clampScroll(view);
    }

    /// Scrolls by `delta` rows, as the mouse wheel does.
    pub fn scroll(self: *Editor, delta: isize, view: View) void {
        if (delta < 0) self.top_row -|= @abs(delta) else self.top_row += @intCast(delta);
        self.clampScroll(view);
    }

    fn clampScroll(self: *Editor, view: View) void {
        const count = self.rowCount(view.columns);
        const visible = @max(1, view.rows);
        self.top_row = @min(self.top_row, count -| visible);
    }

    /// Puts the cursor where the pointer is, extending the selection when
    /// `extend` is set.
    pub fn pointAt(self: *Editor, row: usize, column: usize, columns: usize, extend: bool) void {
        self.joinable = false;
        self.goal_column = null;
        const count = self.rowCount(columns);
        self.cursor = if (row >= count) self.len else self.positionAt(row, column, columns);
        if (!extend) self.anchor = self.cursor;
    }

    fn previous(self: *const Editor, at: usize) usize {
        if (at == 0) return 0;
        var p = at - 1;
        while (p > 0 and (self.buffer[p] & 0xC0) == 0x80) p -= 1;
        return p;
    }

    fn following(self: *const Editor, at: usize) usize {
        if (at >= self.len) return self.len;
        return at + codepointLen(self.text(), at);
    }

    /// Moves `at` back to a codepoint boundary.
    fn boundary(self: *const Editor, at: usize) usize {
        var p = at;
        while (p > 0 and p < self.len and (self.buffer[p] & 0xC0) == 0x80) p -= 1;
        return p;
    }

    fn wordLeft(self: *const Editor, at: usize) usize {
        var p = at;
        while (p > 0 and !isWord(self.buffer[p - 1])) p = self.previous(p);
        while (p > 0 and isWord(self.buffer[p - 1])) p = self.previous(p);
        return p;
    }

    fn wordRight(self: *const Editor, at: usize) usize {
        var p = at;
        while (p < self.len and !isWord(self.buffer[p])) p = self.following(p);
        while (p < self.len and isWord(self.buffer[p])) p = self.following(p);
        return p;
    }

    fn lineStart(self: *const Editor, at: usize) usize {
        return if (std.mem.lastIndexOfScalar(u8, self.buffer[0..at], '\n')) |nl| nl + 1 else 0;
    }

    fn lineEnd(self: *const Editor, at: usize) usize {
        return if (std.mem.indexOfScalarPos(u8, self.text(), at, '\n')) |nl| nl else self.len;
    }

    /// Replaces `[start, end)` with `value` and records the undo step.
    fn replace(self: *Editor, start: usize, end: usize, value: []const u8, kind: EditKind) void {
        std.debug.assert(self.len - (end - start) + value.len <= capacity);
        self.record(start, end, value, kind);
        self.splice(start, end, value);
        self.cursor = start + value.len;
        self.anchor = self.cursor;
        self.joinable = kind != .other;
    }

    fn splice(self: *Editor, start: usize, end: usize, value: []const u8) void {
        const tail = self.len - end;
        const new_end = start + value.len;
        if (new_end < end) {
            std.mem.copyForwards(u8, self.buffer[new_end..][0..tail], self.buffer[end..][0..tail]);
        } else if (new_end > end) {
            std.mem.copyBackwards(u8, self.buffer[new_end..][0..tail], self.buffer[end..][0..tail]);
        }
        @memcpy(self.buffer[start..new_end], value);
        self.len = self.len - (end - start) + value.len;
    }

    fn record(self: *Editor, start: usize, end: usize, value: []const u8, kind: EditKind) void {
        const removed = self.buffer[start..end];
        // Redo is gone once something new happens.
        if (self.done < self.edit_len) {
            self.edit_len = self.done;
            self.pool_len = if (self.edit_len == 0) 0 else poolEnd(self.edits[self.edit_len - 1]);
        }
        if (self.joinable and self.edit_len > 0 and kind != .other) {
            const last = &self.edits[self.edit_len - 1];
            if (last.kind == kind and self.join(last, start, end, value)) return;
        }
        const need = removed.len + value.len;
        if (need > pool_capacity) {
            self.forget();
            return;
        }
        while (self.edit_len == max_edits or self.pool_len + need > pool_capacity) self.dropOldest();
        const removed_off = self.pool_len;
        @memcpy(self.pool[removed_off..][0..removed.len], removed);
        const inserted_off = removed_off + removed.len;
        @memcpy(self.pool[inserted_off..][0..value.len], value);
        self.pool_len = inserted_off + value.len;
        self.edits[self.edit_len] = .{
            .at = start,
            .removed_off = removed_off,
            .removed_len = removed.len,
            .inserted_off = inserted_off,
            .inserted_len = value.len,
            .cursor_before = self.cursor,
            .anchor_before = self.anchor,
            .cursor_after = start + value.len,
            .kind = kind,
        };
        self.edit_len += 1;
        self.done = self.edit_len;
    }

    /// Adds typing or a deletion next to the latest step to that step.
    fn join(self: *Editor, last: *Edit, start: usize, end: usize, value: []const u8) bool {
        const removed = self.buffer[start..end];
        if (self.pool_len + removed.len + value.len > pool_capacity) return false;
        switch (last.kind) {
            .typing => {
                if (end != start or start != last.at + last.inserted_len) return false;
                // A word and the space after it make one step.
                if (value[0] != ' ' and last.inserted_len > 0 and self.pool[last.inserted_off + last.inserted_len - 1] == ' ') return false;
                @memcpy(self.pool[self.pool_len..][0..value.len], value);
                self.pool_len += value.len;
                last.inserted_len += value.len;
            },
            .deleting_left => {
                if (value.len != 0 or end != last.at) return false;
                // The removed text sits at the end of the pool; put the new
                // bytes in front of it.
                const old = self.pool[last.removed_off..][0..last.removed_len];
                std.mem.copyBackwards(u8, self.pool[last.removed_off + removed.len ..][0..old.len], old);
                @memcpy(self.pool[last.removed_off..][0..removed.len], removed);
                last.removed_len += removed.len;
                last.inserted_off = last.removed_off + last.removed_len;
                self.pool_len += removed.len;
                last.at = start;
            },
            .deleting_right => {
                if (value.len != 0 or start != last.at) return false;
                @memcpy(self.pool[self.pool_len..][0..removed.len], removed);
                last.removed_len += removed.len;
                last.inserted_off = last.removed_off + last.removed_len;
                self.pool_len += removed.len;
            },
            .other => return false,
        }
        last.cursor_after = start + value.len;
        return true;
    }

    fn poolEnd(edit: Edit) usize {
        return edit.inserted_off + edit.inserted_len;
    }

    fn dropOldest(self: *Editor) void {
        const first = poolEnd(self.edits[0]);
        std.mem.copyForwards(u8, self.pool[0 .. self.pool_len - first], self.pool[first..self.pool_len]);
        self.pool_len -= first;
        std.mem.copyForwards(Edit, self.edits[0 .. self.edit_len - 1], self.edits[1..self.edit_len]);
        self.edit_len -= 1;
        self.done -|= 1;
        for (self.edits[0..self.edit_len]) |*edit| {
            edit.removed_off -= first;
            edit.inserted_off -= first;
        }
    }

    fn forget(self: *Editor) void {
        self.edit_len = 0;
        self.done = 0;
        self.pool_len = 0;
    }

    pub fn canUndo(self: *const Editor) bool {
        return self.done > 0;
    }

    pub fn undo(self: *Editor) void {
        self.joinable = false;
        if (self.done == 0) return;
        self.done -= 1;
        const edit = self.edits[self.done];
        self.splice(edit.at, edit.at + edit.inserted_len, self.pool[edit.removed_off..][0..edit.removed_len]);
        self.cursor = edit.cursor_before;
        self.anchor = edit.anchor_before;
        self.full = false;
    }

    pub fn redo(self: *Editor) void {
        self.joinable = false;
        if (self.done == self.edit_len) return;
        const edit = self.edits[self.done];
        self.done += 1;
        self.splice(edit.at, edit.at + edit.removed_len, self.pool[edit.inserted_off..][0..edit.inserted_len]);
        self.cursor = edit.cursor_after;
        self.anchor = self.cursor;
    }
};

const Sanitized = struct { text: []const u8, cut: bool };

/// Copies the valid UTF-8 of `value` into `out`, up to `room` bytes. Line
/// breaks become `\n`, tabs four spaces; other control characters and
/// invalid bytes go.
fn sanitize(out: []u8, value: []const u8, room: usize) Sanitized {
    var len: usize = 0;
    var at: usize = 0;
    const limit = @min(room, out.len);
    while (at < value.len) {
        const byte = value[at];
        var piece: []const u8 = undefined;
        var step: usize = 1;
        if (byte == '\r') {
            piece = "\n";
            if (at + 1 < value.len and value[at + 1] == '\n') step = 2;
        } else if (byte == '\t') {
            piece = "    ";
        } else if ((byte < 0x20 and byte != '\n') or byte == 0x7f) {
            at += 1;
            continue;
        } else {
            const n = std.unicode.utf8ByteSequenceLength(byte) catch {
                at += 1;
                continue;
            };
            if (at + n > value.len) break;
            _ = std.unicode.utf8Decode(value[at..][0..n]) catch {
                at += 1;
                continue;
            };
            piece = value[at..][0..n];
            step = n;
        }
        if (len + piece.len > limit) return .{ .text = out[0..len], .cut = true };
        @memcpy(out[len..][0..piece.len], piece);
        len += piece.len;
        at += step;
    }
    return .{ .text = out[0..len], .cut = false };
}

const t = std.testing;
const wide: Editor.View = .{ .columns = 80, .rows = 6 };

fn apply(editor: *Editor, op: Op, extend: bool) void {
    editor.run(.{ .op = op, .select = extend }, wide, "");
}

test "typing, moving and deleting keep whole codepoints" {
    var e: Editor = .{};
    try t.expect(e.insert("añ€b"));
    apply(&e, .char_left, false);
    apply(&e, .char_left, false);
    try t.expectEqual(@as(usize, 3), e.cursor);
    apply(&e, .backspace, false);
    try t.expectEqualStrings("a€b", e.text());
    apply(&e, .delete, false);
    try t.expectEqualStrings("ab", e.text());
    try t.expectEqual(LineColumn{ .line = 1, .column = 2 }, e.lineColumn());
}

test "word, line and text jumps" {
    var e: Editor = .{};
    _ = e.insert("const target = line + 1;\nnext line");
    apply(&e, .text_start, false);
    apply(&e, .word_right, false);
    try t.expectEqual(@as(usize, 5), e.cursor);
    apply(&e, .word_right, false);
    try t.expectEqual(@as(usize, 12), e.cursor);
    apply(&e, .word_left, true);
    try t.expectEqualStrings("target", e.selected());
    apply(&e, .line_end, false);
    try t.expectEqual(@as(usize, 24), e.cursor);
    apply(&e, .row_down, false);
    try t.expectEqual(LineColumn{ .line = 2, .column = 10 }, e.lineColumn());
    apply(&e, .line_start, false);
    try t.expectEqual(LineColumn{ .line = 2, .column = 1 }, e.lineColumn());
    apply(&e, .text_end, true);
    try t.expectEqualStrings("next line", e.selected());
    apply(&e, .char_left, false);
    try t.expectEqual(e.lineColumn().column, 1);
}

test "vertical moves keep the goal column across short lines" {
    var e: Editor = .{};
    _ = e.insert("abcdefgh\nab\nabcdefgh");
    e.select(5, 5);
    apply(&e, .row_down, false);
    try t.expectEqual(LineColumn{ .line = 2, .column = 3 }, e.lineColumn());
    apply(&e, .row_down, false);
    try t.expectEqual(LineColumn{ .line = 3, .column = 6 }, e.lineColumn());
    apply(&e, .row_down, false);
    try t.expectEqual(e.len, e.cursor);
    // Past the first row, Page Up keeps the column; on it, it goes to the start.
    apply(&e, .page_up, false);
    try t.expectEqual(@as(usize, 5), e.cursor);
    apply(&e, .page_up, false);
    try t.expectEqual(@as(usize, 0), e.cursor);
}

test "soft wrapping breaks after spaces and moves by rows" {
    var e: Editor = .{};
    _ = e.insert("one two three four");
    const narrow: Editor.View = .{ .columns = 9, .rows = 2 };
    var rows = Rows.init(e.text(), narrow.columns);
    try t.expectEqual(Row{ .start = 0, .end = 8, .wrapped = true }, rows.next().?);
    try t.expectEqual(Row{ .start = 8, .end = 14, .wrapped = true }, rows.next().?);
    try t.expectEqual(Row{ .start = 14, .end = 18, .wrapped = false }, rows.next().?);
    try t.expect(rows.next() == null);
    // The end of a wrapped row shows at the start of the next one.
    try t.expectEqual(Place{ .row = 1, .column = 0 }, e.place(8, 9));
    try t.expectEqual(Place{ .row = 2, .column = 4 }, e.place(18, 9));
    e.run(.{ .op = .row_up }, narrow, "");
    try t.expectEqual(@as(usize, 12), e.cursor);
    e.run(.{ .op = .row_up }, narrow, "");
    try t.expectEqual(@as(usize, 4), e.cursor);
    try t.expectEqual(@as(usize, 0), e.top_row);
    e.select(e.len, e.len);
    e.reveal(narrow);
    try t.expectEqual(@as(usize, 1), e.top_row);
    // Long words break inside.
    e.setText("abcdefghijkl");
    rows = Rows.init(e.text(), 5);
    try t.expectEqual(@as(usize, 5), rows.next().?.end);
}

test "selection, clipboard and undo" {
    var e: Editor = .{};
    _ = e.insert("hello world");
    apply(&e, .word_left, true);
    try t.expectEqualStrings("world", e.selected());
    apply(&e, .copy, false);
    try t.expectEqualStrings("world", e.selected());
    apply(&e, .cut, false);
    try t.expectEqualStrings("hello ", e.text());
    e.run(.{ .op = .paste }, wide, "there\r\nfriend");
    try t.expectEqualStrings("hello there\nfriend", e.text());
    apply(&e, .undo, false);
    try t.expectEqualStrings("hello ", e.text());
    apply(&e, .undo, false);
    try t.expectEqualStrings("hello world", e.text());
    try t.expectEqualStrings("world", e.selected());
    apply(&e, .redo, false);
    apply(&e, .redo, false);
    try t.expectEqualStrings("hello there\nfriend", e.text());
    apply(&e, .select_all, false);
    _ = e.insert("x");
    try t.expectEqualStrings("x", e.text());
    e.clear();
    try t.expectEqualStrings("", e.text());
    apply(&e, .undo, false);
    try t.expectEqualStrings("x", e.text());
}

test "typing and backspacing undo a word at a time" {
    var e: Editor = .{};
    for ("one two") |ch| _ = e.insert(&.{ch});
    apply(&e, .undo, false);
    try t.expectEqualStrings("one ", e.text());
    apply(&e, .undo, false);
    try t.expectEqualStrings("", e.text());
    apply(&e, .redo, false);
    apply(&e, .redo, false);
    for (0..3) |_| apply(&e, .backspace, false);
    try t.expectEqualStrings("one ", e.text());
    apply(&e, .undo, false);
    try t.expectEqualStrings("one two", e.text());
    try t.expectEqual(e.len, e.cursor);
}

test "deleting by word and to the line start" {
    var e: Editor = .{};
    _ = e.insert("first\nsecond word");
    apply(&e, .delete_word_left, false);
    try t.expectEqualStrings("first\nsecond ", e.text());
    apply(&e, .delete_to_line_start, false);
    try t.expectEqualStrings("first\n", e.text());
    apply(&e, .delete_to_line_start, false);
    try t.expectEqualStrings("first", e.text());
    apply(&e, .text_start, false);
    apply(&e, .delete_word_right, false);
    try t.expectEqualStrings("", e.text());
}

test "a full field refuses more text instead of dropping its start" {
    var e: Editor = .{};
    var big: [capacity - 1]u8 = undefined;
    @memset(&big, 'a');
    try t.expect(e.insert(&big));
    try t.expect(!e.insert("€"));
    try t.expect(e.full);
    try t.expectEqual(@as(usize, capacity - 1), e.len);
    try t.expect(e.insert("b"));
    try t.expectEqual(@as(u8, 'a'), e.text()[0]);
    try t.expect(!e.insert("c"));
    // Clearing a full field can be undone.
    e.clear();
    apply(&e, .undo, false);
    try t.expectEqual(@as(usize, capacity), e.len);
}

test "invalid UTF-8 and control characters are dropped" {
    var e: Editor = .{};
    _ = e.insert("a\xffb\x01\tc\xe2\x82");
    try t.expectEqualStrings("ab    c", e.text());
}

test "the undo history forgets its oldest steps" {
    var e: Editor = .{};
    for (0..max_edits + 20) |_| {
        _ = e.insert("\n");
    }
    try t.expectEqual(@as(usize, max_edits), e.edit_len);
    for (0..max_edits + 20) |_| apply(&e, .undo, false);
    try t.expectEqual(@as(usize, 20), e.len);
}

test "keys map to commands per platform" {
    const mac = Platform.mac;
    const pc = Platform.pc;
    try t.expectEqual(Command{ .op = .word_left, .select = true }, commandFor(.{ .code = .left, .mods = .{ .alt = true, .shift = true } }, mac).?);
    try t.expectEqual(Command{ .op = .line_end }, commandFor(.{ .code = .right, .mods = .{ .command = true } }, mac).?);
    try t.expectEqual(Command{ .op = .text_start }, commandFor(.{ .code = .up, .mods = .{ .command = true } }, mac).?);
    try t.expectEqual(Command{ .op = .word_right }, commandFor(.{ .code = .right, .mods = .{ .control = true } }, pc).?);
    try t.expectEqual(Command{ .op = .text_end, .select = true }, commandFor(.{ .code = .end, .mods = .{ .control = true, .shift = true } }, pc).?);
    try t.expectEqual(Command{ .op = .line_start }, commandFor(.{ .code = .home }, mac).?);
    try t.expectEqual(Command{ .op = .redo }, commandFor(.{ .code = .z, .mods = .{ .command = true, .shift = true } }, mac).?);
    try t.expectEqual(Command{ .op = .redo }, commandFor(.{ .code = .y, .mods = .{ .control = true } }, pc).?);
    try t.expectEqual(Command{ .op = .delete_to_line_start }, commandFor(.{ .code = .backspace, .mods = .{ .command = true } }, mac).?);
    try t.expect(commandFor(.{ .code = .other, .mods = .{ .command = true } }, mac) == null);
    try t.expect(commandFor(.{ .code = .a, .mods = .{ .control = true } }, mac) == null);
    try t.expect(commandFor(.{ .code = .tab, .mods = .{ .shift = true } }, mac) == null);

    var buffer: [48]u8 = undefined;
    try t.expectEqualStrings("⌥⇧←", comboText(&buffer, .{ .code = .left, .mods = .{ .alt = true, .shift = true } }, "", mac));
    try t.expectEqualStrings("⌘D", comboText(&buffer, .{ .code = .other, .mods = .{ .command = true } }, "D", mac));
    try t.expectEqualStrings("Ctrl+Shift+Left", comboText(&buffer, .{ .code = .left, .mods = .{ .control = true, .shift = true } }, "", pc));
}
