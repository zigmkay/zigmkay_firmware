//! Key and host-palette labels of one project snapshot, translated through
//! one host input source revision.
const std = @import("std");
const desktop = @import("desktop-core");

const Captions = @This();

labels: desktop.label_cache.LabelCache,
host: desktop.host_palette.Cache,
snapshot: [32]u8,
revision: u64,

pub fn init(
    gpa: std.mem.Allocator,
    model: *const desktop.model.Model,
    translator: anytype,
    identity: []const u8,
    revision: u64,
) !Captions {
    var labels = try desktop.label_cache.buildProjectCache(gpa, translator, model.document());
    errdefer labels.deinit();
    var host = try desktop.host_palette.Cache.init(gpa, desktop.labels.running_host, identity, revision, translator);
    errdefer host.deinit();
    return .{ .labels = labels, .host = host, .snapshot = try model.id(), .revision = revision };
}

pub fn deinit(self: *Captions) void {
    self.labels.deinit();
    self.host.deinit();
}

/// Rebuilds the captions for a new source revision. Both caches are built
/// before either is replaced, so a failure keeps the current captions.
pub fn refresh(
    self: *Captions,
    gpa: std.mem.Allocator,
    model: *const desktop.model.Model,
    translator: anytype,
    identity: []const u8,
    revision: u64,
) !void {
    if (self.revision == revision) return;
    const replacement = try Captions.init(gpa, model, translator, identity, revision);
    self.deinit();
    self.* = replacement;
}
