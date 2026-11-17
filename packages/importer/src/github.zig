//! Public GitHub sources, resolved to a commit before bounded archive download.
const std = @import("std");
const paths = @import("project").collection;
pub const Repository = struct { owner: []const u8, name: []const u8, ref: ?[]const u8 };
pub fn parse(url: []const u8) !Repository {
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, url, prefix) or std.mem.indexOfAny(u8, url, "?#\\\r\n\x00") != null) return error.PublicGithubRepositoryUrlRequired;
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, url[prefix.len..], "/"), '/');
    const owner = parts.next() orelse return error.PublicGithubRepositoryUrlRequired;
    var name = parts.next() orelse return error.PublicGithubRepositoryUrlRequired;
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    for ([_][]const u8{ owner, name }) |part| {
        if (part.len == 0 or part.len > 100 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.PublicGithubRepositoryUrlRequired;
        for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.PublicGithubRepositoryUrlRequired;
    }
    const marker = parts.next() orelse return .{ .owner = owner, .name = name, .ref = null };
    if (!std.mem.eql(u8, marker, "tree")) return error.GithubRootTreeUrlRequired;
    const ref = parts.rest();
    if (ref.len == 0 or ref.len > 256) return error.GithubRootTreeUrlRequired;
    for (ref) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '/' and c != '%') return error.GithubRootTreeUrlRequired;
    return .{ .owner = owner, .name = name, .ref = ref };
}
pub fn get(a: std.mem.Allocator, io: std.Io, url: []const u8, limit: usize) ![]const u8 {
    const Outcome = union(enum) { downloaded: anyerror![]const u8, timeout: std.Io.Cancelable!void };
    var buffer: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &buffer);
    defer while (select.cancel()) |outcome| switch (outcome) {
        .downloaded => |result| {
            if (result) |bytes| a.free(bytes) else |_| {}
        },
        .timeout => {},
    };
    try select.concurrent(.downloaded, download, .{ a, io, url, limit });
    try select.concurrent(.timeout, struct {
        fn timeout(clock_io: std.Io) std.Io.Cancelable!void {
            try std.Io.sleep(clock_io, .fromSeconds(60), .awake);
        }
    }.timeout, .{io});
    return switch (try select.await()) {
        .downloaded => |result| result,
        .timeout => error.GithubDownloadTimedOut,
    };
}
fn download(a: std.mem.Allocator, io: std.Io, url: []const u8, limit: usize) ![]const u8 {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const buffer = try a.alloc(u8, limit);
    defer a.free(buffer);
    var output: std.Io.Writer = .fixed(buffer);
    const response = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &output, .extra_headers = &.{.{ .name = "User-Agent", .value = "Zigmkay-Keymap-Importer/1" }} });
    if (response.status == .not_found or response.status == .unauthorized or response.status == .forbidden) return error.PublicRepositoryUnavailable;
    if (response.status != .ok) return error.GithubDownloadFailed;
    return a.dupe(u8, output.buffered());
}
pub const Resolved = struct { repository: []const u8, ref: []const u8, commit: []const u8 };
pub fn resolve(a: std.mem.Allocator, io: std.Io, url: []const u8) !Resolved {
    return resolveAt(a, io, url, "https://api.github.com");
}
pub fn resolveAt(a: std.mem.Allocator, io: std.Io, url: []const u8, api_root: []const u8) !Resolved {
    const repo = try parse(url);
    const encoded_ref = repo.ref orelse "HEAD";
    const reference = try (std.Uri.Component{ .percent_encoded = encoded_ref }).toRawMaybeAlloc(a);
    defer if (std.mem.indexOfScalar(u8, encoded_ref, '%') != null) a.free(reference);
    const escaped = try std.fmt.allocPrint(a, "{f}", .{std.fmt.alt(std.Uri.Component{ .raw = reference }, .formatEscaped)});
    defer a.free(escaped);
    const endpoint = try std.fmt.allocPrint(a, "{s}/repos/{s}/{s}/commits/{s}", .{ api_root, repo.owner, repo.name, escaped });
    defer a.free(endpoint);
    const bytes = try get(a, io, endpoint, 1024 * 1024);
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(struct { sha: []const u8 }, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const commit = parsed.value.sha;
    if (commit.len != 40) return error.InvalidGithubCommit;
    for (commit) |c| if (!std.ascii.isHex(c)) return error.InvalidGithubCommit;
    return .{ .repository = try std.fmt.allocPrint(a, "https://github.com/{s}/{s}", .{ repo.owner, repo.name }), .ref = try a.dupe(u8, reference), .commit = try a.dupe(u8, commit) };
}
/// Strip the single GitHub archive root. Reject links and unsafe names before IO.
pub fn archivePath(name: []const u8) ![]const u8 {
    const clean = std.mem.trimEnd(u8, name, "/");
    if (clean.len == 0 or clean.len > 1024 or clean[0] == '/' or std.mem.indexOfAny(u8, clean, "\\:\x00") != null) return error.ArchivePathRejected;
    var parts = std.mem.splitScalar(u8, clean, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.ArchivePathRejected;
    const slash = std.mem.indexOfScalar(u8, clean, '/') orelse return "";
    return clean[slash + 1 ..];
}
pub fn extract(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, gzip: []const u8) !void {
    if (gzip.len > 16 * 1024 * 1024) return error.DownloadLimit;
    var input: std.Io.Reader = .fixed(gzip);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    // Bound even metadata and skipped files before interpreting tar records.
    const unpacked = try decompress.reader.allocRemaining(a, .limited(64 * 1024 * 1024));
    defer a.free(unpacked);
    var reader: std.Io.Reader = .fixed(unpacked);
    var names: [1024]u8 = undefined;
    var links: [1024]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    var count: usize = 0;
    var root: ?[]const u8 = null;
    defer if (root) |value| a.free(value);
    while (try it.next()) |file| {
        count += 1;
        if (count > 4096) return error.ArchiveFileLimit;
        const path = try archivePath(file.name);
        const top = file.name[0 .. std.mem.indexOfScalar(u8, file.name, '/') orelse file.name.len];
        if (root) |value| {
            if (!std.mem.eql(u8, value, top)) return error.ArchivePathRejected;
        } else root = try a.dupe(u8, top);
        switch (file.kind) {
            .directory => continue,
            .file => {},
            else => return error.ArchiveLinkRejected,
        }
        if (path.len == 0) return error.ArchivePathRejected;
        if (!std.mem.endsWith(u8, path, ".zig") and !std.mem.eql(u8, path, "build.zig.zon")) continue;
        if (file.size > @import("project").Limits.source_bytes) return error.SourceLimit;
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
        const out = try dir.createFile(io, path, .{ .exclusive = true });
        defer out.close(io);
        const bytes = try a.alloc(u8, @intCast(file.size));
        defer a.free(bytes);
        var writer: std.Io.Writer = .fixed(bytes);
        try it.streamRemaining(file, &writer);
        try out.writeStreamingAll(io, writer.buffered());
    }
}
test "GitHub URLs and archive containment reject ambiguous or escaping input" {
    const t = std.testing;
    try t.expectEqualStrings("v1", (try parse("https://github.com/owner/repo/tree/v1")).ref.?);
    try t.expect((try parse("https://github.com/owner/repo.git")).ref == null);
    try t.expectError(error.GithubRootTreeUrlRequired, parse("https://github.com/owner/repo/blob/main/src/keymap.zig"));
    try t.expectError(error.PublicGithubRepositoryUrlRequired, parse("https://user:password@github.com/owner/repo"));
    for ([_][]const u8{ "root/../escape", "/root/file", "root/a\\b", "root/C:/file", "root//file" }) |path| try t.expectError(error.ArchivePathRejected, archivePath(path));
    try t.expectEqualStrings("src/keymap.zig", try archivePath("repo-commit/src/keymap.zig"));
}

fn archiveFixture(a: std.mem.Allocator, path: []const u8, link: bool) ![]u8 {
    var tar: std.Io.Writer.Allocating = .init(a);
    defer tar.deinit();
    var writer: std.tar.Writer = .{ .underlying_writer = &tar.writer };
    if (link) try writer.writeLink(path, "../outside", .{}) else try writer.writeFileBytes(path, "pub const keymap = .{};\n", .{});
    try writer.finishPedantically();
    var compressed: std.Io.Writer.Allocating = .init(a);
    errdefer compressed.deinit();
    var buffer: [65536]u8 = undefined;
    var gzip = try std.compress.flate.Compress.Raw.init(&compressed.writer, &buffer, .gzip);
    try gzip.writer.writeAll(tar.written());
    try gzip.finish();
    return compressed.toOwnedSlice();
}
test "bounded archive extraction accepts sources and rejects escaping paths and links" {
    const t = std.testing;
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    const valid = try archiveFixture(t.allocator, "repo-sha/src/keymap.zig", false);
    defer t.allocator.free(valid);
    try extract(t.allocator, t.io, dir.dir, valid);
    const bytes = try dir.dir.readFileAlloc(t.io, "src/keymap.zig", t.allocator, .limited(1024));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("pub const keymap = .{};\n", bytes);
    const escaping = try archiveFixture(t.allocator, "repo-sha/../escape.zig", false);
    defer t.allocator.free(escaping);
    try t.expectError(error.ArchivePathRejected, extract(t.allocator, t.io, dir.dir, escaping));
    const linked = try archiveFixture(t.allocator, "repo-sha/link.zig", true);
    defer t.allocator.free(linked);
    try t.expectError(error.ArchiveLinkRejected, extract(t.allocator, t.io, dir.dir, linked));
}
fn respond(server: *std.Io.net.Server, io: std.Io, body: []const u8, status: []const u8, expected_path: []const u8) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    var input_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &input_buffer);
    const first = try reader.interface.takeDelimiterInclusive('\n');
    if (std.mem.indexOf(u8, first, expected_path) == null) return error.UnexpectedHttpFixturePath;
    while (true) {
        const line = try reader.interface.takeDelimiterInclusive('\n');
        if (std.mem.eql(u8, line, "\r\n")) break;
    }
    var output_buffer: [8192]u8 = undefined;
    var writer = stream.writer(io, &output_buffer);
    try writer.interface.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len });
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}
test "local HTTP fixtures verify immutable ref resolution download bounds and retryable failure" {
    const t = std.testing;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(t.io, .{});
    defer server.deinit(t.io);
    const root = try std.fmt.allocPrint(t.allocator, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    defer t.allocator.free(root);
    const json = "{\"sha\":\"9a3965c07cac85722817ef98da4f56335781a412\"}";
    var first = try std.Io.concurrent(t.io, respond, .{ &server, t.io, json, "200 OK", "/repos/owner/repo/commits/release" });
    defer _ = first.cancel(t.io) catch {};
    const resolved = try resolveAt(t.allocator, t.io, "https://github.com/owner/repo/tree/release", root);
    defer {
        t.allocator.free(resolved.repository);
        t.allocator.free(resolved.ref);
        t.allocator.free(resolved.commit);
    }
    try first.await(t.io);
    try t.expectEqualStrings("9a3965c07cac85722817ef98da4f56335781a412", resolved.commit);
    var branched = try std.Io.concurrent(t.io, respond, .{ &server, t.io, json, "200 OK", "/repos/owner/repo/commits/feature%2Fbranch" });
    defer _ = branched.cancel(t.io) catch {};
    const branch = try resolveAt(t.allocator, t.io, "https://github.com/owner/repo/tree/feature%2Fbranch", root);
    defer {
        t.allocator.free(branch.repository);
        t.allocator.free(branch.ref);
        t.allocator.free(branch.commit);
    }
    try branched.await(t.io);
    try t.expectEqualStrings("feature/branch", branch.ref);
    var failed = try std.Io.concurrent(t.io, respond, .{ &server, t.io, "unavailable", "503 Service Unavailable", "/" });
    defer _ = failed.cancel(t.io) catch {};
    try t.expectError(error.GithubDownloadFailed, get(t.allocator, t.io, root, 1024));
    try failed.await(t.io);
    var oversized = try std.Io.concurrent(t.io, respond, .{ &server, t.io, "larger than limit", "200 OK", "/" });
    defer _ = oversized.cancel(t.io) catch {};
    if (get(t.allocator, t.io, root, 2)) |bytes| {
        t.allocator.free(bytes);
        return error.ExpectedDownloadLimit;
    } else |_| {}
    try oversized.await(t.io);
}
