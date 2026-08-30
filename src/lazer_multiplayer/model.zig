const std = @import("std");
const fixed = @import("fixed.zig");

pub const max_users = 16;
pub const max_playlist = 32;
pub const max_matchmaking_maps = 16;
pub const matchmaking_rounds = 3;
pub const ranked_player_count = 2;
pub const ranked_hand_size = 5;
pub const max_ranked_cards = max_playlist * ranked_player_count;
pub const timespan_ticks_per_millisecond: i64 = 10_000;

pub const matchmaking_stage = struct {
    pub const waiting_for_clients_join: u8 = 0;
    pub const round_warmup: u8 = 1;
    pub const user_beatmap_select: u8 = 2;
    pub const server_beatmap_finalised: u8 = 3;
    pub const waiting_for_beatmap_download: u8 = 4;
    pub const gameplay_warmup: u8 = 5;
    pub const gameplay: u8 = 6;
    pub const results: u8 = 7;
    pub const ended: u8 = 8;
};

pub const ranked_stage = struct {
    pub const wait_for_join: u8 = 0;
    pub const round_warmup: u8 = 1;
    pub const card_discard: u8 = 2;
    pub const finish_card_discard: u8 = 3;
    pub const card_play: u8 = 4;
    pub const finish_card_play: u8 = 5;
    pub const gameplay_warmup: u8 = 6;
    pub const gameplay: u8 = 7;
    pub const results: u8 = 8;
    pub const ended: u8 = 9;
};

pub const PlaylistItem = struct {
    id: i64 = 0,
    owner_id: i32 = 0,
    beatmap_id: i32 = 0,
    beatmapset_id: i32 = 0,
    checksum: fixed.Text64 = .{},
    ruleset_id: u8 = 0,
    artist: fixed.Text256 = .{},
    title: fixed.Text256 = .{},
    version: fixed.Text128 = .{},
    creator: fixed.Text128 = .{},
    status: i8 = 3,
    required_mods: fixed.Raw2048 = .{},
    allowed_mods: fixed.Raw2048 = .{},
    expired: bool = false,
    order: u16 = 0,
    played_at: fixed.Raw64 = .{},
    star_rating: f64 = 0,
    total_length: i32 = 0,
    hit_length: i32 = 0,
    freestyle: bool = false,
};

pub const RoomUser = struct {
    id: i32,
    name: fixed.Text64 = .{},
    country: [2]u8 = .{ 'X', 'X' },
    state: u8 = 0,
    availability: fixed.Raw128 = .{},
    mods: fixed.Raw2048 = .{},
    ruleset_id: ?i32 = null,
    beatmap_id: ?i32 = null,
    voted_skip: bool = false,
    role: u8 = 0,
    team_id: ?i32 = null,
};

pub const RoomParticipant = struct {
    id: i32,
    name: fixed.Text64 = .{},
    country: [2]u8 = .{ 'X', 'X' },
};

pub const MatchmakingRound = struct {
    round: u8,
    placement: u8 = 0,
    total_score: i64 = 0,
    accuracy: f64 = 0,
    max_combo: i32 = 0,
    passed: bool = false,
};

pub const MatchmakingUser = struct {
    id: i32,
    placement: ?u8 = null,
    points: i32 = 0,
    rounds: [matchmaking_rounds]?MatchmakingRound = [_]?MatchmakingRound{null} ** matchmaking_rounds,
};

pub const MatchmakingState = struct {
    stage: u8 = 0,
    current_round: u8 = 0,
    candidate_items: [max_users]i64 = [_]i64{0} ** max_users,
    candidate_count: usize = 0,
    candidate_item: i64 = 0,
    gameplay_item: i64 = 0,
    users: [max_users]?MatchmakingUser = [_]?MatchmakingUser{null} ** max_users,
    user_count: usize = 0,
    picks: [max_users]?i64 = [_]?i64{null} ** max_users,

    pub fn userIndex(self: *const MatchmakingState, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }
};

pub const RankedCard = struct {
    id: fixed.Text64 = .{},
    playlist_item_id: i64,
};

pub const RankedDamage = struct {
    damage: i32 = 0,
    raw_damage: i32 = 0,
    old_life: i32 = 1_000_000,
    new_life: i32 = 1_000_000,
    direct_damage: i32 = 0,
    multiplier: f64 = 1,
    bonus_damage: i32 = 0,
};

pub const RankedUser = struct {
    id: i32,
    rating: i32 = 1500,
    life: i32 = 1_000_000,
    hand: [ranked_hand_size]?RankedCard = [_]?RankedCard{null} ** ranked_hand_size,
    hand_count: usize = 0,
    rating_after: i32 = 1500,
    damage: ?RankedDamage = null,
    rounds_won: i32 = 0,
    damage_multiplier: f64 = 0.5,
    total_score: i64 = 0,
    submitted: bool = false,
    discarded: bool = false,

    pub fn cardIndex(self: *const RankedUser, card_id: []const u8) ?usize {
        for (self.hand, 0..) |entry, index| if (entry) |card| if (std.mem.eql(u8, card.id.slice(), card_id)) return index;
        return null;
    }
};

pub const RankedPlayState = struct {
    stage: u8 = ranked_stage.wait_for_join,
    current_round: u16 = 0,
    damage_multiplier: f64 = 0.5,
    users: [ranked_player_count]?RankedUser = [_]?RankedUser{null} ** ranked_player_count,
    user_count: usize = 0,
    active_user_id: ?i32 = null,
    star_rating: f64 = 0,
    winning_user_id: ?i32 = null,
    deck: [max_ranked_cards]?RankedCard = [_]?RankedCard{null} ** max_ranked_cards,
    deck_count: usize = 0,
    deck_cursor: usize = 0,
    played_card: ?RankedCard = null,
    gameplay_item: i64 = 0,
    round_winner_id: ?i32 = null,
    pick_countdown: ?RankedStageCountdown = null,
    result_persisted: bool = false,

    pub fn userIndex(self: *const RankedPlayState, user_id: i32) ?usize {
        for (self.users, 0..) |entry, index| if (entry) |user| if (user.id == user_id) return index;
        return null;
    }
};

pub const RankedResultContext = struct {
    room_id: i64,
    ruleset_id: u8,
    winner_id: i32,
    loser_id: i32,
};

pub const RankedStageCountdown = struct {
    id: i32,
    deadline_ms: i64,
    stage: u8,

    pub fn remainingTicks(self: RankedStageCountdown, now_ms: i64) i64 {
        return @max(0, self.deadline_ms - now_ms) * timespan_ticks_per_millisecond;
    }
};

pub const MatchStartCountdownState = struct {
    id: i32,
    deadline_ms: i64,

    pub fn remainingTicks(self: MatchStartCountdownState, now_ms: i64) i64 {
        return @max(0, self.deadline_ms - now_ms) * timespan_ticks_per_millisecond;
    }
};

pub const PlaylistAdvance = struct {
    expired: ?PlaylistItem = null,
    next_item_id: ?i64 = null,
};

pub const Settings = struct {
    name: fixed.Text128 = .{},
    playlist_item_id: i64 = 0,
    password: fixed.Text64 = .{},
    match_type: u8 = 1,
    queue_mode: u8 = 0,
    auto_start: fixed.Raw64 = .{},
    auto_skip: bool = false,
    max_participants: ?u8 = null,
};

pub const PendingMatch = struct {
    id: u32,
    pool_id: i32,
    users: [2]i32,
    joined: [2]bool = .{ true, true },
    accepted: [2]bool = .{ false, false },
    is_duel: bool = false,
    duel_id: fixed.Text64 = .{},
    created_at: i64,

    pub fn userIndex(self: PendingMatch, user_id: i32) ?usize {
        if (self.users[0] == user_id) return 0;
        if (self.users[1] == user_id) return 1;
        return null;
    }
};
