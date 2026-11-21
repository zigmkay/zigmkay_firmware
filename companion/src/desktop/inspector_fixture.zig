//! Fixed visual fixture. Native captures never compile or execute source bytes.
const std = @import("std");
const p = @import("project");

pub fn setup(model: anytype) !void {
    model.layer = 1;
    try model.apply(.{ .tap_hold = .{
        .tap = .{ .key_press = .{ .tap_keycode = 4 } },
        .hold = .{ .hold_modifiers = .{ .left_gui = true } },
        .tapping_term = .{ .ms = 180 },
    } });
    const bytes = "const core = @import(\"zigmkay\").core;\npub const custom_functions = core.CustomFunctions{};\n";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const metadata = [_]p.Source{.{ .path = "callbacks.zig", .digest = digest }};
    const callbacks = [_]p.Callback{.{
        .kind = .attached,
        .binding = "callbacks.zig",
        .ids = &.{1},
        .sources = &metadata,
    }};
    const sources = [_]p.snapshot.SourceBytes{.{
        .callback_index = 0,
        .path = "callbacks.zig",
        .bytes = bytes,
    }};
    var snapshot = model.current.snapshot;
    snapshot.document.callbacks = &callbacks;
    snapshot.sources = &sources;
    try model.commit(snapshot);
    model.saved_id = try model.id();
}
