const std = @import("std");

pub const legacy_count = 83;
pub const count = 203;

pub const Achievement = struct {
    id: u8,
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
};

pub const Unlocks = struct {
    ids: [count]u8 = [_]u8{0} ** count,
    len: u8 = 0,

    pub fn append(self: *Unlocks, id: u8) void {
        if (self.len == count) return;
        self.ids[self.len] = id;
        self.len += 1;
    }

    pub fn slice(self: *const Unlocks) []const u8 {
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

pub const catalog = blk: {
    @setEvalBranchQuota(250_000);
    var result: [count]Achievement = undefined;
    for (legacy_catalog, 0..) |achievement, index| result[index] = achievement;
    const modes = [_][]const u8{ "osu", "taiko", "catch", "mania" };
    var id: u8 = legacy_count + 1;
    for (modes) |mode| for (11..16) |level| {
        result[id - 1] = .{
            .id = id,
            .file = std.fmt.comptimePrint("kai-{s}-pass-{d}", .{ mode, level }),
            .name = std.fmt.comptimePrint("{s} {d} star clear", .{ mode, level }),
            .description = std.fmt.comptimePrint("clear a ranked {s} map between {d} and {d} stars.", .{ mode, level, level + 1 }),
        };
        id += 1;
    };
    for (modes) |mode| for (9..16) |level| {
        result[id - 1] = .{
            .id = id,
            .file = std.fmt.comptimePrint("kai-{s}-fc-{d}", .{ mode, level }),
            .name = std.fmt.comptimePrint("{s} {d} star full combo", .{ mode, level }),
            .description = std.fmt.comptimePrint("full combo a ranked {s} map between {d} and {d} stars.", .{ mode, level, level + 1 }),
        };
        id += 1;
    };
    const accuracy_names = [_][]const u8{ "90", "95", "97", "98", "99", "99.5", "100" };
    for (modes) |mode| for (accuracy_names) |accuracy| {
        result[id - 1] = .{
            .id = id,
            .file = std.fmt.comptimePrint("kai-{s}-accuracy-{s}", .{ mode, accuracy }),
            .name = std.fmt.comptimePrint("{s} {s}%", .{ mode, accuracy }),
            .description = std.fmt.comptimePrint("pass a ranked {s} map with at least {s}% accuracy.", .{ mode, accuracy }),
        };
        id += 1;
    };
    const pp_levels = [_]u16{ 25, 50, 100, 150, 200, 300, 400, 500, 750, 1000 };
    for (modes) |mode| for (pp_levels) |pp| {
        result[id - 1] = .{
            .id = id,
            .file = std.fmt.comptimePrint("kai-{s}-pp-{d}", .{ mode, pp }),
            .name = std.fmt.comptimePrint("{s} {d}pp", .{ mode, pp }),
            .description = std.fmt.comptimePrint("set a ranked {s} score worth at least {d}pp.", .{ mode, pp }),
        };
        id += 1;
    };
    const combo_levels = [_]u16{ 3000, 5000, 7500, 10_000 };
    for (combo_levels) |combo| {
        result[id - 1] = .{
            .id = id,
            .file = std.fmt.comptimePrint("kai-osu-combo-{d}", .{combo}),
            .name = std.fmt.comptimePrint("{d} Combo", .{combo}),
            .description = std.fmt.comptimePrint("hold a {d} combo on a ranked osu! map.", .{combo}),
        };
        id += 1;
    }
    if (id != count + 1) @compileError("achievement catalogue count is stale");
    break :blk result;
};

pub fn byId(id: u8) ?Achievement {
    if (id == 0 or id > catalog.len) return null;
    return catalog[id - 1];
}

fn starLevel(input: Input, mode: u8, level: u8, requires_perfect: bool) bool {
    return input.mode == mode and (!requires_perfect or input.perfect) and input.stars >= @as(f64, @floatFromInt(level)) and input.stars < @as(f64, @floatFromInt(level + 1));
}

pub fn matches(id: u8, input: Input) bool {
    if (!input.eligible or !std.math.isFinite(input.stars) or input.stars < 0) return false;
    if (id >= 1 and id <= 10) return input.mods & 1 == 0 and starLevel(input, 0, id, false);
    if (id >= 11 and id <= 20) return starLevel(input, 0, id - 10, true);
    if (id == 21) return input.mode == 0 and input.max_combo >= 500 and input.max_combo < 750;
    if (id == 22) return input.mode == 0 and input.max_combo >= 750 and input.max_combo < 1000;
    if (id == 23) return input.mode == 0 and input.max_combo >= 1000 and input.max_combo < 2000;
    if (id == 24) return input.mode == 0 and input.max_combo >= 2000;
    if (id >= 25 and id <= 32) return input.mods & 1 == 0 and starLevel(input, 1, id - 24, false);
    if (id >= 33 and id <= 40) return starLevel(input, 1, id - 32, true);
    if (id >= 41 and id <= 48) return input.mods & 1 == 0 and starLevel(input, 2, id - 40, false);
    if (id >= 49 and id <= 56) return starLevel(input, 2, id - 48, true);
    if (id >= 57 and id <= 64) return input.mods & 1 == 0 and starLevel(input, 3, id - 56, false);
    if (id >= 65 and id <= 72) return starLevel(input, 3, id - 64, true);
    if (id <= legacy_count) return switch (id) {
        73 => input.mods == 32,
        74 => input.mods & 8 != 0,
        75 => input.mods & 16_384 != 0,
        76 => input.mods & 16 != 0,
        77 => input.mods & 64 != 0,
        78 => input.mods & 1_024 != 0,
        79 => input.mods & 2 != 0,
        80 => input.mods & 1 != 0,
        81 => input.mods & 512 != 0,
        82 => input.mods & 256 != 0,
        83 => input.mods & 4_096 != 0,
        else => false,
    };
    if (id >= 84 and id <= 103) {
        const offset = id - 84;
        return starLevel(input, offset / 5, 11 + offset % 5, false);
    }
    if (id >= 104 and id <= 131) {
        const offset = id - 104;
        return starLevel(input, offset / 7, 9 + offset % 7, true);
    }
    if (id >= 132 and id <= 159) {
        const thresholds = [_]f64{ 0.90, 0.95, 0.97, 0.98, 0.99, 0.995, 1.0 };
        const offset = id - 132;
        return input.mode == offset / 7 and input.accuracy >= thresholds[offset % 7];
    }
    if (id >= 160 and id <= 199) {
        const thresholds = [_]f64{ 25, 50, 100, 150, 200, 300, 400, 500, 750, 1000 };
        const offset = id - 160;
        return input.mode == offset / 10 and input.pp >= thresholds[offset % 10];
    }
    if (id >= 200 and id <= 203) {
        const thresholds = [_]u32{ 3000, 5000, 7500, 10_000 };
        return input.mode == 0 and input.max_combo >= thresholds[id - 200];
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

pub fn writeJson(writer: *std.Io.Writer, id: u8, achieved_at: i64, include_metadata: bool) !void {
    const achievement = byId(id) orelse return error.InvalidAchievement;
    try writer.print("{{\"achievement_id\":{d},\"achieved_at\":{d}", .{ id, achieved_at });
    if (include_metadata) {
        try writer.writeAll(",\"file\":");
        try std.json.Stringify.value(achievement.file, .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(achievement.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(achievement.description, .{}, writer);
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
        try writer.print("{{\"achievement_id\":{d},\"achievement_mode\":null,\"cover_url\":\"\",\"slug\":", .{id});
        try std.json.Stringify.value(achievement.file, .{}, writer);
        try writer.writeAll(",\"title\":");
        try std.json.Stringify.value(achievement.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(achievement.description, .{}, writer);
        try writer.print(",\"user_id\":{d}}}", .{user_id});
    }
    try writer.writeByte(']');
}

test "catalog is dense and compatible conditions stay bounded" {
    try std.testing.expectEqual(@as(usize, count), catalog.len);
    for (catalog, 1..) |achievement, id| try std.testing.expectEqual(@as(u8, @intCast(id)), achievement.id);
    const unlocks = candidates(.{ .eligible = true, .mode = 0, .mods = 8, .perfect = true, .max_combo = 750, .stars = 4.2, .accuracy = 0.99, .pp = 210 });
    try std.testing.expectEqualSlices(u8, &.{ 4, 14, 22, 74, 132, 133, 134, 135, 136, 160, 161, 162, 163, 164 }, unlocks.slice());
    try std.testing.expectEqual(@as(usize, 0), candidates(.{ .eligible = false, .mode = 0, .mods = 8, .perfect = true, .max_combo = 750, .stars = 4.2 }).slice().len);
}

test "stable unlock text is exact and JSON escapes metadata" {
    var stable: [256]u8 = undefined;
    var stable_writer = std.Io.Writer.fixed(&stable);
    var unlocks: Unlocks = .{};
    unlocks.append(1);
    unlocks.append(74);
    try writeStable(&stable_writer, unlocks);
    try std.testing.expectEqualStrings("osu-skill-pass-1+Rising Star+Can't go forward without the first steps./all-intro-hidden+Blindsight+I can see just perfectly", stable[0..stable_writer.end]);
}
