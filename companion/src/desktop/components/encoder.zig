//! A round encoder indicator showing the last action's caption.
const dvui = @import("dvui");
const key_component = @import("key.zig");
const desktop = @import("desktop-core");
const cache = desktop.label_cache;
const core = @import("layout-model");
const Modifiers = core.Modifiers;

pub const EncoderComponent = struct {
    instance_id: usize = 5000,
    state: desktop.encoder_state.State = .{},

    pub fn handleSignal(self: *EncoderComponent, action_index: usize, action_count: usize, now_ms: u64) !void {
        try self.state.observe(action_index, action_count, now_ms);
    }

    pub fn reset(self: *EncoderComponent) void {
        self.state = .{};
    }

    pub fn draw(
        self: *const EncoderComponent,
        current_layer: usize,
        label_cache: *const cache.EncoderCache,
        physical_mods: Modifiers,
        now_ms: u64,
        center_x: f32,
        y: f32,
        size: f32,
        scale: f32,
    ) !void {
        const active = self.state.active(now_ms);
        const radius = size / 2.0;
        const x = center_x - radius;

        const layer_color = if (current_layer < key_component.layer_colors.len)
            key_component.layer_colors[current_layer]
        else
            dvui.Color.white;
        const muted_layer_color = key_component.getMutedColor(layer_color);
        const text_color = dvui.Color.white;

        var b = dvui.box(@src(), .{}, .{
            .id_extra = self.instance_id,
            .rect = .{ .x = x, .y = y, .w = size, .h = size },
            .background = true,
            .color_fill = .{ .color = if (active) muted_layer_color else dvui.Color.black },
            .color_border = .{ .color = if (active) layer_color else muted_layer_color },
            .border = dvui.Rect.all(1.5 * scale),
            .corners = .all(radius),
        });
        defer b.deinit();

        const index = self.state.last_action_index orelse return;
        const entry = label_cache.lookup(index, physical_mods) catch return;
        if (entry.icon) |icon_bytes| {
            dvui.icon(@src(), entry.icon_name, icon_bytes, .{}, .{
                .id_extra = 1,
                .color_text = .{ .color = text_color },
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = size * 0.5, .h = size * 0.5 },
            });
        } else if (entry.label orelse entry.caption) |l| {
            dvui.label(@src(), "{s}", .{l}, .{
                .id_extra = 1,
                .color_text = .{ .color = text_color },
                .font = dvui.Font.theme(.body).larger(2),
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });
        }
    }
};
