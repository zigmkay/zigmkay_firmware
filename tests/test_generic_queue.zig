const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const std = @import("std");
const q = zigmkay.generic_queue;

test "queue" {
    var queue = q.GenericQueue(i32, 10).Create();
    try std.testing.expectEqual(0, queue.Count());
    try queue.enqueue(10);
    try queue.enqueue(11);
    try queue.enqueue(12);

    try std.testing.expectEqual(3, queue.Count());
    try std.testing.expectEqual(10, queue.dequeue());
    try std.testing.expectEqual(11, queue.dequeue());
    try std.testing.expectEqual(1, queue.Count());
    try std.testing.expectEqual(12, queue.dequeue());
    try std.testing.expectEqual(0, queue.Count());

    try queue.enqueue(20);
    try queue.enqueue(21);

    try std.testing.expectEqual(2, queue.Count());

    try std.testing.expectEqual(20, queue.dequeue());
    try std.testing.expectEqual(21, queue.dequeue());

    try std.testing.expectEqual(0, queue.Count());
}

test "dequeue_count" {
    var queue = q.GenericQueue(i32, 10).Create();
    try std.testing.expectEqual(0, queue.Count());
    try queue.enqueue(10);
    try queue.enqueue(11);
    try queue.enqueue(12);

    try std.testing.expectEqual(3, queue.Count());
    try queue.dequeue_count(2);

    try std.testing.expectEqual(1, queue.Count());
    try std.testing.expectEqual(12, queue.dequeue());
}

test "enqueue error" {
    var queue = q.GenericQueue(i32, 5).Create();
    try std.testing.expectEqual(0, queue.Count());
    _ = try queue.enqueue(1);
    _ = try queue.enqueue(2);
    _ = try queue.enqueue(3);
    _ = try queue.enqueue(4);
    _ = try queue.enqueue(5);

    try std.testing.expectEqual(5, queue.Count());
    const result = queue.enqueue(6);
    try std.testing.expectEqual(q.EnqueueError.CapacityExceeded, result);

    try std.testing.expectEqual(1, queue.dequeue());
    try std.testing.expectEqual(2, queue.dequeue());
    try std.testing.expectEqual(3, queue.Count());
    try queue.enqueue(10);
    try queue.enqueue(11);

    try std.testing.expectEqual(5, queue.Count());

    try std.testing.expectEqual(3, queue.dequeue());
    try std.testing.expectEqual(4, queue.dequeue());
    try std.testing.expectEqual(5, queue.dequeue());
    try std.testing.expectEqual(10, queue.dequeue());
    try std.testing.expectEqual(11, queue.dequeue());
}

test "dequeue error" {
    var queue = q.GenericQueue(i32, 5).Create();
    try std.testing.expectEqual(0, queue.Count());
    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    try queue.enqueue(4);

    _ = queue.dequeue();
    _ = queue.dequeue();
    _ = queue.dequeue();
    _ = queue.dequeue();

    const result = queue.dequeue();
    try std.testing.expectEqual(null, result);

    try queue.enqueue(5);
    try std.testing.expectEqual(5, queue.dequeue());
}

test "queue ring buffer testing" {
    var queue = q.GenericQueue(u32, 5).Create();
    var idx: u32 = 0;
    while (idx < 10) {
        queue.enqueue(idx) catch {};
        idx += 1;
    }

    try std.testing.expectEqual(0, queue.dequeue());
    try std.testing.expectEqual(1, queue.dequeue());
    try std.testing.expectEqual(2, queue.dequeue());
    try std.testing.expectEqual(3, queue.dequeue());
    try std.testing.expectEqual(4, queue.dequeue());
    try std.testing.expectEqual(0, queue.Count());
}

test "peek_all" {
    var queue = q.GenericQueue(u32, 5).Create();
    try queue.enqueue(1);

    {
        const all = queue.peek_all();
        try std.testing.expectEqual(1, all.len);
        try std.testing.expectEqual(1, all[0]);
    }
    _ = try queue.enqueue(2);
    _ = try queue.enqueue(3);
    _ = try queue.enqueue(4);

    {
        const all = queue.peek_all();
        try std.testing.expectEqual(4, all.len);

        try std.testing.expectEqual(1, all[0]);
        try std.testing.expectEqual(2, all[1]);
        try std.testing.expectEqual(3, all[2]);
        try std.testing.expectEqual(4, all[3]);
    }

    _ = queue.dequeue();
    _ = queue.dequeue();

    const all = queue.peek_all();
    try std.testing.expectEqual(2, queue.Count());
    {
        try std.testing.expectEqual(2, all.len);

        try std.testing.expectEqual(3, all[0]);
        try std.testing.expectEqual(4, all[1]);
    }
}

test "peek" {
    var queue = q.GenericQueue(u32, 5).Create();
    try std.testing.expectEqual(null, queue.peek());
    try queue.enqueue(1);

    try std.testing.expectEqual(1, queue.peek());
    try std.testing.expectEqual(1, queue.peek());
    _ = try queue.enqueue(2);
    _ = try queue.enqueue(3);
    _ = try queue.enqueue(4);

    try std.testing.expectEqual(1, queue.peek());

    _ = queue.dequeue();
    _ = queue.dequeue();

    try std.testing.expectEqual(2, queue.Count());
    try std.testing.expectEqual(3, queue.peek());
}
