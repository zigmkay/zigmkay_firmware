//! Recent key events, newest first, in three columns.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const project = @import("project");
const core = @import("layout-model");
const key_component = @import("key.zig");
const Modifiers = core.Modifiers;
const LogMessage = desktop.event_history.KeyEvent;
const LabelCache = desktop.label_cache.LabelCache;

pub const TimedLogMessage = desktop.event_history.TimedLogMessage;

const gray = dvui.Color{ .r = 150, .g = 150, .b = 150, .a = 255 };

pub const LogComponent = struct {
    history: desktop.event_history.History = .{},

    /// Record an already validated protocol event on the UI thread.
    pub fn record(self: *LogComponent, log_msg: LogMessage, now: i64) void {
        self.history.record(log_msg, now);
    }

    /// Renders the event ring buffer list UI inside the application loop.
    pub fn draw(self: *LogComponent, document: project.Document, labels: *const LabelCache, center_x: f32, start_y: f32, scale: f32) !void {
        const safe_log_y = @max(10.0 * scale, start_y - (160.0 * scale));
        const safe_log_h = @max(80, @min(160.0 * scale, start_y - 20.0 * scale));
        const ui_w = 600.0 * scale;
        var log_box = dvui.box(@src(), .{}, .{
            .rect = .{ .x = center_x - ui_w / 2.0, .y = safe_log_y, .w = ui_w, .h = safe_log_h },
            .background = true,
            .color_fill = .{ .color = .{ .r = 20, .g = 20, .b = 20, .a = 240 } },
            .color_border = .{ .color = .{ .r = 80, .g = 80, .b = 80, .a = 255 } },
            .border = dvui.Rect.all(1.0 * scale),
            .corners = .all(4.0 * scale),
        });
        defer log_box.deinit();

        var log_col = dvui.box(@src(), .{}, .{ .expand = .both });
        defer log_col.deinit();

        dvui.label(@src(), "Recent Events (Log)", .{}, .{ .color_text = .{ .color = .{ .r = 200, .g = 200, .b = 200, .a = 255 } } });

        // Rows per column for the height below the 24-point header.
        const row_h = 24.0 * scale;
        const avail_h = safe_log_h - (24.0 * scale);
        var items_per_col = @as(usize, @intFromFloat(avail_h / row_h)) + 3;
        if (items_per_col == 0) items_per_col = 1;

        var columns_row = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .both });
        defer columns_row.deinit();

        for (0..3) |col_idx| {
            var col_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .id_extra = col_idx });
            defer col_box.deinit();
            for (0..items_per_col) |row_idx| {
                const j = (col_idx * items_per_col) + row_idx;
                const ev = self.history.newest(j) orelse continue;
                drawEvent(ev, j, document, labels, scale);
            }
        }
    }
};

fn drawEvent(ev: TimedLogMessage, j: usize, document: project.Document, labels: *const LabelCache, scale: f32) void {
    var time_buffer: [32]u8 = undefined;
    const time = std.fmt.bufPrint(&time_buffer, "[{d: >6} ms] ", .{ev.delta_ms}) catch "";
    var modifier_buffer: [64]u8 = undefined;
    var detail_buffer: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, " K{d: <3} ({s}){s}", .{
        ev.msg.key_index,
        keyName(ev.msg, document, labels),
        modifierText(ev.msg.modifiers, &modifier_buffer),
    }) catch "Err";
    const arrow_color = if (ev.msg.pressed)
        dvui.Color{ .r = 100, .g = 250, .b = 100, .a = 255 }
    else
        dvui.Color{ .r = 250, .g = 100, .b = 100, .a = 255 };
    const layer_color = if (ev.msg.layer < key_component.layer_colors.len) key_component.layer_colors[ev.msg.layer] else dvui.Color.white;
    var row_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = j,
        .color_border = .{ .color = layer_color },
        .border = dvui.Rect.all(1.0 * scale),
        .corners = .all(2.0 * scale),
        .margin = dvui.Rect.all(1.0 * scale),
    });
    defer row_box.deinit();
    dvui.label(@src(), "{s}", .{time}, .{ .color_text = .{ .color = gray }, .font = dvui.Font.theme(.mono) });
    dvui.label(
        @src(),
        "{s}",
        .{if (ev.msg.pressed) "[+]" else "[-]"},
        .{ .color_text = .{ .color = arrow_color }, .font = dvui.Font.theme(.mono) },
    );
    dvui.label(@src(), "{s}", .{detail}, .{ .color_text = .{ .color = gray }, .font = dvui.Font.theme(.mono) });
}

/// The cached caption of the key's tap key press, or "???" for other keys.
fn keyName(msg: LogMessage, document: project.Document, labels: *const LabelCache) []const u8 {
    const valid = msg.key_index < document.key_ids.len and msg.layer < document.layers.len and
        msg.key_index < document.layers[msg.layer].actions.len and msg.key_index < labels.key_count and
        msg.layer < labels.layer_count;
    if (!valid) return "???";
    const key_press = switch (document.layers[msg.layer].actions[msg.key_index] orelse .none) {
        .tap_only => |t| t.key_press,
        .tap_hold => |th| th.tap.key_press,
        .tap_with_autofire => |af| af.tap.key_press,
        else => null,
    };
    if (key_press == null) return "???";
    const cached = labels.lookup(msg.layer, msg.key_index, msg.modifiers);
    const name = cached.label orelse cached.icon_name;
    return if (name.len < 32) name else "???";
}

/// Held modifiers as " [CtrlL ShiftR]", or "" when none are held.
fn modifierText(mods: Modifiers, buffer: *[64]u8) []const u8 {
    if (@as(u8, @bitCast(mods)) == 0) return "";
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll(" [") catch {};
    const names = .{
        .{ "left_ctrl", "CtrlL" },   .{ "right_ctrl", "CtrlR" },
        .{ "left_shift", "ShiftL" }, .{ "right_shift", "ShiftR" },
        .{ "left_alt", "AltL" },     .{ "right_alt", "AltR" },
        .{ "left_gui", "GuiL" },     .{ "right_gui", "GuiR" },
    };
    inline for (names) |entry| {
        if (@field(mods, entry[0])) writer.writeAll(entry[1] ++ " ") catch {};
    }
    const len = writer.end;
    if (len > 2 and buffer[len - 1] == ' ') {
        buffer[len - 1] = ']';
        return buffer[0..len];
    }
    writer.writeAll("]") catch {};
    return writer.buffered();
}
