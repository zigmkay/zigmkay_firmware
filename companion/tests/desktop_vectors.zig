//! Decode actual retained vector assets; no renderer or window required.
const std = @import("std");
const vectors = @import("svg2tvg");
const icons = @import("icons");
test "retained command volume and layer icons parse every drawing command" {
    for ([_][]const u8{ icons.tvg.lucide.command, icons.tvg.lucide.@"volume-2", icons.tvg.lucide.layers }) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        var parser = try vectors.tvg.parse(std.testing.allocator, &reader);
        defer parser.deinit();
        try std.testing.expect(parser.header.width > 0);
        try std.testing.expect(parser.header.height > 0);
        var commands: usize = 0;
        while (try parser.next()) |_| commands += 1;
        try std.testing.expect(commands > 0);
    }
}
