//! Reuse the inventory's firmware module ownership when consumers meet.
const defaults = @import("firmware-defaults");

const profile = blk: {
    for (defaults.boards.entries, 0..) |board, i| {
        if (@import("std").mem.eql(u8, board.name, "lk7")) break :blk defaults.profiles[i];
    }
    @compileError("Selected firmware inventory lacks LK7");
};

pub const keymap = profile.keymap;
pub const combos = profile.combos;
pub const sides = profile.sides;
pub const custom_functions = profile.custom_functions;
