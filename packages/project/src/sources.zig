const std = @import("std");
const p = @import("root.zig");

fn moduleName(name: []const u8) bool {
    for ([_][]const u8{ "std", "zigmkay", "layout-model", "zkeycodes" }) |allowed| if (std.mem.eql(u8, name, allowed)) return true;
    return false;
}
pub fn resolve(gpa: std.mem.Allocator, from: []const u8, name: []const u8) ![]u8 {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '\\') != null or std.mem.indexOfScalar(u8, name, ':') != null) return error.InvalidImport;
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    if (std.fs.path.dirname(from)) |parent| {
        var parent_parts = std.mem.splitScalar(u8, parent, '/');
        while (parent_parts.next()) |part| try parts.append(gpa, part);
    }
    var names = std.mem.splitScalar(u8, name, '/');
    while (names.next()) |part| {
        if (part.len == 0) return error.InvalidImport;
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.ImportEscapesProject;
            _ = parts.pop();
        } else try parts.append(gpa, part);
    }
    const path = try std.mem.join(gpa, "/", parts.items);
    errdefer gpa.free(path);
    if (!p.pathValid(path)) return error.InvalidImport;
    return path;
}
fn imports(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) ![][]u8 {
    const text = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(text);
    var tokenizer = std.zig.Tokenizer.init(text);
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |entry| gpa.free(entry);
        paths.deinit(gpa);
    }
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .builtin) continue;
        const builtin_name = text[token.loc.start..token.loc.end];
        if (std.mem.eql(u8, builtin_name, "@cImport")) return error.CImportUnsupported;
        const embed = std.mem.eql(u8, builtin_name, "@embedFile");
        if (!embed and !std.mem.eql(u8, builtin_name, "@import")) continue;
        if (tokenizer.next().tag != .l_paren) return error.InvalidImport;
        const literal = tokenizer.next();
        if (literal.tag != .string_literal) return error.DynamicImportUnsupported;
        const name = try std.zig.string_literal.parseAlloc(gpa, text[literal.loc.start..literal.loc.end]);
        defer gpa.free(name);
        if (tokenizer.next().tag != .r_paren) return error.DynamicImportUnsupported;
        if (!embed and moduleName(name)) continue;
        const resolved = try resolve(gpa, path, name);
        errdefer gpa.free(resolved);
        try paths.append(gpa, resolved);
    }
    return paths.toOwnedSlice(gpa);
}
/// Static literal import closure only. This never evaluates Zig or proves arbitrary behavior.
pub fn verify(gpa: std.mem.Allocator, snapshot: p.snapshot.Snapshot) !void {
    for (snapshot.document.callbacks, 0..) |_, ci| _ = try p.profiles.callbackEntry(snapshot, ci);
    for (snapshot.sources) |source| {
        const dependencies = try imports(gpa, source.path, source.bytes);
        defer {
            for (dependencies) |path| gpa.free(path);
            gpa.free(dependencies);
        }
        for (dependencies) |path| _ = p.snapshot.find(snapshot, source.callback_index, path) catch return error.UnresolvedImport;
    }
}
pub const Bundle = struct {
    arena: std.heap.ArenaAllocator,
    entry: []const u8,
    metadata: []const p.Source,
    bytes: []const p.snapshot.SourceBytes,
    pub fn deinit(self: *Bundle) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
/// Copies an entry module and its literal owned import closure into immutable memory.
/// The caller explicitly supplies the directory root; absolute/escaping imports fail.
pub fn capture(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, entry: []const u8) !Bundle {
    if (!p.pathValid(entry)) return error.InvalidPath;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(a, try a.dupe(u8, entry));
    var sources: std.ArrayList(p.snapshot.SourceBytes) = .empty;
    var total: usize = 0;
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const path = pending.items[cursor];
        var seen = false;
        for (sources.items) |source| if (std.mem.eql(u8, source.path, path)) {
            seen = true;
        };
        if (seen) continue;
        if (sources.items.len >= p.Limits.source_files) return error.SourceLimit;
        // Walk literal components without following directory or file links.
        // A source closure must remain inside its explicitly selected root.
        var parent = dir;
        var owns_parent = false;
        defer if (owns_parent) parent.close(io);
        var parts = std.mem.splitScalar(u8, path, '/');
        var name = parts.next().?;
        while (parts.next()) |next| {
            const child = try parent.openDir(io, name, .{ .follow_symlinks = false });
            if (owns_parent) parent.close(io);
            parent = child;
            owns_parent = true;
            name = next;
        }
        const input = try parent.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false });
        defer input.close(io);
        if ((try input.stat(io)).kind != .file) return error.UnsupportedSourceKind;
        var buffer: [4096]u8 = undefined;
        var reader = input.reader(io, &buffer);
        const bytes = try reader.interface.allocRemaining(a, .limited(p.Limits.source_bytes - total));
        total += bytes.len;
        try sources.append(a, .{ .callback_index = 0, .path = path, .bytes = bytes });
        const dependencies = try imports(a, path, bytes);
        for (dependencies) |dependency| try pending.append(a, dependency);
    }
    std.mem.sort(p.snapshot.SourceBytes, sources.items, {}, struct {
        fn less(_: void, lhs: p.snapshot.SourceBytes, rhs: p.snapshot.SourceBytes) bool {
            return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        }
    }.less);
    const metadata = try a.alloc(p.Source, sources.items.len);
    for (sources.items, metadata) |source, *item| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source.bytes, &digest, .{});
        item.* = .{ .path = source.path, .digest = digest };
    }
    const owned_entry = try a.dupe(u8, entry);
    return .{ .arena = arena, .entry = owned_entry, .metadata = metadata, .bytes = sources.items };
}

pub fn attach(gpa: std.mem.Allocator, snapshot: p.snapshot.Snapshot, bundle: Bundle, ids: []const u8, required_layers: []const p.LayerId) !p.snapshot.Loaded {
    return attachForBoard(gpa, snapshot, p.profiles.board, bundle, ids, required_layers);
}
pub fn attachForBoard(gpa: std.mem.Allocator, snapshot: p.snapshot.Snapshot, board: p.Board, bundle: Bundle, ids: []const u8, required_layers: []const p.LayerId) !p.snapshot.Loaded {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = snapshot.document;
    const callbacks = try a.alloc(p.Callback, doc.callbacks.len + 1);
    @memcpy(callbacks[0..doc.callbacks.len], doc.callbacks);
    callbacks[doc.callbacks.len] = .{ .kind = .attached, .binding = bundle.entry, .ids = ids, .required_layers = required_layers, .sources = bundle.metadata };
    const sources = try a.alloc(p.snapshot.SourceBytes, snapshot.sources.len + bundle.bytes.len);
    @memcpy(sources[0..snapshot.sources.len], snapshot.sources);
    for (bundle.bytes, sources[snapshot.sources.len..]) |source, *dest| {
        dest.* = source;
        dest.callback_index = doc.callbacks.len;
    }
    doc.callbacks = callbacks;
    const result = p.snapshot.Snapshot{ .document = doc, .sources = sources };
    try p.snapshot.validate(result, board);
    try verify(a, result);
    return p.snapshot.clone(gpa, result);
}

/// Creates editable mirrors only through an explicit attachment/external-editor action.
/// Ordinary save/load never reads or overwrites these files.
pub fn checkout(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, snapshot: p.snapshot.Snapshot, index: usize) !void {
    if (index >= snapshot.document.callbacks.len) return error.InvalidCallback;
    if (snapshot.document.callbacks[index].kind != .attached) return error.RegisteredCallbackReadOnly;
    for (snapshot.sources) |source| {
        if (source.callback_index != index) continue;
        const path = try std.fmt.allocPrint(gpa, "callbacks/{d}/{s}", .{ index, source.path });
        defer gpa.free(path);
        try dir.createDirPath(io, std.fs.path.dirname(path).?);
        var file = try dir.createFileAtomic(io, path, .{ .replace = false });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, source.bytes);
        try file.file.sync(io);
        file.link(io) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

pub fn refresh(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, snapshot: p.snapshot.Snapshot, index: usize) !p.snapshot.Loaded {
    return refreshForBoard(gpa, io, dir, snapshot, p.profiles.board, index);
}
pub fn refreshForBoard(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, snapshot: p.snapshot.Snapshot, board: p.Board, index: usize) !p.snapshot.Loaded {
    if (index >= snapshot.document.callbacks.len) return error.InvalidCallback;
    const callback = snapshot.document.callbacks[index];
    if (callback.kind != .attached) return error.RegisteredCallbackReadOnly;
    const path = try std.fmt.allocPrint(gpa, "callbacks/{d}", .{index});
    defer gpa.free(path);
    var owned_dir = try dir.openDir(io, path, .{});
    defer owned_dir.close(io);
    var bundle = try capture(gpa, io, owned_dir, callback.binding);
    defer bundle.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const callbacks = try a.dupe(p.Callback, snapshot.document.callbacks);
    callbacks[index].sources = bundle.metadata;
    var files: std.ArrayList(p.snapshot.SourceBytes) = .empty;
    for (snapshot.sources) |source| if (source.callback_index != index) try files.append(a, source);
    for (bundle.bytes) |source| {
        var mapped = source;
        mapped.callback_index = index;
        try files.append(a, mapped);
    }
    var doc = snapshot.document;
    doc.callbacks = callbacks;
    const result = p.snapshot.Snapshot{ .document = doc, .sources = files.items };
    try p.snapshot.validate(result, board);
    try verify(a, result);
    return p.snapshot.clone(gpa, result);
}

test "transitive callback imports preserve relative paths bytes and reject missing dynamic escaping imports" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "helpers");
    try tmp.dir.writeFile(io, .{ .sub_path = "callback.zig", .data = "const helper = @import(\"helpers/helper.zig\");\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers/helper.zig", .data = "const root = @import(\"../callback.zig\");\n" });
    var bundle = try capture(gpa, io, tmp.dir, "callback.zig");
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 2), bundle.bytes.len);
    try std.testing.expectEqualStrings("helpers/helper.zig", bundle.bytes[1].path);
    try tmp.dir.deleteFile(io, "helpers/helper.zig");
    try std.testing.expectError(error.FileNotFound, capture(gpa, io, tmp.dir, "callback.zig"));
    try tmp.dir.writeFile(io, .{ .sub_path = "callback.zig", .data = "const helper = @import(dynamic_name);" });
    try std.testing.expectError(error.DynamicImportUnsupported, capture(gpa, io, tmp.dir, "callback.zig"));
    try tmp.dir.writeFile(io, .{ .sub_path = "callback.zig", .data = "const helper = @import(\"../escape.zig\");" });
    try std.testing.expectError(error.ImportEscapesProject, capture(gpa, io, tmp.dir, "callback.zig"));
}

test "external callback checkout refresh creates a new immutable snapshot without modifying the saved bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var source_dir = std.testing.tmpDir(.{});
    defer source_dir.cleanup();
    try source_dir.dir.writeFile(io, .{ .sub_path = "custom.zig", .data = "// version one\n" });
    var bundle = try capture(gpa, io, source_dir.dir, "custom.zig");
    defer bundle.deinit();
    var base = try p.profiles.create(gpa, .qwerty);
    defer base.deinit();
    var attached = try attach(gpa, base.snapshot, bundle, &.{1}, &.{});
    defer attached.deinit();
    var project_dir = std.testing.tmpDir(.{});
    defer project_dir.cleanup();
    try p.snapshot.save(gpa, io, project_dir.dir, attached.snapshot, p.profiles.board);
    try checkout(gpa, io, project_dir.dir, attached.snapshot, 0);
    try project_dir.dir.writeFile(io, .{ .sub_path = "callbacks/0/custom.zig", .data = "// version two\n" });
    var refreshed = try refresh(gpa, io, project_dir.dir, attached.snapshot, 0);
    defer refreshed.deinit();
    try std.testing.expectEqualStrings("// version two\n", refreshed.snapshot.sources[0].bytes);
    var saved = try p.snapshot.load(gpa, io, project_dir.dir, p.profiles.board);
    defer saved.deinit();
    try std.testing.expectEqualStrings("// version one\n", saved.snapshot.sources[0].bytes);
    const original_identity = try p.snapshot.identity(gpa, attached.snapshot, p.profiles.board);
    try std.testing.expect(!std.mem.eql(u8, &original_identity.digest, &(try p.snapshot.identity(gpa, refreshed.snapshot, p.profiles.board)).digest));
}
test "explicit callback attachment and refresh use the supplied board contract" {
    const t = std.testing;
    var base = try p.profiles.create(t.allocator, .qwerty);
    defer base.deinit();
    const board = p.Board{ .id = "fixture\x00".*, .physical_layout = "explicit-fixture", .key_ids = &.{ "left", "right", "thumb" }, .sides = &.{ .X, .X, .X } };
    var doc = base.snapshot.document;
    doc.board_id = board.id;
    doc.physical_layout = board.physical_layout;
    doc.key_ids = board.key_ids;
    doc.combos = &.{};
    var layers: [p.Limits.layers]p.Layer = undefined;
    const count = doc.layers.len;
    for (layers[0..count], doc.layers) |*target, layer| {
        target.* = layer;
        target.actions = layer.actions[0..3];
    }
    doc.layers = layers[0..count];
    const original = p.snapshot.Snapshot{ .document = doc, .sources = base.snapshot.sources };
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "custom.zig", .data = "// frozen initial callback\n" });
    var bundle = try capture(t.allocator, t.io, tmp.dir, "custom.zig");
    defer bundle.deinit();
    var attached = try attachForBoard(t.allocator, original, board, bundle, &.{1}, &.{});
    defer attached.deinit();
    try p.snapshot.validate(attached.snapshot, board);
    try checkout(t.allocator, t.io, tmp.dir, attached.snapshot, 0);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "callbacks/0/custom.zig", .data = "// deliberately edited mirror\n" });
    var refreshed = try refreshForBoard(t.allocator, t.io, tmp.dir, attached.snapshot, board, 0);
    defer refreshed.deinit();
    try p.snapshot.validate(refreshed.snapshot, board);
    try t.expectEqualStrings("// frozen initial callback\n", attached.snapshot.sources[0].bytes);
    try t.expectEqualStrings("// deliberately edited mirror\n", refreshed.snapshot.sources[0].bytes);
    try t.expectError(error.InvalidCallback, checkout(t.allocator, t.io, tmp.dir, attached.snapshot, 1));
    try t.expectError(error.InvalidCallback, refreshForBoard(t.allocator, t.io, tmp.dir, attached.snapshot, board, 1));
}
