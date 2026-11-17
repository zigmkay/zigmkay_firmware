//! Source → Keyboard → Review → Create. All IO is scheduled after drawing.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const flow = desktop.onboarding;
const p = @import("project");
const ui = @import("editor-ui");
pub const Action = enum { none, inspect, analyze, prepare, create, open, add_existing, cancel, cancel_tutor, editor, tutor, choose_source, choose_location, choose_open };
pub const State = struct {
    active: bool = true,
    selected: bool = false,
    stage: flow.Stage = .welcome,
    generation: u64 = 1,
    editor_generation: u64 = 0,
    captured: [32]u8 = @splat(0),
    operation: ?flow.Operation = null,
    worker: ?*flow.Worker = null,
    source: ?flow.importer.Captured = null,
    analysis: ?flow.importer.Analysis = null,
    prepared: ?flow.importer.Prepared = null,
    collection: ?p.collection.Loaded = null,
    root: [4096]u8 = @splat(0),
    location: [4096]u8 = @splat(0),
    source_location: [4096]u8 = @splat(0),
    source_valid: bool = false,
    entry: [256]u8 = @splat(0),
    name: [129]u8 = @splat(0),
    directory: [129]u8 = @splat(0),
    diagnostic: [1024]u8 = @splat(0),
    selector: usize = 0,
    template: usize = 0,
    module: usize = 0,
    confirmed: bool = false,
    discard: bool = false,
    add_existing: bool = false,
    review_details: bool = false,
    preparing_tutor: bool = false,
    pub fn deinit(self: *State) void {
        if (self.worker) |worker| worker.destroy();
        self.clearImport();
        if (self.collection) |*value| value.deinit();
    }
    pub fn clearImport(self: *State) void {
        if (self.prepared) |*value| value.deinit();
        self.prepared = null;
        if (self.analysis) |*value| value.deinit();
        self.analysis = null;
        if (self.source) |*value| value.deinit();
        self.source = null;
        self.source_valid = false;
        self.confirmed = false;
        self.template = 0;
    }
    pub fn report(self: *State, err: anyerror) void {
        self.diagnostic = @splat(0);
        if (err == error.IncompatibleKeymapSeeCachedCompilerLog) if (self.source) |source| {
            _ = std.fmt.bufPrint(&self.diagnostic, "This module is incompatible with the pinned keymap API. Compiler diagnostics: {s}/analysis.log. Choose another module or migrate the reported API manually.", .{source.directory}) catch {};
            return;
        };
        if (err == error.DefaultCallbackWithoutIds) {
            _ = std.fmt.bufPrint(&self.diagnostic, "Schema 1 cannot represent a callback without declared custom IDs. Keep this source project and migrate its callback contract manually.", .{}) catch {};
            return;
        }
        _ = std.fmt.bufPrint(&self.diagnostic, "{s}. Your source and existing projects are preserved. Retry analysis or choose a local folder.", .{@errorName(err)}) catch {};
    }
    pub fn set(buffer: []u8, value: []const u8) !void {
        if (value.len >= buffer.len or std.mem.indexOfScalar(u8, value, 0) != null) return error.PathTooLong;
        @memset(buffer, 0);
        @memcpy(buffer[0..value.len], value);
    }
    pub fn defaults(self: *State, root: []const u8) !void {
        try set(&self.root, root);
        try set(&self.entry, "src/keymap.zig");
        try set(&self.name, "My keyboard");
        try set(&self.directory, "my-keyboard");
    }
    pub fn reset(self: *State) void {
        if (self.worker) |worker| worker.destroy();
        self.worker = null;
        self.generation +%= 1;
        self.clearImport();
        self.stage = .welcome;
        self.active = true;
        self.discard = false;
        self.diagnostic = @splat(0);
    }
    pub fn reloadCollection(self: *State, gpa: std.mem.Allocator, io: std.Io) !void {
        if (self.collection) |*value| value.deinit();
        self.collection = null;
        var dir = std.Io.Dir.cwd().openDir(io, std.mem.sliceTo(&self.root, 0), .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        self.collection = p.collection.load(gpa, io, dir) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }
    pub fn fingerprint(self: *State) [32]u8 {
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        inline for (.{ "root", "location", "entry", "name", "directory" }) |field_name| {
            hash.update(std.mem.sliceTo(&@field(self, field_name), 0));
            hash.update(&.{0});
        }
        hash.update(std.mem.asBytes(&self.selector));
        hash.update(std.mem.asBytes(&self.template));
        hash.update(&.{ @intFromBool(self.confirmed), @intFromBool(self.discard) });
        if (self.source) |value| hash.update(&value.provenance.fingerprint);
        return hash.finalResult();
    }
    pub fn start(self: *State, gpa: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map, toolchain: flow.importer.Toolchain, action: Action, owner_generation: u64) !void {
        if (self.worker != null) return error.OnboardingAlreadyRunning;
        if (action == .analyze and (!self.source_valid or !std.mem.eql(u8, std.mem.sliceTo(&self.location, 0), std.mem.sliceTo(&self.source_location, 0)) or (if (self.source) |source| !std.mem.eql(u8, std.mem.sliceTo(&self.entry, 0), source.provenance.entry) else true))) return error.InspectNewSourceSelectionFirst;
        if (action == .inspect) self.source_valid = false;
        self.generation = try std.math.add(u64, self.generation, 1);
        var input: flow.Inputs = .{ .operation = .inspect, .toolchain = toolchain, .location = std.mem.sliceTo(&self.location, 0), .entry = if (self.entry[0] != 0) std.mem.sliceTo(&self.entry, 0) else null, .selector = flow.catalog.entries[self.selector].selector, .name = std.mem.sliceTo(&self.name, 0) };
        if (self.source) |value| input.source = .{ .directory = value.directory, .source_root = value.source_root, .provenance = value.provenance, .candidates = value.candidates };
        if (self.analysis) |value| input.analysis = .{ .captured = value.captured, .data = value.data };
        input.template = @fromBackingInt(@intCast(self.template));
        input.operation = switch (action) {
            .inspect => .inspect,
            .analyze => .analyze,
            .prepare => .prepare,
            .create => .create,
            .open => .open,
            .add_existing => .add_existing,
            else => return error.InvalidOnboardingAction,
        };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (action == .create or action == .add_existing) {
            const relative = try std.fmt.allocPrint(a, "keyboards/{s}", .{std.mem.sliceTo(&self.directory, 0)});
            const entry: p.collection.Entry = .{ .id = std.mem.sliceTo(&self.directory, 0), .directory = relative };
            try p.collection.validate(.{ .projects = &.{entry} });
            input.collection = std.mem.sliceTo(&self.root, 0);
            input.collection_entry = entry;
            input.collection_fingerprint = if (self.collection) |value| value.fingerprint else null;
            input.destination = try std.fs.path.join(a, &.{ input.collection.?, relative });
        }
        if (action == .create) {
            const prepared = self.prepared orelse return error.PreparedProjectRequired;
            input.prepared = .{ .snapshot = prepared.project.snapshot, .selector = prepared.board.entry.selector };
        }
        const source_fingerprint = if (self.source) |value| value.provenance.fingerprint else @as([32]u8, @splat(0));
        var request = try flow.Request.init(gpa, input, environment, source_fingerprint);
        errdefer request.deinit();
        self.captured = self.fingerprint();
        self.editor_generation = owner_generation;
        self.worker = try flow.Worker.create(gpa, io, &request, self.generation);
        self.operation = input.operation;
        self.diagnostic = @splat(0);
    }
    pub fn poll(self: *State, owner_generation: u64) !?flow.Opened {
        const worker = self.worker orelse return null;
        const event = worker.poll() orelse return null;
        self.worker = null;
        defer worker.destroy();
        var result = event.result catch |err| {
            self.report(err);
            return null;
        };
        if (event.ticket.generation != self.generation or self.editor_generation != owner_generation or !std.mem.eql(u8, &self.captured, &self.fingerprint())) {
            result.deinit();
            return error.StaleOnboardingResult;
        }
        switch (result) {
            .inspected => |value| {
                self.clearImport();
                self.source = value;
                self.source_valid = true;
                try set(&self.source_location, worker.request.inputs.location);
                self.module = 0;
                try set(&self.entry, value.provenance.entry);
                for (value.candidates, 0..) |candidate, index| if (std.mem.eql(u8, candidate, value.provenance.entry)) {
                    self.module = index;
                };
            },
            .analyzed => |value| {
                if (self.analysis) |*old| old.deinit();
                self.analysis = value;
                self.stage = .keyboard;
                for (flow.catalog.entries, 0..) |entry, index| if (flow.importer.compatible(value.data, entry)) {
                    self.selector = index;
                    break;
                };
            },
            .prepared => |value| {
                if (self.prepared) |*old| old.deinit();
                self.prepared = value;
                self.stage = .review;
            },
            .opened => |value| return value,
        }
        return null;
    }
};
fn field(comptime label: []const u8, buffer: []u8) void {
    const id = std.hash.Wyhash.hash(0, label);
    dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = id });
    const entry = dvui.textEntry(@src(), .{ .text = .{ .buffer = buffer } }, .{ .expand = .horizontal, .id_extra = id });
    entry.deinit();
}
pub fn draw(state: *State, dirty: bool, host_source: []const u8, light: bool) !Action {
    const theme = ui.Theme.get(light);
    const canvas = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(28), .background = true, .color_fill = .{ .color = theme.bg }, .font = dvui.Font.find(.{ .family = "Vera Sans", .size = 16 }) });
    defer canvas.deinit();
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    dvui.label(@src(), "My Keyboards", .{}, .{ .font = dvui.Font.find(.{ .family = "Vera Sans", .size = 28 }).withWeight(.bold) });
    dvui.label(@src(), "{s}", .{switch (state.stage) {
        .welcome => "Choose a keyboard project",
        .source => "Source → Keyboard → Review → Create",
        .keyboard => "Keyboard → Review → Create",
        .review => "Review → Create",
        .created => "Keyboard ready",
        .open => "Open project or collection",
    }}, .{});
    var action: Action = .none;
    const busy = state.worker != null;
    if (busy) {
        dvui.label(@src(), "Preparing {s}…", .{if (state.operation) |operation| @tagName(operation) else "keyboard"}, .{});
        if (state.operation != .create and dvui.button(@src(), "Cancel", .{}, .{})) action = .cancel;
    }
    const controls = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer controls.deinit();
    if (busy) dvui.label(@src(), "Wait for preparation before continuing.", .{}, .{}) else switch (state.stage) {
        .welcome => {
            if (dvui.button(@src(), "Create keyboard", .{}, .{ .tag = "onboarding.create" })) {
                state.clearImport();
                state.stage = .keyboard;
            }
            if (dvui.button(@src(), "Import existing keymap", .{}, .{ .tag = "onboarding.import" })) {
                state.clearImport();
                state.stage = .source;
            }
            if (dvui.button(@src(), "Open project or collection", .{}, .{ .tag = "onboarding.open" })) {
                state.stage = .open;
                state.add_existing = false;
            }
            if (state.collection) |collection| {
                for (collection.manifest.projects, 0..) |entry, index| if (dvui.button(@src(), entry.id, .{}, .{ .id_extra = index })) {
                    const path = try std.fs.path.join(dvui.currentWindow().arena(), &.{ std.mem.sliceTo(&state.root, 0), entry.directory });
                    try State.set(&state.location, path);
                    action = .open;
                };
                if (dvui.button(@src(), "Add keyboard", .{}, .{})) state.stage = .keyboard;
                if (dvui.button(@src(), "Add existing project", .{}, .{})) {
                    state.stage = .open;
                    state.add_existing = true;
                }
            }
            if (state.selected and dvui.button(@src(), "Back to editor", .{}, .{})) action = .editor;
        },
        .source => {
            field("Local source folder or public GitHub repository URL", &state.location);
            if (dvui.button(@src(), "Choose source folder…", .{}, .{})) action = .choose_source;
            field("Keymap module (suggested: src/keymap.zig)", &state.entry);
            if (dvui.button(@src(), "Inspect source / Retry", .{}, .{})) action = .inspect;
            if (state.source) |source| {
                dvui.label(@src(), "Captured {d} source files · {s}", .{ source.provenance.sources.len, std.fmt.bytesToHex(source.provenance.fingerprint, .lower) }, .{});
                if (source.candidates.len > 1 and dvui.dropdown(@src(), source.candidates, .{ .choice = &state.module }, .{}, .{})) {
                    try State.set(&state.entry, source.candidates[state.module]);
                    try State.set(&state.location, source.source_root);
                    action = .inspect;
                }
                if (source.provenance.commit) |commit| dvui.label(@src(), "Immutable commit: {s}", .{commit}, .{});
                for (source.provenance.sources, 0..) |file, index| dvui.label(@src(), "Retain {s}", .{file.path}, .{ .id_extra = index });
                if (state.source_valid and std.mem.eql(u8, std.mem.sliceTo(&state.location, 0), std.mem.sliceTo(&state.source_location, 0)) and std.mem.eql(u8, std.mem.sliceTo(&state.entry, 0), source.provenance.entry) and dvui.button(@src(), "Analyze selected module", .{}, .{})) action = .analyze;
            }
        },
        .keyboard => {
            const names = try dvui.currentWindow().arena().alloc([]const u8, flow.catalog.entries.len);
            for (flow.catalog.entries, names) |entry, *name| name.* = try std.fmt.allocPrint(dvui.currentWindow().arena(), "{s} · PCB {s} · {s}", .{ entry.display.name, entry.display.revision, entry.display.template });
            if (dvui.dropdown(@src(), names, .{ .choice = &state.selector }, .{}, .{ .expand = .horizontal })) {
                state.confirmed = false;
                state.template = 0;
            }
            const selected = flow.catalog.entries[state.selector];
            if (state.analysis == null and std.mem.eql(u8, selected.selector, "lk7")) {
                dvui.label(@src(), "Starting template", .{}, .{});
                _ = dvui.dropdown(@src(), &.{ "Selected firmware default", "QWERTY", "EurKEY draft", "EurKEY Next Mac candidate" }, .{ .choice = &state.template }, .{}, .{});
            }
            dvui.label(@src(), "{d} keys · {d} encoder directions · schematic geometry", .{ selected.default_dimensions.key_count, selected.encoder_action_slots }, .{});
            if (state.analysis) |analysis| if (!flow.importer.compatible(analysis.data, selected)) dvui.label(@src(), "Choose a compatible Keycaprio 0.6 or 0.7 target. Matching dimensions alone do not establish hardware compatibility.", .{}, .{});
            _ = dvui.checkbox(@src(), &state.confirmed, "I confirm this keyboard hardware and PCB revision", .{});
            field("Profile name", &state.name);
            if (state.confirmed and dvui.button(@src(), "Review keyboard", .{}, .{})) action = .prepare;
        },
        .review => {
            const prepared = state.prepared orelse return error.PreparedProjectRequired;
            const doc = prepared.project.snapshot.document;
            dvui.label(@src(), "Keyboard: {s} · PCB {s}", .{ prepared.board.entry.display.name, prepared.board.entry.display.revision }, .{});
            dvui.label(@src(), "{s}: {d} keys, {d} layers, {d} ordered combos", .{ doc.name, doc.key_ids.len, doc.layers.len, doc.combos.len }, .{});
            for (doc.layers, 0..) |layer, index| {
                var disabled: usize = 0;
                var transparent: usize = 0;
                for (layer.actions) |assignment| {
                    if (assignment) |value| {
                        if (value == .none) disabled += 1;
                    } else transparent += 1;
                }
                dvui.label(@src(), "{s}: {d} assignments, {d} transparent, {d} disabled", .{ layer.name, layer.actions.len - transparent - disabled, transparent, disabled }, .{ .id_extra = index });
            }
            if (doc.callbacks.len != 0) dvui.label(@src(), "Custom callback source is retained byte-for-byte. Existing layer indices stay fixed; names and assignments remain editable.", .{}, .{});
            for (doc.callbacks, 0..) |callback, index| dvui.label(@src(), "Retained module {s} · custom IDs {any}", .{ callback.binding, callback.ids }, .{ .id_extra = index });
            _ = dvui.checkbox(@src(), &state.review_details, "Show every assignment, combo and encoder action", .{});
            if (state.review_details) {
                for (doc.layers, 0..) |layer, li| for (layer.actions, 0..) |assignment, ki| {
                    dvui.label(@src(), "{s} / {s}: {any}", .{ layer.name, doc.key_ids[ki], assignment }, .{ .id_extra = li * 128 + ki });
                };
                for (doc.combos, 0..) |combo, index| dvui.label(@src(), "Combo {d}: {any}", .{ index + 1, combo }, .{ .id_extra = index });
                for (doc.encoders, 0..) |encoder, index| dvui.label(@src(), "Encoder direction {d}: {any}", .{ index + 1, encoder }, .{ .id_extra = index });
            }
            dvui.label(@src(), "Host layout hint: {s} · active OS input source: {s}", .{ if (state.source) |source| source.provenance.host_layout_hint else prepared.board.entry.display.host_layout, host_source }, .{});
            dvui.label(@src(), "Your OS input settings are unchanged. Exports use the application's pinned firmware.", .{}, .{});
            field("Collection location (Change location)", &state.root);
            if (dvui.button(@src(), "Change location…", .{}, .{})) action = .choose_location;
            field("New keyboard directory / stable collection entry ID", &state.directory);
            dvui.label(@src(), "Destination: {s}/keyboards/{s}", .{ std.mem.sliceTo(&state.root, 0), std.mem.sliceTo(&state.directory, 0) }, .{});
            if (dvui.button(@src(), "Create new project", .{}, .{ .tag = "onboarding.commit" })) action = .create;
        },
        .created => {
            dvui.label(@src(), "Saved, reopened and added to your collection.", .{}, .{});
            if (dvui.button(@src(), "Open editor", .{}, .{})) action = .editor;
            if (state.preparing_tutor) {
                dvui.label(@src(), "Preparing the native tutor runner…", .{}, .{});
                if (dvui.button(@src(), "Cancel tutor preparation", .{}, .{})) action = .cancel_tutor;
            } else if (dvui.button(@src(), "Try tutor", .{}, .{})) action = .tutor;
        },
        .open => {
            if (state.add_existing) {
                dvui.label(@src(), "Add a project inside this collection, or explicitly make a portable copy of an external project. The original stays unchanged.", .{}, .{});
                field("Existing project directory (leave empty for membership only)", &state.location);
                if (dvui.button(@src(), "Choose existing project…", .{}, .{})) action = .choose_open;
                field("Directory name inside keyboards/", &state.directory);
                if (dvui.button(@src(), if (state.location[0] != 0) "Copy project into collection" else "Add existing project", .{}, .{})) action = .add_existing;
            } else {
                field("Project or collection directory", &state.location);
                if (dvui.button(@src(), "Choose folder…", .{}, .{})) action = .choose_open;
                if (dvui.button(@src(), "Open", .{}, .{})) action = .open;
            }
        },
    }
    if (dirty) {
        dvui.label(@src(), "The editor has unsaved changes. Save them in the editor or explicitly discard them when switching.", .{}, .{});
        _ = dvui.checkbox(@src(), &state.discard, "Discard the current unsaved changes when opening the new project", .{});
        if (!state.discard and (action == .open or action == .create or action == .add_existing)) action = .none;
    }
    dvui.labelNoFmt(@src(), std.mem.sliceTo(&state.diagnostic, 0), .{}, .{});
    if (!busy and state.stage != .welcome and state.stage != .created and dvui.button(@src(), "Back to My Keyboards", .{}, .{})) {
        state.clearImport();
        state.stage = .welcome;
    }
    return action;
}

test "wizard rejects stale settings and owner generations without touching destinations" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var state: State = .{};
    defer state.deinit();
    try state.defaults(path);
    const toolchain: flow.importer.Toolchain = .{ .compiler = "", .build_root = "", .cache = path };
    try state.start(t.allocator, t.io, &env, toolchain, .prepare, 1);
    try State.set(&state.name, "Newer selection");
    var refused = false;
    for (0..1000) |_| {
        if (state.poll(1)) |opened| {
            if (opened != null) return error.UnexpectedProjectReplacement;
        } else |err| {
            try t.expectEqual(error.StaleOnboardingResult, err);
            refused = true;
            break;
        }
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(refused);
    try t.expect(state.prepared == null);
    try state.start(t.allocator, t.io, &env, toolchain, .prepare, 1);
    refused = false;
    for (0..1000) |_| {
        if (state.poll(2)) |opened| {
            if (opened != null) return error.UnexpectedProjectReplacement;
        } else |err| {
            try t.expectEqual(error.StaleOnboardingResult, err);
            refused = true;
            break;
        }
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(refused);
    try state.start(t.allocator, t.io, &env, toolchain, .prepare, 2);
    state.reset();
    try t.expect(state.worker == null and state.prepared == null);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "project.zon", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "workspace.zon", .{}));
    try State.set(&state.location, "/new/source");
    try t.expectError(error.InspectNewSourceSelectionFirst, state.start(t.allocator, t.io, &env, toolchain, .analyze, 2));
}
