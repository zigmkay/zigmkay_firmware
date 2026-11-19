const std = @import("std");
const core = @import("layout-model");
const native = @import("input-source");

pub const Text = struct {
    bytes: [8192]u8 = @splat(0),
    len: usize = 0,
    cursor: usize = 0,
    mods: core.Modifiers = .{},
    fixture_dead: bool = false,
    native_session: ?native.Session = null,
    logged: usize = 0,

    pub fn init(use_fixture: bool) Text {
        return .{ .native_session = if (use_fixture) null else native.Session.init() };
    }

    pub fn deinit(self: *Text) void {
        if (self.native_session) |*session| session.deinit();
    }

    pub fn reset(self: *Text) void {
        self.mods = .{};
        self.fixture_dead = false;
        if (self.native_session) |*session| session.reset();
    }

    /// Clear text and caret as well as pending composition and modifiers.
    pub fn clear(self: *Text) void {
        @memset(self.bytes[0..self.len], 0);
        self.len = 0;
        self.cursor = 0;
        self.reset();
    }

    pub fn refresh(self: *Text) bool {
        if (self.native_session) |*session| return session.refresh();
        return false;
    }

    pub fn value(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn insert(self: *Text, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUnicode;
        if (bytes.len > self.bytes.len - self.len) return error.TextLimit;
        std.mem.copyBackwards(
            u8,
            self.bytes[self.cursor + bytes.len .. self.len + bytes.len],
            self.bytes[self.cursor..self.len],
        );
        @memcpy(self.bytes[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
        self.len += bytes.len;
    }

    fn previous(self: *const Text) usize {
        if (self.cursor == 0) return 0;
        var index = self.cursor - 1;
        while (index > 0 and self.bytes[index] & 0xC0 == 0x80) index -= 1;
        return index;
    }

    fn next(self: *const Text) usize {
        if (self.cursor == self.len) return self.len;
        return self.cursor + (std.unicode.utf8ByteSequenceLength(self.bytes[self.cursor]) catch 1);
    }

    fn erase(self: *Text, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.bytes[start .. self.len - (end - start)], self.bytes[end..self.len]);
        self.len -= end - start;
        self.cursor = start;
    }

    /// Deterministic fixture is deliberately small; native acceptance separately
    /// uses actual selected EurKEY. Includes dead composition and multi-scalar output.
    fn fixture(self: *Text, code: u8, buffer: *[128]u8) []const u8 {
        if (self.mods.left_alt and code == 52) {
            self.fixture_dead = true;
            return "";
        }
        if (self.fixture_dead) {
            self.fixture_dead = false;
            return if (code == 8) "é" else "´a";
        }
        if (self.mods.left_alt and code == 22) return "ß";
        if (code >= 4 and code <= 29) {
            buffer[0] = (if (self.mods.left_shift or self.mods.right_shift) @as(u8, 'A') else 'a') + code - 4;
            return buffer[0..1];
        }
        return switch (code) {
            44 => " ",
            54 => ",",
            55 => ".",
            56 => "/",
            else => "",
        };
    }

    pub fn output(self: *Text, commands: []const core.OutputCommand) !void {
        try self.outputMode(commands, false);
    }

    pub fn singleLineOutput(self: *Text, commands: []const core.OutputCommand) !void {
        try self.outputMode(commands, true);
    }

    /// Filter translated control characters without splitting UTF-8 scalars.
    pub fn insertSingleLine(self: *Text, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUnicode;
        var start: usize = 0;
        for (bytes, 0..) |byte, index| {
            if (byte >= 0x20 and byte != 0x7f) continue;
            try self.insert(bytes[start..index]);
            self.logged += 1;
            start = index + 1;
        }
        try self.insert(bytes[start..]);
    }

    fn outputMode(self: *Text, commands: []const core.OutputCommand, single_line: bool) !void {
        for (commands) |command| switch (command) {
            .ModifiersChanged => |mods| self.mods = mods,
            .KeyCodeRelease => {},
            .KeyCodePress => |code| {
                if (code >= 252) {
                    self.logged += 1;
                    continue;
                }
                if (self.mods.left_ctrl or self.mods.right_ctrl or self.mods.left_gui or self.mods.right_gui) {
                    self.logged += 1;
                    continue;
                }
                switch (code) {
                    40 => if (single_line) {
                        self.logged += 1;
                    } else try self.insert("\n"),
                    43 => if (single_line) {
                        self.logged += 1;
                    } else try self.insert("\t"),
                    42 => self.erase(self.previous(), self.cursor),
                    76 => self.erase(self.cursor, self.next()),
                    80 => self.cursor = self.previous(),
                    79 => self.cursor = self.next(),
                    74 => self.cursor = 0,
                    77 => self.cursor = self.len,
                    else => {
                        var buffer: [128]u8 = undefined;
                        const bytes = if (self.native_session) |*session| session.translate(.{
                            .tap_keycode = code,
                            .tap_modifiers = self.mods,
                        }, &buffer) catch |err| {
                            if (single_line and err == error.UnsupportedUsage) {
                                self.logged += 1;
                                continue;
                            }
                            return err;
                        } else self.fixture(code, &buffer);
                        if (single_line) try self.insertSingleLine(bytes) else try self.insert(bytes);
                    },
                }
            },
            else => self.logged += 1,
        };
    }

    /// Reuse native layout/dead-key translation, while scoring each insertion.
    pub fn practiceOutput(
        self: *Text,
        commands: []const core.OutputCommand,
        session: *@import("practice.zig").Session,
        now: u64,
    ) !void {
        for (commands) |command| {
            if (command == .KeyCodePress) {
                const code = command.KeyCodePress;
                const shortcut = self.mods.left_ctrl or self.mods.right_ctrl or self.mods.left_gui or self.mods.right_gui;
                if (!shortcut and code == 42) {
                    session.backspace();
                    continue;
                }
                if (!shortcut and code == 43) {
                    try session.insert("    ", now, false);
                    continue;
                }
                if (code == 76 or code == 80 or code == 79 or code == 74 or code == 77) continue;
            }
            self.len = 0;
            self.cursor = 0;
            try self.output(&.{command});
            try session.insert(self.value(), now, false);
        }
        self.len = 0;
        self.cursor = 0;
    }
};

test "composition, several scalars, editing and reset have literal text outcomes" {
    var text = Text.init(true);
    defer text.deinit();
    try text.output(&.{
        .{ .ModifiersChanged = .{ .left_alt = true } },
        .{ .KeyCodePress = 52 },
        .{ .ModifiersChanged = .{} },
        .{ .KeyCodePress = 8 },
    });
    try std.testing.expectEqualStrings("é", text.value());
    try text.output(&.{
        .{ .ModifiersChanged = .{ .left_alt = true } },
        .{ .KeyCodePress = 52 },
        .{ .ModifiersChanged = .{} },
        .{ .KeyCodePress = 4 },
    });
    try std.testing.expectEqualStrings("é´a", text.value());
    try text.output(&.{ .{ .KeyCodePress = 42 }, .{ .KeyCodePress = 80 }, .{ .KeyCodePress = 76 } });
    try std.testing.expectEqualStrings("é", text.value());
    try text.output(&.{ .{ .ModifiersChanged = .{ .left_alt = true } }, .{ .KeyCodePress = 52 } });
    text.reset();
    try text.output(&.{.{ .KeyCodePress = 8 }});
    try std.testing.expectEqualStrings("ée", text.value());
    try text.output(&.{
        .ActivateBootMode,
        .{ .ConsumerKeyPressed = .VolumeUp },
        .{ .MouseCommandPressed = .WheelDown },
        .{ .ModifiersChanged = .{ .left_gui = true } },
        .{ .KeyCodePress = 20 },
    });
    try std.testing.expectEqualStrings("ée", text.value());
    try std.testing.expectEqual(@as(usize, 4), text.logged);
}

test "draft practice uses composed text and counts corrections without navigation" {
    var text = Text.init(true);
    defer text.deinit();
    var session: @import("practice.zig").Session = .{};
    try session.load("é    a", .draft);
    try text.practiceOutput(&.{
        .{ .ModifiersChanged = .{ .left_alt = true } },
        .{ .KeyCodePress = 52 },
        .{ .ModifiersChanged = .{} },
        .{ .KeyCodePress = 8 },
        .{ .KeyCodePress = 43 },
        .{ .KeyCodePress = 5 },
        .{ .KeyCodePress = 42 },
        .{ .KeyCodePress = 80 },
        .{ .KeyCodePress = 4 },
    }, &session, 100);
    try std.testing.expectEqual(@import("practice.zig").State.complete, session.state);
    try std.testing.expectEqual(@as(usize, 7), session.attempts);
    try std.testing.expectEqual(@as(usize, 1), session.corrected);
}

test "single line text filters translated controls and edits Unicode safely" {
    var text = Text.init(true);
    defer text.deinit();
    try text.insertSingleLine("é\nß\t🙂\r\x1b\x7f");
    try std.testing.expectEqualStrings("éß🙂", text.value());
    try text.singleLineOutput(&.{
        .{ .KeyCodePress = 80 },
        .{ .KeyCodePress = 42 },
        .{ .KeyCodePress = 40 },
        .{ .KeyCodePress = 43 },
    });
    try std.testing.expectEqualStrings("é🙂", text.value());
    try std.testing.expectEqual(@as(usize, 2), text.cursor);
    try std.testing.expectEqual(@as(usize, 7), text.logged);
    try text.singleLineOutput(&.{ .{ .ModifiersChanged = .{ .left_alt = true } }, .{ .KeyCodePress = 52 } });
    text.clear();
    try std.testing.expectEqualStrings("", text.value());
    try std.testing.expectEqual(@as(usize, 0), text.cursor);
    try text.singleLineOutput(&.{.{ .KeyCodePress = 8 }});
    try std.testing.expectEqualStrings("e", text.value());
}

test "invalid Unicode and bounded insert leave existing text and caret unchanged" {
    const t = std.testing;
    var text = Text.init(true);
    defer text.deinit();
    try text.insert("aé🙂z");
    try text.output(&.{.{ .KeyCodePress = 80 }});
    const cursor = text.cursor;
    try t.expectError(error.InvalidUnicode, text.insert("\xf0\x80\x80\x80"));
    try t.expectEqualStrings("aé🙂z", text.value());
    try t.expectEqual(cursor, text.cursor);
    const large: [8192]u8 = @splat('x');
    try t.expectError(error.TextLimit, text.insert(&large));
    try t.expectEqualStrings("aé🙂z", text.value());
    try t.expectEqual(cursor, text.cursor);
    try text.output(&.{ .{ .KeyCodePress = 80 }, .{ .KeyCodePress = 76 } });
    try t.expectEqualStrings("aéz", text.value());
    try text.output(&.{ .{ .KeyCodePress = 74 }, .{ .KeyCodePress = 42 } });
    try t.expectEqualStrings("aéz", text.value());
    try t.expectEqual(@as(usize, 0), text.cursor);
    try text.output(&.{ .{ .KeyCodePress = 77 }, .{ .KeyCodePress = 76 } });
    try t.expectEqualStrings("aéz", text.value());
    try t.expectEqual(text.len, text.cursor);
    try t.expect(!text.refresh());
}

test "reset clears modifiers and composition while clear retains diagnostic count" {
    const t = std.testing;
    var text = Text.init(true);
    defer text.deinit();
    try text.output(&.{ .{ .ModifiersChanged = .{ .right_ctrl = true } }, .{ .KeyCodePress = 4 } });
    try t.expectEqualStrings("", text.value());
    try t.expectEqual(@as(usize, 1), text.logged);
    text.reset();
    try text.output(&.{ .{ .KeyCodePress = 4 }, .{ .KeyCodeRelease = 4 } });
    try t.expectEqualStrings("a", text.value());
    try text.output(&.{ .{ .ModifiersChanged = .{ .left_alt = true } }, .{ .KeyCodePress = 52 } });
    text.clear();
    try t.expectEqual(@as(usize, 1), text.logged);
    try text.output(&.{.{ .KeyCodePress = 8 }});
    try t.expectEqualStrings("e", text.value());
}
