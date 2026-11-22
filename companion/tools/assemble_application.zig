//! Developer-only application assembly. Never linked into the installed editor.
const std = @import("std");
const jobs = @import("companion-jobs");
const pins = @import("bundle-pins");
const builtin = @import("builtin");
// The runtime closure comes from `build/runtime.zig` through `bundle-pins`.
const runtime_source_root = pins.runtime_source_root;
const runtime_closure = pins.runtime_closure;
const Assembler = struct {
    a: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
    packages: []const u8,
    seen: std.StringHashMap(void),
    legal_seen: std.StringHashMap(void),
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    /// Leave the parts of the compiler distribution and of firmware packages
    /// out that bundled builds never read. Corresponding sources stay whole.
    prune: bool = false,
    fn copy(self: *Assembler, source: []const u8, relative: []const u8) anyerror!void {
        return self.copyTree(source, relative, .{});
    }
    /// Like `copy`, for the entries `selection` keeps.
    fn copyTree(self: *Assembler, source: []const u8, relative: []const u8, selection: Selection) anyerror!void {
        const destination = try std.fs.path.join(self.a, &.{ self.output, relative });
        const stat = try std.Io.Dir.cwd().statFile(self.io, source, .{});
        if (stat.kind == .directory) {
            var dir = try std.Io.Dir.cwd().openDir(self.io, source, .{ .iterate = true });
            defer dir.close(self.io);
            // A filtered tree gets directories only for the files it keeps.
            if (selection.keep == null) try std.Io.Dir.cwd().createDirPath(self.io, destination);
            var names: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (try it.next(self.io)) |entry| {
                if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".zig-cache") or std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, "zig-pkg")) continue;
                if (selection.extensions) |kept| if (entry.kind != .directory and !hasExtension(entry.name, kept)) continue;
                if (selection.extensions != null and entry.kind == .directory and (for (pins.firmware_skipped) |name| {
                    if (std.mem.eql(u8, entry.name, name)) break true;
                } else isSkippedFirmwarePath(relative, entry.name))) continue;
                if (selection.keep) |keep| if (!keep(try below(self.a, selection.below, entry.name), entry.kind == .directory)) continue;
                try names.append(self.a, try self.a.dupe(u8, entry.name));
            }
            std.mem.sort([]const u8, names.items, {}, less);
            for (names.items) |name| try self.copyTree(try std.fs.path.join(self.a, &.{ source, name }), try std.fs.path.join(self.a, &.{ relative, name }), .{
                .extensions = selection.extensions,
                .keep = selection.keep,
                .below = try below(self.a, selection.below, name),
            });
        } else if (stat.kind == .file) {
            try std.Io.Dir.cwd().copyFile(source, .cwd(), destination, self.io, .{ .make_path = true });
            const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, source, self.a, .limited(512 * 1024 * 1024));
            defer self.a.free(bytes);
            self.hash.update(relative);
            self.hash.update(&.{0});
            self.hash.update(&jobs.firmware.digest(bytes));
        } else return error.UnsupportedBundleResource;
    }
    fn closure(self: *Assembler, source: []const u8) anyerror!void {
        const manifest_path = try std.fs.path.join(self.a, &.{ source, "build.zig.zon" });
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.a.free(bytes);
        var manifest = try jobs.package_manifest.parse(self.a, bytes);
        defer manifest.deinit();
        for (manifest.dependencies) |dep| {
            if (dep.lazy and !std.mem.eql(u8, dep.name, "microzig") and !std.mem.eql(u8, dep.name, "port/raspberrypi/rp2xxx") and !std.mem.eql(u8, dep.name, "pico-sdk")) continue;
            if (dep.path) |path| {
                try self.closure(try std.fs.path.join(self.a, &.{ source, path }));
            } else if (dep.package_hash) |hash| try self.package(dep.name, hash);
        }
    }
    /// Copy the package `hash`, which a manifest depends on as `name`, and
    /// the packages it depends on.
    fn package(self: *Assembler, name: []const u8, hash: []const u8) anyerror!void {
        const entry = try self.seen.getOrPut(try self.a.dupe(u8, hash));
        if (entry.found_existing) return;
        const source = try std.fs.path.join(self.a, &.{ self.packages, hash });
        try self.copyTree(source, try std.fs.path.join(self.a, &.{ "dependencies/p", hash }), .{
            .keep = if (self.prune) packageFilter(name) else null,
        });
        try self.closure(source);
    }
    fn legal(self: *Assembler, source: []const u8, relative: []const u8) anyerror!void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, source, .{ .iterate = true });
        defer dir.close(self.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.name[0] != '.') try names.append(self.a, try self.a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, less);
        for (names.items) |name| {
            const path = try std.fs.path.join(self.a, &.{ source, name });
            const destination = try std.fs.path.join(self.a, &.{ relative, name });
            const stat = try dir.statFile(self.io, name, .{});
            if (stat.kind == .directory) {
                try self.legal(path, destination);
            } else if (stat.kind == .file and (std.ascii.startsWithIgnoreCase(name, "license") or std.ascii.startsWithIgnoreCase(name, "copying") or std.ascii.startsWithIgnoreCase(name, "notice") or std.ascii.startsWithIgnoreCase(name, "ofl") or std.ascii.startsWithIgnoreCase(name, "copyright"))) try self.copy(path, destination);
        }
    }
    fn legalPackage(self: *Assembler, hash: []const u8) anyerror!void {
        const entry = try self.legal_seen.getOrPut(try self.a.dupe(u8, hash));
        if (entry.found_existing) return;
        const source = try std.fs.path.join(self.a, &.{ self.packages, hash });
        try self.legal(source, try std.fs.path.join(self.a, &.{ "licenses", hash }));
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, try std.fs.path.join(self.a, &.{ source, "build.zig.zon" }), self.a, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.a.free(bytes);
        var manifest = try jobs.package_manifest.parse(self.a, bytes);
        defer manifest.deinit();
        for (manifest.dependencies) |dep| {
            if (dep.package_hash) |dependency| {
                if (dep.lazy) std.Io.Dir.cwd().access(self.io, try std.fs.path.join(self.a, &.{ self.packages, dependency }), .{}) catch continue;
                try self.legalPackage(dependency);
            }
        }
    }
};
/// What `copyTree` copies below a source directory.
const Selection = struct {
    /// Keep only files whose name ends in one of these (the firmware
    /// sources), and leave out the firmware's skipped directories.
    extensions: ?[]const []const u8 = null,
    /// Keep only the entries this accepts. It receives the entry's path below
    /// the copied tree's root, separated by '/'.
    keep: ?*const fn (path: []const u8, is_directory: bool) bool = null,
    /// The path of the directory being copied below the copied tree's root.
    below: []const u8 = "",
};

fn below(a: std.mem.Allocator, parent: []const u8, name: []const u8) ![]const u8 {
    return if (parent.len == 0) a.dupe(u8, name) else std.fmt.allocPrint(a, "{s}/{s}", .{ parent, name });
}

/// The host libc a bundled build links: its headers, its sources in `libc/`
/// and, for Linux, the generic headers of glibc.
const host_libc = switch (builtin.os.tag) {
    .macos => .{ .os = "darwin", .sources = "darwin", .generic = "" },
    .linux => .{ .os = "linux", .sources = "glibc", .generic = "generic-glibc" },
    .windows => .{ .os = "windows", .sources = "mingw", .generic = "" },
    else => @compileError("Unsupported bundle platform"),
};

/// The libc source directories of Zig's `lib/libc/`.
const libc_sources = [_][]const u8{ "darwin", "freebsd", "glibc", "mingw", "musl", "netbsd", "openbsd", "wasi" };

/// The parts of Zig's `lib/` that builds with the bundled compiler read.
/// Firmware targets are freestanding. Only host programs (the build runner,
/// regz with libxml2 and SQLite, the native tutor runner) link a libc, so
/// only the host's libc headers and sources ship. Nothing compiles C++ or
/// uses ThreadSanitizer; MinGW links libunwind.
fn keepToolchain(path: []const u8, is_directory: bool) bool {
    _ = is_directory;
    var parts = std.mem.splitScalar(u8, path, '/');
    const top = parts.first();
    for ([_][]const u8{ "docs", "libcxx", "libcxxabi", "libtsan" }) |unused| if (std.mem.eql(u8, top, unused)) return false;
    if (std.mem.eql(u8, top, "libunwind")) return builtin.os.tag == .windows;
    if (!std.mem.eql(u8, top, "libc")) return true;
    const kind = parts.next() orelse return true;
    if (std.mem.eql(u8, kind, "include")) return hostLibcHeaders(parts.next() orelse return true);
    for (libc_sources) |name| if (std.mem.eql(u8, kind, name)) return std.mem.eql(u8, kind, host_libc.sources);
    return true;
}

/// Whether `libc/include/<name>` holds headers of the host libc. Names are
/// `<arch>-<os>-<abi>`, `any-<os>-any` or `generic-<libc>`.
fn hostLibcHeaders(name: []const u8) bool {
    if (std.mem.eql(u8, name, host_libc.generic)) return true;
    var parts = std.mem.splitScalar(u8, name, '-');
    if (std.mem.eql(u8, parts.first(), "generic")) return false;
    const os = parts.next() orelse return false;
    if (!std.mem.eql(u8, os, host_libc.os)) return false;
    if (builtin.os.tag != .linux) return true;
    const abi = parts.rest();
    return std.mem.eql(u8, abi, "any") or std.mem.startsWith(u8, abi, "gnu");
}

/// Packages that ship much more than bundled builds read, by the name a
/// manifest depends on them as.
fn packageFilter(name: []const u8) ?*const fn ([]const u8, bool) bool {
    if (std.mem.eql(u8, name, "pico-sdk")) return keepPicoSdk;
    if (std.mem.eql(u8, name, "libxml2")) return keepLibxml2;
    return null;
}

/// The rp2xxx port reads only pico-sdk's SVD register descriptions
/// (`src/<chip>/hardware_regs/<CHIP>.svd`); its license stays beside them.
fn keepPicoSdk(path: []const u8, is_directory: bool) bool {
    const depth = std.mem.count(u8, path, "/");
    if (depth == 0) return if (is_directory) std.mem.eql(u8, path, "src") else std.ascii.startsWithIgnoreCase(path, "license");
    if (!std.mem.startsWith(u8, path, "src/")) return false;
    if (is_directory) return depth == 1 or (depth == 2 and std.mem.endsWith(u8, path, "/hardware_regs"));
    return depth == 3 and std.mem.indexOf(u8, path, "/hardware_regs/") != null and std.ascii.endsWithIgnoreCase(path, ".svd");
}

/// libxml2's release archive carries its test suite, fuzzers, Python
/// bindings and documentation next to the C sources that regz compiles.
fn keepLibxml2(path: []const u8, is_directory: bool) bool {
    if (!is_directory or std.mem.indexOfScalar(u8, path, '/') != null) return true;
    for ([_][]const u8{ "doc", "example", "fuzz", "python", "result", "test" }) |unused| if (std.mem.eql(u8, path, unused)) return false;
    return true;
}

fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
fn hasExtension(name: []const u8, extensions: []const []const u8) bool {
    for (extensions) |extension| if (std.mem.endsWith(u8, name, extension)) return true;
    return false;
}
fn isSkippedFirmwarePath(relative: []const u8, entry_name: []const u8) bool {
    const prefix = "build/" ++ pins.firmware_root ++ "/";
    if (relative.len < prefix.len) return false;
    for (prefix, relative[0..prefix.len]) |expected, actual| {
        if (expected == '/') {
            if (actual != '/' and actual != '\\') return false;
        } else if (actual != expected) return false;
    }
    const rest = relative[prefix.len..];
    for (pins.firmware_skipped_paths) |excluded| {
        if (rest.len + 1 + entry_name.len != excluded.len) continue;
        if (excluded[rest.len] != '/') continue;
        var matched = true;
        for (rest, excluded[0..rest.len]) |actual, expected| {
            if (expected == '/') {
                if (actual != '/' and actual != '\\') {
                    matched = false;
                    break;
                }
            } else if (actual != expected) {
                matched = false;
                break;
            }
        }
        if (matched and std.mem.eql(u8, entry_name, excluded[rest.len + 1 ..])) return true;
    }
    return false;
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 10) return error.InvalidAssemblyArguments;
    const repository = args[1];
    const compiler = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, args[2], a);
    const distribution = std.fs.path.dirname(compiler).?;
    const layout = switch (builtin.os.tag) {
        .macos => "Contents/Resources",
        .windows => "resources",
        .linux => "usr/share/zigmkay",
        else => return error.UnsupportedBundlePlatform,
    };
    // The build reuses its output directories; start empty so files from an
    // earlier layout never ship.
    for ([_][]const u8{ args[4], args[9] }) |output| {
        try std.Io.Dir.cwd().deleteTree(init.io, output);
        try std.Io.Dir.cwd().createDirPath(init.io, output);
    }
    const resources = try std.fs.path.join(a, &.{ args[4], layout });
    var assembly: Assembler = .{ .a = a, .io = init.io, .output = resources, .packages = args[3], .seen = .init(a), .legal_seen = .init(a), .prune = true };
    for ([_][]const u8{ "LICENSE", "NOTICE" }) |name| try assembly.copy(try std.fs.path.join(a, &.{ repository, name }), try std.fs.path.join(a, &.{ "licenses/application", name }));
    for (pins.license_hashes) |hash| try assembly.legalPackage(hash);
    try assembly.copy(compiler, "toolchain/zig" ++ if (@import("builtin").os.tag == .windows) ".exe" else "");
    try assembly.copyTree(try std.fs.path.join(a, &.{ distribution, "lib" }), "toolchain/lib", .{ .keep = keepToolchain });
    try assembly.copy(try std.fs.path.join(a, &.{ distribution, "LICENSE" }), "licenses/Zig.txt");
    for (runtime_closure) |name| try assembly.copy(try std.fs.path.join(a, &.{ repository, runtime_source_root, name }), try std.fs.path.join(a, &.{ "build/" ++ runtime_source_root, name }));
    try assembly.copy(try std.fs.path.join(a, &.{ repository, "runtime/build.zig" }), "build/build.zig");
    if (builtin.os.tag == .windows) {
        try assembly.copy(args[6], "tools/bootsel-transfer.exe");
    } else {
        try assembly.copy(args[6], "tools/picotool_flash");
        try assembly.copy(args[7], "tools/picotool");
    }
    // The firmware package of this repository, and the packages it pins.
    for (pins.firmware_paths) |path| try assembly.copyTree(try std.fs.path.join(a, &.{ pins.firmware_source, path }), try std.fs.path.join(a, &.{ "build", pins.firmware_root, path }), .{ .extensions = pins.firmware_extensions });
    try assembly.closure(pins.firmware_source);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ resources, "build/build.zig.zon" }), .data = pins.manifest });
    assembly.hash.update(pins.manifest);
    const manifest: jobs.application_bundle.Manifest = .{ .version = 2, .backend = if (builtin.os.tag == .windows) .windows_bootsel else .picotool, .id = assembly.hash.finalResult(), .firmware_revision = pins.firmware_revision, .wrapper_hash = jobs.firmware.digest(try std.Io.Dir.cwd().readFileAlloc(init.io, args[6], a, .limited(128 * 1024 * 1024))), .picotool_hash = jobs.firmware.digest(try std.Io.Dir.cwd().readFileAlloc(init.io, args[7], a, .limited(128 * 1024 * 1024))) };
    var text: std.Io.Writer.Allocating = .init(a);
    try std.zon.stringify.serialize(manifest, .{}, &text.writer);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ resources, "application.zon" }), .data = text.written() });
    const metadata = try std.fmt.allocPrint(a, "version={s}\nrevision={s}\narchitecture={s}\nminimum_os={s}\nunsigned_preview=true\n", .{ pins.application_version, pins.source_revision, @tagName(builtin.cpu.arch), switch (builtin.os.tag) {
        .macos => "macOS 15",
        .windows => "Windows 11",
        .linux => "glibc 2.35; Linux 5.15",
        else => unreachable,
    } });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ resources, "release.txt" }), .data = metadata });
    switch (builtin.os.tag) {
        .macos => {
            try std.Io.Dir.cwd().copyFile(args[5], .cwd(), try std.fs.path.join(a, &.{ args[4], "Contents/MacOS/zigmkay-companion" }), init.io, .{ .make_path = true });
            const numeric_version = pins.application_version[0 .. std.mem.indexOfScalar(u8, pins.application_version, '-') orelse pins.application_version.len];
            const plist = try std.fmt.allocPrint(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>zigmkay-companion</string><key>CFBundleIdentifier</key><string>org.zigmkay.companion</string><key>CFBundleName</key><string>Zigmkay</string><key>CFBundleIconFile</key><string>Zigmkay.icns</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>{s}</string><key>CFBundleVersion</key><string>{s}</string><key>ZigmkayVersion</key><string>{s}</string><key>LSMinimumSystemVersion</key><string>15.0</string><key>ZigmkayRevision</key><string>{s}</string><key>ZigmkayArchitecture</key><string>{s}</string></dict></plist>", .{ numeric_version, numeric_version, pins.application_version, pins.source_revision, @tagName(builtin.cpu.arch) });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ args[4], "Contents/Info.plist" }), .data = plist });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ resources, "Zigmkay.icns" }), .data = @embedFile("application-icns") });
        },
        .windows => try jobs.bundle_payload.pack(a, init.io, args[5], resources, try std.fs.path.join(a, &.{ args[4], "Zigmkay.exe" })),
        .linux => {
            try std.Io.Dir.cwd().copyFile(args[5], .cwd(), try std.fs.path.join(a, &.{ args[4], "usr/bin/zigmkay-companion" }), init.io, .{ .make_path = true });
            try std.Io.Dir.cwd().copyFile(args[8], .cwd(), try std.fs.path.join(a, &.{ args[4], "AppRun" }), init.io, .{});
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ args[4], "zigmkay.desktop" }), .data = "[Desktop Entry]\nType=Application\nName=Zigmkay (unsigned preview)\nExec=zigmkay-companion\nIcon=zigmkay\nCategories=Utility;Development;\nTerminal=false\n" });
            const app_dir = try std.Io.Dir.cwd().openDir(init.io, args[4], .{});
            defer app_dir.close(init.io);
            const png = @embedFile("application-png");
            try app_dir.writeFile(init.io, .{ .sub_path = "zigmkay.png", .data = png });
            try app_dir.writeFile(init.io, .{ .sub_path = ".DirIcon", .data = png });
            const theme = "usr/share/icons/hicolor/";
            try app_dir.createDirPath(init.io, theme ++ "scalable/apps");
            try app_dir.createDirPath(init.io, theme ++ "256x256/apps");
            try app_dir.writeFile(init.io, .{ .sub_path = theme ++ "scalable/apps/zigmkay.svg", .data = @embedFile("application-svg") });
            try app_dir.writeFile(init.io, .{ .sub_path = theme ++ "256x256/apps/zigmkay.png", .data = png });
            try assembly.copy(try std.fs.path.join(a, &.{ repository, "packaging/linux/70-zigmkay.rules" }), "70-zigmkay.rules");
        },
        else => unreachable,
    }
    // Keep corresponding sources outside the download's runtime resources.
    // Only selected package hashes are copied; never archive a developer cache.
    var sources: Assembler = .{ .a = a, .io = init.io, .output = args[9], .packages = args[3], .seen = .init(a), .legal_seen = .init(a) };
    var firmware_sources = assembly.seen.keyIterator();
    while (firmware_sources.next()) |hash| try sources.package("", hash.*);
    var desktop_sources = assembly.legal_seen.keyIterator();
    while (desktop_sources.next()) |hash| try sources.package("", hash.*);
}
