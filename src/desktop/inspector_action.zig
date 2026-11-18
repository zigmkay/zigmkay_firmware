//! Bind a rendered inspector intent to both document/selection and staged fields.
const std = @import("std");
const editing = @import("inspector_session.zig");
const Model = @import("model.zig").Model;
const p = @import("project");

pub const Intent = enum {
    none,
    copy,
    paste,
    apply,
    cancel,
    resolve_apply,
    resolve_discard,
    keep_editing,
    save_close,
    discard_close,
    keep_close,
};

pub fn stagedDigest(gpa: std.mem.Allocator, session: *const editing.Session) ![32]u8 {
    var writer = std.Io.Writer.Allocating.init(gpa);
    defer writer.deinit();
    try std.zon.stringify.serializeMaxDepth(
        .{ .selected = session.selected, .drafts = session.drafts },
        .{ .whitespace = false },
        &writer.writer,
        32,
    );
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(writer.written(), &digest, .{});
    return digest;
}

pub const Action = struct {
    snapshot: [32]u8,
    layer_id: p.LayerId,
    primary: usize,
    draft_digest: [32]u8,
    intent: Intent,

    pub fn capture(session: *const editing.Session, model: *const Model, intent: Intent) !Action {
        if (try session.stale(model)) return error.StaleInspectorAction;
        return .{
            .snapshot = session.starting_id,
            .layer_id = session.layer_id,
            .primary = session.primary,
            .draft_digest = try stagedDigest(model.gpa, session),
            .intent = intent,
        };
    }

    /// Validate immediately before the caller resolves pending edits or commits.
    pub fn validate(self: Action, session: *const editing.Session, model: *const Model) !void {
        if (!std.mem.eql(u8, &self.snapshot, &session.starting_id) or
            self.layer_id != session.layer_id or
            self.primary != session.primary or
            try session.stale(model)) return error.StaleInspectorAction;
        const current = try stagedDigest(model.gpa, session);
        if (!std.mem.eql(u8, &current, &self.draft_digest)) return error.StaleInspectorAction;
    }
};
