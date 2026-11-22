//! The Zigmkay desktop editor and companion.
//!
//! Normal startup monitors connected keyboards. The offline modes and the
//! fixtures never open a device, and flashing always needs an explicit click.
const std = @import("std");
const App = @import("App.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const video_driver = std.c.getenv("SDL_VIDEODRIVER");
    const mode = try cli.parse(args, .{
        .flash_trial = init.environ_map.get("ZIGMKAY_EXPLICIT_FLASH_TRIAL"),
        .video_driver = if (video_driver) |driver| std.mem.span(driver) else null,
    });
    var app: App = undefined;
    try app.init(init, mode);
    defer app.deinit();
    try app.run();
}
