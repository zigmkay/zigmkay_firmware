const std = @import("std");
const p = @import("root.zig");
const protocol = @import("device-protocol");
const model = @import("layout-model");

pub const SourceBytes = struct { callback_index: usize, path: []const u8, bytes: []const u8 };
/// Sources are caller-owned immutable bytes. Each declared file appears exactly once.
pub const Snapshot = struct { document: p.Document, sources: []const SourceBytes };

pub fn clone(gpa: std.mem.Allocator, snapshot: Snapshot) !Loaded {
    const bytes = try p.serialize(gpa, snapshot.document);
    defer gpa.free(bytes);
    const document = try p.parse(gpa, bytes, null);
    errdefer p.deinit(gpa, document);
    var sources: std.ArrayList(SourceBytes) = .empty;
    errdefer {
        for (sources.items) |source| gpa.free(source.bytes);
        sources.deinit(gpa);
    }
    for (snapshot.sources) |source| {
        const data = try gpa.dupe(u8, source.bytes);
        errdefer gpa.free(data);
        var owned_path: ?[]const u8 = null;
        if (source.callback_index >= document.callbacks.len) return error.UnexpectedSource;
        for (document.callbacks[source.callback_index].sources) |entry| if (std.mem.eql(u8, entry.path, source.path)) {
            owned_path = entry.path;
        };
        try sources.append(gpa, .{
            .callback_index = source.callback_index,
            .path = owned_path orelse return error.UnexpectedSource,
            .bytes = data,
        });
    }
    return .{ .snapshot = .{ .document = document, .sources = try sources.toOwnedSlice(gpa) }, .gpa = gpa };
}

fn addFramed(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .little);
    hash.update(&length);
    hash.update(bytes);
}

/// Bundle location depends on ordered paths and their hashes, not mutable directory state.
pub fn bundleDigest(callback: p.Callback) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-callback-source-v1\x00");
    var abi: [2]u8 = undefined;
    std.mem.writeInt(u16, &abi, callback.abi_version, .little);
    hash.update(&abi);
    for (callback.sources) |source| {
        addFramed(&hash, source.path);
        hash.update(&source.digest);
    }
    return hash.finalResult();
}

pub fn find(snapshot: Snapshot, callback_index: usize, path: []const u8) ![]const u8 {
    for (snapshot.sources) |source| {
        if (source.callback_index == callback_index and std.mem.eql(u8, source.path, path)) return source.bytes;
    }
    return error.MissingSource;
}

pub fn validate(snapshot: Snapshot, board: p.Board) !void {
    try p.validate(snapshot.document, board);
    var total: usize = 0;
    var count: usize = 0;
    for (snapshot.document.callbacks, 0..) |callback, ci| {
        for (callback.sources) |source| {
            count += 1;
            const bytes = try find(snapshot, ci, source.path);
            if (bytes.len > p.Limits.source_bytes - total) return error.SourceLimit;
            total += bytes.len;
            var actual: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
            if (!std.mem.eql(u8, &actual, &source.digest)) return error.SourceMismatch;
        }
    }
    if (snapshot.sources.len != count) return error.UnexpectedSource;
    for (snapshot.sources, 0..) |source, index| {
        if (source.callback_index >= snapshot.document.callbacks.len) return error.UnexpectedSource;
        var declared = false;
        for (snapshot.document.callbacks[source.callback_index].sources) |entry| if (std.mem.eql(u8, source.path, entry.path)) {
            declared = true;
        };
        if (!declared) return error.UnexpectedSource;
        for (snapshot.sources[0..index]) |earlier| {
            if (source.callback_index == earlier.callback_index and
                std.mem.eql(u8, source.path, earlier.path)) return error.DuplicateSource;
        }
    }
}

pub fn identity(gpa: std.mem.Allocator, snapshot: Snapshot, board: p.Board) !protocol.Identity {
    try validate(snapshot, board);
    const doc = snapshot.document;
    const keys = try gpa.alloc(?model.KeyDef, doc.layers.len * doc.key_ids.len);
    defer gpa.free(keys);
    for (doc.layers, 0..) |layer, li| for (layer.actions, 0..) |action, ki| {
        keys[li * doc.key_ids.len + ki] = if (action) |value| try p.lowerAction(doc, value) else null;
    };
    const combos = try gpa.alloc(model.Combo2Def, doc.combos.len);
    defer gpa.free(combos);
    for (doc.combos, combos) |combo, *lowered| lowered.* = .{
        .key_indexes = .{ try p.keyIndex(doc, combo.key_ids[0]), try p.keyIndex(doc, combo.key_ids[1]) },
        .layer = try p.layerIndex(doc, combo.layer_id),
        .timeout = combo.timeout,
        .key_def = try p.lowerAction(doc, combo.action),
    };
    const encoders = try gpa.alloc(model.EncoderAction, doc.encoders.len);
    defer gpa.free(encoders);
    for (doc.encoders, encoders) |tap, *lowered| lowered.* = .{ .tap = try p.lowerTap(doc, tap) };
    var callbacks: std.ArrayList(protocol.CallbackIdentity) = .empty;
    defer {
        for (callbacks.items) |callback| gpa.free(callback.behavior);
        callbacks.deinit(gpa);
    }
    for (doc.callbacks) |callback| {
        const digest = bundleDigest(callback);
        for (callback.ids) |id| {
            const behavior = try std.fmt.allocPrint(gpa, "source-v1:{s}:{s}", .{
                callback.binding,
                std.fmt.bytesToHex(digest, .lower),
            });
            errdefer gpa.free(behavior);
            try callbacks.append(gpa, .{ .id = id, .behavior = behavior });
        }
    }
    return protocol.computeIdentity(.{
        .board_id = doc.board_id,
        .profile_id = doc.profile_id,
        .dimensions = .{ .key_count = @intCast(doc.key_ids.len), .layer_count = @intCast(doc.layers.len) },
        .keys = keys,
        .sides = board.sides,
        .combos = combos,
        .encoders = encoders,
        .callbacks = callbacks.items,
    });
}

/// Metadata-inclusive freshness hash; telemetry identity deliberately excludes layer names.
pub fn projectDigest(gpa: std.mem.Allocator, snapshot: Snapshot, board: p.Board) ![32]u8 {
    try validate(snapshot, board);
    const bytes = try p.serialize(gpa, snapshot.document);
    defer gpa.free(bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("zigmkay-project-v1\x00");
    addFramed(&hash, bytes);
    for (snapshot.document.callbacks) |callback| hash.update(&bundleDigest(callback));
    return hash.finalResult();
}

pub fn sourceLocation(gpa: std.mem.Allocator, callback: p.Callback, path: []const u8) ![]u8 {
    const digest = bundleDigest(callback);
    return std.fmt.allocPrint(gpa, ".sources/{s}/{s}", .{ std.fmt.bytesToHex(digest, .lower), path });
}

fn atomicWrite(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8, replace: bool) !void {
    var file = try dir.createFileAtomic(io, path, .{ .replace = replace });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    if (replace) try file.replace(io) else try file.link(io);
}

/// Save into an explicitly selected project directory. Never writes profile source files.
/// Immutable source bundles are materialized before the single atomic document commit.
/// Failures may leave unreferenced bundles; the previous document and bundles stay readable.
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, snapshot: Snapshot, board: p.Board) !void {
    try saveChecked(gpa, io, dir, snapshot, board, null);
}

/// Cooperating writers keep the same lock inode across atomic document replaces.
/// The lock file is retained; unlinking it would let later writers bypass a holder.
pub fn saveChecked(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    snapshot: Snapshot,
    board: p.Board,
    expected: ?[32]u8,
) !void {
    const lock = try dir.createFile(io, ".project.lock", .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    if (expected) |baseline| {
        const present = dir.openFile(io, "project.zon", .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (present) |file| {
            file.close(io);
            var previous = try load(gpa, io, dir, board);
            defer previous.deinit();
            if (!std.mem.eql(u8, &baseline, &try projectDigest(gpa, previous.snapshot, board)))
                return error.ExternalProjectChanged;
        }
    }
    try validate(snapshot, board);
    const document = try p.serialize(gpa, snapshot.document);
    defer gpa.free(document);
    for (snapshot.document.callbacks, 0..) |callback, ci| for (callback.sources) |source| {
        const path = try sourceLocation(gpa, callback, source.path);
        defer gpa.free(path);
        try dir.createDirPath(io, std.fs.path.dirname(path).?);
        const bytes = try find(snapshot, ci, source.path);
        atomicWrite(io, dir, path, bytes, false) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const existing = try dir.readFileAlloc(io, path, gpa, .limited(p.Limits.source_bytes));
                defer gpa.free(existing);
                if (!std.mem.eql(u8, existing, bytes)) return error.SourceMismatch;
            },
            else => return err,
        };
    };
    try atomicWrite(io, dir, "project.zon", document, true);
}

pub const Loaded = struct {
    snapshot: Snapshot,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Loaded) void {
        for (self.snapshot.sources) |source| self.gpa.free(source.bytes);
        self.gpa.free(self.snapshot.sources);
        p.deinit(self.gpa, self.snapshot.document);
        self.* = undefined;
    }
};

pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, board: p.Board) !Loaded {
    const bytes = try dir.readFileAlloc(io, "project.zon", gpa, .limited(p.Limits.document_bytes));
    defer gpa.free(bytes);
    const doc = try p.parse(gpa, bytes, null);
    errdefer p.deinit(gpa, doc);
    try p.validate(doc, board);
    var sources: std.ArrayList(SourceBytes) = .empty;
    errdefer {
        for (sources.items) |source| gpa.free(source.bytes);
        sources.deinit(gpa);
    }
    var total: usize = 0;
    for (doc.callbacks, 0..) |callback, ci| for (callback.sources) |source| {
        const path = try sourceLocation(gpa, callback, source.path);
        defer gpa.free(path);
        const contents = try dir.readFileAlloc(io, path, gpa, .limited(p.Limits.source_bytes - total));
        errdefer gpa.free(contents);
        total += contents.len;
        try sources.append(gpa, .{ .callback_index = ci, .path = source.path, .bytes = contents });
    };
    const snapshot = Snapshot{ .document = doc, .sources = sources.items };
    try validate(snapshot, board);
    return .{ .snapshot = .{ .document = doc, .sources = try sources.toOwnedSlice(gpa) }, .gpa = gpa };
}
