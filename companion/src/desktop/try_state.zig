const std = @import("std");

pub const MainView = enum { editor, try_it_out };
pub const Mode = enum { free_typing, typing_test };
pub const Owner = enum { none, free_typing, typing_test };
pub const Preparation = enum { idle, preparing, ready, failed };
pub const Ticket = struct { generation: u64, sequence: u64 };

/// Pure navigation and asynchronous ownership rules. Document history and text
/// buffers belong to the caller; navigation never modifies either.
pub const State = struct {
    view: MainView = .editor,
    mode: Mode = .free_typing,
    focused: bool = false,
    owner: Owner = .none,
    preparation: Preparation = .idle,
    generation: u64 = 0,
    sequence: u64 = 0,
    pending: ?Ticket = null,

    pub fn navigate(self: *State, view: MainView, pending_edits: bool) bool {
        if (view == self.view) return true;
        if (pending_edits) return false;
        self.release();
        self.view = view;
        return true;
    }

    pub fn chooseMode(self: *State, mode: Mode) void {
        if (mode == self.mode) return;
        self.release();
        self.mode = mode;
    }

    pub fn focus(self: *State, focused: bool) void {
        if (!focused) self.release();
        self.focused = focused and self.view == .try_it_out;
        if (self.focused and self.mode == .free_typing and self.preparation == .ready) self.owner = .free_typing;
    }

    pub fn release(self: *State) void {
        self.focused = false;
        self.owner = .none;
        self.pending = null;
        if (self.preparation == .preparing) self.preparation = .idle;
    }

    pub fn invalidate(self: *State) void {
        self.release();
        self.generation +%= 1;
        self.preparation = .idle;
    }

    pub fn prepare(self: *State) ?Ticket {
        if (self.view != .try_it_out or
            self.mode != .free_typing or
            !self.focused or
            self.preparation != .idle) return null;
        self.sequence +%= 1;
        const ticket: Ticket = .{ .generation = self.generation, .sequence = self.sequence };
        self.pending = ticket;
        self.preparation = .preparing;
        return ticket;
    }

    pub fn complete(self: *State, ticket: Ticket, success: bool) bool {
        const pending = self.pending orelse return false;
        if (!std.meta.eql(ticket, pending) or
            ticket.generation != self.generation or
            self.view != .try_it_out or
            self.mode != .free_typing or
            !self.focused) return false;
        self.pending = null;
        self.preparation = if (success) .ready else .failed;
        self.owner = if (success) .free_typing else .none;
        return true;
    }

    pub fn retry(self: *State) void {
        if (self.preparation == .failed) self.preparation = .idle;
    }

    /// Scoring starts only through the deliberate test controls.
    pub fn startTest(self: *State) bool {
        if (self.view != .try_it_out or self.mode != .typing_test or !self.focused) return false;
        self.owner = .typing_test;
        return true;
    }
};

test "pending edits block navigation and modes survive main tab changes" {
    var state: State = .{};
    try std.testing.expect(!state.navigate(.try_it_out, true));
    try std.testing.expectEqual(MainView.editor, state.view);
    try std.testing.expect(state.navigate(.try_it_out, false));
    state.chooseMode(.typing_test);
    state.focus(true);
    try std.testing.expectEqual(Owner.none, state.owner);
    try std.testing.expect(state.startTest());
    try std.testing.expect(state.navigate(.editor, false));
    try std.testing.expectEqual(Owner.none, state.owner);
    try std.testing.expect(state.navigate(.try_it_out, false));
    state.focus(true);
    try std.testing.expectEqual(Mode.typing_test, state.mode);
    try std.testing.expectEqual(Owner.none, state.owner);
}

test "preparation rejects departed changed and superseded snapshots" {
    var state: State = .{};
    _ = state.navigate(.try_it_out, false);
    state.focus(true);
    const departed = state.prepare().?;
    state.focus(false);
    try std.testing.expect(!state.complete(departed, true));
    state.focus(true);
    const replaced = state.prepare().?;
    state.invalidate();
    state.focus(true);
    const current = state.prepare().?;
    try std.testing.expect(!state.complete(replaced, true));
    try std.testing.expect(state.complete(current, true));
    try std.testing.expectEqual(Owner.free_typing, state.owner);
    state.chooseMode(.typing_test);
    try std.testing.expectEqual(Owner.none, state.owner);
    try std.testing.expect(!state.complete(current, true));
}

test "failed preparation waits for explicit retry" {
    var state: State = .{};
    _ = state.navigate(.try_it_out, false);
    state.focus(true);
    try std.testing.expect(state.complete(state.prepare().?, false));
    try std.testing.expect(state.prepare() == null);
    state.focus(false);
    state.focus(true);
    try std.testing.expect(state.prepare() == null);
    state.retry();
    try std.testing.expect(state.complete(state.prepare().?, true));
}
