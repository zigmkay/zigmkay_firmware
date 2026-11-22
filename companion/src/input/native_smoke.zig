//! Compile/link only. Default checks never execute this entry point.
const keymap = @import("zkeymap");
const source = @import("input-source");

pub fn main() !void {
    var map: keymap.KeyMap = undefined;
    keymap.KeyMap.init(&map);
    defer map.deinit();
    map.refresh();
    _ = map.keyToText(.{ .tap_keycode = 4 });
    var labels = source.Source.init();
    defer labels.deinit();
    _ = labels.refresh();
    _ = labels.id();
    _ = labels.layoutId();
    _ = labels.keyToText(.{ .tap_keycode = 4 });
    var session = source.Session.init();
    defer session.deinit();
    session.reset();
    _ = session.refresh();
    _ = session.eurkey();
    var output: [128]u8 = undefined;
    _ = session.translate(.{ .tap_keycode = 4 }, &output) catch return;
}
