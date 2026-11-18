//! Reviewable fixed seed samples; this utility performs no acquisition or device I/O.
const std = @import("std");
const generator = @import("generator");

pub fn main() !void {
    std.debug.print("Curated base entries: {d}\n", .{generator.vocabulary.len});
    for ([_]generator.Preset{ .words, .mixed_case, .punctuation }) |preset| for (0..3) |length| {
        var buffer: [8192]u8 = undefined;
        const text = try generator.generate(&buffer, .{
            .seed = 42,
            .preset = preset,
            .length = @intCast(length),
        }, &.{});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
        std.debug.print("\n{t}/{d} · {d} chars · {s}\n{s}\n", .{
            preset,
            length,
            text.len,
            std.fmt.bytesToHex(hash, .lower),
            text,
        });
    };
}
