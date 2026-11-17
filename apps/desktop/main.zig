//! Native editor/companion startup monitors HID by default. Explicit offline
//! modes and fixtures avoid devices; flashing remains explicit.
const std = @import("std");
const flash_session = @import("flash_session.zig");
const bundled = @import("desktop-core").application_bundle;
const bootloader = @import("flash_bootloader.zig");
const flash_ui = @import("flash-ui");
const jobs_api = @import("companion-jobs");
const dvui = @import("dvui");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const project = @import("project");
const boards = @import("catalog-project");
const editor = @import("editor-frame-ui");
const keyboard_onboarding = @import("onboarding-ui");
const paths = @import("paths-ui");
const callbacks = @import("callback-ui");
const dialog = @import("folder-dialog");
const Source = @import("input-source").Source;
const installed = @import("app-paths");
const tutor = @import("practice-ui");
const ui = @import("editor-ui");
const tray_backend = @import("native-tray");
const companion_ui = @import("companion-ui");
const zkeymap = @import("zkeymap");
const LiveDriver = @import("live-adapter").Driver(@import("native-hid").Native(Backend.c));
const Fixture = struct {
    alternate: bool = false,
    pub fn keyToText(self: *@This(), input: zkeymap.KeyCodeFire) zkeymap.TextResult {
        var result: zkeymap.TextResult = .{};
        if (input.tap_keycode >= 4 and input.tap_keycode <= 29) {
            result.data[0] = (if (self.alternate or input.tap_modifiers.toByte() & 0x22 != 0) @as(u8, 'A') else @as(u8, 'a')) + input.tap_keycode - 4;
            result.len = 1;
        }
        if (result.len == 0) {
            const shifted = input.tap_modifiers.toByte() & 0x22 != 0;
            if (input.tap_keycode >= 30 and input.tap_keycode <= 39) {
                result.data[0] = (if (shifted) "!@#$%^&*()" else "1234567890")[input.tap_keycode - 30];
                result.len = 1;
            } else {
                const value: u8 = switch (input.tap_keycode) {
                    40 => '\n',
                    43 => '\t',
                    44 => ' ',
                    45 => if (shifted) '_' else '-',
                    46 => if (shifted) '+' else '=',
                    47 => if (shifted) '{' else '[',
                    48 => if (shifted) '}' else ']',
                    49 => if (shifted) '|' else '\\',
                    51 => if (shifted) ':' else ';',
                    52 => if (shifted) '"' else '\'',
                    53 => if (shifted) '~' else '`',
                    54 => if (shifted) '<' else ',',
                    55 => if (shifted) '>' else '.',
                    56 => if (shifted) '?' else '/',
                    else => 0,
                };
                if (value != 0) {
                    result.data[0] = value;
                    result.len = 1;
                }
            }
        }
        return result;
    }
};
const Events = struct {
    io: std.Io,
    root: u32,
    close: bool = false,
    quit: bool = false,
    lost_focus: bool = false,
    draft: ?*desktop.runner_runtime.Runtime = null,
    practice: ?*desktop.practice_controller.Controller = null,
    model: ?*desktop.model.Model = null,
    view: ?*editor.View = null,
    now_us: u64 = 0,
    times: [512]desktop.practice_timing.EventTime = undefined,
    time_count: usize = 0,
    fn timestamp(self: *Events, event: Backend.c.SDL_Event) u64 {
        const now: u64 = @intCast(@max(0, std.Io.Clock.awake.now(self.io).toNanoseconds()) / 1000);
        const age = Backend.c.SDL_GetTicksNS() -| event.common.timestamp;
        return now -| (age / 1000);
    }
    pub fn forwarded(self: *Events, event: Backend.c.SDL_Event, added: []const dvui.Event) void {
        if (@import("native-events").windowId(event) != self.root or event.common.timestamp == 0) return;
        const at = self.timestamp(event);
        for (added) |item| {
            if (item.evt != .text and item.evt != .key) continue;
            if (self.time_count == self.times.len) break;
            self.times[self.time_count] = .{ .number = item.num, .now_us = at };
            self.time_count += 1;
        }
    }
    pub fn raw(self: *Events, event: Backend.c.SDL_Event) !bool {
        if (event.type == Backend.c.SDL_EVENT_QUIT) {
            self.quit = true;
            return true;
        }
        if (event.type == Backend.c.SDL_EVENT_WINDOW_CLOSE_REQUESTED and event.window.windowID == self.root) {
            self.close = true;
            return true;
        }
        if (event.type == Backend.c.SDL_EVENT_WINDOW_FOCUS_LOST and event.window.windowID == self.root) self.lost_focus = true;
        if (self.draft) |runtime| if (self.practice) |practice| if (self.model) |model| if (@import("native-draft-input").convert(&event)) |converted| {
            const at = if (event.common.timestamp != 0) self.timestamp(event) else self.now_us;
            const consumed = runtime.route(practice, model, converted, at) catch |err| failed: {
                runtime.fail(practice, err, self.now_us);
                if (self.view) |view| view.report(err);
                break :failed false;
            };
            if (consumed) return true;
        };
        return false;
    }
};
const Captions = struct {
    labels: desktop.label_cache.LabelCache,
    host: desktop.host_palette.Cache,
    snapshot: [32]u8,
    revision: u64,
    fn init(gpa: std.mem.Allocator, model: *const desktop.model.Model, translator: anytype, identity: []const u8, revision: u64) !Captions {
        var labels = try desktop.label_cache.buildProjectCache(gpa, translator, model.document());
        errdefer labels.deinit();
        var host = try desktop.host_palette.Cache.init(gpa, desktop.labels.running_host, identity, revision, translator);
        errdefer host.deinit();
        return .{ .labels = labels, .host = host, .snapshot = try model.id(), .revision = revision };
    }
    fn deinit(self: *Captions) void {
        self.labels.deinit();
        self.host.deinit();
    }
};
const PracticeSnapshot = struct {
    model: desktop.model.Model,
    captions: Captions,
    board: boards.OwnedBoard,
    generation: u64,
    control: [32]u8,
    live: bool,
    fn init(gpa: std.mem.Allocator, selected: *const desktop.model.Model, translator: anytype, identity: []const u8, revision: u64, generation: u64, control: [32]u8, is_live: bool) !PracticeSnapshot {
        var frozen = try desktop.model.Model.init(gpa, selected.board, selected.current.snapshot);
        errdefer frozen.deinit();
        var captions = try Captions.init(gpa, &frozen, translator, identity, revision);
        errdefer captions.deinit();
        return .{ .model = frozen, .captions = captions, .board = try boards.OwnedBoard.fromDocument(gpa, frozen.document()), .generation = generation, .control = control, .live = is_live };
    }
    fn deinit(self: *PracticeSnapshot) void {
        self.board.deinit();
        self.captions.deinit();
        self.model.deinit();
    }
};
// Build both caches before replacing either one. A source change must never
// relabel the verified running project with an unsaved editor draft.
fn refreshRunningCaptions(gpa: std.mem.Allocator, captions: *Captions, running: *const desktop.model.Model, translator: anytype, identity: []const u8, revision: u64) !void {
    if (captions.revision == revision) return;
    const replacement = try Captions.init(gpa, running, translator, identity, revision);
    captions.deinit();
    captions.* = replacement;
}

// Read the selected saved project independently of the mutable editor. Build
// every replacement before releasing the accepted running binding.
fn loadSavedRunning(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !desktop.model.Model {
    if (!std.fs.path.isAbsolute(path)) return error.AbsoluteProjectPathRequired;
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer directory.close(io);
    const bytes = try directory.readFileAlloc(io, "project.zon", gpa, .limited(project.Limits.document_bytes));
    defer gpa.free(bytes);
    const document = try project.parse(gpa, bytes, null);
    defer project.deinit(gpa, document);
    var board = try boards.OwnedBoard.fromDocument(gpa, document);
    defer board.deinit();
    var loaded = try project.snapshot.load(gpa, io, directory, board.board);
    defer loaded.deinit();
    return desktop.model.Model.init(gpa, board.board, loaded.snapshot);
}
fn liveStatus(driver: ?*const LiveDriver, frame: desktop.live_keyboard.Frame) desktop.tray_lifecycle.Status {
    const active = driver orelse return .offline;
    if (active.session.phase == .incompatible) return .incompatible;
    if (!active.connected) return if (active.status == .searching) .connecting else .disconnected;
    if (frame.labels != null and !frame.stale) return .live;
    return if (active.session.token == 0) .connecting else .stale;
}
fn resetLivePresentation(presenter: *desktop.live_keyboard.Presenter, visibility: *desktop.live_keyboard.Visibility, frame: *desktop.live_keyboard.Frame, pressed: []bool, life: *desktop.tray_lifecycle.Lifecycle) void {
    presenter.invalidate();
    visibility.* = .{ .mode = visibility.mode };
    frame.* = .{};
    @memset(pressed, false);
    life.companion_visible = false;
}

fn captureFile(gpa: std.mem.Allocator, io: std.Io, view: *editor.View, model: *desktop.model.Model, action: paths.Action) !desktop.project_files.Request {
    var selected: ?boards.OwnedBoard = null;
    defer if (selected) |*board| board.deinit();
    if (action.kind == .open or action.kind == .open_discard) {
        try paths.validate(action, view.paths, model);
        var directory = try std.Io.Dir.cwd().openDir(io, std.mem.sliceTo(&action.project, 0), .{});
        defer directory.close(io);
        const bytes = try directory.readFileAlloc(io, "project.zon", gpa, .limited(project.Limits.document_bytes));
        defer gpa.free(bytes);
        const document = try project.parse(gpa, bytes, null);
        defer project.deinit(gpa, document);
        selected = try boards.OwnedBoard.fromDocument(gpa, document);
    }
    return paths.request(action, view.paths, model, if (selected) |board| board.board else null);
}
fn fileOperation(gpa: std.mem.Allocator, io: std.Io, view: *editor.View, model: *desktop.model.Model, action: paths.Action) !?[32]u8 {
    var request = try captureFile(gpa, io, view, model, action);
    defer request.deinit();
    var prepared = try request.prepare(gpa, io);
    defer prepared.deinit();
    _ = try prepared.promote(model);
    return prepared.exported;
}
const FileJob = struct {
    worker: *desktop.project_worker.Owner,
    action: paths.Action,
    editor_generation: u64,
    close: ?desktop.editor_dispatch.Request = null,
};
const SourceJob = struct { worker: *desktop.source_worker.Owner, action: callbacks.Action, editor_generation: u64 };
const ProfileJob = struct { worker: *desktop.profile_switch.Worker, action: desktop.editor_dispatch.Request, editor_generation: u64, previous_path: [4096]u8 };
const BuildJob = struct { worker: *desktop.build_worker.Owner, editor_generation: u64, first_build: bool };
const Jobs = struct {
    file: ?FileJob = null,
    source: ?SourceJob = null,
    profile: ?ProfileJob = null,
    build: ?BuildJob = null,
    runner: ?BuildJob = null,
    fn busy(self: *const Jobs) bool {
        return self.file != null or self.source != null or self.profile != null or self.build != null or self.runner != null;
    }
    fn cancel(self: *Jobs) void {
        if (self.file) |job| job.worker.destroy();
        if (self.source) |job| job.worker.destroy();
        if (self.profile) |job| job.worker.destroy();
        if (self.build) |job| job.worker.destroy();
        if (self.runner) |job| job.worker.destroy();
        self.* = .{};
    }
};
fn startFile(gpa: std.mem.Allocator, io: std.Io, view: *editor.View, model: *desktop.model.Model, action: paths.Action, generation: u64, editor_generation: u64) !FileJob {
    var request = try captureFile(gpa, io, view, model, action);
    errdefer request.deinit();
    return .{ .worker = try desktop.project_worker.Owner.create(gpa, io, &request, generation), .action = action, .editor_generation = editor_generation };
}
fn artifactMatchesBundle(artifact: anytype) bool {
    return artifact.audit_mode == jobs_api.firmware.AuditMode.bundled;
}
fn startBuild(gpa: std.mem.Allocator, io: std.Io, model: *const desktop.model.Model, config: desktop.build_worker.Config, environment: *const std.process.Environ.Map, generation: u64, editor_generation: u64) !BuildJob {
    var request = try desktop.build_worker.Request.capture(model, config, environment, generation);
    errdefer request.deinit();
    const first_build = jobs_api.managed_build.isFirstBuild(gpa, io, config.request);
    return .{ .worker = try desktop.build_worker.Owner.create(gpa, io, &request, generation), .editor_generation = editor_generation, .first_build = first_build };
}
fn applyPractice(runtime: *desktop.runner_runtime.Runtime, practice: *desktop.practice_controller.Controller, effect: desktop.practice_controller.Effect, runner: ?desktop.build_worker.Runner, model: *const desktop.model.Model, view: *editor.View, now_us: u64) void {
    runtime.apply(practice, effect, runner, model, now_us) catch |err| {
        runtime.fail(practice, err, now_us);
        view.report(err);
    };
}
fn captureSource(view: *editor.View, model: *desktop.model.Model, action: callbacks.Action) !desktop.source_worker.Request {
    try callbacks.validate(action, view.callback, model);
    const path = std.mem.sliceTo(&action.root, 0);
    if (action.kind == .checkout) return desktop.source_worker.Request.captureCheckout(model, path, action.index);
    var request = try callbacks.request(action, view.callback, model);
    errdefer request.deinit();
    return desktop.source_worker.Request.prepareCallback(&request, path);
}
fn installedPaths(init: std.process.Init) !installed.OwnedPaths {
    const executable = try std.process.executablePathAlloc(init.io, init.gpa);
    defer init.gpa.free(executable);
    return installed.resolve(init.gpa, .{
        .platform = switch (@import("builtin").os.tag) {
            .macos => .macos,
            .windows => .windows,
            .linux => .linux,
            else => return error.UnsupportedPlatform,
        },
        .executable_path = executable,
        .env = .{ .home = init.environ_map.get("HOME"), .appdata = init.environ_map.get("APPDATA"), .localappdata = init.environ_map.get("LOCALAPPDATA"), .xdg_config_home = init.environ_map.get("XDG_CONFIG_HOME"), .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"), .xdg_cache_home = init.environ_map.get("XDG_CACHE_HOME") },
    });
}
fn remember(gpa: std.mem.Allocator, io: std.Io, user_paths: installed.Paths, view: *editor.View, model: *const desktop.model.Model) !void {
    var config = try std.Io.Dir.cwd().createDirPathOpen(io, user_paths.config, .{});
    defer config.close(io);
    try desktop.startup_project.save(gpa, io, config, std.mem.sliceTo(&view.paths.project, 0));
    var registry = try desktop.profile_projects.Registry.load(gpa, io, config, null);
    defer registry.deinit();
    try registry.set(.{ .board_id = model.document().board_id, .profile_id = model.document().profile_id }, std.mem.sliceTo(&view.paths.project, 0));
    try registry.save(io, config);
}
/// Route both toolbar clicks and offline state-machine tests through the same
/// captured editor request. This only authorizes an intent; it never starts a
/// build, discovers a device, or transfers firmware.
pub fn dispatchFlash(owner: *desktop.editor_dispatch.State, model: *desktop.model.Model) !desktop.editor_dispatch.Effect {
    return owner.request(model, try desktop.editor_dispatch.Request.capture(model, .flash));
}
pub fn acceptFlashEffect(model: *const desktop.model.Model, captured: desktop.editor_dispatch.Request) !void {
    if (captured.intent != .flash) return error.NotFlashRequest;
    try captured.validate(model);
}
fn flashSnapshot(session: *const flash_session.Session, rendered: desktop.flash_presenter.View, generation: u64) bootloader.Snapshot {
    return .{
        .operation = rendered.operation_id,
        .model_generation = generation,
        .board_id = session.request.config.board_id,
        .build_key = session.owner.current.build_key,
        .artifact_hash = rendered.uf2_hash orelse @splat(0),
        .selection_revision = rendered.selection_revision,
        .selected_target = if (session.owner.selected) |selection| if (selection == .unique_bootsel) @as(u64, 1) else 0 else 0,
    };
}
// A HID BOOTSEL request requires a coherent running binding on the artifact's
// board; the selected project's profile and digest may differ from firmware.
fn flashLiveMatches(driver: *const LiveDriver, running: ?@TypeOf(@as(LiveDriver, undefined).session.expected), selected: @TypeOf(@as(LiveDriver, undefined).session.expected), artifact_board: [8]u8) bool {
    const expected = running orelse return false;
    return driver.connected and driver.session.token != 0 and driver.session.hasCoherentState() and
        std.meta.eql(driver.session.expected, expected) and
        std.mem.eql(u8, &expected.board_id, &artifact_board) and
        std.mem.eql(u8, &selected.board_id, &artifact_board);
}
fn bootloaderStatus(status: @TypeOf(@as(LiveDriver, undefined).session.bootloader_status)) bootloader.Session.Status {
    return switch (status) {
        .idle => .idle,
        .requested => .requested,
        .accepted => .accepted,
        .rejected => .rejected,
        .timed_out => .timed_out,
        .disconnected => .disconnected,
    };
}
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const onboarding_fixture = args.len == 3 and std.mem.eql(u8, args[1], "--offline-onboarding-frames");
    const catalog_fixture = args.len == 3 and std.mem.eql(u8, args[1], "--offline-catalog-frames");
    var frame_limit: ?usize = null;
    const physical_flash = args.len > 1 and std.mem.eql(u8, args[1], "--physical-flash-once");
    if (physical_flash) {
        if (args.len != 2 or !std.mem.eql(u8, init.environ_map.get("ZIGMKAY_EXPLICIT_FLASH_TRIAL") orelse "", "1")) return error.ExplicitFlashAuthorizationRequired;
    }
    const background_offline = args.len == 2 and std.mem.eql(u8, args[1], "--background-offline");
    const offline = background_offline or (args.len == 2 and std.mem.eql(u8, args[1], "--offline"));
    const background = background_offline or (args.len == 2 and std.mem.eql(u8, args[1], "--background"));
    const live_hold = (args.len == 2 or args.len == 3) and std.mem.eql(u8, args[1], "--live-hold");
    const live_toggle = (args.len == 2 or args.len == 3) and std.mem.eql(u8, args[1], "--live-toggle");
    const live_tap_hold = (args.len == 2 or args.len == 3) and std.mem.eql(u8, args[1], "--live");
    const explicit_live = live_hold or live_toggle or live_tap_hold;
    const preview_tutor = args.len == 2 and std.mem.eql(u8, args[1], "--light-tutor");
    const preview_companion = args.len == 2 and std.mem.eql(u8, args[1], "--light-companion");
    const light = args.len == 2 and (std.mem.eql(u8, args[1], "--light") or preview_tutor or preview_companion);
    var practice_fixture = false;
    var rundown_fixture = false;
    const layout_preview = args.len == 3 and std.mem.startsWith(u8, args[1], "--native-layout-");
    const preview_name = if (layout_preview) args[1]["--native-layout-".len..] else if (args.len == 3 and std.mem.startsWith(u8, args[1], "--native-")) args[1]["--native-".len..] else "";
    const data_preview = std.mem.eql(u8, preview_name, "data-frames");
    const progress_preview = std.mem.eql(u8, preview_name, "progress-frames");
    const diagnostics_preview = std.mem.eql(u8, preview_name, "diagnostics-frames");
    const curriculum_preview = std.mem.eql(u8, preview_name, "curriculum-frames");
    const help_preview = std.mem.eql(u8, preview_name, "help-frames");
    const rundown_preview = std.mem.eql(u8, preview_name, "rundown-frames");
    const native_rundown = data_preview or progress_preview or diagnostics_preview or curriculum_preview or help_preview or rundown_preview;
    var draft_fixture = false;
    var build_fixture = false;
    var companion_fixture = false;
    var native_tray_fixture = false;
    var source_refresh_fixture = false;
    const native_status_fixture = args.len == 3 and std.mem.eql(u8, args[1], "--native-status-frames");
    const status_fixture = native_status_fixture or (args.len == 3 and std.mem.eql(u8, args[1], "--offline-status-frames"));
    var draft_manifest: ?[]const u8 = null;
    var build_plan: ?desktop.build_worker.Plan = null;
    defer if (build_plan) |plan| project.owned_zon.free(gpa, plan);
    if (args.len != 1 and !background and !offline and !light and !explicit_live and !physical_flash) {
        draft_fixture = std.mem.eql(u8, args[1], "--offline-draft-frames");
        build_fixture = std.mem.eql(u8, args[1], "--offline-build-frames");
        if (args.len != (if (draft_fixture) @as(usize, 4) else 3)) return error.Usage;
        practice_fixture = std.mem.eql(u8, args[1], "--offline-practice-frames");
        rundown_fixture = native_rundown or std.mem.eql(u8, args[1], "--offline-rundown-frames");
        companion_fixture = std.mem.eql(u8, args[1], "--offline-companion-frames");
        native_tray_fixture = std.mem.eql(u8, args[1], "--native-tray-frames");
        source_refresh_fixture = std.mem.eql(u8, args[1], "--offline-source-refresh-frames");
        if (!onboarding_fixture and !catalog_fixture and !rundown_fixture and !practice_fixture and !draft_fixture and !build_fixture and !companion_fixture and !native_tray_fixture and !source_refresh_fixture and !status_fixture and !std.mem.eql(u8, args[1], "--offline-frames")) return error.Usage;
        frame_limit = try std.fmt.parseInt(usize, args[2], 10);
        const minimum_frames: usize = if (rundown_fixture) 20 else if (companion_fixture) 9 else if (practice_fixture or native_tray_fixture or source_refresh_fixture) 3 else if (build_fixture) 2 else 1;
        const maximum_frames: usize = if (build_fixture) 30_000 else if (draft_fixture) 1000 else if (layout_preview) 200 else 100;
        if (frame_limit.? < minimum_frames or frame_limit.? > maximum_frames) return error.InvalidFrameLimit;
        if (draft_fixture) {
            if (!std.fs.path.isAbsolute(args[3])) return error.AbsoluteRunnerManifestRequired;
            draft_manifest = args[3];
        }
        if (native_tray_fixture or native_rundown or native_status_fixture) {
            if (std.c.getenv("SDL_VIDEODRIVER")) |driver| if (std.mem.eql(u8, std.mem.span(driver), "dummy")) return error.NativeVideoRequired;
        } else {
            const driver = std.c.getenv("SDL_VIDEODRIVER") orelse return error.DummyVideoRequired;
            if (!std.mem.eql(u8, std.mem.span(driver), "dummy")) return error.DummyVideoRequired;
        }
    }
    const live_enabled = explicit_live or (!offline and !light and frame_limit == null);
    if (frame_limit != null and live_enabled) return error.OfflineFixtureOpenedLiveMode;
    std.log.info("Keyboard monitoring: {s}", .{if (live_enabled) "enabled" else "offline"});
    var template = try project.profiles.create(gpa, if (draft_fixture) .eurkey else .qwerty);
    defer template.deinit();
    var model = try desktop.model.Model.init(gpa, project.profiles.board, template.snapshot);
    defer model.deinit();
    if (rundown_fixture) try @import("practice_fixture.zig").install(&model);
    if (help_preview) {
        const previous_layer = model.layer;
        model.layer = 0;
        model.select(16, false);
        try model.apply(.{ .tap_hold = .{ .tap = .{ .key_press = .{ .tap_keycode = 13 } }, .hold = .{ .hold_modifiers = .{ .right_shift = true } }, .tapping_term = .{ .ms = 180 } } });
        model.layer = previous_layer;
        model.saved_id = try model.id();
    }
    var owner = try desktop.editor_dispatch.State.init(&model);
    defer owner.deinit();
    var view: editor.View = .{};
    var onboarding: keyboard_onboarding.State = .{ .active = onboarding_fixture or (frame_limit == null and !preview_tutor and !preview_companion), .selected = !onboarding_fixture and (frame_limit != null or preview_tutor or preview_companion) };
    defer onboarding.deinit();
    if (onboarding_fixture) {
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", gpa);
        defer gpa.free(cwd);
        const root = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache/onboarding-uncreated/My Keyboards" });
        defer gpa.free(root);
        try onboarding.defaults(root);
    }
    view.toolbar.light = light;
    var registry = desktop.profile_projects.Registry.init(gpa);
    defer registry.deinit();
    var user_paths: ?installed.OwnedPaths = null;
    defer if (user_paths) |*owned| owned.deinit();
    if (frame_limit == null or build_fixture) {
        user_paths = installedPaths(init) catch |err| unavailable: {
            if (build_fixture) {
                std.log.err("Managed editor startup path resolution failed: {s}", .{@errorName(err)});
                return err;
            }
            view.report(err);
            break :unavailable null;
        };
        if (user_paths) |owned| {
            const default_path = try std.fs.path.join(gpa, &.{ owned.paths.projects, "My Keyboards" });
            defer gpa.free(default_path);
            try onboarding.defaults(default_path);
            if (default_path.len >= view.paths.project.len) return error.InvalidProjectPath;
            @memcpy(view.paths.project[0..default_path.len], default_path);
            const export_path = try std.fs.path.join(gpa, &.{ owned.paths.builds, "export" });
            defer gpa.free(export_path);
            if (export_path.len >= view.paths.exported.len) return error.InvalidProjectPath;
            @memcpy(view.paths.exported[0..export_path.len], export_path);
            // Startup reads existing preferences only; missing/corrupt/future data
            // never triggers a default preference or project write.
            const config = std.Io.Dir.cwd().openDir(init.io, owned.paths.config, .{}) catch |err| unavailable: {
                if (err != error.FileNotFound) view.report(err);
                break :unavailable null;
            };
            if (config) |directory| {
                defer directory.close(init.io);
                const associated = desktop.profile_projects.Registry.load(gpa, init.io, directory, null) catch |err| unavailable: {
                    view.report(err);
                    break :unavailable null;
                };
                if (associated) |loaded_registry| {
                    registry.deinit();
                    registry = loaded_registry;
                }
                const remembered = desktop.startup_project.load(gpa, init.io, directory) catch |err| unavailable: {
                    view.report(err);
                    break :unavailable null;
                };
                if (remembered) |path| {
                    defer gpa.free(path);
                    view.paths.project = @splat(0);
                    @memcpy(view.paths.project[0..path.len], path);
                    if (fileOperation(gpa, init.io, &view, &model, view.paths.action(try model.id(), .open))) |_| {
                        onboarding.active = false;
                        onboarding.selected = true;
                        // Legacy preferences contain a child project path. Recover
                        // portable collection navigation when it is a member.
                        if (std.fs.path.dirname(path)) |parent| if (std.fs.path.dirname(parent)) |root| {
                            try keyboard_onboarding.State.set(&onboarding.root, root);
                            onboarding.reloadCollection(gpa, init.io) catch |err| onboarding.report(err);
                            if (onboarding.collection == null) try keyboard_onboarding.State.set(&onboarding.root, default_path);
                        };
                    } else |err| {
                        view.report(err);
                        onboarding.report(err);
                        try keyboard_onboarding.State.set(&onboarding.location, path);
                    }
                    try owner.sync(&model);
                }
            }
        }
    }
    if (explicit_live and args.len == 3) {
        if (!std.fs.path.isAbsolute(args[2]) or args[2].len >= view.paths.project.len) return error.AbsoluteProjectPathRequired;
        view.paths.project = @splat(0);
        @memcpy(view.paths.project[0..args[2].len], args[2]);
        _ = try fileOperation(gpa, init.io, &view, &model, view.paths.action(try model.id(), .open));
        onboarding.active = false;
        onboarding.selected = true;
        try owner.sync(&model);
    }
    var source: ?Source = if (frame_limit == null) Source.init() else null;
    defer if (source) |*active| active.deinit();
    var fixture: Fixture = .{};
    var revision: u64 = 1;
    var captions = if (source) |*active| try Captions.init(gpa, &model, active, active.id(), revision) else try Captions.init(gpa, &model, &fixture, "Offline launch fixture", revision);
    defer captions.deinit();
    var native = try Backend.initWindow(.{ .io = init.io, .size = if (frame_limit != null) .{ .w = 1536, .h = 1024 } else .{ .w = desktop.geometry.initial.w, .h = desktop.geometry.initial.h }, .min_size = .{ .w = desktop.geometry.minimum.w, .h = desktop.geometry.minimum.h }, .title = "Zigmkay Editor", .vsync = true, .hidden = frame_limit != null or background, .persist_window_geometry = false });
    defer native.deinit();
    var window = try dvui.Window.init(@src(), gpa, native.backend(), .{});
    defer window.deinit();
    var tray = tray_backend.NativeTray.init(.{ .allocator = gpa }, frame_limit == null or native_tray_fixture);
    defer tray.deinit();
    if (native_tray_fixture and !tray.installed) return error.NativeTrayUnavailable;
    if (background and !tray.installed) return error.BackgroundTrayUnavailable;
    var life = desktop.tray_lifecycle.Lifecycle{ .resident = tray.installed or companion_fixture, .editor_visible = !background, .companion_visible = preview_companion };
    var companion_window: ?u32 = null;
    var companion_view: companion_ui.View = .{};
    // Freeze the startup project independently of all later editor mutations.
    var running_model = try desktop.model.Model.init(gpa, model.board, model.current.snapshot);
    defer running_model.deinit();
    var running_captions = if (source) |*active| try Captions.init(gpa, &running_model, active, active.id(), revision) else try Captions.init(gpa, &running_model, &fixture, "Offline live fixture", revision);
    defer running_captions.deinit();
    var running_board = try boards.OwnedBoard.fromDocument(gpa, running_model.document());
    defer running_board.deinit();
    var running_identity = if (live_enabled and onboarding.selected) try project.snapshot.identity(gpa, running_model.current.snapshot, running_model.board) else null;
    var seed: u32 = 0;
    if (live_enabled) try std.Io.randomSecure(init.io, std.mem.asBytes(&seed));
    var live: ?LiveDriver = if (running_identity) |identity| try LiveDriver.init(.{ .io = init.io }, identity, seed, null) else null;
    defer if (live) |*driver| driver.disconnect(driver.transport.now());
    var presenter = desktop.live_keyboard.Presenter{};
    var visibility = desktop.live_keyboard.Visibility{ .mode = if (live_hold) .hold else if (live_toggle) .toggle else .tap_hold };
    var live_pressed: [128]bool = @splat(false);
    var live_frame = desktop.live_keyboard.Frame{};
    var last_live_status: ?desktop.tray_lifecycle.Status = null;
    var retained_fixture: ?[32]u8 = null;
    var events = Events{ .io = init.io, .root = Backend.c.SDL_GetWindowID(native.window) };
    var chooser: desktop.folder_selection.State = .{};
    var exported: ?[32]u8 = null;
    var count: usize = 0;
    var practicing = practice_fixture or rundown_fixture or draft_fixture or preview_tutor;
    var practice = desktop.practice_controller.Controller.init(try model.id());
    var practice_snapshot: ?PracticeSnapshot = null;
    defer if (practice_snapshot) |*value| value.deinit();
    var practice_timing = desktop.practice_timing.Recorder.init(gpa);
    practice_timing.clock = .frame;
    defer practice_timing.deinit();
    practice.session.recorder = &practice_timing;
    if (practice_fixture) _ = try practice.dispatch(practice.action(.{ .start = true }), null, 0);
    var practice_view: tutor.View = .{};
    if (frame_limit == null) try std.Io.randomSecure(init.io, std.mem.asBytes(&practice.seed));
    var practice_history = try desktop.practice_history_runtime.Runtime.init(gpa, init.io, if (user_paths) |owned| owned.paths.data else null);
    defer practice_history.deinit();
    if (data_preview) {
        const root = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", gpa);
        defer gpa.free(root);
        if (practice_history.path) |previous| gpa.free(previous);
        const capture_folder = try std.fmt.allocPrint(gpa, "data-{d}", .{std.Io.Clock.awake.now(init.io).toNanoseconds()});
        defer gpa.free(capture_folder);
        practice_history.path = try std.fs.path.join(gpa, &.{ root, ".zig-cache", "native-data-verification", capture_folder });
    }
    var practice_history_loaded = false;

    var interrupted = false;
    var fonts_installed = false;
    var owner_generation: u64 = 1;
    var job_generation: u64 = 0;
    var jobs: Jobs = .{};
    defer jobs.cancel();
    var flash_tools: ?jobs_api.flash_inputs.Tools = null;
    defer if (flash_tools) |*tools| tools.deinit();
    const executable = try std.process.executablePathAlloc(init.io, gpa);
    defer gpa.free(executable);
    var resources: ?bundled.Bundle = if (user_paths) |owned| (if (@import("builtin").os.tag == .windows) bundled.Bundle.fromExecutable(gpa, init.io, executable, owned.paths.cache) else bundled.Bundle.open(gpa, init.io, owned.paths.resources)) catch |err| unavailable: {
        if (build_fixture) {
            std.log.err("Managed editor startup bundle loading failed: {s}", .{@errorName(err)});
            return err;
        }
        break :unavailable null;
    } else null;
    defer if (resources) |*value| value.deinit();
    if (resources) |value| {
        if (flash_tools == null) flash_tools = try bundled.tools(gpa, value);
    }
    var trial_start: ?i128 = null;
    var flash: ?flash_session.Session = null;
    var flash_panel = false;
    var flash_details_open = false;
    var flash_failure: ?anyerror = null;
    var flash_gate: bootloader.Gate = .{};
    var retained_flash_view: ?desktop.flash_presenter.View = null;
    var pending_flash: ?struct { snapshot: [32]u8, generation: u64 } = null;
    var advance_flash = false;
    var built_generation: u64 = 0;
    var built_tree: jobs_api.firmware.Digest = @splat(0);
    defer if (flash) |*session| session.deinit();
    var built: ?desktop.build_worker.Artifact = null;
    defer if (built) |*artifact| artifact.deinit();
    var built_runner: ?desktop.build_worker.Runner = null;
    defer if (built_runner) |*runner| runner.deinit();
    var draft_runtime = desktop.runner_runtime.Runtime.init(gpa, init.io, events.root, frame_limit != null);
    defer draft_runtime.deinit();
    events.draft = &draft_runtime;
    events.practice = &practice;
    events.model = &model;
    events.view = &view;
    if (draft_manifest) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(32 * 1024));
        defer gpa.free(bytes);
        built_runner = try desktop.build_worker.Runner.parse(gpa, bytes);
        _ = try practice.choose(.{ .source = .draft }, 0);
        const effect = try practice.start(true, built_runner.?.record.inputs.project_digest, 0);
        try practice.session.load("aa", .draft);
        try draft_runtime.apply(&practice, effect, built_runner, &model, 0);
    }
    var draft_phase: enum { starting, input, paused } = .starting;
    var build_checked = false;
    var build_scheduler: desktop.auto_build.Scheduler = .{};
    var accepted_editor_generation = owner_generation;
    var onboarding_chooser_generation: ?u64 = null;
    while (!owner.closed) {
        if (catalog_fixture and count % 4 == 0 and count / 4 < desktop.onboarding.catalog.entries.len) {
            const entry = desktop.onboarding.catalog.entries[count / 4];
            var selected_board = try boards.OwnedBoard.init(gpa, entry.selector);
            defer selected_board.deinit();
            var selected_default = try boards.createDefault(gpa, selected_board);
            defer selected_default.deinit();
            var replacement = try desktop.model.Model.init(gpa, selected_board.board, selected_default.snapshot);
            std.mem.swap(desktop.model.Model, &model, &replacement);
            replacement.deinit();
            owner_generation += 1;
        }
        if (catalog_fixture) practicing = count % 4 >= 2;
        if (onboarding_fixture) {
            if (count == 3) onboarding.stage = .source;
            if (count >= 6 and count < 20) {
                onboarding.stage = .keyboard;
                onboarding.selector = count - 6;
            }
            if (count == 20) {
                var environment = std.process.Environ.Map.init(gpa);
                defer environment.deinit();
                var request = try desktop.onboarding.Request.init(gpa, .{ .operation = .prepare, .selector = desktop.onboarding.catalog.entries[onboarding.selector].selector, .toolchain = .{ .compiler = "", .build_root = "", .cache = "" } }, &environment, @splat(0));
                defer request.deinit();
                const prepared = try request.prepare(gpa, init.io);
                onboarding.prepared = prepared.prepared;
                onboarding.stage = .review;
            }
        }
        if (onboarding.poll(owner_generation) catch |err| failed: {
            onboarding.report(err);
            break :failed null;
        }) |opened_value| {
            var opened = opened_value;
            defer opened.deinit();
            if (opened.model == null) {
                try keyboard_onboarding.State.set(&onboarding.root, opened.collection.?);
                try onboarding.reloadCollection(gpa, init.io);
                onboarding.active = true;
                onboarding.stage = .welcome;
            } else if ((model.dirty() or owner.inspector.dirty() or owner.pending != null) and !onboarding.discard) {
                onboarding.report(error.UnsavedProjectChanges);
            } else {
                jobs.cancel();
                if (built) |*value| value.deinit();
                built = null;
                if (built_runner) |*value| value.deinit();
                built_runner = null;
                pending_flash = null;
                advance_flash = false;
                exported = null;
                view.combo = null;
                view.encoders = null;
                view.modal = .none;
                owner.deinit();
                model.deinit();
                model = opened.model.?;
                opened.model = null;
                owner = try desktop.editor_dispatch.State.init(&model);
                owner_generation = try std.math.add(u64, owner_generation, 1);
                accepted_editor_generation = owner_generation;
                build_scheduler = .{};
                if (practice.active or draft_runtime.owner != null) draft_runtime.fail(&practice, error.PracticeProjectSwitched, 0);
                practicing = false;
                try keyboard_onboarding.State.set(&view.paths.project, opened.path);
                onboarding.selected = true;
                if (opened.collection) |root| try keyboard_onboarding.State.set(&onboarding.root, root);
                try onboarding.reloadCollection(gpa, init.io);
                onboarding.stage = if (onboarding.operation == .create) .created else .welcome;
                onboarding.active = onboarding.operation == .create;
                onboarding.discard = false;
                if (user_paths) |owned| remember(gpa, init.io, owned.paths, &view, &model) catch |err| view.report(err);
                if (live_enabled and live == null) {
                    var replacement = try desktop.model.Model.init(gpa, model.board, model.current.snapshot);
                    defer replacement.deinit();
                    var next_captions = if (source) |*active| try Captions.init(gpa, &replacement, active, active.id(), revision) else try Captions.init(gpa, &replacement, &fixture, "Offline live fixture", revision);
                    defer next_captions.deinit();
                    var next_board = try boards.OwnedBoard.fromDocument(gpa, replacement.document());
                    defer next_board.deinit();
                    running_identity = try project.snapshot.identity(gpa, replacement.current.snapshot, replacement.board);
                    live = try LiveDriver.init(.{ .io = init.io }, running_identity.?, seed, null);
                    std.mem.swap(desktop.model.Model, &running_model, &replacement);
                    std.mem.swap(Captions, &running_captions, &next_captions);
                    std.mem.swap(boards.OwnedBoard, &running_board, &next_board);
                }
            }
        }
        if (physical_flash) if (trial_start) |start| {
            const elapsed = native.nanoTime() - start;
            if (flash) |*session| {
                if (session.owner.phase == .ready) {
                    if (!(try session.matchesModel(&model, built_generation)) or flash_failure != null) return error.PhysicalFlashIdentityMismatch;
                    std.log.info("Physical flash ready in {d} ms", .{@divTrunc(elapsed, std.time.ns_per_ms)});
                    return;
                }
                if (session.owner.phase == .failed or session.owner.phase == .stale or session.owner.phase == .cancelled or session.owner.phase == .reconnect_timeout) {
                    std.log.err("Physical flash terminated after {d} ms: {t}; error={s}; runtime={s}", .{ @divTrunc(elapsed, std.time.ns_per_ms), session.owner.phase, if (flash_failure) |err| @errorName(err) else "none", if (session.runtime.last_error) |err| @errorName(err) else "none" });
                    if (session.completion) |result| if (result.completion) |completed| {
                        std.log.err("Flash wrapper stdout: {s}", .{completed.process.stdout});
                        std.log.err("Flash wrapper stderr: {s}", .{completed.process.stderr});
                    };
                    return error.PhysicalFlashFailed;
                }
            }
            if (flash_failure) |err| {
                std.log.err("Physical flash failed after {d} ms: {s}", .{ @divTrunc(elapsed, std.time.ns_per_ms), @errorName(err) });
                return err;
            }
            if (elapsed >= 120 * std.time.ns_per_s) {
                std.log.err("Physical flash timed out after {d} ms", .{@divTrunc(elapsed, std.time.ns_per_ms)});
                return error.PhysicalFlashTimeout;
            }
        };
        if (live) |*driver| {
            const driver_now = driver.transport.now();
            driver.poll(driver_now);
            live_frame = try presenter.select(&running_captions.labels, running_identity, &driver.session, &live_pressed);
            const status = liveStatus(driver, live_frame);
            if (last_live_status == null or last_live_status.? != status) {
                std.log.info("Keyboard connection: {t}", .{status});
                last_live_status = status;
            }
            life.companion_visible = visibility.updateAt(live_frame, driver.signal_events[0..driver.signal_event_count], driver.transport.now());
            for (driver.signal_events[0..driver.signal_event_count]) |signal| {
                std.log.debug("Live overlay signal {t} pressed={any}; latched={any} held={any} visible={any}", .{ signal.kind, signal.pressed, visibility.latched, visibility.held, life.companion_visible });
            }
            if (!life.companion_visible or (practicing and practice.config.assistance == .hidden)) if (companion_window) |id| if (Backend.c.SDL_GetWindowFromID(id)) |child_window| {
                _ = Backend.c.SDL_HideWindow(child_window);
            };
        }
        if (build_fixture and !build_checked and count >= 2 and jobs.build == null) {
            if (built) |artifact| {
                if (!std.mem.eql(u8, &artifact.inputs.project_digest, &(try model.id()))) return error.ManagedEditorBuildStale;
                const runner = built_runner orelse return error.ManagedEditorRunnerMissing;
                try runner.verifyFile(gpa, init.io, artifact.inputs);
                build_checked = true;
                practicing = true;
                const fixture_now: u64 = @intCast(@max(0, native.nanoTime()) / 1000);
                _ = try practice.choose(.{ .source = .draft }, fixture_now);
                const effect = try practice.start(true, artifact.inputs.project_digest, fixture_now);
                try practice.session.load("aa", .draft);
                try draft_runtime.apply(&practice, effect, built_runner, &model, fixture_now);
            } else {
                std.log.err("Managed editor build failed: {s}", .{std.mem.sliceTo(&view.diagnostic, 0)});
                return error.ManagedEditorBuildFailed;
            }
        }
        const check_draft = draft_fixture or (build_fixture and build_checked);
        if (check_draft and draft_phase == .paused and practice.session.state == .paused and draft_runtime.owner == null) break;
        if (frame_limit) |limit| if (count == limit) break;
        count += 1;
        if (tray.poll()) |action| switch (action) {
            .open_editor => {
                life.action(action);
                _ = Backend.c.SDL_ShowWindow(native.window);
                _ = Backend.c.SDL_RaiseWindow(native.window);
            },
            .toggle_companion => {
                life.action(action);
                if (visibility.mode != .hold and live_frame.labels != null and !live_frame.stale) visibility.latched = life.companion_visible;
            },
            .quit => events.quit = true,
            .bind_saved_project => bind: {
                if (!live_enabled) break :bind;
                if (jobs.busy() or pending_flash != null or flash != null) {
                    view.report(error.ProjectJobInProgress);
                    break :bind;
                }
                var replacement = loadSavedRunning(gpa, init.io, std.mem.sliceTo(&view.paths.project, 0)) catch |err| {
                    view.report(err);
                    break :bind;
                };
                defer replacement.deinit();
                var next_captions = if (source) |*active| Captions.init(gpa, &replacement, active, active.id(), revision) catch |err| {
                    view.report(err);
                    break :bind;
                } else Captions.init(gpa, &replacement, &fixture, "Offline live fixture", revision) catch |err| {
                    view.report(err);
                    break :bind;
                };
                defer next_captions.deinit();
                var next_board = boards.OwnedBoard.fromDocument(gpa, replacement.document()) catch |err| {
                    view.report(err);
                    break :bind;
                };
                defer next_board.deinit();
                const next_identity = project.snapshot.identity(gpa, replacement.current.snapshot, replacement.board) catch |err| {
                    view.report(err);
                    break :bind;
                };
                var next_seed: u32 = 0;
                std.Io.randomSecure(init.io, std.mem.asBytes(&next_seed)) catch |err| {
                    view.report(err);
                    break :bind;
                };
                const next_driver = LiveDriver.init(.{ .io = init.io }, next_identity, next_seed, null) catch |err| {
                    view.report(err);
                    break :bind;
                };
                flash_gate.cancel();
                retained_flash_view = null;
                if (live) |*driver| driver.disconnect(driver.transport.now());
                live = next_driver;
                std.mem.swap(desktop.model.Model, &running_model, &replacement);
                std.mem.swap(Captions, &running_captions, &next_captions);
                std.mem.swap(boards.OwnedBoard, &running_board, &next_board);
                running_identity = next_identity;
                resetLivePresentation(&presenter, &visibility, &live_frame, &live_pressed, &life);
                view.diagnostic = @splat(0);
            },
            .zoom_out, .zoom_in, .zoom_reset => life.action(action),
        };
        life.resident = tray.installed or companion_fixture;
        if (!life.resident and !life.editor_visible and !life.companion_visible) {
            life.editor_visible = true;
            _ = Backend.c.SDL_ShowWindow(native.window);
        }
        if (life.quit_requested and owner.close_requested == null and owner.pending == null and !owner.closed) life.cancelQuit();
        if (onboarding.selected) if (resources) |value| if (user_paths) |owned| {
            if (build_plan == null or !std.mem.eql(u8, &build_plan.?.config.board_id, &model.board.id)) {
                var selected = try boards.OwnedBoard.fromDocument(gpa, model.document());
                defer selected.deinit();
                if (build_plan) |old| project.owned_zon.free(gpa, old);
                build_plan = try bundled.plan(gpa, value, owned.paths.cache, selected.entry.selector, model.board.id);
            }
        };
        if (frame_limit == null and !life.editor_visible and !life.companion_visible and !jobs.busy() and flash == null and pending_flash == null and retained_flash_view == null and draft_runtime.owner == null and practice_history.worker == null and (practice_history.queued == 0 or practice_history.error_value != null)) {
            // An idle resident does not construct editor frames or redraw hidden
            // windows. SDL waits for native events between bounded tray polls.
            tray.update(.{ .live_mode = live_enabled, .status = liveStatus(if (live) |*driver| driver else null, live_frame), .companion_visible = false });
            var event: Backend.c.SDL_Event = undefined;
            while (Backend.c.SDL_PollEvent(&event)) _ = try events.raw(event);
            if (!events.quit and !events.close) {
                interrupted = try native.waitEventTimeout(desktop.live_keyboard.waitBudget(live_enabled, false, true));
                continue;
            }
        }
        if (companion_fixture) switch (count) {
            2 => {
                try model.rename("Retained draft");
                retained_fixture = try model.id();
                life.action(.toggle_companion);
            },
            3 => {
                if (companion_window == null) return error.CompanionWindowMissing;
                events.close = true;
            },
            4 => {
                if (life.editor_visible or owner.closed or !life.keepRunning()) return error.ResidentEditorCloseFailed;
                life.action(.open_editor);
                life.action(.toggle_companion);
                _ = Backend.c.SDL_ShowWindow(native.window);
            },
            5 => {
                if (companion_window) |id| if (Backend.c.SDL_GetWindowFromID(id)) |child_window| {
                    if (Backend.c.SDL_GetWindowFlags(child_window) & Backend.c.SDL_WINDOW_HIDDEN == 0) return error.CompanionNativeHideFailed;
                };
                life.action(.toggle_companion);
                companion_view.overlay = true;
                companion_view.applied_window = null;
            },
            6 => {
                const id = companion_window orelse return error.CompanionWindowMissing;
                const child_window = Backend.c.SDL_GetWindowFromID(id) orelse return error.CompanionWindowMissing;
                if (companion_view.applied_window != id) return error.CompanionModeNotApplied;
                const flags = Backend.c.SDL_GetWindowFlags(child_window);
                if (flags & Backend.c.SDL_WINDOW_HIDDEN != 0) return error.CompanionNativeShowFailed;
                const overlay_flags = Backend.c.SDL_WINDOW_BORDERLESS | Backend.c.SDL_WINDOW_ALWAYS_ON_TOP | Backend.c.SDL_WINDOW_NOT_FOCUSABLE;
                if ((flags & overlay_flags) != (if (companion_view.overlay) overlay_flags else 0)) {
                    std.log.err("Companion mode flags: actual={x} expected={x} overlay={any}", .{ flags & overlay_flags, if (companion_view.overlay) overlay_flags else 0, companion_view.overlay });
                    return error.CompanionModeFlagsMismatch;
                }
                var event: Backend.c.SDL_Event = std.mem.zeroes(Backend.c.SDL_Event);
                event.window.type = Backend.c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
                event.window.windowID = id;
                if (!Backend.c.SDL_PushEvent(&event)) return error.FixtureEventRejected;
            },
            7 => {
                if (life.companion_visible or !life.editor_visible or owner.closed) return error.CompanionCloseFailed;
                events.quit = true;
            },
            8 => {
                if (owner.close_requested == null or owner.closed) return error.ResidentDirtyQuitNotGuarded;
                _ = try owner.inspect(&model, try desktop.inspector_action.Action.capture(&owner.inspector, &model, .keep_close));
                life.cancelQuit();
            },
            9 => {
                if (owner.closed or owner.close_requested != null or life.quit_requested or !life.keepRunning() or !std.mem.eql(u8, &retained_fixture.?, &(try model.id()))) return error.ResidentDraftRetentionFailed;
                // Simulate a clean saved document, then exercise accepted Quit
                // after hide/reopen and cancelled dirty Quit in the same loop.
                model.saved_id = try model.id();
                var quit_event: Backend.c.SDL_Event = std.mem.zeroes(Backend.c.SDL_Event);
                quit_event.type = Backend.c.SDL_EVENT_QUIT;
                if (!Backend.c.SDL_PushEvent(&quit_event)) return error.FixtureEventRejected;
            },
            else => {},
        };
        if (source_refresh_fixture and count == 2) {
            const frozen = try running_model.id();
            const cache_path = try std.fmt.allocPrint(gpa, ".zig-cache/live-binding-{d}", .{native.nanoTime()});
            defer gpa.free(cache_path);
            defer std.Io.Dir.cwd().deleteTree(init.io, cache_path) catch {};
            var saved_directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, cache_path, .{});
            defer saved_directory.close(init.io);
            try project.snapshot.save(gpa, init.io, saved_directory, running_model.current.snapshot, running_model.board);
            var absolute_buffer: [4096]u8 = undefined;
            const absolute_len = try saved_directory.realPath(init.io, &absolute_buffer);
            const saved_path = absolute_buffer[0..absolute_len];
            var letter: ?usize = null;
            for (running_model.document().layers[0].actions, 0..) |action, index| {
                if (action) |value| switch (value) {
                    .tap_only => |tap| {
                        if (tap.key_press) |press| {
                            if (press.tap_keycode >= 4 and press.tap_keycode <= 29 and running_captions.labels.lookup(0, index, .{}).label != null) {
                                letter = index;
                                break;
                            }
                        }
                    },
                    else => {},
                };
            }
            const key = letter orelse return error.NoFixtureLetter;
            const saved_label = try gpa.dupe(u8, running_captions.labels.lookup(0, key, .{}).label.?);
            defer gpa.free(saved_label);
            model.select(key, false);
            try model.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 30 } } });
            try model.rename("Unsaved editor draft");
            if (std.mem.eql(u8, &frozen, &(try model.id()))) return error.EditorFixtureNotChanged;
            var saved_binding = try loadSavedRunning(gpa, init.io, saved_path);
            defer saved_binding.deinit();
            if (!std.mem.eql(u8, &frozen, &(try saved_binding.id())) or
                std.mem.eql(u8, &(try model.id()), &(try saved_binding.id()))) return error.LiveBindingUsedUnsavedDraft;
            // A deliberately saved replacement can be prepared without changing
            // the editor or the still-accepted startup binding.
            try saved_binding.rename("Saved replacement binding");
            saved_binding.select(key, false);
            try saved_binding.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 5 } } });
            try project.snapshot.save(gpa, init.io, saved_directory, saved_binding.current.snapshot, saved_binding.board);
            var replacement_binding = try loadSavedRunning(gpa, init.io, saved_path);
            defer replacement_binding.deinit();
            if (!std.mem.eql(u8, &(try saved_binding.id()), &(try replacement_binding.id())) or
                !std.mem.eql(u8, &frozen, &(try running_model.id()))) return error.LiveReplacementChangedAcceptedBinding;
            const replacement_identity = try project.snapshot.identity(gpa, replacement_binding.current.snapshot, replacement_binding.board);
            var offline_driver = try LiveDriver.init(.{ .io = init.io }, replacement_identity, 123, null);
            if (offline_driver.connected or offline_driver.session.token != 0 or
                !std.meta.eql(replacement_identity, offline_driver.session.expected)) return error.LiveRebindSkippedNegotiation;
            var replacement_captions = try Captions.init(gpa, &replacement_binding, &fixture, "Offline replacement", revision);
            defer replacement_captions.deinit();
            var replacement_presenter = desktop.live_keyboard.Presenter{};
            var replacement_pressed: [128]bool = @splat(false);
            const unverified = try replacement_presenter.select(&replacement_captions.labels, replacement_identity, &offline_driver.session, &replacement_pressed);
            if (unverified.labels != null or !unverified.stale or liveStatus(&offline_driver, unverified) != .connecting) return error.UnverifiedReplacementVisible;
            var old_visibility = desktop.live_keyboard.Visibility{ .mode = .hold, .latched = true, .held = true, .down = true };
            var old_frame = desktop.live_keyboard.Frame{ .labels = &running_captions.labels, .stale = false };
            var old_life = desktop.tray_lifecycle.Lifecycle{ .companion_visible = true };
            replacement_presenter.accepted_identity = replacement_identity;
            @memset(&replacement_pressed, true);
            resetLivePresentation(&replacement_presenter, &old_visibility, &old_frame, &replacement_pressed, &old_life);
            if (replacement_presenter.accepted_identity != null or old_visibility.held or old_visibility.latched or old_visibility.down or
                old_visibility.mode != .hold or old_frame.labels != null or old_life.companion_visible or
                std.mem.indexOfScalar(bool, &replacement_pressed, true) != null) return error.LiveRebindRetainedOldPresentation;
            const accepted_entries = running_captions.labels.entries.ptr;
            try saved_directory.writeFile(init.io, .{ .sub_path = "project.zon", .data = "not a project" });
            if (loadSavedRunning(gpa, init.io, saved_path)) |loaded_value| {
                var unexpected = loaded_value;
                unexpected.deinit();
                return error.InvalidSavedBindingAccepted;
            } else |_| {}
            if (!std.mem.eql(u8, &frozen, &(try running_model.id())) or running_captions.labels.entries.ptr != accepted_entries) return error.FailedBindingDiscardedAcceptedProject;
            const old_entries = running_captions.labels.entries.ptr;
            try refreshRunningCaptions(gpa, &running_captions, &running_model, &fixture, "Offline live fixture", revision);
            if (running_captions.labels.entries.ptr != old_entries) return error.SameRevisionRebuiltCaptions;
            var empty_storage: [0]u8 = .{};
            var failing: std.heap.FixedBufferAllocator = .init(&empty_storage);
            if (refreshRunningCaptions(failing.allocator(), &running_captions, &running_model, &fixture, "Offline live fixture", revision + 1)) |_| {
                return error.FailedAllocationUnexpectedlySucceeded;
            } else |err| if (err != error.OutOfMemory) return err;
            if (running_captions.labels.entries.ptr != old_entries or running_captions.revision != revision or
                !std.mem.eql(u8, running_captions.labels.lookup(0, key, .{}).label orelse "", saved_label)) return error.FailedRefreshDiscardedCaptions;
            fixture.alternate = true;
            revision = try std.math.add(u64, revision, 1);
            try refreshRunningCaptions(gpa, &running_captions, &running_model, &fixture, "Offline live fixture", revision);
            const translated = running_captions.labels.lookup(0, key, .{}).label orelse return error.MissingTranslatedLetter;
            if (std.mem.eql(u8, translated, saved_label) or
                !std.mem.eql(u8, &frozen, &(try running_model.id())) or
                !std.mem.eql(u8, &running_captions.snapshot, &frozen) or
                std.mem.eql(u8, &running_captions.snapshot, &(try model.id())) or
                running_captions.revision != revision) return error.RunningSourceRefreshChangedProject;
        }
        if (source_refresh_fixture and count == 3) {
            if (captions.revision != revision or running_captions.revision != revision) return error.SourceRefreshNotApplied;
        }
        if (native_tray_fixture and count == 2) {
            life.companion_visible = true;
            companion_view.overlay = true;
            companion_view.applied_window = null;
        }
        if (native_tray_fixture and count == 3) {
            const id = companion_window orelse return error.CompanionWindowMissing;
            if (companion_view.applied_window != id) return error.CompanionModeNotApplied;
            const child_window = Backend.c.SDL_GetWindowFromID(id) orelse return error.CompanionWindowMissing;
            const flags = Backend.c.SDL_GetWindowFlags(child_window);
            const mask = Backend.c.SDL_WINDOW_BORDERLESS | Backend.c.SDL_WINDOW_ALWAYS_ON_TOP | Backend.c.SDL_WINDOW_NOT_FOCUSABLE;
            if ((flags & mask) != (if (companion_view.overlay) mask else 0)) return error.CompanionModeFlagsMismatch;
            std.log.info("Native companion overlay supported: {any}", .{companion_view.overlay});
        }
        if (jobs.runner) |job| if (job.worker.poll()) |event| {
            jobs.runner = null;
            defer job.worker.destroy();
            var prepared = event.result catch |err| {
                onboarding.report(err);
                continue;
            };
            defer prepared.deinit();
            if (job.editor_generation != owner_generation or !std.meta.eql(event.ticket, job.worker.ticket) or !std.mem.eql(u8, &event.ticket.snapshot, &(try model.id()))) {
                onboarding.report(error.StaleBuild);
                continue;
            }
            const runner = prepared.runner orelse {
                onboarding.report(error.RunnerArtifactNotPrepared);
                continue;
            };
            prepared.runner = null;
            if (built_runner) |*old| old.deinit();
            built_runner = runner;
            _ = try practice.choose(.{ .source = .draft }, 0);
            practicing = true;
            onboarding.active = false;
        };
        if (jobs.build) |job| if (job.worker.poll()) |event| {
            jobs.build = null;
            defer job.worker.destroy();
            var prepared = event.result catch |err| {
                if (pending_flash != null) {
                    flash_failure = err;
                    flash_panel = true;
                }
                pending_flash = null;
                advance_flash = false;
                view.report(err);
                continue;
            };
            defer prepared.deinit();
            if (job.editor_generation != owner_generation or !std.meta.eql(event.ticket, job.worker.ticket)) {
                if (pending_flash != null) {
                    flash_failure = error.StaleBuild;
                    flash_panel = true;
                }
                pending_flash = null;
                advance_flash = false;
                view.report(error.StaleBuild);
                continue;
            }
            const bundle = prepared.takeBundle(&model, .{ .generation = job_generation, .snapshot = try model.id() }) catch |err| {
                if (pending_flash != null) {
                    flash_failure = err;
                    flash_panel = true;
                }
                pending_flash = null;
                advance_flash = false;
                view.report(err);
                continue;
            };
            flash_gate.cancel();
            retained_flash_view = null;
            if (pending_flash) |pending| {
                if (pending.generation == owner_generation and std.mem.eql(u8, &pending.snapshot, &(try model.id()))) {
                    advance_flash = true;
                } else pending_flash = null;
            }
            if (flash) |*previous| previous.deinit();
            flash = null;
            if (built) |*previous| previous.deinit();
            if (built_runner) |*previous| previous.deinit();
            built = bundle.firmware;
            built_runner = bundle.runner;
            built_generation = job_generation;
            built_tree = bundle.expected_export_tree;
            flash_panel = false;
            view.diagnostic = @splat(0);
        };
        if (jobs.file) |job| if (job.worker.poll()) |event| {
            jobs.file = null;
            defer job.worker.destroy();
            var prepared = event.result catch |err| {
                view.report(err);
                continue;
            };
            defer prepared.deinit();
            if (job.editor_generation != owner_generation or !std.meta.eql(event.ticket, job.worker.ticket)) {
                view.report(error.StaleProjectAction);
                continue;
            }
            paths.validateCompletion(job.action, view.paths, &model) catch |err| {
                view.report(err);
                continue;
            };
            if ((job.action.kind == .open or job.action.kind == .open_discard) and (owner.inspector.dirty() or owner.pending != null)) {
                view.report(error.PendingEditorRequest);
                continue;
            }
            _ = prepared.promote(&model) catch |err| {
                view.report(err);
                continue;
            };
            if (job.action.kind == .open or job.action.kind == .open_discard) owner_generation = try std.math.add(u64, owner_generation, 1);
            if (job.action.kind == .open or job.action.kind == .open_discard or job.action.kind == .save) {
                registry.set(.{ .board_id = model.document().board_id, .profile_id = model.document().profile_id }, std.mem.sliceTo(&view.paths.project, 0)) catch |err| view.report(err);
                if (user_paths) |owned| remember(gpa, init.io, owned.paths, &view, &model) catch |err| view.report(err);
            }
            if (prepared.exported) |id| exported = id;
            if (job.close) |captured| {
                _ = owner.savedClose(&model, captured) catch |err| failed: {
                    view.report(err);
                    break :failed desktop.editor_dispatch.Effect.none;
                };
            }
            if (owner.closed) break;
        };
        if (jobs.source) |job| if (job.worker.poll()) |event| {
            jobs.source = null;
            defer job.worker.destroy();
            var prepared = event.result catch |err| {
                view.report(err);
                continue;
            };
            defer prepared.deinit();
            if (job.editor_generation != owner_generation or !std.meta.eql(event.ticket, job.worker.ticket)) {
                view.report(error.StaleCallbackAction);
                continue;
            }
            callbacks.validate(job.action, view.callback, &model) catch |err| {
                view.report(err);
                continue;
            };
            if ((job.action.kind == .attach or job.action.kind == .refresh) and (owner.inspector.dirty() or owner.pending != null)) {
                view.report(error.PendingEditorRequest);
                continue;
            }
            const changed = prepared.promote(&model) catch |err| {
                view.report(err);
                continue;
            };
            if (job.action.kind == .check) {
                view.diagnostic = @splat(0);
                const message = if (changed) "External source differs · refresh explicitly to accept" else "External source matches the attached snapshot";
                @memcpy(view.diagnostic[0..message.len], message);
            }
        };
        if (jobs.profile) |job| if (job.worker.poll()) |event| {
            jobs.profile = null;
            defer job.worker.destroy();
            var prepared = event.result catch |err| {
                view.report(err);
                continue;
            };
            defer prepared.deinit();
            if (job.editor_generation != owner_generation or !std.meta.eql(event.ticket, job.worker.ticket) or !std.meta.eql(job.previous_path, view.paths.project)) {
                view.report(error.StaleProfileAction);
                continue;
            }
            job.action.validate(&model) catch |err| {
                view.report(err);
                continue;
            };
            if (owner.inspector.dirty() or owner.pending != null) {
                view.report(error.PendingEditorRequest);
                continue;
            }
            const next_owner = try std.math.add(u64, owner_generation, 1);
            prepared.promote(&model) catch |err| {
                view.report(err);
                continue;
            };
            owner_generation = next_owner;
            const target = job.worker.request.path;
            view.paths.project = @splat(0);
            @memcpy(view.paths.project[0..target.len], target);
            registry.set(.{ .board_id = model.document().board_id, .profile_id = model.document().profile_id }, target) catch |err| view.report(err);
            if (prepared.existing) if (user_paths) |owned| remember(gpa, init.io, owned.paths, &view, &model) catch |err| view.report(err);
        };
        const now_us: u64 = @intCast(@max(0, native.nanoTime()) / 1000);
        if (accepted_editor_generation != owner_generation) {
            accepted_editor_generation = owner_generation;
            jobs.cancel();
            if (built) |*value| value.deinit();
            built = null;
            if (built_runner) |*value| value.deinit();
            built_runner = null;
            exported = null;
            pending_flash = null;
            advance_flash = false;
            build_scheduler = .{};
            view.combo = null;
            view.encoders = null;
            view.modal = .none;
            view.host.drag = null;
            view.keyboard.drag = null;
            if (practice.active or draft_runtime.owner != null) draft_runtime.fail(&practice, error.PracticeProjectSwitched, now_us);
        }
        if (flash) |*session| {
            if (retained_flash_view != null) {
                const current = flashSnapshot(session, session.view(null), built_generation);
                flash_gate.observe(current);
                if (flash_gate.phase == .idle or !(session.matchesModel(&model, built_generation) catch false)) {
                    flash_gate.cancel();
                    retained_flash_view = null;
                }
            }
            _ = session.observe(&model, built_generation) catch |err| {
                flash_failure = err;
                view.report(err);
            };
            if (retained_flash_view) |rendered_view| {
                const current = flashSnapshot(session, session.view(null), built_generation);
                const driver_now = if (live) |*driver| driver.transport.now() else @as(u64, @intCast(std.Io.Clock.awake.now(init.io).toMilliseconds()));
                if (live) |*driver| {
                    if (driver.session.bootloader_status == .accepted) flash_gate.observeAccepted(current, driver_now);
                }
                // Only the board must match the selected artifact; the live
                // session remains bound to the verified running firmware.
                const selected_identity = project.snapshot.identity(gpa, model.current.snapshot, model.board) catch null;
                const gate_session: bootloader.Session = if (live) |*driver| .{
                    .available = if (selected_identity) |selected| flashLiveMatches(driver, running_identity, selected, current.board_id) and driver.session.bootloaderAvailable() else false,
                    .status = bootloaderStatus(driver.session.bootloader_status),
                } else .{};
                switch (flash_gate.step(gate_session, current, driver_now)) {
                    .request_once => if (live) |*driver| {
                        session.discovery_started = now_us / 1000;
                        if (!gate_session.available) {
                            flash_gate.requestFailed();
                        } else driver.enterBootloader(driver_now) catch |err| {
                            flash_gate.requestFailed();
                            std.log.info("HID BOOTSEL request unavailable ({s}); continuing the same operation with manual guidance", .{@errorName(err)});
                        };
                    },
                    .start => {
                        session.confirm(rendered_view, &model, built_generation, now_us / 1000) catch |err| {
                            flash_failure = err;
                            view.report(err);
                        };
                        retained_flash_view = null;
                    },
                    else => {},
                }
                if (flash_gate.phase == .manual and flash_gate.consumeManual(current)) {
                    if (session.discovery_started == null) session.guidance_delay_ms = 0;
                    session.confirm(rendered_view, &model, built_generation, now_us / 1000) catch |err| {
                        flash_failure = err;
                        view.report(err);
                    };
                    retained_flash_view = null;
                }
                if (flash_gate.phase == .idle) retained_flash_view = null;
            }
            const poll_effect = session.poll(now_us / 1000) catch |err| failed: {
                flash_failure = err;
                view.report(err);
                break :failed desktop.flash_controller.Effect.none;
            };
            if (poll_effect == .watch_reconnect and session.owner.phase == .reconnecting and
                !session.owner.reconnect_binding_prepared and
                (session.matchesModel(&model, built_generation) catch false))
            handoff: {
                const watch = poll_effect.watch_reconnect;
                const artifact = session.owner.artifact orelse break :handoff;
                if (!std.meta.eql(watch.expected, artifact.expected_identity)) break :handoff;
                var replacement = desktop.model.Model.init(gpa, session.request.file.board, session.request.file.loaded.snapshot) catch |err| {
                    view.report(err);
                    break :handoff;
                };
                defer replacement.deinit();
                const next_identity = project.snapshot.identity(gpa, replacement.current.snapshot, replacement.board) catch |err| {
                    view.report(err);
                    break :handoff;
                };
                if (!std.mem.eql(u8, &replacement.board.id, &artifact.expected_identity.board_id) or
                    !std.mem.eql(u8, &replacement.document().profile_id, &artifact.expected_identity.profile_id) or
                    !std.mem.eql(u8, &next_identity.digest, &artifact.expected_identity.digest) or
                    !std.meta.eql(next_identity, try project.snapshot.identity(gpa, model.current.snapshot, model.board))) break :handoff;
                var next_captions = if (source) |*active| Captions.init(gpa, &replacement, active, active.id(), revision) catch |err| {
                    view.report(err);
                    break :handoff;
                } else Captions.init(gpa, &replacement, &fixture, "Offline live fixture", revision) catch |err| {
                    view.report(err);
                    break :handoff;
                };
                defer next_captions.deinit();
                var next_board = boards.OwnedBoard.fromDocument(gpa, replacement.document()) catch |err| {
                    view.report(err);
                    break :handoff;
                };
                defer next_board.deinit();
                var next_seed: u32 = 0;
                std.Io.randomSecure(init.io, std.mem.asBytes(&next_seed)) catch |err| {
                    view.report(err);
                    break :handoff;
                };
                const old_token = session.owner.previous_session_token orelse if (live) |driver| driver.session.token else 0;
                const first_token = if (next_seed == std.math.maxInt(u32)) @as(u32, 1) else next_seed + 1;
                if (old_token != 0 and first_token == old_token) next_seed +%= 1;
                const next_driver = LiveDriver.init(.{ .io = init.io }, next_identity, next_seed, null) catch |err| {
                    view.report(err);
                    break :handoff;
                };
                if (live) |*driver| {
                    if (driver.session.token != 0 and session.owner.previous_session_token == null)
                        session.owner.previous_session_token = driver.session.token;
                    driver.disconnect(driver.transport.now());
                }
                live = next_driver;
                std.mem.swap(desktop.model.Model, &running_model, &replacement);
                std.mem.swap(Captions, &running_captions, &next_captions);
                std.mem.swap(boards.OwnedBoard, &running_board, &next_board);
                running_identity = next_identity;
                resetLivePresentation(&presenter, &visibility, &live_frame, &live_pressed, &life);
                session.owner.reconnect_binding_prepared = true;
                std.log.info("Flash reconnect binding prepared for operation {d}", .{watch.operation.id});
            }
            if (session.owner.phase == .failed and flash_failure == null) {
                if (session.runtime.last_error) |err| {
                    flash_failure = err;
                    view.report(err);
                }
            }
            if (session.reconnect) |watch| if (live) |*driver| {
                const identity = driver.session.expected;
                if (driver.connected and driver.session.token != 0 and (session.owner.previous_session_token == null or driver.session.token != session.owner.previous_session_token.?) and
                    driver.session.hasCoherentState() and std.mem.eql(u8, &identity.board_id, &watch.expected.board_id) and
                    std.mem.eql(u8, &identity.profile_id, &watch.expected.profile_id) and std.mem.eql(u8, &identity.digest, &watch.expected.digest))
                {
                    _ = session.reconnected(driver.session.token, true, watch.expected, now_us / 1000) catch |err| {
                        flash_failure = err;
                        view.report(err);
                    };
                }
            };
        }
        if (source) |*active| if (active.refresh()) {
            revision = try std.math.add(u64, revision, 1);
            applyPractice(&draft_runtime, &practice, practice.pause(now_us), built_runner, &model, &view, now_us);
            if (practice.active) {
                practice.session.scored = false;
                practice.failure = error.PracticeContextChanged;
            }
        };
        if (!practice.active or (practice_snapshot != null and !std.mem.eql(u8, &practice_snapshot.?.control, &practice.current))) {
            if (practice_snapshot) |*value| value.deinit();
            practice_snapshot = null;
        }
        if (practice.active and practice_snapshot == null and frame_limit == null) {
            const selected_live = practice.captured_config.source == .os and live_frame.labels != null and !live_frame.stale;
            const selected = if (selected_live) &running_model else &model;
            practice_snapshot = if (source) |*active| try PracticeSnapshot.init(gpa, selected, active, active.id(), revision, practice.generation, practice.current, selected_live) else try PracticeSnapshot.init(gpa, selected, &fixture, "Offline fixture", revision, practice.generation, practice.current, selected_live);
        }
        const practice_control_model = if (practice_snapshot) |*value| &value.model else &model;
        const practice_control_id = if (practice_snapshot) |value| value.control else try model.id();
        applyPractice(&draft_runtime, &practice, practice.observe(practice_control_id, now_us), built_runner, practice_control_model, &view, now_us);
        draft_runtime.poll(&practice, practice_control_model, now_us) catch |err| {
            draft_runtime.fail(&practice, err, now_us);
            view.report(err);
        };
        if (check_draft) {
            if (practice.failure) |failure| return failure;
            if (practice.session.len > 1) return error.DraftRepeatRoutingFailed;
        }
        events.now_us = now_us;
        events.model = practice_control_model;
        draft_runtime.router.owns_practice_input = practicing and !practice_view.data_open and !practice_view.progress_open and !practice_view.diagnostics_open and !practice_view.curriculum_open and !practice_view.help_open and !practice_view.review_open;
        draft_runtime.router.focused = frame_limit != null or Backend.c.SDL_GetWindowFlags(native.window) & Backend.c.SDL_WINDOW_INPUT_FOCUS != 0;
        if (captions.revision != revision or !std.mem.eql(u8, &captions.snapshot, &(try model.id()))) {
            const replacement = if (source) |*active| try Captions.init(gpa, &model, active, active.id(), revision) else try Captions.init(gpa, &model, &fixture, "Offline launch fixture", revision);
            captions.deinit();
            captions = replacement;
        }
        if (source) |*active| {
            refreshRunningCaptions(gpa, &running_captions, &running_model, active, active.id(), revision) catch |err| view.report(err);
        }
        if (dialog.pollCorrelated()) |completion| if (chooser.pending) |ticket| {
            if (completion.token == ticket.generation and chooser.accept(ticket, owner_generation, try model.id())) {
                if (completion.path) |path| {
                    if (path[0] != 0) switch (ticket.target) {
                        .project => view.paths.project = path,
                        .export_directory => view.paths.exported = path,
                        .callback_source => view.callback.root = path,
                        .onboarding_source => if (onboarding_chooser_generation == onboarding.generation) {
                            onboarding.location = path;
                        },
                        .onboarding_location => if (onboarding_chooser_generation == onboarding.generation) {
                            onboarding.root = path;
                        },
                        .onboarding_open => if (onboarding_chooser_generation == onboarding.generation) {
                            onboarding.location = path;
                        },
                    };
                } else |err| view.report(err);
            }
        };
        var board = try boards.OwnedBoard.fromDocument(gpa, model.document());
        defer board.deinit();
        if (status_fixture and (count == 1 or count == 21)) {
            _ = Backend.c.SDL_SetWindowSize(native.window, if (count == 21) 900 else 1440, if (count == 21) 600 else 1000);
        }
        const available = window.backend.windowSize();
        const system_scale = window.backend.contentScale();
        // Match the reference editor: fit the whole design canvas, accounting
        // for macOS display density. Menu zoom is relative to that fitted size.
        const fitted_scale = desktop.geometry.fitScale(available.w / system_scale, available.h / system_scale);
        // Practice has a responsive canvas; keep its controls readable in the
        // native minimum window instead of shrinking the editor's fixed canvas.
        window.content_scale = (if (practicing) @max(@as(f32, 0.8), fitted_scale) else fitted_scale) * life.editor_scale;
        window.snap_to_pixels = window.content_scale == 1;
        if (rundown_fixture) view.toolbar.light = count < (if (layout_preview) @as(usize, 19) else 7);
        window.themeSet(if (view.toolbar.light) dvui.Theme.builtin.adwaita_light else dvui.Theme.builtin.adwaita_dark);
        try window.begin(if (frame_limit == null) window.beginWait(interrupted) else native.nanoTime());
        // DVUI rounds its render scale to hundredths. Keep the fitted editor
        // aligned with the exact pixel edge, including on Retina displays.
        if (!practicing and window.data().rect.w > 0) window.natural_scale = window.rect_pixels.w / window.data().rect.w;
        var ended = false;
        errdefer if (!ended) {
            _ = window.end(.{ .manage_backend = frame_limit == null }) catch {};
        };
        if (!fonts_installed and (frame_limit == null or native_rundown or status_fixture)) {
            try @import("editor-fonts").install(gpa, init.io);
            fonts_installed = true;
        }
        if (practice_fixture and count == 3) {
            var lost: Backend.c.SDL_Event = std.mem.zeroes(Backend.c.SDL_Event);
            lost.window.type = Backend.c.SDL_EVENT_WINDOW_FOCUS_LOST;
            lost.window.windowID = events.root;
            if (!Backend.c.SDL_PushEvent(&lost)) return error.FixtureEventRejected;
        }
        if (check_draft and draft_phase == .starting and draft_runtime.router.runner_running) {
            var key: Backend.c.SDL_Event = std.mem.zeroes(Backend.c.SDL_Event);
            key.key.type = Backend.c.SDL_EVENT_KEY_DOWN;
            key.key.windowID = events.root;
            key.key.scancode = 4;
            key.key.down = true;
            if (!Backend.c.SDL_PushEvent(&key)) return error.FixtureEventRejected;
            key.key.repeat = true;
            if (!Backend.c.SDL_PushEvent(&key)) return error.FixtureEventRejected;
            draft_phase = .input;
        } else if (check_draft and draft_phase == .input and practice.session.len == 1) {
            var lost: Backend.c.SDL_Event = std.mem.zeroes(Backend.c.SDL_Event);
            lost.window.type = Backend.c.SDL_EVENT_WINDOW_FOCUS_LOST;
            lost.window.windowID = events.root;
            if (!Backend.c.SDL_PushEvent(&lost)) return error.FixtureEventRejected;
            draft_phase = .paused;
        }
        events.time_count = 0;
        try @import("native-events").pump(&native, &window, &events);
        if (practice_fixture and count == 2) {
            var text: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(practice.session.reference[0], &text);
            _ = try window.addEventText(.{ .text = text[0..len] });
        }
        if (events.lost_focus) {
            events.lost_focus = false;
            applyPractice(&draft_runtime, &practice, practice.pause(now_us), built_runner, &model, &view, now_us);
        }
        const document = model.document();
        const can_build = onboarding.selected and if (build_plan) |plan| !jobs.busy() and std.mem.eql(u8, &plan.config.board_id, &model.board.id) and std.mem.eql(u8, plan.config.build_board, board.entry.selector) else false;
        const build_status: []const u8 = if (jobs.build) |job| (if (job.first_build) "First build: this can take a few minutes. Later builds are faster." else "Building") else if (built) |artifact| (if (std.mem.eql(u8, &artifact.inputs.project_digest, &(try model.id()))) "Built snapshot" else "Build outdated") else if (build_plan != null) "Ready to build and Flash" else "Application bundle is missing build resources";
        const status_scene = if (status_fixture) (count - 1) / 4 else 0;
        if (status_fixture) {
            view.toolbar.auto_build = true;
            view.toolbar.details_open = status_scene == 4;
        }
        view.callback.busy = jobs.busy();
        practice_history.poll();
        if (practice_view.transfer != .none) {
            practice_history.transfer(practice.configCohort(), std.mem.sliceTo(&practice_view.data_path, 0), practice_view.transfer == .import_database) catch |err| {
                practice_history.error_value = err;
            };
            practice_view.transfer = .none;
        }
        const use_practice_live = if (practice_snapshot) |value| value.live else practice.config.source == .os and live_frame.labels != null and !live_frame.stale;
        const practice_labels = if (practice_snapshot) |*value| &value.captions.labels else if (use_practice_live) &running_captions.labels else &captions.labels;
        practice.curriculum_labels = practice_labels.practiceLabels();
        const practice_geometry = if (practice_snapshot) |value| value.board.entry.geometry else if (use_practice_live) running_board.entry.geometry else board.entry.geometry;
        const practice_model = if (practice_snapshot) |*value| &value.model else if (use_practice_live) &running_model else &model;
        const practice_identity = try project.snapshot.identity(gpa, practice_model.current.snapshot, practice_model.board);
        var behavior_hash = std.crypto.hash.sha2.Sha256.init(.{});
        behavior_hash.update(&practice_identity.board_id);
        behavior_hash.update(&practice_identity.digest);
        const source_name = if (source) |*active| active.id() else "Offline fixture";
        desktop.practice_results.displayName(practice_model.document().name, &practice.context_profile);
        desktop.practice_results.displayName(source_name, &practice.context_source);
        const mapping_name = if (source) |*active| try std.fmt.allocPrint(window.arena(), "{s}/{s}", .{ active.id(), active.layoutId() }) else "Offline fixture";
        practice.cohort.behavior = behavior_hash.finalResult();
        practice.cohort.mapping = desktop.practice_context.mapping(practice_labels, mapping_name);
        practice.cohort.verified = (use_practice_live or practice.config.source == .draft) and if (source) |*active| active.hasActiveLayout() else false;
        if (frame_limit != null and count == 1 and practice.active) {
            practice.captured_cohort.behavior = practice.cohort.behavior;
            practice.captured_cohort.mapping = practice.cohort.mapping;
            practice.captured_cohort.verified = practice.cohort.verified;
        }
        if (practice.active and practice.session.state != .complete and
            (!std.mem.eql(u8, &practice.cohort.behavior, &practice.captured_cohort.behavior) or
                !std.mem.eql(u8, &practice.cohort.mapping, &practice.captured_cohort.mapping) or
                practice.cohort.verified != practice.captured_cohort.verified) and practice.generation != 0)
        {
            practice.session.scored = false;
            applyPractice(&draft_runtime, &practice, practice.pause(now_us), built_runner, &model, &view, now_us);
            practice.failure = error.PracticeContextChanged;
        }
        const practice_metadata = try window.arena().alloc(desktop.practice.KeyMetadata, practice_labels.key_count);
        @memset(practice_metadata, .{});
        for (practice_geometry) |key| practice_metadata[key.key_index] = .{ .hand = @fromBackingInt(@backingInt(key.hand)), .thumb = key.group == .thumb, .home_row = key.home_row };
        var hand_coverage: desktop.practice_generator.HandCoverage = .{};
        for ('A'..'Z' + 1) |capital| {
            if (try desktop.practice.hint(practice_labels.practiceLabels(), 0, 0, @intCast(capital), 1)) |route| {
                switch (practice_metadata[route.key].hand) {
                    .left => hand_coverage.left[capital - 'A'] = true,
                    .right => hand_coverage.right[capital - 'A'] = true,
                    .neutral => {},
                }
            }
        }
        const known_hand_translation = if (source) |*active| active.hasActiveLayout() else frame_limit != null;
        practice.normal_coverage = if (known_hand_translation and std.mem.indexOfScalar(bool, &hand_coverage.left, true) != null and std.mem.indexOfScalar(bool, &hand_coverage.right, true) != null) hand_coverage else null;
        const practice_pressed = try window.arena().alloc(bool, practice_labels.key_count);
        @memset(practice_pressed, false);
        if (use_practice_live and live_frame.pressed.len == practice_pressed.len) @memcpy(practice_pressed, live_frame.pressed) else if (draft_runtime.owner) |runner| if (runner.pressed.len == practice_pressed.len) {
            @memcpy(practice_pressed, runner.pressed);
        };
        const practice_frame: tutor.Frame = .{
            .source = if (use_practice_live) .live else if (draft_runtime.owner != null) .simulated else .draft,
            .labels = practice_labels,
            .geometry = practice_geometry,
            .metadata = practice_metadata,
            .profile = practice_model.document().name,
            .layer = if (use_practice_live) live_frame.layer else if (draft_runtime.owner != null) draft_runtime.highest_layer else 0,
            .active_layers = if (use_practice_live) live_frame.active else if (draft_runtime.owner != null) draft_runtime.active_layers else 1,
            .modifiers = if (use_practice_live) live_frame.modifiers else @bitCast(draft_runtime.modifiers),
            .pressed = practice_pressed,
        };
        const scene_frames: usize = if (layout_preview) 6 else 2;
        if (rundown_fixture and count % scene_frames == 1) {
            const scene = (count + scene_frames - 1) / scene_frames;
            if (scene == 1 or scene == 2 or scene == 5 or scene == 8 or scene == 9 or scene == 10) practice_view.rundown = .{};
            if (scene == 1) {
                practice.config = .{ .preset = .mixed_case, .level = 0 };
                _ = try practice.start(true, null, now_us);
                view.toolbar.light = true;
            } else if (scene == 2) {
                practice.config = .{ .preset = .punctuation, .level = 1 };
                _ = try practice.start(true, null, now_us);
                for (practice.session.reference[0..practice.session.reference_len], 0..) |cp, index| {
                    if (index % 17 == 0 or cp == ';' or cp == '"') {
                        try practice.session.insert("x", now_us + index * 120_000, false);
                        practice.session.backspace();
                    }
                    var bytes: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &bytes);
                    try practice.session.insert(bytes[0..n], now_us + index * 120_000, false);
                }
                practice_view.rundown.selected = ';';
            } else if (scene == 3) {
                const record = practice.completed.?;
                for (record.stats[0..record.stat_count]) |stat| if (stat.cp == '"' and stat.route_count > 0) {
                    practice_view.rundown.layer = stat.routes[0].layer;
                    practice_view.rundown.variant = std.mem.indexOfScalar(u8, &desktop.practice.route_modifiers, stat.routes[0].modifiers) orelse 0;
                };
                practice_view.rundown.selected = '"';
            } else if (scene == 4) {
                view.toolbar.light = false;
            } else if (scene == 5) {
                practice.config.targets = .{ 'e', 'a', 't', 0, 0 };
                practice.config.target_count = 3;
                _ = try practice.start(true, null, now_us);
            } else if (scene == 6) {
                for (practice.session.reference[0..practice.session.reference_len], 0..) |cp, index| {
                    var bytes: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &bytes);
                    try practice.session.insert(bytes[0..n], now_us + index * 120_000, false);
                }
            } else if (scene == 7) {
                practice_view.rundown.scope = 1;
                practice_history.cohort = practice.completed.?.cohort;
                practice_history.data.deinit();
                practice_history.data = .{};
                practice_history.data.requested_id = practice.completed.?.id;
                practice_history.data.contains_requested = true;
                for (0..12) |_| try practice_history.data.all.add(&practice.completed.?);
                for (0..10) |_| try practice_history.data.recent.add(&practice.completed.?);
            } else if (scene == 8) {
                practice.config.target_count = 0;
                practice.config.assistance = .layout_only;
                _ = try practice.start(true, null, now_us);
            } else if (scene == 9) {
                practice.config.assistance = .hidden;
                _ = try practice.start(true, null, now_us);
                if (!Backend.c.SDL_SetWindowSize(native.window, 820, 700)) return error.PracticeFixtureResize;
            } else if (scene == 10) {
                practice.config.assistance = .guided;
                _ = try practice.start(true, null, now_us);
                try practice.session.load("a;A", .os);
                try practice.session.insert("a;A", now_us + 1_000_000, false);
            } else if (data_preview and scene == 11) {
                practice_view.data_open = true;
                practice_view.rundown.refresh = true;
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 960)) return error.PracticeFixtureResize;
                const path = try std.fs.path.join(window.arena(), &.{ practice_history.path.?, "portable.sqlite3" });
                @memcpy(practice_view.data_path[0..path.len], path);
            } else if (data_preview and scene == 12) {
                if (!Backend.c.SDL_SetWindowSize(native.window, 820, 700)) return error.PracticeFixtureResize;
            } else if (progress_preview and scene == 11) {
                practice_view.progress_open = true;
                practice_view.progress.smoothing = true;
                practice_history.cohort = practice.completed.?.cohort;
                practice_history.data.deinit();
                practice_history.data = .{};
                practice_history.data.progress_allocator = gpa;
                practice_history.data.progress = try gpa.create(desktop.practice_progress.Summary);
                practice_history.data.progress.?.* = .{};
                const today = @divFloor(@as(i64, @intCast(std.Io.Clock.real.now(init.io).toNanoseconds())), desktop.practice_progress.day_ns);
                practice_history.data.progress.?.today = today;
                for (0..40) |index| {
                    var record = practice.completed.?;
                    record.id[0] = @intCast(index);
                    record.timestamp = (today - 27 + @as(i64, @intCast(index / 2))) * desktop.practice_progress.day_ns + @as(i64, @intCast(index % 2)) * 3_600_000_000_000;
                    record.active_us = 3_000_000 + @as(u64, @intCast(index % 7)) * 300_000;
                    practice_history.data.progress.?.add(&record);
                    try practice_history.data.all.add(&record);
                }
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (progress_preview and scene == 12) {
                if (!Backend.c.SDL_SetWindowSize(native.window, 820, 700)) return error.PracticeFixtureResize;
            } else if (progress_preview and scene == 13) {
                practice_view.progress.tab = 1;
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 960)) return error.PracticeFixtureResize;
            } else if (progress_preview and scene == 14) {
                if (!Backend.c.SDL_SetWindowSize(native.window, 820, 700)) return error.PracticeFixtureResize;
            } else if (progress_preview and scene == 15) {
                practice_view.progress.tab = 0;
                practice_history.data.progress.?.count = 0;
            } else if (progress_preview and scene == 16) {
                practice_history.data.progress.?.count = 1;
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 960)) return error.PracticeFixtureResize;
            } else if (diagnostics_preview and scene == 11) {
                practice.config = .{ .level = 0 };
                _ = try practice.start(true, null, now_us);
                try practice.session.load("the tree there the tree there the tree there", .os);
                practice_timing.clock = .injected;
                var event_at: u64 = 1_000_000;
                for (practice.session.reference[0..practice.session.reference_len], 0..) |cp, index| {
                    event_at += if (index % 11 == 0) @as(u64, 600_000) else 120_000;
                    if (index % 13 == 0) {
                        try practice.session.insert("x", event_at, false);
                        practice.session.backspaceAt(event_at + 10_000);
                        event_at += 30_000;
                    }
                    if (index == 20) {
                        practice.session.pause(event_at);
                        event_at += 2_000_000;
                        practice.session.resumeRun(event_at);
                    }
                    if (index == 10) practice_timing.record(.hint_shown, event_at, practice.session.duration(event_at), practice.session.len, null, .ordinary);
                    var bytes: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &bytes);
                    try practice.session.insert(bytes[0..n], event_at, false);
                }
                var record = try desktop.practice_results.capture(&practice.session, practice.captured_cohort, practice_labels.practiceLabels());
                try std.Io.randomSecure(init.io, &record.id);
                record.timestamp = @intCast(std.Io.Clock.real.now(init.io).toNanoseconds());
                practice.completed = record;
                practice.completed_enqueued = true;
                practice_view.diagnostics_open = true;
                practice_view.rundown.selected = 'e';
                practice_history.data.deinit();
                practice_history.data = .{ .requested_id = record.id, .requested_record = record, .contains_requested = true, .progress_allocator = gpa };
                practice_history.cohort = record.cohort;
                practice_history.data.timing = try desktop.practice_timing.Owned.clone(gpa, practice_timing.payload());
                practice_history.data.analysis = try desktop.practice_analysis.analyze(gpa, practice_timing.payload());
                practice_history.data.progress = try gpa.create(desktop.practice_progress.Summary);
                practice_history.data.progress.?.* = .{};
                for (0..4) |index| {
                    var older = record;
                    older.id[0] = @intCast(index);
                    older.timestamp -= @as(i64, @intCast(index + 1)) * desktop.practice_progress.day_ns;
                    practice_history.data.progress.?.add(&older);
                }
                for (practice_history.data.progress.?.points[0..4]) |*point| try point.enrich(gpa, practice_timing.payload());
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (diagnostics_preview and scene == 12) {
                if (!Backend.c.SDL_SetWindowSize(native.window, 820, 700)) return error.PracticeFixtureResize;
            } else if (diagnostics_preview and scene == 13) {
                practice_view.diagnostics.tab = 1;
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (diagnostics_preview and scene == 14) {
                practice_view.diagnostics.tab = 2;
            } else if (diagnostics_preview and scene == 15) {
                practice.completed.?.timing_available = false;
                practice_view.diagnostics.tab = 0;
            } else if (curriculum_preview and scene == 11) {
                practice_view.curriculum_open = true;
                practice_view.curriculum.config = .{ .curriculum = .{ .version = 1 } };
                practice_history.cohort = practice.cohortFor(practice_view.curriculum.config);
                practice_history.data.deinit();
                practice_history.data = .{};
                var alphabet: [26]u8 = undefined;
                const learned = desktop.practice_curriculum.letters(practice_labels.practiceLabels(), &alphabet);
                var record: desktop.practice_results.Record = .{ .cohort = practice_history.cohort, .active_us = 60_000_000, .matched = 120, .attempts = 120, .correct_attempts = 120, .stat_count = 6 };
                for (learned[0..6], 0..) |cp, index| record.stats[index] = .{ .cp = cp, .opportunities = 20 };
                for (0..3) |index| {
                    record.id[0] = @intCast(index);
                    try practice_history.data.all.add(&record);
                }
                practice_history.data.latest_curriculum = record;
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (curriculum_preview and scene == 12) {
                if (!Backend.c.SDL_SetWindowSize(native.window, 820, 700)) return error.PracticeFixtureResize;
            } else if (curriculum_preview and scene >= 13 and scene <= 16) {
                practice_view.curriculum.config.curriculum.stage = @fromBackingInt(@as(u3, @intCast(scene - 12)));
                practice_view.curriculum.config.curriculum.family = 0;
                if (scene == 13) practice_view.curriculum.config.curriculum.alphabet = 7;
                if (scene == 16) practice_view.curriculum.config.curriculum.layer = 0;
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (curriculum_preview and scene == 17) {
                practice_view.curriculum_open = false;
                practice.config = .{ .level = 0, .curriculum = .{ .version = 1 } };
                _ = try practice.start(true, null, now_us);
            } else if (curriculum_preview and scene == 18) {
                for (practice.session.reference[0..practice.session.reference_len], 0..) |cp, index| {
                    var bytes: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &bytes);
                    try practice.session.insert(bytes[0..n], now_us + index * 150_000, false);
                }
            } else if (help_preview and scene == 11) {
                practice.config = .{ .level = 0, .preset = .mixed_case, .hints = .{ .policy = .delayed, .adaptive = false } };
                _ = try practice.start(true, null, now_us);
                try practice.session.load("A calm tree appears beside a quiet river.", .os);
                practice_view.help = .{ .generation = practice.generation, .position = 0, .last = now_us, .paused = false };
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (help_preview and scene == 12) {
                practice_view.help.waited_us = 2_000_000;
            } else if (help_preview and scene == 13) {
                if (!Backend.c.SDL_SetWindowSize(native.window, 820, 700)) return error.PracticeFixtureResize;
            } else if (help_preview and scene == 14) {
                practice_view.help_open = true;
                practice_view.help_config = practice.config;
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (help_preview and scene == 15) {
                practice_view.help_open = false;
                practice_view.review_open = true;
                practice_history.data.deinit();
                practice_history.data = .{ .progress_allocator = gpa };
                practice_history.cohort = practice.configCohort();
                practice_history.data.retention = try gpa.create(desktop.practice_retention.Summary);
                const now: i64 = @intCast(std.Io.Clock.real.now(init.io).toNanoseconds());
                practice_history.data.retention.?.* = .{ .now = now, .eligible_runs = 12, .unknown_runs = 4, .count = 3 };
                for ([_]u21{ 'e', 'r', 'A' }, 0..) |cp, index| practice_history.data.retention.?.entries[index] = .{ .cp = cp, .opportunities = 80, .cued = 40, .uncued = 40, .last_exposure = now - 8 * desktop.practice_retention.day_ns, .last_recall = if (index == 2) null else now - 8 * desktop.practice_retention.day_ns, .recalls = if (index == 2) 0 else 2, .context = practice.configCohort() };
            } else if (help_preview and scene == 16) {
                if (!Backend.c.SDL_SetWindowSize(native.window, 820, 700)) return error.PracticeFixtureResize;
            } else if (help_preview and scene == 17) {
                practice_view.review_open = false;
                practice.config = .{ .level = 0, .preset = .mixed_case, .assistance = .hidden };
                _ = try practice.start(true, null, now_us);
                try practice.session.load("A quiet river runs beside the tree.", .os);
                practice_view.help = .{ .generation = practice.generation, .position = 0, .last = now_us, .paused = false, .requested = true };
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (help_preview and scene == 18) {
                for (practice.session.reference[0..practice.session.reference_len], 0..) |cp, index| {
                    var bytes: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &bytes);
                    try practice.session.insert(bytes[0..n], now_us + index * 160_000, false);
                }
            } else if (help_preview and scene == 19) {
                practice_view.help_open = true;
                practice_view.help_config = practice.config;
                practice_view.help_config.hints.policy = .delayed;
                practice_view.help_config.assistance = .guided;
                if (!Backend.c.SDL_SetWindowSize(native.window, 900, 600)) return error.PracticeFixtureResize;
            } else if (layout_preview and help_preview and scene == 20) {
                practice_view.help_open = false;
                practice.config.assistance = .guided;
                practice.config.hints.policy = .on_request;
                _ = try practice.start(true, null, now_us);
                if (!Backend.c.SDL_SetWindowSize(native.window, 900, 700)) return error.PracticeFixtureResize;
            } else if (layout_preview and help_preview and scene == 21) {
                practice_view.review_open = true;
                practice_view.review.details = true;
            } else if (layout_preview and rundown_preview and scene == 11) {
                practice_view.rundown = .{ .history_open = true };
                practice.config = .{ .preset = .words, .level = 0 };
                _ = try practice.start(true, null, now_us);
                for (practice.session.reference[0..practice.session.reference_len], 0..) |cp, index| {
                    var bytes: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(cp, &bytes);
                    try practice.session.insert(bytes[0..n], now_us + index * 150_000, false);
                }
                var current = try desktop.practice_results.capture(&practice.session, practice.captured_cohort, practice_labels.practiceLabels());
                try std.Io.randomSecure(init.io, &current.id);
                current.timestamp = @intCast(std.Io.Clock.real.now(init.io).toNanoseconds());
                practice.completed = current;
                practice.completed_enqueued = true;
                practice_history.cohort = current.cohort;
                practice_history.data.deinit();
                practice_history.data = .{ .progress_allocator = gpa, .page_count = 5 };
                practice_history.data.page = try gpa.alloc(desktop.practice_results.Record, 10);
                @memset(practice_history.data.page, .{});
                for (0..5) |index| {
                    var saved = current;
                    saved.id[0] ^= @intCast(index + 1);
                    saved.timestamp -= @as(i64, @intCast(index + 1)) * desktop.practice_progress.day_ns;
                    practice_history.data.page[index] = saved;
                    try practice_history.data.all.add(&saved);
                    try practice_history.data.recent.add(&saved);
                    practice_history.data.recent_ids[index] = saved.id;
                }
                practice_history.data.recent_count = 5;
                if (!Backend.c.SDL_SetWindowSize(native.window, 1440, 1050)) return error.PracticeFixtureResize;
            } else if (layout_preview and rundown_preview and scene == 12) {
                practice_view.rundown.history_open = false;
                practice_view.rundown.more_details = true;
                practice_view.rundown.selected = 'e';
                if (!Backend.c.SDL_SetWindowSize(native.window, 900, 700)) return error.PracticeFixtureResize;
            } else if (layout_preview and rundown_preview and scene == 13) {
                practice_view.rundown.confirm_clear = true;
            }
        }
        try @import("practice_persistence.zig").update(init.io, &practice, &practice_view, &practice_history, practice_labels, &practice_timing, &practice_history_loaded, .{
            .now_us = now_us,
            .practicing = practicing,
            .rundown_fixture = rundown_fixture,
            .data_preview = data_preview,
        });
        var leave_practice = false;
        var practice_action: ?desktop.practice_controller.Action = null;
        var practice_input_effect: desktop.practice_controller.Effect = .{};
        if (layout_preview and help_preview and count == 19 * scene_frames + 4) if (dvui.tagGet("practice.tools")) |menu| {
            _ = try window.addEventMouseMotion(.{ .pt = .{ .x = menu.rect.x + menu.rect.w / 2, .y = menu.rect.y + menu.rect.h / 2 } });
            _ = try window.addEventMouseButton(.left, .press);
            _ = try window.addEventMouseButton(.left, .release);
        };
        // Manual layout gallery: capture the top, then exercise real scrolling
        // to inspect footer controls and long explanations after resizing.
        if (layout_preview and count % scene_frames == 4 and (practice_view.data_open or practice_view.progress_open or practice_view.diagnostics_open or practice_view.curriculum_open or practice_view.help_open or practice_view.review_open or practice.completed != null)) {
            _ = try window.addEventMouseMotion(.{ .pt = .{ .x = available.w * 0.75, .y = available.h * 0.65 } });
            _ = try window.addEventMouseWheel(-2000, .vertical, .mouse);
        }
        var toolbar_frame: @FieldType(editor.Frame, "toolbar") = .{ .board_name = board.entry.display.name, .connection = if (live != null and live.?.status == .multiple_devices) "Multiple keyboards: ambiguous" else switch (liveStatus(if (live) |*driver| driver else null, live_frame)) {
            .offline => "Offline editor",
            .connecting => "Keyboard connecting",
            .live => "Keyboard connected",
            .stale => "Keyboard state stale",
            .disconnected => "Keyboard disconnected",
            .incompatible => "Keyboard layout mismatch",
        }, .can_build = can_build, .can_flash = flash_tools != null and build_plan != null and can_build and frame_limit == null, .flash_active = flash != null and switch (flash.?.owner.phase) {
            .ready, .failed, .cancelled, .reconnect_timeout, .stale => false,
            else => true,
        }, .build_active = jobs.build != null, .first_build = if (jobs.build) |job| job.first_build else false, .flash_succeeded = if (flash) |session| session.owner.phase == .ready else false, .flash_failed = flash_failure != null or (if (flash) |session| session.owner.phase == .failed or session.owner.phase == .reconnect_timeout else false), .now_ms = now_us / 1000, .flash_status = if (jobs.build != null) "" else if (flash) |session| try session.status(dvui.currentWindow().arena(), now_us / 1000) else if (pending_flash != null) "Building for Flash" else if (flash_failure != null) "Flash failed" else "", .build_status = build_status, .profiles = if (std.mem.eql(u8, &model.board.id, &project.profiles.board.id)) &.{ .{ .id = "danish\x00\x00".*, .name = project.profiles.names[0] }, .{ .id = "qwerty\x00\x00".*, .name = project.profiles.names[1] }, .{ .id = "eurkey\x00\x00".*, .name = project.profiles.names[2] }, .{ .id = "eurmac\x00\x00".*, .name = project.profiles.names[3] } } else &.{} };
        if (status_fixture) {
            toolbar_frame.can_build = true;
            toolbar_frame.can_flash = true;
            toolbar_frame.build_active = status_scene == 0;
            toolbar_frame.first_build = status_scene == 0;
            toolbar_frame.flash_active = status_scene == 1;
            toolbar_frame.flash_succeeded = status_scene == 2;
            toolbar_frame.flash_failed = status_scene >= 3;
            toolbar_frame.flash_status = switch (status_scene) {
                0 => "",
                1 => "Transferring firmware to keyboard…",
                2 => "Matching firmware reconnected",
                else => "Flash failed: the selected firmware could not be verified against the current project snapshot. Review the complete diagnostic here before starting a new transfer.",
            };
        }
        var onboarding_action: keyboard_onboarding.Action = .none;
        onboarding.preparing_tutor = jobs.runner != null;
        var rendered = if (onboarding.active) onboarding_frame: {
            onboarding_action = try keyboard_onboarding.draw(&onboarding, model.dirty() or owner.inspector.dirty() or owner.pending != null, if (source) |*active| active.id() else "Offline", view.toolbar.light);
            break :onboarding_frame editor.Result{ .effect = .none };
        } else if (practicing) tutor_frame: {
            const theme = ui.Theme.get(view.toolbar.light);
            const canvas = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .{}, .background = true, .color_fill = .{ .color = theme.bg } });
            defer canvas.deinit();
            leave_practice = ui.button(theme, "Back to editor", "practice.back", .{ .x = 24, .y = 12, .w = 160, .h = 36 });
            const input: tutor.Input = .{
                .now_us = now_us,
                .window_focused = frame_limit != null or Backend.c.SDL_GetWindowFlags(native.window) & Backend.c.SDL_WINDOW_INPUT_FOCUS != 0,
                .owns_input = true,
                .fixture = frame_limit != null,
                .diagnostic = std.mem.sliceTo(&view.diagnostic, 0),
                .frame = if (practice.config.source == .os and live_enabled and !use_practice_live) null else practice_frame,
                .history = &practice_history.data,
                .history_cohort = practice_history.cohort,
                .history_saving = practice_history.worker != null,
                .history_failure = practice_history.error_value,
                .history_path = practice_history.path orelse "",
                .history_pending = practice_history.queued,
                .event_times = events.times[0..events.time_count],
            };
            const drawn = tutor.draw(&practice, &practice_view, theme, .{ .x = 24, .y = 64, .w = @max(300, window.data().rect.w - 48), .h = @max(300, window.data().rect.h - 88) }, input) catch |err| failed: {
                view.report(err);
                break :failed tutor.DrawResult{};
            };
            practice_action = drawn.action;
            practice_input_effect = drawn.input_effect;
            break :tutor_frame editor.Result{ .effect = .none };
        } else if (!life.editor_visible) editor.Result{ .effect = .none } else editor.draw(&view, &owner, &model, .{
            .toolbar = toolbar_frame,
            .keyboard = .{ .snapshot = try model.id(), .board_id = document.board_id, .physical_layout = document.physical_layout, .geometry = board.entry.geometry, .labels = &captions.labels, .board_name = board.entry.selector, .fidelity = "Catalog geometry · physical acceptance pending" },
            .host = &captions.host,
            .paths = .{ .exported = exported, .can_choose = frame_limit == null and !dialog.active(), .busy = jobs.busy() },
        }) catch |err| failed: {
            view.report(err);
            break :failed editor.Result{ .effect = .none };
        };
        var flash_intent: ?desktop.flash_controller.Intent = null;
        var flash_rendered: ?desktop.flash_presenter.View = null;
        var close_flash_panel = false;
        const flash_has_error = desktop.flash_presenter.showErrorWindow(if (flash) |session| session.owner.phase else null, flash_failure);
        if (flash_panel and flash_has_error and life.editor_visible and !practicing) {
            if (flash) |*session| {
                const live_token: ?u32 = if (live) |*driver| (if (driver.connected and driver.session.hasCoherentState()) driver.session.token else null) else null;
                flash_rendered = session.view(live_token);
                flash_intent = flash_ui.draw(&session.owner, .{ .session_token = live_token, .failure = flash_failure, .close_requested = &close_flash_panel, .details_open = &flash_details_open, .diagnostics = if (session.completion) |result| (if (result.completion) |completed| desktop.flash_presenter.Diagnostics.fromResult(completed) else null) else null }) catch |err| failed: {
                    view.report(err);
                    break :failed null;
                };
            } else if (pending_flash != null or flash_failure != null) {
                flash_ui.drawPending(flash_failure, jobs.build != null, &close_flash_panel);
            }
        }
        if (physical_flash and trial_start == null and can_build) {
            if (!can_build or jobs.busy() or flash != null) return error.PhysicalFlashStartupNotIdle;
            trial_start = native.nanoTime();
            std.log.info("Physical flash click dispatched (prepared inputs; cache-only status determined by build)", .{});
            rendered.effect = try dispatchFlash(&owner, &model);
        }
        if (build_fixture and count == 2) {
            if (!can_build or built != null or jobs.busy()) {
                std.log.err("Managed editor startup: paths={any} resources={any} plan={any} can_build={any} built={any} busy={any}", .{ user_paths != null, resources != null, build_plan != null, can_build, built != null, jobs.busy() });
                return error.ManagedEditorStartupNotIdle;
            }
            rendered = .{ .effect = try owner.request(&model, try desktop.editor_dispatch.Request.capture(&model, .build)) };
        }
        if (live_enabled and (live_frame.labels == null or live_frame.stale)) life.companion_visible = false;
        if (!life.companion_visible or (practicing and practice.config.assistance == .hidden)) if (companion_window) |id| if (Backend.c.SDL_GetWindowFromID(id)) |child_window| {
            _ = Backend.c.SDL_HideWindow(child_window);
        };
        if (life.companion_visible and (!practicing or practice.config.assistance != .hidden)) {
            // Child creation inherits this flag from the backend's saved options.
            // The editor's existing native window remains opaque.
            const parent_transparent = native.init_opts_save.?.transparent;
            native.init_opts_save.?.transparent = true;
            const child = dvui.osWindow(@src(), .{ .title = "Zigmkay Companion", .size = .{ .w = 880, .h = 300 }, .min_size = .{ .w = 400, .h = 180 }, .hidden = true }, .{ .open_flag = &life.companion_visible });
            native.init_opts_save.?.transparent = parent_transparent;
            defer child.deinit();
            companion_window = switch (child.inner) {
                .os => |active| Backend.c.SDL_GetWindowID(active.backend.window),
                .floating => null,
            };
            if (frame_limit == null and companion_view.applied_window != companion_window) try @import("editor-fonts").install(gpa, init.io);
            const held = try dvui.currentWindow().arena().alloc(bool, model.document().key_ids.len);
            @memset(held, false);
            if (draft_runtime.owner) |active| if (active.pressed.len == held.len) @memcpy(held, active.pressed);
            const companion_labels = if (live_enabled) &running_captions.labels else &captions.labels;
            const companion_layer = if (live_enabled) live_frame.layer else if (draft_runtime.owner != null) draft_runtime.highest_layer else model.layer;
            const companion_mods = if (live_enabled) live_frame.modifiers else if (draft_runtime.owner != null) @as(@TypeOf(live_frame.modifiers), @bitCast(draft_runtime.modifiers)) else @as(@TypeOf(live_frame.modifiers), .{});
            const practice_taps = try dvui.currentWindow().arena().alloc(bool, companion_labels.key_count);
            const practice_holds = try dvui.currentWindow().arena().alloc(bool, companion_labels.key_count);
            @memset(practice_taps, false);
            @memset(practice_holds, false);
            if (practicing and practice.config.assistance == .guided and practice.active and practice.session.state != .complete and
                (!live_enabled or use_practice_live) and companion_labels == practice_labels)
            {
                const next_position = desktop.practice_view.focus(&practice.session);
                const next_hint = if (next_position < practice.session.reference_len) try desktop.practice.hint(companion_labels.practiceLabels(), companion_layer, companion_mods.toByte(), practice.session.reference[next_position], if (live_enabled) live_frame.active else if (draft_runtime.owner != null) draft_runtime.active_layers else desktop.practice.layerMask(companion_layer)) else null;
                try desktop.practice.guidance(companion_labels.practiceLabels(), practice_metadata, companion_layer, companion_mods.toByte(), next_hint, .{ .tap = practice_taps, .hold = practice_holds });
            }
            companion_ui.draw(if (live_enabled) &running_model else &model, .{
                .snapshot = if (live_enabled) try running_model.id() else try model.id(),
                .geometry = if (live_enabled) running_board.entry.geometry else board.entry.geometry,
                .labels = if (live_enabled) &running_captions.labels else &captions.labels,
                .board_name = if (live_enabled) running_board.entry.selector else board.entry.selector,
                .layer = if (live_enabled) live_frame.layer else if (draft_runtime.owner != null) draft_runtime.highest_layer else model.layer,
                .modifiers = if (live_enabled) live_frame.modifiers else if (draft_runtime.owner != null) @bitCast(draft_runtime.modifiers) else .{},
                .pressed = if (live_enabled) live_frame.pressed else held,
                .live = live_enabled,
                .active_layers = if (live_enabled) live_frame.active else null,
                .practicing = practicing,
                .assistance = practice.config.assistance,
                .targets = practice_taps,
                .holds = practice_holds,
            }, view.toolbar.light) catch |err| {
                view.report(err);
            };
            if (companion_fixture and (dvui.tagGet("companion.open_editor") != null or dvui.tagGet("companion.overlay") != null)) return error.InteractiveCompanionControl;
            switch (child.inner) {
                .os => |active| {
                    const id = Backend.c.SDL_GetWindowID(active.backend.window);
                    if (companion_view.applied_window != id) {
                        const requested = companion_view.overlay;
                        @import("companion-window").mode(active.backend.window, requested) catch |err| {
                            companion_view.unavailable = requested;
                            if (frame_limit != null) {
                                companion_view.overlay = false;
                                @import("companion-window").mode(active.backend.window, false) catch {};
                            } else {
                                view.report(err);
                                life.companion_visible = false;
                                _ = Backend.c.SDL_HideWindow(active.backend.window);
                            }
                        };
                        companion_view.applied_window = id;
                    }
                    // Native child windows can survive skipped draw frames. Sync
                    // visibility on every visible frame, not only initial mode setup.
                    if (companion_fixture or (frame_limit == null and !companion_view.unavailable)) _ = Backend.c.SDL_ShowWindow(active.backend.window);
                },
                .floating => {
                    companion_view.unavailable = companion_view.overlay;
                    if (frame_limit != null) companion_view.overlay = false else life.companion_visible = false;
                },
            }
        }
        tray.update(.{ .live_mode = live_enabled, .status = liveStatus(if (live) |*driver| driver else null, live_frame), .companion_visible = life.companion_visible });
        if (status_fixture and count % 4 == 0) {
            const activity = dvui.tagGet("editor.activity") orelse return error.ActivityRowMissing;
            const toolbar_bounds = dvui.tagGet("toolbar") orelse return error.ToolbarMissing;
            if (activity.rect.x < toolbar_bounds.rect.x or activity.rect.x + activity.rect.w > toolbar_bounds.rect.x + toolbar_bounds.rect.w + 1 or activity.rect.y + activity.rect.h > toolbar_bounds.rect.y + toolbar_bounds.rect.h + 1) return error.ActivityRowOverflow;
            if (toolbar_bounds.rect.x + toolbar_bounds.rect.w < dvui.windowRectPixels().w - 3) {
                std.log.err("Activity bounds: toolbar={any}, window={any}, natural={any}, scale={d}", .{ toolbar_bounds.rect, dvui.windowRectPixels(), dvui.windowRect(), window.content_scale });
                return error.ActivityToolbarGutter;
            }
            const message = dvui.tagGet("editor.activity.message") orelse return error.ActivityMessageMissing;
            const automatic = dvui.tagGet("firmware.auto_build") orelse return error.AutoBuildControlMissing;
            if (message.rect.x + message.rect.w > automatic.rect.x) return error.ActivityControlsOverlap;
            if (dvui.tagGet("system.status") != null) return error.SeparateStatusBarRetained;
            window.endRendering(.{ .manage_backend = false });
            try std.Io.Dir.cwd().createDirPath(init.io, ".zig-cache/editor-status");
            const surface = Backend.c.SDL_RenderReadPixels(native.renderer, null) orelse return error.StatusScreenshotRead;
            defer Backend.c.SDL_DestroySurface(surface);
            const file = try std.fmt.allocPrintSentinel(window.arena(), ".zig-cache/editor-status/{d}.bmp", .{status_scene}, 0);
            if (!Backend.c.SDL_SaveBMP(surface, file)) return error.StatusScreenshotSave;
        }
        if (rundown_fixture) {
            if (!practice_view.drawn_panel) return error.PracticePanelNotDrawn;
            if (dvui.tagGet(if (practice_view.review_open) "practice.review" else if (practice_view.help_open) "practice.help.title" else if (practice_view.curriculum_open) "practice.curriculum" else if (practice_view.diagnostics_open) "practice.diagnostics" else if (practice_view.progress_open) "practice.progress" else if (practice_view.data_open) "practice.data.title" else if (practice.completed != null) "practice.rundown" else "practice.word") == null) return error.PracticeRundownNotDrawn;
            if (practice.config.assistance == .hidden and !practice_view.help.requested and practice_view.drawn_keyboard) return error.HiddenPracticeKeyboardVisible;
        }
        if (rundown_fixture) {
            window.endRendering(.{ .manage_backend = false });
            if (!layout_preview or count % scene_frames == 0 or count % scene_frames == 3) {
                try std.Io.Dir.cwd().createDirPath(init.io, ".zig-cache/typing-practice-gallery");
                const surface = Backend.c.SDL_RenderReadPixels(native.renderer, null) orelse return error.PracticeScreenshotRead;
                defer Backend.c.SDL_DestroySurface(surface);
                const file = try std.fmt.allocPrintSentinel(window.arena(), ".zig-cache/typing-practice-gallery/{d}.bmp", .{count}, 0);
                if (!Backend.c.SDL_SaveBMP(surface, file)) return error.PracticeScreenshotSave;
            }
        }
        if (onboarding_fixture or catalog_fixture) {
            if (onboarding_fixture and (dvui.tagGet("firmware.build") != null or dvui.tagGet("firmware.inspect") != null or onboarding.selected)) return error.ImplicitOnboardingTargetExposed;
            if (onboarding_fixture and count <= 3 and dvui.tagGet("onboarding.create") == null) return error.OnboardingControlsMissing;
            if (onboarding_fixture) if (std.Io.Dir.cwd().statFile(init.io, std.mem.sliceTo(&onboarding.root, 0), .{})) |_| return error.OnboardingCreatedDestinationBeforeCommit else |err| if (err != error.FileNotFound) return err;
            window.endRendering(.{ .manage_backend = false });
            try std.Io.Dir.cwd().createDirPath(init.io, ".zig-cache/keyboard-onboarding-gallery");
            const surface = Backend.c.SDL_RenderReadPixels(native.renderer, null) orelse return error.OnboardingScreenshotRead;
            defer Backend.c.SDL_DestroySurface(surface);
            const file = try std.fmt.allocPrintSentinel(window.arena(), ".zig-cache/keyboard-onboarding-gallery/{s}-{d}.bmp", .{ if (onboarding_fixture) "wizard" else "catalog", count }, 0);
            if (!Backend.c.SDL_SaveBMP(surface, file)) return error.OnboardingScreenshotSave;
        }
        const delay = try window.end(.{ .manage_backend = frame_limit == null });
        ended = true;
        if (frame_limit != null) native.renderPresent();
        applyPractice(&draft_runtime, &practice, practice_input_effect, built_runner, practice_control_model, &view, now_us);
        if (leave_practice) {
            applyPractice(&draft_runtime, &practice, practice.pause(now_us), built_runner, &model, &view, now_us);
            practicing = false;
        } else if (practice_action) |action| {
            const effect = tutor.apply(&practice, &practice_view, action, .{ .now_us = now_us, .prepared_snapshot = if (built_runner) |runner| runner.record.inputs.project_digest else null }) catch |err| failed: {
                view.report(err);
                break :failed desktop.practice_controller.Effect{};
            };
            applyPractice(&draft_runtime, &practice, effect, built_runner, practice_control_model, &view, now_us);
        }
        // Dismissal only hides the panel. The session remains available from
        // the toolbar and cannot implicitly transfer or reset a selected UF2.
        if (close_flash_panel) flash_panel = false;
        if (pending_flash) |pending| {
            if (owner_generation != pending.generation or !std.mem.eql(u8, &pending.snapshot, &(try model.id()))) {
                pending_flash = null;
                advance_flash = false;
            }
        }
        if (advance_flash and built != null and pending_flash != null and flash == null and !jobs.busy() and artifactMatchesBundle(built.?)) {
            advance_flash = false;
            const pending = pending_flash.?;
            pending_flash = null;
            if (flash_tools) |tools| admit: {
                const plan = build_plan orelse break :admit;
                var request = desktop.build_worker.Request.capture(&model, plan.config, init.environ_map, built_generation) catch |err| {
                    view.report(err);
                    break :admit;
                };
                var cloned = jobs_api.flash_inputs.Tools.clone(gpa, tools.record) catch |err| {
                    request.deinit();
                    view.report(err);
                    break :admit;
                };
                const session = flash_session.Session.init(gpa, init.io, pending.snapshot, built_generation, built.?, request, built_tree, cloned) catch |err| {
                    request.deinit();
                    cloned.deinit();
                    view.report(err);
                    break :admit;
                };
                flash = session;
                flash_panel = true;
                flash_failure = null;
                advance_flash = true;
            }
        }
        if (flash) |*session| {
            if (advance_flash and try session.matchesModel(&model, built_generation)) {
                advance_flash = false;
                const stamp = now_us / 1000;
                session.prepare(stamp) catch |err| {
                    flash_failure = err;
                    view.report(err);
                };
                if (flash_failure == null) session.built(built.?, stamp) catch |err| {
                    flash_failure = err;
                    view.report(err);
                };
                if (flash_failure == null) freeze: {
                    const base = if (user_paths) |owned| owned.paths.cache else std.fs.path.dirname(built.?.uf2_path) orelse break :freeze;
                    var cache = std.Io.Dir.cwd().createDirPathOpen(init.io, base, .{}) catch |err| {
                        flash_failure = err;
                        view.report(err);
                        break :freeze;
                    };
                    defer cache.close(init.io);
                    var directory = cache.createDirPathOpen(init.io, "flash", .{}) catch |err| {
                        flash_failure = err;
                        view.report(err);
                        break :freeze;
                    };
                    defer directory.close(init.io);
                    const path = directory.realPathFileAlloc(init.io, ".", gpa) catch |err| {
                        flash_failure = err;
                        view.report(err);
                        break :freeze;
                    };
                    defer gpa.free(path);
                    session.freeze(built.?, directory, path, stamp) catch |err| {
                        flash_failure = err;
                        view.report(err);
                    };
                }
                if (flash_failure == null) session.selectUniqueBootsel() catch |err| {
                    flash_failure = err;
                    view.report(err);
                };
                if (flash_failure == null) {
                    // The initial Flash click is the sole user authorization. The
                    // internal selection and frozen hash are bound before HID or
                    // picotool can run; no further panel button is required.
                    const shown = session.view(if (live) |*driver| (if (driver.connected and driver.session.hasCoherentState()) driver.session.token else null) else null);
                    const bound = flashSnapshot(session, shown, built_generation);
                    if (!shown.can_confirm or !flash_gate.confirm(bound, bound)) {
                        flash_failure = error.StaleFlashRequest;
                        view.report(error.StaleFlashRequest);
                    } else retained_flash_view = shown;
                }
            }
        }
        // All admission and frozen UF2 copying happen only after the displayed frame.
        if (flash_intent) |intent| if (flash) |*session| {
            const action = std.meta.activeTag(intent);
            switch (action) {
                .prepare => session.prepare(now_us / 1000) catch |err| {
                    flash_failure = err;
                    view.report(err);
                },
                .build => session.built(built.?, now_us / 1000) catch |err| {
                    flash_failure = err;
                    view.report(err);
                },
                .freeze => freeze: {
                    const base = if (user_paths) |owned| owned.paths.cache else std.fs.path.dirname(built.?.uf2_path) orelse return error.FlashCacheUnavailable;
                    var cache = std.Io.Dir.cwd().createDirPathOpen(init.io, base, .{}) catch |err| {
                        flash_failure = err;
                        view.report(err);
                        break :freeze;
                    };
                    defer cache.close(init.io);
                    var flash_cache = cache.createDirPathOpen(init.io, "flash", .{}) catch |err| {
                        flash_failure = err;
                        view.report(err);
                        break :freeze;
                    };
                    defer flash_cache.close(init.io);
                    const flash_cache_path = flash_cache.realPathFileAlloc(init.io, ".", gpa) catch |err| {
                        flash_failure = err;
                        view.report(err);
                        break :freeze;
                    };
                    defer gpa.free(flash_cache_path);
                    session.freeze(built.?, flash_cache, flash_cache_path, now_us / 1000) catch |err| {
                        flash_failure = err;
                        view.report(err);
                    };
                },
                .select => session.selectUniqueBootsel() catch |err| {
                    flash_failure = err;
                    view.report(err);
                },
                .confirm => confirm: {
                    const shown = flash_rendered orelse return error.FlashViewMissing;
                    const current_view = session.view(shown.previous_session_token);
                    const rendered_snapshot = flashSnapshot(session, shown, built_generation);
                    const current_snapshot = flashSnapshot(session, current_view, built_generation);
                    if (!shown.can_confirm or !current_view.can_confirm or !try session.matchesModel(&model, built_generation) or
                        !flash_gate.confirm(rendered_snapshot, current_snapshot))
                    {
                        flash_gate.cancel();
                        view.report(error.StaleFlashRequest);
                        break :confirm;
                    }
                    retained_flash_view = shown;
                },
                .cancel => {
                    flash_gate.cancel();
                    retained_flash_view = null;
                    _ = session.cancel() catch |err| {
                        flash_failure = err;
                        view.report(err);
                    };
                },
                .reset => {
                    flash_gate.cancel();
                    retained_flash_view = null;
                    session.deinit();
                    flash = null;
                    flash_panel = false;
                },
            }
        };
        switch (onboarding_action) {
            .none => {},
            .cancel => onboarding.reset(),
            .cancel_tutor => {
                if (jobs.runner) |job| job.worker.destroy();
                jobs.runner = null;
            },
            .editor => if (onboarding.selected) {
                if (jobs.runner) |job| job.worker.destroy();
                jobs.runner = null;
                onboarding.active = false;
            },
            .tutor => prepare_tutor: {
                if (!onboarding.selected or jobs.busy()) break :prepare_tutor;
                const plan = build_plan orelse {
                    onboarding.report(error.MissingApplicationBundle);
                    break :prepare_tutor;
                };
                var config = plan.config;
                config.request.native_only = true;
                const next_job = try std.math.add(u64, job_generation, 1);
                jobs.runner = startBuild(gpa, init.io, &model, config, init.environ_map, next_job, owner_generation) catch |err| {
                    onboarding.report(err);
                    break :prepare_tutor;
                };
                job_generation = next_job;
            },
            .choose_source, .choose_location, .choose_open => choose: {
                const target: desktop.folder_selection.Target = switch (onboarding_action) {
                    .choose_source => .onboarding_source,
                    .choose_location => .onboarding_location,
                    .choose_open => .onboarding_open,
                    else => unreachable,
                };
                const ticket = chooser.begin(owner_generation, try model.id(), target) catch |err| {
                    onboarding.report(err);
                    break :choose;
                };
                onboarding_chooser_generation = onboarding.generation;
                dialog.startCorrelated(native.window, ticket.generation) catch |err| {
                    _ = chooser.discard(ticket);
                    onboarding.report(err);
                };
            },
            else => prepare_onboarding: {
                if (jobs.busy()) {
                    onboarding.report(error.ProjectOperationAlreadyRunning);
                    break :prepare_onboarding;
                }
                if ((onboarding_action == .create or onboarding_action == .open or onboarding_action == .add_existing) and (model.dirty() or owner.inspector.dirty() or owner.pending != null) and !onboarding.discard) {
                    onboarding.report(error.UnsavedProjectChanges);
                    break :prepare_onboarding;
                }
                const owned = user_paths orelse {
                    onboarding.report(error.UserPathsUnavailable);
                    break :prepare_onboarding;
                };
                if (onboarding_action == .create or onboarding_action == .add_existing) onboarding.reloadCollection(gpa, init.io) catch |err| {
                    onboarding.report(err);
                    break :prepare_onboarding;
                };
                var scratch: std.heap.ArenaAllocator = .init(gpa);
                defer scratch.deinit();
                const a = scratch.allocator();
                var toolchain: desktop.onboarding.importer.Toolchain = .{ .compiler = "", .build_root = "", .cache = try std.fs.path.join(a, &.{ owned.paths.cache, "imports" }) };
                if (resources) |value| {
                    toolchain.compiler = try value.path(a, "toolchain/zig" ++ if (@import("builtin").os.tag == .windows) ".exe" else "");
                    toolchain.build_root = try value.path(a, "build");
                    toolchain.packages = try value.path(a, "dependencies/p");
                    toolchain.payload_executable = value.executable;
                    toolchain.payload_root = value.root;
                } else if (onboarding_action == .analyze) {
                    onboarding.report(error.MissingApplicationBundle);
                    break :prepare_onboarding;
                }
                onboarding.start(gpa, init.io, init.environ_map, toolchain, onboarding_action, owner_generation) catch |err| onboarding.report(err);
            },
        }
        // Filesystem replacement and native chooser starts run after retained draw.
        switch (rendered) {
            .paths => |action| switch (action.kind) {
                .cancel => {
                    jobs.cancel();
                },
                .choose_project, .choose_export => {
                    const ticket = chooser.begin(owner_generation, action.snapshot, if (action.kind == .choose_project) .project else .export_directory) catch |err| {
                        view.report(err);
                        continue;
                    };
                    dialog.startCorrelated(native.window, ticket.generation) catch |err| {
                        _ = chooser.discard(ticket);
                        view.report(err);
                    };
                },
                else => {
                    if (jobs.busy()) {
                        view.report(error.ProjectOperationAlreadyRunning);
                        continue;
                    }
                    const next_job = try std.math.add(u64, job_generation, 1);
                    jobs.file = startFile(gpa, init.io, &view, &model, action, next_job, owner_generation) catch |err| {
                        view.report(err);
                        continue;
                    };
                    job_generation = next_job;
                },
            },
            .callback => |action| {
                if (action.kind == .cancel) {
                    jobs.cancel();
                    continue;
                }
                if (jobs.busy()) {
                    view.report(error.ProjectOperationAlreadyRunning);
                    continue;
                }
                if (action.kind == .choose_root) {
                    const ticket = chooser.begin(owner_generation, action.snapshot, .callback_source) catch |err| {
                        view.report(err);
                        continue;
                    };
                    dialog.startCorrelated(native.window, ticket.generation) catch |err| {
                        _ = chooser.discard(ticket);
                        view.report(err);
                    };
                } else {
                    const next_job = try std.math.add(u64, job_generation, 1);
                    var request = captureSource(&view, &model, action) catch |err| {
                        view.report(err);
                        continue;
                    };
                    const worker = desktop.source_worker.Owner.create(gpa, init.io, &request, next_job) catch |err| {
                        request.deinit();
                        view.report(err);
                        continue;
                    };
                    jobs.source = .{ .worker = worker, .action = action, .editor_generation = owner_generation };
                    job_generation = next_job;
                }
            },
            .effect => |effect| switch (effect) {
                .save, .save_close => |captured| {
                    captured.validate(&model) catch |err| {
                        view.report(err);
                        continue;
                    };
                    if (jobs.busy()) {
                        view.report(error.ProjectOperationAlreadyRunning);
                        continue;
                    }
                    const next_job = try std.math.add(u64, job_generation, 1);
                    jobs.file = startFile(gpa, init.io, &view, &model, view.paths.action(try model.id(), .save), next_job, owner_generation) catch |err| {
                        view.report(err);
                        view.modal = .paths;
                        continue;
                    };
                    job_generation = next_job;
                    if (effect == .save_close) jobs.file.?.close = captured;
                },
                .open => |target| {
                    if (target == .practice) {
                        practicing = true;
                        view.diagnostic = @splat(0);
                    } else if (target == .keyboards) {
                        onboarding.reset();
                        onboarding.reloadCollection(gpa, init.io) catch |err| onboarding.report(err);
                    } else view.report(error.NavigationNotConnected);
                },
                .profile => |captured| {
                    if (jobs.busy()) {
                        view.report(error.ProjectOperationAlreadyRunning);
                        continue;
                    }
                    captured.validate(&model) catch |err| {
                        view.report(err);
                        continue;
                    };
                    const owned = user_paths orelse {
                        view.report(error.UserPathsUnavailable);
                        continue;
                    };
                    const id = captured.intent.profile;
                    const key = desktop.profile_projects.Key{ .board_id = model.document().board_id, .profile_id = id };
                    const target = if (registry.path(key)) |associated| try gpa.dupe(u8, associated) else try std.fs.path.join(gpa, &.{ owned.paths.projects, std.mem.sliceTo(&id, 0) });
                    defer gpa.free(target);
                    const next_job = try std.math.add(u64, job_generation, 1);
                    var request = desktop.profile_switch.Request.capture(&model, id, target) catch |err| {
                        view.report(err);
                        continue;
                    };
                    const worker = desktop.profile_switch.Worker.create(gpa, init.io, &request, next_job) catch |err| {
                        request.deinit();
                        view.report(err);
                        continue;
                    };
                    jobs.profile = .{ .worker = worker, .action = captured, .editor_generation = owner_generation, .previous_path = view.paths.project };
                    job_generation = next_job;
                },
                .build => |captured| {
                    if (jobs.busy()) {
                        view.report(error.ProjectOperationAlreadyRunning);
                        continue;
                    }
                    captured.validate(&model) catch |err| {
                        view.report(err);
                        continue;
                    };
                    const plan = build_plan orelse {
                        view.report(error.MissingApplicationBundle);
                        continue;
                    };
                    const next_job = try std.math.add(u64, job_generation, 1);
                    const job = startBuild(gpa, init.io, &model, plan.config, init.environ_map, next_job, owner_generation) catch |err| {
                        view.report(err);
                        continue;
                    };
                    jobs.build = job;
                    job_generation = next_job;
                    build_scheduler.manual(try model.id());
                    view.diagnostic = @splat(0);
                },
                .flash => |captured| {
                    try acceptFlashEffect(&model, captured);
                    if (flash_failure != null and flash == null) {
                        flash_failure = null;
                        flash_panel = false;
                    }
                    if (flash) |*previous| {
                        // The second click authorizes a new operation only after a
                        // terminal outcome; an active transfer is never restarted.
                        switch (previous.owner.phase) {
                            .ready, .failed, .cancelled, .reconnect_timeout, .stale => {
                                previous.deinit();
                                flash = null;
                                flash_gate.cancel();
                                retained_flash_view = null;
                                flash_failure = null;
                                flash_details_open = false;
                            },
                            else => {
                                flash_panel = true;
                                continue;
                            },
                        }
                    }
                    // The accepted build manifest alone is not a flash-tools receipt.
                    // Do not open a panel that could imply a verified target or offer
                    // confirmation until the application can capture and retain the
                    // wrapper/picotool provenance and a genuine selected device.
                    if (built == null or !std.mem.eql(u8, &built.?.inputs.project_digest, &(try model.id())) or !artifactMatchesBundle(built.?)) {
                        if (jobs.busy() or !can_build or build_plan == null or flash_tools == null) {
                            view.report(error.FreshFirmwareBuildRequired);
                            continue;
                        }
                        const next_job = try std.math.add(u64, job_generation, 1);
                        jobs.build = startBuild(gpa, init.io, &model, build_plan.?.config, init.environ_map, next_job, owner_generation) catch |err| {
                            view.report(err);
                            continue;
                        };
                        job_generation = next_job;
                        pending_flash = .{ .snapshot = try model.id(), .generation = owner_generation };
                        build_scheduler.manual(try model.id());
                        flash_panel = true;
                    } else if (build_plan == null or
                        !std.mem.eql(u8, &build_plan.?.config.board_id, &model.board.id) or
                        !std.mem.eql(u8, build_plan.?.config.build_board, board.entry.selector))
                    {
                        view.report(error.FlashBuildConfigurationChanged);
                    } else if (flash_tools) |tools| {
                        if (built_generation == 0 or jobs.busy()) {
                            view.report(error.FlashAlreadyInProgress);
                            continue;
                        }
                        var request = desktop.build_worker.Request.capture(&model, build_plan.?.config, init.environ_map, built_generation) catch |err| {
                            view.report(err);
                            continue;
                        };
                        var cloned = jobs_api.flash_inputs.Tools.clone(gpa, tools.record) catch |err| {
                            request.deinit();
                            view.report(err);
                            continue;
                        };
                        const session = flash_session.Session.init(gpa, init.io, try model.id(), built_generation, built.?, request, built_tree, cloned) catch |err| {
                            request.deinit();
                            cloned.deinit();
                            view.report(err);
                            continue;
                        };
                        if (flash) |*old| old.deinit();
                        flash = session;
                        flash_panel = true;
                        flash_failure = null;
                        advance_flash = true;
                        view.diagnostic = @splat(0);
                    } else {
                        view.report(error.FlashToolsReceiptRequired);
                    }
                },
                else => {},
            },
        }
        if (events.close) {
            events.close = false;
            view.modal = .none;
            view.combo = null;
            view.encoders = null;
            practicing = false;
            applyPractice(&draft_runtime, &practice, practice.pause(now_us), built_runner, &model, &view, now_us);
            if (life.resident) {
                life.editor_visible = false;
                _ = Backend.c.SDL_HideWindow(native.window);
            } else events.quit = true;
        }
        if (events.quit) {
            events.quit = false;
            view.modal = .none;
            view.combo = null;
            view.encoders = null;
            practicing = false;
            applyPractice(&draft_runtime, &practice, practice.pause(now_us), built_runner, &model, &view, now_us);
            life.action(.quit);
            _ = owner.request(&model, try desktop.editor_dispatch.Request.capture(&model, .close)) catch |err| failed: {
                view.report(err);
                break :failed desktop.editor_dispatch.Effect.none;
            };
            if (!owner.closed) {
                life.editor_visible = true;
                _ = Backend.c.SDL_ShowWindow(native.window);
            }
        }
        build_scheduler.observe(try model.id(), now_us / 1000);
        if (build_scheduler.take(now_us / 1000, onboarding.active or !onboarding.selected or !view.toolbar.auto_build or build_plan == null or !can_build or jobs.busy() or pending_flash != null or desktop.flash_presenter.blocksAutoBuild(if (flash) |session| session.owner.phase else null) or practicing or view.modal != .none or owner.closed or owner.close_requested != null or owner.pending != null or owner.inspector.dirty())) {
            const next_job = try std.math.add(u64, job_generation, 1);
            jobs.build = startBuild(gpa, init.io, &model, build_plan.?.config, init.environ_map, next_job, owner_generation) catch |err| failed: {
                view.report(err);
                break :failed null;
            };
            if (jobs.build != null) {
                job_generation = next_job;
                if (flash) |*previous| previous.deinit();
                flash = null;
                flash_gate.cancel();
                retained_flash_view = null;
                flash_failure = null;
                flash_panel = false;
                view.diagnostic = @splat(0);
            }
        }
        // Never enter SDL's potentially unbounded wait after accepting Quit.
        if (owner.closed) {
            if (companion_fixture and (count != 9 or !life.quit_requested)) return error.ResidentCleanQuitFailed;
            break;
        }
        if (frame_limit == null) interrupted = try native.waitEventTimeout(@min(window.waitTime(delay), desktop.live_keyboard.waitBudget(live_enabled, jobs.busy() or draft_runtime.owner != null or practice_history.worker != null, false)));
        if (draft_fixture or build_fixture) try std.Io.sleep(init.io, .fromMilliseconds(10), .awake);
    }
    if (practice_fixture and (practice.session.len != 1 or practice.session.matched() != 1 or practice.session.state != .paused)) return error.PracticeTextRoutingFailed;
    if ((draft_fixture or build_fixture) and (draft_phase != .paused or practice.session.len != 1 or practice.session.matched() != 1 or practice.session.state != .paused or draft_runtime.owner != null)) return error.DraftProcessorRoutingFailed;
    if (build_fixture and !build_checked) return error.ManagedEditorBuildIncomplete;
    if (companion_fixture and (retained_fixture == null or !std.mem.eql(u8, &retained_fixture.?, &(try model.id())))) return error.ResidentDraftRetentionFailed;
    if (companion_fixture and !owner.closed) return error.ResidentCleanQuitFailed;
    if (native_tray_fixture and !tray.installed) return error.NativeTrayLifecycleFailed;
}
