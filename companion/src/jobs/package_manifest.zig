//! Literal dependency metadata. No manifest/build script is evaluated.
const std = @import("std");

pub const Dependency = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    package_hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    lazy: bool = false,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    dependencies: []const Dependency,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn fields(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    buffer: *[2]std.zig.Ast.Node.Index,
) ![]const std.zig.Ast.Node.Index {
    const object = tree.fullStructInit(buffer, node) orelse return error.ExpectedLiteralManifestObject;
    if (object.ast.type_expr != .none) return error.ExpectedLiteralManifestObject;
    return object.ast.fields;
}

fn name(gpa: std.mem.Allocator, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ![]const u8 {
    const first = tree.firstToken(node);
    if (first < 3 or
        tree.tokenTag(first - 3) != .period or
        tree.tokenTag(first - 2) != .identifier or
        tree.tokenTag(first - 1) != .equal) return error.InvalidManifestField;
    const token = tree.tokenSlice(first - 2);
    const text = if (std.mem.startsWith(u8, token, "@\"")) try std.zig.string_literal.parseAlloc(gpa, token[1..]) else token;
    // MicroZig uses slash-separated dependency namespaces. These identifiers
    // are map keys, never filesystem paths; reject traversal-like components.
    if (text.len == 0 or text.len > 64) return error.InvalidDependencyName;
    var components = std.mem.splitScalar(u8, text, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.InvalidDependencyName;
        for (component) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and
                byte != '_' and
                byte != '-' and
                byte != '.') return error.InvalidDependencyName;
        }
    }
    return text;
}

fn string(gpa: std.mem.Allocator, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ![]const u8 {
    if (tree.nodeTag(node) != .string_literal) return error.ExpectedLiteralManifestString;
    return std.zig.string_literal.parseAlloc(
        gpa,
        tree.tokenSlice(tree.nodeMainToken(node)),
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidManifestString,
    };
}

/// Fields accepted in a dependency entry.
const Field = enum { url, hash, path, lazy, version, api_version, protocol_version, interface_version, unicode_version };

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Manifest {
    if (bytes.len > 1024 * 1024) return error.ManifestTooLarge;
    const source = try gpa.dupeSentinel(u8, bytes, 0);
    defer gpa.free(source);
    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.InvalidManifest;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var root_buffer: [2]std.zig.Ast.Node.Index = undefined;
    var dependencies_node: ?std.zig.Ast.Node.Index = null;
    for (try fields(&tree, tree.rootDecls()[0], &root_buffer)) |field| if (std.mem.eql(u8, try name(a, &tree, field), "dependencies")) {
        if (dependencies_node != null) return error.DuplicateManifestField;
        dependencies_node = field;
    };
    var dependencies: std.ArrayList(Dependency) = .empty;
    if (dependencies_node) |node| {
        var dependency_buffer: [2]std.zig.Ast.Node.Index = undefined;
        for (try fields(&tree, node, &dependency_buffer)) |entry| {
            if (dependencies.items.len == 256) return error.TooManyDependencies;
            const dependency_name = try name(a, &tree, entry);
            for (dependencies.items) |existing| {
                if (std.mem.eql(u8, existing.name, dependency_name)) return error.DuplicateDependency;
            }
            var dependency = Dependency{ .name = try a.dupe(u8, dependency_name) };
            var entry_buffer: [2]std.zig.Ast.Node.Index = undefined;
            var seen: std.EnumSet(Field) = .empty;
            for (try fields(&tree, entry, &entry_buffer)) |value| {
                const key = try name(a, &tree, value);
                const field = std.meta.stringToEnum(Field, key) orelse return error.UnsupportedDependencyField;
                if (seen.contains(field)) return error.DuplicateManifestField;
                seen.insert(field);
                switch (field) {
                    .url => dependency.url = try string(a, &tree, value),
                    .hash => dependency.package_hash = try string(a, &tree, value),
                    .path => dependency.path = try string(a, &tree, value),
                    .lazy => {
                        if (tree.nodeTag(value) != .identifier) return error.ExpectedLiteralManifestBoolean;
                        const boolean = tree.tokenSlice(tree.nodeMainToken(value));
                        dependency.lazy = if (std.mem.eql(u8, boolean, "true"))
                            true
                        else if (std.mem.eql(u8, boolean, "false"))
                            false
                        else
                            return error.ExpectedLiteralManifestBoolean;
                    },
                    // Informational versions are bound by the whole manifest SHA.
                    // They do not replace the immutable location/content pin.
                    .version, .api_version, .protocol_version, .unicode_version => _ = try string(a, &tree, value),
                    .interface_version => {
                        if (tree.nodeTag(value) != .number_literal) return error.ExpectedLiteralManifestInteger;
                        _ = std.fmt.parseInt(
                            u64,
                            tree.tokenSlice(tree.nodeMainToken(value)),
                            0,
                        ) catch return error.ExpectedLiteralManifestInteger;
                    },
                }
            }
            if (dependency.path != null) {
                if (dependency.url != null or
                    dependency.package_hash != null or
                    dependency.path.?.len == 0) return error.InvalidDependencyLocation;
            } else {
                if (dependency.url == null or
                    dependency.package_hash == null or
                    dependency.url.?.len == 0 or
                    dependency.package_hash.?.len == 0) return error.IncompleteDependencyPin;
                try validatePackageHash(dependency.package_hash.?);
            }
            try dependencies.append(a, dependency);
        }
    }
    const owned = try dependencies.toOwnedSlice(a);
    return .{ .arena = arena, .dependencies = owned };
}

test "literal dependency manifests own immutable pins" {
    const t = std.testing;
    const text = ".{ .name = .fixture, .dependencies = .{ .git = .{ .lazy = true, .url = \"git+https://github.com/allyourcodebase/picotool.git#d8df33801dbea792128baaab516291720d400a91\", .hash = \"picotool-2.3.1-PtJrRaJNAAA3xRwGctKAdomuKCJXz5UwMOrhzQ_Z2f-e\" }, .release = .{ .url = \"https://example.test/releases/v1/source.tar.gz\", .hash = \"sdl-1.0.3+3.4.16-i4QD0e0HqgDYP8m4T3rMJShyaDLy8ksp8qzCrCSncaPB\" }, .owned = .{ .path = \"packages/local\" } } }";
    const caller = try t.allocator.dupe(u8, text);
    defer t.allocator.free(caller);
    var parsed = try parse(t.allocator, caller);
    defer parsed.deinit();
    @memset(caller, 'x');
    try t.expectEqual(@as(usize, 3), parsed.dependencies.len);
    try t.expect(parsed.dependencies[0].lazy);
    try t.expectEqualStrings("packages/local", parsed.dependencies[2].path.?);
}

test "manifest data refuses missing pins conflicting locations and executable values" {
    const t = std.testing;
    try t.expectError(
        error.IncompleteDependencyPin,
        parse(
            t.allocator,
            ".{ .dependencies = .{ .dep = .{ .url = \"https://example.test/source.tar.gz\" } } }",
        ),
    );
    try t.expectError(
        error.InvalidDependencyLocation,
        parse(
            t.allocator,
            ".{ .dependencies = .{ .dep = .{ .path = \"local\", .url = \"https://example.test/source.tar.gz\" } } }",
        ),
    );
    try t.expectError(
        error.DuplicateManifestField,
        parse(t.allocator, ".{ .dependencies = .{ .dep = .{ .path = \"one\", .path = \"two\" } } }"),
    );
    if (parse(t.allocator, ".{ .dependencies = .{ .dep = .{ .url = @import(\"script.zig\"), .hash = \"opaque\" } } }")) |result| {
        var unexpected = result;
        unexpected.deinit();
        return error.ExpectedLiteralRefusal;
    } else |_| {}
    var empty = try parse(t.allocator, ".{ .dependencies = .{} }");
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.dependencies.len);
    var quoted = try parse(
        t.allocator,
        ".{ .dependencies = .{ .@\"microzig-core\" = .{ .path = \"packages/core\" } } }",
    );
    defer quoted.deinit();
    try t.expectEqualStrings("microzig-core", quoted.dependencies[0].name);
    var namespaced = try parse(
        t.allocator,
        ".{ .dependencies = .{ .@\"port/raspberrypi/rp2xxx\" = .{ .path = \"packages/rp\" } } }",
    );
    defer namespaced.deinit();
    try t.expectEqualStrings("port/raspberrypi/rp2xxx", namespaced.dependencies[0].name);
    for ([_][]const u8{ "/port", "port/", "port//rp", "port/../rp", "port/./rp" }) |invalid| {
        const fixture = try std.fmt.allocPrint(
            t.allocator,
            ".{{ .dependencies = .{{ .@\"{s}\" = .{{ .path = \"packages/rp\" }} }} }}",
            .{invalid},
        );
        defer t.allocator.free(fixture);
        try t.expectError(error.InvalidDependencyName, parse(t.allocator, fixture));
    }
    try t.expectError(
        error.InvalidDependencyName,
        parse(t.allocator, ".{ .dependencies = .{ .@\"../escape\" = .{ .path = \"outside\" } } }"),
    );
}

test "literal dependency metadata keeps pins mandatory" {
    const t = std.testing;
    var parsed = try parse(
        t.allocator,
        ".{ .dependencies = .{ .sdk = .{ .version = \"1.2.3\", .api_version = \"0.3\", .protocol_version = \"35\", .interface_version = 4, .unicode_version = \"16.0.0\", .url = \"https://example.test/sdk.tar.gz\", .hash = \"N-V-__8AAA46JQABKU7sa-6xGUAN44uFsYSUS_w79UVuu7qo\" } } }",
    );
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 1), parsed.dependencies.len);
    try t.expectError(
        error.IncompleteDependencyPin,
        parse(t.allocator, ".{ .dependencies = .{ .sdk = .{ .version = \"1.2.3\" } } }"),
    );
    try t.expectError(
        error.DuplicateManifestField,
        parse(
            t.allocator,
            ".{ .dependencies = .{ .sdk = .{ .path = \"local\", .version = \"1\", .version = \"2\" } } }",
        ),
    );
    try t.expectError(
        error.ExpectedLiteralManifestInteger,
        parse(
            t.allocator,
            ".{ .dependencies = .{ .sdk = .{ .path = \"local\", .interface_version = \"4\" } } }",
        ),
    );
}

fn validatePackageHash(value: []const u8) !void {
    if (value.len < 46 or value.len > 256 or value[value.len - 45] != '-') return error.InvalidDependencyPackageHash;
    for (value, 0..) |c, offset| {
        if (!std.ascii.isAlphanumeric(c) and
            c != '-' and
            c != '_' and
            !((c == '.' or c == '+') and offset < value.len - 45)) return error.InvalidDependencyPackageHash;
    }
}
