const std = @import("std");
const p = @import("project");
const model = @import("layout-model");
const labels = @import("labels.zig");

pub const Target = enum { tap, hold };
pub const Category = enum { all, key, modifier, layer, media, mouse, callback, one_shot, signal };

pub const Entry = union(enum) {
    key: u8,
    modifier: u8,
    layer: p.LayerId,
    media: model.MediaCode,
    mouse: model.MouseAction,
    callback: u8,
    one_shot,
    signal: u8,
};

pub fn available(target: Target, category: Category) bool {
    return target == .tap or switch (category) {
        .all, .modifier, .layer, .callback, .signal => true,
        else => false,
    };
}

pub fn label(entry: Entry, doc: p.Document, buffer: []u8) []const u8 {
    return switch (entry) {
        .key => |code| labels.hostUsage(labels.running_host, code, buffer),
        .modifier => |bit| labels.hostModifierNames(labels.running_host, @as(u8, 1) << @intCast(bit), buffer),
        .layer => |id| blk: {
            for (doc.layers) |layer| if (layer.id == id) break :blk std.fmt.bufPrint(
                buffer,
                "Layer {d}: {s}",
                .{ id, layer.name },
            ) catch "Layer";
            break :blk std.fmt.bufPrint(buffer, "Layer {d}", .{id}) catch "Layer";
        },
        .media => |value| labels.spelled(labels.mediaSymbol(value), buffer),
        .mouse => |value| labels.spelled(labels.mouseSymbol(value), buffer),
        .callback => |id| std.fmt.bufPrint(buffer, "Callback {d}", .{id}) catch "Callback",
        .one_shot => "One-shot",
        .signal => |id| labels.signal(id, buffer),
    };
}

fn append(
    doc: p.Document,
    target: Target,
    category: Category,
    query: []const u8,
    entry: Entry,
    out: []Entry,
    count: *usize,
) void {
    const kind: Category = switch (entry) {
        .key => .key,
        .modifier => .modifier,
        .layer => .layer,
        .media => .media,
        .mouse => .mouse,
        .callback => .callback,
        .one_shot => .one_shot,
        .signal => .signal,
    };
    if (!available(target, kind) or (category != .all and category != kind) or count.* == out.len) return;
    var buffer: [256]u8 = undefined;
    const matches = switch (entry) {
        .key => |code| labels.matchesUsage(labels.running_host, code, query),
        .modifier => |bit| labels.matchesUsage(labels.running_host, 224 + bit, query),
        // Firmware names such as "VolumeMute" stay searchable.
        .media => |value| labels.containsIgnoreCase(label(entry, doc, &buffer), query) or labels.containsIgnoreCase(@tagName(value), query),
        .mouse => |value| labels.containsIgnoreCase(label(entry, doc, &buffer), query) or labels.containsIgnoreCase(@tagName(value), query),
        else => labels.containsIgnoreCase(label(entry, doc, &buffer), query),
    };
    if (matches) {
        out[count.*] = entry;
        count.* += 1;
    }
}

/// Caller-owned storage bounds results; no allocation or hidden picker state.
pub fn search(doc: p.Document, target: Target, category: Category, query: []const u8, out: []Entry) usize {
    var count: usize = 0;
    inline for (@typeInfo(@import("zkeycodes").layouts.keycodes.kc.basic).@"enum".field_values) |value| {
        // The keyboard-page Mute and Volume usages (127 to 129) repeat the
        // media keys, which macOS honours too; offer only the media keys.
        if (value < 224 and (value < 127 or value > 129)) append(doc, target, category, query, .{ .key = @intCast(value) }, out, &count);
    }
    append(doc, target, category, query, .{ .key = 252 }, out, &count);
    for (0..8) |bit| append(doc, target, category, query, .{ .modifier = @intCast(bit) }, out, &count);
    if (target == .hold) {
        for (doc.layers) |layer| append(
            doc,
            target,
            category,
            query,
            .{ .layer = layer.id },
            out,
            &count,
        );
    }
    inline for (@typeInfo(model.MediaCode).@"enum".field_values) |value| append(
        doc,
        target,
        category,
        query,
        .{ .media = @fromBackingInt(@intCast(value)) },
        out,
        &count,
    );
    inline for (@typeInfo(model.MouseAction).@"enum".field_values) |value| append(
        doc,
        target,
        category,
        query,
        .{ .mouse = @fromBackingInt(@intCast(value)) },
        out,
        &count,
    );
    var callbacks: [256]bool = @splat(false);
    for (doc.callbacks) |callback| for (callback.ids) |id| {
        callbacks[id] = true;
    };
    for (callbacks, 0..) |present, id| if (present) {
        append(doc, target, category, query, .{ .callback = @intCast(id) }, out, &count);
    };
    append(doc, target, category, query, .one_shot, out, &count);
    for (253..256) |id| append(doc, target, category, query, .{ .signal = @intCast(id) }, out, &count);
    return count;
}

test "picker uses stable document layer and deduplicated callback IDs with bounded results" {
    const t = std.testing;
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "synthetic",
        .name = "Picker",
        .key_ids = &.{},
        .layers = &.{
            .{ .id = 912, .name = "Navigation", .actions = &.{} },
            .{ .id = 42, .name = "Symbols", .actions = &.{} },
        },
        .callbacks = &.{.{
            .kind = .registered,
            .binding = "preserved",
            .ids = &.{ 7, 3, 7 },
            .sources = &.{},
        }},
    };
    var out: [16]Entry = undefined;
    const layers = search(doc, .hold, .layer, "", &out);
    try t.expectEqual(@as(usize, 2), layers);
    try t.expectEqual(@as(p.LayerId, 912), out[0].layer);
    try t.expectEqual(@as(p.LayerId, 42), out[1].layer);
    var buffer: [128]u8 = undefined;
    try t.expectEqualStrings("Layer 912: Navigation", label(out[0], doc, &buffer));
    const callbacks = search(doc, .tap, .callback, "", &out);
    try t.expectEqual(@as(usize, 2), callbacks);
    try t.expectEqual(@as(u8, 3), out[0].callback);
    try t.expectEqual(@as(u8, 7), out[1].callback);
    try t.expectEqual(@as(usize, 0), search(doc, .tap, .layer, "", &out));
    try t.expectEqual(@as(usize, 0), search(doc, .hold, .all, "", out[0..0]));
    try t.expectEqual(@as(usize, 1), search(doc, .hold, .callback, "7", out[0..1]));
    try t.expectEqual(@as(u8, 7), out[0].callback);
    try t.expectEqual(@as(usize, 1), search(doc, .hold, .all, "show", &out));
    try t.expectEqual(@as(u8, 255), out[0].signal);
    try t.expectEqual(@as(usize, 3), search(doc, .hold, .signal, "", &out));
}

test "volume keys appear once, as media keys with their symbols" {
    const t = std.testing;
    const doc: p.Document = .{
        .schema_version = 1,
        .board_id = @splat(0),
        .profile_id = @splat(0),
        .physical_layout = "synthetic",
        .name = "Picker",
        .key_ids = &.{},
        .layers = &.{},
    };
    var out: [16]Entry = undefined;
    const found = search(doc, .tap, .all, "volu", &out);
    try t.expectEqual(@as(usize, 3), found);
    for (out[0..found]) |entry| try t.expect(entry == .media);
    var buffer: [64]u8 = undefined;
    const mute: Entry = .{ .media = .VolumeMute };
    try t.expectEqualStrings(labels.keycap_symbols.Symbol.literal(.mute) ++ " Mute", label(mute, doc, &buffer));
    try t.expectEqual(@as(usize, 1), search(doc, .tap, .all, "mute", &out));
}
