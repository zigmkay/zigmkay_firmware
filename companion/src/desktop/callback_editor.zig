//! Explicit source preparation borrows no editor state. Promotion is UI-thread only.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
pub const Kind = enum { attach, check, refresh };

pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    loaded: p.snapshot.Loaded,
    board: p.Board,
    snapshot: [32]u8,
    kind: Kind,
    index: usize,
    entry: []const u8,
    ids: []const u8,
    required_layers: []const p.LayerId,

    pub fn capture(
        model: *const Model,
        kind: Kind,
        index: usize,
        entry: []const u8,
        ids: []const u8,
        required_layers: []const p.LayerId,
    ) !Request {
        if (kind != .attach) {
            if (index >= model.document().callbacks.len) return error.InvalidCallback;
            if (model.document().callbacks[index].kind != .attached) return error.RegisteredCallbackReadOnly;
        } else if (!p.pathValid(entry)) return error.InvalidPath;
        var arena: std.heap.ArenaAllocator = .init(model.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const board = try p.owned_zon.clone(a, model.board);
        const owned_entry = try a.dupe(u8, entry);
        const owned_ids = try a.dupe(u8, ids);
        const owned_layers = try a.dupe(p.LayerId, required_layers);
        var loaded = try p.snapshot.clone(model.gpa, model.current.snapshot);
        errdefer loaded.deinit();
        const digest = try model.id();
        return .{
            .arena = arena,
            .loaded = loaded,
            .board = board,
            .snapshot = digest,
            .kind = kind,
            .index = index,
            .entry = owned_entry,
            .ids = owned_ids,
            .required_layers = owned_layers,
        };
    }

    pub fn deinit(self: *Request) void {
        self.loaded.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Explicit caller-selected source/project directory. Never compiles source.
    /// The request must remain alive until preparation returns.
    pub fn prepare(self: *const Request, gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Prepared {
        var next = switch (self.kind) {
            .attach => blk: {
                var bundle = try p.sources.capture(gpa, io, dir, self.entry);
                defer bundle.deinit();
                break :blk try p.sources.attachForBoard(
                    gpa,
                    self.loaded.snapshot,
                    self.board,
                    bundle,
                    self.ids,
                    self.required_layers,
                );
            },
            .check, .refresh => try p.sources.refreshForBoard(
                gpa,
                io,
                dir,
                self.loaded.snapshot,
                self.board,
                self.index,
            ),
        };
        errdefer next.deinit();
        const digest = try p.snapshot.projectDigest(gpa, next.snapshot, self.board);
        return .{ .loaded = next, .captured = self.snapshot, .next = digest, .kind = self.kind };
    }
};

pub const Prepared = struct {
    loaded: p.snapshot.Loaded,
    captured: [32]u8,
    next: [32]u8,
    kind: Kind,
    consumed: bool = false,

    pub fn deinit(self: *Prepared) void {
        self.loaded.deinit();
        self.* = undefined;
    }

    /// Check reports differences without changing history. Each result is single use.
    pub fn promote(self: *Prepared, model: *Model) !bool {
        if (self.consumed or !std.mem.eql(u8, &self.captured, &(try model.id()))) return error.StaleCallbackAction;
        const changed = !std.mem.eql(u8, &self.captured, &self.next);
        if (self.kind != .check) try model.commit(self.loaded.snapshot);
        self.consumed = true;
        return changed;
    }
};

/// Creating mirrors requires a fresh document and explicit caller action.
pub fn checkout(model: *const Model, captured: [32]u8, io: std.Io, dir: std.Io.Dir, index: usize) !void {
    if (!std.mem.eql(u8, &captured, &(try model.id()))) return error.StaleCallbackAction;
    try p.sources.checkout(model.gpa, io, dir, model.current.snapshot, index);
}
