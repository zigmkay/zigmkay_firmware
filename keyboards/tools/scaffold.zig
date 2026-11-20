//! Creates a personal keymap or a new board from the keyboards directory, the
//! working directory of this tool. Run through the mise tasks:
//!
//!     scaffold keymap <keyboard> [name]   keymap:new, copies into local/<name>/
//!     scaffold board <name>               board:new, into my_keyboards/<name>/
//!
//! It only reads and writes files below the keyboards directory.
const std = @import("std");
const boards = @import("boards");

const usage =
    \\usage: scaffold keymap <keyboard> [name]
    \\       scaffold board <name>
    \\
;

/// Git ignores this folder, so personal keymaps never conflict with upstream.
const local_dir = "local";
const board_template_main = @embedFile("templates/main.zig");
const board_template_keymap = @embedFile("templates/keymap.zig");
/// The word in the board templates that becomes the board name.
const template_name = "template_board";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) std.process.fatal(usage, .{});
    const cwd = std.Io.Dir.cwd();
    const command = args[1];
    if (std.mem.eql(u8, command, "keymap") and (args.len == 3 or args.len == 4)) {
        try newKeymap(init.io, arena, cwd, args[2], if (args.len == 4) args[3] else args[2]);
    } else if (std.mem.eql(u8, command, "board") and args.len == 3) {
        try newBoard(init.io, arena, cwd, args[2]);
    } else std.process.fatal(usage, .{});
}

fn newKeymap(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, keyboard: []const u8, name: []const u8) !void {
    const board = boards.find(keyboard) orelse {
        std.debug.print("Unknown keyboard '{s}'. Available keyboards:\n", .{keyboard});
        for (boards.boards) |entry| std.debug.print("  {s}\n", .{entry.name});
        std.process.exit(1);
    };
    const source = board.keymap orelse std.process.fatal(
        "'{s}' defines its keymap in its main file, {s}, so it has no keymap to copy.",
        .{ keyboard, board.root_source_file },
    );
    if (!validName(name, false)) std.process.fatal("Invalid keymap name '{s}': use letters, digits, '_' and '-'.", .{name});

    const target_dir = try std.fmt.allocPrint(arena, local_dir ++ "/{s}", .{name});
    const target = try std.fmt.allocPrint(arena, "{s}/keymap.zig", .{target_dir});
    if (exists(io, dir, target_dir)) std.process.fatal(
        "{s} already exists. Pick another name, such as `mise run //keyboards:keymap:new {s} {s}_2`, or delete the folder.",
        .{ target_dir, keyboard, name },
    );

    // A keymap file is its module's root, and a module root reaches only files
    // below its own folder; so the files it imports by path come along, at the
    // same place relative to it.
    const files = try importClosure(io, arena, dir, source);
    const source_dir = parentDir(source);
    const prefix = if (source_dir.len == 0) 0 else source_dir.len + 1;
    for (files[1..]) |file| if (std.mem.eql(u8, file[prefix..], "keymap.zig"))
        std.process.fatal("{s} imports a file named keymap.zig; copy the files yourself.", .{source});
    for (files, 0..) |file, index| {
        const bytes = try dir.readFileAlloc(io, file, arena, .limited(16 * 1024 * 1024));
        const relative = if (index == 0) "keymap.zig" else file[prefix..];
        const destination = try std.fmt.allocPrint(arena, "{s}/{s}", .{ target_dir, relative });
        try dir.createDirPath(io, parentDir(destination));
        try dir.writeFile(io, .{ .sub_path = destination, .data = bytes, .flags = .{ .exclusive = true } });
    }

    std.debug.print(
        \\Created keyboards/{s} from the default keymap of {s}, {s}.
        \\
    , .{ target, keyboard, source });
    for (files[1..]) |file| std.debug.print("Copied {s}, which it imports, next to it.\n", .{file});
    std.debug.print(
        \\Git ignores keyboards/local/, so this keymap stays yours: edit it freely,
        \\upstream updates never touch it. Build and flash it from the repository root:
        \\
        \\  mise run //keyboards:build {[keyboard]s} --keymap {[target]s}
        \\  mise run //keyboards:flash {[keyboard]s} --keymap {[target]s}
        \\
        \\The firmware lands in keyboards/zig-out/firmware/zigmkay_firmware.uf2.
        \\The keymap guide is docs/keymaps.md.
        \\
    , .{ .keyboard = keyboard, .target = target });
}

fn newBoard(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !void {
    if (!validName(name, true)) std.process.fatal(
        "Invalid board name '{s}': start with a lowercase letter, then use lowercase letters, digits and '_'.",
        .{name},
    );
    if (boards.find(name) != null) std.process.fatal("boards.zig already has a keyboard named '{s}'.", .{name});
    const board_dir = try std.fmt.allocPrint(arena, "my_keyboards/{s}", .{name});
    if (exists(io, dir, board_dir)) std.process.fatal("{s} already exists; pick another name.", .{board_dir});

    const main_path = try std.fmt.allocPrint(arena, "{s}/main.zig", .{board_dir});
    const keymap_path = try std.fmt.allocPrint(arena, "{s}/keymap.zig", .{board_dir});
    try dir.createDirPath(io, board_dir);
    try dir.writeFile(io, .{ .sub_path = main_path, .data = try replaceName(arena, board_template_main, name), .flags = .{ .exclusive = true } });
    try dir.writeFile(io, .{ .sub_path = keymap_path, .data = try replaceName(arena, board_template_keymap, name), .flags = .{ .exclusive = true } });

    const entry = try std.fmt.allocPrint(
        arena,
        "    .{{ .name = \"{s}\", .root_source_file = \"{s}\", .keymap = \"{s}\" }},\n",
        .{ name, main_path, keymap_path },
    );
    const table = try dir.readFileAlloc(io, "boards.zig", arena, .limited(1024 * 1024));
    const registered = if (try insertBoard(arena, table, entry)) |updated| blk: {
        try dir.writeFile(io, .{ .sub_path = "boards.zig", .data = updated });
        break :blk true;
    } else false;

    std.debug.print(
        \\Created keyboards/{[main]s} (pins, matrix, processing loop)
        \\    and keyboards/{[keymap]s} (layers and combos).
        \\
    , .{ .main = main_path, .keymap = keymap_path });
    if (registered)
        std.debug.print("Registered '{s}' in keyboards/boards.zig.\n", .{name})
    else
        std.debug.print("Could not find the board list in keyboards/boards.zig; add this line to it:\n{s}", .{entry});
    std.debug.print(
        \\
        \\Next:
        \\  1. Set the pins, pin_cols, pin_rows and pin_mappings in main.zig to
        \\     your PCB's wiring, and key_count, the layers and sides in keymap.zig
        \\     to its keys.
        \\  2. mise run //keyboards:build {[name]s}
        \\  3. mise run //keyboards:flash {[name]s}
        \\
        \\The companion does not offer '{[name]s}' until it has a processing
        \\descriptor; keyboards/README.md lists the steps to add it, and those for
        \\contributing the board upstream.
        \\
    , .{ .name = name });
}

/// Board names are build options and companion selectors; keymap names are
/// folder names.
fn validName(name: []const u8, board: bool) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (board and !std.ascii.isLower(name[0])) return false;
    for (name) |char| {
        const ok = if (board)
            std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '_'
        else
            std.ascii.isAlphanumeric(char) or char == '_' or char == '-';
        if (!ok) return false;
    }
    return !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

fn exists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn replaceName(arena: std.mem.Allocator, template: []const u8, name: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, arena, template, template_name, name);
}

/// `table` with `entry` inserted as the last element of `boards`, or null if
/// the list is not where it is expected.
fn insertBoard(arena: std.mem.Allocator, table: []const u8, entry: []const u8) !?[]u8 {
    const start = std.mem.indexOf(u8, table, "pub const boards = [_]Board{\n") orelse return null;
    const end = std.mem.indexOfPos(u8, table, start, "\n};\n") orelse return null;
    return try std.mem.concat(arena, u8, &.{ table[0 .. end + 1], entry, table[end + 1 ..] });
}

/// `root` and every file it reaches through `@import` or `@embedFile` of a
/// path, first `root`. Fails when one lies outside `root`'s folder.
fn importClosure(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, root: []const u8) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    try files.append(arena, root);
    const base = parentDir(root);
    var index: usize = 0;
    while (index < files.items.len) : (index += 1) {
        const file = files.items[index];
        const bytes = dir.readFileAlloc(io, file, arena, .limited(16 * 1024 * 1024)) catch |err|
            std.process.fatal("Cannot read keyboards/{s}: {t}", .{ file, err });
        var imports = pathImports(bytes);
        while (imports.next()) |import| {
            const resolved = (try joinRelative(arena, parentDir(file), import)) orelse
                std.process.fatal("keyboards/{s} imports \"{s}\", outside the keyboards folder.", .{ file, import });
            if (!within(base, resolved)) std.process.fatal(
                \\keyboards/{s} imports "{s}" from outside the folder of {s},
                \\so a copy of it could not reach that file. Copy the files yourself, or
                \\ask on the Discord: https://discord.gg/bJCZUtJD65
            , .{ file, import, root });
            if (std.mem.eql(u8, resolved, root)) std.process.fatal(
                "keyboards/{s} imports the keymap file itself; copy the files yourself.",
                .{file},
            );
            for (files.items) |seen| {
                if (std.mem.eql(u8, seen, resolved)) break;
            } else try files.append(arena, resolved);
        }
    }
    return files.items;
}

/// The string operands of `@import` and `@embedFile` that name files rather
/// than modules: those ending in `.zig`, and every `@embedFile`.
const PathImports = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(self: *PathImports) ?[]const u8 {
        while (self.at < self.bytes.len) {
            const rest = self.bytes[self.at..];
            const import = std.mem.indexOf(u8, rest, "@import(\"");
            const embed = std.mem.indexOf(u8, rest, "@embedFile(\"");
            const found = if (import != null and (embed == null or import.? < embed.?))
                .{ import.?, "@import(\"".len, false }
            else if (embed) |offset|
                .{ offset, "@embedFile(\"".len, true }
            else
                return null;
            const start = self.at + found[0] + found[1];
            const end = std.mem.indexOfScalarPos(u8, self.bytes, start, '"') orelse return null;
            self.at = end + 1;
            if (lineIsComment(self.bytes, start)) continue;
            const operand = self.bytes[start..end];
            if (found[2] or std.mem.endsWith(u8, operand, ".zig")) return operand;
        }
        return null;
    }
};

fn pathImports(bytes: []const u8) PathImports {
    return .{ .bytes = bytes };
}

fn lineIsComment(bytes: []const u8, at: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, bytes[0..at], '\n')) |newline| newline + 1 else 0;
    return std.mem.indexOf(u8, bytes[line_start..at], "//") != null;
}

/// The folder part of a `/`-separated path, empty for a bare file name.
fn parentDir(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

/// `base/relative` with `.` and `..` resolved, or null if it leaves the
/// keyboards folder or `relative` is absolute.
fn joinRelative(arena: std.mem.Allocator, base: []const u8, relative: []const u8) !?[]const u8 {
    if (relative.len == 0 or relative[0] == '/' or std.mem.indexOfScalar(u8, relative, '\\') != null or
        std.mem.indexOfScalar(u8, relative, ':') != null) return null;
    var parts: std.ArrayList([]const u8) = .empty;
    var all = std.mem.splitScalar(u8, base, '/');
    var rel = std.mem.splitScalar(u8, relative, '/');
    for ([_]*std.mem.SplitIterator(u8, .scalar){ &all, &rel }) |it| while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
        } else try parts.append(arena, part);
    };
    return try std.mem.join(arena, "/", parts.items);
}

fn within(base: []const u8, path: []const u8) bool {
    if (base.len == 0) return true;
    return path.len > base.len and std.mem.startsWith(u8, path, base) and path[base.len] == '/';
}

test "path imports skip modules and comments" {
    var imports = pathImports(
        \\const std = @import("std");
        \\const shared = @import("keymap_shared.zig");
        \\// const old = @import("old.zig");
        \\const text = @embedFile("notes.txt");
    );
    try std.testing.expectEqualStrings("keymap_shared.zig", imports.next().?);
    try std.testing.expectEqualStrings("notes.txt", imports.next().?);
    try std.testing.expect(imports.next() == null);
}

test "relative paths stay inside the keymap folder" {
    const arena = std.testing.allocator;
    var state = std.heap.ArenaAllocator.init(arena);
    defer state.deinit();
    const a = state.allocator();
    const resolved = (try joinRelative(a, "my_keyboards/janbeelte", "./keymap_shared.zig")).?;
    try std.testing.expectEqualStrings("my_keyboards/janbeelte/keymap_shared.zig", resolved);
    try std.testing.expect(within("my_keyboards/janbeelte", resolved));
    const up = (try joinRelative(a, "my_keyboards/janbeelte", "../rollercole/x.zig")).?;
    try std.testing.expect(!within("my_keyboards/janbeelte", up));
    try std.testing.expect(try joinRelative(a, "examples", "../../x.zig") == null);
    try std.testing.expect(try joinRelative(a, "examples", "/etc/x.zig") == null);
}

test "a new board is appended to the board list" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const table =
        \\pub const boards = [_]Board{
        \\    .{ .name = "lk8" },
        \\};
        \\
        \\pub fn find() void {}
        \\
    ;
    const updated = (try insertBoard(state.allocator(), table, "    .{ .name = \"new\" },\n")).?;
    try std.testing.expectEqualStrings(
        \\pub const boards = [_]Board{
        \\    .{ .name = "lk8" },
        \\    .{ .name = "new" },
        \\};
        \\
        \\pub fn find() void {}
        \\
    , updated);
    try std.testing.expect(try insertBoard(state.allocator(), "const x = 1;\n", "") == null);
}

test "board names are build options, keymap names folder names" {
    try std.testing.expect(validName("my_board2", true));
    try std.testing.expect(!validName("My-Board", true));
    try std.testing.expect(!validName("2board", true));
    try std.testing.expect(validName("My-keymap_2", false));
    try std.testing.expect(!validName("..", false));
    try std.testing.expect(!validName("a/b", false));
    try std.testing.expect(!validName("", false));
}

test "the board templates name the board in one word" {
    try std.testing.expect(std.mem.indexOf(u8, board_template_main, template_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, board_template_keymap, template_name) != null);
}
