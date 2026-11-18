//! The starting points of a new layout on one keyboard, and the candidate
//! project each produces before anything is written.
const std = @import("std");
const p = @import("project");
const importer = @import("keymap-importer");
const labels = @import("labels.zig");
const library = @import("library.zig");
pub const transfer = @import("layout_transfer.zig");
const boards = importer.boards;
const catalog = importer.catalog;

pub const Template = struct {
    label: []const u8,
    selector: []const u8,
    /// A built-in LK7 layout instead of the selector's firmware default.
    curated: ?p.profiles.Profile = null,
};

const lk7_templates = [_]Template{
    .{ .label = "Rollercole · default", .selector = "lk7", .curated = .danish },
    .{ .label = "QWERTY", .selector = "lk7", .curated = .qwerty },
    .{ .label = "EurKEY draft", .selector = "lk7", .curated = .eurkey },
    .{ .label = "EurKEY Next Mac", .selector = "lk7", .curated = .eurmac },
};

/// The templates of the hardware of `entry`: the firmware default of each of
/// its selectors. The LK7 offers its built-in layouts, which share the board
/// identity of existing LK7 projects.
/// Room for every template of one keyboard.
pub const Templates = [catalog.entries.len + lk7_templates.len]Template;

pub fn templates(entry: *const catalog.Entry, out: *Templates) []const Template {
    if (std.mem.eql(u8, entry.selector, "lk7")) return &lk7_templates;
    var len: usize = 0;
    for (&catalog.entries) |*candidate| {
        if (!library.sameHardware(candidate, entry)) continue;
        out[len] = .{ .label = candidate.display.template, .selector = candidate.selector };
        len += 1;
    }
    return out[0..len];
}

pub const Start = union(enum) {
    template: Template,
    /// A copy of the project at this path, moved onto this keyboard if it
    /// belongs to other hardware.
    duplicate: []const u8,
    /// One empty Base layer.
    blank,
};

pub const Candidate = struct {
    arena: std.heap.ArenaAllocator,
    board: boards.OwnedBoard,
    snapshot: p.snapshot.Snapshot,
    /// What a copy from other hardware could not carry over.
    report: ?transfer.Report = null,
    transferred: ?transfer.Transferred = null,
    /// Keycap captions per layer, in key-index order.
    captions: []const []const []const u8,

    pub fn deinit(self: *Candidate) void {
        if (self.transferred) |*value| value.deinit();
        self.board.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The board new layouts on this hardware use. The LK7 keeps the curated
/// identity of the existing LK7 projects.
pub fn targetBoard(gpa: std.mem.Allocator, entry: *const catalog.Entry) !boards.OwnedBoard {
    if (std.mem.eql(u8, entry.selector, "lk7")) {
        var curated = try p.profiles.create(gpa, .qwerty);
        defer curated.deinit();
        return boards.OwnedBoard.fromDocument(gpa, curated.snapshot.document);
    }
    return boards.OwnedBoard.init(gpa, entry.selector);
}

/// Builds the project a start point yields on the keyboard of `entry`.
/// Reading a project to duplicate never changes it.
pub fn prepare(gpa: std.mem.Allocator, io: std.Io, entry: *const catalog.Entry, start: Start) !Candidate {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var board: boards.OwnedBoard = undefined;
    var snapshot: p.snapshot.Snapshot = undefined;
    var transferred: ?transfer.Transferred = null;
    errdefer if (transferred) |*value| value.deinit();
    switch (start) {
        .template => |template| if (template.curated) |profile| {
            var created = try p.profiles.create(gpa, profile);
            defer created.deinit();
            board = try boards.OwnedBoard.fromDocument(gpa, created.snapshot.document);
            errdefer board.deinit();
            snapshot = try p.owned_zon.clone(a, created.snapshot);
        } else {
            board = try boards.OwnedBoard.init(gpa, template.selector);
            errdefer board.deinit();
            var created = try boards.createDefault(gpa, board);
            defer created.deinit();
            snapshot = try p.owned_zon.clone(a, created.snapshot);
        },
        .blank => {
            board = try targetBoard(gpa, entry);
            errdefer board.deinit();
            snapshot = try blank(a, board.board);
        },
        .duplicate => |path| {
            var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
            defer dir.close(io);
            const bytes = try dir.readFileAlloc(io, "project.zon", a, .limited(p.Limits.document_bytes));
            const document = try p.parse(a, bytes, null);
            var source_board = try boards.OwnedBoard.fromDocument(gpa, document);
            errdefer source_board.deinit();
            var loaded = try p.snapshot.load(gpa, io, dir, source_board.board);
            defer loaded.deinit();
            if (library.sameHardware(source_board.entry, entry)) {
                board = source_board;
                snapshot = try p.owned_zon.clone(a, loaded.snapshot);
            } else {
                source_board.deinit();
                board = try targetBoard(gpa, entry);
                errdefer board.deinit();
                transferred = try transfer.transfer(gpa, loaded.snapshot, board.board);
                snapshot = transferred.?.snapshot;
            }
        },
    }
    errdefer board.deinit();
    try p.snapshot.validate(snapshot, board.board);
    return .{
        .arena = arena,
        .board = board,
        .snapshot = snapshot,
        .report = if (transferred) |value| value.report else null,
        .transferred = transferred,
        .captions = try captions(a, snapshot.document),
    };
}

/// One Base layer with every key unassigned.
fn blank(a: std.mem.Allocator, board: p.Board) !p.snapshot.Snapshot {
    const ids = try a.alloc([]const u8, board.key_ids.len);
    for (board.key_ids, ids) |id, *copy| copy.* = try a.dupe(u8, id);
    const actions = try a.alloc(?p.Action, ids.len);
    @memset(actions, null);
    const layers = try a.alloc(p.Layer, 1);
    layers[0] = .{ .id = 1, .name = "Base", .actions = actions };
    const encoders = try a.alloc(p.Tap, board.encoder_actions);
    @memset(encoders, .{});
    return .{ .document = .{
        .schema_version = p.schema_version,
        .board_id = board.id,
        .profile_id = "blank001".*,
        .physical_layout = try a.dupe(u8, board.physical_layout),
        .name = "Blank layout",
        .key_ids = ids,
        .layers = layers,
        .encoders = encoders,
    }, .sources = &.{} };
}

/// Keycap captions of every layer; unassigned and disabled keys are blank.
pub fn captions(a: std.mem.Allocator, doc: p.Document) ![]const []const []const u8 {
    const result = try a.alloc([]const []const u8, doc.layers.len);
    for (doc.layers, result) |layer, *row| {
        const keys = try a.alloc([]const u8, layer.actions.len);
        for (layer.actions, keys) |action, *caption| {
            var buffer: [256]u8 = undefined;
            const text = if (action == null) "" else labels.keycap(action, doc, &buffer);
            caption.* = if (std.mem.eql(u8, text, "---")) "" else try a.dupe(u8, text);
        }
        row.* = keys;
    }
    return result;
}

/// A collection directory name for `name`: lowercase ASCII words joined by
/// hyphens, numbered when `taken` already holds it.
pub fn directoryName(buffer: []u8, name: []const u8, taken: anytype) []const u8 {
    var base: [96]u8 = undefined;
    var len: usize = 0;
    var hyphen = false;
    for (name) |byte| {
        if (len == base.len) break;
        if (std.ascii.isAlphanumeric(byte)) {
            if (hyphen and len != 0) {
                base[len] = '-';
                len += 1;
                if (len == base.len) break;
            }
            base[len] = std.ascii.toLower(byte);
            len += 1;
            hyphen = false;
        } else hyphen = true;
    }
    const stem = if (len == 0) "layout" else base[0..len];
    var number: usize = 1;
    while (true) : (number += 1) {
        const candidate = if (number == 1)
            std.fmt.bufPrint(buffer, "{s}", .{stem}) catch return stem
        else
            std.fmt.bufPrint(buffer, "{s}-{d}", .{ stem, number }) catch return stem;
        if (!taken.contains(candidate)) return candidate;
    }
}
