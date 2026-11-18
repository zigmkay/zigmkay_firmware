//! My Keyboards and the pages that add keyboards and layouts. All IO is
//! scheduled after drawing.
const std = @import("std");
const dvui = @import("dvui");
const desktop = @import("desktop-core");
const flow = desktop.onboarding;
const p = @import("project");
const ui = @import("editor-ui");
const keyboards_ui = @import("keyboards_ui.zig");
const catalog_ui = @import("catalog_ui.zig");
const new_layout_ui = @import("new_layout_ui.zig");
const import_ui = @import("import_ui.zig");

pub const Action = enum {
    none,
    inspect,
    analyze,
    prepare,
    create,
    open,
    add_existing,
    cancel,
    cancel_tutor,
    editor,
    tutor,
    choose_source,
    choose_location,
    choose_open,
    toggle_theme,
};

pub const State = struct {
    active: bool = true,
    selected: bool = false,
    stage: flow.Stage = .home,
    /// The keyboard chosen on My Keyboards, an index into `library.keyboards`.
    keyboard: ?usize = null,
    catalog: catalog_ui.View = .{},
    new_layout: new_layout_ui.View = .{},
    /// The project New layout would create, for its current start point.
    candidate: ?desktop.new_layout.Candidate = null,
    candidate_key: u64 = 0,
    candidate_failure: [256]u8 = @splat(0),
    /// The analyzed keymap next to the chosen keyboard.
    comparison: ?desktop.import_compare.Comparison = null,
    comparison_key: u64 = 0,
    comparison_failure: [256]u8 = @splat(0),
    /// Creates the import once its preparation arrives.
    create_ready: bool = false,
    /// Callback source of an in-memory analysis without a captured source,
    /// for offscreen galleries.
    sample_sources: []const flow.catalog.SourceFile = &.{},
    /// Opens the folder the native chooser returns.
    awaiting_open: bool = false,
    /// Opens `location` once the open layout is saved.
    open_when_saved: bool = false,
    /// The collection root My Keyboards was last loaded from.
    listed_root: [4096]u8 = @splat(0),
    generation: u64 = 1,
    editor_generation: u64 = 0,
    captured: [32]u8 = @splat(0),
    operation: ?flow.Operation = null,
    worker: ?*flow.Worker = null,
    source: ?flow.importer.Captured = null,
    analysis: ?flow.importer.Analysis = null,
    prepared: ?flow.importer.Prepared = null,
    collection: ?p.collection.Loaded = null,
    /// The layouts of every known keyboard, grouped by hardware.
    library: ?desktop.library.Library = null,
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
        if (self.library) |*value| value.deinit();
        self.dropCandidate();
        self.dropComparison();
    }

    fn dropCandidate(self: *State) void {
        if (self.candidate) |*value| value.deinit();
        self.candidate = null;
        self.candidate_key = 0;
        self.candidate_failure = @splat(0);
    }

    /// Shows New layout for the keyboard of `catalog.entries[entry]`.
    pub fn openNewLayout(self: *State, entry: usize) void {
        self.clearImport();
        self.dropCandidate();
        self.selector = entry;
        self.new_layout = .{ .entry = entry };
        self.stage = .new_layout;
    }

    /// Rebuilds the New layout candidate when its start point changed. Reading
    /// a layout to duplicate never changes it.
    pub fn refreshCandidate(self: *State, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.stage != .new_layout) return;
        const owned = if (self.library) |*value| value else null;
        const wanted = new_layout_ui.key(&self.new_layout, owned);
        if (wanted == self.candidate_key) return;
        self.dropCandidate();
        self.candidate_key = wanted;
        const start_point = new_layout_ui.start(&self.new_layout, owned) orelse return;
        const entry = &flow.catalog.entries[self.new_layout.entry];
        self.candidate = desktop.new_layout.prepare(gpa, io, entry, start_point) catch |err| {
            _ = std.fmt.bufPrint(&self.candidate_failure, "This start point cannot be used here: {s}", .{@errorName(err)}) catch {};
            return;
        };
    }

    pub fn replaceLibrary(self: *State, library: desktop.library.Library) void {
        if (self.library) |*old| old.deinit();
        self.library = library;
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
        self.create_ready = false;
        self.dropComparison();
    }

    fn dropComparison(self: *State) void {
        if (self.comparison) |*value| value.deinit();
        self.comparison = null;
        self.comparison_key = 0;
        self.comparison_failure = @splat(0);
    }

    /// Compares the analyzed keymap with the chosen keyboard when either
    /// changed. Callback source is read from the captured copy.
    pub fn refreshComparison(self: *State, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.stage != .source) return;
        const analysis = self.analysis orelse return;
        var hash: std.hash.Wyhash = .init(0);
        hash.update(&analysis.captured);
        hash.update(std.mem.asBytes(&self.selector));
        const wanted = hash.final() | 1;
        if (wanted == self.comparison_key) return;
        self.dropComparison();
        self.comparison_key = wanted;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const files = if (analysis.data.has_callbacks) if (self.source) |source|
            flow.importer.sourceFiles(scratch.allocator(), gpa, io, source) catch |err| return self.compareFailed(err)
        else
            self.sample_sources else &.{};
        self.comparison = desktop.import_compare.compare(gpa, analysis.data, files, &flow.catalog.entries[self.selector]) catch |err|
            return self.compareFailed(err);
    }

    fn compareFailed(self: *State, err: anyerror) void {
        _ = std.fmt.bufPrint(&self.comparison_failure, "This keymap cannot be compared with that keyboard: {s}", .{@errorName(err)}) catch {};
    }

    pub fn report(self: *State, err: anyerror) void {
        self.diagnostic = @splat(0);
        if (err == error.IncompatibleKeymapSeeCachedCompilerLog) if (self.source) |source| {
            const message = "This module is incompatible with the pinned keymap API. Compiler diagnostics: " ++
                "{s}/analysis.log. Choose another module or migrate the reported API manually.";
            _ = std.fmt.bufPrint(&self.diagnostic, message, .{source.directory}) catch {};
            return;
        };
        if (err == error.DefaultCallbackWithoutIds) {
            const message = "Schema 1 cannot represent a callback without declared custom IDs. " ++
                "Keep this source project and migrate its callback contract manually.";
            _ = std.fmt.bufPrint(&self.diagnostic, message, .{}) catch {};
            return;
        }
        const message = "{s}. Your source and existing projects are preserved. Retry analysis or choose a local folder.";
        _ = std.fmt.bufPrint(&self.diagnostic, message, .{@errorName(err)}) catch {};
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
        self.stage = .home;
        self.active = true;
        self.awaiting_open = false;
        self.open_when_saved = false;
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

    /// Whether the inspected source still matches the location and module fields.
    fn inspectedSelection(self: *const State) bool {
        const source = self.source orelse return false;
        return self.source_valid and
            std.mem.eql(u8, std.mem.sliceTo(&self.location, 0), std.mem.sliceTo(&self.source_location, 0)) and
            std.mem.eql(u8, std.mem.sliceTo(&self.entry, 0), source.provenance.entry);
    }

    pub fn start(
        self: *State,
        gpa: std.mem.Allocator,
        io: std.Io,
        environment: *const std.process.Environ.Map,
        toolchain: flow.importer.Toolchain,
        action: Action,
        owner_generation: u64,
    ) !void {
        if (self.worker != null) return error.OnboardingAlreadyRunning;
        if (action == .analyze and !self.inspectedSelection()) return error.InspectNewSourceSelectionFirst;
        if (action == .inspect) self.source_valid = false;
        self.generation = try std.math.add(u64, self.generation, 1);
        var input: flow.Inputs = .{
            .operation = .inspect,
            .toolchain = toolchain,
            .location = std.mem.sliceTo(&self.location, 0),
            .entry = if (self.entry[0] != 0) std.mem.sliceTo(&self.entry, 0) else null,
            .selector = flow.catalog.entries[self.selector].selector,
            .name = std.mem.sliceTo(&self.name, 0),
        };
        if (self.source) |value| input.source = .{
            .directory = value.directory,
            .source_root = value.source_root,
            .provenance = value.provenance,
            .candidates = value.candidates,
        };
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
        const new_layout = action == .create and self.stage == .new_layout;
        if (new_layout) try self.nameLayout(io, std.mem.sliceTo(&self.new_layout.name, 0));
        if (action == .create and self.stage == .source) try self.nameLayout(io, std.mem.sliceTo(&self.name, 0));
        if (action == .create or action == .add_existing) {
            const relative = try std.fmt.allocPrint(a, "keyboards/{s}", .{std.mem.sliceTo(&self.directory, 0)});
            const entry: p.collection.Entry = .{ .id = std.mem.sliceTo(&self.directory, 0), .directory = relative };
            try p.collection.validate(.{ .projects = &.{entry} });
            input.collection = std.mem.sliceTo(&self.root, 0);
            input.collection_entry = entry;
            input.collection_fingerprint = if (self.collection) |value| value.fingerprint else null;
            input.destination = try std.fs.path.join(a, &.{ input.collection.?, relative });
        }
        if (new_layout) {
            const candidate = self.candidate orelse return error.PreparedProjectRequired;
            var snapshot = candidate.snapshot;
            snapshot.document.name = std.mem.sliceTo(&self.name, 0);
            snapshot.document.profile_id = flow.randomProfileId(io);
            input.prepared = .{ .snapshot = snapshot, .selector = candidate.board.entry.selector };
        } else if (action == .create) {
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

    /// Takes the layout name and a free collection directory for it.
    fn nameLayout(self: *State, io: std.Io, typed: []const u8) !void {
        var copy: [129]u8 = undefined;
        const trimmed = std.mem.trim(u8, typed, " ");
        if (trimmed.len == 0) return error.LayoutNameRequired;
        if (trimmed.len >= copy.len) return error.InvalidName;
        // `typed` may be `self.name` itself.
        @memcpy(copy[0..trimmed.len], trimmed);
        const name = copy[0..trimmed.len];
        try set(&self.name, name);
        const Taken = struct {
            io: std.Io,
            root: []const u8,
            collection: ?p.collection.Manifest,

            pub fn contains(taken: @This(), directory: []const u8) bool {
                if (taken.collection) |manifest| for (manifest.projects) |entry| {
                    if (std.mem.eql(u8, entry.id, directory) or
                        std.mem.eql(u8, std.fs.path.basename(entry.directory), directory)) return true;
                };
                var buffer: [4300]u8 = undefined;
                const path = std.fmt.bufPrint(&buffer, "{s}/keyboards/{s}", .{ taken.root, directory }) catch return true;
                _ = std.Io.Dir.cwd().statFile(taken.io, path, .{}) catch return false;
                return true;
            }
        };
        var buffer: [128]u8 = undefined;
        const directory = desktop.new_layout.directoryName(&buffer, name, Taken{
            .io = io,
            .root = std.mem.sliceTo(&self.root, 0),
            .collection = if (self.collection) |value| value.manifest else null,
        });
        try set(&self.directory, directory);
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
        const stale = event.ticket.generation != self.generation or self.editor_generation != owner_generation or
            !std.mem.eql(u8, &self.captured, &self.fingerprint());
        if (stale) {
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
                for (value.candidates, 0..) |candidate, index| {
                    if (std.mem.eql(u8, candidate, value.provenance.entry)) self.module = index;
                }
            },
            .analyzed => |value| {
                if (self.analysis) |*old| old.deinit();
                self.analysis = value;
                // Prefer a keyboard the keymap fits; otherwise keep the chosen one.
                for (flow.catalog.entries, 0..) |entry, index| {
                    if (flow.importer.compatible(value.data, entry)) {
                        self.selector = index;
                        break;
                    }
                }
            },
            .prepared => |value| {
                if (self.prepared) |*old| old.deinit();
                self.prepared = value;
                self.create_ready = true;
            },
            .opened => |value| return value,
        }
        return null;
    }
};

/// What the onboarding pages know about the editor and the connected keyboard.
pub const Context = struct {
    dirty: bool = false,
    /// Whether the open layout saves itself; otherwise unsaved edits need an
    /// explicit discard before another project opens.
    autosaves: bool = false,
    host_source: []const u8 = "Offline",
    light: bool = false,
    current_path: []const u8 = "",
    running: ?keyboards_ui.Running = null,
    now: i96 = 0,
};

pub fn draw(state: *State, context: Context) !Action {
    const theme = ui.Theme.get(context.light);
    const scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .padding = .{}, .border = .{}, .background = false });
    defer scroll.deinit();
    const canvas = dvui.box(@src(), .{}, .{
        .expand = .horizontal,
        .min_size_content = .{ .w = keyboards_ui.canvas_width, .h = keyboards_ui.canvas_height },
        .padding = .{},
        .margin = .{},
        .background = true,
        .color_fill = .{ .color = theme.bg },
    });
    defer canvas.deinit();
    var action: Action = .none;
    const busy = state.worker != null;
    switch (state.stage) {
        .home => action = try home(state, theme, context),
        .catalog => switch (catalog_ui.draw(&state.catalog, theme, context.light, libraryOf(state))) {
            .none => {},
            .back => state.stage = .home,
            .toggle_theme => action = .toggle_theme,
            .choose => |index| state.openNewLayout(index),
        },
        .new_layout => switch (new_layout_ui.draw(&state.new_layout, theme, .{
            .library = libraryOf(state),
            .candidate = if (state.candidate) |*value| value else null,
            .failure = std.mem.sliceTo(&state.candidate_failure, 0),
            .collection = std.mem.sliceTo(&state.root, 0),
            .busy = busy,
            .light = context.light,
        })) {
            .none => {},
            .back => state.stage = .home,
            .toggle_theme => action = .toggle_theme,
            .create => action = .create,
            .import_git => {
                state.clearImport();
                state.selector = state.new_layout.entry;
                state.stage = .source;
            },
        },
        .source => action = try importPage(state, theme, context, busy),
    }
    if (state.awaiting_open and state.location[0] != 0 and action == .none) {
        state.awaiting_open = false;
        action = .open;
    }
    if (busy) drawBusy(state, theme, &action);
    if (context.dirty and !context.autosaves) {
        const warning = "The editor has unsaved changes.";
        banner(theme, warning, ui.color(0xF59E0B), 0);
        var opts = ui.options(theme, .{ .x = 560, .y = 1012, .w = 560, .h = 22 }, 13);
        opts.padding = .{};
        _ = dvui.checkbox(@src(), &state.discard, "Discard them when opening another project", opts);
        if (!state.discard and (action == .open or action == .create or action == .add_existing)) action = .none;
    }
    const diagnostic = std.mem.sliceTo(&state.diagnostic, 0);
    if (diagnostic.len != 0) banner(theme, diagnostic, ui.color(0xF06B73), 1);
    return action;
}

fn libraryOf(state: *const State) ?*const desktop.library.Library {
    return if (state.library) |*value| value else null;
}

fn home(state: *State, theme: ui.Theme, context: Context) !Action {
    const intent = keyboards_ui.draw(theme, context.light, &state.keyboard, .{
        .library = libraryOf(state),
        .current_path = context.current_path,
        .running = context.running,
        .now = context.now,
        .has_editor = state.selected,
        .collection = std.mem.sliceTo(&state.root, 0),
    });
    switch (intent) {
        .none => {},
        .open_layout => |index| {
            try State.set(&state.location, state.library.?.layouts[index].path);
            return .open;
        },
        .new_layout => |index| {
            const keyboard = state.library.?.keyboards[index];
            state.openNewLayout(entryIndex(state.library.?.layouts[keyboard.layouts[0]].entry));
        },
        .add_keyboard => {
            state.catalog = .{};
            state.stage = .catalog;
        },
        .import_git => {
            state.clearImport();
            state.stage = .source;
        },
        .open_folder => {
            state.location = @splat(0);
            state.awaiting_open = true;
            return .choose_open;
        },
        .change_location => return .choose_location,
        .editor => return .editor,
        .toggle_theme => return .toggle_theme,
    }
    return .none;
}

pub fn entryIndex(entry: *const desktop.library.catalog.Entry) usize {
    for (&flow.catalog.entries, 0..) |*candidate, index| if (candidate == entry) return index;
    return 0;
}

/// A one-line message across the bottom of the page.
fn banner(theme: ui.Theme, message: []const u8, tint: dvui.Color, id: usize) void {
    const y: f32 = if (id == 0) 1004 else 964;
    const strip = dvui.box(@src(), .{}, .{
        .id_extra = id,
        .rect = .{ .x = 16, .y = y, .w = keyboards_ui.canvas_width - 32, .h = 36 },
        .background = true,
        .color_fill = .{ .color = ui.mix(theme.panel, tint, 0.14) },
        .color_border = .{ .color = tint },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = if (id == 0) "onboarding.unsaved" else "onboarding.diagnostic",
    });
    strip.deinit();
    keyboards_ui.text(theme, message, .{ .x = 32, .y = y + 8, .w = 520, .h = 20 }, 13, theme.text, false, 900 + id);
}

/// While a worker prepares something, a strip names it and offers Cancel.
fn drawBusy(state: *State, theme: ui.Theme, action: *Action) void {
    const strip = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 16, .y = 924, .w = keyboards_ui.canvas_width - 32, .h = 36 },
        .background = true,
        .color_fill = .{ .color = theme.control },
        .color_border = .{ .color = theme.border },
        .border = .all(1),
        .corners = .all(8),
        .padding = .{},
        .margin = .{},
        .tag = "onboarding.busy",
    });
    strip.deinit();
    dvui.spinner(@src(), .{
        .rect = .{ .x = 30, .y = 932, .w = 20, .h = 20 },
        .min_size_content = .{ .w = 20, .h = 20 },
        .padding = .{},
        .margin = .{},
        .color_text = .{ .color = theme.accent },
    });
    var buffer: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&buffer, "Working: {s}…", .{if (state.operation) |operation| switch (operation) {
        .inspect => "capturing the source",
        .analyze => "analyzing the keymap",
        .prepare => "preparing the layout",
        .create => "creating the layout",
        .open => "opening",
        .add_existing => "adding the project",
    } else "preparing"}) catch "Working…";
    keyboards_ui.text(theme, label, .{ .x = 60, .y = 932, .w = 600, .h = 20 }, 13, theme.text, false, 910);
    if (state.operation != .create and ui.iconButton(theme, null, "Cancel", "onboarding.cancel", .{ .x = keyboards_ui.canvas_width - 128, .y = 928, .w = 96, .h = 28 }, false)) action.* = .cancel;
}

fn importPage(state: *State, theme: ui.Theme, context: Context, busy: bool) !Action {
    var hint: [160]u8 = undefined;
    const provenance = if (state.source) |source| source.provenance.host_layout_hint else "none";
    const host = std.fmt.bufPrint(&hint, "{s} · active OS input source: {s}", .{ provenance, context.host_source }) catch context.host_source;
    const intent = try import_ui.draw(theme, .{
        .location = &state.location,
        .name = &state.name,
        .module = &state.module,
        .selector = &state.selector,
        .source = if (state.source) |*value| value else null,
        .inspected = state.inspectedSelection(),
        .analyzed = state.analysis != null,
        .comparison = if (state.comparison) |*value| value else null,
        .failure = std.mem.sliceTo(&state.comparison_failure, 0),
        .host_source = host,
        .collection = std.mem.sliceTo(&state.root, 0),
        .busy = busy,
        .light = context.light,
    });
    switch (intent) {
        .none, .target => {},
        .back => {
            state.clearImport();
            state.stage = .home;
        },
        .toggle_theme => return .toggle_theme,
        .choose_source => return .choose_source,
        .inspect => return .inspect,
        .analyze => return .analyze,
        .module => if (state.source) |source| {
            try State.set(&state.entry, source.candidates[state.module]);
            try State.set(&state.location, source.source_root);
            return .inspect;
        },
        .create => return .prepare,
    }
    return .none;
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
