//! Board-sized owned captions and translated text. No device or icon renderer.
const std = @import("std");
const p = @import("project");
const core = @import("layout-model");
const zkeymap = @import("zkeymap");
const labels = @import("labels.zig");
const practice = @import("practice.zig");
const Modifiers = core.Modifiers;

pub const CachedKeyContent = struct {
    caption: ?[]const u8 = null,
    label: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    icon_name: []const u8 = "",
    hold_layer: ?core.LayerIndex = null,
    hold_mods: ?Modifiers = null,
    hold_signal: ?u8 = null,
    hid_code: ?u8 = null,
    dead: bool = false,
    shortcut: bool = false,
    /// Display placeholders/named keys and arbitrary callbacks are not literal output.
    unproven: bool = false,
    provider_unknown: bool = false,

    pub fn withIconName(self: CachedKeyContent, name: []const u8) CachedKeyContent {
        var c = self;
        c.icon_name = name;
        return c;
    }

    pub fn withLabel(self: CachedKeyContent, text: []const u8) CachedKeyContent {
        var c = self;
        c.label = text;
        return c;
    }

    fn setHold(self: *CachedKeyContent, hold: core.HoldDef) void {
        self.hold_layer = hold.hold_layer;
        self.hold_signal = hold.custom;
        self.hold_mods = if (hold.hold_modifiers.has_any()) hold.hold_modifiers else null;
    }
};

pub const IconResolver = struct {
    context: *const anyopaque,
    /// Returns bytes owned by gpa. Cache copies and frees them immediately.
    resolve: *const fn (*const anyopaque, std.mem.Allocator, []const u8) anyerror!?[]u8,
};

/// Encoder action indices have their own namespace; never index key geometry.
pub const EncoderCache = struct {
    arena: std.heap.ArenaAllocator,
    entries: []CachedKeyContent,
    action_count: usize,

    pub fn lookup(self: *const EncoderCache, action: usize, mods: Modifiers) !*const CachedKeyContent {
        if (action >= self.action_count) return error.InvalidEncoderIndex;
        return &self.entries[action * 256 + mods.toByte()];
    }

    pub fn deinit(self: *EncoderCache) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn buildEncoderCache(
    gpa: std.mem.Allocator,
    translator: anytype,
    document: p.Document,
    resolver: ?IconResolver,
) !EncoderCache {
    if (document.encoders.len > 256) return error.InvalidDimensions;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const entries = try a.alloc(CachedKeyContent, document.encoders.len * 256);
    for (document.encoders, 0..) |tap, index| {
        const definition: core.KeyDef = .{ .tap_only = try p.lowerTap(document, tap) };
        for (0..256) |mods| {
            const physical: Modifiers = @bitCast(@as(u8, @intCast(mods)));
            var buffer: [64]u8 = undefined;
            var caption: [256]u8 = undefined;
            var entry = computeKeyContent(translator, definition, physical, &buffer);
            entry.caption = try a.dupe(
                u8,
                labels.keycapWithLayout(translator, .{ .tap_only = tap }, document, physical, &caption),
            );
            if (entry.label) |label| entry.label = try a.dupe(u8, label);
            if (resolver) |icons| {
                if (entry.icon_name.len > 0) {
                    if (try icons.resolve(icons.context, gpa, entry.icon_name)) |bytes| {
                        defer gpa.free(bytes);
                        entry.icon = try a.dupe(u8, bytes);
                    }
                }
            }
            entries[index * 256 + mods] = entry;
        }
    }
    return .{ .arena = arena, .entries = entries, .action_count = document.encoders.len };
}

pub const LabelCache = struct {
    entries: []CachedKeyContent,
    arena: std.heap.ArenaAllocator,
    layer_count: usize,
    key_count: usize,

    pub fn init(gpa: std.mem.Allocator, layers: usize, keys: usize) !LabelCache {
        if (layers == 0 or
            layers > p.Limits.layers or
            keys == 0 or
            keys > p.Limits.keys) return error.InvalidDimensions;
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const entries = try arena.allocator().alloc(CachedKeyContent, layers * keys * 256);
        @memset(entries, .{});
        return .{ .entries = entries, .arena = arena, .layer_count = layers, .key_count = keys };
    }

    pub fn lookup(
        self: *const LabelCache,
        layer: usize,
        key: usize,
        mods: Modifiers,
    ) *const CachedKeyContent {
        std.debug.assert(layer < self.layer_count and key < self.key_count);
        return &self.entries[(layer * self.key_count + key) * 256 + mods.toByte()];
    }

    pub fn lookupActiveChecked(
        self: *const LabelCache,
        layer: usize,
        key: usize,
        mods: Modifiers,
        active: u16,
    ) !*const CachedKeyContent {
        if (layer >= self.layer_count or key >= self.key_count) return error.InvalidDimensions;
        const valid = (@as(u16, 1) << @intCast(self.layer_count)) - 1;
        if (active & ~valid != 0) return error.InvalidActiveLayers;
        return self.lookupActive(layer, key, mods, active);
    }

    pub fn lookupActive(
        self: *const LabelCache,
        layer: usize,
        key: usize,
        mods: Modifiers,
        active: u16,
    ) *const CachedKeyContent {
        var selected = @min(layer, self.layer_count - 1);
        while (true) {
            const entry = self.lookup(selected, key, mods);
            const inherited = if (entry.label) |text| std.mem.eql(u8, text, "---") else false;
            if (selected == 0 or (active & (@as(u16, 1) << @intCast(selected)) != 0 and !inherited)) return entry;
            selected -= 1;
        }
    }

    /// Borrowed adapter: the cache must stay at a stable address while in use.
    pub fn practiceLabels(self: *const LabelCache) practice.Labels {
        return .{
            .context = self,
            .key_count = self.key_count,
            .layer_count = self.layer_count,
            .lookup = practiceLookup,
        };
    }

    fn practiceLookup(
        context: *const anyopaque,
        layer: usize,
        key: usize,
        mods: u8,
        active: u16,
    ) practice.Label {
        const self: *const LabelCache = @ptrCast(@alignCast(context));
        const entry = self.lookupActiveChecked(layer, key, @bitCast(mods), active) catch return .{};
        return .{
            .text = if (entry.unproven) null else entry.label,
            .unproven = entry.unproven,
            .provider_unknown = entry.provider_unknown or (if (entry.hold_signal) |signal| signal < 253 else false),
            .hid_code = entry.hid_code,
            .dead = entry.dead,
            .shortcut = entry.shortcut,
            .hold_layer = if (entry.hold_layer) |layer_index| @as(usize, layer_index) else null,
            .hold_modifiers = if (entry.hold_mods) |held| held.toByte() else null,
        };
    }

    pub fn deinit(self: *LabelCache) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn textKey(key: core.KeyCodeFire, physical: Modifiers) zkeymap.KeyCodeFire {
    return .{
        .tap_keycode = key.tap_keycode,
        .tap_modifiers = key.tap_modifiers.add(physical),
        .dead = key.dead,
    };
}

fn tapIcon(tap: core.TapDef) ?[]const u8 {
    if (tap.key_press) |key| {
        if (key.tap_keycode == core.special_keycode_COMPANION) return "companion";
        if (key.tap_keycode == core.special_keycode_SHUTDOWN_COMPANION) return "shutdown";
    }
    if (companionIcon(tap.custom)) |name| return name;
    if (tap.media_key) |m| {
        return switch (m) {
            .VolumeUp => "vol_up",
            .VolumeDown => "vol_down",
            .VolumeMute => "mute",
            .NextTrack => "next",
            .PreviousTrack => "prev",
        };
    }
    if (tap.mouse_action) |m| {
        return switch (m) {
            .LeftButton => "m_left",
            .RightButton => "m_right",
            .MiddleButton => "m_mid",
            .WheelUp => "w_up",
            .WheelDown => "w_down",
            .WheelLeft => "w_left",
            .WheelRight => "w_right",
            else => null,
        };
    }
    return null;
}

pub fn computeKeyContent(
    translator: anytype,
    definition: ?core.KeyDef,
    physical: Modifiers,
    buffer: *[64]u8,
) CachedKeyContent {
    const def = definition orelse return .{ .label = "---" };
    var entry: CachedKeyContent = .{};
    var fire: ?core.KeyCodeFire = null;
    switch (def) {
        .tap_only => |tap| {
            entry.unproven = tap.custom != null;
            entry.provider_unknown = tap.custom != null;
            if (tapIcon(tap)) |name| return entry.withIconName(name);
            if (tap.mouse_action != null) entry.label = "MS";
            fire = tap.key_press;
        },
        .tap_hold => |th| {
            entry.unproven = th.tap.custom != null;
            // The reference adds icons only for companion custom tap holds.
            if (companionIcon(th.tap.custom)) |name| entry.icon_name = name else fire = th.tap.key_press;
            entry.setHold(th.hold);
        },
        .tap_with_autofire => |af| {
            entry.unproven = af.tap.custom != null;
            entry.provider_unknown = af.tap.custom != null;
            fire = af.tap.key_press;
        },
        .hold_only => |held| entry.setHold(held),
        .none => {},
    }
    const key = fire orelse return entry;
    entry.hid_code = key.tap_keycode;
    entry.dead = key.dead;
    const mods = key.tap_modifiers;
    entry.shortcut = mods.left_ctrl or mods.right_ctrl or mods.left_gui or mods.right_gui;
    const scancode = std.enums.fromInt(zkeymap.ScanCode, key.tap_keycode) orelse {
        entry.unproven = true;
        return entry.withLabel("???");
    };
    if (editingIcon(scancode)) |icon| {
        entry.icon_name = icon;
        if (scancode == .KC_SPACE) entry.label = " ";
        return entry;
    }
    const translated = translator.keyToText(textKey(key, physical));
    entry.unproven = entry.unproven or translated.isLabel();
    const text = if (translated.isLabel()) translated.getLabel() else translated.slice();
    if (text.len != 0 and text.len < buffer.len and !(text.len == 1 and text[0] < 32)) {
        @memcpy(buffer[0..text.len], text);
        buffer[text.len] = 0;
        entry.label = buffer[0..text.len];
        return entry;
    }
    if (entry.label == null and entry.icon_name.len == 0) {
        entry.label = "?";
        entry.unproven = true;
    }
    return entry;
}

fn companionIcon(custom: ?u8) ?[]const u8 {
    if (custom == core.CUSTOM_ID_COMPANION_TOGGLE) return "companion";
    if (custom == core.CUSTOM_ID_COMPANION_SHUTDOWN) return "shutdown";
    return null;
}

/// Icons for whitespace, deletion and navigation keys.
fn editingIcon(scancode: zkeymap.ScanCode) ?[]const u8 {
    return switch (scancode) {
        .KC_BACKSPACE => "backspace",
        .KC_ENTER => "enter",
        .KC_LEFT => "left",
        .KC_RIGHT => "right",
        .KC_UP => "up",
        .KC_DOWN => "down",
        .KC_TAB => "tab",
        .KC_SPACE => "space",
        .KC_PAGE_DOWN => "page_down",
        .KC_PAGE_UP => "page_up",
        .KC_HOME => "home",
        .KC_END => "end",
        else => null,
    };
}

pub fn buildProjectCache(gpa: std.mem.Allocator, translator: anytype, document: p.Document) !LabelCache {
    return buildProjectCacheWithIcons(gpa, translator, document, null);
}

pub fn buildProjectCacheWithIcons(
    gpa: std.mem.Allocator,
    translator: anytype,
    document: p.Document,
    resolver: ?IconResolver,
) !LabelCache {
    const key_count = document.key_ids.len;
    if (document.layers.len == 0 or
        document.layers.len > p.Limits.layers or
        key_count == 0 or
        key_count > p.Limits.keys) return error.InvalidDimensions;
    for (document.layers) |layer| if (layer.actions.len != key_count) return error.InvalidDimensions;
    var result = try LabelCache.init(gpa, document.layers.len, key_count);
    errdefer result.deinit();
    const a = result.arena.allocator();
    for (document.layers, 0..) |layer, layer_index| for (layer.actions, 0..) |action, key_index| {
        const def = if (action) |value| try p.lowerAction(document, value) else null;
        for (0..256) |mods| {
            var buffer: [64]u8 = undefined;
            var caption: [256]u8 = undefined;
            const physical: Modifiers = @bitCast(@as(u8, @intCast(mods)));
            var entry = computeKeyContent(translator, def, physical, &buffer);
            entry.caption = try a.dupe(
                u8,
                labels.keycapWithLayout(translator, action, document, physical, &caption),
            );
            if (entry.label) |text| entry.label = try a.dupe(u8, text);
            if (resolver) |icons| {
                if (entry.icon_name.len != 0) {
                    if (try icons.resolve(icons.context, gpa, entry.icon_name)) |bytes| {
                        defer gpa.free(bytes);
                        entry.icon = try a.dupe(u8, bytes);
                    }
                }
            }
            result.entries[(layer_index * key_count + key_index) * 256 + mods] = entry;
        }
    };
    return result;
}

/// Geometry records are injected in arbitrary display order, keyed by index.
pub const GeometryKey = struct { key_index: usize, metadata: practice.KeyMetadata };

pub fn practiceMetadata(
    gpa: std.mem.Allocator,
    key_count: usize,
    geometry: []const GeometryKey,
) ![]practice.KeyMetadata {
    if (key_count == 0 or key_count > p.Limits.keys or geometry.len != key_count) return error.InvalidDimensions;
    const result = try gpa.alloc(practice.KeyMetadata, key_count);
    errdefer gpa.free(result);
    var seen: [p.Limits.keys]bool = @splat(false);
    for (geometry) |key| {
        if (key.key_index >= key_count or seen[key.key_index]) return error.InvalidGeometry;
        seen[key.key_index] = true;
        result[key.key_index] = key.metadata;
    }
    return result;
}

const Fixture = struct {
    alternate: bool = false,

    pub fn keyToText(self: *@This(), key: zkeymap.KeyCodeFire) zkeymap.TextResult {
        if (!zkeymap.isLayoutDependent(key.tap_keycode)) {
            return .{
                .data = @bitCast(@as(u32, key.tap_keycode)),
            };
        }
        if (key.dead) return .{ .data = .{ '^', 0, 0, 0 }, .len = 1 };
        if (key.tap_modifiers.left_alt or key.tap_modifiers.right_alt) {
            return .{
                .data = .{ '@', 0, 0, 0 },
                .len = 1,
            };
        }
        return .{ .data = .{
            if (self.alternate) 'z' else if (key.tap_modifiers.left_shift or key.tap_modifiers.right_shift) 'A' else 'a',
            0,
            0,
            0,
        }, .len = 1 };
    }
};

inline fn fixtureDocument(actions: []const ?p.Action) p.Document {
    return .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "fixture",
        .name = "Fixture",
        .key_ids = &.{ "thumb", "modifier", "letter", "return" },
        .layers = &.{.{ .id = 42, .name = "Base", .actions = actions }},
        .callbacks = &.{.{ .kind = .registered, .binding = "fixture", .ids = &.{7}, .sources = &.{} }},
    };
}

test "encoder action labels own four independent slots and physical modifier variants" {
    const t = std.testing;
    var source = Fixture{};
    var document = fixtureDocument(&.{ null, null, null, null });
    document.encoders = &.{
        .{ .key_press = .{ .tap_keycode = 4 } },
        .{ .key_press = .{ .tap_keycode = 5 } },
        .{ .media_key = .VolumeUp },
        .{ .media_key = .VolumeDown },
    };
    var encoders = try buildEncoderCache(t.allocator, &source, document, null);
    defer encoders.deinit();
    try t.expectEqual(@as(usize, 4), encoders.action_count);
    try t.expectEqualStrings("a", (try encoders.lookup(0, .{})).label.?);
    try t.expectEqualStrings("A", (try encoders.lookup(0, .{ .left_shift = true })).label.?);
    try t.expectEqualStrings("vol_up", (try encoders.lookup(2, .{})).icon_name);
    try t.expectEqualStrings("vol_down", (try encoders.lookup(3, .{})).icon_name);
    source.alternate = true;
    try t.expectEqualStrings("a", (try encoders.lookup(0, .{})).label.?);
    try t.expectError(error.InvalidEncoderIndex, encoders.lookup(4, .{}));
    document.encoders = &.{};
    var empty = try buildEncoderCache(t.allocator, &source, document, null);
    defer empty.deinit();
    try t.expectError(error.InvalidEncoderIndex, empty.lookup(0, .{}));
}

test "project captions preserve thumb holds translated labels and all modifier combinations across rebuild" {
    const t = std.testing;
    var source: Fixture = .{};
    const actions: []const ?p.Action = &.{
        .{ .tap_hold = .{
            .tap = .{ .key_press = .{ .tap_keycode = 44 } },
            .hold = .{ .custom = 7 },
            .tapping_term = .{ .ms = 200 },
        } },
        .{ .hold_only = .{ .hold_modifiers = .{ .left_alt = true } } },
        .{ .tap_only = .{ .key_press = .{ .tap_keycode = 4 } } },
        .{ .tap_hold = .{
            .tap = .{ .key_press = .{ .tap_keycode = 40 } },
            .hold = .{ .layer_id = 42 },
            .tapping_term = .{ .ms = 200 },
        } },
    };
    const doc = fixtureDocument(actions);
    var first = try buildProjectCache(t.allocator, &source, doc);
    defer first.deinit();
    try t.expectEqual(@as(usize, 1024), first.entries.len);
    var plain: [64]u8 = undefined;
    try t.expectEqualStrings("␣\nƒ7", labels.keycap_symbols.plain(first.lookup(0, 0, .{}).caption.?, &plain));
    try t.expectEqualStrings("↩\nL0", labels.keycap_symbols.plain(first.lookup(0, 3, .{}).caption.?, &plain));
    try t.expectEqualStrings("a", first.lookup(0, 2, .{}).label.?);
    try t.expectEqualStrings("@", first.lookup(0, 2, .{ .left_alt = true }).label.?);
    try t.expect(first.lookup(0, 1, .{}).label == null);
    try t.expect(first.lookup(0, 0, .{}).icon == null);
    try t.expectEqualStrings("space", first.lookup(0, 0, .{}).icon_name);
    source.alternate = true;
    var second = try buildProjectCache(t.allocator, &source, doc);
    defer second.deinit();
    try t.expectEqualStrings("a", first.lookup(0, 2, .{}).label.?);
    try t.expectEqualStrings("z", second.lookup(0, 2, .{}).label.?);
    for (first.entries, second.entries) |old, new| {
        try t.expectEqual(old.hid_code, new.hid_code);
        try t.expectEqual(old.hold_layer, new.hold_layer);
    }
}

test "active transparency explicit blocks dimensions and practice adapters are checked" {
    const t = std.testing;
    try t.expectError(error.InvalidDimensions, LabelCache.init(t.allocator, 0, 1));
    try t.expectError(error.InvalidDimensions, LabelCache.init(t.allocator, 16, 1));
    try t.expectError(error.InvalidDimensions, LabelCache.init(t.allocator, 1, 128));
    var cache = try LabelCache.init(t.allocator, 3, 1);
    defer cache.deinit();
    cache.entries[0] = .{ .label = "a" };
    cache.entries[256] = .{ .label = "!" };
    cache.entries[512] = .{ .label = "---" };
    try t.expectEqualStrings("a", (try cache.lookupActiveChecked(2, 0, .{}, 0b101)).label.?);
    try t.expectEqualStrings("!", (try cache.lookupActiveChecked(2, 0, .{}, 0b111)).label.?);
    try t.expectError(error.InvalidActiveLayers, cache.lookupActiveChecked(2, 0, .{}, 0b1000));
    try t.expectError(error.InvalidDimensions, cache.lookupActiveChecked(2, 1, .{}, 0b111));
    try t.expectEqual(@as(usize, 0), (try practice.hint(cache.practiceLabels(), 2, 0, 'a', 0b101)).?.key);
    cache.entries[512] = .{ .label = "" };
    try t.expectEqualStrings("", cache.lookupActive(2, 0, .{}, 0b111).label.?);
    var source: Fixture = .{};
    var doc = fixtureDocument(&.{null});
    try t.expectError(error.InvalidDimensions, buildProjectCache(t.allocator, &source, doc));
    doc.key_ids = &.{};
    try t.expectError(error.InvalidDimensions, buildProjectCache(t.allocator, &source, doc));
}

test "dead shortcut and shifted tap variants remain distinct from captions" {
    const t = std.testing;
    var source: @import("label_fixture.zig").Fixture = .{};
    const tap: p.Tap = .{ .key_press = .{ .tap_keycode = 38, .tap_modifiers = .{ .right_shift = true } } };
    const actions: []const ?p.Action = &.{
        .{ .tap_only = tap },
        .{ .tap_hold = .{ .tap = tap, .hold = .{ .layer_id = 42 }, .tapping_term = .{ .ms = 200 } } },
        .{ .tap_with_autofire = .{
            .tap = tap,
            .initial_delay = .{ .ms = 200 },
            .repeat_interval = .{ .ms = 50 },
        } },
        .{ .tap_only = .{ .key_press = .{ .tap_keycode = 39 } } },
    };
    var cache = try buildProjectCache(t.allocator, &source, fixtureDocument(actions));
    defer cache.deinit();
    try t.expectEqualStrings("(", cache.lookup(0, 0, .{}).caption.?);
    var plain: [64]u8 = undefined;
    try t.expectEqualStrings("(\nL0", labels.keycap_symbols.plain(cache.lookup(0, 1, .{}).caption.?, &plain));
    try t.expectEqualStrings("(", cache.lookup(0, 2, .{}).label.?);
    try t.expectEqualStrings(")", cache.lookup(0, 3, .{ .right_shift = true }).caption.?);
    var buffer: [64]u8 = undefined;
    const dead = computeKeyContent(&source, .{ .tap_only = .{ .key_press = .{
        .tap_keycode = 4,
        .dead = true,
    } } }, .{}, &buffer);
    const shortcut = computeKeyContent(&source, .{ .tap_only = .{ .key_press = .{
        .tap_keycode = 4,
        .tap_modifiers = .{ .left_gui = true },
    } } }, .{}, &buffer);
    try t.expect(dead.dead);
    try t.expect(shortcut.shortcut);
}

test "optional icon provider owns bytes and geometry maps by processing index" {
    const t = std.testing;
    const Icons = struct {
        fn resolve(_: *const anyopaque, gpa: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
            return try gpa.dupe(u8, name);
        }
    };
    var context: u8 = 0;
    var source: Fixture = .{};
    const actions: []const ?p.Action = &.{ .{ .tap_only = .{
        .key_press = .{ .tap_keycode = 44 },
    } }, null, null, null };
    var cache = try buildProjectCacheWithIcons(
        t.allocator,
        &source,
        fixtureDocument(actions),
        .{ .context = &context, .resolve = Icons.resolve },
    );
    defer cache.deinit();
    try t.expectEqualStrings("space", cache.lookup(0, 0, .{}).icon.?);
    const metadata = try practiceMetadata(t.allocator, 2, &.{
        .{ .key_index = 1, .metadata = .{ .hand = .right, .thumb = true } },
        .{ .key_index = 0, .metadata = .{ .hand = .left } },
    });
    defer t.allocator.free(metadata);
    try t.expect(metadata[0].hand == .left and metadata[1].thumb);
    try t.expectError(
        error.InvalidGeometry,
        practiceMetadata(t.allocator, 2, &.{
            .{ .key_index = 0, .metadata = .{} },
            .{ .key_index = 0, .metadata = .{} },
        }),
    );
}

test "unknown question placeholders and arbitrary callbacks never become proven practice routes" {
    const Empty = struct {
        pub fn keyToText(_: *@This(), _: zkeymap.KeyCodeFire) zkeymap.TextResult {
            return .{};
        }
    };
    const Literal = struct {
        pub fn keyToText(_: *@This(), _: zkeymap.KeyCodeFire) zkeymap.TextResult {
            return .{ .data = .{ '?', 0, 0, 0 }, .len = 1 };
        }
    };
    var empty: Empty = .{};
    var literal: Literal = .{};
    var buffer: [64]u8 = undefined;
    var cache = try LabelCache.init(std.testing.allocator, 1, 1);
    defer cache.deinit();
    cache.entries[0] = computeKeyContent(&empty, .{ .tap_only = .{
        .key_press = .{ .tap_keycode = 58 },
    } }, .{}, &buffer);
    try std.testing.expectEqualStrings("?", cache.entries[0].label.?);
    try std.testing.expect((try practice.hint(cache.practiceLabels(), 0, 0, '?', 1)) == null);
    cache.entries[0] = computeKeyContent(&literal, .{ .tap_only = .{
        .key_press = .{ .tap_keycode = 56 },
    } }, .{}, &buffer);
    try std.testing.expect((try practice.hint(cache.practiceLabels(), 0, 0, '?', 1)) != null);
    cache.entries[0] = computeKeyContent(&literal, .{ .tap_only = .{
        .key_press = .{ .tap_keycode = 44 },
        .custom = 42,
    } }, .{}, &buffer);
    try std.testing.expect((try practice.hint(cache.practiceLabels(), 0, 0, ' ', 1)) == null);
    cache.entries[0] = computeKeyContent(&literal, .{ .tap_only = .{
        .key_press = .{ .tap_keycode = 56 },
        .custom = 42,
    } }, .{}, &buffer);
    try std.testing.expect((try practice.hint(cache.practiceLabels(), 0, 0, '?', 1)) == null);
}
