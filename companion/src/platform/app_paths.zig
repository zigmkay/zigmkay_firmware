//! Pure installed-resource and user-storage policy. Callers inject environment
//! and installation paths; this module never queries the OS or touches files.
const std = @import("std");
pub const Platform = enum { macos, windows, linux };

pub const Environment = struct {
    home: ?[]const u8 = null,
    appdata: ?[]const u8 = null,
    localappdata: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
};

pub const Options = struct {
    platform: Platform,
    env: Environment,
    executable_path: []const u8,
    /// Packaging supplies this for layouts other than adjacent resources or a
    /// macOS Contents/MacOS executable with Contents/Resources assets.
    resource_root: ?[]const u8 = null,
    /// Optional package prefix. Otherwise the executable directory (or .app
    /// bundle root) is protected from writable storage paths.
    installation_root: ?[]const u8 = null,
    app_name: []const u8 = "zigmkay",
};

pub const Paths = struct {
    installation_root: []const u8,
    resources: []const u8,
    config: []const u8,
    data: []const u8,
    cache: []const u8,
    projects: []const u8,
    logs: []const u8,
    rollback: []const u8,
    builds: []const u8,
    startup_preference: []const u8,
    profile_preferences: []const u8,
    legacy_profile_preferences: []const u8,
};

pub const OwnedPaths = struct {
    arena: std.heap.ArenaAllocator,
    paths: Paths,

    pub fn deinit(self: *OwnedPaths) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn separator(platform: Platform, char: u8) bool {
    return char == '/' or (platform == .windows and char == '\\');
}

fn validateWindowsSegment(part: []const u8) !void {
    if (part.len == 0 or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.InvalidAssetPath;
    for (part) |char| {
        if (char < 32 or std.mem.indexOfScalar(u8, "<>\"|?*", char) != null) return error.InvalidAssetPath;
    }
    const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return error.InvalidAssetPath;
    }
    if (stem.len == 4 and
        (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt")) and
        stem[3] >= '1' and
        stem[3] <= '9') return error.InvalidAssetPath;
}

pub fn validateAbsolute(platform: Platform, path: []const u8) !void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (platform == .windows) {
        const kind = std.fs.path.parsePathWindows(u8, path).kind;
        if (kind != .drive_absolute and kind != .unc_absolute) return error.InvalidPath;
        if (kind == .unc_absolute) {
            var components = std.mem.tokenizeAny(u8, path[2..], "/\\");
            _ = components.next() orelse return error.InvalidPath;
            _ = components.next() orelse return error.InvalidPath;
        }
    } else if (!std.fs.path.isAbsolutePosix(path)) return error.InvalidPath;
}

fn normalize(a: std.mem.Allocator, platform: Platform, parts: []const []const u8) ![]u8 {
    return if (platform == .windows) std.fs.path.resolveAllocWindows(a, parts) else std.fs.path.resolveAllocPosix(a, parts);
}

fn required(platform: Platform, value: ?[]const u8) ![]const u8 {
    const path = value orelse return error.MissingUserDirectory;
    try validateAbsolute(platform, path);
    return path;
}

fn xdg(
    a: std.mem.Allocator,
    env: Environment,
    value: ?[]const u8,
    fallback: []const u8,
    app: []const u8,
) ![]u8 {
    if (value) |path| {
        if (path.len != 0) {
            try validateAbsolute(.linux, path);
            return normalize(a, .linux, &.{ path, app });
        }
    }
    return normalize(a, .linux, &.{ try required(.linux, env.home), fallback, app });
}

fn inside(platform: Platform, child: []const u8, parent: []const u8) bool {
    if (child.len < parent.len) return false;
    const equal = if (platform == .windows) std.ascii.eqlIgnoreCase(child[0..parent.len], parent) else std.mem.eql(
        u8,
        child[0..parent.len],
        parent,
    );
    return equal and (child.len == parent.len or separator(platform, parent[parent.len - 1]) or separator(platform, child[parent.len]));
}

pub fn resolve(gpa: std.mem.Allocator, options: Options) !OwnedPaths {
    try validateAppName(options.platform, options.app_name);
    try validateAbsolute(options.platform, options.executable_path);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const platform = options.platform;
    const executable = try normalize(a, platform, &.{options.executable_path});
    const exe_dir = dirname(platform, executable) orelse return error.InvalidPath;
    const installation: Installation = if (platform == .macos and std.mem.endsWith(u8, exe_dir, "/Contents/MacOS"))
        .app_bundle
    else if (platform == .linux and exe_dir.len > "/usr/bin".len and std.mem.endsWith(u8, exe_dir, "/usr/bin"))
        .usr_prefix
    else
        .portable;
    const resources = if (options.resource_root) |root| blk: {
        try validateAbsolute(platform, root);
        break :blk try normalize(a, platform, &.{root});
    } else try normalize(a, platform, &.{ exe_dir, switch (installation) {
        .app_bundle => "../Resources",
        .usr_prefix => "../share/zigmkay",
        .portable => "resources",
    } });
    const installation_root = if (options.installation_root) |root| blk: {
        try validateAbsolute(platform, root);
        const prefix = try normalize(a, platform, &.{root});
        if (!inside(platform, executable, prefix) or !inside(platform, resources, prefix))
            return error.InvalidInstallationRoot;
        break :blk prefix;
    } else switch (installation) {
        .app_bundle, .usr_prefix => try normalize(a, platform, &.{ exe_dir, "../.." }),
        .portable => try a.dupe(u8, exe_dir),
    };
    const storage = try userStorage(a, options);
    try checkStorageOverlap(
        platform,
        &.{ storage.config, storage.data, storage.cache },
        &.{ resources, installation_root },
    );
    const config = storage.config;
    const data = storage.data;
    const cache = storage.cache;
    return .{ .arena = arena, .paths = .{
        .installation_root = installation_root,
        .resources = resources,
        .config = config,
        .data = data,
        .cache = cache,
        .projects = try normalize(a, platform, &.{ data, "projects" }),
        .logs = try normalize(a, platform, &.{ data, "logs" }),
        .rollback = try normalize(a, platform, &.{ data, "verified-rollback" }),
        .builds = try normalize(a, platform, &.{ cache, "builds" }),
        .startup_preference = try normalize(a, platform, &.{ config, "startup-project.zon" }),
        .profile_preferences = try normalize(a, platform, &.{ config, "profile-projects-v1.zon" }),
        .legacy_profile_preferences = try normalize(a, platform, &.{ config, "profile-projects.zon" }),
    } };
}

/// Where the executable is installed, which decides the default resource
/// directory and the protected installation root.
const Installation = enum {
    /// A macOS `.app` bundle executable in `Contents/MacOS`.
    app_bundle,
    /// A Linux executable in `<prefix>/usr/bin`.
    usr_prefix,
    /// Anything else: resources live next to the executable.
    portable,
};

fn dirname(platform: Platform, path: []const u8) ?[]const u8 {
    return if (platform == .windows) std.fs.path.dirnameWindows(path) else std.fs.path.dirnamePosix(path);
}

fn validateAppName(platform: Platform, name: []const u8) !void {
    if (name.len == 0) return error.InvalidAppName;
    for (name) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '-')) return error.InvalidAppName;
    }
    if (platform == .windows) validateWindowsSegment(name) catch return error.InvalidAppName;
}

const Storage = struct { config: []const u8, data: []const u8, cache: []const u8 };

/// The platform's per-user configuration, data and cache directories.
fn userStorage(a: std.mem.Allocator, options: Options) !Storage {
    const platform = options.platform;
    const name = options.app_name;
    switch (platform) {
        .macos => {
            const home = try required(platform, options.env.home);
            return .{
                .config = try normalize(a, platform, &.{
                    home,
                    "Library/Application Support",
                    name,
                    "preferences",
                }),
                .data = try normalize(a, platform, &.{ home, "Library/Application Support", name, "data" }),
                .cache = try normalize(a, platform, &.{ home, "Library/Caches", name }),
            };
        },
        .windows => {
            const config = try normalize(a, platform, &.{
                try required(platform, options.env.appdata),
                name,
                "preferences",
            });
            const local = try required(platform, options.env.localappdata);
            return .{
                .config = config,
                .data = try normalize(a, platform, &.{ local, name, "data" }),
                .cache = try normalize(a, platform, &.{ local, name, "cache" }),
            };
        },
        .linux => return .{
            .config = try xdg(a, options.env, options.env.xdg_config_home, ".config", name),
            .data = try xdg(a, options.env, options.env.xdg_data_home, ".local/share", name),
            .cache = try xdg(a, options.env, options.env.xdg_cache_home, ".cache", name),
        },
    }
}

/// Writable directories must not nest in each other or in protected ones.
fn checkStorageOverlap(
    platform: Platform,
    writable: []const []const u8,
    protected: []const []const u8,
) !void {
    for (writable, 0..) |path, i| {
        for (protected) |other| {
            if (inside(platform, path, other) or inside(platform, other, path)) return error.StorageOverlap;
        }
        for (writable[0..i]) |earlier| {
            if (inside(platform, path, earlier) or inside(platform, earlier, path)) return error.StorageOverlap;
        }
    }
}

pub const Asset = struct { relative_path: []const u8, bytes: []const u8 };

pub const MigrationEntry = struct {
    source: []const u8,
    destination: []const u8,
    bytes: []const u8,
    digest: [32]u8,
};

/// A proposal only. An eventual explicit executor must retain originals, reject
/// differing destinations and recheck source/destination digests. These bytes
/// are never parsed, normalized, compiled or rewritten as part of migration.
pub const MigrationReceipt = struct {
    version: u16 = 1,
    entries: []const MigrationEntry,
    preserve_originals: bool = true,
    destination_policy: enum { absent_or_identical } = .absent_or_identical,
};

pub const OwnedMigration = struct {
    arena: std.heap.ArenaAllocator,
    receipt: MigrationReceipt,

    pub fn deinit(self: *OwnedMigration) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn proposeMigration(
    gpa: std.mem.Allocator,
    platform: Platform,
    old_directory: []const u8,
    destination_directory: []const u8,
    assets: []const Asset,
) !OwnedMigration {
    try validateAbsolute(platform, old_directory);
    try validateAbsolute(platform, destination_directory);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const old = try normalize(a, platform, &.{old_directory});
    const destination = try normalize(a, platform, &.{destination_directory});
    if (inside(platform, old, destination) or inside(platform, destination, old)) return error.StorageOverlap;
    const entries = try a.alloc(MigrationEntry, assets.len);
    for (assets, entries, 0..) |asset, *entry, index| {
        if (asset.relative_path.len == 0 or
            std.mem.indexOfScalar(u8, asset.relative_path, 0) != null or
            separator(platform, asset.relative_path[0])) return error.InvalidAssetPath;
        if (std.mem.indexOfScalar(u8, asset.relative_path, ':') != null or
            std.mem.indexOfScalar(u8, asset.relative_path, '\\') != null) return error.InvalidAssetPath;
        var parts = std.mem.splitScalar(u8, asset.relative_path, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or
                std.mem.eql(u8, part, ".") or
                std.mem.eql(u8, part, "..")) return error.InvalidAssetPath;
            if (platform == .windows) try validateWindowsSegment(part);
        }
        const source = try normalize(a, platform, &.{ old, asset.relative_path });
        const target = try normalize(a, platform, &.{ destination, asset.relative_path });
        for (entries[0..index]) |earlier| {
            if (inside(platform, earlier.destination, target) or
                inside(platform, target, earlier.destination)) return error.DuplicateAsset;
        }
        entry.* = .{
            .source = source,
            .destination = target,
            .bytes = try a.dupe(u8, asset.bytes),
            .digest = undefined,
        };
        std.crypto.hash.sha2.Sha256.hash(entry.bytes, &entry.digest, .{});
    }
    return .{ .arena = arena, .receipt = .{ .entries = entries } };
}

test "installed paths are independent of working directories on all platforms" {
    var mac = try resolve(std.testing.allocator, .{
        .platform = .macos,
        .env = .{ .home = "/Users/Jane Doe" },
        .executable_path = "/Applications/Zigmkay.app/Contents/MacOS/zigmkay",
    });
    defer mac.deinit();
    try std.testing.expectEqualStrings("/Applications/Zigmkay.app/Contents/Resources", mac.paths.resources);
    try std.testing.expectEqualStrings("/Applications/Zigmkay.app", mac.paths.installation_root);
    try std.testing.expectEqualStrings(
        "/Users/Jane Doe/Library/Application Support/zigmkay/data/projects",
        mac.paths.projects,
    );
    try std.testing.expectEqualStrings("/Users/Jane Doe/Library/Caches/zigmkay/builds", mac.paths.builds);
    var windows = try resolve(std.testing.allocator, .{
        .platform = .windows,
        .env = .{
            .appdata = "C:\\Users\\Zoë\\AppData\\Roaming",
            .localappdata = "C:\\Users\\Zoë\\AppData\\Local",
        },
        .executable_path = "C:\\Program Files\\Zigmkay\\zigmkay.exe",
    });
    defer windows.deinit();
    try std.testing.expectEqualStrings("C:\\Program Files\\Zigmkay\\resources", windows.paths.resources);
    try std.testing.expectEqualStrings(
        "C:\\Users\\Zoë\\AppData\\Roaming\\zigmkay\\preferences\\startup-project.zon",
        windows.paths.startup_preference,
    );
    var linux = try resolve(std.testing.allocator, .{
        .platform = .linux,
        .env = .{ .home = "/home/zoë" },
        .executable_path = "/usr/bin/zigmkay",
        .resource_root = "/usr/share/zigmkay",
    });
    defer linux.deinit();
    try std.testing.expectEqualStrings("/home/zoë/.local/share/zigmkay/projects", linux.paths.projects);
    try std.testing.expectEqualStrings(
        "/home/zoë/.config/zigmkay/profile-projects-v1.zon",
        linux.paths.profile_preferences,
    );
    try std.testing.expectEqualStrings(
        "/home/zoë/.config/zigmkay/profile-projects.zon",
        linux.paths.legacy_profile_preferences,
    );
    try std.testing.expectEqualStrings("/usr/share/zigmkay", linux.paths.resources);
}

test "Windows relocated smoke test separates installation from user storage" {
    const env: Environment = .{
        .home = "C:\\temp\\Zigmkay offline ü\\home",
        .appdata = "C:\\temp\\Zigmkay offline ü\\config",
        .localappdata = "C:\\temp\\Zigmkay offline ü\\cache",
    };
    try std.testing.expectError(error.StorageOverlap, resolve(std.testing.allocator, .{
        .platform = .windows,
        .env = env,
        .executable_path = "C:\\temp\\Zigmkay offline ü\\Zigmkay.exe",
    }));
    var paths = try resolve(std.testing.allocator, .{
        .platform = .windows,
        .env = env,
        .executable_path = "C:\\temp\\Zigmkay offline ü\\install\\Zigmkay.exe",
    });
    defer paths.deinit();
    try std.testing.expectEqualStrings("C:\\temp\\Zigmkay offline ü\\install", paths.paths.installation_root);
    try std.testing.expectEqualStrings(
        "C:\\temp\\Zigmkay offline ü\\cache\\zigmkay\\cache",
        paths.paths.cache,
    );
}

test "mounted and extracted Linux AppDirs resolve resources without writable mount storage" {
    for ([_][]const u8{
        "/tmp/.mount_Zig ü/usr/bin/zigmkay-companion",
        "/home/user/Downloads/Zigmkay ü/squashfs-root/usr/bin/zigmkay-companion",
    }) |executable| {
        var paths = try resolve(std.testing.allocator, .{
            .platform = .linux,
            .env = .{ .home = "/home/user" },
            .executable_path = executable,
        });
        defer paths.deinit();
        try std.testing.expect(std.mem.endsWith(u8, paths.paths.resources, "/usr/share/zigmkay"));
        try std.testing.expect(!std.mem.endsWith(u8, paths.paths.installation_root, "/usr/bin"));
        try std.testing.expectEqualStrings("/home/user/.cache/zigmkay/builds", paths.paths.builds);
        try std.testing.expectEqualStrings("/home/user/.local/share/zigmkay/projects", paths.paths.projects);
    }
}

test "XDG values and UNC user directories are injected and validated" {
    var linux = try resolve(std.testing.allocator, .{
        .platform = .linux,
        .env = .{
            .xdg_config_home = "/settings",
            .xdg_data_home = "/personal",
            .xdg_cache_home = "/scratch",
        },
        .executable_path = "/opt/zigmkay/zigmkay",
    });
    defer linux.deinit();
    try std.testing.expectEqualStrings("/personal/zigmkay", linux.paths.data);
    try validateAbsolute(.windows, "\\\\server\\share\\profiles");
    for ([_][]const u8{
        "C:relative",
        "\\rooted",
        "relative",
        "\\\\server",
        "C:\\bad\x00path",
    }) |bad| try std.testing.expectError(error.InvalidPath, validateAbsolute(.windows, bad));
    try std.testing.expectError(error.InvalidPath, resolve(std.testing.allocator, .{
        .platform = .linux,
        .env = .{ .home = "/home/test", .xdg_data_home = "relative" },
        .executable_path = "/opt/app",
    }));
    try std.testing.expectError(
        error.MissingUserDirectory,
        resolve(std.testing.allocator, .{
            .platform = .macos,
            .env = .{},
            .executable_path = "/Applications/app",
        }),
    );
    try std.testing.expectError(error.StorageOverlap, resolve(std.testing.allocator, .{
        .platform = .macos,
        .env = .{ .home = "/user" },
        .executable_path = "/Applications/app",
        .resource_root = "/user/Library/Application Support/zigmkay/data",
    }));
    try std.testing.expectError(error.StorageOverlap, resolve(std.testing.allocator, .{
        .platform = .macos,
        .env = .{ .home = "/Applications/Zigmkay.app" },
        .executable_path = "/Applications/Zigmkay.app/Contents/MacOS/app",
    }));
    try std.testing.expectError(error.StorageOverlap, resolve(std.testing.allocator, .{
        .platform = .linux,
        .env = .{
            .xdg_config_home = "/settings",
            .xdg_data_home = "/settings",
            .xdg_cache_home = "/scratch",
        },
        .executable_path = "/opt/app",
    }));
}

test "migration receipt preserves exact project and source bytes and never overwrites" {
    var bytes = [_]u8{ 0, '\n', 255, '\r', 0 };
    var proposal = try proposeMigration(
        std.testing.allocator,
        .linux,
        "/old/repo/projects/personal",
        "/home/user/projects/personal",
        &.{
            .{ .relative_path = "project.zon", .bytes = "old project bytes\r\n" },
            .{ .relative_path = "sources/original.zig", .bytes = &bytes },
        },
    );
    defer proposal.deinit();
    bytes[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 0, '\n', 255, '\r', 0 }, proposal.receipt.entries[1].bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(proposal.receipt.entries[1].bytes, &digest, .{});
    try std.testing.expectEqual(digest, proposal.receipt.entries[1].digest);
    try std.testing.expect(proposal.receipt.preserve_originals);
    try std.testing.expectEqual(.absent_or_identical, proposal.receipt.destination_policy);
    try std.testing.expectEqualStrings(
        "/old/repo/projects/personal/sources/original.zig",
        proposal.receipt.entries[1].source,
    );
    try std.testing.expectError(
        error.InvalidAssetPath,
        proposeMigration(
            std.testing.allocator,
            .linux,
            "/old",
            "/new",
            &.{.{ .relative_path = "../escape", .bytes = "" }},
        ),
    );
    try std.testing.expectError(
        error.DuplicateAsset,
        proposeMigration(std.testing.allocator, .windows, "C:\\old", "C:\\new", &.{
            .{ .relative_path = "project.zon", .bytes = "a" },
            .{ .relative_path = "PROJECT.zon", .bytes = "a" },
        }),
    );
    for ([_][]const u8{
        "sources/CON.zig",
        "sources/filename. ",
        "sources/lpt1",
        "sources/file:stream",
    }) |bad|
        try std.testing.expectError(
            error.InvalidAssetPath,
            proposeMigration(
                std.testing.allocator,
                .windows,
                "C:\\old",
                "C:\\new",
                &.{.{ .relative_path = bad, .bytes = "" }},
            ),
        );
}
