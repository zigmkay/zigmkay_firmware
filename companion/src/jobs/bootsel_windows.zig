//! Native Windows volume discovery. Only called by an explicit flash helper.
const std = @import("std");
const policy = @import("bootsel-policy");
const w = std.os.windows;
const cc = std.builtin.CallingConvention.winapi;
const Handle = w.HANDLE;
const Guid = w.GUID;

const Device = extern struct {
    size: u32 = @sizeOf(Device),
    class: Guid = std.mem.zeroes(Guid),
    instance: u32 = 0,
    reserved: usize = 0,
};

const Interface = extern struct {
    size: u32 = @sizeOf(Interface),
    class: Guid = std.mem.zeroes(Guid),
    flags: u32 = 0,
    reserved: usize = 0,
};

const Number = extern struct { kind: u32, disk: u32, partition: u32 };
extern "kernel32" fn FindFirstVolumeW([*]u16, u32) callconv(cc) Handle;
extern "kernel32" fn FindNextVolumeW(Handle, [*]u16, u32) callconv(cc) i32;
extern "kernel32" fn FindVolumeClose(Handle) callconv(cc) i32;

extern "kernel32" fn GetVolumeInformationW(
    [*:0]const u16,
    ?[*]u16,
    u32,
    *u32,
    ?*u32,
    ?*u32,
    ?[*]u16,
    u32,
) callconv(cc) i32;

extern "kernel32" fn CreateFileW(
    [*:0]const u16,
    u32,
    u32,
    ?*anyopaque,
    u32,
    u32,
    ?Handle,
) callconv(cc) Handle;

extern "kernel32" fn CloseHandle(Handle) callconv(cc) i32;

extern "kernel32" fn DeviceIoControl(
    Handle,
    u32,
    ?*const anyopaque,
    u32,
    *anyopaque,
    u32,
    *u32,
    ?*anyopaque,
) callconv(cc) i32;

extern "kernel32" fn ReadFile(Handle, [*]u8, u32, *u32, ?*anyopaque) callconv(cc) i32;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(cc) i32;
extern "kernel32" fn GetLastError() callconv(cc) u32;
pub extern "kernel32" fn ExitProcess(u32) callconv(cc) noreturn;
extern "setupapi" fn SetupDiGetClassDevsW(*const Guid, ?[*:0]const u16, ?Handle, u32) callconv(cc) Handle;

extern "setupapi" fn SetupDiEnumDeviceInterfaces(
    Handle,
    ?*Device,
    *const Guid,
    u32,
    *Interface,
) callconv(cc) i32;

extern "setupapi" fn SetupDiGetDeviceInterfaceDetailW(
    Handle,
    *Interface,
    *anyopaque,
    u32,
    ?*u32,
    *Device,
) callconv(cc) i32;

extern "setupapi" fn SetupDiDestroyDeviceInfoList(Handle) callconv(cc) i32;
extern "cfgmgr32" fn CM_Get_Parent(*u32, u32, u32) callconv(cc) u32;
extern "cfgmgr32" fn CM_Get_Device_IDW(u32, [*]u16, u32, u32) callconv(cc) u32;

fn deviceNumber(handle: Handle) !Number {
    var result: Number = undefined;
    var returned: u32 = 0;
    if (DeviceIoControl(handle, 0x002d1080, null, 0, &result, @sizeOf(Number), &returned, null) == 0 or
        returned != @sizeOf(Number)) return error.VolumeIdentityUnavailable;
    return result;
}

fn usbIdentity(disk: u32) ![256]u16 {
    const disk_guid: Guid = .{
        .Data1 = 0x53f56307,
        .Data2 = 0xb6bf,
        .Data3 = 0x11d0,
        .Data4 = .{ 0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b },
    };
    const set = SetupDiGetClassDevsW(&disk_guid, null, null, 0x12);
    if (set == w.INVALID_HANDLE_VALUE) return error.UsbIdentityUnavailable;
    defer _ = SetupDiDestroyDeviceInfoList(set);
    var index: u32 = 0;
    while (index < 4096) : (index += 1) {
        var interface: Interface = .{};
        if (SetupDiEnumDeviceInterfaces(set, null, &disk_guid, index, &interface) == 0) {
            if (GetLastError() == 259) break;
            return error.UsbEnumerationFailed;
        }
        var detail: [4096]u8 align(8) = @splat(0);
        std.mem.writeInt(u32, detail[0..4], 8, .little); // x86_64 SP_DEVICE_INTERFACE_DETAIL_DATA_W
        var device: Device = .{};
        if (SetupDiGetDeviceInterfaceDetailW(set, &interface, &detail, detail.len, null, &device) == 0)
            return error.UsbEnumerationFailed;
        const name: [*:0]const u16 = @ptrCast(@alignCast(&detail[4]));
        const handle = CreateFileW(name, 0, 3, null, 3, 0, null);
        if (handle == w.INVALID_HANDLE_VALUE) continue;
        const number = deviceNumber(handle) catch {
            _ = CloseHandle(handle);
            continue;
        };
        _ = CloseHandle(handle);
        if (number.kind != 7 or number.disk != disk) continue;
        var instance = device.instance;
        for (0..16) |_| {
            var id: [256]u16 = @splat(0);
            if (CM_Get_Device_IDW(instance, &id, id.len, 0) != 0) return error.UsbIdentityUnavailable;
            // CM returns canonical uppercase device IDs. Match a complete USB
            // device node, rather than a label or a mass-storage product string.
            if (policy.isRp2040UsbIdentity(std.mem.sliceTo(&id, 0))) return id;
            var parent: u32 = 0;
            if (CM_Get_Parent(&parent, instance, 0) != 0) break;
            instance = parent;
        }
        return error.NotRp2040UsbDevice;
    }
    return error.NotRp2040UsbDevice;
}

fn path(root: [64]u16, suffix: []const u16) ![128:0]u16 {
    const prefix = std.mem.sliceTo(&root, 0);
    if (!std.mem.startsWith(u16, prefix, std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\Volume{")) or
        prefix.len == 0 or
        prefix[prefix.len - 1] != '\\' or
        prefix.len + suffix.len > 128) return error.InvalidVolumePath;
    var out: [128:0]u16 = @splat(0);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..suffix.len], suffix);
    return out;
}

fn inspect(root: [64]u16) !policy.Volume {
    var serial: u32 = 0;
    const root_path = try path(root, &.{});
    if (GetVolumeInformationW(&root_path, null, 0, &serial, null, null, null, 0) == 0)
        return error.VolumeIdentityUnavailable;
    var device_path = root_path;
    device_path[std.mem.len(@as([*:0]const u16, &device_path)) - 1] = 0;
    const handle = CreateFileW(&device_path, 0, 3, null, 3, 0, null);
    if (handle == w.INVALID_HANDLE_VALUE) return error.VolumeIdentityUnavailable;
    defer _ = CloseHandle(handle);
    const number = try deviceNumber(handle);
    const usb = try usbIdentity(number.disk);
    const info_path = try path(root, std.unicode.utf8ToUtf16LeStringLiteral("INFO_UF2.TXT"));
    const info = CreateFileW(&info_path, 0x80000000, 3, null, 3, 0, null);
    if (info == w.INVALID_HANDLE_VALUE) return error.InvalidBootselInfo;
    defer _ = CloseHandle(info);
    var bytes: [4097]u8 = undefined;
    var length: u32 = 0;
    if (ReadFile(info, &bytes, bytes.len, &length, null) == 0) return error.InvalidBootselInfo;
    try policy.validateInfo(bytes[0..length]);
    return .{ .root = root, .serial = serial, .disk = number.disk, .usb_identity = usb };
}

pub fn discover() !?policy.Volume {
    var root: [64]u16 = @splat(0);
    const search = FindFirstVolumeW(&root, root.len);
    if (search == w.INVALID_HANDLE_VALUE) return error.VolumeEnumerationFailed;
    defer _ = FindVolumeClose(search);
    var found: ?policy.Volume = null;
    while (true) {
        if (inspect(root)) |volume| {
            if (found != null) return error.AmbiguousBootselDevices;
            found = volume;
        } else |err| switch (err) {
            error.NotRp2040UsbDevice, error.VolumeIdentityUnavailable, error.UsbIdentityUnavailable => {},
            else => return err,
        }
        @memset(&root, 0);
        if (FindNextVolumeW(search, &root, root.len) == 0) {
            if (GetLastError() != 18) return error.VolumeEnumerationFailed;
            break;
        }
    }
    return found;
}

pub const Ops = struct {
    io: std.Io,
    deadline: i64,

    pub fn check(self: *Ops) !void {
        if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= self.deadline) return error.TransferTimeout;
    }

    pub fn revalidate(_: *Ops, volume: policy.Volume) !policy.Volume {
        // Re-enumeration rejects a second device arriving during discovery.
        const current = try discover() orelse return error.DeviceDisappeared;
        if (!volume.same(current)) return error.BootselVolumeChanged;
        return current;
    }

    pub fn open(_: *Ops, volume: policy.Volume) !Handle {
        // Final recheck occurs immediately before opening the GUID-qualified
        // destination; no drive-letter mapping or drive-relative path is used.
        if (!volume.same(try inspect(volume.root))) return error.BootselVolumeChanged;
        const name = try path(volume.root, std.unicode.utf8ToUtf16LeStringLiteral("FIRMWARE.UF2"));
        const handle = CreateFileW(&name, 0x40000000, 0, null, 2, 0x80000000, null);
        if (handle == w.INVALID_HANDLE_VALUE) return error.BootselDestinationUnavailable;
        return handle;
    }

    pub fn close(_: *Ops, handle: Handle) void {
        _ = CloseHandle(handle);
    }

    pub fn write(_: *Ops, handle: Handle, bytes: []const u8) !usize {
        var written: u32 = 0;
        if (WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null) == 0) return error.BootselWriteFailed;
        return written;
    }
};
