//! `--offline-source-refresh-frames`: the live binding keeps the saved
//! project while the editor holds an unsaved draft, a replacement binding
//! stays unverified until it negotiates, and a host input source change
//! relabels the running project atomically.
const std = @import("std");
const desktop = @import("desktop-core");
const project = @import("project");
const App = @import("App.zig");
const Captions = @import("Captions.zig");
const LiveKeyboard = @import("LiveKeyboard.zig");

pub fn run(app: *App) !void {
    if (app.count == 2) try verify(app);
    if (app.count == 3 and (app.captions.revision != app.revision or app.live.captions.revision != app.revision))
        return error.SourceRefreshNotApplied;
}

fn verify(app: *App) !void {
    const gpa = app.gpa;
    const running = &app.live.model;
    const frozen = try running.id();
    const cache_path = try std.fmt.allocPrint(gpa, ".zig-cache/live-binding-{d}", .{app.native.nanoTime()});
    defer gpa.free(cache_path);
    defer std.Io.Dir.cwd().deleteTree(app.io, cache_path) catch {};
    var directory = try std.Io.Dir.cwd().createDirPathOpen(app.io, cache_path, .{});
    defer directory.close(app.io);
    try project.snapshot.save(gpa, app.io, directory, running.current.snapshot, running.board);
    var absolute_buffer: [4096]u8 = undefined;
    const saved_path = absolute_buffer[0..try directory.realPath(app.io, &absolute_buffer)];

    const key = try letterKey(app);
    const saved_label = try gpa.dupe(u8, app.live.captions.labels.lookup(0, key, .{}).label.?);
    defer gpa.free(saved_label);
    var replacement = try checkDraftIsolation(app, directory, saved_path, key, frozen);
    defer replacement.deinit();
    try checkUnverifiedReplacement(app, &replacement);
    try checkFailedLoad(app, directory, saved_path, frozen);
    try checkCaptionRefresh(app, key, saved_label, frozen);
}

/// The first key of the base layer that types a labelled letter.
fn letterKey(app: *App) !usize {
    for (app.live.model.document().layers[0].actions, 0..) |action, index| {
        const value = action orelse continue;
        const tap = switch (value) {
            .tap_only => |tap| tap,
            else => continue,
        };
        const press = tap.key_press orelse continue;
        if (press.tap_keycode >= 4 and press.tap_keycode <= 29 and app.live.captions.labels.lookup(0, index, .{}).label != null)
            return index;
    }
    return error.NoFixtureLetter;
}

/// An unsaved editor draft never reaches the binding loaded from disk, and a
/// deliberately saved replacement leaves the accepted binding alone.
fn checkDraftIsolation(
    app: *App,
    directory: std.Io.Dir,
    saved_path: []const u8,
    key: usize,
    frozen: [32]u8,
) !desktop.model.Model {
    const gpa = app.gpa;
    app.model.select(key, false);
    try app.model.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 30 } } });
    try app.model.rename("Unsaved editor draft");
    if (std.mem.eql(u8, &frozen, &(try app.model.id()))) return error.EditorFixtureNotChanged;
    var saved = try LiveKeyboard.loadSaved(gpa, app.io, saved_path);
    defer saved.deinit();
    if (!std.mem.eql(u8, &frozen, &(try saved.id())) or std.mem.eql(u8, &(try app.model.id()), &(try saved.id())))
        return error.LiveBindingUsedUnsavedDraft;
    try saved.rename("Saved replacement binding");
    saved.select(key, false);
    try saved.apply(.{ .tap_only = .{ .key_press = .{ .tap_keycode = 5 } } });
    try project.snapshot.save(gpa, app.io, directory, saved.current.snapshot, saved.board);
    var replacement = try LiveKeyboard.loadSaved(gpa, app.io, saved_path);
    errdefer replacement.deinit();
    if (!std.mem.eql(u8, &(try saved.id()), &(try replacement.id())) or !std.mem.eql(u8, &frozen, &(try app.live.model.id())))
        return error.LiveReplacementChangedAcceptedBinding;
    return replacement;
}

/// A replacement session shows nothing until it negotiates, and rebinding
/// clears everything the previous binding presented.
fn checkUnverifiedReplacement(app: *App, replacement: *const desktop.model.Model) !void {
    const gpa = app.gpa;
    const identity = try project.snapshot.identity(gpa, replacement.current.snapshot, replacement.board);
    var driver = try LiveKeyboard.Driver.init(.{ .io = app.io }, identity, 123, null);
    if (driver.connected or driver.session.token != 0 or !std.meta.eql(identity, driver.session.expected))
        return error.LiveRebindSkippedNegotiation;
    var captions = try Captions.init(gpa, replacement, &app.translator, "Offline replacement", app.revision);
    defer captions.deinit();
    var presenter = desktop.live_keyboard.Presenter{};
    var pressed: [128]bool = @splat(false);
    const unverified = try presenter.select(&captions.labels, identity, &driver.session, &pressed);
    if (unverified.labels != null or !unverified.stale or LiveKeyboard.statusOf(&driver, unverified) != .connecting)
        return error.UnverifiedReplacementVisible;

    var visibility = desktop.live_keyboard.Visibility{ .mode = .hold, .latched = true, .held = true, .down = true };
    var frame = desktop.live_keyboard.Frame{ .labels = &app.live.captions.labels, .stale = false };
    var life = desktop.tray_lifecycle.Lifecycle{ .companion_visible = true };
    presenter.accepted_identity = identity;
    @memset(&pressed, true);
    LiveKeyboard.resetPresentation(&presenter, &visibility, &frame, &pressed, &life);
    if (presenter.accepted_identity != null or visibility.held or visibility.latched or visibility.down or
        visibility.mode != .hold or frame.labels != null or life.companion_visible or
        std.mem.indexOfScalar(bool, &pressed, true) != null) return error.LiveRebindRetainedOldPresentation;
}

/// An invalid saved project is refused without touching the accepted binding.
fn checkFailedLoad(app: *App, directory: std.Io.Dir, saved_path: []const u8, frozen: [32]u8) !void {
    const accepted_entries = app.live.captions.labels.entries.ptr;
    try directory.writeFile(app.io, .{ .sub_path = "project.zon", .data = "not a project" });
    if (LiveKeyboard.loadSaved(app.gpa, app.io, saved_path)) |loaded| {
        var unexpected = loaded;
        unexpected.deinit();
        return error.InvalidSavedBindingAccepted;
    } else |_| {}
    if (!std.mem.eql(u8, &frozen, &(try app.live.model.id())) or app.live.captions.labels.entries.ptr != accepted_entries)
        return error.FailedBindingDiscardedAcceptedProject;
}

/// Running captions are rebuilt once per source revision, keep their old
/// labels when the rebuild fails, and never take the editor draft.
fn checkCaptionRefresh(app: *App, key: usize, saved_label: []const u8, frozen: [32]u8) !void {
    const captions = &app.live.captions;
    const running = &app.live.model;
    const old_entries = captions.labels.entries.ptr;
    try captions.refresh(app.gpa, running, &app.translator, "Offline live fixture", app.revision);
    if (captions.labels.entries.ptr != old_entries) return error.SameRevisionRebuiltCaptions;
    var empty_storage: [0]u8 = .{};
    var failing: std.heap.FixedBufferAllocator = .init(&empty_storage);
    if (captions.refresh(failing.allocator(), running, &app.translator, "Offline live fixture", app.revision + 1)) |_| {
        return error.FailedAllocationUnexpectedlySucceeded;
    } else |err| if (err != error.OutOfMemory) return err;
    if (captions.labels.entries.ptr != old_entries or captions.revision != app.revision or
        !std.mem.eql(u8, captions.labels.lookup(0, key, .{}).label orelse "", saved_label)) return error.FailedRefreshDiscardedCaptions;

    app.translator.alternate = true;
    app.revision = try std.math.add(u64, app.revision, 1);
    try captions.refresh(app.gpa, running, &app.translator, "Offline live fixture", app.revision);
    const translated = captions.labels.lookup(0, key, .{}).label orelse return error.MissingTranslatedLetter;
    if (std.mem.eql(u8, translated, saved_label) or
        !std.mem.eql(u8, &frozen, &(try running.id())) or
        !std.mem.eql(u8, &captions.snapshot, &frozen) or
        std.mem.eql(u8, &captions.snapshot, &(try app.model.id())) or
        captions.revision != app.revision) return error.RunningSourceRefreshChangedProject;
}
