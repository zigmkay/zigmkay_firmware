//! Stable mapping fingerprint excludes transient refresh serials and names.
const std = @import("std");
const cache = @import("label_cache.zig");

pub fn mapping(labels: *const cache.LabelCache, source_id: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_id);
    var dimensions: [4]u8 = undefined;
    std.mem.writeInt(u16, dimensions[0..2], @intCast(labels.layer_count), .little);
    std.mem.writeInt(u16, dimensions[2..4], @intCast(labels.key_count), .little);
    hash.update(&dimensions);
    for (0..labels.layer_count) |layer| for (0..labels.key_count) |key| for (@import("practice.zig").route_modifiers) |mods| {
        const value = labels.lookup(layer, key, @bitCast(mods));
        const text = value.label orelse "";
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(text.len), .little);
        hash.update(&length);
        hash.update(text);
        hash.update(&.{
            @intFromBool(value.dead),
            @intFromBool(value.shortcut),
            @intFromBool(value.unproven),
        });
    };
    return hash.finalResult();
}
