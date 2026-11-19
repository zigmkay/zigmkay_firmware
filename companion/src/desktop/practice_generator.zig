//! English typing tests: sentences of words from the first-party vocabulary,
//! reproducible from a seed with a fixed SplitMix64 stream.
const std = @import("std");

/// The sentence counts the tutor offers.
pub const sentence_counts = [_]usize{ 1, 3, 5, 10 };
/// Every sentence uses its own template, so a test has at most this many.
pub const max_sentences = templates;
const templates = 12;

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

/// SplitMix64.
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

/// Writes `sentences` lowercase sentences of two vocabulary words each. One
/// test never repeats a word or a sentence template.
pub fn generate(buffer: []u8, seed: u64, sentences: usize) ![]const u8 {
    if (sentences == 0 or sentences > max_sentences) return error.InvalidExerciseLevel;
    var state: Generator = .{ .random = .{ .state = seed } };
    var writer: std.Io.Writer = .fixed(buffer);
    for (0..sentences) |sentence| {
        if (sentence > 0) try writer.writeByte(' ');
        try writeSentence(&writer, &state, state.pickWord(), state.pickWord());
    }
    return writer.buffered();
}

/// The random stream plus the words and templates already used.
const Generator = struct {
    random: Random,
    used_words: [2 * max_sentences]usize = undefined,
    used_word_count: usize = 0,
    used_templates: [templates]bool = @splat(false),

    fn pickWord(self: *Generator) []const u8 {
        var candidate = self.random.index(vocabulary.len);
        while (std.mem.indexOfScalar(usize, self.used_words[0..self.used_word_count], candidate) != null) {
            candidate = (candidate + 1) % vocabulary.len;
        }
        self.used_words[self.used_word_count] = candidate;
        self.used_word_count += 1;
        return vocabulary[candidate];
    }

    fn template(self: *Generator) usize {
        var chosen = self.random.index(templates);
        while (self.used_templates[chosen]) chosen = (chosen + 1) % templates;
        self.used_templates[chosen] = true;
        return chosen;
    }
};

fn writeSentence(writer: *std.Io.Writer, state: *Generator, a: []const u8, b: []const u8) !void {
    const args = .{ a, b };
    switch (state.template()) {
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

test "vocabulary words are unique" {
    const t = std.testing;
    try t.expect(vocabulary.len >= 500);
    var unique: std.StringHashMap(void) = .init(t.allocator);
    defer unique.deinit();
    for (vocabulary) |word| try t.expect(!(try unique.getOrPut(word)).found_existing);
}

test "tests have the chosen number of lowercase sentences and are reproducible" {
    const t = std.testing;
    for (sentence_counts) |count| for (0..64) |seed| {
        var buffer: [4096]u8 = undefined;
        var again: [4096]u8 = undefined;
        const text = try generate(&buffer, seed, count);
        try t.expectEqualStrings(text, try generate(&again, seed, count));
        try t.expectEqual(count, std.mem.count(u8, text, "."));
        for (text) |byte| try t.expect(std.ascii.isLower(byte) or byte == ' ' or byte == '.');
    };
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    try t.expect(!std.mem.eql(u8, try generate(&a, 42, 5), try generate(&b, 43, 5)));
    try t.expectError(error.InvalidExerciseLevel, generate(&a, 1, 0));
    try t.expectError(error.InvalidExerciseLevel, generate(&a, 1, max_sentences + 1));
    try t.expectError(error.WriteFailed, generate(a[0..4], 1, 1));
}
