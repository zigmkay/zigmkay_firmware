const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const p = zigmkay.split_protocol;

const std = @import("std");

test "receiveMessage - non-delimiters and then no new message" {
    var uart_helper = p.UartReceiveHelper{};
    try std.testing.expectEqual(null, uart_helper.receiveByte(40));
    try std.testing.expectEqual(null, uart_helper.receiveByte(41));
    try std.testing.expectEqual(null, uart_helper.receiveByte(42));
}

test "receiveMessage - delimiter, then no more data" {
    var uart_helper = p.UartReceiveHelper{};
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
}

test "receiveMessage - delimiter, then one more delimiter" {
    var uart_helper = p.UartReceiveHelper{};
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
}

test "receiveMessage - KeyPressed example" {
    var uart_helper = p.UartReceiveHelper{};
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(1)); // key pressed message type
    const msg = uart_helper.receiveByte(54);
    try std.testing.expectEqual(p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 54, .pressed = true } }, msg);
}

test "receiveMessage - KeyReleased example" {
    var uart_helper = p.UartReceiveHelper{};
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER)); // key released message type
    try std.testing.expectEqual(null, uart_helper.receiveByte(2));
    const msg = uart_helper.receiveByte(54);
    try std.testing.expectEqual(p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 54, .pressed = false } }, msg);
}

test "receiveMessage - EncoderActionIndexTriggered example" {
    var uart_helper = p.UartReceiveHelper{};
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER)); // EncoderActionIndexTriggered message type
    try std.testing.expectEqual(null, uart_helper.receiveByte(3));
    const msg = uart_helper.receiveByte(2);
    try std.testing.expectEqual(p.ProtocolMessage{ .EncoderActionIndexTriggered = 2 }, msg);
}

test "receiveMessage - EncoderActionIndexTriggered example, payload exceeding a u2" {
    var uart_helper = p.UartReceiveHelper{};

    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(3)); // key released message type
    try std.testing.expectEqual(null, uart_helper.receiveByte(5)); // invalid encoder value
}

test "receiveMessage - Mixed data" {
    var uart_helper = p.UartReceiveHelper{};

    // key pressed
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(1)); // key pressed
    try std.testing.expectEqual(p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 111, .pressed = true } }, uart_helper.receiveByte(111));

    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(2)); // key released
    try std.testing.expectEqual(p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 112, .pressed = false } }, uart_helper.receiveByte(112));

    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(3)); // encoder val changed
    try std.testing.expectEqual(p.ProtocolMessage{ .EncoderActionIndexTriggered = 1 }, uart_helper.receiveByte(1)); // key index
}

test "receiveMessage - Mixed data - with errors in it" {
    var uart_helper = p.UartReceiveHelper{};
    // VALID
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(1)); // key pressed
    try std.testing.expectEqual(p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 111, .pressed = true } }, uart_helper.receiveByte(111));

    // INVALID
    try std.testing.expectEqual(null, uart_helper.receiveByte(111)); // key index
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));

    // VALID
    try std.testing.expectEqual(p.UartReceiveHelper.ExpectedData.MessageId, uart_helper.expected_next);
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(p.UartReceiveHelper.ExpectedData.MessageId, uart_helper.expected_next);
    try std.testing.expectEqual(null, uart_helper.receiveByte(2)); // key released
    try std.testing.expectEqual(p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 112, .pressed = false } }, uart_helper.receiveByte(112));

    // INVALID
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(112));

    // VALID
    try std.testing.expectEqual(null, uart_helper.receiveByte(p.DELIMITER));
    try std.testing.expectEqual(null, uart_helper.receiveByte(3)); // encoder val changed
    try std.testing.expectEqual(p.ProtocolMessage{ .EncoderActionIndexTriggered = 1 }, uart_helper.receiveByte(1));
}

test "sendMessage/receive - KeyPressed example" {
    var uart_receiver = p.UartReceiveHelper{};
    var uart_sender = p.UartSendHelper{};

    const msg = p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 54, .pressed = true } };
    try uart_sender.sendMessage(msg);

    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(msg, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(0, uart_sender.byte_queue.Count());
}

test "sendMessage/receive - KeyReleased example" {
    var uart_receiver = p.UartReceiveHelper{};
    var uart_sender = p.UartSendHelper{};

    const msg = p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 54, .pressed = false } };
    try uart_sender.sendMessage(msg);

    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(msg, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(0, uart_sender.byte_queue.Count());
}

test "sendMessage/receive - EncoderActionIndexTriggered example" {
    var uart_receiver = p.UartReceiveHelper{};
    var uart_sender = p.UartSendHelper{};
    try uart_sender.sendMessage(p.ProtocolMessage{ .EncoderActionIndexTriggered = 2 });

    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(p.ProtocolMessage{ .EncoderActionIndexTriggered = 2 }, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(0, uart_sender.byte_queue.Count());
}

test "sendMessage/receive - multiple values example" {
    var uart_receiver = p.UartReceiveHelper{};
    var uart_sender = p.UartSendHelper{};

    const msg1 = p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 20, .pressed = true } };
    const msg2 = p.ProtocolMessage{ .MatrixStateChange = .{ .key_index = 100, .pressed = false } };
    const msg3 = p.ProtocolMessage{ .EncoderActionIndexTriggered = 2 };
    try uart_sender.sendMessage(msg1);
    try uart_sender.sendMessage(msg2);

    try uart_sender.byte_queue.enqueue(p.DELIMITER); // add some noise!
    try uart_sender.sendMessage(msg3);

    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(msg1, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));

    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(msg2, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));

    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(null, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));
    try std.testing.expectEqual(msg3, uart_receiver.receiveByte(uart_sender.byte_queue.dequeue().?));

    try std.testing.expectEqual(0, uart_sender.byte_queue.Count());
}
