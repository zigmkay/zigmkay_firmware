//! Standalone design mockups with illustrative data; no device or user-data access.
const std = @import("std");

const Canvas = struct {
    out: std.Io.Writer.Allocating,

    fn init(gpa: std.mem.Allocator) Canvas {
        return .{ .out = .init(gpa) };
    }

    fn rect(c: *Canvas, x: f64, y: f64, w: f64, h: f64, fill: []const u8) !void {
        try c.out.writer.print(
            "<rect x='{d}' y='{d}' width='{d}' height='{d}' rx='12' fill='{s}'/>",
            .{ x, y, w, h, fill },
        );
    }

    fn text(c: *Canvas, x: f64, y: f64, size: u32, fill: []const u8, value: []const u8) !void {
        try c.out.writer.print(
            "<text xml:space='preserve' x='{d}' y='{d}' font-size='{d}' fill='{s}'>{s}</text>",
            .{ x, y, size, fill, value },
        );
    }

    fn label(c: *Canvas, x: f64, y: f64, value: []const u8) !void {
        try c.text(x, y, 18, "#A5B0BD", value);
    }

    fn title(c: *Canvas, x: f64, y: f64, value: []const u8) !void {
        try c.text(x, y, 25, "#F0F3F7", value);
    }

    fn button(c: *Canvas, x: f64, y: f64, w: f64, value: []const u8, primary: bool) !void {
        try c.rect(x, y, w, 44, if (primary) "#246CF6" else "#303740");
        try c.text(x + 16, y + 28, 18, "#F0F3F7", value);
    }

    fn start(c: *Canvas, package: []const u8, page: []const u8, sub: []const u8) !void {
        try c.out.writer.writeAll(
            "<svg xmlns='http://www.w3.org/2000/svg' width='1440' height='960' viewBox='0 0 1440 960'><g font-family='Helvetica,Arial,sans-serif'>",
        );
        try c.rect(0, 0, 1440, 960, "#191D22");
        try c.rect(0, 0, 1440, 56, "#23292F");
        try c.text(28, 36, 20, "#F0F3F7", "Zigmkay   /   Typing practice");
        try c.text(1075, 36, 16, "#A5B0BD", package);
        try c.button(32, 77, 125, "Practice", false);
        try c.button(170, 77, 125, "Progress", false);
        try c.label(1100, 104, "Eurmac · verified layout");
        try c.text(32, 177, 36, "#F0F3F7", page);
        try c.label(32, 209, sub);
        try c.label(32, 931, "Design mockup · example data · not a live DVUI screen");
    }

    fn end(c: *Canvas) !void {
        try c.out.writer.writeAll("</g></svg>");
    }

    fn card(c: *Canvas, x: f64, y: f64, w: f64, h: f64, heading: []const u8) !void {
        try c.rect(x, y, w, h, "#232A32");
        try c.title(x + 24, y + 40, heading);
    }

    fn metric(c: *Canvas, x: f64, y: f64, name: []const u8, value: []const u8, detail: []const u8) !void {
        try c.rect(x, y, 322, 130, "#232A32");
        try c.label(x + 22, y + 30, name);
        try c.text(x + 22, y + 77, 36, "#F0F3F7", value);
        try c.text(x + 22, y + 109, 16, "#7ED6B1", detail);
    }

    fn line(c: *Canvas, x: f64, y: f64, w: f64, h: f64, color: []const u8, values: []const f64) !void {
        for (0..4) |i| {
            const yy = y + @as(f64, @floatFromInt(i)) * h / 3;
            try c.out.writer.print(
                "<path d='M {d} {d} H {d}' stroke='#39424E' fill='none'/>",
                .{ x, yy, x + w },
            );
        }
        try c.out.writer.print(
            "<polyline fill='none' stroke='{s}' stroke-width='3' stroke-linejoin='round' points='",
            .{color},
        );
        for (values, 0..) |v, i| try c.out.writer.print("{d},{d} ", .{
            x + @as(f64, @floatFromInt(i)) * w / @as(f64, @floatFromInt(values.len - 1)),
            y + h - v * h,
        });
        try c.out.writer.writeAll("'/>");
    }

    fn keys(c: *Canvas, x: f64, y: f64, guided: bool) !void {
        const letters = "qwertyuiopasdfghjkl;zxcvbnm,./";
        const size: f64 = 42;
        for (letters, 0..) |_, i| {
            const xx = x + @as(f64, @floatFromInt(i % 10)) * (size + 7) + (if (i % 10 >= 5) @as(f64, 40) else 0);
            const yy = y + @as(f64, @floatFromInt(i / 10)) * (size + 7);
            const fill = if (guided) (if (i == 10 or i == 16) "#246CF6" else "#39424E") else (if (i == 2 or i == 3 or i == 19) "#71552A" else if (i % 6 == 0) "#39424E" else "#285446");
            try c.rect(xx, yy, size, size, fill);
            try c.text(xx + size * 0.35, yy + size * 0.64, 20, "#F0F3F7", letters[i .. i + 1]);
            if (guided and i == 16) try c.text(xx + 6, yy + 39, 9, "#F0F3F7", "Shift");
        }
        const thumbs = [_][]const u8{ "Space", "L1", "Tab", "L2" };
        for (thumbs, 0..) |name, i| {
            const xx = x + 3 * (size + 7) + @as(f64, @floatFromInt(i)) * (size + 7) + (if (i >= 2) @as(f64, 40) else 0);
            try c.rect(xx, y + 3 * (size + 7), size, size, "#39424E");
            try c.text(xx + 4, y + 3 * (size + 7) + 26, 12, "#F0F3F7", name);
        }
    }
};

fn draw(c: *Canvas, n: usize) !void {
    switch (n) {
        0 => {
            try c.start(
                "A · Timing and storage",
                "Practice data",
                "Timing collection stays quiet. Data controls live in Settings.",
            );
            try c.card(32, 245, 740, 625, "Local practice history");
            try c.label(56, 322, "Save completed exercises and their timing datapoints");
            try c.button(56, 355, 245, "Timing collection   ON", true);
            try c.title(56, 452, "Stored on this computer");
            try c.label(56, 493, "Exercise timing, corrections, pauses and hint usage.");
            try c.label(56, 528, "Only input inside an active practice exercise is recorded.");
            try c.label(56, 563, "Older runs remain available; their timing is unavailable.");
            try c.button(56, 642, 192, "Export history…", false);
            try c.button(262, 642, 205, "Open data folder", false);
            try c.button(56, 724, 192, "Clear history…", false);
            try c.card(800, 245, 608, 300, "Your practice continues as usual");
            try c.label(824, 327, "46 WPM      97.5% accuracy      Ready");
            try c.rect(824, 356, 558, 104, "#303740");
            try c.text(850, 418, 26, "#F0F3F7", "learn   earlier   line   area");
            try c.button(824, 463, 160, "Start", true);
            try c.card(800, 571, 608, 299, "History available");
            try c.title(824, 655, "24 completed runs");
            try c.label(824, 701, "Saved locally · last saved just now");
            try c.label(824, 749, "Data collection adds no charts to the tutor.");
        },
        1 => {
            try c.start(
                "B · Clearer rundown",
                "Exercise complete",
                "Words · Normal · Guided · compare with your last 10 matching runs",
            );
            try c.metric(32, 243, "Typing speed", "46 WPM", "+4 WPM against recent average");
            try c.metric(380, 243, "Attempt accuracy", "97.5%", "+1.2 percentage points");
            try c.metric(728, 243, "First-pass success", "96.8%", "7 corrections · 1m 24s active");
            try c.rect(1076, 243, 332, 130, "#263B35");
            try c.title(1097, 284, "A useful next step");
            try c.button(1097, 306, 288, "Practice e and r", true);
            try c.rect(32, 397, 1376, 67, "#253730");
            try c.text(
                54,
                437,
                21,
                "#B5EBD3",
                "Common letters improved. Most mistakes were e → r. Try a short contrast exercise.",
            );
            try c.card(32, 488, 688, 335, "Where errors happened");
            try c.button(56, 550, 184, "Miss rate ▾", false);
            try c.button(254, 550, 130, "Base ▾", false);
            try c.keys(56, 618, false);
            try c.card(746, 488, 662, 335, "Characters to review");
            const columns = [_]f64{ 770, 875, 1030, 1140 };
            const headings = [_][]const u8{ "Character", "First-pass", "Exposure", "Common error" };
            for (columns, headings) |xx, heading| try c.label(xx, 562, heading);
            const rows = [_][4][]const u8{
                .{ "e", "88%", "25", "e → r × 3" },
                .{ "r", "93%", "14", "r → e × 1" },
                .{ ";", "50%", "2", "Limited evidence" },
            };
            for (rows, 0..) |row, i| for (columns, row) |xx, value| try c.text(
                xx,
                615 + @as(f64, @floatFromInt(i)) * 54,
                19,
                "#F0F3F7",
                value,
            );
            try c.button(32, 850, 192, "New exercise", true);
            try c.button(238, 850, 180, "View progress", false);
            try c.button(1108, 850, 300, "More details…", false);
        },
        2 => {
            try c.start("C · Progress", "Your progress", "Eurmac · Words · Guided · last 30 matching runs");
            try c.metric(32, 243, "Today", "12 minutes", "Daily goal: 12 / 15 minutes");
            try c.metric(380, 243, "Recent average", "46 WPM", "+8 WPM since your first week");
            try c.metric(728, 243, "Accuracy streak", "5 exercises", "At least 97% attempt accuracy");
            try c.button(1076, 266, 332, "Last 30 runs ▾", false);
            try c.card(32, 398, 800, 242, "Speed over time");
            try c.line(
                88,
                478,
                701,
                110,
                "#7ED6B1",
                &.{ 0.15, 0.3, 0.27, 0.44, 0.41, 0.58, 0.49, 0.67, 0.61, 0.8 },
            );
            try c.label(
                56,
                610,
                "30 WPM                                    Runs 1–30                                  50 WPM",
            );
            try c.card(32, 659, 800, 226, "Accuracy over time");
            try c.line(
                88,
                735,
                701,
                99,
                "#91B8FF",
                &.{ 0.2, 0.4, 0.34, 0.54, 0.48, 0.68, 0.62, 0.7, 0.77, 0.87 },
            );
            try c.label(
                56,
                861,
                "95%                                          Same runs                                       100%",
            );
            try c.card(860, 398, 548, 487, "Character progress");
            try c.label(884, 468, "First-pass success · gaps mean no practice");
            for (0..8) |r| {
                try c.text(884, 519 + @as(f64, @floatFromInt(r)) * 35, 17, "#F0F3F7", "earlint;"[r .. r + 1]);
                for (0..14) |col| try c.rect(
                    919 + @as(f64, @floatFromInt(col)) * 32,
                    497 + @as(f64, @floatFromInt(r)) * 35,
                    27,
                    25,
                    if ((r + col) % 11 == 0) "#39424E" else if (col < 4 and r % 3 == 0) "#71552A" else if (col < 8) "#386A55" else "#4DAA7C",
                );
            }
            try c.label(884, 826, "Earlier                                      Most recent");
            try c.label(884, 860, "Select a character for details →");
        },
        3 => {
            try c.start(
                "D · Detailed diagnostics",
                "Character details: e",
                "Opened from rundown or Progress · measurements are illustrative",
            );
            try c.metric(32, 243, "Clean character interval", "240 ms", "Median · 120 valid intervals");
            try c.metric(380, 243, "First-pass success", "96.2%", "5 missed / 132 opportunities");
            try c.metric(728, 243, "Slow tail", "510 ms", "90th percentile · excludes pauses");
            try c.button(1076, 280, 332, "Practice this character", true);
            try c.card(32, 398, 842, 277, "Character interval over time");
            try c.line(
                85,
                478,
                737,
                132,
                "#7ED6B1",
                &.{ 0.9, 0.78, 0.6, 0.64, 0.4, 0.43, 0.37, 0.2, 0.25, 0.14 },
            );
            try c.out.writer.writeAll("<path d='M 85 582 H 822' stroke='#A5B0BD' stroke-dasharray='5 5'/>");
            try c.label(56, 649, "500 ms → 240 ms     Lower is faster · target 260 ms");
            try c.card(903, 398, 505, 277, "Difficult transitions");
            try c.label(927, 478, "r → e      420 ms       8 observations");
            try c.label(927, 525, "e → ;      680 ms       6 observations");
            try c.label(927, 572, "Common substitution: e → r");
            try c.label(927, 628, "Physical route: possible, not observed");
            try c.card(32, 698, 1376, 187, "Last run: rhythm and corrections");
            try c.line(
                84,
                765,
                990,
                76,
                "#91B8FF",
                &.{ 0.5, 0.7, 0.3, 0.45, 0.7, 0.73, 0.65, 0.32, 0.68, 0.77 },
            );
            try c.out.writer.writeAll(
                "<path d='M 304 765 V 841' stroke='#E6A976'/><circle cx='304' cy='841' r='5' fill='#E6A976'/><path d='M 854 765 V 841' stroke='#A89ADF'/><circle cx='854' cy='841' r='5' fill='#A89ADF'/>",
            );
            try c.label(1100, 773, "● Error   ● Hint");
            try c.label(1100, 814, "Pause excluded");
            try c.label(
                56,
                866,
                "0s                      Select an event to inspect its practice context                     84s",
            );
        },
        4 => {
            try c.start(
                "E · Adaptive curriculum",
                "Learn your layout",
                "Difficulty, assistance and exercise length are independent.",
            );
            try c.card(32, 243, 401, 645, "Your learning path");
            const stages = [_][]const u8{
                "1   Find the keys          Complete",
                "2   Build fluency           Current",
                "3   Add Shift                 Next",
                "4   Change layers",
                "5   Combine modifiers",
                "6   Use real text",
            };
            for (stages, 0..) |stage, i| {
                if (i == 1) try c.rect(51, 355, 363, 59, "#29483D");
                try c.text(
                    56,
                    332 + @as(f64, @floatFromInt(i)) * 62,
                    19,
                    if (i == 1) "#B5EBD3" else "#A5B0BD",
                    stage,
                );
            }
            try c.label(56, 778, "Review or choose a stage yourself.");
            try c.button(56, 811, 348, "Choose another stage…", false);
            try c.card(461, 243, 947, 369, "Stage 2: Build fluency");
            try c.label(485, 323, "Current focus: r     ·     Next new character: t");
            try c.text(485, 387, 30, "#F0F3F7", "e   n   i   a   r   l       + t");
            try c.label(485, 439, "Accuracy goal reached in 3 runs. Timing needs more practice.");
            try c.rect(485, 467, 875, 13, "#39424E");
            try c.rect(485, 467, 610, 13, "#55BD8E");
            try c.label(485, 523, "You can add t now, or let the tutor recommend when to progress.");
            try c.card(461, 638, 947, 250, "Next exercise");
            try c.button(485, 718, 250, "Guided ▾", false);
            try c.button(753, 718, 250, "Short · 2 units ▾", false);
            try c.label(485, 817, "Readable words · mostly familiar keys · extra r practice");
            try c.button(1114, 718, 270, "Start exercise", true);
        },
        5 => {
            try c.start(
                "F · Help and retention",
                "Stage 3: Add Shift",
                "A focused exercise with deliberate hints and spaced review",
            );
            try c.button(32, 246, 290, "Hints after hesitation ▾", false);
            try c.button(339, 246, 220, "Short · 2 units ▾", false);
            try c.label(952, 275, "Recall check · capitals learned yesterday");
            try c.rect(32, 320, 1376, 146, "#232A32");
            try c.text(62, 410, 44, "#F0F3F7", "A   Little   River   Near   The   Lane");
            try c.card(32, 494, 826, 280, "Keyboard guide");
            try c.keys(56, 564, true);
            try c.card(886, 494, 522, 280, "Hint for capital A");
            try c.text(910, 578, 21, "#F0F3F7", "Hold right home-row Shift");
            try c.text(910, 618, 21, "#F0F3F7", "Then tap A with your left hand");
            try c.label(910, 659, "Shown after hesitation · counted as assisted");
            try c.button(910, 698, 220, "Show full guidance", false);
            try c.rect(32, 800, 1376, 86, "#253730");
            try c.text(
                56,
                836,
                20,
                "#B5EBD3",
                "Next review: lowercase transitions · retained from an earlier session",
            );
            try c.label(
                56,
                866,
                "Recent assisted successes and unaided recall stay separate in your progress.",
            );
        },
        else => unreachable,
    }
}

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0")) return error.WrongCompiler;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer dir.close(init.io);
    var sheet = Canvas.init(init.gpa);
    defer sheet.out.deinit();
    try sheet.out.writer.writeAll(
        "<svg xmlns='http://www.w3.org/2000/svg' width='1440' height='1440' viewBox='0 0 2880 2880'>",
    );
    const names = [_][]const u8{
        "01-data.svg",
        "02-rundown.svg",
        "03-progress.svg",
        "04-diagnostics.svg",
        "05-curriculum.svg",
        "06-help.svg",
    };
    for (names, 0..) |name, n| {
        var c = Canvas.init(init.gpa);
        defer c.out.deinit();
        try draw(&c, n);
        try c.end();
        try dir.writeFile(init.io, .{ .sub_path = name, .data = c.out.written() });
        try sheet.out.writer.print(
            "<g transform='translate({d} {d})'>{s}</g>",
            .{ (n % 2) * 1440, (n / 2) * 960, c.out.written() },
        );
    }
    try sheet.out.writer.writeAll("</svg>");
    try dir.writeFile(init.io, .{ .sub_path = "00-overview.svg", .data = sheet.out.written() });
}
