//! Host presentation only. Display hands never supply processor sides.
const std = @import("std");

pub const Metadata = struct {
    name: []const u8,
    revision: []const u8,
    template: []const u8,
    host_layout: []const u8,
    encoders: usize = 0,
};

pub fn metadata(comptime selector: []const u8) Metadata {
    if (std.mem.eql(u8, selector, "molekula")) {
        return .{
            .name = "Molekula",
            .revision = "38-key",
            .template = "QWERTY",
            .host_layout = "US International",
        };
    }
    if (std.mem.eql(u8, selector, "dasbob")) {
        return .{
            .name = "Dasbob",
            .revision = "36-key",
            .template = "Danish",
            .host_layout = "Danish",
        };
    }
    if (std.mem.eql(u8, selector, "tuckytwotimes")) {
        return .{
            .name = "Tucky Two Times",
            .revision = "30-key",
            .template = "Rollercole",
            .host_layout = "Danish",
            .encoders = 2,
        };
    }
    if (std.mem.startsWith(u8, selector, "clacky")) {
        return .{
            .name = "Clacky Chan",
            .revision = "30-key",
            .template = if (std.mem.eql(u8, selector, "clacky_chan")) "Rollercole" else "Colemak",
            .host_layout = if (std.mem.eql(u8, selector, "clacky_chan")) "Danish" else "US International",
        };
    }
    if (std.mem.startsWith(u8, selector, "keycaprio")) {
        return .{
            .name = "Keycaprio",
            .revision = if (std.mem.endsWith(u8, selector, "0_4")) "0.4" else if (std.mem.endsWith(u8, selector, "0_6")) "0.6" else "0.7",
            .template = if (std.mem.indexOf(u8, selector, "us_intl") != null) "US International" else "Colemak",
            .host_layout = "US International",
        };
    }
    if (std.mem.eql(u8, selector, "lk1")) {
        return .{
            .name = "Leonardo Keycaprio",
            .revision = "0.1 (LK1)",
            .template = "Rollercole",
            .host_layout = "Danish",
        };
    }
    if (std.mem.eql(u8, selector, "lk2")) {
        return .{
            .name = "Leonardo Keycaprio",
            .revision = "0.2 (LK2)",
            .template = "Rollercole",
            .host_layout = "Danish",
        };
    }
    if (std.mem.eql(u8, selector, "lk6")) {
        return .{
            .name = "Leonardo Keycaprio",
            .revision = "0.6 (LK6)",
            .template = "Rollercole",
            .host_layout = "Danish",
        };
    }
    if (std.mem.eql(u8, selector, "lk7")) {
        return .{
            .name = "Leonardo Keycaprio",
            .revision = "0.7 (LK7)",
            .template = "Rollercole",
            .host_layout = "Danish",
        };
    }
    if (std.mem.eql(u8, selector, "lk8")) {
        return .{
            .name = "Leonardo Keycaprio",
            .revision = "0.8 (LK8)",
            .template = "Rollercole",
            .host_layout = "Danish",
        };
    }
    @compileError("Missing catalog presentation");
}
