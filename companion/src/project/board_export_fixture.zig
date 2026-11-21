//! Offline export of an existing curated project for the official LK7 board.
const std = @import("std");
const project = @import("keymap-project");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2 or args.len > 4) return error.Usage;
    const trigger = args.len == 4 and std.mem.eql(u8, args[3], "--overlay-trigger");
    if (args.len == 4 and !trigger) return error.Usage;
    var loaded = if (args.len >= 3) blk: {
        var source = try std.Io.Dir.cwd().openDir(init.io, args[2], .{});
        defer source.close(init.io);
        break :blk try project.snapshot.load(allocator, init.io, source, project.profiles.board);
    } else try project.profiles.create(allocator, .qwerty);
    defer loaded.deinit();
    if (trigger) {
        // Test-only copy: the base-layer W position is not part of the existing
        // Q/T combo. Keep every other assignment and all callback bytes intact.
        if (!std.mem.eql(u8, loaded.snapshot.document.key_ids[1], "lk7_0101")) return error.UnexpectedTriggerPosition;
        for (loaded.snapshot.document.combos) |combo| {
            for (combo.key_ids) |id| if (std.mem.eql(u8, id, "lk7_0101")) return error.TriggerPositionInCombo;
        }
        const layers = try allocator.dupe(project.Layer, loaded.snapshot.document.layers);
        const actions = try allocator.dupe(?project.Action, layers[0].actions);
        actions[1] = .{ .tap_only = .{ .key_press = .{ .tap_keycode = 0xFE } } };
        layers[0].actions = actions;
        var candidate = loaded.snapshot;
        candidate.document.layers = layers;
        candidate.document.profile_id = "ovrtest\x00".*;
        candidate.document.name = "Eurmac overlay trigger test";
        const changed = try project.snapshot.clone(allocator, candidate);
        loaded.deinit();
        loaded = changed;
    }
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    var directory = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer directory.close(init.io);
    try project.snapshot.save(allocator, init.io, directory, loaded.snapshot, project.profiles.board);
    var reopened = try project.snapshot.load(allocator, init.io, directory, project.profiles.board);
    defer reopened.deinit();
    const bytes = try project.exporter.generate(allocator, reopened.snapshot, project.profiles.board);
    try directory.writeFile(init.io, .{ .sub_path = "keymap.zig", .data = bytes });
}
