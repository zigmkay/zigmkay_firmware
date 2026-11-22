//! Read-only grouping of layout projects by keyboard hardware. A keyboard is a
//! catalog board and PCB revision; each schema-1 project is one layout on it.
//! Collection members, remembered projects and legacy profile folders are
//! listed where they are: nothing here writes, moves or rewrites a project.
const std = @import("std");
const p = @import("project");
const importer = @import("keymap-importer");
const labels = @import("labels.zig");
const boards = importer.boards;
pub const catalog = importer.catalog;

pub const max_layouts = 256;

pub const Layout = struct {
    name: []const u8,
    /// Absolute project directory.
    path: []const u8,
    /// The collection-relative directory of a member, null outside the collection.
    member: ?[]const u8,
    entry: *const catalog.Entry,
    board_id: [8]u8,
    profile_id: [8]u8,
    key_count: usize,
    layer_count: usize,
    combo_count: usize,
    callback_count: usize,
    encoder_count: usize,
    /// Last modification of `project.zon`, in nanoseconds since the epoch.
    modified: i96,
    /// Base-layer keycap captions in key-index order; unassigned keys are empty.
    base: []const []const u8,
};

/// One catalog board and PCB revision with the layouts made for it.
pub const Keyboard = struct {
    entry: *const catalog.Entry,
    /// Indices into `Library.layouts`, in discovery order.
    layouts: []const usize,
};

/// A project that is listed but could not be read. It stays untouched on disk.
pub const Unreadable = struct { path: []const u8, reason: []const u8 };

pub const Sources = struct {
    /// The collection root holding `workspace.zon`.
    collection: ?[]const u8 = null,
    /// The folder of legacy per-profile projects; its direct children are listed.
    projects: ?[]const u8 = null,
    /// Further absolute project paths, such as remembered profile projects.
    extra: []const []const u8 = &.{},
};

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    layouts: []const Layout = &.{},
    keyboards: []const Keyboard = &.{},
    unreadable: []const Unreadable = &.{},

    pub fn deinit(self: *Library) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Library, path: []const u8) ?usize {
        for (self.layouts, 0..) |layout, index| if (std.mem.eql(u8, layout.path, path)) return index;
        return null;
    }

    /// The keyboard of the same hardware as `entry`.
    pub fn keyboardFor(self: *const Library, entry: *const catalog.Entry) ?usize {
        for (self.keyboards, 0..) |keyboard, index| if (sameHardware(keyboard.entry, entry)) return index;
        return null;
    }
};

/// Selectors that differ only in their default template run on the same
/// hardware, so they share one keyboard.
pub fn sameHardware(a: *const catalog.Entry, b: *const catalog.Entry) bool {
    return std.mem.eql(u8, a.display.name, b.display.name) and std.mem.eql(u8, a.display.revision, b.display.revision);
}

const Candidate = struct { path: []const u8, member: ?[]const u8 };

pub fn load(gpa: std.mem.Allocator, io: std.Io, sources: Sources) !Library {
    var library: Library = .{ .arena = .init(gpa) };
    errdefer library.arena.deinit();
    const a = library.arena.allocator();
    var candidates: std.ArrayList(Candidate) = .empty;
    var unreadable: std.ArrayList(Unreadable) = .empty;
    if (sources.collection) |root| try collectMembers(a, gpa, io, root, &candidates, &unreadable);
    for (sources.extra) |path| try addCandidate(a, &candidates, .{ .path = path, .member = null });
    if (sources.projects) |folder| try collectFolder(a, io, folder, &candidates);
    var layouts: std.ArrayList(Layout) = .empty;
    for (candidates.items) |candidate| {
        if (layouts.items.len == max_layouts) break;
        const layout = read(a, gpa, io, sources.collection, candidate) catch |err| {
            try unreadable.append(a, .{ .path = candidate.path, .reason = @errorName(err) });
            continue;
        };
        try layouts.append(a, layout);
    }
    library.layouts = layouts.items;
    library.unreadable = unreadable.items;
    library.keyboards = try group(a, layouts.items);
    return library;
}

fn addCandidate(a: std.mem.Allocator, candidates: *std.ArrayList(Candidate), candidate: Candidate) !void {
    if (!std.fs.path.isAbsolute(candidate.path)) return;
    for (candidates.items) |existing| if (std.mem.eql(u8, existing.path, candidate.path)) return;
    try candidates.append(a, .{ .path = try a.dupe(u8, candidate.path), .member = candidate.member });
}

fn collectMembers(
    a: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    candidates: *std.ArrayList(Candidate),
    unreadable: *std.ArrayList(Unreadable),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return unreadable.append(a, .{ .path = try a.dupe(u8, root), .reason = @errorName(err) }),
    };
    defer dir.close(io);
    var manifest = p.collection.load(gpa, io, dir) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return unreadable.append(a, .{ .path = try a.dupe(u8, root), .reason = @errorName(err) }),
    };
    defer manifest.deinit();
    for (manifest.manifest.projects) |entry| {
        const path = try std.fs.path.join(a, &.{ root, entry.directory });
        try addCandidate(a, candidates, .{ .path = path, .member = try a.dupe(u8, entry.directory) });
    }
}

/// Lists the direct children of `folder` that hold a project.
fn collectFolder(a: std.mem.Allocator, io: std.Io, folder: []const u8, candidates: *std.ArrayList(Candidate)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |child| {
        if (child.kind != .directory or child.name.len == 0 or child.name[0] == '.') continue;
        var project = dir.openDir(io, child.name, .{ .follow_symlinks = false }) catch continue;
        defer project.close(io);
        _ = project.statFile(io, "project.zon", .{}) catch continue;
        try names.append(a, try a.dupe(u8, child.name));
        if (names.items.len == max_layouts) break;
    }
    std.mem.sortUnstable([]const u8, names.items, {}, lessThan);
    for (names.items) |name| try addCandidate(a, candidates, .{ .path = try std.fs.path.join(a, &.{ folder, name }), .member = null });
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn read(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, root: ?[]const u8, candidate: Candidate) !Layout {
    var dir = if (candidate.member) |relative| member: {
        var collection = try std.Io.Dir.cwd().openDir(io, root.?, .{});
        defer collection.close(io);
        break :member try p.collection.openProject(io, collection, relative);
    } else try std.Io.Dir.cwd().openDir(io, candidate.path, .{});
    defer dir.close(io);
    const bytes = try dir.readFileAlloc(io, "project.zon", a, .limited(p.Limits.document_bytes));
    const stat = try dir.statFile(io, "project.zon", .{});
    const doc = try p.parse(a, bytes, null);
    return describe(a, gpa, .{ .path = candidate.path, .member = candidate.member, .document = doc, .modified = stat.mtime.nanoseconds });
}

/// A layout that exists only in memory.
pub const Sample = struct {
    path: []const u8,
    member: ?[]const u8 = null,
    document: p.Document,
    modified: i96 = 0,
};

/// A library of in-memory documents, for offscreen galleries.
pub fn fromSamples(gpa: std.mem.Allocator, samples: []const Sample) !Library {
    var library: Library = .{ .arena = .init(gpa) };
    errdefer library.arena.deinit();
    const a = library.arena.allocator();
    const layouts = try a.alloc(Layout, samples.len);
    for (samples, layouts) |sample, *layout| {
        var copy = sample;
        copy.document = try p.owned_zon.clone(a, sample.document);
        layout.* = try describe(a, gpa, copy);
    }
    library.layouts = layouts;
    library.keyboards = try group(a, layouts);
    return library;
}

/// Summarizes a validated document; `a` owns the document and the result.
fn describe(a: std.mem.Allocator, gpa: std.mem.Allocator, sample: Sample) !Layout {
    const doc = sample.document;
    var board = try boards.OwnedBoard.fromDocument(gpa, doc);
    defer board.deinit();
    const base = try a.alloc([]const u8, doc.key_ids.len);
    for (base, doc.layers[0].actions) |*caption, action| {
        var buffer: [256]u8 = undefined;
        const text = if (action == null) "" else labels.keycap(action, doc, &buffer);
        // Disabled keys read "---" in the editor; previews leave them blank.
        caption.* = if (std.mem.eql(u8, text, "---")) "" else try a.dupe(u8, text);
    }
    return .{
        .name = doc.name,
        .path = sample.path,
        .member = sample.member,
        .entry = board.entry,
        .board_id = doc.board_id,
        .profile_id = doc.profile_id,
        .key_count = doc.key_ids.len,
        .layer_count = doc.layers.len,
        .combo_count = doc.combos.len,
        .callback_count = doc.callbacks.len,
        .encoder_count = doc.encoders.len,
        .modified = sample.modified,
        .base = base,
    };
}

fn group(a: std.mem.Allocator, layouts: []const Layout) ![]const Keyboard {
    var entries: std.ArrayList(*const catalog.Entry) = .empty;
    var members: std.ArrayList(std.ArrayList(usize)) = .empty;
    for (layouts, 0..) |layout, index| {
        const slot = for (entries.items, 0..) |entry, slot| {
            if (sameHardware(entry, layout.entry)) break slot;
        } else blk: {
            try entries.append(a, layout.entry);
            try members.append(a, .empty);
            break :blk entries.items.len - 1;
        };
        try members.items[slot].append(a, index);
    }
    const keyboards = try a.alloc(Keyboard, entries.items.len);
    for (keyboards, entries.items, members.items) |*keyboard, entry, list| keyboard.* = .{ .entry = entry, .layouts = list.items };
    return keyboards;
}

/// A short relative age such as "2 min ago" or "yesterday".
pub fn age(buffer: []u8, now: i96, then: i96) []const u8 {
    const seconds = @divTrunc(@max(0, now - then), std.time.ns_per_s);
    const minutes = @divTrunc(seconds, 60);
    const hours = @divTrunc(minutes, 60);
    const days = @divTrunc(hours, 24);
    return if (minutes < 1)
        "just now"
    else if (hours < 1)
        std.fmt.bufPrint(buffer, "{d} min ago", .{minutes}) catch "recently"
    else if (days < 1)
        std.fmt.bufPrint(buffer, "{d} h ago", .{hours}) catch "today"
    else if (days < 2)
        "yesterday"
    else if (days < 14)
        std.fmt.bufPrint(buffer, "{d} days ago", .{days}) catch "this month"
    else if (days < 60)
        std.fmt.bufPrint(buffer, "{d} weeks ago", .{@divTrunc(days, 7)}) catch "weeks ago"
    else
        std.fmt.bufPrint(buffer, "{d} months ago", .{@divTrunc(days, 30)}) catch "months ago";
}
