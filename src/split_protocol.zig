const std = @import("std");
const core = @import("core.zig");
const generic_queue = @import("generic_queue.zig");

pub const ProtocolMessage = union(enum) {
    MatrixStateChange: struct { pressed: bool, key_index: core.KeyIndex },
    EncoderActionIndexTriggered: u8,
};

pub const ByteQueue = generic_queue.GenericQueue(u8, 250);

pub const DELIMITER: u8 = 0b11111111;
pub const MessageType = enum(u8) { Undefined = 0, KeyPressed = 1, KeyReleased = 2, EncoderValueChanged = 3 };

pub const UartReceiveHelper = struct {
    pub const ExpectedData = enum { Delimiter, MessageId, Payload };
    pointer: usize = 0,
    cached_message_type: MessageType = undefined,
    expected_next: ExpectedData = ExpectedData.Delimiter,
    pub fn receiveByte(self: *UartReceiveHelper, byte: u8) ?ProtocolMessage {
        // read until delimiter + 2x non-delimiters received or null received
        switch (self.expected_next) {
            .Delimiter => {
                if (byte == DELIMITER) {
                    self.expected_next = .MessageId;
                }
                return null;
            },
            .MessageId => {
                if (byte == DELIMITER) {
                    // Let the expected next stay at message id
                    return null;
                }
                const val_or_null: ?MessageType = std.enums.fromInt(MessageType, byte);
                if (val_or_null) |val| {
                    self.cached_message_type = val;
                    self.expected_next = .Payload;
                } else {
                    self.expected_next = .Delimiter;
                }

                return null;
            },
            .Payload => {
                if (byte == DELIMITER) {
                    self.expected_next = .MessageId;
                    return null;
                }

                self.expected_next = .Delimiter; // Reset no matter what

                var buffer: [2]u8 = @splat(2);
                buffer[0] = @intFromEnum(self.cached_message_type);
                buffer[1] = byte;
                const msg = deserialize(buffer) catch return null;
                return msg;
            },
        }

        unreachable;
    }
};

pub const UartSendHelper = struct {
    byte_queue: ByteQueue = ByteQueue.Create(),
    pub fn sendMessage(self: *UartSendHelper, msg: ProtocolMessage) !void {
        const data: [2]u8 = serialize(msg);
        try self.byte_queue.enqueue(DELIMITER);
        try self.byte_queue.enqueue(data[0]);
        try self.byte_queue.enqueue(data[1]);
    }
};

fn u8_to_u7(val: u8) DeserializeError!u7 {
    if (val > 127) {
        return DeserializeError.U8notConvertibleToU7;
    }
    return @intCast(val);
}

pub fn serialize(msg: ProtocolMessage) [2]u8 {
    switch (msg) {
        .MatrixStateChange => |state_change| {
            if (state_change.pressed) {
                return .{ @intFromEnum(MessageType.KeyPressed), state_change.key_index };
            } else {
                return .{ @intFromEnum(MessageType.KeyReleased), state_change.key_index };
            }
        },
        .EncoderActionIndexTriggered => |encoder_value| {
            return .{ @intFromEnum(MessageType.EncoderValueChanged), encoder_value };
        },
    }
}

pub fn deserialize(buffer: [2]u8) DeserializeError!ProtocolMessage {
    const message_type_or_null: ?MessageType = std.enums.fromInt(MessageType, buffer[0]);
    if (message_type_or_null) |message_type| {
        const payload = buffer[1];
        switch (message_type) {
            .KeyPressed => return .{ .MatrixStateChange = .{ .key_index = try u8_to_u7(payload), .pressed = true } },
            .KeyReleased => return .{ .MatrixStateChange = .{ .key_index = try u8_to_u7(payload), .pressed = false } },
            .EncoderValueChanged => return .{ .EncoderActionIndexTriggered = try u8_to_u2(payload) },
            else => return DeserializeError.UnknownMessageType,
        }
    } else {
        return DeserializeError.UnknownMessageType;
    }
}

pub fn u8_to_u2(input: u8) DeserializeError!u2 {
    if (input > 3) {
        return DeserializeError.U7notConvertibleToU2;
    }
    return @intCast(input);
}

pub const DeserializeError = error{
    U7notConvertibleToU2,
    U8notConvertibleToU7,
    UnknownMessageType,
    InvalidMessageType,
};
