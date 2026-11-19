//! The editor font: Inter, embedded so that every host renders the same text,
//! with a real bold face. macOS additionally reads Arial Unicode locally as a
//! fallback for code points Inter lacks; it is never copied or bundled.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const sans = "Editor Sans";
/// Fallback for code points the editor font cannot render.
const unicode = "Editor Unicode";

const regular_bytes = @embedFile("inter-regular");
/// SemiBold reads better than Bold at editor sizes; it serves bold requests.
const bold_bytes = @embedFile("inter-semibold");

/// Registers the editor fonts in the current window. Safe to call again.
pub fn install(gpa: std.mem.Allocator, io: std.Io) !void {
    const window = dvui.currentWindow();
    if (!available(sans)) {
        try window.addFont(sans, regular_bytes, null);
        try window.fonts.database.append(window.gpa, .{
            .family = dvui.Font.array(sans),
            .weight = .bold,
            .bytes = bold_bytes,
        });
    }
    if (builtin.os.tag != .macos or available(unicode)) return;
    const path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(32 * 1024 * 1024)) catch return;
    window.addFont(unicode, bytes, gpa) catch gpa.free(bytes);
}

fn available(name: []const u8) bool {
    return availableIn(dvui.currentWindow(), name);
}

fn availableIn(window: *const dvui.Window, name: []const u8) bool {
    for (window.fonts.database.items) |source| {
        if (std.mem.eql(u8, std.mem.sliceTo(&source.family, 0), name)) return true;
    }
    return false;
}

/// The editor font at `size`, switching to the Unicode fallback when `text`
/// contains a code point the primary font lacks.
pub fn font(text: []const u8, size: f32) dvui.Font {
    var selected = dvui.Font.find(.{ .family = if (available(sans)) sans else "Vera Sans", .size = size * 0.76 });
    if (available(unicode)) {
        const entry = dvui.fontCacheGet(selected) catch return selected;
        var iterator = (std.unicode.Utf8View.init(text) catch return selected).iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            // Keycap symbols live in the Private Use Area and are drawn as icons.
            if (codepoint >= 0xE000 and codepoint <= 0xF8FF) continue;
            if (dvui.c.FT_Get_Char_Index(entry.face, codepoint) == 0) {
                selected = selected.withFamily(unicode);
                break;
            }
        }
    }
    return selected;
}

/// `base` with its text fonts in the editor family, so widgets drawn without
/// an explicit font match the rest of the editor. Unchanged until `install`
/// registered the family in `window`.
pub fn theme(window: *const dvui.Window, base: dvui.Theme) dvui.Theme {
    if (!availableIn(window, sans)) return base;
    var result = base;
    result.font_body = result.font_body.withFamily(sans);
    result.font_heading = result.font_heading.withFamily(sans);
    result.font_title = result.font_title.withFamily(sans);
    return result;
}
