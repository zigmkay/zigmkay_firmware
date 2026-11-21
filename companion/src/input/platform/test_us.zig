//! Deterministic injected US fixture for offline wrapper tests. Never a native backend.
const root = @import("../root.zig");

pub const Fixture = struct {
    var instance: Fixture = .{};

    pub fn init() *Fixture {
        return &instance;
    }

    pub fn deinit(_: *Fixture) void {}
    pub fn refresh(_: *Fixture) void {}

    pub fn keyToText(_: *Fixture, input: root.KeyCodeFire) root.TextResult {
        const shift = input.tap_modifiers.left_shift or input.tap_modifiers.right_shift;
        const code = input.tap_keycode;
        const value: u8 = switch (code) {
            4...29 => (if (shift) @as(u8, 'A') else @as(u8, 'a')) + code - 4,
            30...39 => (if (shift) "!@#$%^&*()" else "1234567890")[code - 30],
            44 => ' ',
            45...56 => (if (shift) "_+{}|~:\"~<>?" else "-=[]\\#;'`,./")[code - 45],
            84...87 => "/*-+"[code - 84],
            89...97 => '1' + code - 89,
            98 => '0',
            99 => '.',
            else => return .{},
        };
        return .{ .data = .{ value, 0, 0, 0 }, .len = 1 };
    }
};
