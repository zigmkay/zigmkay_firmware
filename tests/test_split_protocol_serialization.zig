const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const p = zigmkay.split_protocol;

const std = @import("std");
test "Serialize and deserialize: KeyPress" {
    const msg = p.ProtocolMessage{ .MatrixStateChange = .{ .pressed = true, .key_index = 102 } };
    const data: [2]u8 = p.serialize(msg);
    const other_msg = try p.deserialize(data);

    try std.testing.expectEqual(msg, other_msg);
}

test "Serialize and deserialize: KeyReleased" {
    const msg = p.ProtocolMessage{ .MatrixStateChange = .{ .pressed = false, .key_index = 102 } };
    const data: [2]u8 = p.serialize(msg);

    // sanity checking
    try std.testing.expectEqual(2, data[0]);

    const other_msg = try p.deserialize(data);

    try std.testing.expectEqual(msg, other_msg);
}

test "Serialize and deserialize: EncoderActionIndexTriggered" {
    const msg = p.ProtocolMessage{ .EncoderActionIndexTriggered = 3 };
    const data: [2]u8 = p.serialize(msg);
    const other_msg = try p.deserialize(data);

    try std.testing.expectEqual(msg, other_msg);
}

test "Serialize and deserialize: Invalid message type - 0" {
    const data: [2]u8 = [2]u8{ 0, 127 };
    const err = p.deserialize(data);

    try std.testing.expectEqual(err, p.DeserializeError.UnknownMessageType);
}

test "Serialize and deserialize: Invalid message type - 4" {
    const data: [2]u8 = [2]u8{ 4, 127 };
    const err = p.deserialize(data);

    try std.testing.expectEqual(err, p.DeserializeError.UnknownMessageType);
}

test "Serialize and deserialize: EncoderActionIndexTriggered (invalid u2 value) - 4" {
    const msg = p.ProtocolMessage{ .EncoderActionIndexTriggered = 3 };
    var data: [2]u8 = p.serialize(msg);
    try std.testing.expectEqual(3, data[1]); // sanity checking that the actual value is currently at this position

    // now make the data invalid
    data[1] = 4;

    const err = p.deserialize(data);

    try std.testing.expectEqual(err, p.DeserializeError.U7notConvertibleToU2);
}

test "Serialize and deserialize: EncoderActionIndexTriggered (invalid u2 value) - 127" {
    const msg = p.ProtocolMessage{ .EncoderActionIndexTriggered = 3 };
    var data: [2]u8 = p.serialize(msg);
    try std.testing.expectEqual(3, data[1]); // sanity checking that the actual value is currently at this position

    // now make the data invalid
    data[1] = 127;

    const err = p.deserialize(data);

    try std.testing.expectEqual(err, p.DeserializeError.U7notConvertibleToU2);
}
