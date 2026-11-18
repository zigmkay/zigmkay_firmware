//! The main window shows onboarding, the tutor or the editor.
const std = @import("std");
const dvui = @import("dvui");
const project = @import("project");
const boards = @import("catalog-project");
const editor = @import("editor-frame-ui");
const keyboard_onboarding = @import("onboarding-ui");
const dialog = @import("folder-dialog");
const App = @import("App.zig");
const Tutor = @import("Tutor.zig");
const commands = @import("commands.zig");
const desktop = @import("desktop-core");
const fixtures = @import("fixtures.zig");

const Toolbar = @FieldType(editor.Frame, "toolbar");
const Choice = std.meta.Elem(@FieldType(Toolbar, "layouts"));

/// What the screen requested this frame.
pub const Screen = struct {
    rendered: editor.Result = .{ .effect = .none },
    onboarding: keyboard_onboarding.Action = .none,
    tutor: Tutor.Outcome = .{},
};

pub fn draw(app: *App, board: *const boards.OwnedBoard, practice: Tutor.Frame, can_build: bool, now_us: u64) !Screen {
    var toolbar = try toolbarFrame(app, board, can_build, now_us);
    fixtures.statusToolbar(app, &toolbar);
    var screen: Screen = .{};
    app.onboarding.preparing_tutor = app.jobs.runner != null;
    if (app.onboarding.active) {
        screen.onboarding = try keyboard_onboarding.draw(&app.onboarding, .{
            .dirty = app.unsavedChanges(),
            .autosaves = commands.autosaves(app),
            .host_source = if (app.source) |*value| value.id() else "Offline",
            .light = app.view.toolbar.light,
            .current_path = std.mem.sliceTo(&app.view.paths.project, 0),
            .running = if (runningIdentity(app)) |identity| .{ .board_id = identity.board_id, .profile_id = identity.profile_id } else null,
            .now = std.Io.Timestamp.now(app.io, .real).nanoseconds,
        });
    } else if (app.practicing) {
        screen.tutor = Tutor.draw(app, practice, now_us);
    } else if (app.life.editor_visible) {
        screen.rendered = drawEditor(app, board, toolbar) catch |err| failed: {
            app.view.report(err);
            break :failed .{ .effect = .none };
        };
    }
    return screen;
}

fn drawEditor(app: *App, board: *const boards.OwnedBoard, toolbar: Toolbar) !editor.Result {
    const document = app.model.document();
    return editor.draw(&app.view, &app.owner, &app.model, .{
        .toolbar = toolbar,
        .keyboard = .{
            .snapshot = try app.model.id(),
            .board_id = document.board_id,
            .physical_layout = document.physical_layout,
            .geometry = board.entry.geometry,
            .labels = &app.captions.labels,
            .board_name = try keyboardName(board),
            .fidelity = try std.fmt.allocPrint(app.window.arena(), "Key placement: {s}", .{board.entry.fidelity.note()}),
        },
        .host = &app.captions.host,
        .paths = .{
            .exported = app.exported,
            .can_choose = app.frame_limit == null and !dialog.active(),
            .busy = app.jobs.busy(),
            .keyboard = try keyboardName(board),
        },
    });
}

/// The keyboard and its PCB revision, such as "Leonardo Keycaprio · PCB 0.7 (LK7)".
fn keyboardName(board: *const boards.OwnedBoard) ![]const u8 {
    const display = board.entry.display;
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} · PCB {s}", .{ display.name, display.revision });
}

fn toolbarFrame(app: *App, board: *const boards.OwnedBoard, can_build: bool, now_us: u64) !Toolbar {
    const flash = &app.flash;
    const build_job = app.jobs.build;
    return .{
        .keyboard_name = board.entry.display.name,
        .connection = connectionLabel(app),
        .layouts = (try layoutChoices(app, board, dvui.currentWindow().arena())).choices,
        .save = saveState(app),
        .can_build = can_build,
        .can_flash = app.build.tools != null and app.build.plan != null and can_build and app.frame_limit == null,
        .flash_active = flash.active(),
        .build_active = build_job != null,
        .first_build = if (build_job) |job| job.first_build else false,
        .flash_succeeded = flash.phase() == .ready,
        .flash_failed = flash.failed(),
        .now_ms = now_us / 1000,
        .flash_status = try flash.toolbarStatus(dvui.currentWindow().arena(), build_job != null, now_us / 1000),
        .build_status = try buildStatus(app),
    };
}

fn saveState(app: *const App) @FieldType(Toolbar, "save") {
    if (!commands.autosaves(app)) return if (app.model.dirty()) .manual else .saved;
    if (app.view.autosave.failed) return .failed;
    if (app.jobs.file) |job| if (job.action.kind == .save) return .saving;
    return if (app.unsavedChanges()) .pending else .saved;
}

pub const Choices = struct { choices: []const Choice, paths: []const []const u8 };

/// The layouts of the open keyboard for the layout menu, with their project
/// paths. The open layout is always listed, even outside the library.
pub fn layoutChoices(app: *App, board: *const boards.OwnedBoard, arena: std.mem.Allocator) !Choices {
    const current_path = std.mem.sliceTo(&app.view.paths.project, 0);
    var choices: std.ArrayList(Choice) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    const now = std.Io.Timestamp.now(app.io, .real).nanoseconds;
    const running = runningIdentity(app);
    var listed_current = false;
    if (app.onboarding.library) |*library| if (library.keyboardFor(board.entry)) |index| {
        for (library.keyboards[index].layouts) |layout_index| {
            const layout = library.layouts[layout_index];
            const current = app.onboarding.selected and std.mem.eql(u8, layout.path, current_path);
            listed_current = listed_current or current;
            var buffer: [64]u8 = undefined;
            const detail = if (layout.member == null) "outside collection" else try arena.dupe(u8, desktop.library.age(&buffer, now, layout.modified));
            try choices.append(arena, .{
                .name = if (current) app.model.document().name else layout.name,
                .detail = detail,
                .current = current,
                .running = if (running) |identity| std.mem.eql(u8, &identity.board_id, &layout.board_id) and
                    std.mem.eql(u8, &identity.profile_id, &layout.profile_id) else false,
            });
            try paths.append(arena, layout.path);
        }
    };
    if (!listed_current) {
        try choices.insert(arena, 0, .{ .name = app.model.document().name, .current = true });
        try paths.insert(arena, 0, current_path);
    }
    return .{ .choices = choices.items, .paths = paths.items };
}

/// The identity of the layout verified on the connected keyboard.
fn runningIdentity(app: *const App) @FieldType(@TypeOf(app.live), "identity") {
    if (app.live.status() != .live) return null;
    return app.live.identity;
}

fn connectionLabel(app: *const App) []const u8 {
    if (app.live.driver) |*driver| if (driver.status == .multiple_devices) return "Multiple keyboards: ambiguous";
    return switch (app.live.status()) {
        .offline => "Offline editor",
        .connecting => "Keyboard connecting",
        .live => "Keyboard connected",
        .stale => "Keyboard state stale",
        .disconnected => "Keyboard disconnected",
        .incompatible => "Keyboard layout mismatch",
    };
}

fn buildStatus(app: *App) ![]const u8 {
    if (app.jobs.build) |job| return if (job.first_build)
        "First build: this can take a few minutes. Later builds are faster."
    else
        "Building";
    if (app.build.artifact) |artifact| return if (std.mem.eql(u8, &artifact.inputs.project_digest, &(try app.model.id())))
        "Built snapshot"
    else
        "Build outdated";
    if (app.build.plan != null) return "Ready to build and Flash";
    return "Application bundle is missing build resources";
}
