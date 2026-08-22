const std = @import("std");

pub const legacy_count = 83;
pub const official_count = 109;
pub const count = official_count;

pub const Achievement = struct {
    id: u16,
    file: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const Input = struct {
    eligible: bool,
    mode: u8,
    mods: u32,
    perfect: bool,
    max_combo: u32,
    stars: f64,
    accuracy: f64 = 0,
    pp: f64 = 0,
    plays: i64 = 0,
    total_hits: i64 = 0,
    global_rank: i64 = 0,
    mod_intro_eligible: bool = false,
    conversion_mod: bool = false,
    fun_mod: bool = false,
};

pub const Unlocks = struct {
    ids: [count]u16 = [_]u16{0} ** count,
    len: usize = 0,

    pub fn append(self: *Unlocks, id: u16) void {
        if (self.len == count) return;
        self.ids[self.len] = id;
        self.len += 1;
    }

    pub fn slice(self: *const Unlocks) []const u16 {
        return self.ids[0..self.len];
    }
};

const legacy_catalog = [_]Achievement{
    .{ .id = 1, .file = "osu-skill-pass-1", .name = "Rising Star", .description = "Can't go forward without the first steps." },
    .{ .id = 2, .file = "osu-skill-pass-2", .name = "Constellation Prize", .description = "Definitely not a consolation prize. Now things start getting hard!" },
    .{ .id = 3, .file = "osu-skill-pass-3", .name = "Building Confidence", .description = "Oh, you've SO got this." },
    .{ .id = 4, .file = "osu-skill-pass-4", .name = "Insanity Approaches", .description = "You're not twitching, you're just ready." },
    .{ .id = 5, .file = "osu-skill-pass-5", .name = "These Clarion Skies", .description = "Everything seems so clear now." },
    .{ .id = 6, .file = "osu-skill-pass-6", .name = "Above and Beyond", .description = "A cut above the rest." },
    .{ .id = 7, .file = "osu-skill-pass-7", .name = "Supremacy", .description = "All marvel before your prowess." },
    .{ .id = 8, .file = "osu-skill-pass-8", .name = "Absolution", .description = "My god, you're full of stars!" },
    .{ .id = 9, .file = "osu-skill-pass-9", .name = "Event Horizon", .description = "No force dares to pull you under." },
    .{ .id = 10, .file = "osu-skill-pass-10", .name = "Phantasm", .description = "Fevered is your passion, extraordinary is your skill." },
    .{ .id = 11, .file = "osu-skill-fc-1", .name = "Totality", .description = "All the notes. Every single one." },
    .{ .id = 12, .file = "osu-skill-fc-2", .name = "Business As Usual", .description = "Two to go, please." },
    .{ .id = 13, .file = "osu-skill-fc-3", .name = "Building Steam", .description = "Hey, this isn't so bad." },
    .{ .id = 14, .file = "osu-skill-fc-4", .name = "Moving Forward", .description = "Bet you feel good about that." },
    .{ .id = 15, .file = "osu-skill-fc-5", .name = "Paradigm Shift", .description = "Surprisingly difficult." },
    .{ .id = 16, .file = "osu-skill-fc-6", .name = "Anguish Quelled", .description = "Don't choke." },
    .{ .id = 17, .file = "osu-skill-fc-7", .name = "Never Give Up", .description = "Excellence is its own reward." },
    .{ .id = 18, .file = "osu-skill-fc-8", .name = "Aberration", .description = "They said it couldn't be done. They were wrong." },
    .{ .id = 19, .file = "osu-skill-fc-9", .name = "Chosen", .description = "Reign among the Prometheans, where you belong." },
    .{ .id = 20, .file = "osu-skill-fc-10", .name = "Unfathomable", .description = "You have no equal." },
    .{ .id = 21, .file = "osu-combo-500", .name = "500 Combo", .description = "500 big ones! You're moving up in the world!" },
    .{ .id = 22, .file = "osu-combo-750", .name = "750 Combo", .description = "750 notes back to back? Woah." },
    .{ .id = 23, .file = "osu-combo-1000", .name = "1000 Combo", .description = "A thousand reasons why you rock at this game." },
    .{ .id = 24, .file = "osu-combo-2000", .name = "2000 Combo", .description = "Nothing can stop you now." },
    .{ .id = 25, .file = "taiko-skill-pass-1", .name = "My First Don", .description = "Marching to the beat of your own drum. Literally." },
    .{ .id = 26, .file = "taiko-skill-pass-2", .name = "Katsu Katsu Katsu", .description = "Hora! Izuko!" },
    .{ .id = 27, .file = "taiko-skill-pass-3", .name = "Not Even Trying", .description = "Muzukashii? Not even." },
    .{ .id = 28, .file = "taiko-skill-pass-4", .name = "Face Your Demons", .description = "The first trials are now behind you, but are you a match for the Oni?" },
    .{ .id = 29, .file = "taiko-skill-pass-5", .name = "The Demon Within", .description = "No rest for the wicked." },
    .{ .id = 30, .file = "taiko-skill-pass-6", .name = "Drumbreaker", .description = "Too strong." },
    .{ .id = 31, .file = "taiko-skill-pass-7", .name = "The Godfather", .description = "You are the Don of Dons." },
    .{ .id = 32, .file = "taiko-skill-pass-8", .name = "Rhythm Incarnate", .description = "Feel the beat. Become the beat." },
    .{ .id = 33, .file = "taiko-skill-fc-1", .name = "Keeping Time", .description = "Don, then katsu. Don, then katsu.." },
    .{ .id = 34, .file = "taiko-skill-fc-2", .name = "To Your Own Beat", .description = "Straight and steady." },
    .{ .id = 35, .file = "taiko-skill-fc-3", .name = "Big Drums", .description = "Bigger scores to match." },
    .{ .id = 36, .file = "taiko-skill-fc-4", .name = "Adversity Overcome", .description = "Difficult? Not for you." },
    .{ .id = 37, .file = "taiko-skill-fc-5", .name = "Demonslayer", .description = "An Oni felled forevermore." },
    .{ .id = 38, .file = "taiko-skill-fc-6", .name = "Rhythm's Call", .description = "Heralding true skill." },
    .{ .id = 39, .file = "taiko-skill-fc-7", .name = "Time Everlasting", .description = "Not a single beat escapes you." },
    .{ .id = 40, .file = "taiko-skill-fc-8", .name = "The Drummer's Throne", .description = "Percussive brilliance befitting royalty alone." },
    .{ .id = 41, .file = "fruits-skill-pass-1", .name = "A Slice Of Life", .description = "Hey, this fruit catching business isn't bad." },
    .{ .id = 42, .file = "fruits-skill-pass-2", .name = "Dashing Ever Forward", .description = "Fast is how you do it." },
    .{ .id = 43, .file = "fruits-skill-pass-3", .name = "Zesty Disposition", .description = "No scurvy for you, not with that much fruit." },
    .{ .id = 44, .file = "fruits-skill-pass-4", .name = "Hyperdash ON!", .description = "Time and distance is no obstacle to you." },
    .{ .id = 45, .file = "fruits-skill-pass-5", .name = "It's Raining Fruit", .description = "And you can catch them all." },
    .{ .id = 46, .file = "fruits-skill-pass-6", .name = "Fruit Ninja", .description = "Legendary techniques." },
    .{ .id = 47, .file = "fruits-skill-pass-7", .name = "Dreamcatcher", .description = "No fruit, only dreams now." },
    .{ .id = 48, .file = "fruits-skill-pass-8", .name = "Lord of the Catch", .description = "Your kingdom kneels before you." },
    .{ .id = 49, .file = "fruits-skill-fc-1", .name = "Sweet And Sour", .description = "Apples and oranges, literally." },
    .{ .id = 50, .file = "fruits-skill-fc-2", .name = "Reaching The Core", .description = "The seeds of future success." },
    .{ .id = 51, .file = "fruits-skill-fc-3", .name = "Clean Platter", .description = "Clean only of failure. It is completely full, otherwise." },
    .{ .id = 52, .file = "fruits-skill-fc-4", .name = "Between The Rain", .description = "No umbrella needed." },
    .{ .id = 53, .file = "fruits-skill-fc-5", .name = "Addicted", .description = "That was an overdose?" },
    .{ .id = 54, .file = "fruits-skill-fc-6", .name = "Quickening", .description = "A dash above normal limits." },
    .{ .id = 55, .file = "fruits-skill-fc-7", .name = "Supersonic", .description = "Faster than is reasonably necessary." },
    .{ .id = 56, .file = "fruits-skill-fc-8", .name = "Dashing Scarlet", .description = "Speed beyond mortal reckoning." },
    .{ .id = 57, .file = "mania-skill-pass-1", .name = "First Steps", .description = "It isn't 9-to-5, but 1-to-9. Keys, that is." },
    .{ .id = 58, .file = "mania-skill-pass-2", .name = "No Normal Player", .description = "Not anymore, at least." },
    .{ .id = 59, .file = "mania-skill-pass-3", .name = "Impulse Drive", .description = "Not quite hyperspeed, but getting close." },
    .{ .id = 60, .file = "mania-skill-pass-4", .name = "Hyperspeed", .description = "Woah." },
    .{ .id = 61, .file = "mania-skill-pass-5", .name = "Ever Onwards", .description = "Another challenge is just around the corner." },
    .{ .id = 62, .file = "mania-skill-pass-6", .name = "Another Surpassed", .description = "Is there no limit to your skills?" },
    .{ .id = 63, .file = "mania-skill-pass-7", .name = "Extra Credit", .description = "See me after class." },
    .{ .id = 64, .file = "mania-skill-pass-8", .name = "Maniac", .description = "There's just no stopping you." },
    .{ .id = 65, .file = "mania-skill-fc-1", .name = "Keystruck", .description = "The beginning of a new story" },
    .{ .id = 66, .file = "mania-skill-fc-2", .name = "Keying In", .description = "Finding your groove." },
    .{ .id = 67, .file = "mania-skill-fc-3", .name = "Hyperflow", .description = "You can *feel* the rhythm." },
    .{ .id = 68, .file = "mania-skill-fc-4", .name = "Breakthrough", .description = "Many skills mastered, rolled into one." },
    .{ .id = 69, .file = "mania-skill-fc-5", .name = "Everything Extra", .description = "Giving your all is giving everything you have." },
    .{ .id = 70, .file = "mania-skill-fc-6", .name = "Level Breaker", .description = "Finesse beyond reason" },
    .{ .id = 71, .file = "mania-skill-fc-7", .name = "Step Up", .description = "A precipice rarely seen." },
    .{ .id = 72, .file = "mania-skill-fc-8", .name = "Behind The Veil", .description = "Supernatural!" },
    .{ .id = 73, .file = "all-intro-suddendeath", .name = "Finality", .description = "High stakes, no regrets." },
    .{ .id = 74, .file = "all-intro-hidden", .name = "Blindsight", .description = "I can see just perfectly" },
    .{ .id = 75, .file = "all-intro-perfect", .name = "Perfectionist", .description = "Accept nothing but the best." },
    .{ .id = 76, .file = "all-intro-hardrock", .name = "Rock Around The Clock", .description = "You can't stop the rock." },
    .{ .id = 77, .file = "all-intro-doubletime", .name = "Time And A Half", .description = "Having a right ol' time. One and a half of them, almost." },
    .{ .id = 78, .file = "all-intro-flashlight", .name = "Are You Afraid Of The Dark?", .description = "Harder than it looks, probably because it's hard to look." },
    .{ .id = 79, .file = "all-intro-easy", .name = "Dial It Right Back", .description = "Sometimes you just want to take it easy." },
    .{ .id = 80, .file = "all-intro-nofail", .name = "Risk Averse", .description = "Safety nets are fun!" },
    .{ .id = 81, .file = "all-intro-nightcore", .name = "Sweet Rave Party", .description = "Founded in the fine tradition of changing things that were just fine as they were." },
    .{ .id = 82, .file = "all-intro-halftime", .name = "Slowboat", .description = "You got there. Eventually." },
    .{ .id = 83, .file = "all-intro-spunout", .name = "Burned Out", .description = "One cannot always spin to win." },
};

const official_extra_catalog = [_]Achievement{
    .{ .id = 204, .file = "all-skill-highranker-1", .name = "I Can See The Top", .description = "Your dedication has paid off. Welcome to the top 50,000!" },
    .{ .id = 205, .file = "all-skill-highranker-2", .name = "The Gradual Rise", .description = "There's no stopping you, is there? Welcome to the top 10,000!" },
    .{ .id = 206, .file = "all-skill-highranker-3", .name = "Scaling Up", .description = "Welcome to the top 5,000. Never give up!" },
    .{ .id = 207, .file = "all-skill-highranker-4", .name = "Approaching The Summit", .description = "Pro tier. Welcome to the top 1,000!" },
    .{ .id = 208, .file = "osu-plays-5000", .name = "5,000 Plays", .description = "There's a lot more where that came from." },
    .{ .id = 209, .file = "osu-plays-15000", .name = "15,000 Plays", .description = "Must.. click.. circles.." },
    .{ .id = 210, .file = "osu-plays-25000", .name = "25,000 Plays", .description = "There's no going back." },
    .{ .id = 211, .file = "osu-plays-50000", .name = "50,000 Plays", .description = "You're here forever." },
    .{ .id = 212, .file = "taiko-hits-30000", .name = "30,000 Drum Hits", .description = "Did that drum have a face?" },
    .{ .id = 213, .file = "taiko-hits-300000", .name = "300,000 Drum Hits", .description = "The rhythm never stops." },
    .{ .id = 214, .file = "taiko-hits-3000000", .name = "3,000,000 Drum Hits", .description = "Truly, the Don of dons." },
    .{ .id = 215, .file = "taiko-hits-30000000", .name = "30,000,000 Drum Hits", .description = "Your rhythm, eternal." },
    .{ .id = 216, .file = "fruits-hits-20000", .name = "Catch 20,000 fruits", .description = "That is a lot of dietary fiber." },
    .{ .id = 217, .file = "fruits-hits-200000", .name = "Catch 200,000 fruits", .description = "So, I heard you like fruit..." },
    .{ .id = 218, .file = "fruits-hits-2000000", .name = "Catch 2,000,000 fruits", .description = "Downright healthy." },
    .{ .id = 219, .file = "fruits-hits-20000000", .name = "Catch 20,000,000 fruits", .description = "Nothing left behind." },
    .{ .id = 220, .file = "mania-hits-40000", .name = "40,000 Keys", .description = "Just the start of the rainbow." },
    .{ .id = 221, .file = "mania-hits-400000", .name = "400,000 Keys", .description = "Four hundred thousand and still not even close." },
    .{ .id = 222, .file = "mania-hits-4000000", .name = "4,000,000 Keys", .description = "Is this the end of the rainbow?" },
    .{ .id = 223, .file = "mania-hits-40000000", .name = "40,000,000 Keys", .description = "When someone asks which keys you play, the answer is now 'yes'." },
    .{ .id = 224, .file = "all-intro-conversion", .name = "Gear Shift", .description = "Tailor your experience to your perfect fit." },
    .{ .id = 225, .file = "all-intro-fun", .name = "Game Night", .description = "Mum said it's my turn with the beatmap!" },
    .{ .id = 226, .file = "all-skill-dc-1", .name = "Daily Sprout", .description = "Ready for anything." },
    .{ .id = 227, .file = "all-skill-dc-7", .name = "Weekly Sapling", .description = "Circadian rhythm calibrated." },
    .{ .id = 228, .file = "all-skill-dc-30", .name = "Monthly Shrub", .description = "In for the grind." },
    .{ .id = 229, .file = "osu-skill-cyclone", .name = "Cyclone", .description = "Clockwise or anticlockwise, that is the question." },
};

pub const catalog = legacy_catalog ++ official_extra_catalog;

pub fn byId(id: u16) ?Achievement {
    for (catalog) |achievement| if (achievement.id == id) return achievement;
    return null;
}

pub fn modeFor(achievement: Achievement) ?[]const u8 {
    const slug = achievement.file;
    if (std.mem.startsWith(u8, slug, "osu-")) return "osu";
    if (std.mem.startsWith(u8, slug, "taiko-")) return "taiko";
    if (std.mem.startsWith(u8, slug, "fruits-")) return "fruits";
    if (std.mem.startsWith(u8, slug, "mania-")) return "mania";
    return null;
}

pub fn groupingFor(achievement: Achievement) []const u8 {
    if (std.mem.indexOf(u8, achievement.file, "-intro-") != null) return "Mod Introduction";
    return "Skill & Dedication";
}

pub fn orderingFor(achievement: Achievement) u16 {
    const slug = achievement.file;
    if (std.mem.indexOf(u8, slug, "-skill-pass-") != null or std.mem.indexOf(u8, slug, "-pass-") != null) return 10;
    if (std.mem.indexOf(u8, slug, "-skill-fc-") != null or std.mem.indexOf(u8, slug, "-fc-") != null) return 20;
    if (std.mem.indexOf(u8, slug, "-accuracy-") != null) return 30;
    if (std.mem.indexOf(u8, slug, "-pp-") != null) return 40;
    if (std.mem.indexOf(u8, slug, "-combo-") != null) return 50;
    if (std.mem.indexOf(u8, slug, "-plays-") != null or std.mem.indexOf(u8, slug, "-hits-") != null) return 60;
    if (std.mem.indexOf(u8, slug, "-highranker-") != null) return 70;
    if (std.mem.indexOf(u8, slug, "-dc-") != null) return 80;
    if (std.mem.indexOf(u8, slug, "-intro-") != null) return 100;
    return 90;
}

pub fn writeIconUrl(writer: *std.Io.Writer, achievement: Achievement) !void {
    try writer.print("https://assets.ppy.sh/medals/web/{s}.png", .{achievement.file});
}

fn starLevel(input: Input, mode: u8, level: u8, requires_perfect: bool) bool {
    return input.mode == mode and (!requires_perfect or input.perfect) and input.stars >= @as(f64, @floatFromInt(level)) and input.stars < @as(f64, @floatFromInt(level + 1));
}

pub fn matches(id: u16, input: Input) bool {
    if (id == 224) return input.mod_intro_eligible and input.conversion_mod;
    if (id == 225) return input.mod_intro_eligible and input.fun_mod;
    if (!input.eligible or !std.math.isFinite(input.stars) or input.stars < 0) return false;
    const difficulty_reduction = @as(u32, 1 | 2 | 256);
    const skill_eligible = input.mods & difficulty_reduction == 0;
    if (id >= 1 and id <= 10) return skill_eligible and starLevel(input, 0, @intCast(id), false);
    if (id >= 11 and id <= 20) return skill_eligible and starLevel(input, 0, @intCast(id - 10), true);
    if (id == 21) return input.mode == 0 and input.max_combo >= 500;
    if (id == 22) return input.mode == 0 and input.max_combo >= 750;
    if (id == 23) return input.mode == 0 and input.max_combo >= 1000;
    if (id == 24) return input.mode == 0 and input.max_combo >= 2000;
    if (id >= 25 and id <= 32) return skill_eligible and starLevel(input, 1, @intCast(id - 24), false);
    if (id >= 33 and id <= 40) return skill_eligible and starLevel(input, 1, @intCast(id - 32), true);
    if (id >= 41 and id <= 48) return skill_eligible and starLevel(input, 2, @intCast(id - 40), false);
    if (id >= 49 and id <= 56) return skill_eligible and starLevel(input, 2, @intCast(id - 48), true);
    if (id >= 57 and id <= 64) return skill_eligible and starLevel(input, 3, @intCast(id - 56), false);
    if (id >= 65 and id <= 72) return skill_eligible and starLevel(input, 3, @intCast(id - 64), true);
    if (id <= legacy_count) return switch (id) {
        73 => input.mods == 32,
        74 => input.mods == 8,
        75 => input.mods == 16_416,
        76 => input.mods == 16,
        77 => input.mods == 64,
        78 => input.mods == 1_024,
        79 => input.mods == 2,
        80 => input.mods == 1,
        81 => input.mods == 576,
        82 => input.mods == 256,
        83 => input.mode == 0 and input.mods == 4_096,
        else => false,
    };
    if (id >= 204 and id <= 207) {
        const thresholds = [_]i64{ 50_000, 10_000, 5_000, 1_000 };
        return input.global_rank > 0 and input.global_rank <= thresholds[id - 204];
    }
    if (id >= 208 and id <= 211) {
        const thresholds = [_]i64{ 5_000, 15_000, 25_000, 50_000 };
        return input.mode == 0 and input.plays >= thresholds[id - 208];
    }
    if (id >= 212 and id <= 215) {
        const thresholds = [_]i64{ 30_000, 300_000, 3_000_000, 30_000_000 };
        return input.mode == 1 and input.total_hits >= thresholds[id - 212];
    }
    if (id >= 216 and id <= 219) {
        const thresholds = [_]i64{ 20_000, 200_000, 2_000_000, 20_000_000 };
        return input.mode == 2 and input.total_hits >= thresholds[id - 216];
    }
    if (id >= 220 and id <= 223) {
        const thresholds = [_]i64{ 40_000, 400_000, 4_000_000, 40_000_000 };
        return input.mode == 3 and input.total_hits >= thresholds[id - 220];
    }
    return false;
}

pub fn candidates(input: Input) Unlocks {
    var result: Unlocks = .{};
    for (catalog) |achievement| if (matches(achievement.id, input)) result.append(achievement.id);
    return result;
}

pub fn writeStable(writer: *std.Io.Writer, unlocks: Unlocks) !void {
    var first = true;
    for (unlocks.slice()) |id| {
        const achievement = byId(id) orelse continue;
        if (!first) try writer.writeByte('/');
        first = false;
        try writer.print("{s}+{s}+{s}", .{ achievement.file, achievement.name, achievement.description });
    }
}

pub fn writeJson(writer: *std.Io.Writer, id: u16, achieved_at: []const u8, achieved_count: i64, user_count: i64, include_metadata: bool) !void {
    const achievement = byId(id) orelse return error.InvalidAchievement;
    try writer.print("{{\"achievement_id\":{d},\"achieved_at\":", .{id});
    try std.json.Stringify.value(achieved_at, .{}, writer);
    if (include_metadata) {
        try writer.writeAll(",\"file\":");
        try std.json.Stringify.value(achievement.file, .{}, writer);
        try writer.writeAll(",\"slug\":");
        try std.json.Stringify.value(achievement.file, .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(achievement.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(achievement.description, .{}, writer);
        try writer.writeAll(",\"grouping\":");
        try std.json.Stringify.value(groupingFor(achievement), .{}, writer);
        try writer.print(",\"ordering\":{d},\"mode\":", .{orderingFor(achievement)});
        if (modeFor(achievement)) |mode| try std.json.Stringify.value(mode, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll(",\"instructions\":null,\"icon_url\":\"");
        try writeIconUrl(writer, achievement);
        try writer.print("\",\"achieved_count\":{d},\"achieved_percent\":", .{achieved_count});
        if (user_count > 0) try writer.print("{d:.8}", .{@as(f64, @floatFromInt(achieved_count)) / @as(f64, @floatFromInt(user_count))}) else try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

pub fn writeLazerUnlocks(writer: *std.Io.Writer, unlocks: Unlocks, user_id: i32) !void {
    try writer.writeByte('[');
    var first = true;
    for (unlocks.slice()) |id| {
        const achievement = byId(id) orelse continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"achievement_id\":{d},\"achievement_mode\":", .{id});
        if (modeFor(achievement)) |mode| try std.json.Stringify.value(mode, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll(",\"cover_url\":\"");
        try writeIconUrl(writer, achievement);
        try writer.writeAll("\",\"slug\":");
        try std.json.Stringify.value(achievement.file, .{}, writer);
        try writer.writeAll(",\"title\":");
        try std.json.Stringify.value(achievement.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(achievement.description, .{}, writer);
        try writer.print(",\"user_id\":{d}}}", .{user_id});
    }
    try writer.writeByte(']');
}

test "catalog contains only official achievements and compatible conditions stay bounded" {
    try std.testing.expectEqual(@as(usize, count), catalog.len);
    for (catalog) |achievement| try std.testing.expect(!std.mem.startsWith(u8, achievement.file, "kai-"));
    try std.testing.expect(byId(84) == null);
    try std.testing.expectEqualStrings("I Can See The Top", byId(204).?.name);
    const unlocks = candidates(.{ .eligible = true, .mode = 0, .mods = 8, .perfect = true, .max_combo = 750, .stars = 4.2, .accuracy = 0.99, .pp = 210 });
    try std.testing.expectEqualSlices(u16, &.{ 4, 14, 21, 22, 74 }, unlocks.slice());
    try std.testing.expectEqual(@as(usize, 0), candidates(.{ .eligible = false, .mode = 0, .mods = 8, .perfect = true, .max_combo = 750, .stars = 4.2 }).slice().len);
}

test "official skill dedication and lazer mod medals use exact rules" {
    try std.testing.expect(!matches(4, .{ .eligible = true, .mode = 0, .mods = 2, .perfect = false, .max_combo = 0, .stars = 4.2 }));
    try std.testing.expect(!matches(74, .{ .eligible = true, .mode = 0, .mods = 8 | 16, .perfect = false, .max_combo = 0, .stars = 1 }));
    try std.testing.expect(matches(204, .{ .eligible = true, .mode = 0, .mods = 0, .perfect = false, .max_combo = 0, .stars = 1, .global_rank = 42_000 }));
    try std.testing.expect(matches(208, .{ .eligible = true, .mode = 0, .mods = 0, .perfect = false, .max_combo = 0, .stars = 1, .plays = 5_000 }));
    try std.testing.expect(matches(215, .{ .eligible = true, .mode = 1, .mods = 0, .perfect = false, .max_combo = 0, .stars = 1, .total_hits = 30_000_000 }));
    try std.testing.expect(matches(224, .{ .eligible = false, .mode = 0, .mods = 0, .perfect = false, .max_combo = 0, .stars = 0, .mod_intro_eligible = true, .conversion_mod = true }));
    try std.testing.expect(matches(225, .{ .eligible = false, .mode = 0, .mods = 0, .perfect = false, .max_combo = 0, .stars = 0, .mod_intro_eligible = true, .fun_mod = true }));
    try std.testing.expect(!matches(226, .{ .eligible = true, .mode = 0, .mods = 0, .perfect = false, .max_combo = 0, .stars = 1 }));
}

test "stable unlock text is exact and JSON escapes metadata" {
    var stable: [256]u8 = undefined;
    var stable_writer = std.Io.Writer.fixed(&stable);
    var unlocks: Unlocks = .{};
    unlocks.append(1);
    unlocks.append(74);
    try writeStable(&stable_writer, unlocks);
    try std.testing.expectEqualStrings("osu-skill-pass-1+Rising Star+Can't go forward without the first steps./all-intro-hidden+Blindsight+I can see just perfectly", stable[0..stable_writer.end]);

    var json_buffer: [1024]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(&json_buffer);
    try writeJson(&json_writer, 1, "2026-08-23T01:02:03Z", 5, 20, true);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_buffer[0..json_writer.end], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("2026-08-23T01:02:03Z", parsed.value.object.get("achieved_at").?.string);
    try std.testing.expectEqualStrings("Skill & Dedication", parsed.value.object.get("grouping").?.string);
    try std.testing.expectEqualStrings("https://assets.ppy.sh/medals/web/osu-skill-pass-1.png", parsed.value.object.get("icon_url").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), parsed.value.object.get("achieved_percent").?.float, 0.000001);

    var lazer_buffer: [1024]u8 = undefined;
    var lazer_writer = std.Io.Writer.fixed(&lazer_buffer);
    try writeLazerUnlocks(&lazer_writer, unlocks, 4);
    try std.testing.expect(std.mem.indexOf(u8, lazer_buffer[0..lazer_writer.end], "\"cover_url\":\"https://assets.ppy.sh/medals/web/osu-skill-pass-1.png\"") != null);
}
