//! The import comparison: an analyzed keymap on the catalog board with its
//! key count, next to the result on the chosen keyboard. Nothing is written.
const std = @import("std");
const p = @import("project");
const importer = @import("keymap-importer");
const new_layout = @import("new_layout.zig");
const transfer = @import("layout_transfer.zig");
const boards = importer.boards;
const catalog = importer.catalog;

/// The catalog board an analyzed keymap is drawn on: the target when its
/// dimensions fit, otherwise the first board with the same key count and
/// encoder directions.
pub fn sourceEntry(data: importer.Data, target: *const catalog.Entry) ?*const catalog.Entry {
    if (data.layers.len == 0) return null;
    const keys = data.layers[0].len;
    if (fits(data, target, keys)) return target;
    for (&catalog.entries) |*entry| if (fits(data, entry, keys)) return entry;
    return null;
}

fn fits(data: importer.Data, entry: *const catalog.Entry, keys: usize) bool {
    return entry.default_dimensions.key_count == keys and entry.encoder_action_slots == data.encoders.len and
        !std.mem.eql(u8, entry.selector, "lk7");
}

pub const Comparison = struct {
    arena: std.heap.ArenaAllocator,
    source_entry: *const catalog.Entry,
    target_entry: *const catalog.Entry,
    /// Base-layer captions of the found keymap and of the result.
    source_captions: []const []const u8,
    target_captions: []const []const u8,
    report: transfer.Report,
    callbacks: bool,

    pub fn deinit(self: *Comparison) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Compares the analyzed keymap with the keyboard of `target`, with the
/// captured callback source when the keymap has callbacks.
pub fn compare(gpa: std.mem.Allocator, data: importer.Data, callback_sources: []const catalog.SourceFile, target: *const catalog.Entry) !Comparison {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const source_entry = sourceEntry(data, target) orelse return error.NoCatalogBoardWithThisKeyCount;
    var source_board = try boards.OwnedBoard.init(gpa, source_entry.selector);
    defer source_board.deinit();
    var source = try boards.createData(gpa, source_board, .{
        .entry = source_entry,
        .layers = data.layers,
        .combos = data.combos,
        .sides = data.sides,
        .encoder_actions = data.encoders,
        .has_callbacks = data.has_callbacks,
        .callback_sources = if (data.has_callbacks) callback_sources else &.{},
    });
    defer source.deinit();
    var target_board = try new_layout.targetBoard(gpa, target);
    defer target_board.deinit();
    var moved = try transfer.transfer(gpa, source.snapshot, target_board.board);
    defer moved.deinit();
    const source_captions = try new_layout.captions(a, source.snapshot.document);
    const target_captions = try new_layout.captions(a, moved.snapshot.document);
    var report = moved.report;
    report.missing = try a.dupe(bool, report.missing);
    report.origin = try a.dupe(?usize, report.origin);
    report.callbacks = @intFromBool(data.has_callbacks);
    return .{
        .arena = arena,
        .source_entry = source_entry,
        .target_entry = target,
        .source_captions = source_captions[0],
        .target_captions = target_captions[0],
        .report = report,
        .callbacks = data.has_callbacks,
    };
}

/// Prepares the import onto `target`. A keymap that fits the target
/// converts directly; any other is converted on the board with its key count
/// and moved onto the target like a layout from another revision.
pub fn prepare(
    gpa: std.mem.Allocator,
    io: std.Io,
    capture: importer.Captured,
    analysis: importer.Analysis,
    target: *const catalog.Entry,
    name: []const u8,
    profile_id: [8]u8,
) !importer.Prepared {
    const data = analysis.data;
    if (importer.compatible(data, target.*)) return importer.prepare(gpa, io, capture, analysis, target.selector, name, profile_id);
    const source_entry = sourceEntry(data, target) orelse return error.NoCatalogBoardWithThisKeyCount;
    var converted = try importer.convert(gpa, io, capture, analysis, try boards.OwnedBoard.init(gpa, source_entry.selector), name, profile_id);
    defer converted.deinit();
    var target_board = try new_layout.targetBoard(gpa, target);
    errdefer target_board.deinit();
    var moved = try transfer.transfer(gpa, converted.project.snapshot, target_board.board);
    defer moved.deinit();
    var project: boards.OwnedProject = .{ .arena = .init(gpa), .snapshot = undefined };
    errdefer project.deinit();
    project.snapshot = try p.owned_zon.clone(project.arena.allocator(), moved.snapshot);
    try p.sources.verify(project.arena.allocator(), project.snapshot);
    return .{ .board = target_board, .project = project, .captured = converted.captured };
}
