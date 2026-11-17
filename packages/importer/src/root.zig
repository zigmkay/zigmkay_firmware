//! Explicit one-way migration. Repository build scripts and callback handlers
//! never execute. Only captured source is supplied to an application-owned helper.
const std = @import("std");
const p = @import("project");
pub const boards = @import("catalog-project");
pub const catalog = @import("catalog");
const jobs = @import("companion-jobs");
pub const github = @import("github.zig");
pub const Data = @import("data.zig").Data;
pub const converter_version = 1;
/// Explicit catalog host substitutes, after complete stable document validation.
/// These simulate physical positions; they do not identify a real OS keyboard.
pub fn hostScancodes(a: std.mem.Allocator, document: p.Document) ![]const u32 {
    var owned = try boards.OwnedBoard.fromDocument(a, document);
    defer owned.deinit();
    const fingers = [_]u32{ 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 29, 27, 6, 25, 5, 17, 16, 54, 55, 56 };
    const result = try a.alloc(u32, document.key_ids.len);
    switch (result.len) {
        1 => result[0] = 4,
        30 => {
            @memcpy(result[0..20], fingers[0..20]);
            @memcpy(result[20..28], &[_]u32{ 27, 6, 25, 5, 17, 16, 54, 55 });
            @memcpy(result[28..30], &[_]u32{ 44, 40 });
        },
        34, 36 => {
            @memcpy(result[0..30], &fingers);
            const thumbs = [_]u32{ 44, 40, 42, 43, 58, 59 };
            @memcpy(result[30..], thumbs[0 .. result.len - 30]);
        },
        38 => {
            @memcpy(result[0..10], fingers[0..10]);
            @memcpy(result[10..22], &[_]u32{ 43, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 52 });
            @memcpy(result[22..32], fingers[20..30]);
            @memcpy(result[32..38], &[_]u32{ 58, 44, 42, 40, 59, 60 });
        },
        else => return error.HostMappingUnavailable,
    }
    return result;
}
pub const Provenance = struct {
    version: u32 = 1,
    converter_version: u32 = converter_version,
    repository: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    entry: []const u8,
    fingerprint: [32]u8,
    sources: []const p.Source,
    source_manifest: ?[]const u8 = null,
    source_dependencies: []const jobs.package_manifest.Dependency = &.{},
    selected_target: ?[]const u8 = null,
    processing_digest: ?[32]u8 = null,
    host_layout_hint: []const u8 = "Confirm the source keymap's host layout",
};
pub const Captured = struct {
    arena: std.heap.ArenaAllocator,
    directory: []const u8,
    source_root: []const u8,
    provenance: Provenance,
    candidates: []const []const u8,
    pub fn deinit(self: *Captured) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn hash(bytes: []const u8) [32]u8 {
    return jobs.firmware.digest(bytes);
}
fn fingerprint(entry: []const u8, metadata: []const p.Source, manifest: ?[]const u8) [32]u8 {
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    h.update("zigmkay-import-v1\x00");
    h.update(entry);
    h.update(&.{0});
    for (metadata) |file| {
        h.update(file.path);
        h.update(&.{0});
        h.update(&file.digest);
    }
    if (manifest) |bytes| h.update(&hash(bytes));
    return h.finalResult();
}
fn writeZon(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try std.zon.stringify.serializeMaxDepth(value, .{}, &out.writer, 64);
    const file = try dir.createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, out.written());
    try file.sync(io);
}
fn newDirectory(a: std.mem.Allocator, io: std.Io, cache: []const u8, prefix: []const u8) ![]const u8 {
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const path = try std.fmt.allocPrint(a, "{s}/{s}-{s}", .{ cache, prefix, std.fmt.bytesToHex(nonce, .lower) });
    var parent = try std.Io.Dir.cwd().createDirPathOpen(io, cache, .{});
    defer parent.close(io);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    return path;
}
fn candidateFiles(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]const []const u8 {
    const files = try jobs.source_files.collect(a, io, root, .{ .max_files = 2048, .excluded = struct {
        fn skip(_: []const u8, name: []const u8, kind: std.Io.File.Kind) bool {
            return kind == .sym_link or std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, ".zig-cache") or std.mem.eql(u8, name, "zig-out");
        }
    }.skip, .included = struct {
        fn include(path: []const u8, kind: std.Io.File.Kind) bool {
            return kind == .file and std.mem.endsWith(u8, path, ".zig");
        }
    }.include });
    var result: std.ArrayList([]const u8) = .empty;
    var total: usize = 0;
    for (files) |file| {
        const portable = try a.dupe(u8, file.path);
        if (@import("builtin").os.tag == .windows) for (portable) |*byte| {
            if (byte.* == '\\') byte.* = '/';
        };
        if (!p.pathValid(portable)) continue;
        const bytes = try root.readFileAlloc(io, portable, a, .limited(@min(p.Limits.source_bytes, 16 * p.Limits.source_bytes - total)));
        total += bytes.len;
        const text = try a.dupeSentinel(u8, bytes, 0);
        var tokenizer: std.zig.Tokenizer = .init(text);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .keyword_pub or tokenizer.next().tag != .keyword_const) continue;
            const name = tokenizer.next();
            if (name.tag == .identifier and std.mem.eql(u8, text[name.loc.start..name.loc.end], "keymap")) {
                try result.append(a, portable);
                break;
            }
        }
    }
    return result.toOwnedSlice(a);
}
const LocalMetadata = struct { repository: ?[]const u8 = null, ref: ?[]const u8 = null, commit: ?[]const u8 = null };
fn localMetadata(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !LocalMetadata {
    var git = root.openDir(io, ".git", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{},
        else => return err,
    };
    defer git.close(io);
    var result: LocalMetadata = .{};
    const head_bytes = git.readFileAlloc(io, "HEAD", a, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    const head = std.mem.trim(u8, head_bytes, "\r\n ");
    if (std.mem.startsWith(u8, head, "ref: refs/")) {
        const reference = head[5..];
        if (std.mem.indexOf(u8, reference, "..") != null or std.mem.indexOfAny(u8, reference, "\\:\x00") != null) return result;
        result.ref = reference;
        const reference_bytes = git.readFileAlloc(io, reference, a, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (reference_bytes) |bytes| result.commit = std.mem.trim(u8, bytes, "\r\n ") else {
            const packed_refs = git.readFileAlloc(io, "packed-refs", a, .limited(p.Limits.document_bytes)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (packed_refs) |bytes| {
                var lines = std.mem.splitScalar(u8, bytes, '\n');
                while (lines.next()) |line| if (line.len > 41 and std.mem.eql(u8, line[41..], reference)) {
                    result.commit = line[0..40];
                    break;
                };
            }
        }
    } else result.commit = head;
    if (result.commit) |revision| {
        var valid = revision.len == 40;
        for (revision) |byte| if (!std.ascii.isHex(byte)) {
            valid = false;
        };
        if (!valid) result.commit = null;
    }
    const config = git.readFileAlloc(io, "config", a, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, config, '\n');
    var origin = false;
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, text, "[")) origin = std.mem.eql(u8, text, "[remote \"origin\"]");
        if (origin and std.mem.startsWith(u8, text, "url")) if (std.mem.indexOfScalar(u8, text, '=')) |equals| {
            const url = std.mem.trim(u8, text[equals + 1 ..], " \t");
            // Do not persist credentials from a local remote URL.
            if (std.mem.startsWith(u8, url, "https://") and std.mem.indexOfScalar(u8, url, '@') == null) result.repository = url;
        };
    }
    return result;
}
/// Inspection captures bytes into a fresh cache directory. Fetching happens only
/// when this explicit action is scheduled, never while typing a URL.
pub fn inspect(gpa: std.mem.Allocator, io: std.Io, location: []const u8, selected: ?[]const u8, cache: []const u8) !Captured {
    return inspectWithOrigin(gpa, io, location, selected, cache, null);
}
pub fn inspectWithOrigin(gpa: std.mem.Allocator, io: std.Io, location: []const u8, selected: ?[]const u8, cache: []const u8, origin: ?Provenance) !Captured {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var remote: ?github.Resolved = null;
    const root_path = if (std.mem.startsWith(u8, location, "https://")) blk: {
        remote = try github.resolve(a, io, location);
        const path = try newDirectory(a, io, cache, "download");
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        const url = try std.fmt.allocPrint(a, "{s}/archive/{s}.tar.gz", .{ remote.?.repository, remote.?.commit });
        try github.extract(a, io, dir, try github.get(a, io, url, 16 * 1024 * 1024));
        break :blk path;
    } else location;
    if (!std.fs.path.isAbsolute(root_path)) return error.AbsoluteSourceFolderRequired;
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    const candidates = try candidateFiles(a, io, root);
    if (candidates.len == 0) return error.NoKeymapModulesFound;
    const entry = selected orelse blk: {
        for (candidates) |path| if (std.mem.eql(u8, path, "src/keymap.zig")) break :blk path;
        break :blk candidates[0];
    };
    var bundle = try p.sources.capture(gpa, io, root, entry);
    defer bundle.deinit();
    for (bundle.bytes) |file| if (std.mem.eql(u8, file.path, "build.zig") or std.mem.endsWith(u8, file.path, "/build.zig")) return error.SourceBuildScriptDependencyUnsupported;
    const manifest = root.readFileAlloc(io, "build.zig.zon", a, .limited(p.Limits.document_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    var dependencies: []const jobs.package_manifest.Dependency = &.{};
    if (manifest) |bytes| {
        var parsed = try jobs.package_manifest.parse(gpa, bytes);
        defer parsed.deinit();
        dependencies = try p.owned_zon.clone(a, parsed.dependencies);
    }
    const directory = try newDirectory(a, io, cache, "capture");
    var destination = try std.Io.Dir.cwd().openDir(io, directory, .{});
    defer destination.close(io);
    for (bundle.bytes) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try destination.createDirPath(io, parent);
        const out = try destination.createFile(io, file.path, .{ .exclusive = true });
        defer out.close(io);
        try out.writeStreamingAll(io, file.bytes);
    }
    const hint = blk: {
        for (bundle.bytes) |file| {
            if (std.mem.indexOf(u8, file.bytes, "layouts.german") != null) break :blk "German QWERTZ";
            if (std.mem.indexOf(u8, file.bytes, "layouts.us_international") != null) break :blk "US International";
        }
        break :blk "Confirm the source keymap's host layout";
    };
    const local = if (origin) |value| LocalMetadata{ .repository = if (value.repository) |text| try a.dupe(u8, text) else null, .ref = if (value.ref) |text| try a.dupe(u8, text) else null, .commit = if (value.commit) |text| try a.dupe(u8, text) else null } else if (remote == null) try localMetadata(a, io, root) else LocalMetadata{};
    const provenance: Provenance = .{ .entry = try a.dupe(u8, entry), .fingerprint = fingerprint(entry, bundle.metadata, manifest), .sources = try p.owned_zon.clone(a, bundle.metadata), .source_manifest = manifest, .source_dependencies = dependencies, .repository = if (remote) |value| value.repository else local.repository, .ref = if (remote) |value| value.ref else local.ref, .commit = if (remote) |value| value.commit else local.commit, .host_layout_hint = hint };
    try writeZon(a, io, destination, "capture.zon", provenance);
    const source_root = try a.dupe(u8, root_path);
    return .{ .arena = arena, .directory = directory, .source_root = source_root, .provenance = provenance, .candidates = candidates };
}
pub fn verify(a: std.mem.Allocator, io: std.Io, capture: Captured) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, capture.directory, .{});
    defer dir.close(io);
    var bundle = try p.sources.capture(a, io, dir, capture.provenance.entry);
    defer bundle.deinit();
    if (!std.mem.eql(u8, &capture.provenance.fingerprint, &fingerprint(capture.provenance.entry, bundle.metadata, capture.provenance.source_manifest))) return error.ImportSourceChanged;
}
/// Reuse provenance when explicitly making a portable copy of an existing project.
pub fn retained(gpa: std.mem.Allocator, io: std.Io, project_directory: []const u8) !?Captured {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var root = try std.Io.Dir.cwd().openDir(io, project_directory, .{});
    defer root.close(io);
    const bytes = root.readFileAlloc(io, ".import/provenance.zon", a, .limited(8 * p.Limits.document_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            arena.deinit();
            return null;
        },
        else => return err,
    };
    const provenance = try p.owned_zon.parse(Provenance, a, try a.dupeSentinel(u8, bytes, 0));
    if (provenance.version != 1 or provenance.converter_version != converter_version) return error.UnsupportedImportProvenance;
    const directory = try std.fs.path.join(a, &.{ project_directory, ".import/source" });
    const result: Captured = .{ .arena = arena, .directory = directory, .source_root = directory, .provenance = provenance, .candidates = &.{} };
    try verify(gpa, io, result);
    return result;
}
pub const Toolchain = struct { compiler: []const u8, build_root: []const u8, cache: []const u8, packages: ?[]const u8 = null, global_cache: ?[]const u8 = null, payload_executable: ?[]const u8 = null, payload_root: ?[]const u8 = null };
fn execute(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8, environment: *const std.process.Environ.Map, captured: [32]u8) !jobs.Result {
    var job = try jobs.Job.init(a, io, .{ .argv = argv, .cwd = cwd, .snapshot_id = captured, .environ_map = environment, .timeout_ms = 900_000, .isolated_group = @import("builtin").os.tag != .windows });
    defer job.deinit();
    try job.start();
    while (true) {
        if (job.poll()) |result| return try result;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}
pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    captured: [32]u8,
    data: Data,
    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn analyze(gpa: std.mem.Allocator, io: std.Io, capture: Captured, toolchain: Toolchain, environment: *const std.process.Environ.Map) !Analysis {
    if (toolchain.payload_executable) |executable| try jobs.bundle_payload.materialize(gpa, io, executable, toolchain.payload_root orelse return error.InvalidBundlePath);
    try verify(gpa, io, capture);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const output = try newDirectory(a, io, toolchain.cache, "analysis");
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ toolchain.compiler, "build", "analyze-keymap", try std.fmt.allocPrint(a, "-Dimport-root={s}", .{capture.directory}), try std.fmt.allocPrint(a, "-Dimport-module={s}", .{capture.provenance.entry}), "-Dnative-only=true", "-j2", "-p", output, "--cache-dir", try std.fs.path.join(a, &.{ toolchain.cache, "compiler-local" }) });
    if (toolchain.packages) |packages| {
        try args.appendSlice(a, &.{ "--system", try std.fs.path.relativeAlloc(a, toolchain.build_root, environment, toolchain.build_root, packages) });
    }
    var env = try environment.clone(a);
    try env.put("ZIG_GLOBAL_CACHE_DIR", toolchain.global_cache orelse try std.fs.path.join(a, &.{ toolchain.cache, "compiler-global" }));
    for ([_][]const u8{ "ZIG_LIB_DIR", "ZIG_LOCAL_CACHE_DIR", "ZIG_LOCAL_PKG_DIR", "ZIG_BUILD_RUNNER", "ZIG_EXECUTABLE" }) |name| _ = env.swapRemove(name);
    var built = try execute(gpa, io, args.items, toolchain.build_root, &env, capture.provenance.fingerprint);
    defer built.deinit(gpa);
    var dir = try std.Io.Dir.cwd().openDir(io, output, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "compiler.log", .data = built.process.stderr });
    var source_dir = try std.Io.Dir.cwd().openDir(io, capture.directory, .{});
    defer source_dir.close(io);
    try source_dir.writeFile(io, .{ .sub_path = "analysis.log", .data = built.process.stderr });
    if (!built.successful()) {
        std.log.info("Keymap analysis incompatibility ({any}); diagnostics: {s}/analysis.log", .{ built.process.term, capture.directory });
        return error.IncompatibleKeymapSeeCachedCompilerLog;
    }
    const executable = try std.fs.path.join(a, &.{ output, "bin", "keymap-analyzer" ++ if (@import("builtin").os.tag == .windows) ".exe" else "" });
    var result = try execute(gpa, io, &.{executable}, output, &env, capture.provenance.fingerprint);
    defer result.deinit(gpa);
    if (!result.successful()) return error.TypedAnalysisFailed;
    const data = try p.owned_zon.parse(Data, a, try a.dupeSentinel(u8, result.process.stdout, 0));
    if (data.version != 1 or data.layers.len == 0 or data.layers.len > p.Limits.layers) return error.UnsupportedKeymapDimensions;
    if (data.layer_names) |names| if (names.len != data.layers.len) return error.InvalidLayerNames;
    try verify(gpa, io, capture);
    return .{ .arena = arena, .captured = capture.provenance.fingerprint, .data = data };
}
/// Hardware/revision is an explicit catalog choice. The first compatibility
/// family is Keycaprio 0.6/0.7, whose processing order is the researched contract.
pub fn compatible(data: Data, entry: catalog.Entry) bool {
    if (!std.mem.eql(u8, entry.selector, "keycaprio_colemak_0_6") and !std.mem.eql(u8, entry.selector, "keycaprio_colemak_0_7") and !std.mem.eql(u8, entry.selector, "keycaprio_us_intl_0_7")) return false;
    if (data.layers.len == 0 or data.sides == null or !std.mem.eql(@import("layout-model").Side, data.sides.?, entry.processing_sides) or data.encoders.len != entry.encoder_action_slots) return false;
    for (data.layers) |layer| if (layer.len != entry.default_dimensions.key_count) return false;
    return true;
}
pub const Prepared = struct {
    board: boards.OwnedBoard,
    project: boards.OwnedProject,
    captured: [32]u8,
    pub fn deinit(self: *Prepared) void {
        self.project.deinit();
        self.board.deinit();
        self.* = undefined;
    }
};
pub fn prepare(gpa: std.mem.Allocator, io: std.Io, capture: Captured, analysis: Analysis, selector: []const u8, name: []const u8, profile_id: [8]u8) !Prepared {
    if (!std.mem.eql(u8, &analysis.captured, &capture.provenance.fingerprint)) return error.StaleImportAnalysis;
    var board = try boards.OwnedBoard.init(gpa, selector);
    errdefer board.deinit();
    if (!compatible(analysis.data, board.entry.*)) return error.SelectCompatibleKeycaprioRevision;
    try verify(gpa, io, capture);
    var dir = try std.Io.Dir.cwd().openDir(io, capture.directory, .{});
    defer dir.close(io);
    var bundle = try p.sources.capture(gpa, io, dir, capture.provenance.entry);
    defer bundle.deinit();
    const a = board.arena.allocator();
    const files = try a.alloc(catalog.SourceFile, bundle.bytes.len);
    // Binding must point at the selected entry even when a dependency sorts first.
    files[0] = .{ .path = bundle.entry, .bytes = blk: {
        for (bundle.bytes) |file| if (std.mem.eql(u8, file.path, bundle.entry)) break :blk file.bytes;
        return error.MissingSource;
    } };
    var index: usize = 1;
    for (bundle.bytes) |file| if (!std.mem.eql(u8, file.path, bundle.entry)) {
        files[index] = .{ .path = file.path, .bytes = file.bytes };
        index += 1;
    };
    var converted = try boards.createData(gpa, board, .{ .entry = board.entry, .layers = analysis.data.layers, .combos = analysis.data.combos, .sides = analysis.data.sides, .encoder_actions = analysis.data.encoders, .has_callbacks = analysis.data.has_callbacks, .callback_sources = if (analysis.data.has_callbacks) files else &.{} });
    errdefer converted.deinit();
    converted.snapshot.document.name = try converted.arena.allocator().dupe(u8, name);
    converted.snapshot.document.profile_id = profile_id;
    if (analysis.data.layer_names) |names| for (@constCast(converted.snapshot.document.layers), names) |*layer, text| {
        layer.name = try converted.arena.allocator().dupe(u8, text);
    };
    try p.snapshot.validate(converted.snapshot, board.board);
    const generated = try p.exporter.generate(gpa, converted.snapshot, board.board);
    defer gpa.free(generated);
    return .{ .board = board, .project = converted, .captured = capture.provenance.fingerprint };
}
/// Exclusive publication into a new directory; existing projects are never
/// overwritten. Reopen before publication. Collection membership is a later action.
pub fn commit(gpa: std.mem.Allocator, io: std.Io, prepared: Prepared, capture: ?Captured, destination: []const u8) !void {
    if (!std.fs.path.isAbsolute(destination)) return error.AbsoluteDestinationRequired;
    if (capture) |source| {
        if (!std.mem.eql(u8, &prepared.captured, &source.provenance.fingerprint)) return error.StaleImportAnalysis;
        try verify(gpa, io, source);
    }
    const parent_path = std.fs.path.dirname(destination) orelse return error.InvalidDestination;
    var parent = try std.Io.Dir.cwd().createDirPathOpen(io, parent_path, .{});
    defer parent.close(io);
    const basename = std.fs.path.basename(destination);
    if (parent.statFile(io, basename, .{ .follow_symlinks = false })) |_| return error.DestinationOccupied else |err| if (err != error.FileNotFound) return err;
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const stage = try std.fmt.allocPrint(gpa, ".pending-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
    defer gpa.free(stage);
    try parent.createDir(io, stage, .default_dir);
    defer parent.deleteTree(io, stage) catch {};
    var dir = try parent.openDir(io, stage, .{});
    defer dir.close(io);
    try p.snapshot.save(gpa, io, dir, prepared.project.snapshot, prepared.board.board);
    if (capture) |source| {
        var cached = try std.Io.Dir.cwd().openDir(io, source.directory, .{});
        defer cached.close(io);
        try dir.createDirPath(io, ".import/source");
        var snapshot = try dir.openDir(io, ".import/source", .{});
        defer snapshot.close(io);
        var bundle = try p.sources.capture(gpa, io, cached, source.provenance.entry);
        defer bundle.deinit();
        for (bundle.bytes) |file| {
            if (std.fs.path.dirname(file.path)) |path| try snapshot.createDirPath(io, path);
            try snapshot.writeFile(io, .{ .sub_path = file.path, .data = file.bytes });
        }
        var provenance = source.provenance;
        provenance.selected_target = prepared.board.entry.selector;
        provenance.processing_digest = prepared.board.entry.processing_digest;
        try writeZon(gpa, io, dir, ".import/provenance.zon", provenance);
    }
    var reopened = try p.snapshot.load(gpa, io, dir, prepared.board.board);
    defer reopened.deinit();
    if (!std.mem.eql(u8, &try p.snapshot.projectDigest(gpa, reopened.snapshot, prepared.board.board), &try p.snapshot.projectDigest(gpa, prepared.project.snapshot, prepared.board.board))) return error.ImportReopenMismatch;
    try parent.renamePreserve(stage, parent, basename, io);
}

test {
    _ = github;
}

test "pinned friend sources convert reopen export and preserve immutable provenance for both revisions" {
    const t = std.testing;
    const options = @import("test-options");
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    for ([_][]const u8{ "us", "de" }) |fixture| {
        const root = try std.fs.path.join(t.allocator, &.{ options.repository, "tests/fixtures/import", fixture });
        defer t.allocator.free(root);
        var source = try inspect(t.allocator, t.io, root, null, path);
        defer source.deinit();
        var analysis = try analyze(t.allocator, t.io, source, .{ .compiler = options.compiler, .build_root = options.repository, .cache = path, .packages = options.packages, .global_cache = options.compiler_cache }, &env);
        defer analysis.deinit();
        try t.expectEqual(@as(usize, 6), analysis.data.layers.len);
        try t.expectEqual(@as(usize, if (std.mem.eql(u8, fixture, "us")) 22 else 23), analysis.data.combos.len);
        for ([_][]const u8{ "keycaprio_colemak_0_6", "keycaprio_colemak_0_7" }) |selector| {
            var prepared = try prepare(t.allocator, t.io, source, analysis, selector, "Imported fixture", "fixture1".*);
            defer prepared.deinit();
            const destination = try std.fmt.allocPrint(t.allocator, "{s}/{s}-{s}", .{ path, fixture, selector });
            defer t.allocator.free(destination);
            try commit(t.allocator, t.io, prepared, source, destination);
            try t.expectError(error.DestinationOccupied, commit(t.allocator, t.io, prepared, source, destination));
            var dir = try std.Io.Dir.cwd().openDir(t.io, destination, .{});
            defer dir.close(t.io);
            var reopened = try p.snapshot.load(t.allocator, t.io, dir, prepared.board.board);
            defer reopened.deinit();
            try t.expectEqualSlices(u8, &.{ 3, 6, 10, 25, 27 }, reopened.snapshot.document.callbacks[0].ids);
            try t.expectEqual(@as(usize, 6), reopened.snapshot.document.callbacks[0].index_constraints.?.len);
            var original_dir = try std.Io.Dir.cwd().openDir(t.io, root, .{});
            defer original_dir.close(t.io);
            const original = try original_dir.readFileAlloc(t.io, "src/keymap.zig", t.allocator, .limited(p.Limits.source_bytes));
            defer t.allocator.free(original);
            try t.expectEqualStrings(original, reopened.snapshot.sources[0].bytes);
            var export_dir = try dir.createDirPathOpen(t.io, "export", .{});
            defer export_dir.close(t.io);
            const manifest = try p.exporter.write(t.allocator, t.io, export_dir, reopened.snapshot, prepared.board.board);
            defer p.exporter.freeManifest(t.allocator, manifest);
        }
    }
}

fn simpleSource(a: std.mem.Allocator, callbacks: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.writeAll("const c = @import(\"zigmkay\").core;\npub const keymap = [_][34]?c.KeyDef{ @splat(null) };\npub const layer_names = [_][]const u8{\"Personal base\"};\npub const sides: [34]c.Side = ");
    try std.zon.stringify.serialize(catalog.find("keycaprio_colemak_0_7").?.processing_sides, .{}, &out.writer);
    try out.writer.writeAll(";\n");
    if (callbacks) try out.writer.writeAll("pub const custom_functions: c.CustomFunctions = .{.on_event = callback};\nfn callback(_: c.ProcessorEvent, _: *c.LayerActivations, _: *c.OutputCommandQueue) void {}\n");
    return out.toOwnedSlice();
}
test "callback-free imports keep provenance explicit names stale fingerprints and source integrity" {
    const t = std.testing;
    const options = @import("test-options");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    var original = try tmp.dir.createDirPathOpen(t.io, "original", .{});
    defer original.close(t.io);
    try original.createDirPath(t.io, "src");
    const source_bytes = try simpleSource(t.allocator, false);
    defer t.allocator.free(source_bytes);
    try original.writeFile(t.io, .{ .sub_path = "src/keymap.zig", .data = source_bytes });
    try original.writeFile(t.io, .{ .sub_path = "build.zig", .data = "comptime { @compileError(\"Source build scripts must never execute\"); }" });
    try original.createDirPath(t.io, ".git/refs/heads");
    try original.writeFile(t.io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try original.writeFile(t.io, .{ .sub_path = ".git/refs/heads/main", .data = "9a3965c07cac85722817ef98da4f56335781a412\n" });
    try original.writeFile(t.io, .{ .sub_path = ".git/config", .data = "[remote \"origin\"]\nurl = https://github.com/owner/source.git\n" });
    const path = try std.fs.path.join(t.allocator, &.{ base, "original" });
    defer t.allocator.free(path);
    var source = try inspect(t.allocator, t.io, path, null, base);
    defer source.deinit();
    try t.expectEqualStrings("9a3965c07cac85722817ef98da4f56335781a412", source.provenance.commit.?);
    try t.expectEqualStrings("https://github.com/owner/source.git", source.provenance.repository.?);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var data = try analyze(t.allocator, t.io, source, .{ .compiler = options.compiler, .build_root = options.repository, .cache = base, .packages = options.packages, .global_cache = options.compiler_cache }, &env);
    defer data.deinit();
    var stale = data;
    stale.captured[0] ^= 1;
    try t.expectError(error.StaleImportAnalysis, prepare(t.allocator, t.io, source, stale, "keycaprio_colemak_0_7", "Personal", "unique01".*));
    try t.expectError(error.SelectCompatibleKeycaprioRevision, prepare(t.allocator, t.io, source, data, "lk7", "Personal", "unique01".*));
    var prepared = try prepare(t.allocator, t.io, source, data, "keycaprio_colemak_0_7", "Personal", "unique01".*);
    defer prepared.deinit();
    try t.expectEqualStrings("Personal base", prepared.project.snapshot.document.layers[0].name);
    try t.expectEqual(@as(usize, 0), prepared.project.snapshot.sources.len);
    const destination = try std.fs.path.join(t.allocator, &.{ base, "callback-free" });
    defer t.allocator.free(destination);
    try commit(t.allocator, t.io, prepared, source, destination);
    var retained_source = (try retained(t.allocator, t.io, destination)).?;
    defer retained_source.deinit();
    try t.expectEqualSlices(u8, &source.provenance.fingerprint, &retained_source.provenance.fingerprint);
    var captured_dir = try std.Io.Dir.cwd().openDir(t.io, source.directory, .{});
    defer captured_dir.close(t.io);
    try captured_dir.writeFile(t.io, .{ .sub_path = "src/keymap.zig", .data = "pub const keymap = .{};" });
    try t.expectError(error.ImportSourceChanged, verify(t.allocator, t.io, source));
}
test "unsupported callbacks and malformed API fail without creating a partial destination" {
    const t = std.testing;
    const options = @import("test-options");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var original = try tmp.dir.createDirPathOpen(t.io, "source", .{});
    defer original.close(t.io);
    const source_path = try std.fs.path.join(t.allocator, &.{ root, "source" });
    defer t.allocator.free(source_path);
    try original.createDirPath(t.io, "src");
    const source_bytes = try simpleSource(t.allocator, true);
    defer t.allocator.free(source_bytes);
    try original.writeFile(t.io, .{ .sub_path = "src/keymap.zig", .data = source_bytes });
    var source = try inspect(t.allocator, t.io, source_path, null, root);
    defer source.deinit();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const toolchain: Toolchain = .{ .compiler = options.compiler, .build_root = options.repository, .cache = root, .packages = options.packages, .global_cache = options.compiler_cache };
    var data = try analyze(t.allocator, t.io, source, toolchain, &env);
    defer data.deinit();
    try t.expect(data.data.has_callbacks);
    try t.expectError(error.DefaultCallbackWithoutIds, prepare(t.allocator, t.io, source, data, "keycaprio_colemak_0_7", "Unsupported", "unique01".*));
    try original.writeFile(t.io, .{ .sub_path = "src/keymap.zig", .data = "pub const keymap = @compileError(\"Unsupported fixture API\");" });
    var bad = try inspect(t.allocator, t.io, source_path, "src/keymap.zig", root);
    defer bad.deinit();
    try t.expectError(error.IncompatibleKeymapSeeCachedCompilerLog, analyze(t.allocator, t.io, bad, toolchain, &env));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "project.zon", .{}));
    try original.writeFile(t.io, .{ .sub_path = "src/keymap.zig", .data = "pub const keymap = @import(\"../../escape.zig\");" });
    try t.expectError(error.ImportEscapesProject, inspect(t.allocator, t.io, source_path, "src/keymap.zig", root));
    try original.writeFile(t.io, .{ .sub_path = "src/keymap.zig", .data = "pub const keymap = @cImport({ @cInclude(\"system.h\"); });" });
    try t.expectError(error.CImportUnsupported, inspect(t.allocator, t.io, source_path, "src/keymap.zig", root));
}
