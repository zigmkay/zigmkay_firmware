//! Curriculum v1: reachable readable practice, separate from length and help.
const std = @import("std");
const practice = @import("practice.zig");
const generator = @import("practice_generator.zig");
pub const Stage = enum { find_keys, fluency, shift, layers, modifiers, real_text };

pub const names = [_][]const u8{
    "Find keys",
    "Build fluency",
    "Add Shift",
    "Change layers",
    "Combine modifiers",
    "Real text",
};

pub const alphabet_order = "enaritoslcdumpghbyfvkwzxjq";

pub const Context = struct {
    version: u16 = 0,
    stage: Stage = .find_keys,
    alphabet: u8 = 6,
    layer: u8 = 1,
    modifiers: u8 = 4,
    shifted_symbols: bool = false,
    family: u8 = 0,

    pub fn effective(self: Context) Context {
        if (self.version == 0) return self;
        var value = self;
        if (self.stage != .layers and self.stage != .modifiers) value.layer = 1;
        if (self.stage != .modifiers) value.modifiers = 4;
        if (self.stage != .shift) value.shifted_symbols = false;
        if (self.stage == .find_keys or self.stage == .fluency or self.stage == .real_text) value.family = 0;
        if (self.stage == .real_text) value.alphabet = 26;
        return value;
    }

    pub fn validate(self: Context) !void {
        if (self.version == 0) {
            if (!std.meta.eql(self, Context{})) return error.InvalidCurriculum;
        } else if (self.version != 1) return error.UnsupportedCurriculum else {
            if (self.alphabet < 6 or
                self.alphabet > 26 or
                self.layer > 14 or
                std.mem.indexOfScalar(
                    u8,
                    &.{ 4, 6, 64, 66 },
                    self.modifiers,
                ) == null) return error.InvalidCurriculum;
        }
    }
};

pub fn reachable(labels: practice.Labels, layer: usize, modifiers: u8, cp: u21) bool {
    if (layer >= labels.layer_count) return false;
    for (0..labels.key_count) |target| {
        if (!practice.matches(labels.get(layer, target, modifiers, practice.layerMask(layer)), cp)) continue;
        if (providers(labels, layer, modifiers, target)) return true;
    }
    return false;
}

fn providers(labels: practice.Labels, layer: usize, modifiers: u8, target: usize) bool {
    if (layer != 0) {
        var provider = false;
        for (0..labels.key_count) |key| {
            const entry = labels.get(0, key, 0, 1);
            if (key != target and !entry.provider_unknown and entry.hold_layer == layer) provider = true;
        }
        if (!provider) return false;
    }
    for (0..8) |bit| {
        const flag = @as(u8, 1) << @intCast(bit);
        if (modifiers & flag == 0) continue;
        const accepted = if (flag & 0x22 != 0) @as(u8, 0x22) else flag;
        var provider = false;
        for (0..labels.key_count) |key| {
            const entry = labels.get(layer, key, 0, practice.layerMask(layer));
            const held = entry.hold_modifiers orelse if (entry.hid_code) |code| (if (code >= 224 and code <= 231) @as(u8, 1) << @intCast(code - 224) else 0) else 0;
            if (key != target and !entry.provider_unknown and held & accepted != 0) provider = true;
        }
        if (!provider) return false;
    }
    return true;
}

pub fn letters(labels: practice.Labels, output: *[26]u8) []const u8 {
    var count: usize = 0;
    for (alphabet_order) |cp| if (reachable(labels, 0, 0, cp)) {
        output[count] = cp;
        count += 1;
    };
    return output[0..count];
}

pub fn family(labels: practice.Labels, context: Context, output: *[256]u21) []const u21 {
    const layer: usize = if (context.stage == .layers or context.stage == .modifiers) context.layer else 0;
    const mods: u8 = if (context.stage == .shift) 2 else if (context.stage == .modifiers) context.modifiers else 0;
    if (layer >= labels.layer_count or labels.key_count > 256) return &.{};
    var count: usize = 0;
    var alphabet: [26]u8 = undefined;
    const available = letters(labels, &alphabet);
    const learned = available[0..@min(context.alphabet, available.len)];
    for (0..labels.key_count) |key| {
        const entry = labels.get(layer, key, mods, practice.layerMask(layer));
        const text = entry.text orelse continue;
        var view = std.unicode.Utf8View.init(text) catch continue;
        var it = view.iterator();
        const cp = it.nextCodepoint() orelse continue;
        if (it.nextCodepoint() != null or
            cp <= ' ' or
            !reachable(labels, layer, mods, cp) or
            reachable(labels, 0, 0, cp)) continue;
        if (context.stage == .shift and
            !context.shifted_symbols and
            !std.ascii.isUpper(@intCast(@min(cp, 127)))) continue;
        if (context.stage == .shift and
            !context.shifted_symbols and
            std.mem.indexOfScalar(u8, learned, std.ascii.toLower(@intCast(cp))) == null) continue;
        if (context.stage == .shift and
            context.shifted_symbols and
            std.ascii.isAlphabetic(@intCast(@min(cp, 127)))) continue;
        if (std.mem.indexOfScalar(u21, output[0..count], cp) == null) {
            output[count] = cp;
            count += 1;
        }
    }
    std.mem.sort(u21, output[0..count], {}, std.sort.asc(u21));
    return output[0..count];
}

pub fn hintFor(labels: practice.Labels, context: Context, cp: u21) ?practice.Hint {
    if (context.version == 0 or
        (context.stage != .shift and context.stage != .layers and context.stage != .modifiers)) return null;
    var members_buffer: [256]u21 = undefined;
    const members = family(labels, context, &members_buffer);
    if (context.family >= members.len or members[context.family] != cp) return null;
    const layer: usize = if (context.stage == .shift) 0 else context.layer;
    const modifiers: u8 = if (context.stage == .shift) 2 else if (context.stage == .modifiers) context.modifiers else 0;
    for (0..labels.key_count) |key| if (practice.matches(labels.get(layer, key, modifiers, practice.layerMask(layer)), cp) and providers(labels, layer, modifiers, key)) return .{
        .layer = layer,
        .key = key,
        .modifiers = modifiers,
    };
    return null;
}

fn anyRoute(labels: practice.Labels, cp: u21) bool {
    for (0..labels.layer_count) |layer| {
        for (practice.route_modifiers) |mods| if (reachable(labels, layer, mods, cp)) return true;
    }
    return false;
}

pub fn validateText(labels: practice.Labels, text: []const u8) !void {
    var view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (!anyRoute(labels, cp)) return error.CurriculumRouteUnavailable;
}

pub fn generate(
    buffer: []u8,
    context: Context,
    seed: u64,
    length: u8,
    preset: generator.Preset,
    targets: []const u21,
    labels: practice.Labels,
) ![]const u8 {
    try context.validate();
    try labels.validate();
    if (context.version != 1 or length > 2) return error.InvalidCurriculum;
    if (!reachable(labels, 0, 0, ' ')) return error.CurriculumSpaceUnavailable;
    if (context.stage == .real_text) {
        const text = try generator.generate(buffer, .{
            .seed = seed,
            .length = length,
            .preset = preset,
        }, targets);
        try validateText(labels, text);
        return text;
    }
    var alphabet: [26]u8 = undefined;
    const available = letters(labels, &alphabet);
    if (available.len < context.alphabet) return error.CurriculumAlphabetUnavailable;
    const learned = available[0..context.alphabet];
    var symbols: [256]u21 = undefined;
    const members = family(labels, context, &symbols);
    // Stages that introduce a symbol family insert one member between words.
    const focused: ?u21 = switch (context.stage) {
        .shift, .layers, .modifiers => if (context.family < members.len)
            members[context.family]
        else
            return error.CurriculumFamilyUnavailable,
        else => null,
    };
    for (targets) |cp| {
        if (cp != ' ' and
            cp != focused and
            (cp > 127 or std.mem.indexOfScalar(u8, learned, @intCast(cp)) == null))
            return error.CurriculumTargetUnavailable;
    }
    var candidates: [generator.vocabulary.len]usize = undefined;
    const count = learnedWords(context, learned, &candidates);
    if (count < 2) return error.CurriculumCorpusUnavailable;
    var random: generator.Random = .{ .state = seed };
    var writer: std.Io.Writer = .fixed(buffer);
    const words = ([_]usize{ 8, 20, 40 })[length];
    var previous: ?usize = null;
    for (0..words) |slot| {
        const start = random.index(count);
        const target: ?u21 = if (targets.len > 0)
            targets[slot % targets.len]
        else if (context.stage == .fluency and slot % 2 == 0)
            learned[learned.len - 1]
        else
            null;
        const chosen = for (0..count) |offset| {
            const candidate = (start + offset) % count;
            if (previous == candidate) continue;
            const word = generator.vocabulary[candidates[candidate]];
            if (target) |cp| {
                if (cp != ' ' and
                    cp < 128 and
                    cp != focused and
                    std.mem.indexOfScalar(u8, word, @intCast(cp)) == null) continue;
            }
            break candidate;
        } else return error.CurriculumCorpusUnavailable;
        if (slot != 0) try writer.writeByte(' ');
        try writer.writeAll(generator.vocabulary[candidates[chosen]]);
        if (focused) |cp| {
            if (slot % 2 == 0) {
                try writer.writeByte(' ');
                var bytes: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(cp, &bytes);
                try writer.writeAll(bytes[0..n]);
            }
        }
        previous = chosen;
    }
    return writer.buffered();
}

/// Stores the indexes of vocabulary words typed with learned letters only and
/// returns their number. Key finding uses short words.
fn learnedWords(context: Context, learned: []const u8, candidates: []usize) usize {
    var count: usize = 0;
    for (generator.vocabulary, 0..) |word, index| {
        if (context.stage == .find_keys and word.len > 5) continue;
        const allowed = for (word) |cp| {
            if (std.mem.indexOfScalar(u8, learned, cp) == null) break false;
        } else true;
        if (allowed) {
            candidates[count] = index;
            count += 1;
        }
    }
    return count;
}

pub const Assessment = struct {
    ready: bool = false,
    missing: usize = 0,
    runs: u64 = 0,
    timing_runs: usize = 0,
};

pub fn assess(context: Context, aggregate: anytype, progress: anytype, expected: []const u21) Assessment {
    var output: Assessment = .{ .runs = aggregate.runs };
    for (expected) |cp| {
        var passed = false;
        for (aggregate.stats[0..aggregate.stat_count]) |stat| if (stat.cp == cp and stat.opportunities >= 20 and stat.rate() <= 3) {
            passed = true;
            break;
        };
        if (!passed) output.missing += 1;
    }
    if (progress) |data| {
        for (data.points[0..@min(3, data.count)]) |point| {
            var samples: usize = 0;
            for (point.characters[0..point.count]) |character| samples += character.samples;
            if (point.active_us > 0 and
                point.accuracy >= 97 and
                samples >= 5 and
                !point.truncated) output.timing_runs += 1;
        }
    }
    output.ready = aggregate.runs >= 3 and output.missing == 0 and expected.len > 0 and (context.stage == .find_keys or output.timing_runs >= 3);
    return output;
}

const Fixture = struct {
    const lower = "abcdefghijklmnopqrstuvwxyz";
    const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    fn lookup(_: *const anyopaque, layer: usize, key: usize, mods: u8, _: u16) practice.Label {
        if (key == 26) return .{ .hid_code = 44 };
        if (key == 27) return .{ .hold_modifiers = 2 };
        if (key == 28) return .{ .hold_layer = 1 };
        if (key == 29) return .{ .hold_modifiers = 4 };
        if (key == 30) return .{ .hold_modifiers = 64 };
        if (key == 31) return .{ .text = "." };
        if (key >= 26) return .{};
        if (layer == 1 and key == 0 and mods == 0) return .{ .text = "[" };
        if (key == 0 and mods == 4) return .{ .text = "€" };
        if (key == 0 and mods == 6) return .{ .text = "£" };
        if (key == 0 and mods == 64) return .{ .text = "@" };
        if (key == 1 and mods == 2) return .{ .text = "!" };
        return .{ .text = if (mods & 2 != 0) upper[key .. key + 1] else lower[key .. key + 1] };
    }

    fn labels() practice.Labels {
        return .{ .context = lower, .key_count = 32, .layer_count = 2, .lookup = lookup };
    }
};

test "curriculum stages are reproducible readable and constrained to proven families" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 26), alphabet_order.len);
    for (alphabet_order, 0..) |cp, index| try t.expect(
        std.mem.indexOfScalar(u8, alphabet_order[0..index], cp) == null,
    );
    var buffer: [8192]u8 = undefined;
    var again: [8192]u8 = undefined;
    for (std.meta.tags(Stage)) |stage| for (0..3) |length| {
        const context: Context = .{
            .version = 1,
            .stage = stage,
            .layer = if (stage == .modifiers) 0 else 1,
        };
        const text = try generate(&buffer, context, 17, @intCast(length), .words, &.{}, Fixture.labels());
        try t.expectEqualStrings(
            text,
            try generate(&again, context, 17, @intCast(length), .words, &.{}, Fixture.labels()),
        );
        try t.expect(std.mem.indexOfScalar(u8, text, ' ') != null);
        try validateText(Fixture.labels(), text);
        if (stage == .find_keys or stage == .fluency) {
            for (text) |cp| try t.expect(
                cp == ' ' or std.mem.indexOfScalar(u8, alphabet_order[0..6], cp) != null,
            );
        }
        if (stage == .layers) try t.expect(std.mem.indexOfScalar(u8, text, '[') != null);
        if (stage == .modifiers) try t.expect(std.mem.indexOf(u8, text, "€") != null);
    };
    try t.expectError(
        error.CurriculumFamilyUnavailable,
        generate(
            &buffer,
            .{ .version = 1, .stage = .layers, .layer = 2 },
            1,
            0,
            .words,
            &.{},
            Fixture.labels(),
        ),
    );
    try t.expectError(
        error.CurriculumTargetUnavailable,
        generate(&buffer, .{ .version = 1 }, 1, 0, .words, &.{'z'}, Fixture.labels()),
    );
    try t.expectError(error.UnsupportedCurriculum, (Context{ .version = 999 }).validate());
    const layered: Context = .{ .version = 1, .stage = .layers, .layer = 1 };
    try t.expectEqual(@as(usize, 1), hintFor(Fixture.labels(), layered, '[').?.layer);
    try t.expectEqual(
        @as(u8, 4),
        hintFor(Fixture.labels(), .{ .version = 1, .stage = .modifiers, .layer = 0 }, '€').?.modifiers,
    );
    try t.expect(hintFor(Fixture.labels(), layered, 'e') == null);
}

test "guided mastery needs repeated exposure and fluency also needs clean calibration" {
    const t = std.testing;
    const Stat = struct {
        cp: u21 = 'e',
        opportunities: u64 = 20,
        misses: u64 = 0,

        fn rate(self: @This()) f64 {
            return 100 * @as(f64, @floatFromInt(self.misses)) / @as(f64, @floatFromInt(self.opportunities));
        }
    };
    const Aggregate = struct { runs: u64 = 3, stats: [1]Stat = .{.{}}, stat_count: usize = 1 };
    var aggregate: Aggregate = .{};
    const Data = @import("practice_progress.zig").Summary;
    var progress: Data = .{ .count = 3 };
    for (progress.points[0..3]) |*point| {
        point.active_us = 1;
        point.count = 1;
        point.characters[0].samples = 5;
    }
    const find: Context = .{ .version = 1 };
    try t.expect(assess(find, aggregate, @as(?*Data, null), &.{'e'}).ready);
    const fluency: Context = .{ .version = 1, .stage = .fluency };
    try t.expect(!assess(fluency, aggregate, @as(?*Data, null), &.{'e'}).ready);
    try t.expect(assess(fluency, aggregate, @as(?*Data, &progress), &.{'e'}).ready);
    aggregate.stats[0].misses = 1;
    try t.expect(!assess(find, aggregate, @as(?*Data, null), &.{'e'}).ready);
    aggregate.stats[0].misses = 0;
    aggregate.runs = 2;
    try t.expect(!assess(find, aggregate, @as(?*Data, null), &.{'e'}).ready);
}
