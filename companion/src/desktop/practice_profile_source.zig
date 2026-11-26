//! Derives the Tutor's `LayoutProfile` from a project document: board
//! geometry, translated key labels and the combos that produce one character.
const std = @import("std");
const project = @import("project");
const physical_layout = @import("layout-model").physical_layout;
const label_cache = @import("label_cache.zig");
const lp = @import("practice_layout_profile.zig");

pub const Board = struct {
    geometry: []const physical_layout.Key,
    fidelity: lp.Fidelity,
};

/// `translator` turns key codes into host text, as for the label cache.
pub fn derive(
    board: Board,
    labels: *const label_cache.LabelCache,
    doc: project.Document,
    translator: anytype,
    host_layout: []const u8,
) !lp.LayoutProfile {
    var geo_buf: [lp.max_keys]lp.GeometryKey = undefined;
    const key_count = @min(board.geometry.len, lp.max_keys);
    for (board.geometry[0..key_count], 0..) |g, i| {
        geo_buf[i] = .{
            .key_index = g.key_index,
            .x = g.x,
            .y = g.y,
            .width = g.width,
            .height = g.height,
            .rotation = g.rotation,
            .hand = switch (g.hand) {
                .left => .left,
                .right => .right,
                .neutral => .neutral,
            },
            .group = switch (g.group) {
                .finger => .finger,
                .thumb => .thumb,
            },
            .home_row = g.home_row,
        };
    }

    var combo_buf: [lp.max_combos]lp.ComboInput = undefined;
    var combo_len: usize = 0;
    for (doc.combos) |combo| {
        if (combo_len >= combo_buf.len) break;
        const k0 = project.keyIndex(doc, combo.key_ids[0]) catch continue;
        const k1 = project.keyIndex(doc, combo.key_ids[1]) catch continue;
        const layer_idx = project.layerIndex(doc, combo.layer_id) catch continue;
        const lowered = project.lowerAction(doc, combo.action) catch continue;

        var buf: [64]u8 = undefined;
        const content = label_cache.computeKeyContent(translator, lowered, .{}, &buf);

        var out_cp: ?u21 = null;
        if (!content.unproven and !content.dead and !content.shortcut) {
            if (content.hid_code) |code| {
                if (code == 44) out_cp = ' ';
            }
            if (out_cp == null) {
                if (content.label) |lbl| {
                    if (lbl.len > 0) {
                        const seq = std.unicode.utf8ByteSequenceLength(lbl[0]) catch 0;
                        if (seq == lbl.len) {
                            out_cp = std.unicode.utf8Decode(lbl) catch null;
                        }
                    }
                }
            }
        }
        if (out_cp != null) {
            combo_buf[combo_len] = .{
                .layer = layer_idx,
                .key_indices = .{ k0, k1 },
                .output_cp = out_cp,
                .unproven = content.unproven,
                .dead = content.dead,
                .shortcut = content.shortcut,
            };
            combo_len += 1;
        }
    }

    return lp.derive(geo_buf[0..key_count], labels.practiceLabels(), .{
        .host_layout = host_layout,
        .fidelity = board.fidelity,
        .combos = combo_buf[0..combo_len],
    });
}
