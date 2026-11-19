const std = @import("std");
const zigmkay = @import("zigmkay");
test {
    std.testing.refAllDecls(zigmkay.core);
    std.testing.refAllDecls(zigmkay.combo);
    //std.testing.refAllDecls(zigmkay.encoder);
    std.testing.refAllDecls(zigmkay.generic_queue);
    //std.testing.refAllDecls(zigmkay.loops);
    std.testing.refAllDecls(zigmkay.macros);
    //std.testing.refAllDecls(zigmkay.matrix_scanning);
    std.testing.refAllDecls(zigmkay.processing);
}
