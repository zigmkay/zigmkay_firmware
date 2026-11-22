//! Owned callback preparation/checkouts with no borrowed editor or directory.
const std = @import("std");
const p = @import("project");
const callback = @import("callback_editor.zig");
const Model = @import("model.zig").Model;
pub const Owner = @import("owned_worker.zig").Owner(Request, Prepared, error.InvalidSourceGeneration);

pub const Request = struct {
    captured: [32]u8,
    root: [4096]u8 = @splat(0),
    callback: ?callback.Request = null,
    checkout: ?p.snapshot.Loaded = null,
    index: usize = 0,

    fn path(root: []const u8) ![4096]u8 {
        if (!std.fs.path.isAbsolute(root) or
            root.len >= 4096 or
            std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidSourcePath;
        var owned: [4096]u8 = @splat(0);
        @memcpy(owned[0..root.len], root);
        return owned;
    }

    /// Transfers the inner request on success only.
    pub fn prepareCallback(inner: *callback.Request, root: []const u8) !Request {
        const directory = try path(root);
        const request = Request{ .captured = inner.snapshot, .root = directory, .callback = inner.* };
        inner.* = undefined;
        return request;
    }

    pub fn captureCheckout(model: *const Model, root: []const u8, index: usize) !Request {
        if (index >= model.document().callbacks.len) return error.InvalidCallback;
        const directory = try path(root);
        const captured = try model.id();
        return .{
            .captured = captured,
            .root = directory,
            .index = index,
            .checkout = try p.snapshot.clone(model.gpa, model.current.snapshot),
        };
    }

    pub fn deinit(self: *Request) void {
        if (self.callback) |*inner| inner.deinit();
        if (self.checkout) |*loaded| loaded.deinit();
        self.* = undefined;
    }

    pub fn prepare(self: *const Request, gpa: std.mem.Allocator, io: std.Io) !Prepared {
        const directory = std.mem.sliceTo(&self.root, 0);
        var dir = if (self.checkout != null) try std.Io.Dir.cwd().createDirPathOpen(io, directory, .{}) else try std.Io.Dir.cwd().openDir(io, directory, .{});
        defer dir.close(io);
        if (self.checkout) |loaded| {
            try p.sources.checkout(gpa, io, dir, loaded.snapshot, self.index);
            return .{ .captured = self.captured };
        }
        return .{ .captured = self.captured, .callback = try self.callback.?.prepare(gpa, io, dir) };
    }
};

pub const Prepared = struct {
    captured: [32]u8,
    callback: ?callback.Prepared = null,
    consumed: bool = false,

    pub fn deinit(self: *Prepared) void {
        if (self.callback) |*inner| inner.deinit();
        self.* = undefined;
    }

    pub fn promote(self: *Prepared, model: *Model) !bool {
        if (self.consumed or !std.mem.eql(u8, &self.captured, &(try model.id()))) return error.StaleCallbackAction;
        const changed = if (self.callback) |*inner| try inner.promote(model) else false;
        self.consumed = true;
        return changed;
    }
};
