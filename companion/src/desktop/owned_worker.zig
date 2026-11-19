//! Shared stable-address worker lifetime for owned immutable preparation requests.
const std = @import("std");
pub const Ticket = struct { generation: u64, snapshot: [32]u8 };

pub fn Owner(comptime Request: type, comptime Prepared: type, comptime invalid_generation: anyerror) type {
    return struct {
        const Self = @This();
        pub const Event = struct { ticket: Ticket, result: anyerror!Prepared };
        gpa: std.mem.Allocator,
        io: std.Io,
        request: Request,
        ticket: Ticket,
        future: ?std.Io.Future(anyerror!Prepared) = null,
        done: std.atomic.Value(bool) = .init(false),

        /// Ownership transfers only on success. On failure the caller retains request.
        pub fn create(gpa: std.mem.Allocator, io: std.Io, request: *Request, generation: u64) !*Self {
            if (generation == 0) return invalid_generation;
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .gpa = gpa,
                .io = io,
                .request = request.*,
                .ticket = .{ .generation = generation, .snapshot = request.captured },
            };
            self.future = try std.Io.concurrent(io, prepare, .{self});
            request.* = undefined;
            return self;
        }

        fn prepare(self: *Self) anyerror!Prepared {
            defer self.done.store(true, .release);
            return self.request.prepare(self.gpa, self.io);
        }

        /// A returned successful Prepared is transferred to the caller.
        pub fn poll(self: *Self) ?Event {
            if (self.future == null or !self.done.load(.acquire)) return null;
            const result = self.future.?.await(self.io);
            self.future = null;
            return .{ .ticket = self.ticket, .result = result };
        }

        /// Cancellation joins before request storage is released. Already completed
        /// filesystem writes stay in place; no rollback or cross-process CAS is claimed.
        pub fn destroy(self: *Self) void {
            if (self.future) |*future| {
                if (future.cancel(self.io)) |completed| {
                    var prepared = completed;
                    prepared.deinit();
                } else |_| {}
            }
            self.request.deinit();
            const gpa = self.gpa;
            self.* = undefined;
            gpa.destroy(self);
        }
    };
}
