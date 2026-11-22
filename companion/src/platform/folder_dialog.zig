//! SDL's retained asynchronous native folder dialog. Callback storage has process
//! lifetime, so late cancellation cannot write into a destroyed editor instance.
const std = @import("std");
const sdl = @import("sdl3-c");
var busy = std.atomic.Value(bool).init(false);
var done = std.atomic.Value(bool).init(false);
var result: [4096]u8 = @splat(0);
var failed = false;
var token: u64 = 0;
pub const Completion = struct { token: u64, path: anyerror![4096]u8 };

fn selected(_: ?*anyopaque, paths: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    result = @splat(0);
    failed = paths == null;
    if (paths != null and paths[0] != null) {
        const path = std.mem.span(@as([*:0]const u8, @ptrCast(paths[0])));
        if (path.len >= result.len) failed = true else @memcpy(result[0..path.len], path);
    }
    done.store(true, .release);
}

pub fn start(window: *sdl.SDL_Window) !void {
    return startCorrelated(window, 0);
}

/// UI-thread entry point; the singleton remains busy until its callback is drained.
pub fn startCorrelated(window: *sdl.SDL_Window, request_token: u64) !void {
    if (busy.swap(true, .acq_rel)) return error.DialogAlreadyOpen;
    token = request_token;
    done.store(false, .release);
    sdl.SDL_ShowOpenFolderDialog(selected, null, window, null, false);
}

pub fn poll() ?anyerror![1024]u8 {
    const completion = pollCorrelated() orelse return null;
    const path = try completion.path;
    const len = std.mem.sliceTo(&path, 0).len;
    if (len >= 1024) return error.NativeDialogFailed;
    var legacy: [1024]u8 = @splat(0);
    @memcpy(legacy[0..len], path[0..len]);
    return legacy;
}

/// Poll on the UI thread. Empty paths mean user cancellation; failures are errors.
pub fn pollCorrelated() ?Completion {
    if (!busy.load(.acquire) or !done.load(.acquire)) return null;
    const completion = Completion{ .token = token, .path = if (failed) error.NativeDialogFailed else result };
    busy.store(false, .release);
    return completion;
}

pub fn active() bool {
    return busy.load(.acquire);
}
