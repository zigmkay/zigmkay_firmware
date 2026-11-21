//! Encoder action slots, staged per slot and applied together.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;

/// The way a knob turns. A knob's push button is a matrix key, not a slot.
pub const Direction = enum {
    clockwise,
    counter_clockwise,

    pub fn name(self: Direction) []const u8 {
        return switch (self) {
            .clockwise => "Clockwise",
            .counter_clockwise => "Counter-clockwise",
        };
    }
};

/// What a slot does: one direction of one knob, counted from 0.
pub const Slot = struct { knob: usize, direction: Direction };

/// Every board entrypoint wires knob n to slot 2n clockwise and slot 2n + 1
/// counter-clockwise; see `encoder_actions` in `processing_descriptors.zig`.
pub fn slot(index: usize) Slot {
    return .{ .knob = index / 2, .direction = if (index % 2 == 0) .clockwise else .counter_clockwise };
}

/// The index of the slot that turns `knob` in `direction`.
pub fn slotIndex(knob: usize, direction: Direction) usize {
    return 2 * knob + @backingInt(direction);
}

/// The knobs that `count` slots reach; an odd last slot is a clockwise-only knob.
pub fn knobs(count: usize) usize {
    return (count + 1) / 2;
}

/// The spelled-out slot: "Clockwise" on a one-knob board, "Knob 2 ·
/// Counter-clockwise" when there are several knobs.
pub fn slotName(index: usize, count: usize, buffer: []u8) []const u8 {
    const turn = slot(index);
    if (knobs(count) <= 1) return turn.direction.name();
    return std.fmt.bufPrint(buffer, "Knob {d} · {s}", .{ turn.knob + 1, turn.direction.name() }) catch turn.direction.name();
}
pub const Kind = enum { apply, discard };
pub const Action = struct { snapshot: [32]u8, count: usize, index: usize, drafts: [256]p.Tap, kind: Kind };

pub const Session = struct {
    snapshot: [32]u8,
    count: usize,
    index: usize = 0,
    original: [256]p.Tap = @splat(.{}),
    drafts: [256]p.Tap = @splat(.{}),

    pub fn init(model: *const Model) !Session {
        const source = model.document().encoders;
        if (source.len > 256) return error.InvalidEncoderDimensions;
        var session = Session{ .snapshot = try model.id(), .count = source.len };
        @memcpy(session.original[0..source.len], source);
        session.drafts = session.original;
        return session;
    }

    pub fn fresh(self: *const Session, model: *const Model) !bool {
        return std.mem.eql(u8, &self.snapshot, &(try model.id()));
    }

    pub fn dirty(self: *const Session) bool {
        return !std.meta.eql(self.original, self.drafts);
    }

    pub fn action(self: *const Session, kind: Kind) Action {
        return .{
            .snapshot = self.snapshot,
            .count = self.count,
            .index = self.index,
            .drafts = self.drafts,
            .kind = kind,
        };
    }

    pub fn dispatch(self: *Session, model: *Model, rendered: Action) !void {
        if (!try self.fresh(model) or
            !std.meta.eql(rendered, self.action(rendered.kind))) return error.StaleEncoderAction;
        if (self.count != model.document().encoders.len or
            self.count > 256 or
            (self.count != 0 and self.index >= self.count)) return error.InvalidEncoderDimensions;
        switch (rendered.kind) {
            .apply => {
                try model.setEncoders(rendered.drafts[0..rendered.count]);
                const index = self.index;
                self.* = try init(model);
                self.index = index;
            },
            .discard => self.drafts = self.original,
        }
    }
};
