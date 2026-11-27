//! Windows does not end child processes with their parent. Build and flash
//! children (zig.exe with its build runner and compilers, the BOOTSEL helper)
//! would keep running after the application crashed or was ended from the
//! Task Manager, a clang on a large C file holding gigabytes. On Windows every
//! such child therefore starts suspended, joins one job object that kills its
//! processes when the application's handle closes, and only then resumes, so
//! grandchildren join the job too. Elsewhere `adopt` does nothing.
const std = @import("std");
const builtin = @import("builtin");

/// Pass as `std.process.SpawnOptions.start_suspended`; `adopt` resumes.
pub const suspended = builtin.os.tag == .windows;

/// Moves a child spawned with `start_suspended = suspended` into the
/// application's job and resumes it. A child the job cannot take still runs.
/// On error the child stays suspended; the caller kills it.
pub fn adopt(child: *std.process.Child) error{ChildResumeFailed}!void {
    if (builtin.os.tag != .windows) return;
    if (shared()) |job| {
        if (win.AssignProcessToJobObject(job, child.id.?) == .FALSE)
            std.log.warn("Child process outside the application job: error {d}", .{@backingInt(std.os.windows.GetLastError())});
    }
    if (win.ResumeThread(child.thread_handle) == std.math.maxInt(u32)) return error.ChildResumeFailed;
}

var job_handle: std.atomic.Value(?std.os.windows.HANDLE) = .init(null);

/// The application's job, created on first use and kept open until exit.
fn shared() ?std.os.windows.HANDLE {
    if (job_handle.load(.acquire)) |job| return job;
    const job = win.CreateJobObjectW(null, null) orelse return null;
    var limits = std.mem.zeroes(win.ExtendedLimitInformation);
    limits.basic.limit_flags = win.kill_on_job_close;
    if (win.SetInformationJobObject(job, win.extended_limit_information, &limits, @sizeOf(win.ExtendedLimitInformation)) == .FALSE) {
        std.os.windows.CloseHandle(job);
        return null;
    }
    if (job_handle.cmpxchgStrong(null, job, .acq_rel, .acquire)) |winner| {
        std.os.windows.CloseHandle(job);
        return winner;
    }
    return job;
}

const win = struct {
    const windows = std.os.windows;
    const extended_limit_information: c_int = 9;
    const kill_on_job_close: u32 = 0x2000;

    const BasicLimitInformation = extern struct {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    };
    const IoCounters = extern struct {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    };
    const ExtendedLimitInformation = extern struct {
        basic: BasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    };

    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, class: c_int, info: *const anyopaque, length: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ResumeThread(thread: windows.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn IsProcessInJob(process: windows.HANDLE, job: ?windows.HANDLE, result: *windows.BOOL) callconv(.winapi) windows.BOOL;
};

test "the extended limit layout matches Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(win.ExtendedLimitInformation));
}

test "an adopted child runs inside the application job" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", "exit 5" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .start_suspended = suspended,
        .create_no_window = true,
    });
    adopt(&child) catch |err| {
        child.kill(io);
        return err;
    };
    var in_job: win.windows.BOOL = .FALSE;
    try std.testing.expect(win.IsProcessInJob(child.id.?, job_handle.load(.acquire).?, &in_job) != .FALSE);
    try std.testing.expect(in_job != .FALSE);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 5 }, try child.wait(io));
}
