//! The order in which the Tutor unlocks letters on a layout. The start
//! letters come from the home row as far as they still form plenty of real
//! words, with both hands taking part; every later letter is the one that
//! adds the most frequent words, leaning towards the hand with fewer letters.
const std = @import("std");
const word_list = @import("practice_words.zig");
const layout_profile = @import("practice_layout_profile.zig");

const Hand = layout_profile.Hand;

/// Letters unlocked from the start.
pub const start_letters: usize = 6;
/// Real words the start letters have to form.
pub const min_start_words: u32 = 40;
/// Each hand types at least this many start letters, where the layout knows
/// its hands.
pub const min_letters_per_hand: u32 = 2;
/// Start letters whose words one hand types at most this share more of
/// than the other count as even.
const even_hands_lead: f32 = 0.2;
/// Letters the start set is chosen from: the home row, then the most
/// word-forming others.
const max_pool: usize = 16;
/// A later letter on the hand that already has this many letters more than
/// the other counts only `crowded_hand_factor` of its words.
const crowded_hand_lead: u32 = 2;
const crowded_hand_factor: f32 = 0.5;

pub const Input = struct {
    /// The letters the layout can type, a-z.
    letters: []const u8,
    /// The hand of each letter, by `c - 'a'`.
    hands: [26]Hand = @splat(.neutral),
    /// Letters on the home row.
    home_mask: u32 = 0,
};

/// The hand of every letter `profile` types and its home-row letters.
pub fn inputFor(profile: *const layout_profile.LayoutProfile) Input {
    var input: Input = .{ .letters = profile.unlockSlice(), .hands = handsOf(profile) };
    if (profile.fidelity == .schematic) {
        for (profile.zone1Letters()) |ch| input.home_mask |= bit(ch);
    }
    return input;
}

/// The hand that types each letter on `profile`; neutral when a combo needs
/// both hands or the board does not say.
pub fn handsOf(profile: *const layout_profile.LayoutProfile) [26]Hand {
    var hands: [26]Hand = @splat(.neutral);
    for (0..26) |i| {
        const ch: u21 = @intCast('a' + i);
        const route = profile.routeFor(ch) orelse profile.comboFor(ch) orelse continue;
        const hand = profile.handFor(route.key_index);
        if (route.combo_key_index) |other| {
            if (profile.handFor(other) != hand) continue;
        }
        hands[i] = hand;
    }
    return hands;
}

/// The unlock order for `input` in `out`: the start letters first.
pub fn compute(list: *const word_list.List, input: Input, out: *[26]u8) []const u8 {
    if (cache.valid and cache.matches(input)) {
        @memcpy(out[0..cache.len], cache.order[0..cache.len]);
        return out[0..cache.len];
    }
    const n = computeUncached(list, input, out);
    cache.store(input, out[0..n]);
    return out[0..n];
}

const Cache = struct {
    valid: bool = false,
    letters: [26]u8 = undefined,
    letters_len: usize = 0,
    hands: [26]Hand = undefined,
    home_mask: u32 = 0,
    order: [26]u8 = undefined,
    len: usize = 0,

    fn matches(self: *const Cache, input: Input) bool {
        return std.mem.eql(u8, self.letters[0..self.letters_len], input.letters) and
            std.mem.eql(Hand, &self.hands, &input.hands) and self.home_mask == input.home_mask;
    }

    fn store(self: *Cache, input: Input, order: []const u8) void {
        if (input.letters.len > self.letters.len) return;
        self.letters_len = input.letters.len;
        @memcpy(self.letters[0..input.letters.len], input.letters);
        self.hands = input.hands;
        self.home_mask = input.home_mask;
        self.len = order.len;
        @memcpy(self.order[0..order.len], order);
        self.valid = true;
    }
};

var cache: Cache = .{};

/// Every distinct letter mask of the list with its word count and the summed
/// frequency weight of its words.
const Entry = struct { mask: u32, count: u32, weight: f32 };

var entries_buf: [word_list.max_words]Entry = undefined;
var entries_len: usize = 0;
var entries_list: ?*const word_list.List = null;
/// The entries one start-set search looks at.
var fit_buf: [word_list.max_words]Entry = undefined;

fn entriesOf(list: *const word_list.List) []const Entry {
    if (entries_list == list) return entries_buf[0..entries_len];
    var n: usize = 0;
    for (list.items[0..list.len], 0..) |w, rank| {
        entries_buf[n] = .{ .mask = w.mask, .count = 1, .weight = wordWeight(rank) };
        n += 1;
    }
    std.mem.sort(Entry, entries_buf[0..n], {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.mask < b.mask;
        }
    }.less);
    var out: usize = 0;
    for (entries_buf[0..n]) |e| {
        if (out > 0 and entries_buf[out - 1].mask == e.mask) {
            entries_buf[out - 1].count += 1;
            entries_buf[out - 1].weight += e.weight;
        } else {
            entries_buf[out] = e;
            out += 1;
        }
    }
    entries_len = out;
    entries_list = list;
    return entries_buf[0..out];
}

/// The weight of the word at `rank`, as the lesson generator draws it.
pub fn wordWeight(rank: usize) f32 {
    return 1.0 / @sqrt(@as(f32, @floatFromInt(rank + 3)));
}

fn bit(ch: u8) u32 {
    return @as(u32, 1) << @intCast(ch - 'a');
}

fn isLetter(ch: u8) bool {
    return ch >= 'a' and ch <= 'z';
}

fn computeUncached(list: *const word_list.List, input: Input, out: *[26]u8) usize {
    // The typeable letters in the list's word-forming order, then the rest.
    var ranked: [26]u8 = undefined;
    var ranked_len: usize = 0;
    var typeable: u32 = 0;
    for (input.letters) |ch| if (isLetter(ch)) {
        typeable |= bit(ch);
    };
    for (list.letterOrder()) |ch| if (typeable & bit(ch) != 0) {
        ranked[ranked_len] = ch;
        ranked_len += 1;
    };
    for (input.letters) |ch| {
        if (!isLetter(ch) or std.mem.indexOfScalar(u8, ranked[0..ranked_len], ch) != null) continue;
        ranked[ranked_len] = ch;
        ranked_len += 1;
    }
    if (ranked_len <= start_letters) {
        @memcpy(out[0..ranked_len], ranked[0..ranked_len]);
        return ranked_len;
    }

    var left: u32 = 0;
    var right: u32 = 0;
    for (ranked[0..ranked_len]) |ch| switch (input.hands[ch - 'a']) {
        .left => left |= bit(ch),
        .right => right |= bit(ch),
        .neutral => {},
    };
    const hands_known = @popCount(left) >= min_letters_per_hand and @popCount(right) >= min_letters_per_hand;

    const all = entriesOf(list);
    const start = chooseStart(all, ranked[0..ranked_len], input.home_mask & typeable, left, right, hands_known);

    // Start letters in word-forming order, then one letter at a time.
    var n: usize = 0;
    var chosen: u32 = 0;
    for (ranked[0..ranked_len]) |ch| if (start & bit(ch) != 0) {
        out[n] = ch;
        n += 1;
        chosen |= bit(ch);
    };
    while (n < ranked_len) {
        var best: ?u8 = null;
        var best_gain: f32 = -1;
        const left_count = @popCount(chosen & left);
        const right_count = @popCount(chosen & right);
        for (ranked[0..ranked_len]) |ch| {
            const b = bit(ch);
            if (chosen & b != 0) continue;
            const with = chosen | b;
            var gain: f32 = 0;
            for (all) |e| {
                if (e.mask & b != 0 and e.mask & ~with == 0) gain += e.weight;
            }
            if (hands_known) {
                const crowded = (left & b != 0 and left_count >= right_count + crowded_hand_lead) or
                    (right & b != 0 and right_count >= left_count + crowded_hand_lead);
                if (crowded) gain *= crowded_hand_factor;
            }
            // Ties keep the word-forming order.
            if (gain > best_gain) {
                best = ch;
                best_gain = gain;
            }
        }
        const ch = best.?;
        out[n] = ch;
        n += 1;
        chosen |= bit(ch);
    }
    return n;
}

const Score = struct {
    enough_words: bool,
    hands_ok: bool,
    home: u32,
    imbalance: u32,
    weight: f32,

    fn better(a: Score, b: Score) bool {
        if (a.enough_words != b.enough_words) return a.enough_words;
        if (a.hands_ok != b.hands_ok) return a.hands_ok;
        if (a.enough_words) {
            if (a.home != b.home) return a.home > b.home;
            if (a.imbalance != b.imbalance) return a.imbalance < b.imbalance;
        }
        return a.weight > b.weight;
    }
};

/// The start set: enough words first, both hands, as much home row as
/// possible, then the hands typing the most evenly in the words it forms, and
/// the most frequent words.
fn chooseStart(all: []const Entry, ranked: []const u8, home: u32, left: u32, right: u32, hands_known: bool) u32 {
    var pool: [max_pool]u8 = undefined;
    var pool_len: usize = 0;
    for (ranked) |ch| if (home & bit(ch) != 0 and pool_len < max_pool) {
        pool[pool_len] = ch;
        pool_len += 1;
    };
    for (ranked) |ch| {
        if (pool_len == max_pool) break;
        if (home & bit(ch) != 0) continue;
        pool[pool_len] = ch;
        pool_len += 1;
    }
    var pool_mask: u32 = 0;
    for (pool[0..pool_len]) |ch| pool_mask |= bit(ch);

    // Only words that fit the pool and need at most `start_letters` letters.
    var fit_len: usize = 0;
    for (all) |e| {
        if (e.mask & ~pool_mask != 0 or @popCount(e.mask) > start_letters) continue;
        fit_buf[fit_len] = e;
        fit_len += 1;
    }
    const fit = fit_buf[0..fit_len];

    var best_mask: u32 = 0;
    var best: ?Score = null;
    var idx: [start_letters]usize = undefined;
    for (&idx, 0..) |*v, i| v.* = i;
    while (true) {
        var set: u32 = 0;
        for (idx) |i| set |= bit(pool[i]);
        var words: u32 = 0;
        var weight: f32 = 0;
        // How much each hand types in the words these letters form.
        var left_use: f32 = 0;
        var right_use: f32 = 0;
        for (fit) |e| if (e.mask & ~set == 0) {
            words += e.count;
            weight += e.weight;
            left_use += e.weight * @as(f32, @floatFromInt(@popCount(e.mask & left)));
            right_use += e.weight * @as(f32, @floatFromInt(@popCount(e.mask & right)));
        };
        const l = @popCount(set & left);
        const r = @popCount(set & right);
        const use = left_use + right_use;
        const lead = if (use > 0) @abs(left_use - right_use) / use else 0;
        const score: Score = .{
            .enough_words = words >= min_start_words,
            .hands_ok = !hands_known or (l >= min_letters_per_hand and r >= min_letters_per_hand),
            .home = @popCount(set & home),
            // In tenths of the typing; sets close to even compare by words.
            .imbalance = if (hands_known and lead > even_hands_lead) @intFromFloat(@round(lead * 10)) else 0,
            .weight = weight,
        };
        if (best == null or score.better(best.?)) {
            best = score;
            best_mask = set;
        }
        // Next combination of `start_letters` out of `pool_len`.
        var k: usize = start_letters;
        while (k > 0) {
            k -= 1;
            if (idx[k] < pool_len - start_letters + k) break;
        } else break;
        if (idx[k] >= pool_len - start_letters + k) break;
        idx[k] += 1;
        for (k + 1..start_letters) |j| idx[j] = idx[j - 1] + 1;
    }
    return best_mask;
}

fn countWords(list: *const word_list.List, letters: []const u8) usize {
    var mask: u32 = 0;
    for (letters) |ch| mask |= bit(ch);
    var n: usize = 0;
    for (list.items[0..list.len]) |w| {
        if (w.mask & ~mask == 0) n += 1;
    }
    return n;
}

fn testInput(left: []const u8, right: []const u8, home: []const u8) Input {
    var input: Input = .{ .letters = "abcdefghijklmnopqrstuvwxyz" };
    for (left) |ch| input.hands[ch - 'a'] = .left;
    for (right) |ch| input.hands[ch - 'a'] = .right;
    for (home) |ch| input.home_mask |= bit(ch);
    return input;
}

fn handCount(input: Input, letters: []const u8, hand: Hand) usize {
    var n: usize = 0;
    for (letters) |ch| {
        if (input.hands[ch - 'a'] == hand) n += 1;
    }
    return n;
}

test "Colemak starts on its home row with both hands and plenty of words" {
    const t = std.testing;
    const list = word_list.english();
    const input = testInput("qwfpgarstdzxcvb", "jluyhneiokm", "arstneio");
    var buf: [26]u8 = undefined;
    const order = compute(list, input, &buf);
    try t.expectEqual(@as(usize, 26), order.len);
    const first = order[0..start_letters];
    for (first) |ch| try t.expect(input.home_mask & bit(ch) != 0);
    try t.expectEqual(@as(usize, 3), handCount(input, first, .left));
    try t.expectEqual(@as(usize, 3), handCount(input, first, .right));
    try t.expect(countWords(list, first) >= min_start_words);
    // Every letter appears once.
    var seen: u32 = 0;
    for (order) |ch| {
        try t.expect(seen & bit(ch) == 0);
        seen |= bit(ch);
    }
}

test "QWERTY keeps most of its home row and adds the vowels it lacks" {
    const t = std.testing;
    const list = word_list.english();
    const input = testInput("qwertasdfgzxcvb", "yuiophjklnm", "asdfjkl");
    var buf: [26]u8 = undefined;
    const order = compute(list, input, &buf);
    const first = order[0..start_letters];
    try t.expect(countWords(list, first) >= min_start_words);
    try t.expect(handCount(input, first, .left) >= min_letters_per_hand);
    try t.expect(handCount(input, first, .right) >= min_letters_per_hand);
    var home: usize = 0;
    for (first) |ch| {
        if (input.home_mask & bit(ch) != 0) home += 1;
    }
    try t.expect(home >= 3);
}

test "later letters lean towards the hand with fewer letters" {
    const t = std.testing;
    const list = word_list.english();
    const input = testInput("qwfpgarstdzxcvb", "jluyhneiokm", "arstneio");
    var buf: [26]u8 = undefined;
    const order = compute(list, input, &buf);
    // After the first twelve letters neither hand leads by more than three.
    const left = handCount(input, order[0..12], .left);
    const right = handCount(input, order[0..12], .right);
    try t.expect(@max(left, right) - @min(left, right) <= 3);
}

test "without hands or home row the start letters are the most word-forming" {
    const t = std.testing;
    const list = word_list.english();
    var buf: [26]u8 = undefined;
    const order = compute(list, .{ .letters = "abcdefghijklmnopqrstuvwxyz" }, &buf);
    try t.expect(countWords(list, order[0..start_letters]) >= min_start_words);
    // A second call with the same input comes from the cache, unchanged.
    var again: [26]u8 = undefined;
    try t.expectEqualStrings(order, compute(list, .{ .letters = "abcdefghijklmnopqrstuvwxyz" }, &again));
}
