//! Host presentation only. Display hands never supply processor sides.
//! Selectors that share a name and revision are one keyboard with several
//! templates; the revision tells their wiring apart when building firmware.
const std = @import("std");

pub const Metadata = struct {
    name: []const u8,
    revision: []const u8,
    template: []const u8,
    host_layout: []const u8,
    encoders: usize = 0,
    /// The selector a keyboard opens with among those sharing its revision:
    /// the builder's own default keymap rather than a contributed one.
    primary: bool = true,
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
        const own = std.mem.eql(u8, selector, "clacky_chan");
        return .{
            .name = "Clacky Chan",
            .revision = "30-key",
            .template = if (own) "Rollercole" else "Colemak",
            .host_layout = if (own) "Danish" else "US International",
            .primary = own,
        };
    }
    // Contributed Leonardo Keycaprio keymaps, on the same PCB revisions.
    if (std.mem.startsWith(u8, selector, "keycaprio")) {
        return .{
            .name = "Leonardo Keycaprio",
            .revision = if (std.mem.endsWith(u8, selector, "0_4")) "0.4" else if (std.mem.endsWith(u8, selector, "0_6")) "0.6" else "0.7",
            .template = if (std.mem.indexOf(u8, selector, "us_intl") != null) "US International" else "Colemak",
            .host_layout = "US International",
            // PCB 0.4 has no Rollercole selector.
            .primary = std.mem.endsWith(u8, selector, "0_4"),
        };
    }
    const revisions = [_]struct { []const u8, []const u8 }{
        .{ "lk1", "0.1" }, .{ "lk2", "0.2" }, .{ "lk6", "0.6" }, .{ "lk7", "0.7" }, .{ "lk8", "0.8" },
    };
    inline for (revisions) |entry| if (comptime std.mem.eql(u8, selector, entry[0])) return .{
        .name = "Leonardo Keycaprio",
        .revision = entry[1],
        .template = "Rollercole",
        .host_layout = "Danish",
    };
    @compileError("Missing catalog presentation");
}

test "each keyboard revision opens with exactly one primary selector" {
    @setEvalBranchQuota(100_000);
    const boards = @import("firmware-defaults").boards;
    inline for (boards.entries) |board| {
        const own = comptime metadata(board.name);
        var primaries: usize = 0;
        inline for (boards.entries) |other| {
            const candidate = comptime metadata(other.name);
            if (std.mem.eql(u8, own.name, candidate.name) and
                std.mem.eql(u8, own.revision, candidate.revision) and candidate.primary) primaries += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), primaries);
    }
}
