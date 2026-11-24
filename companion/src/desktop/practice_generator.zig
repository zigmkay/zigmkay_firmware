//! 6-stage adaptive drill generator for the Zigmkay typing tutor. Lessons are
//! real English words from `practice_words.zig`; a clean-room trigram model
//! trained on the same list fills in pseudowords only when too few real words
//! fit the unlocked letters. Deterministic from SplitMix64 seeds.
const std = @import("std");
const practice = @import("practice.zig");
const layout_profile = @import("practice_layout_profile.zig");
const model = @import("practice_model.zig");
const word_list = @import("practice_words.zig");

/// Legacy sentence counts retained for compatibility until M2b removes the old controller mode.
pub const sentence_counts = [_]usize{ 1, 3, 5, 10 };
pub const max_sentences = templates;
const templates = 12;

pub const default_round_words: usize = 20;
pub const default_weak_spot_words: usize = 20;
/// Letters (without spaces) of a lesson of words, about 20 words.
pub const default_lesson_letters: usize = 100;
/// A lesson draws its words from at most this many of the most frequent
/// words that fit, and mixes in pseudowords while fewer than `min_word_pool` fit.
pub const max_word_pool: usize = 1000;
pub const min_word_pool: usize = 15;
const boundary: usize = 26;
const alphabet_size: usize = 27;

pub const Stage = enum(u8) {
    home_row = 1,
    all_letters = 2,
    shift = 3,
    punctuation_numbers = 4,
    layers_combos = 5,
    free_text = 6,

    pub fn fromNumber(n: u8) Stage {
        return switch (n) {
            1 => .home_row,
            2 => .all_letters,
            3 => .shift,
            4 => .punctuation_numbers,
            5 => .layers_combos,
            else => .free_text,
        };
    }

    pub fn number(self: Stage) u8 {
        return @backingInt(self);
    }

    pub fn title(self: Stage) []const u8 {
        return switch (self) {
            .home_row => "Stage 1 · First letters",
            .all_letters => "Stage 2 · All letters",
            .shift => "Stage 3 · Shift & capitals",
            .punctuation_numbers => "Stage 4 · Punctuation & numbers",
            .layers_combos => "Stage 5 · Layers & combos",
            .free_text => "Stage 6 · Free text & code",
        };
    }

    pub fn shortName(self: Stage) []const u8 {
        return switch (self) {
            .home_row => "First letters",
            .all_letters => "All letters",
            .shift => "Shift & capitals",
            .punctuation_numbers => "Punctuation & numbers",
            .layers_combos => "Layers & combos",
            .free_text => "Free text & code",
        };
    }
};

pub const Stage5Filter = enum(u8) {
    mixed,
    combos_only,
    specific_layer,
};

pub const Stage6Source = enum(u8) {
    english_prose,
    zig_code,
    custom_text,
    weak_spot,
};

pub const DrillRequest = struct {
    language: model.Language = .en,
    stage: Stage = .home_row,
    seed: u64 = 1,
    word_count: usize = default_round_words,
    /// Letters of a lesson of words (Stages 1 and 2).
    letter_budget: usize = default_lesson_letters,
    unlocked_mask: u32 = 0,
    /// Stage 1 letters; 0 takes them from `learning` or the profile.
    first_mask: u32 = 0,
    /// A weak-spot lesson: every word contains this letter pair when enough do.
    bigram: ?[2]u8 = null,
    focus_cp: ?u21 = null,
    profile: ?*const layout_profile.LayoutProfile = null,
    learning: ?*const model.LearningModel = null,
    punct_group: usize = 0,
    stage5_filter: Stage5Filter = .mixed,
    stage5_layer: ?usize = null,
    stage6_source: Stage6Source = .english_prose,
    zig_lesson_index: usize = 0,
    custom_text: []const u8 = "",
};

pub const TrigramTable = struct {
    trigram: [alphabet_size][alphabet_size][alphabet_size]u16,
    bigram: [alphabet_size][alphabet_size]u16,
    unigram: [alphabet_size]u16,
};

/// Words of the list the trigram model learns from.
const trigram_words: usize = 10_000;
var trigram_table: TrigramTable = undefined;
var trigrams_ready = false;

/// Clean-room English trigram transition model, trained on first use from
/// the most frequent words of the word list.
pub fn englishTrigrams() *const TrigramTable {
    if (trigrams_ready) return &trigram_table;
    const table = &trigram_table;
    table.* = .{
        .trigram = @splat(@splat(@splat(0))),
        .bigram = @splat(@splat(0)),
        .unigram = @splat(0),
    };
    const list = word_list.english();
    for (0..@min(list.len, trigram_words)) |i| {
        var p2: usize = boundary;
        var p1: usize = boundary;
        for (list.word(i)) |byte| {
            const ch: usize = byte - 'a';
            table.trigram[p2][p1][ch] +|= 1;
            table.bigram[p1][ch] +|= 1;
            table.unigram[ch] +|= 1;
            p2 = p1;
            p1 = ch;
        }
        table.trigram[p2][p1][boundary] +|= 1;
        table.bigram[p1][boundary] +|= 1;
    }
    trigrams_ready = true;
    return table;
}

/// Compact first-party profanity blocklist so pseudowords never emit offensive terms.
const blocked_words = [_][]const u8{
    "arse", "ass",  "cock", "crap", "cunt", "damn", "dick", "fag",
    "fuck", "hell", "piss", "porn", "rape", "sex",  "shit", "slut",
    "tit",  "tits", "twat", "wank", "cum",  "nazi",
};

pub fn isBlockedWord(word: []const u8) bool {
    for (blocked_words) |bad| {
        if (std.ascii.eqlIgnoreCase(word, bad)) return true;
    }
    return false;
}

pub fn hasTripleLetter(word: []const u8) bool {
    if (word.len < 3) return false;
    for (2..word.len) |i| {
        if (word[i] == word[i - 1] and word[i] == word[i - 2]) return true;
    }
    return false;
}

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

pub fn vowelCountInMask(mask: u32) u8 {
    var count: u8 = 0;
    for ("aeiou") |v| {
        if ((mask & (@as(u32, 1) << @intCast(v - 'a'))) != 0) count += 1;
    }
    return count;
}

pub fn maskFromSlice(letters: []const u8) u32 {
    var mask: u32 = 0;
    for (letters) |ch| {
        if (ch >= 'a' and ch <= 'z') {
            mask |= @as(u32, 1) << @intCast(ch - 'a');
        }
    }
    return mask;
}

fn effectiveMask(req: DrillRequest) u32 {
    // Stage 1 stays on the first letters even after later letters unlock;
    // the progressive unlock mask belongs to Stage 2.
    if (req.stage == .home_row) {
        if (req.first_mask != 0) return req.first_mask & 0x03ff_ffff;
        if (req.learning) |lm| {
            const m = maskFromSlice(lm.firstLetters());
            if (m != 0) return m;
        }
        if (req.profile) |p| {
            const m = maskFromSlice(p.zone1Letters());
            if (m != 0) return m;
        }
    }
    if (req.unlocked_mask != 0) return req.unlocked_mask & 0x03ff_ffff;
    if (req.learning) |lm| {
        const m = lm.unlockedMask();
        if (m != 0) return m;
    }
    if (req.profile) |p| {
        const m = maskFromSlice(if (req.stage == .home_row) p.zone1Letters() else p.unlockSlice());
        if (m != 0) return m;
    }
    return 0x03ff_ffff; // fallback all 26 letters
}

fn focusLower(req: DrillRequest, mask: u32) ?u8 {
    const raw = req.focus_cp orelse (if (req.learning) |lm| lm.focus_cp else null) orelse return null;
    if (raw >= 'a' and raw <= 'z') {
        const ch: u8 = @intCast(raw);
        if ((mask & (@as(u32, 1) << @intCast(ch - 'a'))) != 0) return ch;
    }
    return null;
}

/// Primary 6-stage adaptive drill entrypoint.
pub fn generateDrill(buffer: []u8, req: DrillRequest) ![]const u8 {
    _ = req.language; // .en active; reserved for future locales
    const text = try switch (req.stage) {
        .home_row, .all_letters => generateWordRound(buffer, req),
        .shift => generateShiftRound(buffer, req),
        .punctuation_numbers => generatePunctuationNumbersRound(buffer, req),
        .layers_combos => generateLayersCombosRound(buffer, req),
        // Free text is real prose, code or the user's own text; it stays verbatim.
        .free_text => return generateFreeTextRound(buffer, req),
    };
    const profile = req.profile orelse return text;
    // A profile without any route knows nothing about the layout.
    if (profile.route_len == 0) return text;
    return keepTypeable(buffer, text, profile);
}

/// Drops every character the layout cannot produce from a generated drill, so
/// a round can always be finished. The stage generators fall back to fixed
/// letters and unchecked words on sparse layouts; this is the one guarantee
/// behind all of them. `text` must lie at the start of `buffer`.
fn keepTypeable(buffer: []u8, text: []const u8, profile: *const layout_profile.LayoutProfile) ![]const u8 {
    std.debug.assert(text.ptr == buffer.ptr);
    var kept: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(text.len, index + len);
        const cp: ?u21 = std.unicode.utf8Decode(text[index..end]) catch null;
        const keep = if (cp) |value|
            if (value == ' ')
                kept > 0 and buffer[kept - 1] != ' '
            else
                profile.routeFor(value) != null or profile.comboFor(value) != null
        else
            false;
        if (keep) {
            std.mem.copyForwards(u8, buffer[kept..], text[index..end]);
            kept += end - index;
        }
        index = end;
    }
    if (kept > 0 and buffer[kept - 1] == ' ') kept -= 1;
    if (kept == 0) return error.NoTypeableDrill;
    return buffer[0..kept];
}

/// Generates a ~20-word weak-spot drill heavily targeting weakest keys and slowest bigrams.
pub fn generateWeakSpotDrill(
    buffer: []u8,
    seed: u64,
    learning: ?*const model.LearningModel,
    profile: ?*const layout_profile.LayoutProfile,
    word_count: usize,
) ![]const u8 {
    return generateWeakSpotInternal(buffer, seed, learning, profile, if (word_count == 0) default_weak_spot_words else word_count);
}

/// A lesson of real words for Stages 1 and 2: every word uses only unlocked
/// letters and contains the focus letter (or the weak-spot pair). Words come
/// from the `max_word_pool` most frequent that fit, the more frequent ones
/// more often, never the same word twice in a row; while fewer than
/// `min_word_pool` fit, trigram pseudowords make up the difference.
fn generateWordRound(buffer: []u8, req: DrillRequest) ![]const u8 {
    const mask = effectiveMask(req);
    if (mask == 0) return error.InvalidExerciseLevel;
    if (vowelCountInMask(mask) < 2) return generateLowVowelAnchorDrill(buffer, req, mask);
    const focus = focusLower(req, mask);
    var rng: Random = .{ .state = req.seed ^ 0x6c8e_9cf5 };
    const list = word_list.english();

    var pool: [max_word_pool]u16 = undefined;
    var pool_len: usize = 0;
    if (req.bigram) |pair| if (fitsMask(pair[0], mask) and fitsMask(pair[1], mask)) {
        pool_len = collectWords(list, mask, null, &pair, &pool);
        // Too few words with the pair: an ordinary focus lesson instead.
        if (pool_len < min_word_pool) pool_len = 0;
    };
    if (pool_len == 0) pool_len = collectWords(list, mask, focus, null, &pool);

    // Weight 1/sqrt(rank): common words come often, rarer ones still appear.
    var cumulative: [max_word_pool]f32 = undefined;
    var total: f32 = 0;
    for (cumulative[0..pool_len], 0..) |*c, i| {
        total += 1.0 / @sqrt(@as(f32, @floatFromInt(i + 3)));
        c.* = total;
    }

    var writer: std.Io.Writer = .fixed(buffer);
    var letters: usize = 0;
    var count: usize = 0;
    var previous: ?usize = null;
    const budget = @max(@as(usize, 1), req.letter_budget);
    while (letters < budget and count < 64) : (count += 1) {
        if (count > 0) try writer.writeByte(' ');
        const pseudo = pool_len == 0 or (pool_len < min_word_pool and rng.index(min_word_pool) >= pool_len);
        if (pseudo) {
            var word_buf: [8]u8 = undefined;
            const word = samplePseudoword(&rng, mask, focus, focus != null, &word_buf);
            try writer.writeAll(word);
            letters += word.len;
            previous = null;
            continue;
        }
        var pick: usize = 0;
        for (0..3) |_| {
            const r = @as(f32, @floatFromInt(rng.next() >> 40)) / @as(f32, 1 << 24) * total;
            pick = std.sort.lowerBound(f32, cumulative[0..pool_len], r, struct {
                fn order(target: f32, item: f32) std.math.Order {
                    return std.math.order(target, item);
                }
            }.order);
            pick = @min(pick, pool_len - 1);
            if (previous == null or pick != previous.? or pool_len == 1) break;
        }
        previous = pick;
        const word = list.word(pool[pick]);
        try writer.writeAll(word);
        letters += word.len;
    }
    return writer.buffered();
}

fn fitsMask(ch: u8, mask: u32) bool {
    return ch >= 'a' and ch <= 'z' and mask & (@as(u32, 1) << @intCast(ch - 'a')) != 0;
}

/// The most frequent words of `list` that use only `mask` letters and
/// contain `focus` (when given) and `pair` (when given), in rank order.
fn collectWords(list: *const word_list.List, mask: u32, focus: ?u8, pair: ?*const [2]u8, out: *[max_word_pool]u16) usize {
    const focus_bit: u32 = if (focus) |f| @as(u32, 1) << @intCast(f - 'a') else 0;
    var len: usize = 0;
    for (list.items[0..list.len], 0..) |w, i| {
        if (len == out.len) break;
        if (w.mask & ~mask != 0 or w.mask & focus_bit != focus_bit) continue;
        if (pair) |p| if (std.mem.indexOf(u8, list.word(i), p) == null) continue;
        out[len] = @intCast(i);
        len += 1;
    }
    return len;
}

fn generateLowVowelAnchorDrill(buffer: []u8, req: DrillRequest, mask: u32) ![]const u8 {
    var rng: Random = .{ .state = req.seed ^ 0x51a7_9b13 };
    const focus = focusLower(req, mask);
    const word_count = @max(@as(usize, 1), req.word_count);

    // Gather real words from the word list (and home-row classics) strictly within `mask`.
    var real_words: [96][]const u8 = undefined;
    var real_len: usize = 0;

    const classic_home_words = [_][]const u8{
        "sad",   "lad",   "ask",   "dad",  "add",   "all",   "fall", "hall", "half", "glad",
        "glass", "flask", "flash", "flag", "shall", "salad", "dash", "lash", "sash", "alas",
        "lass",  "dads",  "lads",  "asks", "falls", "alf",   "fad",  "jak",
    };
    for (classic_home_words) |w| {
        if (wordFitsMask(w, mask) and !isBlockedWord(w) and real_len < real_words.len) {
            real_words[real_len] = w;
            real_len += 1;
        }
    }
    const list = word_list.english();
    for (0..list.len) |i| {
        if (real_len >= real_words.len) break;
        const w = list.word(i);
        if (w.len >= 3 and w.len <= 7 and list.items[i].mask & ~mask == 0 and !isBlockedWord(w)) {
            var dup = false;
            for (real_words[0..real_len]) |e| if (std.mem.eql(u8, e, w)) {
                dup = true;
                break;
            };
            if (!dup) {
                real_words[real_len] = w;
                real_len += 1;
            }
        }
    }

    // Partition unlocked letters by hand for ergonomic alternation and finger rolls.
    var left_letters: [26]u8 = undefined;
    var left_len: usize = 0;
    var right_letters: [26]u8 = undefined;
    var right_len: usize = 0;
    var all_letters: [26]u8 = undefined;
    var all_len: usize = 0;

    for (0..26) |i| {
        if ((mask & (@as(u32, 1) << @intCast(i))) == 0) continue;
        const ch: u8 = 'a' + @as(u8, @intCast(i));
        all_letters[all_len] = ch;
        all_len += 1;
        if (req.profile) |p| {
            if (p.routeFor(ch)) |r| {
                switch (p.handFor(r.key_index)) {
                    .left => {
                        left_letters[left_len] = ch;
                        left_len += 1;
                    },
                    .right => {
                        right_letters[right_len] = ch;
                        right_len += 1;
                    },
                    .neutral => {},
                }
            }
        }
    }
    if (all_len == 0) return error.InvalidExerciseLevel;

    var writer: std.Io.Writer = .fixed(buffer);
    var focus_hits: usize = 0;

    for (0..word_count) |i| {
        if (i > 0) try writer.writeByte(' ');
        const need_focus = focus != null and (focus_hits * 2 < i + 1);
        var token_buf: [8]u8 = undefined;
        var token: []const u8 = "";

        // Alternate between real home-row words (~50%) and ergonomic alternation/rolls (~50%).
        const try_real = real_len > 0 and (i % 2 == 0 or (left_len == 0 or right_len == 0));
        if (try_real) {
            if (need_focus) {
                // Find a real word containing focus if possible.
                var start = rng.index(real_len);
                var chosen: ?[]const u8 = null;
                for (0..real_len) |offset| {
                    const cand = real_words[(start + offset) % real_len];
                    if (std.mem.indexOfScalar(u8, cand, focus.?) != null) {
                        chosen = cand;
                        break;
                    }
                }
                start = start;
                if (chosen) |c| token = c;
            } else {
                token = real_words[rng.index(real_len)];
            }
        }

        if (token.len == 0) {
            // Synthesize clean 3-5 letter hand-alternation or roll pattern.
            const target_len: usize = 3 + rng.index(3); // 3..5
            var len: usize = 0;
            var use_left = (rng.next() & 1) == 0;
            for (0..target_len) |_| {
                var ch: u8 = undefined;
                if (left_len > 0 and right_len > 0) {
                    const pool = if (use_left) left_letters[0..left_len] else right_letters[0..right_len];
                    ch = pool[rng.index(pool.len)];
                    if ((i % 4) != 3) use_left = !use_left; // mostly alternate hands, occasional roll
                } else {
                    ch = all_letters[rng.index(all_len)];
                }
                // Prevent triple identical letters.
                if (len >= 2 and token_buf[len - 1] == ch and token_buf[len - 2] == ch and all_len > 1) {
                    ch = all_letters[(rng.index(all_len - 1) + 1) % all_len];
                    if (ch == token_buf[len - 1]) {
                        for (all_letters[0..all_len]) |alt| if (alt != token_buf[len - 1]) {
                            ch = alt;
                            break;
                        };
                    }
                }
                token_buf[len] = ch;
                len += 1;
            }
            if (need_focus) {
                if (std.mem.indexOfScalar(u8, token_buf[0..len], focus.?) == null) {
                    const pos = rng.index(len);
                    token_buf[pos] = focus.?;
                    if (hasTripleLetter(token_buf[0..len]) and all_len > 1) {
                        for (all_letters[0..all_len]) |alt| if (alt != focus.?) {
                            token_buf[(pos + 1) % len] = alt;
                            break;
                        };
                    }
                }
            }
            token = token_buf[0..len];
        }

        if (focus) |fc| {
            if (std.mem.indexOfScalar(u8, token, fc) != null) focus_hits += 1;
        }
        try writer.writeAll(token);
    }

    return writer.buffered();
}

fn generateTrigramRound(buffer: []u8, req: DrillRequest) ![]const u8 {
    const mask = effectiveMask(req);
    if (mask == 0) return error.InvalidExerciseLevel;
    if (vowelCountInMask(mask) < 2) {
        return generateLowVowelAnchorDrill(buffer, req, mask);
    }

    var rng: Random = .{ .state = req.seed ^ 0xa3c5_9ac3 };
    const focus = focusLower(req, mask);
    const word_count = @max(@as(usize, 1), req.word_count);

    var writer: std.Io.Writer = .fixed(buffer);
    var focus_hits: usize = 0;

    for (0..word_count) |i| {
        if (i > 0) try writer.writeByte(' ');
        const need_focus = focus != null and (focus_hits * 2 < i + 1);
        var word_buf: [8]u8 = undefined;
        const word = samplePseudoword(&rng, mask, focus, need_focus, &word_buf);
        if (focus) |fc| {
            if (std.mem.indexOfScalar(u8, word, fc) != null) focus_hits += 1;
        }
        try writer.writeAll(word);
    }
    return writer.buffered();
}

fn samplePseudoword(
    rng: *Random,
    mask: u32,
    focus: ?u8,
    require_focus: bool,
    out: *[8]u8,
) []const u8 {
    const attempts: usize = if (require_focus) 24 else 8;
    var best_buf: [8]u8 = undefined;
    var best_len: usize = 0;

    for (0..attempts) |attempt| {
        var buf: [8]u8 = undefined;
        const target_max: usize = 4 + rng.index(4); // 4..7
        var len: usize = 0;
        var p2: usize = boundary;
        var p1: usize = boundary;

        // On later attempts when focus is required, seed the word starting with or placing focus.
        if (require_focus and attempt >= 14 and focus != null) {
            const fc = focus.?;
            buf[0] = fc;
            len = 1;
            p2 = boundary;
            p1 = fc - 'a';
        }

        while (len < target_max) {
            const allow_end = len >= 3;
            const next_idx = pickNextSymbol(rng, p2, p1, mask, focus, allow_end, buf[0..len]);
            if (next_idx == boundary) break;
            buf[len] = 'a' + @as(u8, @intCast(next_idx));
            len += 1;
            p2 = p1;
            p1 = next_idx;
        }

        // Guarantee minimum length 3.
        while (len < 3) {
            const next_idx = pickNextSymbol(rng, p2, p1, mask, focus, false, buf[0..len]);
            if (next_idx >= 26) break;
            buf[len] = 'a' + @as(u8, @intCast(next_idx));
            len += 1;
            p2 = p1;
            p1 = next_idx;
        }

        const candidate = buf[0..len];
        if (len < 3 or isBlockedWord(candidate) or hasTripleLetter(candidate)) continue;

        const has_focus = if (focus) |fc| std.mem.indexOfScalar(u8, candidate, fc) != null else true;
        if (!require_focus or has_focus) {
            @memcpy(out[0..len], candidate);
            return out[0..len];
        }
        if (best_len == 0) {
            @memcpy(best_buf[0..len], candidate);
            best_len = len;
        }
    }

    if (best_len > 0) {
        if (require_focus and focus != null and std.mem.indexOfScalar(u8, best_buf[0..best_len], focus.?) == null) {
            best_buf[0] = focus.?;
        }
        @memcpy(out[0..best_len], best_buf[0..best_len]);
        return out[0..best_len];
    }

    // Absolute fallback for tiny 1-2 letter masks.
    var fallback_len: usize = 0;
    const first_ch: u8 = if (focus) |fc| fc else firstCharInMask(mask);
    const second_ch = otherCharInMask(mask, first_ch);
    out[0] = first_ch;
    out[1] = second_ch;
    out[2] = first_ch;
    fallback_len = 3;
    return out[0..fallback_len];
}

fn pickNextSymbol(
    rng: *Random,
    p2: usize,
    p1: usize,
    mask: u32,
    focus: ?u8,
    allow_end: bool,
    prefix: []const u8,
) usize {
    const focus_idx: ?usize = if (focus) |fc| @as(usize, fc - 'a') else null;
    const table = englishTrigrams();

    // Try trigram -> bigram -> unigram -> uniform backoff.
    inline for (0..4) |tier| {
        var weights: [alphabet_size]u32 = @splat(0);
        var total: u32 = 0;

        for (0..26) |ch| {
            if ((mask & (@as(u32, 1) << @intCast(ch))) == 0) continue;
            // Disallow triple consecutive identical letters.
            if (prefix.len >= 2 and prefix[prefix.len - 1] == ('a' + ch) and prefix[prefix.len - 2] == ('a' + ch)) {
                continue;
            }
            var w: u32 = switch (tier) {
                0 => table.trigram[p2][p1][ch],
                1 => table.bigram[p1][ch],
                2 => table.unigram[ch],
                else => 1,
            };
            if (w > 0 and focus_idx != null and ch == focus_idx.?) {
                w *|= 4; // 4x transition weight boost on focus key
            }
            weights[ch] = w;
            total +|= w;
        }

        if (allow_end and tier < 2) {
            const end_w: u32 = switch (tier) {
                0 => table.trigram[p2][p1][boundary],
                1 => table.bigram[p1][boundary],
                else => 0,
            };
            // Keep end boundary reasonable so words average 4-6 letters.
            const capped_end = @min(end_w, total / 2 + 1);
            if (end_w > 0) {
                weights[boundary] = capped_end;
                total +|= capped_end;
            }
        }

        if (total > 0) {
            var pick: u32 = @intCast(rng.next() % total);
            for (0..alphabet_size) |idx| {
                if (weights[idx] == 0) continue;
                if (pick < weights[idx]) return idx;
                pick -= weights[idx];
            }
        }
    }
    return firstCharInMask(mask) - 'a';
}

fn firstCharInMask(mask: u32) u8 {
    for (0..26) |i| {
        if ((mask & (@as(u32, 1) << @intCast(i))) != 0) return 'a' + @as(u8, @intCast(i));
    }
    return 'a';
}

fn otherCharInMask(mask: u32, avoid: u8) u8 {
    for (0..26) |i| {
        const ch = 'a' + @as(u8, @intCast(i));
        if (ch != avoid and (mask & (@as(u32, 1) << @intCast(i))) != 0) return ch;
    }
    return avoid;
}

fn wordFitsMask(word: []const u8, mask: u32) bool {
    for (word) |byte| {
        if (byte < 'a' or byte > 'z') return false;
        if ((mask & (@as(u32, 1) << @intCast(byte - 'a'))) == 0) return false;
    }
    return true;
}

/// Stage 3: Capitalized / mixed-case words balanced 50/50 between left-hand and right-hand Shift targets.
fn generateShiftRound(buffer: []u8, req: DrillRequest) ![]const u8 {
    var rng: Random = .{ .state = req.seed ^ 0x3f2e_71c9 };
    const word_count = @max(@as(usize, 1), req.word_count);
    const mask = effectiveMask(req);

    var left_starts: [26]u8 = undefined;
    var left_len: usize = 0;
    var right_starts: [26]u8 = undefined;
    var right_len: usize = 0;

    for (0..26) |i| {
        if ((mask & (@as(u32, 1) << @intCast(i))) == 0) continue;
        const lower: u8 = 'a' + @as(u8, @intCast(i));
        const upper: u8 = 'A' + @as(u8, @intCast(i));
        if (req.profile) |p| {
            const lower_route = p.routeFor(lower) orelse continue;
            if (p.routeFor(upper) == null) continue;
            switch (p.handFor(lower_route.key_index)) {
                .left => {
                    left_starts[left_len] = lower;
                    left_len += 1;
                },
                .right => {
                    right_starts[right_len] = lower;
                    right_len += 1;
                },
                .neutral => {
                    if (left_len <= right_len) {
                        left_starts[left_len] = lower;
                        left_len += 1;
                    } else {
                        right_starts[right_len] = lower;
                        right_len += 1;
                    }
                },
            }
        } else {
            // Default split when no profile is provided.
            if (i % 2 == 0) {
                left_starts[left_len] = lower;
                left_len += 1;
            } else {
                right_starts[right_len] = lower;
                right_len += 1;
            }
        }
    }

    var writer: std.Io.Writer = .fixed(buffer);
    for (0..word_count) |i| {
        if (i > 0) try writer.writeByte(' ');
        // Alternate strictly left-hand capital / right-hand capital for 50/50 Shift balance.
        const want_left = (i % 2 == 0);
        const start_pool = if (want_left and left_len > 0)
            left_starts[0..left_len]
        else if (!want_left and right_len > 0)
            right_starts[0..right_len]
        else if (left_len > 0)
            left_starts[0..left_len]
        else
            right_starts[0..right_len];

        const lead_lower: u8 = if (start_pool.len > 0) start_pool[rng.index(start_pool.len)] else 'a';

        // Pick a frequent word starting with `lead_lower` that fits `mask`, or synthesize one.
        var chosen: ?[]const u8 = null;
        const list = word_list.english();
        const span = @min(list.len, common_words);
        const vocab_start = if (span > 0) rng.index(span) else 0;
        for (0..span) |step| {
            const index = (vocab_start + step) % span;
            const w = list.word(index);
            if (w.len >= 3 and w.len <= 8 and w[0] == lead_lower and list.items[index].mask & ~mask == 0) {
                chosen = w;
                break;
            }
        }

        if (chosen) |w| {
            try writer.writeByte(std.ascii.toUpper(w[0]));
            try writer.writeAll(w[1..]);
        } else {
            var tmp: [8]u8 = undefined;
            const synth = samplePseudoword(&rng, mask, lead_lower, true, &tmp);
            try writer.writeByte(std.ascii.toUpper(lead_lower));
            if (synth.len > 1) {
                try writer.writeAll(synth[1..]);
            } else {
                try writer.writeAll("an");
            }
        }
    }
    return writer.buffered();
}

/// Stage 4: Punctuation & numbers in progressive 3-4 character groups filtered to layout reachability.
fn generatePunctuationNumbersRound(buffer: []u8, req: DrillRequest) ![]const u8 {
    var rng: Random = .{ .state = req.seed ^ 0x7c91_4a25 };
    const word_count = @max(@as(usize, 1), req.word_count);

    const groups = [_][]const u8{
        ".,?!",
        "-'\":;",
        "0123",
        "4567",
        "89.,",
        ".,?!-'\":;0123456789",
    };
    const raw_group = groups[req.punct_group % groups.len];

    var allowed: [24]u8 = undefined;
    var allowed_len: usize = 0;
    for (raw_group) |ch| {
        if (req.profile) |p| {
            if (p.routeFor(ch) == null) continue;
        }
        allowed[allowed_len] = ch;
        allowed_len += 1;
    }
    // If the selected group had no reachable chars on this layout, fall back to all reachable punct/digits.
    if (allowed_len == 0) {
        if (req.profile) |p| {
            for (p.punctuationSlice()) |ch| if (allowed_len < allowed.len) {
                allowed[allowed_len] = ch;
                allowed_len += 1;
            };
            for (p.digitsSlice()) |ch| if (allowed_len < allowed.len) {
                allowed[allowed_len] = ch;
                allowed_len += 1;
            };
        }
    }

    var writer: std.Io.Writer = .fixed(buffer);
    for (0..word_count) |i| {
        if (i > 0) try writer.writeByte(' ');
        const word = pickReachableVocabWord(&rng, req.profile);
        if (allowed_len == 0) {
            try writer.writeAll(word);
            continue;
        }
        const ch = allowed[i % allowed_len];
        if (std.ascii.isDigit(ch)) {
            // Emit realistic 2-4 digit pattern using reachable digits in the group.
            const dlen: usize = 2 + rng.index(3);
            for (0..dlen) |di| {
                const candidate = allowed[(i + di + rng.index(allowed_len)) % allowed_len];
                try writer.writeByte(if (std.ascii.isDigit(candidate)) candidate else ch);
            }
        } else if (ch == '"' or ch == '\'') {
            try writer.writeByte(ch);
            try writer.writeAll(word);
            try writer.writeByte(ch);
        } else if (ch == '-') {
            const word2 = pickReachableVocabWord(&rng, req.profile);
            try writer.writeAll(word);
            try writer.writeByte('-');
            try writer.writeAll(word2);
        } else {
            try writer.writeAll(word);
            try writer.writeByte(ch);
        }
    }
    return writer.buffered();
}

/// Stage 5: Programming symbols from project layers + 2-key combos from Document.combos.
fn generateLayersCombosRound(buffer: []u8, req: DrillRequest) ![]const u8 {
    var rng: Random = .{ .state = req.seed ^ 0xd841_2e7b };
    const word_count = @max(@as(usize, 1), req.word_count);

    var tokens: [64][]const u8 = undefined;
    var token_len: usize = 0;

    // Candidate multi-character programming symbol idioms.
    const idiom_pool = [_][]const u8{
        "{}", "[]", "()", "<>", "->", "==", "!=", "<=", ">=",
        "+=", "-=", "&&", "||", "::", "//", "/*", "*/", "=>",
    };

    const include_layers = req.stage5_filter != .combos_only;
    const include_combos = req.stage5_filter != .specific_layer;

    if (include_layers) {
        for (idiom_pool) |idiom| {
            if (token_len >= tokens.len) break;
            if (idiomReachable(idiom, req.profile, req.stage5_layer)) {
                tokens[token_len] = idiom;
                token_len += 1;
            }
        }
    }

    // Collect single-character symbols from layer routes and combos.
    var single_chars: [64]u8 = undefined;
    var single_len: usize = 0;

    if (req.profile) |p| {
        if (include_combos) {
            for (p.comboSlice()) |combo| {
                if (combo.cp >= 0x21 and combo.cp < 0x7f and single_len < single_chars.len) {
                    single_chars[single_len] = @intCast(combo.cp);
                    single_len += 1;
                }
            }
        }
        if (include_layers) {
            for (p.routeSlice()) |route| {
                if (req.stage5_layer) |wanted_layer| {
                    if (route.layer != wanted_layer) continue;
                } else if (route.kind != .layer_tap) {
                    continue;
                }
                if (route.cp >= 0x21 and route.cp < 0x7f) {
                    const ch: u8 = @intCast(route.cp);
                    if (!std.ascii.isAlphabetic(ch) and single_len < single_chars.len) {
                        single_chars[single_len] = ch;
                        single_len += 1;
                    }
                }
            }
            if (single_len == 0) {
                for (p.symbolsSlice()) |ch| {
                    if (single_len < single_chars.len) {
                        single_chars[single_len] = ch;
                        single_len += 1;
                    }
                }
            }
        }
    } else {
        for ("{}[]()<>+-=*/|:\\") |ch| {
            single_chars[single_len] = ch;
            single_len += 1;
        }
    }

    var writer: std.Io.Writer = .fixed(buffer);
    for (0..word_count) |i| {
        if (i > 0) try writer.writeByte(' ');
        // Ensure combos appear regularly when present and requested.
        if (include_combos) {
            if (req.profile) |p| {
                if (p.combo_len > 0 and (req.stage5_filter == .combos_only or i % 3 == 0)) {
                    const combo = p.combos[i % p.combo_len];
                    var cp_buf: [4]u8 = undefined;
                    const cp_len = std.unicode.utf8Encode(combo.cp, &cp_buf) catch 0;
                    if (cp_len > 0) {
                        const w = pickReachableVocabWord(&rng, req.profile);
                        try writer.writeAll(w);
                        try writer.writeAll(cp_buf[0..cp_len]);
                        continue;
                    }
                }
            }
        }
        if (token_len > 0 and (single_len == 0 or i % 2 == 0)) {
            const tok = tokens[(i + rng.index(token_len)) % token_len];
            try writer.writeAll(tok);
        } else if (single_len > 0) {
            const ch = single_chars[(i + rng.index(single_len)) % single_len];
            const w = pickReachableVocabWord(&rng, req.profile);
            try writer.writeByte(ch);
            try writer.writeAll(w);
        } else {
            try writer.writeAll(pickReachableVocabWord(&rng, req.profile));
        }
    }
    return writer.buffered();
}

fn idiomReachable(idiom: []const u8, profile: ?*const layout_profile.LayoutProfile, filter_layer: ?usize) bool {
    const p = profile orelse return true;
    var matches_layer = (filter_layer == null);
    for (idiom) |ch| {
        const r = p.routeFor(ch) orelse return false;
        if (filter_layer) |fl| {
            if (r.layer == fl) matches_layer = true;
        }
    }
    return matches_layer;
}

const curated_prose = [_][]const u8{
    "Steady rhythm builds lasting speed faster than rushing through each word. Keep both hands relaxed on the home row and return after every reach.",
    "Small ergonomic keyboards reward calm finger motion and opposite-hand shifts. Practice a few focused minutes each day to make layers effortless.",
    "Clean accuracy comes first; velocity follows naturally once muscle memory settles. Watch the next word ahead instead of chasing single letters.",
    "Symbols and brackets live one thumb hold away when your layers are consistent. Smooth transitions between prose and code start with steady habits.",
};

fn generateFreeTextRound(buffer: []u8, req: DrillRequest) ![]const u8 {
    switch (req.stage6_source) {
        .zig_code => {
            const lesson = practice.lessons[req.zig_lesson_index % practice.lessons.len];
            if (lesson.len > buffer.len) return error.WriteFailed;
            @memcpy(buffer[0..lesson.len], lesson);
            return buffer[0..lesson.len];
        },
        .custom_text => {
            const trimmed = std.mem.trim(u8, req.custom_text, " \r\n\t");
            if (trimmed.len > 0) {
                var writer: std.Io.Writer = .fixed(buffer);
                var prev_cr = false;
                for (trimmed) |byte| {
                    if (byte == '\n' and prev_cr) {
                        prev_cr = false;
                        continue;
                    }
                    prev_cr = (byte == '\r');
                    try writer.writeByte(if (byte == '\r') '\n' else byte);
                }
                return writer.buffered();
            }
            // Fall through to prose if custom text is empty.
            const text = curated_prose[@intCast(req.seed % curated_prose.len)];
            if (text.len > buffer.len) return error.WriteFailed;
            @memcpy(buffer[0..text.len], text);
            return buffer[0..text.len];
        },
        .weak_spot => {
            return generateWeakSpotInternal(
                buffer,
                req.seed,
                req.learning,
                req.profile,
                if (req.word_count == 0) default_weak_spot_words else req.word_count,
            );
        },
        .english_prose => {
            const text = curated_prose[@intCast(req.seed % curated_prose.len)];
            if (text.len > buffer.len) return error.WriteFailed;
            @memcpy(buffer[0..text.len], text);
            return buffer[0..text.len];
        },
    }
}

fn generateWeakSpotInternal(
    buffer: []u8,
    seed: u64,
    learning: ?*const model.LearningModel,
    profile: ?*const layout_profile.LayoutProfile,
    word_count: usize,
) ![]const u8 {
    var rng: Random = .{ .state = seed ^ 0x91e1_0da5 };
    var weak_keys_buf: [5]model.KeySummary = undefined;
    var weak_bigrams_buf: [3]model.BigramStat = undefined;

    const all_weak_keys: []const model.KeySummary = if (learning) |lm| lm.weakestKeys(&weak_keys_buf) else &.{};
    var unmastered_len: usize = 0;
    for (all_weak_keys) |wk| {
        if (wk.confidence < 1.0 and unmastered_len < 3) {
            unmastered_len += 1;
        } else break;
    }
    const weak_keys: []const model.KeySummary = if (unmastered_len > 0)
        all_weak_keys[0..unmastered_len]
    else
        all_weak_keys[0..@min(all_weak_keys.len, 3)];
    const weak_bigrams: []const model.BigramStat = if (learning) |lm| lm.slowestBigrams(2, &weak_bigrams_buf) else &.{};

    const mask: u32 = if (learning) |lm| blk: {
        const m = lm.unlockedMask();
        break :blk if (m != 0) m else 0x03ff_ffff;
    } else if (profile) |p| blk: {
        const m = maskFromSlice(p.unlockSlice());
        break :blk if (m != 0) m else 0x03ff_ffff;
    } else 0x03ff_ffff;

    var writer: std.Io.Writer = .fixed(buffer);
    for (0..word_count) |i| {
        if (i > 0) try writer.writeByte(' ');
        // Prefer targeting slowest bigrams on even slots when available.
        if (weak_bigrams.len > 0 and (i % 2 == 0 or weak_keys.len == 0)) {
            const bg = weak_bigrams[(i / 2) % weak_bigrams.len];
            if (bg.prev >= 'a' and bg.prev <= 'z' and bg.cur >= 'a' and bg.cur <= 'z') {
                const needle = [2]u8{ @intCast(bg.prev), @intCast(bg.cur) };
                if (findWordContaining(&rng, &needle, mask)) |w| {
                    try writer.writeAll(w);
                    continue;
                }
                // Synthesize a clean word embedding the exact bigram.
                var synth: [6]u8 = undefined;
                const lead = firstCharInMask(mask);
                synth[0] = needle[0];
                synth[1] = needle[1];
                synth[2] = if (lead != needle[1]) lead else otherCharInMask(mask, needle[1]);
                synth[3] = needle[0];
                synth[4] = needle[1];
                try writer.writeAll(synth[0..5]);
                continue;
            }
        }
        if (weak_keys.len > 0) {
            const wk = weak_keys[i % weak_keys.len];
            if (wk.cp >= 'a' and wk.cp <= 'z') {
                const target_ch: u8 = @intCast(wk.cp);
                const needle = [1]u8{target_ch};
                if (findWordContaining(&rng, &needle, mask)) |w| {
                    try writer.writeAll(w);
                    continue;
                }
                var tmp: [8]u8 = undefined;
                try writer.writeAll(samplePseudoword(&rng, mask, target_ch, true, &tmp));
                continue;
            }
        }
        var tmp: [8]u8 = undefined;
        try writer.writeAll(samplePseudoword(&rng, mask, null, false, &tmp));
    }
    return writer.buffered();
}

/// Words the other stages draw from: the most frequent of the list.
const common_words: usize = 3000;

fn findWordContaining(rng: *Random, needle: []const u8, mask: u32) ?[]const u8 {
    const list = word_list.english();
    const span = @min(list.len, 8 * common_words);
    if (span == 0) return null;
    const start = rng.index(span);
    for (0..span) |offset| {
        const index = (start + offset) % span;
        const w = list.word(index);
        if (w.len >= 3 and w.len <= 8 and list.items[index].mask & ~mask == 0 and std.mem.indexOf(u8, w, needle) != null) {
            return w;
        }
    }
    return null;
}

fn pickReachableVocabWord(rng: *Random, profile: ?*const layout_profile.LayoutProfile) []const u8 {
    const list = word_list.english();
    const span = @min(list.len, common_words);
    const start = rng.index(span);
    for (0..@min(span, 128)) |step| {
        const w = list.word((start + step) % span);
        if (w.len < 3 or w.len > 7) continue;
        if (profile) |p| {
            var ok = true;
            for (w) |ch| if (p.routeFor(ch) == null) {
                ok = false;
                break;
            };
            if (!ok) continue;
        }
        return w;
    }
    return list.word(start);
}

// ---------------------------------------------------------------------------
// Legacy compatibility sentence generator (retained until M2b removes old mode)
// ---------------------------------------------------------------------------

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

const Generator = struct {
    random: Random,
    used_words: [2 * max_sentences]usize = undefined,
    used_word_count: usize = 0,
    used_templates: [templates]bool = @splat(false),

    fn pickWord(self: *Generator) []const u8 {
        const list = word_list.english();
        const span = @min(list.len, common_words);
        var candidate = self.random.index(span);
        while (std.mem.indexOfScalar(usize, self.used_words[0..self.used_word_count], candidate) != null) {
            candidate = (candidate + 1) % span;
        }
        self.used_words[self.used_word_count] = candidate;
        self.used_word_count += 1;
        return list.word(candidate);
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

// ---------------------------------------------------------------------------
// Deterministic unit & property tests
// ---------------------------------------------------------------------------

test "the word list has no word the pseudoword filter blocks" {
    const list = word_list.english();
    for (0..list.len) |i| try std.testing.expect(!isBlockedWord(list.word(i)));
}

test "lessons of real words contain the focus letter in every word and stop near 100 letters" {
    const t = std.testing;
    const first = maskFromSlice("esartl");
    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const req: DrillRequest = .{ .stage = .home_row, .seed = 7, .first_mask = first, .focus_cp = 'l' };
    const text = try generateDrill(&buf1, req);
    try t.expectEqualStrings(text, try generateDrill(&buf2, req));
    const list = word_list.english();
    var letters: usize = 0;
    var previous: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |w| {
        letters += w.len;
        try t.expect(wordFitsMask(w, first));
        try t.expect(std.mem.indexOfScalar(u8, w, 'l') != null);
        // Real words only: plenty fit these letters.
        const real = for (0..list.len) |i| {
            if (std.mem.eql(u8, list.word(i), w)) break true;
        } else false;
        try t.expect(real);
        try t.expect(!std.mem.eql(u8, w, previous));
        previous = w;
    }
    try t.expect(letters >= default_lesson_letters and letters < default_lesson_letters + 15);

    // A weak-spot lesson puts the pair in every word.
    const weak = try generateDrill(&buf1, .{ .stage = .all_letters, .seed = 3, .unlocked_mask = maskFromSlice("esartldingo"), .focus_cp = 'g', .bigram = "in".* });
    var pairs = std.mem.splitScalar(u8, weak, ' ');
    while (pairs.next()) |w| try t.expect(std.mem.indexOf(u8, w, "in") != null);
}

test "trigram pseudowords enforce reproducibility, 100% unlocked subset, focus share, no triples, and profanity filter" {
    const t = std.testing;
    // Colemak-DH home row (4 vowels)
    const colemak_mask = maskFromSlice("arstneio");
    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const req: DrillRequest = .{
        .stage = .all_letters,
        .seed = 42,
        .word_count = 25,
        .unlocked_mask = colemak_mask,
        .focus_cp = 'r',
    };
    const text1 = try generateTrigramRound(&buf1, req);
    const text2 = try generateTrigramRound(&buf2, req);
    try t.expectEqualStrings(text1, text2);

    var words: usize = 0;
    var focus_words: usize = 0;
    var it = std.mem.splitScalar(u8, text1, ' ');
    while (it.next()) |w| {
        words += 1;
        try t.expect(w.len >= 3 and w.len <= 7);
        try t.expect(!hasTripleLetter(w));
        try t.expect(!isBlockedWord(w));
        try t.expect(wordFitsMask(w, colemak_mask));
        if (std.mem.indexOfScalar(u8, w, 'r') != null) focus_words += 1;
    }
    try t.expectEqual(@as(usize, 25), words);
    try t.expect(focus_words >= 12); // >= 48% focus share
    try t.expect(isBlockedWord("fuck"));
    try t.expect(hasTripleLetter("aaab"));
}

test "QWERTY low-vowel home-row fallback generates clean non-degenerate anchor drills" {
    const t = std.testing;
    const qwerty_home = maskFromSlice("asdfjkl");
    try t.expectEqual(@as(u8, 1), vowelCountInMask(qwerty_home));
    var buf: [1024]u8 = undefined;
    const text = try generateDrill(&buf, .{
        .stage = .home_row,
        .seed = 99,
        .word_count = 20,
        .unlocked_mask = qwerty_home,
        .focus_cp = 'f',
    });
    var count: usize = 0;
    var focus_hits: usize = 0;
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |w| {
        count += 1;
        try t.expect(w.len >= 3 and w.len <= 7);
        try t.expect(wordFitsMask(w, qwerty_home));
        try t.expect(!hasTripleLetter(w));
        if (std.mem.indexOfScalar(u8, w, 'f') != null) focus_hits += 1;
    }
    try t.expectEqual(@as(usize, 20), count);
    try t.expect(focus_hits >= 9);
}

test "Stage 3 achieves near 50/50 left/right Shift hand balance and Stage 4/5/6 work cleanly" {
    const t = std.testing;

    // Build synthetic profile with left-hand 'a'..'m' and right-hand 'n'..'z', plus layer symbols & a combo.
    var profile: layout_profile.LayoutProfile = .{
        .key_count = 32,
        .layer_count = 2,
    };
    for (0..26) |i| {
        const hand: layout_profile.Hand = if (i < 13) .left else .right;
        profile.keys[i].hand = hand;
        profile.routes[profile.route_len] = .{
            .cp = 'a' + @as(u21, @intCast(i)),
            .kind = .base,
            .layer = 0,
            .key_index = i,
        };
        profile.route_len += 1;
        profile.routes[profile.route_len] = .{
            .cp = 'A' + @as(u21, @intCast(i)),
            .kind = .shifted,
            .layer = 0,
            .key_index = i,
            .modifiers = 0x02,
        };
        profile.route_len += 1;
    }
    // Add layer symbols and a 2-key combo.
    const sym_list = "{ }[]()=->!.,0123";
    for (sym_list, 0..) |ch, si| {
        if (ch == ' ') continue;
        profile.routes[profile.route_len] = .{
            .cp = ch,
            .kind = .layer_tap,
            .layer = 1,
            .key_index = si % 26,
            .layer_activator = 30,
        };
        profile.route_len += 1;
    }
    profile.combos[0] = .{
        .cp = '_',
        .kind = .combo,
        .layer = 0,
        .key_index = 1,
        .combo_key_index = 2,
    };
    profile.combo_len = 1;

    // Stage 3: 50/50 left/right hand shift balance
    var buf: [2048]u8 = undefined;
    const s3 = try generateDrill(&buf, .{
        .stage = .shift,
        .seed = 7,
        .word_count = 24,
        .profile = &profile,
    });
    var left_caps: usize = 0;
    var right_caps: usize = 0;
    for (s3) |ch| {
        if (ch >= 'A' and ch <= 'Z') {
            const r = profile.routeFor(std.ascii.toLower(ch)).?;
            if (profile.handFor(r.key_index) == .left) left_caps += 1 else right_caps += 1;
        }
    }
    try t.expectEqual(@as(usize, 12), left_caps);
    try t.expectEqual(@as(usize, 12), right_caps);

    // Stage 4: punctuation & numbers
    const s4 = try generateDrill(&buf, .{
        .stage = .punctuation_numbers,
        .seed = 11,
        .word_count = 16,
        .profile = &profile,
        .punct_group = 0,
    });
    try t.expect(std.mem.indexOfAny(u8, s4, ".,!") != null);

    // Stage 5: layers & combos (mixed + combos_only)
    const s5_mixed = try generateDrill(&buf, .{
        .stage = .layers_combos,
        .seed = 13,
        .word_count = 18,
        .profile = &profile,
        .stage5_filter = .mixed,
    });
    try t.expect(std.mem.indexOfScalar(u8, s5_mixed, '_') != null);
    try t.expect(std.mem.indexOfAny(u8, s5_mixed, "{}[]()=->") != null);

    const s5_combos = try generateDrill(&buf, .{
        .stage = .layers_combos,
        .seed = 13,
        .word_count = 10,
        .profile = &profile,
        .stage5_filter = .combos_only,
    });
    try t.expect(std.mem.count(u8, s5_combos, "_") == 10);

    // Stage 6: weak-spot drill concentrates target weak keys and bigrams
    var lm = model.LearningModel.init("etaoinshrdlcumwfgypbvkjxqz", 26, .{ .target_wpm = 40.0 });
    lm.getOrAddStat('e').?.* = .{ .cp = 'e', .ema_ms = 200, .ema_acc = 0.99, .samples = 30, .acc_initialized = true };
    lm.getOrAddStat('r').?.* = .{ .cp = 'r', .ema_ms = 520, .ema_acc = 0.85, .samples = 10, .acc_initialized = true };
    for (0..4) |_| lm.recordBigramSample('t', 'h', 540.0);

    const weak = try generateWeakSpotDrill(&buf, 21, &lm, &profile, 20);
    var hits: usize = 0;
    var wit = std.mem.splitScalar(u8, weak, ' ');
    while (wit.next()) |w| {
        if (std.mem.indexOf(u8, w, "th") != null or std.mem.indexOfScalar(u8, w, 'r') != null) hits += 1;
    }
    try t.expect(hits >= 15);
}

test "legacy tests have the chosen number of lowercase sentences and are reproducible" {
    const t = std.testing;
    for (sentence_counts) |count| for (0..16) |seed| {
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

test "generated drills only ask for characters a sparse layout can produce" {
    const t = std.testing;

    // Five lowercase letters and nothing else: no capitals, digits or symbols.
    var profile: layout_profile.LayoutProfile = .{ .key_count = 5, .layer_count = 1 };
    for ("aeint", 0..) |ch, i| {
        profile.routes[profile.route_len] = .{ .cp = ch, .kind = .base, .layer = 0, .key_index = i };
        profile.route_len += 1;
    }
    const stages = [_]Stage{ .home_row, .all_letters, .shift, .punctuation_numbers, .layers_combos };
    var produced: usize = 0;
    for (stages) |stage| for (0..6) |round| {
        var buffer: [2048]u8 = undefined;
        const text = generateDrill(&buffer, .{
            .stage = stage,
            .seed = 0x51ab + round,
            .punct_group = @intCast(round),
            .profile = &profile,
        }) catch |err| {
            try t.expectEqual(error.NoTypeableDrill, err);
            continue;
        };
        produced += 1;
        try t.expect(text[0] != ' ' and text[text.len - 1] != ' ');
        for (text) |ch| try t.expect(ch == ' ' or profile.routeFor(ch) != null);
    };
    // The two letter stages must still produce drills.
    try t.expect(produced >= 12);
}
