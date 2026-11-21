const std = @import("std");
const hid = @import("native-hid");

const Sdl = struct {
    pub const SDL_hid_device = opaque {};
    pub const SDL_HINT_HIDAPI_ENUMERATE_ONLY_CONTROLLERS: [*:0]const u8 = "HID_ENUMERATE_ONLY_CONTROLLERS";

    const Info = extern struct {
        usage_page: u16 = 0xFF31,
        usage: u16 = 0x0074,
        path: [*c]const u8 = "a",
        next: [*c]Info = null,
    };

    var a: Info = .{};
    var b: Info = .{ .path = "b" };
    var empty = false;
    var hint = true;
    var open_ok = true;
    var opens: usize = 0;
    var closes: usize = 0;
    var enumerations: usize = 0;
    var frees: usize = 0;
    var read_count: c_int = 0;
    var write_count: c_int = 33;
    var written: [33]u8 = @splat(0);

    fn reset() void {
        a = .{};
        b = .{ .path = "b" };
        empty = false;
        hint = true;
        open_ok = true;
        opens = 0;
        closes = 0;
        enumerations = 0;
        frees = 0;
        read_count = 0;
        write_count = 33;
    }

    pub fn SDL_SetHint(_: [*:0]const u8, value: [*:0]const u8) bool {
        std.debug.assert(std.mem.eql(u8, std.mem.span(value), "0"));
        return hint;
    }

    pub fn SDL_hid_enumerate(vendor: u16, product: u16) [*c]Info {
        std.debug.assert(vendor == 0xFAFA and product == 0x00F0);
        enumerations += 1;
        return if (empty) null else &a;
    }

    pub fn SDL_hid_free_enumeration(_: [*c]Info) void {
        frees += 1;
    }

    pub fn SDL_hid_open_path(_: [*:0]const u8) ?*SDL_hid_device {
        opens += 1;
        return if (open_ok) @ptrFromInt(16) else null;
    }

    pub fn SDL_hid_read_timeout(_: *SDL_hid_device, _: *[33]u8, _: usize, timeout: c_int) c_int {
        std.debug.assert(timeout == 0);
        return read_count;
    }

    pub fn SDL_hid_write(_: *SDL_hid_device, data: [*]const u8, length: usize) c_int {
        std.debug.assert(length == 33);
        @memcpy(&written, data[0..33]);
        return write_count;
    }

    pub fn SDL_hid_close(_: *SDL_hid_device) void {
        closes += 1;
    }
};

test "native construction is offline and discovery selects only the exact vendor collection" {
    Sdl.reset();
    var native = hid.Native(Sdl){ .io = std.testing.io };
    try std.testing.expectEqual(@as(usize, 0), Sdl.enumerations);
    Sdl.a.next = &Sdl.b;
    try std.testing.expectEqual(.multiple_devices, try native.discover(null));
    try std.testing.expectEqual(@as(usize, 0), Sdl.opens);
    try std.testing.expectEqual(.path_not_found, try native.discover("missing"));
    try std.testing.expectEqual(.selected, try native.discover("b"));
    try std.testing.expectEqual(@as(usize, 3), Sdl.frees);
    native.close();
    native.close();
    try std.testing.expectEqual(@as(usize, 1), Sdl.closes);
    Sdl.a.next = null;
    Sdl.a.usage_page = 1;
    try std.testing.expectEqual(.no_device, try native.discover(null));
}

test "native hint open read and write failures remain explicit" {
    Sdl.reset();
    var native = hid.Native(Sdl){ .io = std.testing.io };
    Sdl.hint = false;
    try std.testing.expectError(error.HidEnumerationHintRejected, native.discover(null));
    try std.testing.expectEqual(@as(usize, 0), Sdl.enumerations);
    Sdl.hint = true;
    Sdl.open_ok = false;
    try std.testing.expectError(error.HidOpenFailed, native.discover(null));
    Sdl.open_ok = true;
    _ = try native.discover(null);
    var bytes: [33]u8 = @splat(0);
    try std.testing.expectEqual(@as(usize, 0), try native.read(&bytes));
    for ([_]c_int{ -1, 34 }) |count| {
        Sdl.read_count = count;
        try std.testing.expectError(error.HidReadFailed, native.read(&bytes));
    }
    for ([_]c_int{ -1, 0, 32, 34 }) |count| {
        Sdl.write_count = count;
        try std.testing.expectError(error.HidWriteFailed, native.write(&bytes));
    }
    Sdl.write_count = 33;
    bytes[1] = 0x5a;
    try native.write(&bytes);
    try std.testing.expectEqual(bytes, Sdl.written);
    native.close();
    try std.testing.expectError(error.HidNotOpen, native.read(&bytes));
}
