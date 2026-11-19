//! Installed locations, the remembered startup project and the project that
//! belongs to each board profile.
const std = @import("std");
const builtin = @import("builtin");
const desktop = @import("desktop-core");
const installed = @import("app-paths");
const keyboard_onboarding = @import("onboarding-ui");
const App = @import("App.zig");
const onboarding_flow = @import("onboarding_flow.zig");
const workers = @import("workers.zig");

pub fn installedPaths(gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map) !installed.OwnedPaths {
    const executable = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(executable);
    return installed.resolve(gpa, .{
        .platform = switch (builtin.os.tag) {
            .macos => .macos,
            .windows => .windows,
            .linux => .linux,
            else => return error.UnsupportedPlatform,
        },
        .executable_path = executable,
        .env = .{
            .home = environment.get("HOME"),
            .appdata = environment.get("APPDATA"),
            .localappdata = environment.get("LOCALAPPDATA"),
            .xdg_config_home = environment.get("XDG_CONFIG_HOME"),
            .xdg_data_home = environment.get("XDG_DATA_HOME"),
            .xdg_cache_home = environment.get("XDG_CACHE_HOME"),
        },
    });
}

/// Remembers `project_path` as the startup project and as the project of its
/// board profile.
pub fn remember(
    gpa: std.mem.Allocator,
    io: std.Io,
    user_paths: installed.Paths,
    project_path: []const u8,
    key: desktop.profile_projects.Key,
) !void {
    var config = try std.Io.Dir.cwd().createDirPathOpen(io, user_paths.config, .{});
    defer config.close(io);
    try desktop.startup_project.save(gpa, io, config, project_path);
    var registry = try desktop.profile_projects.Registry.load(gpa, io, config, null);
    defer registry.deinit();
    try registry.set(key, project_path);
    try registry.save(io, config);
}

/// Applies the installed default locations and opens the remembered project.
/// Startup only reads preferences: missing, corrupt or future data never
/// writes a default preference or project.
pub fn loadStartup(app: *App, user_paths: installed.Paths) !void {
    const gpa = app.gpa;
    const default_path = try std.fs.path.join(gpa, &.{ user_paths.projects, "My Keyboards" });
    defer gpa.free(default_path);
    try app.onboarding.defaults(default_path);
    try copyPath(&app.view.paths.project, default_path);
    const export_path = try std.fs.path.join(gpa, &.{ user_paths.builds, "export" });
    defer gpa.free(export_path);
    try copyPath(&app.view.paths.exported, export_path);

    const config = std.Io.Dir.cwd().openDir(app.io, user_paths.config, .{}) catch |err| {
        if (err != error.FileNotFound) app.view.report(err);
        return;
    };
    defer config.close(app.io);
    if (desktop.profile_projects.Registry.load(gpa, app.io, config, null)) |loaded| {
        app.registry.deinit();
        app.registry = loaded;
    } else |err| app.view.report(err);
    const remembered = desktop.startup_project.load(gpa, app.io, config) catch |err| {
        app.view.report(err);
        return;
    };
    defer onboarding_flow.refreshLibrary(app);
    const path = remembered orelse return;
    defer gpa.free(path);
    try openRemembered(app, path, default_path);
}

fn openRemembered(app: *App, path: []const u8, default_root: []const u8) !void {
    app.view.paths.project = @splat(0);
    @memcpy(app.view.paths.project[0..path.len], path);
    const action = app.view.paths.action(try app.model.id(), .open);
    if (workers.fileOperation(app.gpa, app.io, &app.view, &app.model, action)) |_| {
        app.onboarding.active = false;
        app.onboarding.selected = true;
        // Legacy preferences name a project inside a collection. Recover the
        // collection when the project is one of its members.
        if (std.fs.path.dirname(path)) |parent| if (std.fs.path.dirname(parent)) |root| {
            try keyboard_onboarding.State.set(&app.onboarding.root, root);
            app.onboarding.reloadCollection(app.gpa, app.io) catch |err| app.onboarding.report(err);
            if (app.onboarding.collection == null) try keyboard_onboarding.State.set(&app.onboarding.root, default_root);
        };
    } else |err| {
        app.view.report(err);
        app.onboarding.report(err);
        try keyboard_onboarding.State.set(&app.onboarding.location, path);
    }
    try app.owner.sync(&app.model);
}

/// Copies `path` into a zero-terminated, fixed-size path buffer.
fn copyPath(buffer: []u8, path: []const u8) !void {
    if (path.len >= buffer.len) return error.InvalidProjectPath;
    @memcpy(buffer[0..path.len], path);
}
