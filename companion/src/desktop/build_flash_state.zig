//! What the editor head shows about building and flashing: the status row,
//! the Build and Flash buttons and the headline of the Details popup, derived
//! from the application state of one frame. Pure: no clock, filesystem,
//! process or device access.
const std = @import("std");
const activity = @import("build_activity.zig");

pub const Trigger = activity.Trigger;
pub const Errors = activity.Errors;

/// A click that waits for the cache warm-up to end.
pub const Queued = enum { build, flash };

/// The part of a running Flash, from the firmware check to the reconnect.
pub const FlashStep = enum { preparing, bootloader, writing, restarting, reconnecting, cancelling };

pub const Flash = union(enum) {
    idle,
    working: FlashStep,
    /// The keyboard reconnected with the flashed firmware this many
    /// milliseconds ago.
    done: u64,
    failed,
};

/// The background build that fills the compiler cache.
pub const Warmup = struct {
    elapsed_ms: u64,
    /// How long the last long warm-up took, when one was recorded.
    estimate_ms: ?u64 = null,
};

pub const Building = struct {
    trigger: Trigger,
    elapsed_ms: u64,
    /// No build of this application version finished yet.
    first: bool = false,
};

/// The accepted build, when it is of the editor's current layout.
pub const Built = struct {
    duration_ms: u64,
    /// Built by a click, Auto-build or Flash rather than the startup warm-up.
    by_user: bool,
};

pub const Input = struct {
    /// The application bundle has a toolchain and a build plan.
    toolchain: bool = true,
    /// No other editor job blocks a Build click.
    can_build: bool = true,
    /// A Flash click can build or flash now.
    can_flash: bool = true,
    auto_build: bool = false,
    warmup: ?Warmup = null,
    queued: ?Queued = null,
    building: ?Building = null,
    built: ?Built = null,
    /// The layout changed since the project opened or since its last build.
    changed: bool = false,
    /// The connected keyboard verified that it runs exactly this layout.
    keyboard_runs_layout: bool = false,
    /// The last build of the current layout failed with these errors.
    build_failed: ?Errors = null,
    /// Why the last build failed when no compiler error was located.
    build_failure: []const u8 = "",
    flash: Flash = .idle,
    /// The flash session's own status line, such as BOOTSEL guidance.
    flash_status: []const u8 = "",
    /// Why the last Flash failed.
    flash_failure: []const u8 = "",
};

/// The colour of the status row's mark.
pub const Tone = enum {
    /// Green dot.
    ready,
    /// Accent dot: a step waits for the user.
    next,
    /// Spinner.
    busy,
    /// Pulsing orange dot.
    preparing,
    /// Warning mark.
    failed,
    /// Muted dot: building is not possible.
    unavailable,
};

pub const Style = enum {
    idle,
    /// Looks disabled.
    off,
    /// The next step: accent fill with a gentle glow.
    next,
    /// Working: a light sweeps over it.
    working,
    /// Waiting for the cache warm-up, with a slow orange sweep.
    preparing,
    /// Clicked during the warm-up; starts when it ends.
    queued,
    done,
    failed,

    /// Whether the button moves while it holds this style.
    pub fn sweeps(style: Style) bool {
        return style == .working or style == .preparing or style == .queued;
    }
};

pub const Icon = enum { build, flash, check, warning };

pub const Button = struct {
    style: Style = .idle,
    label: []const u8,
    icon: Icon,
    tooltip: []const u8 = "",
    /// Disabled buttons ignore clicks; their style still shows the state.
    enabled: bool = true,
};

pub const Progress = union(enum) {
    none,
    fraction: f32,
    indeterminate,
};

pub const Step = enum { pending, active, done, failed };
pub const step_names = [_][]const u8{ "Caches", "Build", "Flash", "Reconnect" };

pub const State = struct {
    tone: Tone = .ready,
    message: []const u8 = "Ready",
    hint: []const u8 = "",
    progress: Progress = .none,
    build: Button = .{ .label = "Build", .icon = .build },
    flash: Button = .{ .label = "Flash", .icon = .flash },
    headline: []const u8 = "Ready",
    detail: []const u8 = "",
    steps: [step_names.len]Step = @splat(.pending),
    /// Details opens on the compiler output instead of the activity.
    show_output: bool = false,

    /// Whether anything on the head moves: a sweep, a pulsing dot or bar.
    pub fn working(self: State) bool {
        return self.build.style.sweeps() or self.flash.style.sweeps() or self.tone == .preparing or self.tone == .busy;
    }
};

/// Storage for the formatted strings of a `State`; it must outlive it.
pub const Text = struct {
    message: [128]u8 = undefined,
    hint: [160]u8 = undefined,
    detail: [256]u8 = undefined,
};

/// How long the Flash button says "Flashed" after the keyboard reconnected.
pub const flashed_ms = 5000;
/// Warm-ups shorter than this are not worth remembering as an estimate.
pub const long_warmup_ms = 5000;

const unavailable_tip = "This copy of the editor has no build tools";
const warmup_tip = "Available once the build caches are ready · click to queue";

pub fn derive(input: Input, text: *Text) State {
    if (!input.toolchain) return unavailable();
    if (input.building) |building| return buildingState(input, building, text);
    if (input.flash == .working) return flashingState(input, input.flash.working);
    if (input.warmup) |warmup| return preparingState(input, warmup, text);
    if (input.build_failed) |errors| return buildFailedState(input, errors, text);
    if (input.flash == .failed) return flashFailedState(input);
    return settledState(input, text);
}

fn unavailable() State {
    const off: Style = .off;
    return .{
        .tone = .unavailable,
        .message = "Building unavailable",
        .hint = "this copy of the editor has no build tools",
        .build = .{ .style = off, .label = "Build", .icon = .build, .tooltip = unavailable_tip, .enabled = false },
        .flash = .{ .style = off, .label = "Flash", .icon = .flash, .tooltip = unavailable_tip, .enabled = false },
        .headline = "Building unavailable",
        .detail = "The application bundle holds no build resources, so firmware cannot be built or flashed from here.",
    };
}

fn buildingState(input: Input, building: Building, text: *Text) State {
    const elapsed = building.elapsed_ms / 1000;
    const hint = switch (building.trigger) {
        .auto_build => print(&text.hint, "started by Auto-build · {d} s", .{elapsed}),
        .flash => print(&text.hint, "Flash follows · {d} s", .{elapsed}),
        .warmup_adopted => print(&text.hint, "continuing the cache warm-up · {d} s", .{elapsed}),
        .click, .warmup => print(&text.hint, "{d} s", .{elapsed}),
    };
    const first = if (building.first) print(&text.hint, "first build may take a few minutes · {d} s", .{elapsed}) else hint;
    const flash_queued = building.trigger == .flash;
    return .{
        .tone = .busy,
        .message = "Building firmware…",
        .hint = first,
        .build = .{ .style = .working, .label = "Building…", .icon = .build, .tooltip = "Building · click for Details" },
        .flash = if (flash_queued)
            .{ .style = .queued, .label = "Queued…", .icon = .flash, .tooltip = "Flashes when the build is done" }
        else
            .{ .style = .off, .label = "Flash", .icon = .flash, .tooltip = "Available once the build is done", .enabled = input.can_flash },
        .headline = "Building firmware",
        .detail = if (flash_queued)
            "Compiling the firmware for this layout. Flashing starts when it is done."
        else
            "Compiling the firmware for this layout. No keyboard changes until you flash.",
        .steps = .{ .done, .active, .pending, .pending },
    };
}

fn flashingState(input: Input, step: FlashStep) State {
    const waiting_for_bootsel = std.mem.startsWith(u8, input.flash_status, "Keyboard not in BOOTSEL");
    const message: []const u8, const hint: []const u8 = if (waiting_for_bootsel)
        .{ "Waiting for the bootloader", "hold BOOTSEL while reconnecting USB · open Details" }
    else switch (step) {
        .preparing => .{ "Preparing to flash", "checking the firmware" },
        .bootloader => .{ "Restarting into the bootloader", "keep the keyboard plugged in" },
        .writing => .{ "Writing firmware", "keep the keyboard plugged in" },
        .restarting => .{ "Restarting the keyboard", "keep the keyboard plugged in" },
        .reconnecting => .{ "Waiting for the keyboard to reconnect", "" },
        .cancelling => .{ "Cancelling the flash", "waiting for the flash tool to stop" },
    };
    return .{
        .tone = .busy,
        .message = message,
        .hint = hint,
        .build = .{ .style = .done, .label = "Built", .icon = .check, .tooltip = "Available once flashing is done", .enabled = false },
        .flash = .{ .style = .working, .label = "Flashing…", .icon = .flash, .tooltip = "Flashing · click for Details" },
        .headline = message,
        .detail = input.flash_status,
        .steps = if (step == .reconnecting) .{ .done, .done, .done, .active } else .{ .done, .done, .active, .pending },
    };
}

fn preparingState(input: Input, warmup: Warmup, text: *Text) State {
    const queued_note: []const u8 = if (input.queued) |queued| switch (queued) {
        .build => "your build starts then",
        .flash => "your flash starts then",
    } else "";
    const long = if (warmup.estimate_ms) |estimate| estimate >= 20_000 else true;
    const time: []const u8 = if (warmup.estimate_ms) |estimate| time: {
        const left = estimate -| warmup.elapsed_ms;
        break :time if (left < 5000) "almost done" else if (!long) "a few seconds" else if (left < 50_000) "less than a minute" else "about a minute";
    } else "about a minute";
    const hint = if (queued_note.len != 0)
        print(&text.hint, "{s} · {s}", .{ time, queued_note })
    else if (long)
        print(&text.hint, "first start after an update · {s} · the fans may spin up", .{time})
    else
        time;
    const progress: Progress = if (warmup.estimate_ms) |estimate|
        .{ .fraction = @min(0.97, @as(f32, @floatFromInt(warmup.elapsed_ms)) / @as(f32, @floatFromInt(@max(estimate, 1)))) }
    else
        .indeterminate;
    const build: Button = if (input.queued == .build)
        .{ .style = .queued, .label = "Queued…", .icon = .build, .tooltip = "Builds when the caches are ready · click to cancel" }
    else
        .{ .style = .preparing, .label = "Build", .icon = .build, .tooltip = warmup_tip, .enabled = input.can_build };
    const flash: Button = if (input.queued == .flash)
        .{ .style = .queued, .label = "Queued…", .icon = .flash, .tooltip = "Flashes when the caches are ready · click to cancel" }
    else
        .{ .style = .off, .label = "Flash", .icon = .flash, .tooltip = warmup_tip, .enabled = input.can_flash };
    return .{
        .tone = .preparing,
        .message = "Preparing build caches",
        .hint = hint,
        .progress = progress,
        .build = build,
        .flash = flash,
        .headline = "Preparing build caches",
        .detail = if (input.queued != null)
            "Compiling the build tools for this version of Zigmkay, once per update. Your click runs as soon as it is done."
        else
            "Compiling the build tools for this version of Zigmkay, once per update. Build and Flash are available when it is done.",
        .steps = .{ .active, .pending, .pending, .pending },
    };
}

fn buildFailedState(input: Input, errors: Errors, text: *Text) State {
    const message = if (errors.count != 0)
        print(&text.message, "Build failed · {f} · open Details", .{errors})
    else
        "Build failed · open Details";
    const detail = if (errors.count != 0)
        print(&text.detail, "{f}. The compiler output shows the file and line.", .{errors})
    else if (input.build_failure.len != 0)
        print(&text.detail, "The build stopped: {s}.", .{input.build_failure})
    else
        "The build stopped. The compiler output shows why.";
    return .{
        .tone = .failed,
        .message = message,
        .build = .{ .style = .failed, .label = "Build failed", .icon = .warning, .tooltip = "Build again", .enabled = input.can_build },
        .flash = .{ .style = .off, .label = "Flash", .icon = .flash, .tooltip = "Available once the layout builds", .enabled = input.can_flash },
        .headline = "Build failed",
        .detail = detail,
        .steps = .{ .done, .failed, .pending, .pending },
        .show_output = true,
    };
}

fn flashFailedState(input: Input) State {
    return .{
        .tone = .failed,
        .message = "Flash failed · open Details",
        .build = if (input.built != null)
            .{ .style = .done, .label = "Built", .icon = .check, .tooltip = "Build again", .enabled = input.can_build }
        else
            .{ .label = "Build", .icon = .build, .enabled = input.can_build },
        .flash = .{ .style = .failed, .label = "Flash failed", .icon = .warning, .tooltip = "Flash again", .enabled = input.can_flash },
        .headline = "Flash failed",
        .detail = if (input.flash_failure.len != 0) input.flash_failure else input.flash_status,
        .steps = .{ .done, .done, .failed, .pending },
    };
}

/// Nothing runs: the layout is on the keyboard, built, changed or new.
fn settledState(input: Input, text: *Text) State {
    var state: State = .{};
    state.build.enabled = input.can_build;
    state.flash.enabled = input.can_flash;
    const just_flashed = input.flash == .done and input.flash.done < flashed_ms;
    if (just_flashed) {
        state.build = .{ .style = .done, .label = "Built", .icon = .check, .enabled = input.can_build };
        state.flash = .{ .style = .done, .label = "Flashed", .icon = .check, .enabled = input.can_flash };
    }
    if (input.keyboard_runs_layout) {
        state.message = "Ready · the keyboard runs this layout";
        state.headline = "The keyboard runs this layout";
        state.detail = "The connected keyboard reported exactly the layout in the editor.";
        state.steps = @splat(.done);
        return state;
    }
    if (input.built) |built| {
        state.steps = .{ .done, .done, .pending, .pending };
        if (input.flash == .done) {
            state.message = if (just_flashed) "Flashed" else "Ready · built";
            state.headline = "Flashed";
            state.detail = "The keyboard is not connected or has not verified this layout yet.";
            state.steps = .{ .done, .done, .done, .pending };
            return state;
        }
        if (!built.by_user) {
            state.message = "Ready · built";
            state.headline = "Built";
            state.detail = "This layout is built. Flash puts it on the keyboard.";
            return state;
        }
        state.tone = .next;
        state.message = print(&text.message, "Built in {f} · flash to put it on the keyboard", .{activity.seconds(built.duration_ms)});
        state.headline = "Built, not flashed yet";
        state.detail = "Flash puts this layout on the keyboard. The keyboard restarts once.";
        state.build = .{ .style = .done, .label = "Built", .icon = .check, .tooltip = "Build again", .enabled = input.can_build };
        state.flash = .{ .style = .next, .label = "Flash", .icon = .flash, .tooltip = "Put this layout on the keyboard", .enabled = input.can_flash };
        return state;
    }
    if (input.changed) {
        state.tone = .next;
        if (input.auto_build) {
            state.message = "Layout changed · Auto-build starts in a moment";
            state.headline = "Layout changed";
            state.detail = "Auto-build builds the layout once you pause editing.";
            return state;
        }
        state.message = "Layout changed · build to try it on the keyboard";
        state.headline = "Layout changed";
        state.detail = "Build compiles the changed layout; Flash then puts it on the keyboard. Auto-build does the first step for you.";
        state.build.style = .next;
        state.build.tooltip = "Compile the changed layout";
        return state;
    }
    state.detail = "Build compiles this layout into firmware; Flash puts it on the keyboard.";
    return state;
}

fn print(buffer: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, fmt, args) catch buffer;
}

const testing = std.testing;

fn expectButton(expected_style: Style, expected_label: []const u8, button: Button) !void {
    try testing.expectEqual(expected_style, button.style);
    try testing.expectEqualStrings(expected_label, button.label);
}

test "while the caches are prepared Build and Flash look disabled but queue a click" {
    var text: Text = .{};
    const cold = derive(.{ .warmup = .{ .elapsed_ms = 5000 } }, &text);
    try testing.expectEqual(Tone.preparing, cold.tone);
    try testing.expectEqualStrings("Preparing build caches", cold.message);
    try testing.expectEqualStrings("first start after an update · about a minute · the fans may spin up", cold.hint);
    try testing.expectEqual(Progress.indeterminate, cold.progress);
    try expectButton(.preparing, "Build", cold.build);
    try expectButton(.off, "Flash", cold.flash);
    try testing.expect(cold.build.enabled and cold.flash.enabled);
    try testing.expectEqualStrings(warmup_tip, cold.flash.tooltip);
    try testing.expectEqual(Step.active, cold.steps[0]);

    const estimated = derive(.{ .warmup = .{ .elapsed_ms = 14_000, .estimate_ms = 35_000 } }, &text);
    try testing.expectApproxEqAbs(@as(f32, 0.4), estimated.progress.fraction, 0.001);
    try testing.expectEqualStrings("first start after an update · less than a minute · the fans may spin up", estimated.hint);
    const overdue = derive(.{ .warmup = .{ .elapsed_ms = 50_000, .estimate_ms = 35_000 } }, &text);
    try testing.expectApproxEqAbs(@as(f32, 0.97), overdue.progress.fraction, 0.001);
    try testing.expectEqualStrings("first start after an update · almost done · the fans may spin up", overdue.hint);
    const warm = derive(.{ .warmup = .{ .elapsed_ms = 300, .estimate_ms = 12_000 } }, &text);
    try testing.expectEqualStrings("a few seconds", warm.hint);
    const ending = derive(.{ .warmup = .{ .elapsed_ms = 2000, .estimate_ms = 6000 } }, &text);
    try testing.expectEqualStrings("almost done", ending.hint);

    const build = derive(.{ .warmup = .{ .elapsed_ms = 5000 }, .queued = .build }, &text);
    try expectButton(.queued, "Queued…", build.build);
    try expectButton(.off, "Flash", build.flash);
    try testing.expectEqualStrings("about a minute · your build starts then", build.hint);
    const flash = derive(.{ .warmup = .{ .elapsed_ms = 5000 }, .queued = .flash }, &text);
    try expectButton(.preparing, "Build", flash.build);
    try expectButton(.queued, "Queued…", flash.flash);
    try testing.expect(flash.working());
}

test "ready names the keyboard only when it verified this exact layout" {
    var text: Text = .{};
    const runs = derive(.{ .keyboard_runs_layout = true, .changed = true, .built = .{ .duration_ms = 1, .by_user = true } }, &text);
    try testing.expectEqual(Tone.ready, runs.tone);
    try testing.expectEqualStrings("Ready · the keyboard runs this layout", runs.message);
    try expectButton(.idle, "Build", runs.build);
    try expectButton(.idle, "Flash", runs.flash);
    try testing.expect(!runs.working());
    const warm_built = derive(.{ .built = .{ .duration_ms = 30_000, .by_user = false } }, &text);
    try testing.expectEqualStrings("Ready · built", warm_built.message);
    try expectButton(.idle, "Flash", warm_built.flash);
    const fresh = derive(.{}, &text);
    try testing.expectEqualStrings("Ready", fresh.message);
    try expectButton(.idle, "Build", fresh.build);
}

test "a changed layout makes Build the next step unless Auto-build takes it" {
    var text: Text = .{};
    const manual = derive(.{ .changed = true }, &text);
    try testing.expectEqual(Tone.next, manual.tone);
    try testing.expectEqualStrings("Layout changed · build to try it on the keyboard", manual.message);
    try expectButton(.next, "Build", manual.build);
    try expectButton(.idle, "Flash", manual.flash);
    const automatic = derive(.{ .changed = true, .auto_build = true }, &text);
    try expectButton(.idle, "Build", automatic.build);
    try testing.expectEqualStrings("Layout changed · Auto-build starts in a moment", automatic.message);
}

test "a build names what started it and keeps Flash waiting" {
    var text: Text = .{};
    const auto = derive(.{ .building = .{ .trigger = .auto_build, .elapsed_ms = 2400 } }, &text);
    try testing.expectEqual(Tone.busy, auto.tone);
    try testing.expectEqualStrings("Building firmware…", auto.message);
    try testing.expectEqualStrings("started by Auto-build · 2 s", auto.hint);
    try expectButton(.working, "Building…", auto.build);
    try expectButton(.off, "Flash", auto.flash);
    try testing.expectEqual([_]Step{ .done, .active, .pending, .pending }, auto.steps);
    const click = derive(.{ .building = .{ .trigger = .click, .elapsed_ms = 900, .first = true } }, &text);
    try testing.expectEqualStrings("first build may take a few minutes · 0 s", click.hint);
    const for_flash = derive(.{ .building = .{ .trigger = .flash, .elapsed_ms = 1000 } }, &text);
    try expectButton(.queued, "Queued…", for_flash.flash);
    try testing.expectEqualStrings("Flash follows · 1 s", for_flash.hint);
}

test "a build of the layout not on the keyboard makes Flash the next step" {
    var text: Text = .{};
    const built = derive(.{ .built = .{ .duration_ms = 1200, .by_user = true } }, &text);
    try testing.expectEqual(Tone.next, built.tone);
    try testing.expectEqualStrings("Built in 1.2 s · flash to put it on the keyboard", built.message);
    try expectButton(.done, "Built", built.build);
    try testing.expectEqual(Icon.check, built.build.icon);
    try expectButton(.next, "Flash", built.flash);
}

test "flashing sweeps Flash and settles on Flashed for five seconds" {
    var text: Text = .{};
    const writing = derive(.{ .built = .{ .duration_ms = 1, .by_user = true }, .flash = .{ .working = .writing } }, &text);
    try testing.expectEqualStrings("Writing firmware", writing.message);
    try testing.expectEqualStrings("keep the keyboard plugged in", writing.hint);
    try expectButton(.working, "Flashing…", writing.flash);
    try expectButton(.done, "Built", writing.build);
    try testing.expect(!writing.build.enabled);
    try testing.expectEqual(Progress.none, writing.progress);
    const manual = derive(.{ .flash = .{ .working = .bootloader }, .flash_status = "Keyboard not in BOOTSEL yet. Hold BOOTSEL…" }, &text);
    try testing.expectEqualStrings("Waiting for the bootloader", manual.message);
    try testing.expectEqualStrings("Keyboard not in BOOTSEL yet. Hold BOOTSEL…", manual.detail);

    const built: Built = .{ .duration_ms = 1, .by_user = true };
    const flashed = derive(.{ .built = built, .flash = .{ .done = 1000 }, .keyboard_runs_layout = true }, &text);
    try expectButton(.done, "Flashed", flashed.flash);
    try testing.expectEqualStrings("Ready · the keyboard runs this layout", flashed.message);
    const later = derive(.{ .built = built, .flash = .{ .done = flashed_ms }, .keyboard_runs_layout = true }, &text);
    try expectButton(.idle, "Flash", later.flash);
    try expectButton(.idle, "Build", later.build);
    const unverified = derive(.{ .built = built, .flash = .{ .done = flashed_ms + 1 } }, &text);
    try testing.expectEqualStrings("Ready · built", unverified.message);
    try expectButton(.idle, "Flash", unverified.flash);
}

test "failures point to Details; a build failure opens the compiler output" {
    var text: Text = .{};
    const located = derive(.{ .build_failed = .{ .count = 1, .keymap = true } }, &text);
    try testing.expectEqual(Tone.failed, located.tone);
    try testing.expectEqualStrings("Build failed · 1 error in the keymap · open Details", located.message);
    try expectButton(.failed, "Build failed", located.build);
    try expectButton(.off, "Flash", located.flash);
    try testing.expect(located.show_output);
    try testing.expectEqual(Step.failed, located.steps[1]);
    const unlocated = derive(.{ .build_failed = .{}, .build_failure = "BuildTimeout" }, &text);
    try testing.expectEqualStrings("Build failed · open Details", unlocated.message);
    try testing.expectEqualStrings("The build stopped: BuildTimeout.", unlocated.detail);

    const flash = derive(.{ .built = .{ .duration_ms = 1, .by_user = true }, .flash = .failed, .flash_failure = "FlashJobFailed" }, &text);
    try testing.expectEqualStrings("Flash failed · open Details", flash.message);
    try expectButton(.failed, "Flash failed", flash.flash);
    try expectButton(.done, "Built", flash.build);
    try testing.expect(!flash.show_output);
}

test "a failed warm-up leaves Build and Flash enabled as usual" {
    var text: Text = .{};
    // The warm-up only logs its failure; the state no longer reports it.
    const after = derive(.{}, &text);
    try expectButton(.idle, "Build", after.build);
    try testing.expect(after.build.enabled and after.flash.enabled);
}

test "without a toolchain Build and Flash are off" {
    var text: Text = .{};
    const none = derive(.{ .toolchain = false, .changed = true }, &text);
    try testing.expectEqual(Tone.unavailable, none.tone);
    try expectButton(.off, "Build", none.build);
    try testing.expect(!none.build.enabled and !none.flash.enabled);
}
