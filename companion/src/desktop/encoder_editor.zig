//! Independent encoder action slots. Physical direction mappings are not inferred.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
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
