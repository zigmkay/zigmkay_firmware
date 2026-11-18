//! Path syntax shared by project validation and build-time export selection.
const std = @import("std");

pub fn valid(path: []const u8, max_bytes: usize) bool {
    if (path.len == 0 or path.len > max_bytes or path[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |byte| {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
        }
    }
    return true;
}
