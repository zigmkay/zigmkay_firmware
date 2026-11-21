//! macOS: prints the companion reports of a connected ZigMkay keyboard.
//!
//! The firmware stays silent until the host sends `connect`, so the monitor
//! sends it whenever the Raw HID interface appears and `disconnect` on Ctrl-C.
//! It keeps running across unplugging and reconnecting.
const std = @import("std");
const companion = @import("zigmkay").companion;

const vendor_id = 0xFAFA;
const product_id = 0x00F0;
const usage_page = 0xFF31;
const usage = 0x0074;

const max_devices = 8;

const DeviceSlot = struct {
    device: ?*IOHIDDevice = null,
    report_buffer: companion.Report = undefined,
};

var device_slots: [max_devices]DeviceSlot = @splat(.{});
var run_loop: ?*CFRunLoop = null;
var signal_write_fd: std.posix.fd_t = -1;

pub fn main() !void {
    const manager = IOHIDManagerCreate(null, 0) orelse
        std.process.fatal("Could not create an IOKit HID manager.", .{});
    defer CFRelease(manager);

    const matching = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    setNumber(matching, "VendorID", vendor_id);
    setNumber(matching, "ProductID", product_id);
    setNumber(matching, "PrimaryUsagePage", usage_page);
    setNumber(matching, "PrimaryUsage", usage);
    IOHIDManagerSetDeviceMatching(manager, matching);
    CFRelease(matching);

    IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceConnected, null);
    IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemoved, null);
    run_loop = CFRunLoopGetCurrent();
    IOHIDManagerScheduleWithRunLoop(manager, run_loop.?, kCFRunLoopDefaultMode);

    const open_result = IOHIDManagerOpen(manager, 0);
    if (open_result != 0) std.process.fatal("Could not open ZigMkay RawHID: 0x{x:0>8}", .{@as(u32, @bitCast(open_result))});
    defer _ = IOHIDManagerClose(manager, 0);

    // Self-pipe so signal handlers only call async-signal-safe write(2), while
    // CFRunLoopStop runs on the run loop thread.
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) std.process.fatal("Could not create signal pipe.", .{});
    defer _ = std.c.close(pipe_fds[1]);
    setNonBlocking(pipe_fds[0]);
    setNonBlocking(pipe_fds[1]);
    signal_write_fd = pipe_fds[1];
    defer signal_write_fd = -1;

    const signal_fd = CFFileDescriptorCreate(null, pipe_fds[0], true, signalFired, null) orelse {
        _ = std.c.close(pipe_fds[0]);
        std.process.fatal("Could not register signal descriptor.", .{});
    };
    defer {
        CFFileDescriptorInvalidate(signal_fd);
        CFRelease(signal_fd);
    }
    CFFileDescriptorEnableCallBacks(signal_fd, kCFFileDescriptorReadCallBack);
    const signal_source = CFFileDescriptorCreateRunLoopSource(null, signal_fd, 0) orelse
        std.process.fatal("Could not create signal run loop source.", .{});
    defer CFRelease(signal_source);
    CFRunLoopAddSource(run_loop.?, signal_source, kCFRunLoopDefaultMode);
    defer CFRunLoopRemoveSource(run_loop.?, signal_source, kCFRunLoopDefaultMode);

    // Ctrl-C / SIGTERM / SIGHUP stop the run loop so `disconnect` is sent and
    // the terminal settings are restored before exiting.
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = handleSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.HUP, &action, null);

    std.debug.print("Waiting for ZigMkay RawHID ({X:0>4}:{X:0>4}, {X:0>4}:{X:0>4})...\n", .{ vendor_id, product_id, usage_page, usage });
    const terminal = hideTyping();
    defer restoreTyping(terminal);
    CFRunLoopRun();

    var disconnected = false;
    for (&device_slots) |*slot| {
        if (slot.device) |device| {
            send(device, .disconnect);
            slot.device = null;
            disconnected = true;
        }
    }
    if (disconnected) std.debug.print("Sent disconnect.\n", .{});
}

fn setNonBlocking(fd: std.posix.fd_t) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags >= 0) {
        const nonblock: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        _ = std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock);
    }
}

/// The keyboard also types into this terminal. Hide that echo while the
/// monitor runs, so only report lines appear; null when stdin is no terminal.
fn hideTyping() ?std.posix.termios {
    const saved = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return null;
    var quiet = saved;
    quiet.lflag.ECHO = false;
    quiet.lflag.ICANON = false;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, quiet) catch return null;
    return saved;
}

/// Restores the terminal and drops what was typed, so it never reaches the shell.
fn restoreTyping(saved: ?std.posix.termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, saved orelse return) catch {};
}

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    const fd = signal_write_fd;
    if (fd >= 0) {
        const byte = [_]u8{1};
        _ = std.c.write(fd, &byte, byte.len);
    }
}

fn signalFired(_: *CFFileDescriptor, _: CFOptionFlags, _: ?*anyopaque) callconv(.c) void {
    if (run_loop) |rl| CFRunLoopStop(rl);
}

fn setNumber(dictionary: *CFDictionary, comptime key: [:0]const u8, value: c_int) void {
    const cf_key = CFStringCreateWithCString(null, key, kCFStringEncodingUTF8);
    defer CFRelease(cf_key);
    const number = CFNumberCreate(null, kCFNumberIntType, &value);
    defer CFRelease(number);
    CFDictionarySetValue(dictionary, cf_key, number);
}

/// Sends a command as a 32-byte output report. The interface has no report
/// ids, so report id 0 is passed and byte 0 carries the command.
fn send(device: *IOHIDDevice, command: companion.Command) void {
    var report: companion.Report = @splat(0);
    report[0] = @backingInt(command);
    const result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &report, report.len);
    if (result != 0) std.debug.print("Could not send {t}: 0x{x:0>8}\n", .{ command, @as(u32, @bitCast(result)) });
}

fn deviceConnected(_: ?*anyopaque, _: IOReturn, _: ?*anyopaque, device: *IOHIDDevice) callconv(.c) void {
    for (&device_slots) |*slot| {
        if (slot.device == device) return;
    }
    for (&device_slots) |*slot| {
        if (slot.device == null) {
            slot.device = device;
            std.debug.print("ZigMkay RawHID connected; press Ctrl-C to stop.\n", .{});
            IOHIDDeviceRegisterInputReportCallback(device, &slot.report_buffer, slot.report_buffer.len, printReport, null);
            send(device, .connect);
            return;
        }
    }
    std.debug.print("ZigMkay RawHID connected, but all {d} monitor slots are in use.\n", .{max_devices});
}

fn deviceRemoved(_: ?*anyopaque, _: IOReturn, _: ?*anyopaque, device: *IOHIDDevice) callconv(.c) void {
    for (&device_slots) |*slot| {
        if (slot.device == device) {
            slot.device = null;
            std.debug.print("ZigMkay RawHID disconnected; waiting for it to return...\n", .{});
            return;
        }
    }
}

fn printReport(_: ?*anyopaque, result: IOReturn, _: ?*anyopaque, _: u32, _: u32, report: [*]u8, length: CFIndex) callconv(.c) void {
    if (result != 0) {
        std.debug.print("Raw HID read failed: 0x{x:0>8}\n", .{@as(u32, @bitCast(result))});
        return;
    }
    if (length < 0) return;
    const bytes = report[0..@intCast(length)];
    if (bytes.len < @sizeOf(companion.Report)) return printHex(bytes);
    const id = std.enums.fromInt(companion.MessageId, bytes[0]) orelse return printHex(bytes);
    switch (id) {
        .hello => {
            std.debug.print("hello  version={d}{s} keys={d} layers={d} keymap={x}\n", .{
                bytes[1],
                if (bytes[1] == companion.protocol_version) "" else " (unsupported)",
                bytes[2],
                bytes[3],
                bytes[4..20],
            });
        },
        .state => {
            std.debug.print("state  seq={d:>3} layer={d} modifiers=0x{x:0>2} layers=", .{ bytes[1], bytes[2], bytes[3] });
            printBits(bytes[4..6]);
            std.debug.print(" pressed=", .{});
            printBits(bytes[6..22]);
            std.debug.print("\n", .{});
        },
        .key => std.debug.print("key    seq={d:>3} {s:<8} key={d} layer={d} modifiers=0x{x:0>2}\n", .{
            bytes[1],
            if (bytes[2] != 0) "pressed" else "released",
            bytes[3],
            bytes[4],
            bytes[5],
        }),
        .signal => {
            std.debug.print("signal seq={d:>3} ", .{bytes[1]});
            if (std.enums.fromInt(companion.Signal, bytes[2])) |signal|
                std.debug.print("{t}", .{signal})
            else
                std.debug.print("0x{x:0>2}", .{bytes[2]});
            std.debug.print(" {s}\n", .{if (bytes[3] != 0) "pressed" else "released"});
        },
    }
}

fn printHex(bytes: []const u8) void {
    std.debug.print("report {x}\n", .{bytes});
}

/// Prints the indexes of the set bits, least significant bit of byte 0 first.
fn printBits(bytes: []const u8) void {
    var first = true;
    for (bytes, 0..) |byte, byte_index| {
        for (0..8) |bit| {
            if (byte & (@as(u8, 1) << @intCast(bit)) == 0) continue;
            std.debug.print("{s}{d}", .{ if (first) "" else ",", byte_index * 8 + bit });
            first = false;
        }
    }
    if (first) std.debug.print("-", .{});
}

// IOKit and CoreFoundation, declared by hand to avoid a C import.
const CFIndex = isize;
const CFOptionFlags = usize;
const IOReturn = i32;
const CFAllocator = opaque {};
const CFDictionary = opaque {};
const CFString = opaque {};
const CFRunLoop = opaque {};
const CFRunLoopSource = opaque {};
const CFFileDescriptor = opaque {};
const CFCallBacks = opaque {};
const IOHIDManager = opaque {};
const IOHIDDevice = opaque {};

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFNumberIntType: CFIndex = 9;
const kCFFileDescriptorReadCallBack: CFOptionFlags = 1 << 0;
const kIOHIDReportTypeOutput: u32 = 1;

const DeviceCallback = *const fn (?*anyopaque, IOReturn, ?*anyopaque, *IOHIDDevice) callconv(.c) void;
const ReportCallback = *const fn (?*anyopaque, IOReturn, ?*anyopaque, u32, u32, [*]u8, CFIndex) callconv(.c) void;
const FileDescriptorCallback = *const fn (*CFFileDescriptor, CFOptionFlags, ?*anyopaque) callconv(.c) void;

extern const kCFTypeDictionaryKeyCallBacks: CFCallBacks;
extern const kCFTypeDictionaryValueCallBacks: CFCallBacks;
extern const kCFRunLoopDefaultMode: *const CFString;

extern fn CFRelease(object: *const anyopaque) void;
extern fn CFDictionaryCreateMutable(allocator: ?*const CFAllocator, capacity: CFIndex, key_callbacks: *const CFCallBacks, value_callbacks: *const CFCallBacks) *CFDictionary;
extern fn CFDictionarySetValue(dictionary: *CFDictionary, key: *const anyopaque, value: *const anyopaque) void;
extern fn CFStringCreateWithCString(allocator: ?*const CFAllocator, string: [*:0]const u8, encoding: u32) *CFString;
extern fn CFNumberCreate(allocator: ?*const CFAllocator, number_type: CFIndex, value: *const anyopaque) *anyopaque;
extern fn CFRunLoopGetCurrent() *CFRunLoop;
extern fn CFRunLoopRun() void;
extern fn CFRunLoopStop(run_loop: *CFRunLoop) void;
extern fn CFRunLoopAddSource(rl: *CFRunLoop, source: *CFRunLoopSource, mode: *const CFString) void;
extern fn CFRunLoopRemoveSource(rl: *CFRunLoop, source: *CFRunLoopSource, mode: *const CFString) void;
extern fn CFFileDescriptorCreate(allocator: ?*const CFAllocator, fd: c_int, close_on_invalidate: bool, callout: FileDescriptorCallback, context: ?*const anyopaque) ?*CFFileDescriptor;
extern fn CFFileDescriptorEnableCallBacks(f: *CFFileDescriptor, callback_types: CFOptionFlags) void;
extern fn CFFileDescriptorInvalidate(f: *CFFileDescriptor) void;
extern fn CFFileDescriptorCreateRunLoopSource(allocator: ?*const CFAllocator, f: *CFFileDescriptor, order: CFIndex) ?*CFRunLoopSource;

extern fn IOHIDManagerCreate(allocator: ?*const CFAllocator, options: u32) ?*IOHIDManager;
extern fn IOHIDManagerSetDeviceMatching(manager: *IOHIDManager, matching: *const CFDictionary) void;
extern fn IOHIDManagerRegisterDeviceMatchingCallback(manager: *IOHIDManager, callback: DeviceCallback, context: ?*anyopaque) void;
extern fn IOHIDManagerRegisterDeviceRemovalCallback(manager: *IOHIDManager, callback: DeviceCallback, context: ?*anyopaque) void;
extern fn IOHIDManagerScheduleWithRunLoop(manager: *IOHIDManager, run_loop: *CFRunLoop, mode: *const CFString) void;
extern fn IOHIDManagerOpen(manager: *IOHIDManager, options: u32) IOReturn;
extern fn IOHIDManagerClose(manager: *IOHIDManager, options: u32) IOReturn;
extern fn IOHIDDeviceRegisterInputReportCallback(device: *IOHIDDevice, report: [*]u8, length: CFIndex, callback: ReportCallback, context: ?*anyopaque) void;
extern fn IOHIDDeviceSetReport(device: *IOHIDDevice, report_type: u32, report_id: CFIndex, report: [*]const u8, length: CFIndex) IOReturn;
