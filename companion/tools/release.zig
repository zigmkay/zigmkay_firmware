//! Preview validation, packaging and inventory. No device access or publishing.
const std = @import("std");
const builtin = @import("builtin");
const jobs = @import("companion-jobs");
const options = @import("release-options");
const pins = options;
const a = std.heap.page_allocator;
const version = options.application_version;

const platforms = [_][]const u8{
    "macos-aarch64.dmg",
    "macos-x86_64.dmg",
    "windows-x86_64.exe",
    "linux-x86_64.AppImage",
};

pub fn validateTag(tag: []const u8, expected: []const u8) !void {
    if (!std.mem.startsWith(u8, tag, "v")) return error.InvalidPreviewTag;
    const text = tag[1..];
    const marker = std.mem.indexOf(u8, text, "-preview.") orelse return error.InvalidPreviewTag;
    var numbers = std.mem.splitScalar(u8, text[0..marker], '.');
    for (0..3) |_| try decimal(numbers.next() orelse return error.InvalidPreviewTag);
    if (numbers.next() != null) return error.InvalidPreviewTag;
    try decimal(text[marker + "-preview.".len ..]);
    if (!std.mem.eql(u8, text, expected)) return error.PreviewVersionMismatch;
}

fn decimal(value: []const u8) !void {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidPreviewTag;
    for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidPreviewTag;
    _ = std.fmt.parseInt(u32, value, 10) catch return error.InvalidPreviewTag;
}

fn run(io: std.Io, argv: []const []const u8) ![]const u8 {
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const result = try std.process.run(a, io, .{
            .argv = argv,
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(600), .clock = .awake } },
        });
        defer a.free(result.stderr);
        var retained = false;
        defer if (!retained) a.free(result.stdout);
        if (result.term.success()) {
            retained = true;
            return result.stdout;
        }
        // DiskImages can briefly retain the source volume while creating a DMG.
        // Retry only the observed busy failure; never mask other packaging errors.
        if (attempt < 2 and argv.len > 1 and
            std.mem.eql(u8, std.fs.path.basename(argv[0]), "hdiutil") and
            std.mem.eql(u8, argv[1], "create") and
            std.mem.indexOf(u8, result.stderr, "hdiutil: create failed - Resource busy") != null)
        {
            std.log.warn(
                "Disk image creation is busy; retrying in 5 seconds (attempt {d}/3)",
                .{attempt + 2},
            );
            try std.Io.sleep(io, .fromSeconds(5), .awake);
            continue;
        }
        std.debug.print(
            "release command failed: {s}\n{s}\n{s}\n",
            .{ argv[0], result.stdout, result.stderr },
        );
        return error.ReleaseCommandFailed;
    }
}

fn join(parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(a, parts);
}

fn read(io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024 * 1024));
}

fn write(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn hashFile(io: std.Io, path: []const u8) ![32]u8 {
    const bytes = try read(io, path);
    defer a.free(bytes);
    return jobs.firmware.digest(bytes);
}

fn names(io: std.Io, root: []const u8) ![][]const u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(a);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file or entry.kind == .sym_link) try paths.append(a, try a.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return paths.toOwnedSlice(a);
}

fn elf(io: std.Io, path: []const u8) !bool {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var bytes: [18]u8 = undefined;
    if (try file.readPositionalAll(io, &bytes, 0) != bytes.len) return false;
    // The low byte of e_type: an executable or a shared object.
    return std.mem.eql(u8, bytes[0..4], "\x7fELF") and (bytes[16] == 2 or bytes[16] == 3);
}

pub fn checkGlibc(text: []const u8) !void {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "GLIBC_")) |index| {
        rest = rest[index + 6 ..];
        const end = std.mem.indexOfNone(u8, rest, "0123456789.") orelse rest.len;
        if (end == 0) continue;
        var parts = std.mem.splitScalar(u8, rest[0..end], '.');
        const major = try std.fmt.parseInt(u32, parts.next().?, 10);
        const minor = try std.fmt.parseInt(u32, parts.next() orelse "0", 10);
        if (major > 2 or (major == 2 and minor > 35)) return error.GlibcNewerThan235;
        rest = rest[end..];
    }
}

fn baselineLibrary(name: []const u8) bool {
    for ([_][]const u8{
        "ld-linux",
        "libc.so.",
        "libm.so.",
        "libpthread.so.",
        "libdl.so.",
        "librt.so.",
        "libresolv.so.",
        "libutil.so.",
        "libanl.so.",
        "libnss_",
        "libGL",
        "libEGL",
        "libGLES",
        "libvulkan",
        "libdrm",
    }) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
    return false;
}

fn linuxSource(io: std.Io, root: []const u8, filename: []const u8, packages: *std.StringHashMap(void)) !void {
    var ownership_result = try std.process.run(a, io, .{ .argv = &.{ "dpkg-query", "-S", filename } });
    if (!ownership_result.term.success()) {
        const canonical = try std.Io.Dir.realPathFileAbsoluteAlloc(io, filename, a);
        ownership_result = try std.process.run(a, io, .{ .argv = &.{ "dpkg-query", "-S", canonical } });
        if (!ownership_result.term.success()) return error.UnknownLibraryLicense;
    }
    const ownership = ownership_result.stdout;
    const end = std.mem.indexOf(u8, ownership, ": ") orelse return error.UnknownLibraryLicense;
    const package_name = ownership[0..end];
    const entry = try packages.getOrPut(try a.dupe(u8, package_name));
    if (entry.found_existing) return;
    const unqualified = package_name[0 .. std.mem.indexOfScalar(u8, package_name, ':') orelse package_name.len];
    const destination = try join(&.{ root, "usr/share/zigmkay/licenses/linux", unqualified });
    try std.Io.Dir.cwd().createDirPath(io, destination);
    try std.Io.Dir.cwd().copyFile(
        try join(&.{ "/usr/share/doc", unqualified, "copyright" }),
        .cwd(),
        try join(&.{ destination, "copyright" }),
        io,
        .{},
    );
    const source = std.mem.trim(u8, try run(io, &.{
        "dpkg-query",
        "-W",
        "-f=${source:Package}=${source:Version}",
        package_name,
    }), "\r\n ");
    const sources = try join(&.{
        std.fs.path.dirname(root).?,
        "corresponding-source/system-linux",
        unqualified,
    });
    try std.Io.Dir.cwd().createDirPath(io, sources);
    const result = try std.process.run(a, io, .{
        .argv = &.{ "apt-get", "source", "--download-only", "--only-source", source },
        .cwd = .{ .path = sources },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    if (!result.term.success()) {
        std.debug.print("Could not collect corresponding source {s}: {s}\n", .{ source, result.stderr });
        return error.MissingLibrarySource;
    }
    try write(io, try join(&.{ destination, "source-version.txt" }), source);
}

fn linuxLibraries(io: std.Io, root: []const u8) !void {
    const lib = try join(&.{ root, "usr/lib" });
    try std.Io.Dir.cwd().createDirPath(io, lib);
    var scanned: std.StringHashMap(void) = .init(a);
    var source_packages: std.StringHashMap(void) = .init(a);
    var inventory: std.Io.Writer.Allocating = .init(a);
    // SDL loads these optional native backends at runtime, outside DT_NEEDED.
    const available = try run(io, &.{ "/sbin/ldconfig", "-p" });
    for ([_][]const u8{
        "libudev.so.1",
        "libasound.so.2",
        "libpulse.so.0",
        "libwayland-client.so.0",
        "libwayland-egl.so.1",
        "libwayland-cursor.so.0",
        "libX11.so.6",
        "libXext.so.6",
        "libXcursor.so.1",
        "libXi.so.6",
        "libXfixes.so.3",
        "libXrandr.so.2",
        "libXss.so.1",
        "libxkbcommon.so.0",
        "libdecor-0.so.0",
    }) |soname| {
        var lines = std.mem.splitScalar(u8, available, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t");
            if (!std.mem.startsWith(u8, line, soname) or line.len <= soname.len or line[soname.len] != ' ') continue;
            const arrow = std.mem.indexOf(u8, line, "=> ") orelse continue;
            const source = line[arrow + 3 ..];
            try std.Io.Dir.cwd().copyFile(source, .cwd(), try join(&.{ lib, soname }), io, .{});
            try linuxSource(io, root, source, &source_packages);
            break;
        }
    }
    while (true) {
        var added = false;
        for (try names(io, root)) |relative| {
            const path = try join(&.{ root, relative });
            if (scanned.contains(path) or !try elf(io, path)) continue;
            try scanned.put(path, {});
            const symbols = try run(io, &.{ "readelf", "--version-info", path });
            try checkGlibc(symbols);
            const result = try std.process.run(a, io, .{
                .argv = &.{ "ldd", path },
                .stdout_limit = .limited(1024 * 1024),
                .stderr_limit = .limited(1024 * 1024),
            });
            const dependencies = result.stdout;
            if (!result.term.success() and
                std.mem.indexOf(u8, result.stderr, "not a dynamic executable") == null and
                std.mem.indexOf(u8, dependencies, "statically linked") == null and
                std.mem.indexOf(
                    u8,
                    dependencies,
                    "not a dynamic executable",
                ) == null) return error.LinuxDependencyAuditFailed;
            if (std.mem.indexOf(u8, dependencies, "not found") != null) return error.MissingLinuxLibrary;
            try inventory.writer.print("{s}\n{s}\n", .{ relative, dependencies });
            var lines = std.mem.splitScalar(u8, dependencies, '\n');
            while (lines.next()) |line| {
                const arrow = std.mem.indexOf(u8, line, "=>") orelse continue;
                const name = std.mem.trim(u8, line[0..arrow], " \t");
                const value = std.mem.trim(u8, line[arrow + 2 ..], " \t");
                if (value.len == 0 or value[0] != '/' or baselineLibrary(name)) continue;
                const source = value[0 .. std.mem.indexOfScalar(u8, value, ' ') orelse value.len];
                const destination = try join(&.{ lib, name });
                std.Io.Dir.cwd().access(io, destination, .{}) catch {
                    try std.Io.Dir.cwd().copyFile(source, .cwd(), destination, io, .{});
                    try linuxSource(io, root, source, &source_packages);
                    added = true;
                };
            }
        }
        if (!added) break;
    }
    try write(io, try join(&.{ root, "dependency-audit.txt" }), inventory.written());
    // libxkbcommon needs layout data independently of the working directory.
    try std.Io.Dir.cwd().createDirPath(io, try join(&.{ root, "usr/share/X11" }));
    _ = try run(io, &.{ "cp", "-R", "/usr/share/X11/xkb", try join(&.{ root, "usr/share/X11/xkb" }) });
    try linuxSource(io, root, "/usr/share/X11/xkb/rules/evdev", &source_packages);
}

fn fetch(io: std.Io, url: []const u8, expected: []const u8, destination: []const u8, executable: bool) !void {
    _ = try run(io, &.{
        "curl",
        "--fail",
        "--location",
        "--retry",
        "3",
        "-H",
        "Accept: application/octet-stream",
        url,
        "-o",
        destination,
    });
    const actual = std.fmt.bytesToHex(try hashFile(io, destination), .lower);
    if (!std.mem.eql(u8, &actual, expected)) return error.PackagingToolHashMismatch;
    if (executable) _ = try run(io, &.{ "chmod", "+x", destination });
}

fn runtimeSources(io: std.Io, root: []const u8) !void {
    const source_root = try join(&.{ std.fs.path.dirname(root).?, "corresponding-source/appimage" });
    try std.Io.Dir.cwd().createDirPath(io, source_root);
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "type2-runtime", pins.runtime_source_url, pins.runtime_source_sha256 },
        .{ "libfuse", pins.fuse_source_url, pins.fuse_source_sha256 },
        .{ "squashfuse", pins.squashfuse_source_url, pins.squashfuse_source_sha256 },
    }) |source| {
        const archive = try join(&.{ source_root, try std.fmt.allocPrint(a, "{s}.tar", .{source[0]}) });
        try fetch(io, source[1], source[2], archive, false);
        const extracted = try join(&.{ source_root, source[0] });
        try std.Io.Dir.cwd().createDirPath(io, extracted);
        _ = try run(io, &.{ "tar", "-xf", archive, "--strip-components=1", "-C", extracted });
        for (try names(io, extracted)) |relative| {
            const name = std.fs.path.basename(relative);
            if (std.ascii.startsWithIgnoreCase(name, "license") or
                std.ascii.startsWithIgnoreCase(name, "copying") or
                std.ascii.startsWithIgnoreCase(name, "notice"))
            {
                try std.Io.Dir.cwd().copyFile(
                    try join(&.{ extracted, relative }),
                    .cwd(),
                    try join(&.{ root, "usr/share/zigmkay/licenses/AppImage", source[0], relative }),
                    io,
                    .{ .make_path = true },
                );
            }
        }
        try std.Io.Dir.cwd().deleteTree(io, extracted);
    }
}

fn auditMac(io: std.Io, root: []const u8) !void {
    var inventory: std.Io.Writer.Allocating = .init(a);
    for (try names(io, root)) |relative| {
        const path = try join(&.{ root, relative });
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        var magic: [4]u8 = undefined;
        const count = try file.readPositionalAll(io, &magic, 0);
        file.close(io);
        if (count != 4) continue;
        const value = std.mem.readInt(u32, &magic, .little);
        if (value != 0xfeedfacf and value != 0xfeedface and value != 0xbebafeca) continue;
        const dependencies = try run(io, &.{ "otool", "-L", path });
        var lines = std.mem.splitScalar(u8, dependencies, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            const name = std.mem.trim(u8, line, " \t");
            if (name.len == 0) continue;
            if (!std.mem.startsWith(u8, name, "/usr/lib/") and
                !std.mem.startsWith(u8, name, "/System/Library/")) return error.NonSystemMacDependency;
        }
        try inventory.writer.print("{s}\n", .{dependencies});
    }
    try write(io, try join(&.{ root, "Contents/Resources/dependency-audit.txt" }), inventory.written());
}

fn peRva(coff: std.coff.Coff, rva: u32) !usize {
    for (coff.getSectionHeaders()) |section| {
        if (rva >= section.virtual_address and rva - section.virtual_address < section.size_of_raw_data) {
            const offset = @as(usize, section.pointer_to_raw_data) + rva - section.virtual_address;
            if (offset >= coff.data.len) return error.InvalidPeImport;
            return offset;
        }
    }
    return error.InvalidPeImport;
}

fn windowsSystemLibrary(name: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(name, "api-ms-win-") or
        std.ascii.startsWithIgnoreCase(name, "ext-ms-win-")) return true;
    for ([_][]const u8{
        "ntdll.dll",
        "kernel32.dll",
        "kernelbase.dll",
        "advapi32.dll",
        "bcrypt.dll",
        "bcryptprimitives.dll",
        "user32.dll",
        "gdi32.dll",
        "shell32.dll",
        "ole32.dll",
        "oleaut32.dll",
        "setupapi.dll",
        "cfgmgr32.dll",
        "hid.dll",
        "imm32.dll",
        "version.dll",
        "winmm.dll",
        "shlwapi.dll",
        "comctl32.dll",
        "comdlg32.dll",
        "usp10.dll",
        "powrprof.dll",
        "dwmapi.dll",
        "ws2_32.dll",
        "msvcrt.dll",
        "ucrtbase.dll",
        "crypt32.dll",
        "secur32.dll",
        "mfplat.dll",
        "mf.dll",
        "avrt.dll",
        "ksuser.dll",
        "propsys.dll",
        "runtimeobject.dll",
        "shcore.dll",
        "dxgi.dll",
        "d3d11.dll",
        "d3d12.dll",
        "d3dcompiler_47.dll",
        "dinput8.dll",
        "xinput1_4.dll",
        "windowscodecs.dll",
        "winspool.drv",
        "msimg32.dll",
        "opengl32.dll",
        "mswsock.dll",
        "cabinet.dll",
        "rpcrt4.dll",
        "imagehlp.dll",
        "dbghelp.dll",
        "wintrust.dll",
        "wininet.dll",
        "winhttp.dll",
        "winusb.dll",
        "d3d9.dll",
        "mmdevapi.dll",
        "dsound.dll",
    }) |system| if (std.ascii.eqlIgnoreCase(name, system)) return true;
    for ([_][]const u8{
        "psapi.dll",
        "userenv.dll",
        "iphlpapi.dll",
        "dnsapi.dll",
        "wtsapi32.dll",
        "urlmon.dll",
        "msctf.dll",
        "gdiplus.dll",
    }) |system| if (std.ascii.eqlIgnoreCase(name, system)) return true;
    return false;
}

fn auditPe(io: std.Io, path: []const u8, inventory: *std.Io.Writer) !void {
    const bytes = try read(io, path);
    defer a.free(bytes);
    const coff = try std.coff.Coff.init(bytes, false);
    if (!coff.is_image) return error.InvalidPeImage;
    const directories = coff.getDataDirectories();
    // Both ordinary and delay-loaded imports must resolve to baseline OS DLLs.
    for ([_]usize{ 1, 13 }) |directory_index| {
        if (directories.len <= directory_index) continue;
        const directory = directories[directory_index];
        if (directory.virtual_address == 0 or directory.size == 0) continue;
        const offset = try peRva(coff, directory.virtual_address);
        const stride: usize = if (directory_index == 1) 20 else 32;
        var index: usize = 0;
        while (index + stride <= directory.size) : (index += stride) {
            if (offset + index + stride > bytes.len) return error.InvalidPeImport;
            const entry = bytes[offset + index ..][0..stride];
            const name_rva = std.mem.readInt(
                u32,
                entry[if (directory_index == 1) 12 else 4..][0..4],
                .little,
            );
            if (name_rva == 0) break;
            const name_offset = try peRva(coff, name_rva);
            const end = std.mem.indexOfScalar(u8, bytes[name_offset..], 0) orelse return error.InvalidPeImport;
            const name = bytes[name_offset..][0..end];
            try inventory.print("{s}: {s}\n", .{ std.fs.path.basename(path), name });
            if (!windowsSystemLibrary(name)) {
                std.debug.print("Non-baseline Windows dependency: {s}: {s}\n", .{ path, name });
                return error.NonBaselineWindowsDependency;
            }
        }
    }
}

fn seal(io: std.Io, root: []const u8, resources: []const u8) !jobs.application_bundle.Manifest {
    var bundle = try jobs.application_bundle.Bundle.open(a, io, resources);
    defer bundle.deinit();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (try names(io, root)) |relative| {
        if (std.mem.endsWith(u8, relative, "application.zon")) continue;
        hash.update(relative);
        hash.update(&.{0});
        hash.update(&try hashFile(io, try join(&.{ root, relative })));
    }
    var manifest = bundle.manifest;
    manifest.id = hash.finalResult();
    var output: std.Io.Writer.Allocating = .init(a);
    try std.zon.stringify.serialize(manifest, .{}, &output.writer);
    try write(io, try join(&.{ resources, "application.zon" }), output.written());
    // The returned revision must outlive Bundle's arena.
    manifest.firmware_revision = try a.dupe(u8, manifest.firmware_revision);
    return manifest;
}

fn package(io: std.Io, root: []const u8, output: []const u8, revision: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, output);
    const platform = switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) platforms[0] else platforms[1],
        .windows => platforms[2],
        .linux => platforms[3],
        else => return error.UnsupportedPlatform,
    };
    const filename = try std.fmt.allocPrint(a, "Zigmkay-{s}-{s}", .{ version, platform });
    const destination = try join(&.{ output, filename });
    var manifest: jobs.application_bundle.Manifest = undefined;
    switch (builtin.os.tag) {
        .macos => {
            try auditMac(io, root);
            manifest = try seal(io, root, try join(&.{ root, "Contents/Resources" }));
            const stage = try join(&.{ output, "dmg-stage" });
            try std.Io.Dir.cwd().createDirPath(io, stage);
            _ = try run(io, &.{ "ditto", root, try join(&.{ stage, "Zigmkay.app" }) });
            try std.Io.Dir.cwd().symLink(
                io,
                "/Applications",
                try join(&.{ stage, "Applications" }),
                .{ .is_directory = true },
            );
            _ = try run(io, &.{
                "hdiutil",
                "create",
                "-ov",
                "-format",
                "UDZO",
                "-volname",
                "Zigmkay unsigned preview",
                "-srcfolder",
                stage,
                destination,
            });
            try std.Io.Dir.cwd().deleteTree(io, stage);
        },
        .windows => {
            const header = try jobs.bundle_payload.header(a, io, root);
            manifest = header.manifest;
            const extracted = try join(&.{ output, "windows-audit" });
            try jobs.bundle_payload.materialize(a, io, root, extracted);
            var inventory: std.Io.Writer.Allocating = .init(a);
            try auditPe(io, root, &inventory.writer);
            for (try names(io, extracted)) |name| {
                const binary = std.ascii.endsWithIgnoreCase(name, ".exe") or std.ascii.endsWithIgnoreCase(name, ".dll");
                if (binary) try auditPe(io, try join(&.{ extracted, name }), &inventory.writer);
            }
            try write(
                io,
                try std.fmt.allocPrint(a, "{s}.dependencies.txt", .{destination}),
                inventory.written(),
            );
            try std.Io.Dir.cwd().deleteTree(io, extracted);
            try std.Io.Dir.cwd().copyFile(root, .cwd(), destination, io, .{});
        },
        .linux => {
            try linuxLibraries(io, root);
            try runtimeSources(io, root);
            manifest = try seal(io, root, try join(&.{ root, "usr/share/zigmkay" }));
            const tool = try join(&.{ output, "appimagetool" });
            const runtime = try join(&.{ output, "runtime-x86_64" });
            try fetch(io, pins.tool_url, pins.tool_sha256, tool, true);
            try fetch(io, pins.runtime_url, pins.runtime_sha256, runtime, true);
            try checkGlibc(try run(io, &.{ "readelf", "--version-info", runtime }));
            if (std.mem.indexOf(u8, try run(io, &.{
                "readelf",
                "--program-headers",
                runtime,
            }), "INTERP") != null) return error.NonStaticAppImageRuntime;
            _ = try run(io, &.{
                "/usr/bin/env",
                "ARCH=x86_64",
                tool,
                "--appimage-extract-and-run",
                "--runtime-file",
                runtime,
                "--no-appstream",
                root,
                destination,
            });
            try std.Io.Dir.cwd().deleteFile(io, tool);
            try std.Io.Dir.cwd().deleteFile(io, runtime);
        },
        else => unreachable,
    }
    const metadata = .{
        .version = version,
        .source_commit = revision,
        .firmware_revision = manifest.firmware_revision,
        .zig_version = "0.17.0",
        .bundle_id = std.fmt.bytesToHex(manifest.id, .lower),
        .backend = @tagName(manifest.backend),
        .unsigned_preview = true,
        .schema_version = 3,
        .record_version = 1,
        .timing_version = 1,
        .metric_version = 1,
        .generator_version = 1,
        .asset = filename,
        .sha256 = std.fmt.bytesToHex(try hashFile(io, destination), .lower),
    };
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(metadata, .{ .whitespace = .indent_2 }, &json.writer);
    try write(io, try std.fmt.allocPrint(a, "{s}.metadata.json", .{destination}), json.written());
}

fn finalize(io: std.Io, root: []const u8, commit: []const u8) !void {
    var records: [4]std.json.Value = undefined;
    for (platforms, 0..) |platform, index| {
        const name = try std.fmt.allocPrint(a, "Zigmkay-{s}-{s}", .{ version, platform });
        const metadata_path = try std.fmt.allocPrint(a, "{s}.metadata.json", .{try join(&.{ root, name })});
        const parsed = try std.json.parseFromSlice(std.json.Value, a, try read(io, metadata_path), .{});
        records[index] = parsed.value;
        if (!std.mem.eql(u8, try metadataString(parsed.value, "source_commit"), commit) or
            !std.mem.eql(u8, try metadataString(parsed.value, "version"), version) or
            !std.mem.eql(
                u8,
                try metadataString(parsed.value, "asset"),
                name,
            )) return error.ReleaseMetadataMismatch;
        const hash = std.fmt.bytesToHex(try hashFile(io, try join(&.{ root, name })), .lower);
        if (!std.mem.eql(u8, try metadataString(parsed.value, "sha256"), &hash)) return error.ReleaseAssetHashMismatch;
    }
    _ = try hashFile(io, try join(&.{ root, "corresponding-source.tar.gz" }));
    var metadata: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(.{
        .version = version,
        .source_commit = commit,
        .unsigned_preview = true,
        .targets = records,
    }, .{ .whitespace = .indent_2 }, &metadata.writer);
    try write(io, try join(&.{ root, "release-metadata.json" }), metadata.written());
    var sums: std.Io.Writer.Allocating = .init(a);
    for (try names(io, root)) |name| {
        if (std.mem.eql(u8, name, "SHA256SUMS")) continue;
        if (std.mem.indexOfAny(u8, name, "/\\\r\n") != null) return error.UnexpectedReleaseAsset;
        try sums.writer.print("{s}  {s}\n", .{
            std.fmt.bytesToHex(try hashFile(io, try join(&.{ root, name })), .lower),
            name,
        });
    }
    try write(io, try join(&.{ root, "SHA256SUMS" }), sums.written());
}

fn metadataString(value: std.json.Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.ReleaseMetadataMismatch;
    const field = value.object.get(key) orelse return error.ReleaseMetadataMismatch;
    if (field != .string) return error.ReleaseMetadataMismatch;
    return field.string;
}

fn validateExistingRelease(bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidReleaseState;
    const draft = parsed.value.object.get("isDraft") orelse return error.InvalidReleaseState;
    if (draft != .bool) return error.InvalidReleaseState;
    if (!draft.bool) return error.ReleaseAlreadyPublished;
}

pub fn main(init: std.process.Init) !void {
    if (comptime !std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) @compileError("Requires Zig 0.17.0");
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "version")) {
        var stdout = std.Io.File.stdout().writer(init.io, &.{});
        try stdout.interface.print("{s}\n", .{version});
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "validate-tag")) {
        try validateTag(args[2], version);
        _ = try run(init.io, &.{ "git", "merge-base", "--is-ancestor", args[3], "origin/main" });
    } else if (args.len == 3 and std.mem.eql(u8, args[1], "validate-existing-release")) {
        try validateExistingRelease(try read(init.io, args[2]));
    } else if (args.len == 5 and std.mem.eql(u8, args[1], "package")) {
        try package(init.io, args[2], args[3], args[4]);
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "extract-windows")) {
        var bundle = try jobs.application_bundle.Bundle.fromExecutable(a, init.io, args[2], args[3]);
        defer bundle.deinit();
        try jobs.bundle_payload.materialize(a, init.io, args[2], bundle.root);
    } else if (args.len == 4 and std.mem.eql(u8, args[1], "finalize")) {
        try finalize(init.io, args[2], args[3]);
    } else return error.InvalidReleaseArguments;
}

test "preview tags are canonical and must match the package version" {
    try validateTag("v0.1.0-preview.1", "0.1.0-preview.1");
    for ([_][]const u8{
        "0.1.0-preview.1",
        "v0.1.0",
        "v0.1-preview.1",
        "v0.1.0-preview.01",
        "v0.1.0-preview.1-extra",
        "v0.1.0-preview.",
    }) |tag| try std.testing.expectError(error.InvalidPreviewTag, validateTag(tag, "0.1.0-preview.1"));
    try std.testing.expectError(
        error.PreviewVersionMismatch,
        validateTag("v0.2.0-preview.1", "0.1.0-preview.1"),
    );
    try checkGlibc("Name: GLIBC_2.35 Name: GLIBC_2.2.5");
    try std.testing.expectError(error.GlibcNewerThan235, checkGlibc("Name: GLIBC_2.36"));
    try validateExistingRelease("{\"isDraft\":true}");
    try std.testing.expectError(
        error.ReleaseAlreadyPublished,
        validateExistingRelease("{\"isDraft\":false}"),
    );
    try std.testing.expectError(error.InvalidReleaseState, validateExistingRelease("{}"));
}

test "release inventory refuses missing assets mismatched commits and changed hashes" {
    const t = std.testing;
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try t.expectError(error.FileNotFound, finalize(t.io, root, "commit"));
    for (platforms) |platform| {
        const name = try std.fmt.allocPrint(t.allocator, "Zigmkay-{s}-{s}", .{ version, platform });
        defer t.allocator.free(name);
        try temp.dir.writeFile(t.io, .{ .sub_path = name, .data = "fixture package" });
        var metadata: std.Io.Writer.Allocating = .init(t.allocator);
        defer metadata.deinit();
        try std.json.Stringify.value(.{
            .source_commit = "commit",
            .version = version,
            .asset = name,
            .sha256 = std.fmt.bytesToHex(jobs.firmware.digest("fixture package"), .lower),
        }, .{}, &metadata.writer);
        const meta_name = try std.fmt.allocPrint(t.allocator, "{s}.metadata.json", .{name});
        defer t.allocator.free(meta_name);
        try temp.dir.writeFile(t.io, .{ .sub_path = meta_name, .data = metadata.written() });
    }
    try t.expectError(error.FileNotFound, finalize(t.io, root, "commit"));
    try temp.dir.writeFile(t.io, .{ .sub_path = "corresponding-source.tar.gz", .data = "source fixture" });
    try t.expectError(error.ReleaseMetadataMismatch, finalize(t.io, root, "other commit"));
    try finalize(t.io, root, "commit");
    const changed = try std.fmt.allocPrint(t.allocator, "Zigmkay-{s}-{s}", .{ version, platforms[3] });
    defer t.allocator.free(changed);
    try temp.dir.writeFile(t.io, .{ .sub_path = changed, .data = "changed package" });
    try t.expectError(error.ReleaseAssetHashMismatch, finalize(t.io, root, "commit"));
}
