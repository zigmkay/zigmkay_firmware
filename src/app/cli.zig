//! Command-line modes of the desktop executable.
//!
//! Without arguments the editor starts and monitors keyboards. Fixture modes
//! render a bounded number of frames and never open a device; they require the
//! SDL dummy video driver unless they exist to exercise native video.
const std = @import("std");

pub const Mode = union(enum) {
    editor: Editor,
    /// `--physical-flash-once`: one explicitly authorized hardware flash trial.
    physical_flash,
    fixture: Fixture,

    pub fn frameLimit(mode: Mode) ?usize {
        return switch (mode) {
            .fixture => |fixture| fixture.frames,
            else => null,
        };
    }

    pub fn liveEnabled(mode: Mode) bool {
        return switch (mode) {
            .editor => |editor| editor.live != null or (!editor.offline and editor.light == null),
            .physical_flash => true,
            .fixture => false,
        };
    }

    pub fn fixtureKind(mode: Mode) ?Fixture.Kind {
        return switch (mode) {
            .fixture => |fixture| fixture.kind,
            else => null,
        };
    }

    /// Whether the mode is the fixture `tag`.
    pub fn is(mode: Mode, tag: std.meta.Tag(Fixture.Kind)) bool {
        const kind = mode.fixtureKind() orelse return false;
        return kind == tag;
    }

    pub fn light(mode: Mode) ?Editor.Light {
        return switch (mode) {
            .editor => |editor| editor.light,
            else => null,
        };
    }

    pub fn background(mode: Mode) bool {
        return switch (mode) {
            .editor => |editor| editor.background,
            else => false,
        };
    }

    pub fn live(mode: Mode) ?Editor.Live {
        return switch (mode) {
            .editor => |editor| editor.live,
            else => null,
        };
    }

    pub fn isStatus(mode: Mode) bool {
        return mode.is(.status) or mode.is(.native_status);
    }

    /// The onboarding gallery, offscreen or with the native renderer.
    pub fn isOnboarding(mode: Mode) bool {
        return mode.is(.onboarding) or mode.is(.native_onboarding);
    }

    pub fn isDrawers(mode: Mode) bool {
        return mode.is(.drawers) or mode.is(.native_drawers);
    }

    /// Draft fixtures feed key events through the native runner processor.
    pub fn isDraft(mode: Mode) bool {
        return mode.is(.draft) or mode.is(.build);
    }
};

pub const Editor = struct {
    background: bool = false,
    offline: bool = false,
    /// Light-theme previews never monitor keyboards.
    light: ?Light = null,
    live: ?Live = null,

    pub const Light = enum { editor, tutor, companion };

    pub const Live = struct {
        visibility: Visibility,
        /// Absolute project directory to open before monitoring starts.
        project: ?[]const u8 = null,
    };

    pub const Visibility = enum { tap_hold, hold, toggle };
};

pub const Fixture = struct {
    kind: Kind,
    frames: usize,

    pub const Kind = union(enum) {
        /// `--offline-frames`
        launch,
        onboarding,
        catalog,
        status,
        /// `--offline-drawers-frames`: the combo, callback and encoder drawers.
        drawers,
        native_status,
        native_drawers,
        native_onboarding,
        practice,
        /// `--native-tutor-frames`: screenshots of the tutor's typing tests.
        native_tutor,
        companion,
        native_tray,
        source_refresh,
        build,
        /// Absolute path of the runner manifest.
        draft: []const u8,

        fn minimumFrames(kind: Kind) usize {
            return switch (kind) {
                .native_tutor => 16,
                .companion => 9,
                .practice, .native_tray, .source_refresh => 3,
                .build => 2,
                else => 1,
            };
        }

        fn maximumFrames(kind: Kind) usize {
            return switch (kind) {
                .build => 30_000,
                .draft => 1000,
                else => 100,
            };
        }

        fn needsNativeVideo(kind: Kind) bool {
            return switch (kind) {
                .native_tray, .native_tutor, .native_status, .native_drawers, .native_onboarding => true,
                else => false,
            };
        }
    };
};

pub const Environment = struct {
    /// `ZIGMKAY_EXPLICIT_FLASH_TRIAL`
    flash_trial: ?[]const u8 = null,
    /// `SDL_VIDEODRIVER`
    video_driver: ?[]const u8 = null,
};

pub const Error = error{
    Usage,
    InvalidFrameLimit,
    AbsoluteRunnerManifestRequired,
    NativeVideoRequired,
    DummyVideoRequired,
    ExplicitFlashAuthorizationRequired,
} || std.fmt.ParseIntError;

pub fn parse(args: []const [:0]const u8, environment: Environment) Error!Mode {
    if (args.len <= 1) return .{ .editor = .{} };
    const flag = args[1];
    if (std.mem.eql(u8, flag, "--physical-flash-once")) {
        const authorized = std.mem.eql(u8, environment.flash_trial orelse "", "1");
        if (args.len != 2 or !authorized) return error.ExplicitFlashAuthorizationRequired;
        return .physical_flash;
    }
    if (args.len == 2) if (parseEditor(flag)) |editor| return .{ .editor = editor };
    if (args.len == 3) if (parseVisibility(flag)) |visibility| {
        return .{ .editor = .{ .live = .{ .visibility = visibility, .project = args[2] } } };
    };
    return .{ .fixture = try parseFixture(args, environment) };
}

fn parseEditor(flag: []const u8) ?Editor {
    if (parseVisibility(flag)) |visibility| return .{ .live = .{ .visibility = visibility } };
    const map = std.StaticStringMap(Editor).initComptime(.{
        .{ "--offline", Editor{ .offline = true } },
        .{ "--background", Editor{ .background = true } },
        .{ "--background-offline", Editor{ .background = true, .offline = true } },
        .{ "--light", Editor{ .light = .editor } },
        .{ "--light-tutor", Editor{ .light = .tutor } },
        .{ "--light-companion", Editor{ .light = .companion } },
    });
    return map.get(flag);
}

fn parseVisibility(flag: []const u8) ?Editor.Visibility {
    const map = std.StaticStringMap(Editor.Visibility).initComptime(.{
        .{ "--live", .tap_hold },
        .{ "--live-hold", .hold },
        .{ "--live-toggle", .toggle },
    });
    return map.get(flag);
}

fn parseFixture(args: []const [:0]const u8, environment: Environment) Error!Fixture {
    const draft = std.mem.eql(u8, args[1], "--offline-draft-frames");
    if (args.len != @as(usize, if (draft) 4 else 3)) return error.Usage;
    const kind: Fixture.Kind = if (draft) .{ .draft = args[3] } else try parseKind(args[1]);
    const frames = try std.fmt.parseInt(usize, args[2], 10);
    if (frames < kind.minimumFrames() or frames > kind.maximumFrames()) return error.InvalidFrameLimit;
    if (kind == .draft and !std.fs.path.isAbsolute(kind.draft)) return error.AbsoluteRunnerManifestRequired;
    const dummy = if (environment.video_driver) |driver| std.mem.eql(u8, driver, "dummy") else false;
    if (kind.needsNativeVideo()) {
        if (dummy) return error.NativeVideoRequired;
    } else if (!dummy) return error.DummyVideoRequired;
    return .{ .kind = kind, .frames = frames };
}

fn parseKind(flag: []const u8) error{Usage}!Fixture.Kind {
    const map = std.StaticStringMap(Fixture.Kind).initComptime(.{
        .{ "--offline-frames", .launch },
        .{ "--offline-onboarding-frames", .onboarding },
        .{ "--offline-catalog-frames", .catalog },
        .{ "--offline-status-frames", .status },
        .{ "--offline-drawers-frames", .drawers },
        .{ "--native-status-frames", .native_status },
        .{ "--native-drawers-frames", .native_drawers },
        .{ "--native-onboarding-frames", .native_onboarding },
        .{ "--offline-practice-frames", .practice },
        .{ "--native-tutor-frames", .native_tutor },
        .{ "--offline-companion-frames", .companion },
        .{ "--native-tray-frames", .native_tray },
        .{ "--offline-source-refresh-frames", .source_refresh },
        .{ "--offline-build-frames", .build },
    });
    return map.get(flag) orelse error.Usage;
}

const dummy_video: Environment = .{ .video_driver = "dummy" };

fn expectFixture(expected: Fixture, args: []const [:0]const u8, environment: Environment) !void {
    try std.testing.expectEqualDeep(Mode{ .fixture = expected }, try parse(args, environment));
}

test "interactive modes" {
    const t = std.testing;
    try t.expectEqualDeep(Mode{ .editor = .{} }, try parse(&.{"app"}, .{}));
    try t.expectEqualDeep(Mode{ .editor = .{ .offline = true } }, try parse(&.{ "app", "--offline" }, .{}));
    try t.expectEqualDeep(
        Mode{ .editor = .{ .background = true, .offline = true } },
        try parse(&.{ "app", "--background-offline" }, .{}),
    );
    try t.expectEqualDeep(Mode{ .editor = .{ .light = .tutor } }, try parse(&.{ "app", "--light-tutor" }, .{}));
    try t.expectEqualDeep(
        Mode{ .editor = .{ .live = .{ .visibility = .hold, .project = "/p" } } },
        try parse(&.{ "app", "--live-hold", "/p" }, .{}),
    );
    try t.expectError(error.Usage, parse(&.{ "app", "--offline", "3" }, dummy_video));
    try t.expectError(error.Usage, parse(&.{ "app", "--live", "/p", "x" }, dummy_video));
    try t.expect((try parse(&.{"app"}, .{})).liveEnabled());
    try t.expect(!(try parse(&.{ "app", "--light" }, .{})).liveEnabled());
}

test "physical flash requires explicit authorization" {
    const t = std.testing;
    try t.expectEqual(Mode.physical_flash, try parse(&.{ "app", "--physical-flash-once" }, .{ .flash_trial = "1" }));
    try t.expectError(error.ExplicitFlashAuthorizationRequired, parse(&.{ "app", "--physical-flash-once" }, .{}));
    try t.expectError(
        error.ExplicitFlashAuthorizationRequired,
        parse(&.{ "app", "--physical-flash-once", "x" }, .{ .flash_trial = "1" }),
    );
}

test "fixture modes keep their frame bounds and video requirements" {
    const t = std.testing;
    try expectFixture(.{ .kind = .launch, .frames = 3 }, &.{ "app", "--offline-frames", "3" }, dummy_video);
    try expectFixture(.{ .kind = .drawers, .frames = 24 }, &.{ "app", "--offline-drawers-frames", "24" }, dummy_video);
    try expectFixture(.{ .kind = .build, .frames = 30_000 }, &.{ "app", "--offline-build-frames", "30000" }, dummy_video);
    try expectFixture(
        .{ .kind = .{ .draft = "/m.zon" }, .frames = 600 },
        &.{ "app", "--offline-draft-frames", "600", "/m.zon" },
        dummy_video,
    );
    try expectFixture(.{ .kind = .native_tutor, .frames = 16 }, &.{ "app", "--native-tutor-frames", "16" }, .{});
    try t.expectError(error.InvalidFrameLimit, parse(&.{ "app", "--native-tutor-frames", "15" }, .{}));
    try t.expectError(error.InvalidFrameLimit, parse(&.{ "app", "--offline-frames", "101" }, dummy_video));
    try t.expectError(error.NativeVideoRequired, parse(&.{ "app", "--native-tutor-frames", "16" }, dummy_video));
    try t.expectError(error.AbsoluteRunnerManifestRequired, parse(&.{ "app", "--offline-draft-frames", "9", "m" }, dummy_video));
    try t.expectError(error.DummyVideoRequired, parse(&.{ "app", "--offline-frames", "3" }, .{}));
    try t.expectError(error.NativeVideoRequired, parse(&.{ "app", "--native-tray-frames", "3" }, dummy_video));
    try t.expectError(error.Usage, parse(&.{ "app", "--native-layout-status-frames", "3" }, .{}));
    try t.expectError(error.Usage, parse(&.{ "app", "--offline-draft-frames", "9" }, dummy_video));
}
