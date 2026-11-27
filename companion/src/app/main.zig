//! The Zigmkay desktop editor and companion.
//!
//! Normal startup monitors connected keyboards. The offline modes and the
//! fixtures never open a device, and flashing always needs an explicit click.
const std = @import("std");
const App = @import("App.zig");
const cli = @import("cli.zig");
const single_instance = @import("single-instance");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const video_driver = std.c.getenv("SDL_VIDEODRIVER");
    const mode = try cli.parse(args, .{
        .flash_trial = init.environ_map.get("ZIGMKAY_EXPLICIT_FLASH_TRIAL"),
        .video_driver = if (video_driver) |driver| std.mem.span(driver) else null,
    });
    // Only the editor modes claim the session; fixtures run side by side.
    var instance: ?single_instance.Instance = null;
    if (mode == .editor) switch (single_instance.claim(single_instance.application_name, !mode.background())) {
        .primary => |claimed| instance = claimed,
        .secondary => {
            std.log.info("Zigmkay is already running in this session", .{});
            return;
        },
    };
    defer if (instance) |*claimed| claimed.release();
    var app: App = undefined;
    try app.init(init, mode);
    defer app.deinit();
    if (instance) |*claimed| app.instance = claimed;
    try app.run();
}
