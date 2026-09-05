const MessagePackWriter = @import("../../lazer_multiplayer.zig").MessagePackWriter;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RoomUser = @import("../../lazer_multiplayer.zig").RoomUser;
const RankedCard = @import("../../lazer_multiplayer.zig").RankedCard;
const RankedDamage = @import("../../lazer_multiplayer.zig").RankedDamage;
const RankedUser = @import("../../lazer_multiplayer.zig").RankedUser;
const RankedStageCountdown = @import("../../lazer_multiplayer.zig").RankedStageCountdown;
const MatchStartCountdownState = @import("../../lazer_multiplayer.zig").MatchStartCountdownState;
const Settings = @import("../../lazer_multiplayer.zig").Settings;
const Room = @import("../rooms/model.zig").Room;
const defaultRoomUser = @import("../rooms/state.zig").defaultRoomUser;

pub fn writeSettings(pack: MessagePackWriter, settings: Settings) !void {
    try pack.array(8);
    try pack.string(settings.name.slice());
    try pack.integer(settings.playlist_item_id);
    try pack.string(settings.password.slice());
    try pack.integer(settings.match_type);
    try pack.integer(settings.queue_mode);
    try pack.raw(settings.auto_start.slice());
    try pack.boolean(settings.auto_skip);
    if (settings.max_participants) |limit| try pack.integer(limit) else try pack.nil();
}

pub fn writeUser(pack: MessagePackWriter, user: RoomUser) !void {
    try pack.array(9);
    try pack.integer(user.id);
    try pack.integer(user.state);
    try pack.raw(user.availability.slice());
    try pack.raw(user.mods.slice());
    if (user.team_id) |team_id| {
        // MatchUserState union key 0 is TeamVersusUserState.
        try pack.array(2);
        try pack.integer(0);
        try pack.array(1);
        try pack.integer(team_id);
    } else try pack.nil();
    if (user.ruleset_id) |ruleset_id| try pack.integer(ruleset_id) else try pack.nil();
    if (user.beatmap_id) |beatmap_id| try pack.integer(beatmap_id) else try pack.nil();
    try pack.boolean(user.voted_skip);
    try pack.integer(user.role);
}

pub fn writePlaylistItem(pack: MessagePackWriter, item: PlaylistItem) !void {
    try pack.array(12);
    try pack.integer(item.id);
    try pack.integer(item.owner_id);
    try pack.integer(item.beatmap_id);
    try pack.string(item.checksum.slice());
    try pack.integer(item.ruleset_id);
    try pack.raw(item.required_mods.slice());
    try pack.raw(item.allowed_mods.slice());
    try pack.boolean(item.expired);
    try pack.integer(item.order);
    try pack.raw(item.played_at.slice());
    try pack.float64(item.star_rating);
    try pack.boolean(item.freestyle);
}

pub fn writeRankedCard(pack: MessagePackWriter, card: RankedCard) !void {
    try pack.array(1);
    try pack.string(card.id.slice());
}

pub fn writeRankedDamage(pack: MessagePackWriter, damage: RankedDamage) !void {
    try pack.array(7);
    try pack.integer(damage.damage);
    try pack.integer(damage.raw_damage);
    try pack.integer(damage.old_life);
    try pack.integer(damage.new_life);
    try pack.integer(damage.direct_damage);
    try pack.float64(damage.multiplier);
    try pack.integer(damage.bonus_damage);
}

pub fn writeRankedUser(pack: MessagePackWriter, user: RankedUser) !void {
    try pack.array(7);
    try pack.integer(user.rating);
    try pack.integer(user.life);
    try pack.array(user.hand_count);
    for (user.hand) |entry| if (entry) |card| try writeRankedCard(pack, card);
    try pack.integer(user.rating_after);
    if (user.damage) |damage| try writeRankedDamage(pack, damage) else try pack.nil();
    try pack.integer(user.rounds_won);
    try pack.float64(user.damage_multiplier);
}

pub fn writeMatchState(pack: MessagePackWriter, room: *const Room) !void {
    if (room.ranked_play) |ranked| {
        try pack.array(2);
        try pack.integer(2);
        try pack.array(7);
        try pack.integer(ranked.stage);
        try pack.integer(ranked.current_round);
        try pack.float64(ranked.damage_multiplier);
        try pack.map(ranked.user_count);
        for (ranked.users) |entry| if (entry) |user| {
            try pack.integer(user.id);
            try writeRankedUser(pack, user);
        };
        if (ranked.active_user_id) |user_id| try pack.integer(user_id) else try pack.nil();
        try pack.float64(ranked.star_rating);
        if (ranked.winning_user_id) |user_id| try pack.integer(user_id) else try pack.nil();
        return;
    }
    if (room.matchmaking) |matchmaking| {
        try pack.array(2);
        try pack.integer(1);
        try pack.array(6);
        try pack.integer(matchmaking.stage);
        try pack.integer(matchmaking.current_round);
        try pack.array(matchmaking.candidate_count);
        for (matchmaking.candidate_items[0..matchmaking.candidate_count]) |item_id| try pack.integer(item_id);
        try pack.integer(matchmaking.candidate_item);
        try pack.array(1);
        try pack.map(matchmaking.user_count);
        for (matchmaking.users) |entry| if (entry) |user| {
            try pack.integer(user.id);
            try pack.array(5);
            try pack.integer(user.id);
            if (user.placement) |placement| try pack.integer(placement) else try pack.nil();
            try pack.integer(user.points);
            try pack.array(1);
            var round_count: usize = 0;
            for (user.rounds) |round| if (round != null) {
                round_count += 1;
            };
            try pack.map(round_count);
            for (user.rounds) |round_entry| if (round_entry) |round| {
                try pack.integer(round.round);
                try pack.array(6);
                try pack.integer(round.round);
                try pack.integer(round.placement);
                try pack.integer(round.total_score);
                try pack.float64(round.accuracy);
                try pack.integer(round.max_combo);
                try pack.map(0);
            };
            try pack.nil();
        };
        try pack.integer(matchmaking.gameplay_item);
        return;
    }
    try pack.array(2);
    try pack.integer(if (room.settings.match_type == 2) 0 else 3);
    try pack.array(3);
    if (room.settings.match_type == 2) {
        try pack.array(2);
        try pack.array(2);
        try pack.integer(0);
        try pack.string("Team Red");
        try pack.array(2);
        try pack.integer(1);
        try pack.string("Team Blue");
    } else try pack.nil();
    try pack.boolean(room.locked);
    if (room.settings.max_participants) |limit| {
        try pack.array(limit);
        for (room.users[0..limit]) |entry| if (entry) |user| try pack.integer(user.id) else try pack.nil();
    } else try pack.nil();
}

pub fn writeMatchStartCountdown(pack: MessagePackWriter, countdown: MatchStartCountdownState, now_ms: i64) !void {
    // MultiplayerCountdown union key 0 is MatchStartCountdown.
    try pack.array(2);
    try pack.integer(0);
    try pack.array(2);
    try pack.integer(countdown.id);
    try pack.integer(countdown.remainingTicks(now_ms));
}

pub fn writeRankedStageCountdown(pack: MessagePackWriter, countdown: RankedStageCountdown, now_ms: i64) !void {
    // MultiplayerCountdown union key 4 is RankedPlayStageCountdown. MessagePack-CSharp
    // represents TimeSpan as signed 100ns ticks.
    try pack.array(2);
    try pack.integer(4);
    try pack.array(3);
    try pack.integer(countdown.id);
    try pack.integer(countdown.remainingTicks(now_ms));
    try pack.integer(countdown.stage);
}

pub fn writeRoom(pack: MessagePackWriter, room: *const Room, now_ms: i64) !void {
    try pack.array(9);
    try pack.integer(room.id);
    try pack.integer(room.state);
    try writeSettings(pack, room.settings);
    try pack.array(room.user_count);
    for (room.users) |entry| if (entry) |user| try writeUser(pack, user);
    if (room.userIndex(room.host_id)) |host_index| {
        try writeUser(pack, room.users[host_index].?);
    } else {
        const host = try defaultRoomUser(room.host_id, room.host_name.slice(), room.host_country);
        try writeUser(pack, host);
    }
    try writeMatchState(pack, room);
    try pack.array(room.playlist_count);
    for (room.playlist) |entry| if (entry) |item| try writePlaylistItem(pack, item);
    if (room.ranked_play) |ranked| if (ranked.pick_countdown) |countdown| {
        try pack.array(1);
        try writeRankedStageCountdown(pack, countdown, now_ms);
    } else {
        try pack.array(0);
    } else if (room.match_start_countdown) |countdown| {
        try pack.array(1);
        try writeMatchStartCountdown(pack, countdown, now_ms);
    } else {
        try pack.array(0);
    }
    try pack.integer(room.channel_id);
}
