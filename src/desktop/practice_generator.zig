//! First-party curated vocabulary, fixed SplitMix64 and textual coverage v1.
const std = @import("std");
pub const Preset = enum { words, mixed_case, punctuation };
pub const version: u16 = 1;
pub const character_bounds = [_]usize{ 512, 1280, 2560 };

pub const Descriptor = struct {
    seed: u64,
    preset: Preset = .words,
    length: u8 = 1,
    generator_version: u16 = version,
    corpus_version: u16 = version,
    coverage_version: u16 = 1,

    pub fn validate(self: Descriptor) !void {
        if (self.length > 2) return error.InvalidExerciseLevel;
        if (self.generator_version != version or
            self.corpus_version != version or
            self.coverage_version != 1) return error.UnsupportedChallenge;
    }
};

pub const vocabulary = blk: {
    @setEvalBranchQuota(100_000);
    const data = @embedFile("practice_vocabulary.txt");
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, data, " \n\r\t");
    while (it.next() != null) count += 1;
    var words: [count][]const u8 = undefined;
    it.reset();
    for (&words) |*word| word.* = it.next().?;
    break :blk words;
};

/// SplitMix64. Its fixed sequence is part of the generation version.
pub const Random = struct {
    state: u64,

    pub fn next(self: *Random) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var x = self.state;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        return x ^ (x >> 31);
    }

    pub fn index(self: *Random, size: usize) usize {
        return @intCast(self.next() % size);
    }
};

/// Focusing selects candidates from the same corpus; plain challenge inputs
/// never include history. Unsupported targets are explicitly rejected.
pub const HandCoverage = struct {
    left: [26]bool = @splat(false),
    right: [26]bool = @splat(false),
};

pub fn generate(buffer: []u8, descriptor: Descriptor, targets: []const u21) ![]const u8 {
    return generateWithCoverage(buffer, descriptor, targets, null);
}

pub fn generateWithCoverage(
    buffer: []u8,
    descriptor: Descriptor,
    targets: []const u21,
    coverage: ?HandCoverage,
) ![]const u8 {
    try descriptor.validate();
    if (targets.len > 5) return error.TooManyDrillTargets;
    for (targets) |cp| {
        if (descriptor.preset == .words and (cp < 'a' or cp > 'z')) return error.HarderPresetRequired;
        if (cp > 127) return error.CorpusCoverageUnavailable;
    }
    var state: Generator = .{ .random = .{ .state = descriptor.seed } };
    var writer: std.Io.Writer = .fixed(buffer);
    const units = ([_]usize{ 2, 5, 10 })[descriptor.length];
    for (0..units) |unit| {
        var pair: [2][]const u8 = undefined;
        for (&pair, 0..) |*word, slot| {
            word.* = try state.pickWord(descriptor, targets, coverage, unit, slot);
        }
        if (unit > 0) try writer.writeByte(' ');
        switch (descriptor.preset) {
            .words => try writeWordsSentence(&writer, &state, pair[0], pair[1]),
            .mixed_case => try writeMixedCaseSentence(&writer, &state, pair[0], pair[1]),
            .punctuation => try writePunctuationSentence(&writer, &state, unit, pair[0], pair[1]),
        }
    }
    const text = writer.buffered();
    if (text.len > character_bounds[descriptor.length]) return error.ExerciseTooLong;
    // Every accepted drill target must actually appear, including punctuation.
    for (targets) |cp| {
        if (std.mem.indexOfScalar(u8, text, @intCast(cp)) == null) return error.CorpusCoverageUnavailable;
    }
    return text;
}

/// Generation state: the random stream plus the words and sentence templates
/// already used, so that one exercise never repeats either.
const Generator = struct {
    random: Random,
    used_words: [20]usize = undefined,
    used_word_count: usize = 0,
    used_templates: [12]bool = @splat(false),

    fn isUsed(self: *const Generator, index: usize) bool {
        return std.mem.indexOfScalar(usize, self.used_words[0..self.used_word_count], index) != null;
    }

    /// Returns the first unused vocabulary index at or after `start`, wrapping
    /// around, whose word satisfies `filter.accepts`.
    fn findUnused(self: *const Generator, start: usize, filter: anytype) ?usize {
        for (0..vocabulary.len) |offset| {
            const index = (start + offset) % vocabulary.len;
            if (filter.accepts(vocabulary[index]) and !self.isUsed(index)) return index;
        }
        return null;
    }

    fn pickWord(
        self: *Generator,
        descriptor: Descriptor,
        targets: []const u21,
        coverage: ?HandCoverage,
        unit: usize,
        slot: usize,
    ) ![]const u8 {
        var candidate = self.random.index(vocabulary.len);
        if (targets.len > 0) {
            const cp: u8 = @intCast(targets[(unit * 2 + slot) % targets.len]);
            const filter: ContainsTarget = .{ .cp = cp, .lower = std.ascii.toLower(cp) };
            if (std.ascii.isAlphabetic(filter.lower)) {
                candidate = self.findUnused(candidate, filter) orelse return error.CorpusCoverageUnavailable;
            }
        }
        // Normal mixed-case exercises open with a left-hand then a right-hand
        // initial so that both Shift keys are practiced.
        const opening_units: usize = if (descriptor.length == 0) 1 else 2;
        if (coverage) |hands| {
            if (descriptor.preset == .mixed_case and targets.len == 0 and unit < opening_units) {
                const filter: StartsWithHand = .{ .eligible = if (slot == 0) hands.left else hands.right };
                candidate = self.findUnused(candidate, filter) orelse return error.HandCoverageUnavailable;
            }
        }
        candidate = self.findUnused(candidate, AnyWord{}) orelse candidate;
        self.used_words[self.used_word_count] = candidate;
        self.used_word_count += 1;
        return vocabulary[candidate];
    }

    /// Picks a sentence template among the first `count` not used yet.
    fn template(self: *Generator, count: usize) usize {
        var chosen = self.random.index(count);
        while (self.used_templates[chosen]) chosen = (chosen + 1) % count;
        self.used_templates[chosen] = true;
        return chosen;
    }
};

const AnyWord = struct {
    fn accepts(_: AnyWord, _: []const u8) bool {
        return true;
    }
};

/// An uppercase target needs a word starting with it; others need it anywhere.
const ContainsTarget = struct {
    cp: u8,
    lower: u8,

    fn accepts(self: ContainsTarget, word: []const u8) bool {
        if (std.ascii.isUpper(self.cp)) return word[0] == self.lower;
        return std.mem.indexOfScalar(u8, word, self.lower) != null;
    }
};

const StartsWithHand = struct {
    eligible: [26]bool,

    fn accepts(self: StartsWithHand, word: []const u8) bool {
        return self.eligible[word[0] - 'a'];
    }
};

fn writeWordsSentence(writer: *std.Io.Writer, state: *Generator, a: []const u8, b: []const u8) !void {
    const args = .{ a, b };
    switch (state.template(12)) {
        0 => try writer.print("we wrote the words {s} and {s} in our notebook.", args),
        1 => try writer.print("please add {s} and {s} to the list before lunch.", args),
        2 => try writer.print("the next page pairs the word {s} with the word {s}.", args),
        3 => try writer.print("our next lesson uses {s} alongside {s} in a sentence.", args),
        4 => try writer.print("i found {s} and {s} in the index at the back.", args),
        5 => try writer.print("a friend asked me to spell {s} and then {s}.", args),
        6 => try writer.print("we took turns reading {s} and {s} aloud.", args),
        7 => try writer.print("the teacher circled {s} before pointing to {s}.", args),
        8 => try writer.print("today we will write {s} and {s} on separate lines.", args),
        9 => try writer.print("their latest puzzle includes both {s} and {s}.", args),
        10 => try writer.print("my notebook has a page for {s} and another for {s}.", args),
        else => try writer.print("after the walk we looked up the words {s} and {s}.", args),
    }
}

fn titleCase(buffer: *[64]u8, word: []const u8) []const u8 {
    @memcpy(buffer[0..word.len], word);
    buffer[0] = std.ascii.toUpper(buffer[0]);
    return buffer[0..word.len];
}

fn writeMixedCaseSentence(writer: *std.Io.Writer, state: *Generator, a: []const u8, b: []const u8) !void {
    const acronyms = [_][]const u8{ "HTTP", "USB", "API", "HTML", "DNS", "CPU" };
    const terms = [_][]const u8{ "IPv6", "mDNS", "eBPF", "GitHub", "OpenGL", "WebKit" };
    const names = [_][]const u8{ "Maya", "Robin", "Alex", "Sam", "Zoe", "Noah", "Iris", "Ben" };
    var a_buffer: [64]u8 = undefined;
    var b_buffer: [64]u8 = undefined;
    const title_a = titleCase(&a_buffer, a);
    const title_b = titleCase(&b_buffer, b);
    const name = names[state.random.index(names.len)];
    const acronym = acronyms[state.random.index(acronyms.len)];
    const term = terms[state.random.index(terms.len)];
    switch (state.template(12)) {
        0 => try writer.print(
            "{s} indexed the {s} notes under {s} and {s}; see the {s} guide.",
            .{ name, acronym, title_a, title_b, term },
        ),
        1 => try writer.print(
            "Our {s} workshop has two chapters, {s} and {s}. {s} will demonstrate {s}.",
            .{ acronym, title_a, title_b, name, term },
        ),
        2 => try writer.print(
            "The {s} folder contains {s} and {s}; {s} shared it through {s}.",
            .{ acronym, title_a, title_b, name, term },
        ),
        3 => try writer.print(
            "{s} named the {s} examples {s} and {s}, then updated {s}.",
            .{ name, acronym, title_a, title_b, term },
        ),
        4 => try writer.print(
            "Read {s} before {s} in the {s} manual; ask {s} about {s}.",
            .{ title_a, title_b, acronym, name, term },
        ),
        5 => try writer.print(
            "Please send {s} and {s} to {s}; the {s} team uses {s}.",
            .{ title_a, title_b, name, acronym, term },
        ),
        6 => try writer.print(
            "{s} reviewed our {s} documentation, including {s}, {s} and {s}.",
            .{ name, acronym, title_a, title_b, term },
        ),
        7 => try writer.print(
            "A {s} tutorial links {s} with {s}; {s} tested it with {s}.",
            .{ acronym, title_a, title_b, name, term },
        ),
        8 => try writer.print(
            "In {s}, {s} labeled the {s} samples {s} and {s}.",
            .{ term, name, acronym, title_a, title_b },
        ),
        9 => try writer.print(
            "{s} explained why {s} and {s} appear in our {s} overview of {s}.",
            .{ name, title_a, title_b, acronym, term },
        ),
        10 => try writer.print(
            "Compare the {s} and {s} exercises; {s} prepared the {s} checklist for {s}.",
            .{ title_a, title_b, name, acronym, term },
        ),
        else => try writer.print(
            "The {s} team asked {s} to archive {s} and {s} beside the {s} notes.",
            .{ acronym, name, title_a, title_b, term },
        ),
    }
}

fn writePunctuationSentence(
    writer: *std.Io.Writer,
    state: *Generator,
    unit: usize,
    a: []const u8,
    b: []const u8,
) !void {
    const args = .{ a, b };
    switch (unit % 4) {
        0 => switch (state.template(8)) {
            0 => try writer.print("Let's discuss {s}; she said, \"try {s} next!\"", args),
            1 => try writer.print("Don't forget {s}; he wrote, \"save {s} for later.\"", args),
            2 => try writer.print("We can't skip {s}; the note says, \"review {s} today.\"", args),
            3 => try writer.print("It's time for {s}; our plan reads, \"start with {s}.\"", args),
            4 => try writer.print("Today's list includes {s}; I added, \"please check {s}.\"", args),
            5 => try writer.print("You've already seen {s}; she asked, \"what about {s}?\"", args),
            6 => try writer.print("I'll read {s}; you can reply, \"let's try {s}.\"", args),
            else => try writer.print("That isn't {s}; the label says, \"{s} goes here!\"", args),
        },
        1 => try writer.print("Today's topics: {s} and {s} (pages 12-14).", args),
        2 => try writer.print("Is {s} on your list, or would you prefer {s}?", args),
        else => try writer.print("We wrote \"{s}\" twice; don't forget {s} at 9:30.", args),
    }
}

test "curated base vocabulary is unique and all nine configurations have stable bounded coverage" {
    const t = std.testing;
    try t.expect(vocabulary.len >= 500);
    var unique: std.StringHashMap(void) = .init(t.allocator);
    defer unique.deinit();
    for (vocabulary) |word| {
        const entry = try unique.getOrPut(word);
        // Shared category headings were removed; count ordinary base entries once.
        try t.expect(!entry.found_existing);
    }
    for ([_]Preset{ .words, .mixed_case, .punctuation }) |preset| for (0..3) |length| for (0..64) |seed| {
        var buffer: [8192]u8 = undefined;
        var again: [8192]u8 = undefined;
        const descriptor: Descriptor = .{ .seed = seed, .preset = preset, .length = @intCast(length) };
        const text = try generate(&buffer, descriptor, &.{});
        try t.expectEqualStrings(text, try generate(&again, descriptor, &.{}));
        try t.expect(text.len > 70 and text.len < 2000);
        if (preset == .words) {
            for (text) |byte| {
                try t.expect(std.ascii.isLower(byte) or byte == ' ' or byte == '.');
            }
        }
        if (preset == .mixed_case) {
            var consecutive = false;
            for (text[1..], text[0 .. text.len - 1]) |a, b| if (std.ascii.isUpper(a) and std.ascii.isUpper(b)) {
                consecutive = true;
            };
            try t.expect(consecutive);
        }
        if (preset == .punctuation) {
            try t.expect(std.mem.indexOfScalar(u8, text, ';') != null);
            try t.expect(std.mem.indexOfScalar(u8, text, '\'') != null);
            try t.expect(std.mem.count(u8, text, "\"") % 2 == 0);
            try t.expectEqual(std.mem.count(u8, text, "("), std.mem.count(u8, text, ")"));
            if (length > 0) {
                try t.expect(
                    std.mem.indexOfScalar(u8, text, ':') != null and std.mem.indexOfScalar(u8, text, '(') != null,
                );
            }
        }
    };
    var buffer: [8192]u8 = undefined;
    try t.expectError(error.InvalidExerciseLevel, generate(&buffer, .{ .seed = 1, .length = 3 }, &.{}));
    try t.expectError(
        error.UnsupportedChallenge,
        generate(&buffer, .{ .seed = 1, .generator_version = 2 }, &.{}),
    );
    try t.expectError(error.HarderPresetRequired, generate(&buffer, .{ .seed = 1 }, &.{'A'}));
    try t.expectError(error.WriteFailed, generate(buffer[0..4], .{ .seed = 1 }, &.{}));
}

test "drill candidates increase rare target exposure and capitalization remains distinct" {
    const t = std.testing;
    var ordinary_q: usize = 0;
    var drill_q: usize = 0;
    for (0..64) |seed| {
        var normal: [8192]u8 = undefined;
        var focused: [8192]u8 = undefined;
        const descriptor: Descriptor = .{ .seed = seed, .length = 0 };
        ordinary_q += std.mem.count(u8, try generate(&normal, descriptor, &.{}), "q");
        drill_q += std.mem.count(u8, try generate(&focused, descriptor, &.{'q'}), "q");
        const capitals = try generate(&focused, .{
            .seed = seed,
            .preset = .mixed_case,
            .length = 0,
        }, &.{ 'A', 'B' });
        try t.expect(
            std.mem.indexOfScalar(u8, capitals, 'A') != null and std.mem.indexOfScalar(u8, capitals, 'B') != null,
        );
        const symbols = try generate(
            &focused,
            .{ .seed = seed, .preset = .punctuation, .length = 0 },
            &.{ ';', '"', '\'' },
        );
        try t.expect(std.mem.count(u8, symbols, "\"") % 2 == 0);
    }
    try t.expect(drill_q > ordinary_q * 3);
    var coverage: HandCoverage = .{};
    coverage.left[0] = true;
    coverage.right[25] = true;
    var buffer: [8192]u8 = undefined;
    const balanced = try generateWithCoverage(
        &buffer,
        .{ .seed = 12, .preset = .mixed_case },
        &.{},
        coverage,
    );
    try t.expect(std.mem.count(u8, balanced, "A") >= 2 and std.mem.count(u8, balanced, "Z") >= 2);
    try t.expectError(
        error.HandCoverageUnavailable,
        generateWithCoverage(&buffer, .{ .seed = 12, .preset = .mixed_case }, &.{}, .{}),
    );
}

test "generation v1 literal hashes freeze challenges across platforms" {
    const expected = [_][]const u8{
        "0e8daa3e0dfca7279bbb0490fd873ab76abde72a0bdf72e4778b6a60da4a03fd",
        "be92cd62f04d39346eab3ae492f2937bc3562167f009051c6dab66a3fd0d063f",
        "ae23006622a34db99e6727c28f84a6d1648624dacd1d5b861ce86badb08a92dd",
        "9f1adbf32770e3e58f92090a77b1b42957cc28a924b7c8f0e2daaecc3769daa1",
        "c1e94b685094730b345f47fcdf952e5aab5961354a681e2bad8e4ff8300fb799",
        "74039446c9dc4fb2824517340138ade63dd59bc424c922adda79b9ddb6ec2a78",
        "6a60c835b5da473d2ef7ba8ef8a3f2e269c2ae48768a5b99a0850251e2b374bd",
        "510725efe2d6d06d8fcede662e69549ce2400e4ce79824cab6607a38026a300e",
        "6f0ccfecb425d89f06f7b45b318e53168b4bd5e776456a40c9f297976b196dc2",
    };
    var index: usize = 0;
    for ([_]Preset{ .words, .mixed_case, .punctuation }) |preset| for (0..3) |length| {
        var buffer: [8192]u8 = undefined;
        const text = try generate(&buffer, .{
            .seed = 42,
            .preset = preset,
            .length = @intCast(length),
        }, &.{});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
        try std.testing.expectEqualStrings(expected[index], &std.fmt.bytesToHex(hash, .lower));
        index += 1;
    };
}
