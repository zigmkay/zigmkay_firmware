//! Shared host/firmware build input; no processor or UI dependencies.
/// Version 2 keymaps set `custom_functions.companion_keymap_id`.
pub const version: u16 = 2;
pub const File = struct { path: []const u8, digest: [32]u8 };
pub const Callback = struct { entry: []const u8 };

pub const Manifest = struct {
    version: u16,
    snapshot_id: [32]u8,
    board_id: [8]u8,
    profile_id: [8]u8,
    keymap: []const u8,
    callbacks: []const Callback,
    files: []const File,
};
