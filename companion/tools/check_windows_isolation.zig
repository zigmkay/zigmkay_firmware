//! Check the CI sandbox before accepting an offline Windows bundle build.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--network-child")) return networkDenied(init.io);
    if (args.len != 3) return error.Usage;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const executable = try cwd.openFile(io, args[1], .{});
    defer executable.close(io);
    if (try executable.length(io) == 0) return error.EmptyExecutable;
    if (cwd.openFile(io, args[1], .{ .mode = .write_only })) |file| {
        file.close(io);
        return error.InstallationWritable;
    } else |err| switch (err) {
        error.AccessDenied => {},
        else => return err,
    }
    if (cwd.openFile(io, args[2], .{})) |file| {
        file.close(io);
        return error.CheckoutReadable;
    } else |err| switch (err) {
        error.AccessDenied => {},
        else => return err,
    }
    try networkDenied(io);
    // A newly spawned process must inherit the account's network restriction.
    const child = try std.process.run(init.gpa, io, .{
        .argv = &.{ args[0], "--network-child" },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    defer init.gpa.free(child.stdout);
    defer init.gpa.free(child.stderr);
    if (child.term != .exited or child.term.exited != 0) {
        std.log.err("Child network isolation failed: {s}", .{child.stderr});
        return error.ChildNetworkIsolationFailed;
    }
    std.log.info(
        "Isolation verified: installation readable, writes and checkout reads denied, parent and child network denied",
        .{},
    );
}

fn networkDenied(io: std.Io) !void {
    if (@import("builtin").os.tag == .windows) return windowsNetworkDenied();
    const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 1, 1, 1, 1 }, .port = 443 } };
    if (address.connect(io, .{ .mode = .stream })) |stream| {
        stream.close(io);
        return error.NetworkIsolationIneffective;
    } else |err| switch (err) {
        // Require an explicit local policy denial, not a routing or server error.
        error.AccessDenied => {},
        else => return err,
    }
}

const Winsock = struct {
    extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn socket(family: c_int, kind: c_int, protocol: c_int) callconv(.winapi) usize;
    extern "ws2_32" fn closesocket(handle: usize) callconv(.winapi) c_int;

    extern "ws2_32" fn connect(
        handle: usize,
        address: *const std.os.windows.ws2_32.sockaddr,
        length: c_int,
    ) callconv(.winapi) c_int;
};

fn windowsNetworkDenied() !void {
    // Zig 0.17's Windows Io connect panics for timeouts and does not map the
    // firewall denial. Use Winsock for this probe, bounded by the parent process.
    // Reserve more than WSADATA requires on either Windows pointer width.
    var startup: [512]u8 align(8) = undefined;
    if (Winsock.WSAStartup(0x0202, &startup) != 0) return error.WinsockStartupFailed;
    defer _ = Winsock.WSACleanup();
    const w = std.os.windows.ws2_32;
    const socket = Winsock.socket(w.AF.INET, w.SOCK.STREAM, w.IPPROTO.TCP);
    if (socket == std.math.maxInt(usize)) return error.SocketCreationFailed;
    defer _ = Winsock.closesocket(socket);
    const address: w.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, 443), .addr = 0x01010101 };
    if (Winsock.connect(socket, @ptrCast(&address), @sizeOf(@TypeOf(address))) == 0)
        return error.NetworkIsolationIneffective;
    const code = Winsock.WSAGetLastError();
    if (code != 10013) { // WSAEACCES: an explicit local policy denial.
        std.log.err("Expected firewall denial, got Winsock error {d}", .{code});
        return error.NetworkDenialNotConfirmed;
    }
}
