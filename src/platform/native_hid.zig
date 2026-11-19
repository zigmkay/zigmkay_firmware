// SPDX-License-Identifier: GPL-2.0-or-later
//! Adapted from zigmkay_firmware 3ee4135d308f18f15cc51b1d73e33e1b36bf517f,
//! zigmkay-companion/src/main.zig. SDL bindings are supplied by the desktop.
const std = @import("std");
const adapter = @import("live-adapter");

/// Construction is offline. Discovery/open/read/write require an explicit caller.
/// No SDL dependency or device operation is part of this module's default build.
pub fn Native(comptime sdl: type) type {
    return struct {
        const Self = @This();
        io: std.Io,
        device: ?*sdl.SDL_hid_device = null,
        hint_prepared: bool = false,
        paths: [8][512:0]u8 = undefined,
        path_lengths: [8]usize = @splat(0),
        path_count: usize = 0,

        pub fn now(self: *Self) u64 {
            return @intCast(std.Io.Clock.awake.now(self.io).toMilliseconds());
        }

        pub fn discover(self: *Self, requested: ?[]const u8) !adapter.Discovery {
            if (self.device != null) return error.HidAlreadyOpen;
            if (!self.hint_prepared) {
                if (!sdl.SDL_SetHint(sdl.SDL_HINT_HIDAPI_ENUMERATE_ONLY_CONTROLLERS, "0"))
                    return error.HidEnumerationHintRejected;
                self.hint_prepared = true;
            }
            const devices = sdl.SDL_hid_enumerate(0xFAFA, 0x00F0);
            defer sdl.SDL_hid_free_enumeration(devices);
            self.path_count = 0;
            var count: usize = 0;
            var selected: ?[*:0]const u8 = null;
            var device = devices;
            while (device != null) : (device = device.*.next) {
                if (device.*.usage_page != 0xFF31 or device.*.usage != 0x0074 or device.*.path == null) continue;
                count += 1;
                const path = std.mem.span(device.*.path);
                if (self.path_count < self.paths.len and path.len < self.paths[0].len) {
                    @memcpy(self.paths[self.path_count][0..path.len], path);
                    self.paths[self.path_count][path.len] = 0;
                    self.path_lengths[self.path_count] = path.len;
                    self.path_count += 1;
                }
                if (requested) |wanted| {
                    if (std.mem.eql(u8, wanted, path)) selected = device.*.path;
                } else selected = device.*.path;
            }
            if (requested != null and selected == null) return .path_not_found;
            if (requested == null and count > 1) return .multiple_devices;
            if (selected) |path| {
                self.device = sdl.SDL_hid_open_path(path) orelse return error.HidOpenFailed;
                return .selected;
            }
            return .no_device;
        }

        pub fn read(self: *Self, bytes: *[33]u8) !usize {
            const device = self.device orelse return error.HidNotOpen;
            const count = sdl.SDL_hid_read_timeout(device, bytes, bytes.len, 0);
            if (count < 0 or count > bytes.len) return error.HidReadFailed;
            return @intCast(count);
        }

        pub fn write(self: *Self, bytes: []const u8) !void {
            const device = self.device orelse return error.HidNotOpen;
            const count = sdl.SDL_hid_write(device, bytes.ptr, bytes.len);
            if (count < 0 or count != bytes.len) return error.HidWriteFailed;
        }

        pub fn close(self: *Self) void {
            if (self.device) |device| _ = sdl.SDL_hid_close(device);
            self.device = null;
        }
    };
}
