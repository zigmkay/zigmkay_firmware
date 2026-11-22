//! The live HID session and the saved project it is bound to.
//!
//! The binding is frozen independently of the editor: unsaved edits never
//! relabel the running keyboard. Rebinding prepares every replacement first and
//! only then swaps, so a failure keeps the accepted binding.
const std = @import("std");
const Backend = @import("dvui_backend");
const desktop = @import("desktop-core");
const project = @import("project");
const boards = @import("catalog-project");
const Captions = @import("Captions.zig");

const LiveKeyboard = @This();

pub const Driver = @import("live-adapter").Driver(@import("native-hid").Native(Backend.c));
pub const Identity = @FieldType(@FieldType(Driver, "session"), "expected");
const Status = desktop.tray_lifecycle.Status;

model: desktop.model.Model,
captions: Captions,
board: boards.OwnedBoard,
identity: ?Identity,
driver: ?Driver,
seed: u32,
presenter: desktop.live_keyboard.Presenter = .{},
visibility: desktop.live_keyboard.Visibility,
pressed: [128]bool = @splat(false),
frame: desktop.live_keyboard.Frame = .{},
last_status: ?Status = null,

/// The captions and board of a project prepared for binding. After `rebind`
/// or `swap` it holds those of the previous binding, which the caller
/// releases with `deinit`.
pub const Binding = struct {
    captions: Captions,
    board: boards.OwnedBoard,

    pub fn deinit(self: *Binding) void {
        self.board.deinit();
        self.captions.deinit();
    }
};

pub fn deinit(self: *LiveKeyboard) void {
    if (self.driver) |*driver| driver.disconnect(driver.transport.now());
    self.board.deinit();
    self.captions.deinit();
    self.model.deinit();
}

/// Polls the session and refreshes the presented frame. Returns whether the
/// overlay gesture asks for the companion, or null without a session.
pub fn poll(self: *LiveKeyboard) !?bool {
    const driver = if (self.driver) |*value| value else return null;
    driver.poll(driver.transport.now());
    self.frame = try self.presenter.select(&self.captions.labels, self.identity, &driver.session, &self.pressed);
    const current = self.status();
    if (self.last_status == null or self.last_status.? != current) {
        std.log.info("Keyboard connection: {t}", .{current});
        self.last_status = current;
    }
    var signals: [desktop.live_keyboard.max_signals]desktop.live_keyboard.Signal = undefined;
    const received = desktop.live_keyboard.fromKeyboard(&signals, driver.signal_events[0..driver.signal_event_count]);
    return self.visibility.updateAt(self.frame, received, driver.transport.now());
}

pub fn status(self: *const LiveKeyboard) Status {
    return statusOf(if (self.driver) |*driver| driver else null, self.frame);
}

pub fn statusOf(driver: ?*const Driver, frame: desktop.live_keyboard.Frame) Status {
    const active = driver orelse return .offline;
    if (active.session.phase == .incompatible) return .incompatible;
    if (!active.connected) return if (active.status == .searching) .connecting else .disconnected;
    if (frame.labels != null and !frame.stale) return .live;
    // Only a session that already presented verified labels can become stale;
    // until the first hello and state arrive, the handshake is still connecting.
    return if (active.session.token == 0 or frame.labels == null) .connecting else .stale;
}

/// Whether the frame shows verified labels of the running keyboard.
pub fn verified(self: *const LiveKeyboard) bool {
    return self.frame.labels != null and !self.frame.stale;
}

/// The token of a connected session with coherent state.
pub fn coherentToken(self: *const LiveKeyboard) ?u32 {
    const driver = if (self.driver) |*value| value else return null;
    return if (driver.connected and driver.session.hasCoherentState()) driver.session.token else null;
}

/// Exchanges the bound project with `model` and `binding`.
pub fn swap(self: *LiveKeyboard, model: *desktop.model.Model, binding: *Binding) void {
    std.mem.swap(desktop.model.Model, &self.model, model);
    std.mem.swap(Captions, &self.captions, &binding.captions);
    std.mem.swap(boards.OwnedBoard, &self.board, &binding.board);
}

/// Replaces the session and the bound project. Nothing of the previous
/// binding stays visible until the new session verifies itself.
pub fn rebind(
    self: *LiveKeyboard,
    model: *desktop.model.Model,
    binding: *Binding,
    identity: Identity,
    driver: Driver,
    life: *desktop.tray_lifecycle.Lifecycle,
) void {
    if (self.driver) |*old| old.disconnect(old.transport.now());
    self.driver = driver;
    self.swap(model, binding);
    self.identity = identity;
    resetPresentation(&self.presenter, &self.visibility, &self.frame, &self.pressed, life);
}

pub fn resetPresentation(
    presenter: *desktop.live_keyboard.Presenter,
    visibility: *desktop.live_keyboard.Visibility,
    frame: *desktop.live_keyboard.Frame,
    pressed: []bool,
    life: *desktop.tray_lifecycle.Lifecycle,
) void {
    presenter.invalidate();
    visibility.* = .{ .mode = visibility.mode };
    frame.* = .{};
    @memset(pressed, false);
    life.companion_visible = false;
}

/// Reads the saved project at the absolute `path`, independently of the editor.
pub fn loadSaved(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !desktop.model.Model {
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
