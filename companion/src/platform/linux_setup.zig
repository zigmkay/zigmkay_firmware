//! Linux desktop setup that no application bundle can carry: access to the
//! live keyboard (a udev rule, written as root) and a tray host.
//!
//! Granting access runs exactly `install_argv` with the bundled rule on stdin.
//! pkexec shows the desktop's own polkit password dialog, so the application
//! never sees the password, and nothing stays running as root afterwards.
const std = @import("std");

pub const rule_path = "/etc/udev/rules.d/70-zigmkay.rules";

/// Repository guide explaining why Linux needs a udev rule and how to install it manually.
pub const learn_more_url: [:0]const u8 = "https://github.com/zigmkay/zigmkay_firmware/blob/main/companion/docs/linux-permissions.md";

/// packaging/linux/70-zigmkay.rules, the same file the bundle ships, with
/// LF line ends even when a Windows checkout converted it to CRLF.
pub const udev_rule: []const u8 = lf: {
    @setEvalBranchQuota(100_000);
    const raw = @embedFile("udev-rule");
    var out: []const u8 = "";
    for (raw) |byte| {
        if (byte != '\r') out = out ++ .{byte};
    }
    break :lf out;
};

/// The command the access button runs. The rule arrives on stdin; tee
/// replaces the file, so repeating the grant is harmless.
pub const install_argv = [_][]const u8{ "pkexec", "tee", rule_path };

/// The rule without its comments: what users read before they confirm.
pub const effective_rule: []const u8 = effective: {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "";
    var lines = std.mem.tokenizeScalar(u8, udev_rule, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        out = out ++ line ++ "\n";
    }
    break :effective out;
};

/// The same installation for a terminal, for systems without polkit.
pub const manual_command: []const u8 = "echo '" ++ std.mem.trimEnd(u8, effective_rule, "\n") ++ "' \\\n  | sudo tee " ++ rule_path;

pub const Grant = struct {
    state: std.atomic.Value(State) = .init(.idle),
    thread: ?std.Thread = null,

    pub const State = enum(u8) {
        idle,
        /// pkexec is waiting for the password or writing the rule.
        running,
        /// The rule is installed; the keyboard must be plugged in again.
        installed,
        /// The password dialog was dismissed or authentication failed.
        cancelled,
        /// pkexec is not installed.
        unavailable,
        failed,
    };

    /// Starts the installation on a worker thread so the window keeps
    /// drawing while the password dialog is open.
    pub fn start(self: *Grant, io: std.Io) void {
        switch (self.state.load(.acquire)) {
            .running => return,
            else => {},
        }
        self.join();
        self.state.store(.running, .release);
        self.thread = std.Thread.spawn(.{}, run, .{ self, io }) catch {
            self.state.store(.failed, .release);
            return;
        };
    }

    pub fn current(self: *const Grant) State {
        return self.state.load(.acquire);
    }

    /// Waits for a running installation; call before the Grant goes away.
    pub fn join(self: *Grant) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn run(self: *Grant, io: std.Io) void {
        self.state.store(install(io), .release);
    }
};

fn install(io: std.Io) Grant.State {
    var child = std.process.spawn(io, .{
        .argv = &install_argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| return switch (err) {
        error.FileNotFound => .unavailable,
        else => .failed,
    };
    const stdin = child.stdin.?;
    child.stdin = null;
    const written = if (stdin.writeStreamingAll(io, udev_rule)) |_| true else |_| false;
    stdin.close(io);
    const term = child.wait(io) catch return .failed;
    if (!written) return .failed;
    return outcome(term);
}

/// pkexec exits with 126 when the dialog is dismissed and 127 when
/// authorization fails; any other failure belongs to the installation.
fn outcome(term: std.process.Child.Term) Grant.State {
    return switch (term) {
        .exited => |code| switch (code) {
            0 => .installed,
            126, 127 => .cancelled,
            else => .failed,
        },
        else => .failed,
    };
}

/// Whether a StatusNotifierWatcher (the tray host) owns its session bus name,
/// asked once through busctl, else gdbus, on a worker thread. This works with
/// any ztray, including builds whose tray backend is a stub.
pub const TrayProbe = struct {
    state: std.atomic.Value(State) = .init(.idle),
    thread: ?std.Thread = null,

    pub const State = enum(u8) { idle, running, present, absent, unknown };

    pub fn start(self: *TrayProbe, io: std.Io) void {
        if (self.state.load(.acquire) != .idle) return;
        self.state.store(.running, .release);
        self.thread = std.Thread.spawn(.{}, run, .{ self, io }) catch {
            self.state.store(.unknown, .release);
            return;
        };
    }

    /// true or false once answered; null before or when neither tool answers.
    pub fn result(self: *const TrayProbe) ?bool {
        return switch (self.state.load(.acquire)) {
            .present => true,
            .absent => false,
            else => null,
        };
    }

    pub fn join(self: *TrayProbe) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn run(self: *TrayProbe, io: std.Io) void {
        const answer = ask(io, &busctl_argv, parseBusctl) orelse ask(io, &gdbus_argv, parseGdbus);
        self.state.store(if (answer) |present| (if (present) .present else .absent) else .unknown, .release);
    }
};

const watcher = "org.kde.StatusNotifierWatcher";
const busctl_argv = [_][]const u8{ "busctl", "--user", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", watcher };
const gdbus_argv = [_][]const u8{ "gdbus", "call", "--session", "--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.NameHasOwner", watcher };

fn ask(io: std.Io, argv: []const []const u8, parse: *const fn ([]const u8) ?bool) ?bool {
    var buffer: [4096]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&buffer);
    const reply = std.process.run(allocator.allocator(), io, .{ .argv = argv, .stdout_limit = .limited(256), .stderr_limit = .limited(1024) }) catch return null;
    if (!reply.term.success()) return null;
    return parse(reply.stdout);
}

/// busctl prints "b true" or "b false".
fn parseBusctl(output: []const u8) ?bool {
    const text = std.mem.trim(u8, output, " \n");
    if (std.mem.eql(u8, text, "b true")) return true;
    if (std.mem.eql(u8, text, "b false")) return false;
    return null;
}

/// gdbus prints "(true,)" or "(false,)".
fn parseGdbus(output: []const u8) ?bool {
    const text = std.mem.trim(u8, output, " \n");
    if (std.mem.eql(u8, text, "(true,)")) return true;
    if (std.mem.eql(u8, text, "(false,)")) return false;
    return null;
}

test "tray host answers of busctl and gdbus" {
    const t = std.testing;
    try t.expectEqual(@as(?bool, true), parseBusctl("b true\n"));
    try t.expectEqual(@as(?bool, false), parseBusctl("b false\n"));
    try t.expectEqual(@as(?bool, null), parseBusctl("Failed to connect to bus\n"));
    try t.expectEqual(@as(?bool, true), parseGdbus("(true,)\n"));
    try t.expectEqual(@as(?bool, false), parseGdbus("(false,)\n"));
    try t.expectEqual(@as(?bool, null), parseGdbus(""));
}

pub const Desktop = enum { gnome, other };

/// Classifies `XDG_CURRENT_DESKTOP`, a colon-separated list such as
/// "ubuntu:GNOME" or "KDE".
pub fn desktopOf(current_desktop: ?[]const u8) Desktop {
    var names = std.mem.tokenizeScalar(u8, current_desktop orelse return .other, ':');
    while (names.next()) |name| if (std.ascii.eqlIgnoreCase(name, "GNOME")) return .gnome;
    return .other;
}

test "the effective rule grants only Zigmkay and RP2040 devices to the local session" {
    const t = std.testing;
    try t.expect(std.mem.startsWith(
        u8,
        effective_rule,
        "SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"fafa\", ATTRS{idProduct}==\"00f0\", TAG+=\"uaccess\"\n",
    ));
    var lines = std.mem.tokenizeScalar(u8, effective_rule, '\n');
    while (lines.next()) |line| {
        try t.expect(std.mem.endsWith(u8, line, ", TAG+=\"uaccess\""));
        try t.expect(std.mem.indexOf(u8, line, "{idVendor}==\"fafa\"") != null or
            std.mem.indexOf(u8, line, "{idVendor}==\"2e8a\"") != null);
        try t.expect(std.mem.indexOf(u8, line, "MODE") == null and std.mem.indexOf(u8, line, "RUN") == null);
    }
    try t.expect(std.mem.startsWith(u8, manual_command, "echo 'SUBSYSTEM==\"hidraw\""));
    try t.expect(std.mem.endsWith(u8, manual_command, "' \\\n  | sudo tee /etc/udev/rules.d/70-zigmkay.rules"));
    try t.expect(std.mem.startsWith(u8, learn_more_url, "https://"));
    try t.expect(std.mem.endsWith(u8, learn_more_url, "companion/docs/linux-permissions.md"));
}

test "pkexec outcomes" {
    const t = std.testing;
    try t.expectEqual(Grant.State.installed, outcome(.{ .exited = 0 }));
    try t.expectEqual(Grant.State.cancelled, outcome(.{ .exited = 126 }));
    try t.expectEqual(Grant.State.cancelled, outcome(.{ .exited = 127 }));
    try t.expectEqual(Grant.State.failed, outcome(.{ .exited = 1 }));
    try t.expectEqual(Grant.State.failed, outcome(.{ .unknown = 1 }));
}

test desktopOf {
    const t = std.testing;
    try t.expectEqual(Desktop.gnome, desktopOf("GNOME"));
    try t.expectEqual(Desktop.gnome, desktopOf("ubuntu:GNOME"));
    try t.expectEqual(Desktop.other, desktopOf("KDE"));
    try t.expectEqual(Desktop.other, desktopOf("Hyprland"));
    try t.expectEqual(Desktop.other, desktopOf(null));
}
