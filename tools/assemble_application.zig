//! Developer-only application assembly. Never linked into the installed editor.
const std = @import("std");
const jobs = @import("companion-jobs");
const pins = @import("bundle-pins");
const Assembler = struct {
    a: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
    packages: []const u8,
    seen: std.StringHashMap(void),
    legal_seen: std.StringHashMap(void),
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    fn copy(self: *Assembler, source: []const u8, relative: []const u8) anyerror!void {
        const destination = try std.fs.path.join(self.a, &.{ self.output, relative });
        const stat = try std.Io.Dir.cwd().statFile(self.io, source, .{});
        if (stat.kind == .directory) {
            var dir = try std.Io.Dir.cwd().openDir(self.io, source, .{ .iterate = true });
            defer dir.close(self.io);
            try std.Io.Dir.cwd().createDirPath(self.io, destination);
            var names: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (try it.next(self.io)) |entry| {
                if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".zig-cache") or std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, "zig-pkg")) continue;
                try names.append(self.a, try self.a.dupe(u8, entry.name));
            }
            std.mem.sort([]const u8, names.items, {}, less);
            for (names.items) |name| try self.copy(try std.fs.path.join(self.a, &.{ source, name }), try std.fs.path.join(self.a, &.{ relative, name }));
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
            if (dep.lazy and !std.mem.eql(u8, dep.name, "port/raspberrypi/rp2xxx") and !std.mem.eql(u8, dep.name, "pico-sdk")) continue;
            if (dep.path) |path| {
                try self.closure(try std.fs.path.join(self.a, &.{ source, path }));
            } else if (dep.package_hash) |hash| try self.package(hash);
        }
    }
    fn package(self: *Assembler, hash: []const u8) anyerror!void {
        const entry = try self.seen.getOrPut(try self.a.dupe(u8, hash));
        if (entry.found_existing) return;
        const source = try std.fs.path.join(self.a, &.{ self.packages, hash });
        try self.copy(source, try std.fs.path.join(self.a, &.{ "dependencies/p", hash }));
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
            if (dep.lazy and !std.mem.eql(u8, dep.name, "sdl3") and !std.mem.eql(u8, dep.name, "freetype") and !std.mem.eql(u8, dep.name, "svg2tvg")) continue;
            if (dep.package_hash) |dependency| try self.legalPackage(dependency);
        }
    }
};
fn less(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 8) return error.InvalidAssemblyArguments;
    const repository = args[1];
    const compiler = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, args[2], a);
    const distribution = std.fs.path.dirname(compiler).?;
    const resources = try std.fs.path.join(a, &.{ args[4], "Contents/Resources" });
    var assembly: Assembler = .{ .a = a, .io = init.io, .output = resources, .packages = args[3], .seen = .init(a), .legal_seen = .init(a) };
    for ([_][]const u8{ "LICENSE", "NOTICE" }) |name| try assembly.copy(try std.fs.path.join(a, &.{ repository, name }), try std.fs.path.join(a, &.{ "licenses/application", name }));
    for (pins.license_hashes) |hash| try assembly.legalPackage(hash);
    try assembly.copy(compiler, "toolchain/zig" ++ if (@import("builtin").os.tag == .windows) ".exe" else "");
    try assembly.copy(try std.fs.path.join(a, &.{ distribution, "lib" }), "toolchain/lib");
    try assembly.copy(try std.fs.path.join(a, &.{ distribution, "LICENSE" }), "licenses/Zig.txt");
    for ([_][]const u8{ "project", "layout-model", "runner", "importer" }) |name| try assembly.copy(try std.fs.path.join(a, &.{ repository, "packages", name }), try std.fs.path.join(a, &.{ "build/packages", name }));
    try assembly.copy(try std.fs.path.join(a, &.{ repository, "runtime/build.zig" }), "build/build.zig");
    try assembly.copy(args[6], "tools/picotool_flash" ++ if (@import("builtin").os.tag == .windows) ".exe" else "");
    try assembly.copy(args[7], "tools/picotool" ++ if (@import("builtin").os.tag == .windows) ".exe" else "");
    try assembly.package(pins.firmware_hash);
    try assembly.package(pins.microzig_hash);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ resources, "build/build.zig.zon" }), .data = pins.manifest });
    assembly.hash.update(pins.manifest);
    const manifest: jobs.application_bundle.Manifest = .{ .id = assembly.hash.finalResult(), .firmware_revision = pins.firmware_revision, .wrapper_hash = jobs.firmware.digest(try std.Io.Dir.cwd().readFileAlloc(init.io, args[6], a, .limited(128 * 1024 * 1024))), .picotool_hash = jobs.firmware.digest(try std.Io.Dir.cwd().readFileAlloc(init.io, args[7], a, .limited(128 * 1024 * 1024))) };
    var text: std.Io.Writer.Allocating = .init(a);
    try std.zon.stringify.serialize(manifest, .{}, &text.writer);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ resources, "application.zon" }), .data = text.written() });
    // Native executable and resources are adjacent in the macOS bundle layout.
    try std.Io.Dir.cwd().copyFile(args[5], .cwd(), try std.fs.path.join(a, &.{ args[4], "Contents/MacOS/zigmkay-companion" }), init.io, .{ .make_path = true });
    const plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>zigmkay-companion</string><key>CFBundleIdentifier</key><string>org.zigmkay.companion</string><key>CFBundleName</key><string>Zigmkay</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>";
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ args[4], "Contents/Info.plist" }), .data = plist });
    if (@import("builtin").os.tag == .windows) try jobs.bundle_payload.pack(a, init.io, args[5], resources, try std.fs.path.join(a, &.{ args[4], "Zigmkay.exe" }));
}
