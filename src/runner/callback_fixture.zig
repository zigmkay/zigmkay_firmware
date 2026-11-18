const core = @import("zigmkay").core;
var count: u8 = 0;
fn onEvent(event: core.ProcessorEvent, layers: *core.LayerActivations, queue: *core.OutputCommandQueue) void {
    switch (event) {
        .OnTapEnterAfter => |data| if (data.tap.custom == 1) {
            count += 1;
            queue.tap_key(.{ .tap_keycode = 4 + count }) catch {};
        },
        .OnHoldEnterAfter => |data| if (data.hold.custom == 2) {
            layers.set_layer_state(1, true);
        },
        .OnHoldExitAfter => |data| if (data.hold.custom == 2) {
            layers.set_layer_state(1, false);
        },
        else => {},
    }
}
pub const custom_functions = core.CustomFunctions{ .on_event = onEvent };
