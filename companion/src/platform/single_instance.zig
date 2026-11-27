//! One running application per Windows session. A second start would monitor
//! the same keyboard, show a second tray icon and share the same user data,
//! so it asks the running application to show its editor and exits instead.
//! A named auto-reset event is both the claim and the signal: the first start
//! creates it, later starts open the existing one and set it. Windows deletes
//! the event when the last handle closes, so a crashed application leaves no
//! stale claim. Other systems are not checked yet: `claim` always succeeds.
const std = @import("std");
const builtin = @import("builtin");

/// The event name of the application in the current session.
pub const application_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\org.zigmkay.companion.instance");

pub const Instance = struct {
    event: if (builtin.os.tag == .windows) ?std.os.windows.HANDLE else void = if (builtin.os.tag == .windows) null else {},

    /// Whether another start asked to show the editor since the last call.
    pub fn takeShowRequest(self: *Instance) bool {
        if (builtin.os.tag != .windows) return false;
        const event = self.event orelse return false;
        return win.WaitForSingleObject(event, 0) == win.wait_object_0;
    }

    pub fn release(self: *Instance) void {
        if (builtin.os.tag != .windows) return;
        if (self.event) |event| std.os.windows.CloseHandle(event);
        self.event = null;
    }
};

pub const Claim = union(enum) {
    /// This process is the application; keep the instance until exit.
    primary: Instance,
    /// Another process is; it was asked to show its editor if `show` was set.
    secondary,
};

/// Claims `name` for this process. A failure to create the event never
/// blocks startup: the process then runs as the primary without a claim.
pub fn claim(name: [*:0]const u16, show: bool) Claim {
    if (builtin.os.tag != .windows) return .{ .primary = .{} };
    const event = win.CreateEventW(null, .FALSE, .FALSE, name) orelse return .{ .primary = .{} };
    if (std.os.windows.GetLastError() != .ALREADY_EXISTS) return .{ .primary = .{ .event = event } };
    if (show) {
        // Lets the running application bring its editor to the foreground.
        _ = win.AllowSetForegroundWindow(win.asfw_any);
        _ = win.SetEvent(event);
    }
    std.os.windows.CloseHandle(event);
    return .secondary;
}

const win = struct {
    const windows = std.os.windows;
    const wait_object_0: u32 = 0;
    const asfw_any: u32 = std.math.maxInt(u32);

    extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: windows.BOOL, initial_state: windows.BOOL, name: [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: u32) callconv(.winapi) u32;
    extern "user32" fn AllowSetForegroundWindow(process_id: u32) callconv(.winapi) windows.BOOL;
};

test "a second claim signals the first and the request is taken once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // A name of its own, so the test never meets a running application.
    var buffer: [96]u8 = undefined;
    var random: u64 = undefined;
    try std.Io.randomSecure(std.testing.io, std.mem.asBytes(&random));
    const utf8 = try std.fmt.bufPrint(&buffer, "Local\\org.zigmkay.companion.test-{x}", .{random});
    const name = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, utf8);
    defer std.testing.allocator.free(name);

    var first = claim(name, true);
    try std.testing.expect(first == .primary);
    defer first.primary.release();
    try std.testing.expect(!first.primary.takeShowRequest());

    try std.testing.expect(claim(name, false) == .secondary);
    try std.testing.expect(!first.primary.takeShowRequest());

    try std.testing.expect(claim(name, true) == .secondary);
    try std.testing.expect(first.primary.takeShowRequest());
    try std.testing.expect(!first.primary.takeShowRequest());
}

test "the claim ends with its holder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\org.zigmkay.companion.test-release");
    var first = claim(name, false);
    try std.testing.expect(first == .primary);
    first.primary.release();
    var again = claim(name, false);
    try std.testing.expect(again == .primary);
    again.primary.release();
}
