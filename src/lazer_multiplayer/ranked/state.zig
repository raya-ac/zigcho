const std = @import("std");
const matchmaking_rounds = @import("../model.zig").matchmaking_rounds;
const max_users = @import("../../lazer_multiplayer.zig").max_users;
const ranked_hand_size = @import("../../lazer_multiplayer.zig").ranked_hand_size;
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const MatchmakingState = @import("../../lazer_multiplayer.zig").MatchmakingState;
const RankedCard = @import("../../lazer_multiplayer.zig").RankedCard;
const RankedDamage = @import("../../lazer_multiplayer.zig").RankedDamage;
const RankedUser = @import("../../lazer_multiplayer.zig").RankedUser;
const RankedPlayState = @import("../../lazer_multiplayer.zig").RankedPlayState;

pub fn rankedDrawCard(state: *RankedPlayState, user_index: usize) ?RankedCard {
    if (user_index >= state.users.len or state.deck_cursor >= state.deck_count) return null;
    const user = &(state.users[user_index] orelse return null);
    const hand_slot = for (user.hand, 0..) |entry, index| if (entry == null) break index else {} else return null;
    const card = state.deck[state.deck_cursor] orelse return null;
    state.deck_cursor += 1;
    user.hand[hand_slot] = card;
    user.hand_count += 1;
    return card;
}

pub fn rankedRemoveCard(user: *RankedUser, card_id: []const u8) ?RankedCard {
    const index = user.cardIndex(card_id) orelse return null;
    const card = user.hand[index].?;
    user.hand[index] = null;
    user.hand_count -= 1;
    return card;
}

pub fn parseRankedCardId(encoded: []const u8) ![]const u8 {
    var reader: MessagePackReader = .{ .data = encoded };
    if (try reader.arrayLen() < 1) return error.InvalidRankedPlayCard;
    const id = try reader.string();
    if (id.len != 36 or id[8] != '-' or id[13] != '-' or id[18] != '-' or id[23] != '-') return error.InvalidRankedPlayCard;
    return id;
}

pub fn parseRankedCardList(encoded: []const u8, output: *[ranked_hand_size][]const u8) !usize {
    var reader: MessagePackReader = .{ .data = encoded };
    const count = try reader.arrayLen();
    if (count > output.len) return error.InvalidRankedPlayCard;
    for (0..count) |index| {
        const card = try reader.raw();
        output[index] = try parseRankedCardId(card);
        for (output[0..index]) |existing| if (std.mem.eql(u8, existing, output[index])) return error.InvalidRankedPlayCard;
    }
    return count;
}

pub fn rankedApplyDamage(user: *RankedUser, direct_damage: i64, multiplier: f64, bonus_damage: i32) RankedDamage {
    const direct: i32 = @intCast(std.math.clamp(direct_damage, 0, std.math.maxInt(i32)));
    const scaled = @ceil(@as(f64, @floatFromInt(direct)) * multiplier);
    const scaled_i64: i64 = @intFromFloat(@min(scaled, @as(f64, @floatFromInt(std.math.maxInt(i32)))));
    const total_i64 = std.math.add(i64, scaled_i64, bonus_damage) catch std.math.maxInt(i32);
    const total: i32 = @intCast(@min(total_i64, std.math.maxInt(i32)));
    const old_life = user.life;
    const minimum: i32 = if (old_life == 1_000_000) 1 else 0;
    user.life = @max(minimum, old_life -| total);
    return .{
        .damage = total,
        .raw_damage = @intCast(@min(@as(i64, direct) + bonus_damage, std.math.maxInt(i32))),
        .old_life = old_life,
        .new_life = user.life,
        .direct_damage = direct,
        .multiplier = multiplier,
        .bonus_damage = bonus_damage,
    };
}

pub fn rankedFinishRound(state: *RankedPlayState) void {
    state.round_winner_id = null;
    var winning_score: i64 = std.math.minInt(i64);
    var winner_index: ?usize = null;
    var tied = false;
    for (&state.users, 0..) |*entry, index| if (entry.*) |*user| {
        user.damage = rankedApplyDamage(user, 0, 1, 0);
        if (user.total_score > winning_score) {
            winning_score = user.total_score;
            winner_index = index;
            tied = false;
        } else if (user.total_score == winning_score) tied = true;
    };
    if (!tied) if (winner_index) |winner| {
        const winner_user = &state.users[winner].?;
        state.round_winner_id = winner_user.id;
        winner_user.rounds_won += 1;
        for (&state.users, 0..) |*entry, index| if (index != winner) if (entry.*) |*loser| {
            const difference = winning_score - loser.total_score;
            loser.damage = rankedApplyDamage(loser, difference, state.damage_multiplier + winner_user.damage_multiplier, 50_000);
        };
    };
}

pub fn rankedHasRoundsRemaining(state: *const RankedPlayState) bool {
    var alive: usize = 0;
    var cards = state.deck_count - state.deck_cursor;
    for (state.users) |entry| if (entry) |user| {
        if (user.life > 0) alive += 1;
        cards += user.hand_count;
    };
    return alive > 1 and cards > 0;
}

pub fn rankedWinner(state: *const RankedPlayState) ?i32 {
    var winner: ?i32 = null;
    var max_life: i32 = std.math.minInt(i32);
    var tied = false;
    for (state.users) |entry| if (entry) |user| {
        if (user.life > max_life) {
            max_life = user.life;
            winner = user.id;
            tied = false;
        } else if (user.life == max_life) tied = true;
    };
    return if (tied) null else winner;
}

pub fn recomputeMatchmakingPlacements(state: *MatchmakingState) void {
    const points = [_]i32{ 15, 12, 10, 8, 6, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (&state.users) |*entry| if (entry.*) |*user| {
        user.points = 0;
        user.placement = null;
    };
    for (0..matchmaking_rounds) |round_index| {
        var order: [max_users]usize = undefined;
        var count: usize = 0;
        for (state.users, 0..) |entry, user_index| if (entry) |user| if (user.rounds[round_index] != null) {
            order[count] = user_index;
            count += 1;
        };
        for (0..count) |left| for (left + 1..count) |right| {
            const left_round = state.users[order[left]].?.rounds[round_index].?;
            const right_round = state.users[order[right]].?.rounds[round_index].?;
            if (right_round.total_score > left_round.total_score or (right_round.total_score == left_round.total_score and state.users[order[right]].?.id < state.users[order[left]].?.id)) {
                const swap = order[left];
                order[left] = order[right];
                order[right] = swap;
            }
        };
        var position: usize = 0;
        while (position < count) {
            var end = position + 1;
            const score = state.users[order[position]].?.rounds[round_index].?.total_score;
            while (end < count and state.users[order[end]].?.rounds[round_index].?.total_score == score) : (end += 1) {}
            const placement: u8 = @intCast(end);
            for (position..end) |cursor| {
                const user_index = order[cursor];
                state.users[user_index].?.rounds[round_index].?.placement = placement;
                state.users[user_index].?.points += points[end - 1];
            }
            position = end;
        }
    }
    var order: [max_users]usize = undefined;
    var count: usize = 0;
    for (state.users, 0..) |entry, index| if (entry != null) {
        order[count] = index;
        count += 1;
    };
    for (0..count) |left| for (left + 1..count) |right| {
        const a = state.users[order[left]].?;
        const b = state.users[order[right]].?;
        if (b.points > a.points or (b.points == a.points and b.id < a.id)) {
            const swap = order[left];
            order[left] = order[right];
            order[right] = swap;
        }
    };
    for (order[0..count], 0..) |user_index, placement| state.users[user_index].?.placement = @intCast(placement + 1);
}
