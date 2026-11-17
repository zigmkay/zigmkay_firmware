const std = @import("std");
const zigmkay = @import("zigmkay");
const core = zigmkay.core;
const companion = zigmkay.companion;

const info = companion.Info{ .key_count = 36, .layer_count = 4, .keymap_id = @splat(0xAB) };

fn command(id: companion.Command) companion.Report {
    var report: companion.Report = @splat(0);
    report[0] = @backingInt(id);
    return report;
}

fn take(session: *companion.Session) ?companion.Report {
    const report = session.next_report() orelse return null;
    session.sent();
    return report;
}

test "companion session stays silent until the host connects" {
    var session = companion.Session.init(info);
    session.key_event(true, 3, 0, .{});
    session.update_state(1, .{});
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session answers connect with hello and current state" {
    var session = companion.Session.init(info);
    session.key_event(true, 9, 0, .{});
    session.update_state(2, .{ .left_shift = true });

    try std.testing.expectEqual(.none, session.receive(&command(.connect)));

    const hello = take(&session).?;
    try std.testing.expectEqual(@backingInt(companion.MessageId.hello), hello[0]);
    try std.testing.expectEqual(companion.protocol_version, hello[1]);
    try std.testing.expectEqual(36, hello[2]);
    try std.testing.expectEqual(4, hello[3]);
    try std.testing.expectEqualSlices(u8, &info.keymap_id, hello[4..20]);

    const state = take(&session).?;
    try std.testing.expectEqual(@backingInt(companion.MessageId.state), state[0]);
    try std.testing.expectEqual(0, state[1]);
    try std.testing.expectEqual(2, state[2]);
    try std.testing.expectEqual((core.Modifiers{ .left_shift = true }).toByte(), state[3]);
    try std.testing.expectEqual(0b10, state[4 + 1]); // key 9 is bit 1 of byte 1

    try std.testing.expectEqual(null, session.next_report());
}

test "companion session streams key events with sequence numbers" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);

    session.key_event(true, 5, 1, .{});
    session.key_event(false, 5, 1, .{});

    const press = take(&session).?;
    try std.testing.expectEqualSlices(u8, &.{ @backingInt(companion.MessageId.key), 1, 1, 5, 1, 0 }, press[0..6]);
    const release = take(&session).?;
    try std.testing.expectEqualSlices(u8, &.{ @backingInt(companion.MessageId.key), 2, 0, 5, 1, 0 }, release[0..6]);
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session keeps a report until the endpoint accepts it" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    const first = session.next_report().?;
    try std.testing.expectEqual(first, session.next_report().?);
}

test "companion session resynchronises with a state report after dropping events" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);

    for (0..33) |i| session.key_event(i % 2 == 0, 7, 0, .{});

    const state = take(&session).?;
    try std.testing.expectEqual(@backingInt(companion.MessageId.state), state[0]);
    try std.testing.expectEqual(0b1000_0000, state[4]); // key 7 is still pressed
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session reports layer changes and stops on disconnect" {
    var session = companion.Session.init(info);
    _ = session.receive(&command(.connect));
    _ = take(&session);
    _ = take(&session);

    session.update_state(3, .{});
    try std.testing.expectEqual(3, take(&session).?[2]);

    _ = session.receive(&command(.disconnect));
    session.key_event(true, 1, 0, .{});
    try std.testing.expectEqual(null, session.next_report());
}

test "companion session asks for the bootloader and ignores unknown commands" {
    var session = companion.Session.init(info);
    try std.testing.expectEqual(.enter_bootloader, session.receive(&command(.enter_bootloader)));
    var unknown: companion.Report = @splat(0);
    unknown[0] = 0x7F;
    try std.testing.expectEqual(.none, session.receive(&unknown));
    try std.testing.expectEqual(null, session.next_report());
}
