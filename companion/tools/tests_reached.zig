//! Fails when a `test` block under `src/` or `tests/` is compiled into no test
//! binary of the build.
//!
//! `addTest` collects tests only from files its root module analyzes. A file
//! that no root reaches, or reaches only through an unused declaration, has
//! tests that never run while every step stays green. Rather than guessing
//! from imports, this reads the test binaries: each one names every test it
//! runs as `<file>.test.<name>` (`<file>.decltest.<decl>` for `test decl {}`),
//! where `<file>` is the path from the root module's directory with `/` as `.`
//! and without `.zig`. Ported from fizzy's `scripts/tests_reached.zig`.
//!
//! Usage: tests-reached <repository> [--deferred <root file>]... (<root file> <test binary>)...
//!
//! A deferred root belongs to a test area the current options do not
//! configure (for example `-Ddesktop`); its own tests are reported, not
//! required. Output is sorted, so repeated runs print the same text.
const std = @import("std");

const scanned_directories = [_][]const u8{ "src", "tests" };

const Binary = struct {
    /// The root module's directory, with a trailing separator.
    root_dir: []const u8,
    bytes: []const u8,
};

const TestName = struct {
    /// `test` for `test "name"`, `decltest` for `test decl`.
    kind: []const u8,
    name: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) usage();
    const cwd = std.Io.Dir.cwd();
    const repository = try cwd.realPathFileAlloc(io, args[1], arena);

    var deferred: std.ArrayList([]const u8) = .empty;
    var binaries: std.ArrayList(Binary) = .empty;
    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--deferred")) {
            if (index + 1 >= args.len) usage();
            try deferred.append(arena, try cwd.realPathFileAlloc(io, args[index + 1], arena));
        } else {
            if (index + 1 >= args.len) usage();
            const root = try cwd.realPathFileAlloc(io, args[index], arena);
            try binaries.append(arena, .{
                .root_dir = try std.fmt.allocPrint(arena, "{s}{c}", .{ std.fs.path.dirname(root) orelse ".", std.fs.path.sep }),
                .bytes = try cwd.readFileAlloc(io, args[index + 1], arena, .unlimited),
            });
        }
        index += 2;
    }

    var files: std.ArrayList([]const u8) = .empty;
    for (scanned_directories) |name| try collect(arena, io, repository, name, &files);
    std.mem.sort([]const u8, files.items, {}, lessThan);

    var tested_files: usize = 0;
    var tests: usize = 0;
    var deferred_tests: usize = 0;
    var missing: usize = 0;
    for (files.items) |relative| {
        const absolute = try std.fs.path.join(arena, &.{ repository, relative });
        const source = try cwd.readFileAlloc(io, absolute, arena, .limited(16 * 1024 * 1024));
        const is_deferred = contains(deferred.items, absolute);
        var file_tests: usize = 0;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const name = testName(arena, line) orelse continue;
            file_tests += 1;
            if (is_deferred) continue;
            if (reached(arena, binaries.items, absolute, name)) continue;
            if (missing == 0) std.debug.print("Tests compiled into no test binary of this build:\n", .{});
            std.debug.print("  {s}: {s} \"{s}\"\n", .{ relative, name.kind, name.name });
            missing += 1;
        }
        if (file_tests == 0) continue;
        tested_files += 1;
        if (is_deferred) deferred_tests += file_tests else tests += file_tests;
    }

    if (missing > 0) {
        std.debug.print(
            \\{d} of {d} tests are never compiled into a test binary. Give the file its own
            \\test root in build/, or reference it from a tested file: `test {{ _ = @import("x.zig"); }}`.
            \\
        , .{ missing, tests });
        std.process.exit(1);
    }
    std.debug.print("{d} tests in {d} files are compiled into test binaries", .{ tests, tested_files });
    if (deferred_tests > 0) std.debug.print("; {d} tests of unconfigured areas were not checked", .{deferred_tests});
    std.debug.print("\n", .{});
}

fn usage() noreturn {
    std.debug.print("usage: tests-reached <repository> [--deferred <root file>]... (<root file> <test binary>)...\n", .{});
    std.process.exit(2);
}

/// Append every `.zig` file below `repository/name`, relative to `repository`.
fn collect(arena: std.mem.Allocator, io: std.Io, repository: []const u8, name: []const u8, files: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, try std.fs.path.join(arena, &.{ repository, name }), .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => if (entry.basename[0] != '.') try walker.enter(io, entry),
        .file => if (std.mem.endsWith(u8, entry.basename, ".zig"))
            try files.append(arena, try std.fs.path.join(arena, &.{ name, entry.path })),
        else => {},
    };
}

/// The name of the top-level `test` declared on `line`, or null. A bare
/// `test {}` has no name in the binary; it only references other files.
fn testName(arena: std.mem.Allocator, line: []const u8) ?TestName {
    if (!std.mem.startsWith(u8, line, "test ")) return null;
    const rest = std.mem.trimStart(u8, line["test ".len..], " ");
    if (rest.len > 0 and rest[0] == '"') {
        var end: usize = 1;
        while (end < rest.len and rest[end] != '"') : (end += 1) {
            if (rest[end] == '\\') end += 1;
        }
        if (end >= rest.len) return null;
        const name = std.zig.string_literal.parseAlloc(arena, rest[0 .. end + 1]) catch return null;
        return .{ .kind = "test", .name = name };
    }
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
    if (end == 0) return null;
    return .{ .kind = "decltest", .name = rest[0..end] };
}

/// Whether a binary whose root module directory holds `file` names this test.
fn reached(arena: std.mem.Allocator, binaries: []const Binary, file: []const u8, t: TestName) bool {
    for (binaries) |binary| {
        if (!std.mem.startsWith(u8, file, binary.root_dir)) continue;
        const relative = file[binary.root_dir.len .. file.len - ".zig".len];
        const namespace = std.mem.replaceOwned(u8, arena, relative, std.fs.path.sep_str, ".") catch return false;
        const wanted = std.fmt.allocPrint(arena, "{s}.{s}.{s}", .{ namespace, t.kind, t.name }) catch return false;
        if (std.mem.find(u8, binary.bytes, wanted) != null) return true;
    }
    return false;
}

fn contains(items: []const []const u8, wanted: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, wanted)) return true;
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
