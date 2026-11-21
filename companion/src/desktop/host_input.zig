//! Explicit host scancode substitutes; no GPIO or physical-layout inference.
const std = @import("std");
const project = @import("project");

pub const Binding = struct {
    board_id: [8]u8,
    key_ids: []const []const u8,
    scancodes: []const u32,

    pub fn validate(self: Binding, document: project.Document) !void {
        if (!std.mem.eql(u8, &self.board_id, &document.board_id)) return error.HostMappingBoardMismatch;
        if (self.key_ids.len == 0 or
            self.key_ids.len > project.Limits.keys or
            self.key_ids.len != self.scancodes.len or
            self.key_ids.len != document.key_ids.len) return error.HostMappingDimensions;
        for (self.key_ids, document.key_ids, self.scancodes, 0..) |id, expected, code, index| {
            if (!std.mem.eql(u8, id, expected)) return error.HostMappingKeyOrderMismatch;
            if (code == 0 or code > 511) return error.InvalidHostScancode;
            if (std.mem.indexOfScalar(u32, self.scancodes[0..index], code) != null) return error.DuplicateHostScancode;
        }
    }

    /// Binding must be validated when installed for the captured document.
    pub fn keyIndex(self: Binding, scancode: u32) ?u7 {
        for (self.scancodes, 0..) |code, index| if (code == scancode) return @intCast(index);
        return null;
    }
};

/// HID usages of the QWERTY letter block, row by row.
const fingers = [_]u32{
    20, 26, 8, 21, 23, 28, 24, 12, 18, 19,
    4,  22, 7, 9,  10, 11, 13, 14, 15, 51,
    29, 27, 6, 25, 5,  17, 16, 54, 55, 56,
};

const thumb_fallback = [_]u32{ 44, 40, 42, 43 };

fn tapUsage(action: ?project.Action) ?u32 {
    const value = action orelse return null;
    const tap = switch (value) {
        .tap_only => |t| t,
        .tap_hold => |t| t.tap,
        .tap_with_autofire => |t| t.tap,
        else => return null,
    };
    const key = tap.key_press orelse return null;
    return if (key.tap_modifiers.has_any()) null else key.tap_keycode;
}

/// Retained LK7 QWERTY-position behavior only for the exact known stable key
/// order. A different 34-key board must supply its own explicit binding.
pub fn lk7(document: project.Document) ![34]u32 {
    const expected = project.profiles.board;
    if (!std.mem.eql(u8, &document.board_id, &expected.id) or
        !std.mem.eql(
            u8,
            document.physical_layout,
            expected.physical_layout,
        )) return error.HostMappingUnavailable;
    if (document.key_ids.len != 34 or
        document.layers.len == 0 or
        document.layers[0].actions.len != 34) return error.HostMappingDimensions;
    for (document.key_ids, expected.key_ids) |id, key| {
        if (!std.mem.eql(u8, id, key)) return error.HostMappingKeyOrderMismatch;
    }
    var result: [34]u32 = @splat(0);
    @memcpy(result[0..30], &fingers);
    var used: [256]bool = @splat(false);
    for (fingers) |code| used[code] = true;
    for (30..34) |index| {
        const code = tapUsage(document.layers[0].actions[index]) orelse continue;
        if (std.mem.indexOfScalar(u32, &thumb_fallback, code) == null or used[code]) continue;
        result[index] = code;
        used[code] = true;
    }
    for (30..34) |index| {
        if (result[index] != 0) continue;
        for (thumb_fallback) |code| {
            if (used[code]) continue;
            result[index] = code;
            used[code] = true;
            break;
        }
    }
    return result;
}

test "retained Mac thumbs and all profile positions remain independently releasable" {
    const t = std.testing;
    inline for (.{ .qwerty, .eurkey, .danish, .eurmac }) |profile| {
        var loaded = try project.profiles.create(t.allocator, profile);
        defer loaded.deinit();
        const document = loaded.snapshot.document;
        const codes = try lk7(document);
        const binding = Binding{
            .board_id = document.board_id,
            .key_ids = document.key_ids,
            .scancodes = &codes,
        };
        try binding.validate(document);
        for (codes, 0..) |code, index| try t.expectEqual(@as(?u7, @intCast(index)), binding.keyIndex(code));
        try t.expect(binding.keyIndex(82) == null);
        if (profile == .eurmac) {
            try t.expectEqual(@as(?u7, 30), binding.keyIndex(44));
            try t.expectEqual(@as(?u7, 31), binding.keyIndex(43));
            try t.expectEqual(@as(?u7, 32), binding.keyIndex(40));
            try t.expectEqual(@as(?u7, 33), binding.keyIndex(42));
        }
        var other = document;
        other.board_id[0] ^= 1;
        try t.expectError(error.HostMappingUnavailable, lk7(other));
        try t.expectError(error.HostMappingBoardMismatch, binding.validate(other));
    }
}

test "explicit host mapping rejects ambiguous usages and reordered processing keys" {
    const t = std.testing;
    var loaded = try project.profiles.create(t.allocator, .eurmac);
    defer loaded.deinit();
    const document = loaded.snapshot.document;
    var codes = try lk7(document);
    const binding = Binding{
        .board_id = document.board_id,
        .key_ids = document.key_ids,
        .scancodes = &codes,
    };
    codes[1] = codes[0];
    try t.expectError(error.DuplicateHostScancode, binding.validate(document));
    codes = try lk7(document);
    codes[0] = 512;
    try t.expectError(error.InvalidHostScancode, binding.validate(document));
    const keys = try t.allocator.dupe([]const u8, document.key_ids);
    defer t.allocator.free(keys);
    std.mem.swap([]const u8, &keys[0], &keys[1]);
    var changed = document;
    changed.key_ids = keys;
    try t.expectError(error.HostMappingKeyOrderMismatch, lk7(changed));
}

test "a different board uses its explicitly supplied variable-sized binding" {
    const t = std.testing;
    var loaded = try project.profiles.create(t.allocator, .qwerty);
    defer loaded.deinit();
    var document = loaded.snapshot.document;
    document.board_id = .{ 't', 'e', 's', 't', 0, 0, 0, 0 };
    document.key_ids = &.{ "left", "right", "thumb" };
    const binding = Binding{
        .board_id = document.board_id,
        .key_ids = document.key_ids,
        .scancodes = &.{ 4, 7, 44 },
    };
    try binding.validate(document);
    try t.expectEqual(@as(?u7, 2), binding.keyIndex(44));
    try t.expectError(error.HostMappingUnavailable, lk7(document));
}
