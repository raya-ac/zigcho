const std = @import("std");
const MessagePackWriter = @import("../../lazer_multiplayer.zig").MessagePackWriter;
const allocatingFrame = @import("../../lazer_multiplayer.zig").allocatingFrame;
const beginEvent = @import("../../lazer_multiplayer.zig").beginEvent;
const endEvent = @import("../../lazer_multiplayer.zig").endEvent;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RoomUser = @import("../../lazer_multiplayer.zig").RoomUser;
const RankedCard = @import("../../lazer_multiplayer.zig").RankedCard;
const RankedStageCountdown = @import("../../lazer_multiplayer.zig").RankedStageCountdown;
const MatchStartCountdownState = @import("../../lazer_multiplayer.zig").MatchStartCountdownState;
const Settings = @import("../../lazer_multiplayer.zig").Settings;
const Room = @import("../rooms/model.zig").Room;
const writeSettings = @import("../wire/messagepack.zig").writeSettings;
const writeUser = @import("../wire/messagepack.zig").writeUser;
const writePlaylistItem = @import("../wire/messagepack.zig").writePlaylistItem;
const writeRankedCard = @import("../wire/messagepack.zig").writeRankedCard;
const writeMatchState = @import("../wire/messagepack.zig").writeMatchState;
const writeMatchStartCountdown = @import("../wire/messagepack.zig").writeMatchStartCountdown;
const writeRankedStageCountdown = @import("../wire/messagepack.zig").writeRankedStageCountdown;
const writeRoom = @import("../wire/messagepack.zig").writeRoom;

pub fn completionRoomOwned(allocator: std.mem.Allocator, invocation_id: []const u8, room: *const Room, now_ms: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(3);
    try writeRoom(pack, room, now_ms);
    return allocatingFrame(allocator, &output);
}

pub fn completionMatchmakingPoolsOwned(allocator: std.mem.Allocator, invocation_id: []const u8, pool_type: u8, available: [4]bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try pack.array(5);
    try pack.integer(3);
    try pack.map(0);
    try pack.string(invocation_id);
    try pack.integer(3);
    var count: usize = 0;
    for (available) |enabled| if (enabled) {
        count += 1;
    };
    try pack.array(count);
    for (available, 0..) |enabled, mode| {
        if (!enabled) continue;
        try pack.array(5);
        const pool_offset: usize = if (pool_type == 1) 100 else 0;
        try pack.integer(@as(i64, @intCast(mode + 1 + pool_offset)));
        try pack.integer(@intCast(mode));
        try pack.integer(0);
        try pack.string(if (pool_type == 0) "quick play" else "ranked play");
        try pack.integer(pool_type);
    }
    return allocatingFrame(allocator, &output);
}

pub fn eventQueueStatusOwned(allocator: std.mem.Allocator, status: u8) ![]u8 {
    if (status > 2) return error.InvalidMatchmakingQueueStatus;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingQueueStatusChanged", 1);
    try pack.array(2);
    try pack.integer(status);
    try pack.array(0);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventMatchmakingInvitationOwned(allocator: std.mem.Allocator, pool_type: u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingRoomInvitedWithParams", 1);
    try pack.array(1);
    try pack.integer(pool_type);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventMatchmakingDuelIssuedOwned(
    allocator: std.mem.Allocator,
    duel_id: []const u8,
    challenger_id: i32,
    pool_id: i32,
    mode: u8,
    pool_type: u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingDuelIssued", 1);
    try pack.array(3);
    // MessagePack-CSharp's standard Guid formatter uses the canonical
    // lowercase 36-character string on the wire.
    try pack.string(duel_id);
    try pack.integer(challenger_id);
    try pack.array(5);
    try pack.integer(pool_id);
    try pack.integer(mode);
    try pack.integer(0);
    try pack.string(if (pool_type == 0) "quick play" else "ranked play");
    try pack.integer(pool_type);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventMatchmakingRoomReadyOwned(allocator: std.mem.Allocator, room_id: i64, password: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingRoomReady", 2);
    try pack.integer(room_id);
    try pack.string(password);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventLobbyStatusOwned(allocator: std.mem.Allocator, users: []const i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchmakingLobbyStatusChanged", 1);
    try pack.array(4);
    try pack.array(users.len);
    for (users) |user_id| try pack.integer(user_id);
    // Ratings are not persistent yet. A made-up single bucket gives lazer a
    // zero-width graph range and causes its queue screen to calculate NaN.
    try pack.array(0);
    try pack.nil();
    try pack.array(0);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventMatchStateOwned(allocator: std.mem.Allocator, room: *const Room) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchRoomStateChanged", 1);
    try writeMatchState(pack, room);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventRankedCountdownStartedOwned(allocator: std.mem.Allocator, countdown: RankedStageCountdown, now_ms: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 0 is CountdownStartedEvent.
    try pack.array(2);
    try pack.integer(0);
    try pack.array(1);
    try writeRankedStageCountdown(pack, countdown, now_ms);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventMatchStartCountdownOwned(allocator: std.mem.Allocator, countdown: MatchStartCountdownState, now_ms: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 0 is CountdownStartedEvent.
    try pack.array(2);
    try pack.integer(0);
    try pack.array(1);
    try writeMatchStartCountdown(pack, countdown, now_ms);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventRankedCountdownStoppedOwned(allocator: std.mem.Allocator, countdown_id: i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 1 is CountdownStoppedEvent.
    try pack.array(2);
    try pack.integer(1);
    try pack.array(1);
    try pack.integer(countdown_id);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventMatchRoomStateOwned(allocator: std.mem.Allocator, room: *const Room) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchRoomStateChanged", 1);
    try writeMatchState(pack, room);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventTeamStateOwned(allocator: std.mem.Allocator, user_id: i32, team_id: i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchUserStateChanged", 2);
    try pack.integer(user_id);
    try pack.array(2);
    try pack.integer(0);
    try pack.array(1);
    try pack.integer(team_id);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventRollOwned(allocator: std.mem.Allocator, user_id: i32, max: i64, result: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 4 is RollEvent.
    try pack.array(2);
    try pack.integer(4);
    try pack.array(3);
    try pack.integer(user_id);
    try pack.integer(max);
    try pack.integer(result);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventMatchmakingAvatarActionOwned(allocator: std.mem.Allocator, user_id: i32, action: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 2 is MatchmakingAvatarActionEvent.
    try pack.array(2);
    try pack.integer(2);
    try pack.array(2);
    try pack.integer(user_id);
    try pack.integer(action);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventRankedHandReplayOwned(allocator: std.mem.Allocator, user_id: i32, frames: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "MatchEvent", 1);
    // MatchServerEvent union key 3 is RankedPlayCardHandReplayEvent.
    try pack.array(2);
    try pack.integer(3);
    try pack.array(2);
    try pack.integer(user_id);
    try pack.raw(frames);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventUserOwned(allocator: std.mem.Allocator, target: []const u8, user: RoomUser) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writeUser(pack, user);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventSettingsOwned(allocator: std.mem.Allocator, target: []const u8, settings: Settings) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writeSettings(pack, settings);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventPlaylistOwned(allocator: std.mem.Allocator, target: []const u8, item: PlaylistItem) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 1);
    try writePlaylistItem(pack, item);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventRankedCardUserOwned(allocator: std.mem.Allocator, target: []const u8, user_id: i32, card: RankedCard) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, target, 2);
    try pack.integer(user_id);
    try writeRankedCard(pack, card);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventRankedCardRevealedOwned(allocator: std.mem.Allocator, card: RankedCard, item: PlaylistItem) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "RankedPlayCardRevealed", 2);
    try writeRankedCard(pack, card);
    try writePlaylistItem(pack, item);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventRankedCardPlayedOwned(allocator: std.mem.Allocator, card: RankedCard) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "RankedPlayCardPlayed", 1);
    try writeRankedCard(pack, card);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventStyleOwned(allocator: std.mem.Allocator, user_id: i32, beatmap_id: ?i32, ruleset_id: ?i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "UserStyleChanged", 3);
    try pack.integer(user_id);
    if (beatmap_id) |value| try pack.integer(value) else try pack.nil();
    if (ruleset_id) |value| try pack.integer(value) else try pack.nil();
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}

pub fn eventInviteOwned(allocator: std.mem.Allocator, invited_by: i32, room_id: i64, password: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const pack: MessagePackWriter = .{ .writer = &output.writer };
    try beginEvent(pack, "Invited", 3);
    try pack.integer(invited_by);
    try pack.integer(room_id);
    try pack.string(password);
    try endEvent(pack);
    return allocatingFrame(allocator, &output);
}
