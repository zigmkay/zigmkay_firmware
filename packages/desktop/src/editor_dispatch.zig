//! UI-thread pending-edit ownership. External effects are returned, never started.
const std = @import("std");
const p = @import("project");
const Model = @import("model.zig").Model;
const editing = @import("inspector_session.zig");
const inspector_action = @import("inspector_action.zig");
const keys = @import("key_selection.zig");
const layers = @import("layer_editor.zig");
const chords = @import("chord_action.zig");
pub const Open = enum { paths, combo, callback, editor, practice, encoders, keyboards };
pub const Intent = union(enum) {
    select: struct { index: usize, extend: bool },
    layer: struct { kind: layers.Kind, target: p.LayerId, name: [129]u8 },
    chord: struct { chord: @import("assignment.zig").Chord, held: bool, target: ?usize },
    undo,
    redo,
    copy,
    paste,
    save,
    build,
    flash,
    close,
    open: Open,
    profile: [8]u8,
};
pub const Request = struct {
    snapshot: [32]u8,
    layer: p.LayerId,
    selection: [32]u8,
    intent: Intent,
    pub fn capture(model: *const Model, intent: Intent) !Request {
        return .{ .snapshot = try model.id(), .layer = model.document().layers[model.layer].id, .selection = chords.selectionDigest(model), .intent = intent };
    }
    pub fn fromKey(action: keys.Action) Request {
        return .{ .snapshot = action.snapshot, .layer = action.layer, .selection = action.selected, .intent = .{ .select = .{ .index = action.index, .extend = action.extend } } };
    }
    pub fn fromLayer(action: layers.Action, model: *const Model) Request {
        return .{ .snapshot = action.snapshot, .layer = action.selected, .selection = chords.selectionDigest(model), .intent = .{ .layer = .{ .kind = action.kind, .target = action.target, .name = action.name } } };
    }
    pub fn fromChord(action: chords.Action) Request {
        return .{ .snapshot = action.snapshot, .layer = action.layer, .selection = action.selected, .intent = .{ .chord = .{ .chord = action.chord, .held = action.held, .target = action.target } } };
    }
    pub fn validate(self: Request, model: *const Model) !void {
        if (!std.mem.eql(u8, &self.snapshot, &(try model.id())) or self.layer != model.document().layers[model.layer].id or !std.mem.eql(u8, &self.selection, &chords.selectionDigest(model))) return error.StaleEditorRequest;
        switch (self.intent) {
            .select => |value| if (value.index >= model.selected.len) return error.InvalidKey,
            .chord => |value| {
                if (value.target) |target| if (target >= model.selected.len) return error.InvalidKey;
                if (value.held and (value.chord.tap_keycode < 224 or value.chord.tap_keycode > 231)) return error.DropModifierKeyOnHold;
            },
            .layer => |value| {
                var found = false;
                for (model.document().layers) |layer| if (layer.id == value.target) {
                    found = true;
                };
                if (!found) return error.InvalidLayer;
                if (value.kind == .rename) {
                    const name = std.mem.sliceTo(&value.name, 0);
                    if (name.len == 0 or name.len > 128 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
                }
            },
            else => {},
        }
    }
};
pub const Effect = union(enum) { none, pending, open: Open, profile: Request, save: Request, build: Request, flash: Request, confirm_close, save_close: Request, closed };
pub const Recovery = struct { current: [32]u8, selection: [32]u8, original: [32]u8, drafts: [32]u8 };
pub const State = struct {
    inspector: editing.Session,
    pending: ?Request = null,
    close_requested: ?[32]u8 = null,
    closed: bool = false,
    pub fn init(model: *const Model) !State {
        return .{ .inspector = try editing.Session.init(model) };
    }
    pub fn deinit(self: *State) void {
        self.inspector.deinit();
        self.* = undefined;
    }
    /// Allocate replacement before releasing an old clean session. Dirty stale
    /// sessions remain owned for explicit recovery, never silently overwritten.
    pub fn sync(self: *State, model: *const Model) !void {
        if (!try self.inspector.stale(model)) return;
        if (self.inspector.dirty() or self.pending != null) return error.StaleInspectorSession;
        const replacement = try editing.Session.init(model);
        self.inspector.deinit();
        self.inspector = replacement;
    }
    pub fn recovery(self: *const State, model: *const Model) !Recovery {
        if (self.closed) return error.EditorClosed;
        return .{ .current = try model.id(), .selection = chords.selectionDigest(model), .original = self.inspector.starting_id, .drafts = try inspector_action.stagedDigest(model.gpa, &self.inspector) };
    }
    /// Explicitly discard only the drafts the recovery control presented.
    /// Allocation failure leaves both drafts and pending navigation untouched.
    pub fn discardStale(self: *State, model: *const Model, rendered: Recovery) !void {
        if (!std.meta.eql(rendered, try self.recovery(model))) return error.StaleEditorRecovery;
        const replacement = try editing.Session.init(model);
        self.inspector.deinit();
        self.inspector = replacement;
        self.pending = null;
        self.close_requested = null;
    }
    pub fn request(self: *State, model: *Model, captured: Request) !Effect {
        if (self.closed) return error.EditorClosed;
        try captured.validate(model);
        if (self.pending != null) return error.PendingEditorRequest;
        if (self.inspector.dirty()) {
            if (try self.inspector.stale(model)) return error.StaleInspectorSession;
            self.pending = captured;
            return .pending;
        }
        return self.perform(model, captured);
    }
    fn perform(self: *State, model: *Model, captured: Request) !Effect {
        try captured.validate(model);
        switch (captured.intent) {
            .select => |value| try (keys.Action{ .snapshot = captured.snapshot, .layer = captured.layer, .selected = captured.selection, .index = value.index, .extend = value.extend }).dispatch(model),
            .layer => |value| try layers.dispatch(model, .{ .snapshot = captured.snapshot, .selected = captured.layer, .target = value.target, .kind = value.kind, .name = value.name }),
            .chord => |value| try (chords.Action{ .snapshot = captured.snapshot, .layer = captured.layer, .selected = captured.selection, .chord = value.chord, .held = value.held, .target = value.target }).dispatch(model),
            .undo => try model.undo(),
            .redo => try model.redo(),
            .copy => model.copy(),
            .paste => try model.paste(),
            .open => |target| return .{ .open = target },
            .profile => return .{ .profile = captured },
            .save => return .{ .save = captured },
            .build => return .{ .build = captured },
            .flash => return .{ .flash = captured },
            .close => {
                if (model.dirty()) {
                    self.close_requested = captured.snapshot;
                    return .confirm_close;
                }
                self.closed = true;
                return .closed;
            },
        }
        return .none;
    }
    pub fn inspect(self: *State, model: *Model, action: inspector_action.Action) !Effect {
        if (self.closed) return error.EditorClosed;
        try action.validate(&self.inspector, model);
        switch (action.intent) {
            .none => {},
            .copy => return self.request(model, try Request.capture(model, .copy)),
            .paste => return self.request(model, try Request.capture(model, .paste)),
            .apply => {
                _ = try self.inspector.apply(model);
                // Existing pending semantics are preserved when Apply was
                // pressed instead of the resolve button.
                if (self.pending) |*pending| pending.snapshot = self.inspector.starting_id;
            },
            .cancel => self.inspector.cancel(),
            .keep_editing => self.pending = null,
            .keep_close => self.close_requested = null,
            .resolve_apply, .resolve_discard => {
                var pending = self.pending orelse return error.NoPendingEditorRequest;
                try pending.validate(model);
                if (action.intent == .resolve_apply) _ = try self.inspector.apply(model) else self.inspector.cancel();
                pending.snapshot = self.inspector.starting_id;
                self.pending = pending;
                const effect = try self.perform(model, pending);
                self.pending = null;
                return effect;
            },
            .save_close, .discard_close => {
                const expected = self.close_requested orelse return error.NoCloseRequest;
                if (!std.mem.eql(u8, &expected, &self.inspector.starting_id) or self.inspector.dirty()) return error.StaleCloseRequest;
                if (action.intent == .save_close) return .{ .save_close = try Request.capture(model, .save) };
                self.closed = true;
                return .closed;
            },
        }
        return .none;
    }
    /// A failed save never closes. Called after an explicit successful save.
    pub fn savedClose(self: *State, model: *const Model, captured: Request) !Effect {
        if (self.closed) return error.EditorClosed;
        try captured.validate(model);
        const expected = self.close_requested orelse return error.NoCloseRequest;
        if (!std.mem.eql(u8, &expected, &captured.snapshot) or model.dirty() or self.inspector.dirty()) return error.StaleCloseRequest;
        self.closed = true;
        return .closed;
    }
};
