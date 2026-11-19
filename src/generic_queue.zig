const std = @import("std");

pub const EnqueueError = error{CapacityExceeded};
pub const DequeueError = error{NoElements};
pub fn GenericQueue(comptime T: type, comptime max_capacity: usize) type {
    return struct {
        const Self = @This();
        data: [max_capacity]T,
        size: usize = 0,
        pub fn Create() Self {
            return Self{ .data = @splat(undefined) };
        }
        pub fn Count(self: *Self) usize {
            return self.size;
        }
        pub fn enqueue(self: *Self, element: T) EnqueueError!void {
            if (self.size == max_capacity) {
                return EnqueueError.CapacityExceeded;
            }
            self.data[self.size] = element;
            self.size += 1;
        }
        pub fn dequeue_count(self: *Self, count: u8) DequeueError!void {
            var i = count;
            while (i > 0) {
                const event_or_null = dequeue(self);
                if (event_or_null) |_| {
                    i -= 1;
                } else {
                    return DequeueError.NoElements;
                }
            }
        }
        pub fn dequeue(self: *Self) ?T {
            if (self.size == 0) {
                return null;
            }
            const head_element = self.data[0];

            // todo: don't do this shifting of all values. Use a better queue implementation instead
            for (self.data[1..self.size], 0..self.size - 1) |item, index| {
                self.data[index] = item;
            }
            self.size = self.size - 1;
            return head_element;
        }

        pub fn peek_all(self: *Self) []T {
            return self.data[0..self.size];
        }
        pub fn peek(self: *Self) ?T {
            if (self.size > 0) {
                return self.data[0];
            } else {
                return null;
            }
        }
    };
}
