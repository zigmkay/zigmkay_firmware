pub const Fixture = struct {
    pub fn keyToText(_: *@This(), input: @import("zkeymap").KeyCodeFire) @import("zkeymap").TextResult {
        var result: @import("zkeymap").TextResult = .{};
        const code = input.tap_keycode;
        if (code >= 4 and code <= 29) {
            result.data[0] = (if (input.tap_modifiers.left_shift or input.tap_modifiers.right_shift) @as(u8, 'A') else 'a') + code - 4;
            result.len = 1;
        } else if (code >= 30 and code <= 39) {
            result.data[0] = (if (input.tap_modifiers.left_shift or input.tap_modifiers.right_shift) "!@#$%^&*()" else "1234567890")[code - 30];
            result.len = 1;
        } else if (code == 44) {
            result.data[0] = ' ';
            result.len = 1;
        } else if (code >= 45 and code <= 56) {
            result.data[0] = (if (input.tap_modifiers.left_shift or input.tap_modifiers.right_shift) "_+{}|~:\"~<>?" else "-=[]\\#;'`,./")[code - 45];
            result.len = 1;
        }
        return result;
    }
};
