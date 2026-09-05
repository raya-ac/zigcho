const std = @import("std");
const storage = @import("runtime_storage.zig");
const beatmap_sync = @import("beatmap_sync.zig");
const multiplayer_fixed = @import("lazer_multiplayer/fixed.zig");
const multiplayer_model = @import("lazer_multiplayer/model.zig");
const room_paths = @import("lazer_multiplayer/paths.zig");
const room_scoring = @import("lazer_multiplayer/scoring.zig");
const signalr = @import("lazer_multiplayer/signalr.zig");

pub const max_rooms = 64;
pub const max_pending_archives = max_rooms * 2;

const publicCountry = @import("lazer_multiplayer/rooms/state.zig").publicCountry;
pub const Activity = enum { lobby, queue, multiplayer, playing };
pub const max_connections = 128;
pub const max_users = multiplayer_model.max_users;
pub const max_playlist = multiplayer_model.max_playlist;
pub const max_matchmaking_maps = multiplayer_model.max_matchmaking_maps;
// A playlist room may accept up to 1,000 attempts from each of its 16 users.
// Keep that whole supported contract available for the eventual archive rather
// than silently rotating older attempts out of the room history.
pub const max_room_scores = max_users * 1000;
pub const max_room_participants = 128;
pub const matchmaking_rounds = multiplayer_model.matchmaking_rounds;
pub const ranked_player_count = multiplayer_model.ranked_player_count;
pub const ranked_hand_size = multiplayer_model.ranked_hand_size;
pub const max_ranked_cards = multiplayer_model.max_ranked_cards;
pub const ranked_pick_seconds: i64 = 30;
pub const pending_match_timeout_seconds: i64 = 30;
pub const multiplayer_score_grace_seconds: i64 = 5 * 60;
pub const timespan_ticks_per_millisecond = multiplayer_model.timespan_ticks_per_millisecond;
pub const timespan_ticks_per_second: i64 = std.time.ms_per_s * timespan_ticks_per_millisecond;

pub const matchmaking_stage = multiplayer_model.matchmaking_stage;
pub const ranked_stage = multiplayer_model.ranked_stage;

pub const RoomScorePath = room_paths.RoomScorePath;
pub const RoomUserPath = room_paths.RoomUserPath;
pub const RoomUserScorePath = room_paths.RoomUserScorePath;
pub const RoomListMode = room_paths.RoomListMode;
pub const RoomListStatus = room_paths.RoomListStatus;
pub const RoomListKind = room_paths.RoomListKind;
pub const RoomListFilter = room_paths.RoomListFilter;

pub fn roomListFilter(requester_id: i32, mode: []const u8, status: ?[]const u8, category: []const u8) !RoomListFilter {
    return room_paths.roomListFilter(requester_id, mode, status, category);
}

const archiveIncludesUser = @import("lazer_multiplayer/archive/codec.zig").archiveIncludesUser;

const archiveIncludesUserFallible = @import("lazer_multiplayer/archive/codec.zig").archiveIncludesUserFallible;

const jsonInteger = @import("lazer_multiplayer/archive/codec.zig").jsonInteger;

const jsonFloat = @import("lazer_multiplayer/archive/codec.zig").jsonFloat;

const archivedScoreRecord = @import("lazer_multiplayer/archive/codec.zig").archivedScoreRecord;

const archivedScoreTokenRecord = @import("lazer_multiplayer/archive/codec.zig").archivedScoreTokenRecord;

const archivedScoreContext = @import("lazer_multiplayer/archive/codec.zig").archivedScoreContext;

const archivedScoreTokenBound = @import("lazer_multiplayer/archive/codec.zig").archivedScoreTokenBound;

const archivedRoomRealtime = @import("lazer_multiplayer/archive/codec.zig").archivedRoomRealtime;

const restoreArchivedPlaylist = @import("lazer_multiplayer/archive/codec.zig").restoreArchivedPlaylist;

const archivedLeaderboardHasRows = @import("lazer_multiplayer/archive/codec.zig").archivedLeaderboardHasRows;

const archivedScores = @import("lazer_multiplayer/archive/codec.zig").archivedScores;

pub fn parseRoomUserPath(path: []const u8) ?RoomUserPath {
    return room_paths.parseRoomUserPath(path);
}

pub fn parseRoomLeaderboardPath(path: []const u8) ?i64 {
    return room_paths.parseRoomLeaderboardPath(path);
}

pub fn parseRoomUserScorePath(path: []const u8) ?RoomUserScorePath {
    return room_paths.parseRoomUserScorePath(path);
}

pub const RoomScoreContext = room_scoring.RoomScoreContext;
pub const RoomScoreResult = room_scoring.RoomScoreResult;

pub const RoomScoreTokenRecord = struct {
    token_id: i64,
    user_id: i32,
    playlist_item_id: i64,
    score_id: ?i64 = null,
};

pub const RoomScoreRecord = room_scoring.RoomScoreRecord;
pub const room_score_around_limit = room_scoring.room_score_around_limit;
pub const RoomScoreRanking = room_scoring.RoomScoreRanking;

pub const RoomPersistence = enum { none, archive, checkpoint };
pub const scoreRanksBefore = room_scoring.scoreRanksBefore;
pub const sortRoomScores = room_scoring.sortRoomScores;
pub const scoreEligibleForHighScore = room_scoring.scoreEligibleForHighScore;
pub const considerHighScore = room_scoring.considerHighScore;
pub const rankingForScore = room_scoring.rankingForScore;

pub const FixedRaw = multiplayer_fixed.FixedRaw;
const Raw64 = multiplayer_fixed.Raw64;
const Raw128 = multiplayer_fixed.Raw128;
const Raw2048 = multiplayer_fixed.Raw2048;
pub const Text64 = multiplayer_fixed.Text64;
const Text128 = multiplayer_fixed.Text128;
const Text256 = multiplayer_fixed.Text256;

pub const MessagePackReader = signalr.MessagePackReader;
pub const MessagePackWriter = signalr.MessagePackWriter;
pub const frameOwned = signalr.frameOwned;
pub const allocatingFrame = signalr.allocatingFrame;
pub const completionVoidOwned = signalr.completionVoidOwned;
pub const completionErrorOwned = signalr.completionErrorOwned;
pub const beginEvent = signalr.beginEvent;
pub const endEvent = signalr.endEvent;
pub const pingOwned = signalr.pingOwned;
pub const negotiateJson = signalr.negotiateJson;
pub const validSignalRHandshake = signalr.validSignalRHandshake;
const checkedInteger = signalr.checkedInteger;
pub const checkedReaderInteger = signalr.checkedReaderInteger;
pub const checkedNullableInteger = signalr.checkedNullableInteger;
pub const completionEmptyObjectOwned = signalr.completionEmptyObjectOwned;
pub const eventNoArgsOwned = signalr.eventNoArgsOwned;
pub const eventIntegersOwned = signalr.eventIntegersOwned;
pub const eventIntegerRawOwned = signalr.eventIntegerRawOwned;
pub const eventIntegerBoolOwned = signalr.eventIntegerBoolOwned;

pub const PlaylistItem = multiplayer_model.PlaylistItem;
pub const RoomUser = multiplayer_model.RoomUser;
pub const RoomParticipant = multiplayer_model.RoomParticipant;
const MatchmakingRound = multiplayer_model.MatchmakingRound;
const MatchmakingUser = multiplayer_model.MatchmakingUser;
pub const MatchmakingState = multiplayer_model.MatchmakingState;
pub const RankedCard = multiplayer_model.RankedCard;
pub const RankedDamage = multiplayer_model.RankedDamage;
pub const RankedUser = multiplayer_model.RankedUser;
pub const RankedPlayState = multiplayer_model.RankedPlayState;
pub const RankedResultContext = multiplayer_model.RankedResultContext;
pub const RankedStageCountdown = multiplayer_model.RankedStageCountdown;
pub const MatchStartCountdownState = multiplayer_model.MatchStartCountdownState;
pub const PlaylistAdvance = multiplayer_model.PlaylistAdvance;
pub const Settings = multiplayer_model.Settings;

const Room = @import("lazer_multiplayer/rooms/model.zig").Room;

pub fn roomCategory(room: *const Room) []const u8 {
    return if (room.settings.match_type == 0) "normal" else "realtime";
}

pub const PendingMatch = multiplayer_model.PendingMatch;

pub const Connection = @import("lazer_multiplayer/transport/model.zig").Connection;

const DisconnectEffects = @import("lazer_multiplayer/transport/model.zig").DisconnectEffects;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transition_mutex: std.Io.Mutex = .init,
    lifecycle_mutex: std.Io.Mutex = .init,
    mutations_drained: std.Io.Condition = .init,
    active_mutations: usize = 0,
    terminal_shutdown: bool = false,
    archive_mutex: std.Io.Mutex = .init,
    store: ?*storage.Store = null,
    map_sync: ?*beatmap_sync.Sync = null,
    mutex: std.Io.Mutex = .init,
    rooms: [max_rooms]?*Room = [_]?*Room{null} ** max_rooms,
    pending_archives: [max_pending_archives]?*Room = [_]?*Room{null} ** max_pending_archives,
    connections: std.ArrayList(*Connection) = .empty,
    matchmaking_maps: [4][max_matchmaking_maps]?storage.Store.MatchmakingBeatmap = [_][max_matchmaking_maps]?storage.Store.MatchmakingBeatmap{[_]?storage.Store.MatchmakingBeatmap{null} ** max_matchmaking_maps} ** 4,
    matchmaking_map_counts: [4]usize = [_]usize{0} ** 4,
    pending_matches: [max_rooms]?PendingMatch = [_]?PendingMatch{null} ** max_rooms,
    next_room_id: i64 = 1,
    next_pending_match_id: u32 = 1,
    next_countdown_id: i32 = 1,
    enabled: std.atomic.Value(bool) = .init(true),
    quiescing: bool = false,
    shutting_down: bool = false,

    pub const init = @import("lazer_multiplayer/lifecycle.zig").init;

    pub const bindStore = @import("lazer_multiplayer/archive/store.zig").bindStore;

    pub const bindBeatmapSync = @import("lazer_multiplayer/lifecycle.zig").bindBeatmapSync;

    pub const isEnabled = @import("lazer_multiplayer/lifecycle.zig").isEnabled;

    pub const Mutation = @import("lazer_multiplayer/lifecycle.zig").Mutation;

    pub const beginMutation = @import("lazer_multiplayer/lifecycle.zig").beginMutation;

    pub const waitForMutationsLocked = @import("lazer_multiplayer/lifecycle.zig").waitForMutationsLocked;

    pub const mutationAllowedLocked = @import("lazer_multiplayer/lifecycle.zig").mutationAllowedLocked;

    pub const MutationGateError = @import("lazer_multiplayer/lifecycle.zig").MutationGateError;

    pub const blockedMutationErrorLocked = @import("lazer_multiplayer/lifecycle.zig").blockedMutationErrorLocked;

    pub const DrainMode = @import("lazer_multiplayer/lifecycle.zig").DrainMode;

    pub const setEnabled = @import("lazer_multiplayer/lifecycle.zig").setEnabled;

    pub const drain = @import("lazer_multiplayer/lifecycle.zig").drain;

    pub const hydratePlaylistItem = @import("lazer_multiplayer/archive/hydration.zig").hydratePlaylistItem;

    pub const hydrateRoom = @import("lazer_multiplayer/archive/hydration.zig").hydrateRoom;

    pub const hydrateArchivedPlaylistItem = @import("lazer_multiplayer/archive/hydration.zig").hydrateArchivedPlaylistItem;

    pub const userCountryVisible = @import("lazer_multiplayer/archive/hydration.zig").userCountryVisible;

    pub const applyRoomCountryVisibility = @import("lazer_multiplayer/archive/hydration.zig").applyRoomCountryVisibility;

    pub const sanitizeArchivedApiUser = @import("lazer_multiplayer/archive/hydration.zig").sanitizeArchivedApiUser;

    pub const normalizeArchivedPlaylistRulesets = @import("lazer_multiplayer/archive/hydration.zig").normalizeArchivedPlaylistRulesets;

    pub const writeHydratedArchiveJson = @import("lazer_multiplayer/archive/hydration.zig").writeHydratedArchiveJson;

    pub const writeSanitizedArchiveLeaderboardJson = @import("lazer_multiplayer/archive/hydration.zig").writeSanitizedArchiveLeaderboardJson;

    pub const refreshMatchmakingMaps = @import("lazer_multiplayer/ranked/pools.zig").refreshMatchmakingMaps;

    pub const setMatchmakingMaps = @import("lazer_multiplayer/ranked/pools.zig").setMatchmakingMaps;

    pub const deinit = @import("lazer_multiplayer/lifecycle.zig").deinit;

    pub const shutdown = @import("lazer_multiplayer/lifecycle.zig").shutdown;

    pub const nowMs = @import("lazer_multiplayer/lifecycle.zig").nowMs;

    pub const startRankedPickCountdownLocked = @import("lazer_multiplayer/ranked/results.zig").startRankedPickCountdownLocked;

    pub const rankedResultContext = @import("lazer_multiplayer/ranked/results.zig").rankedResultContext;

    pub const applyRankedResult = @import("lazer_multiplayer/ranked/results.zig").applyRankedResult;

    pub const persistRankedResult = @import("lazer_multiplayer/ranked/results.zig").persistRankedResult;

    pub const persistLiveRankedResult = @import("lazer_multiplayer/ranked/results.zig").persistLiveRankedResult;

    pub const rankedStateEventForRoom = @import("lazer_multiplayer/ranked/results.zig").rankedStateEventForRoom;

    pub const saveRoomSnapshot = @import("lazer_multiplayer/archive/store.zig").saveRoomSnapshot;

    pub const queuePendingArchive = @import("lazer_multiplayer/archive/store.zig").queuePendingArchive;

    pub const removePendingArchive = @import("lazer_multiplayer/archive/store.zig").removePendingArchive;

    pub const discardRoom = @import("lazer_multiplayer/archive/store.zig").discardRoom;

    pub const archiveRoomUnderGate = @import("lazer_multiplayer/archive/store.zig").archiveRoomUnderGate;

    pub const archiveRoom = @import("lazer_multiplayer/archive/store.zig").archiveRoom;

    pub const checkpointPlaylistRoom = @import("lazer_multiplayer/archive/store.zig").checkpointPlaylistRoom;

    pub const roomByIdLocked = @import("lazer_multiplayer/rooms/queries.zig").roomByIdLocked;

    pub const archivedRoomForParticipant = @import("lazer_multiplayer/rooms/queries.zig").archivedRoomForParticipant;

    pub const roomSlotLocked = @import("lazer_multiplayer/rooms/lifecycle.zig").roomSlotLocked;

    pub const connectionByUserLocked = @import("lazer_multiplayer/transport/connections.zig").connectionByUserLocked;

    pub const activity = @import("lazer_multiplayer/rooms/queries.zig").activity;

    pub const currentRoomId = @import("lazer_multiplayer/rooms/queries.zig").currentRoomId;

    pub const RuntimeCounts = struct {
        connections: usize,
        rooms: usize,
        queued: usize,
        pending_matches: usize,
    };

    pub const runtimeCounts = @import("lazer_multiplayer/rooms/queries.zig").runtimeCounts;

    pub const roomChannelAccess = @import("lazer_multiplayer/rooms/queries.zig").roomChannelAccess;

    pub const roomChannelUsersJson = @import("lazer_multiplayer/rooms/queries.zig").roomChannelUsersJson;

    pub const archiveExpiredRooms = @import("lazer_multiplayer/archive/store.zig").archiveExpiredRooms;

    pub const expirePendingMatches = @import("lazer_multiplayer/ranked/queue.zig").expirePendingMatches;

    pub const disconnectUser = @import("lazer_multiplayer/transport/connections.zig").disconnectUser;

    pub const setUserCountryVisibility = @import("lazer_multiplayer/rooms/queries.zig").setUserCountryVisibility;

    pub const restCreateRoom = @import("lazer_multiplayer/rooms/rest.zig").restCreateRoom;

    pub const restJoinRoom = @import("lazer_multiplayer/rooms/rest.zig").restJoinRoom;

    pub const restPartRoom = @import("lazer_multiplayer/rooms/rest.zig").restPartRoom;

    pub const restCloseRoom = @import("lazer_multiplayer/rooms/rest.zig").restCloseRoom;

    pub const pendingMatchByIdLocked = @import("lazer_multiplayer/ranked/queue.zig").pendingMatchByIdLocked;

    pub const pendingMatchSlotLocked = @import("lazer_multiplayer/ranked/queue.zig").pendingMatchSlotLocked;

    pub const pendingDuelByIdLocked = @import("lazer_multiplayer/ranked/queue.zig").pendingDuelByIdLocked;

    pub const clearPendingMatchLocked = @import("lazer_multiplayer/ranked/queue.zig").clearPendingMatchLocked;

    pub const poolMode = @import("lazer_multiplayer/ranked/queue.zig").poolMode;

    pub const poolType = @import("lazer_multiplayer/ranked/queue.zig").poolType;

    pub const recipientsLocked = @import("lazer_multiplayer/transport/connections.zig").recipientsLocked;

    pub const sendRecipients = @import("lazer_multiplayer/transport/connections.zig").sendRecipients;

    pub const releaseRecipients = @import("lazer_multiplayer/transport/connections.zig").releaseRecipients;

    pub const connect = @import("lazer_multiplayer/transport/connections.zig").connect;

    pub const removeConnectionLocked = @import("lazer_multiplayer/transport/connections.zig").removeConnectionLocked;

    pub const leaveLocked = @import("lazer_multiplayer/transport/connections.zig").leaveLocked;

    pub const detachConnectionLocked = @import("lazer_multiplayer/transport/connections.zig").detachConnectionLocked;

    pub const detachConnectionForDrainLocked = @import("lazer_multiplayer/transport/connections.zig").detachConnectionForDrainLocked;

    pub const finishDisconnect = @import("lazer_multiplayer/transport/connections.zig").finishDisconnect;

    pub const disconnect = @import("lazer_multiplayer/transport/connections.zig").disconnect;

    pub const roomsJson = @import("lazer_multiplayer/rooms/queries.zig").roomsJson;

    pub const scoreContext = @import("lazer_multiplayer/scores/queries.zig").scoreContext;

    pub const scoreTokenContext = @import("lazer_multiplayer/scores/queries.zig").scoreTokenContext;

    pub const bindRoomScoreToken = @import("lazer_multiplayer/scores/queries.zig").bindRoomScoreToken;

    pub const scoreSubmissionContext = @import("lazer_multiplayer/scores/queries.zig").scoreSubmissionContext;

    pub const roomScoreIds = @import("lazer_multiplayer/scores/queries.zig").roomScoreIds;

    pub const roomScoreIdForUser = @import("lazer_multiplayer/scores/queries.zig").roomScoreIdForUser;

    pub const roomScoreRanking = @import("lazer_multiplayer/scores/queries.zig").roomScoreRanking;

    pub const roomContainsScore = @import("lazer_multiplayer/scores/queries.zig").roomContainsScore;

    pub const roomLeaderboardJson = @import("lazer_multiplayer/scores/queries.zig").roomLeaderboardJson;

    pub const serve = @import("lazer_multiplayer/transport/dispatch.zig").serve;

    pub const handleFrames = @import("lazer_multiplayer/transport/dispatch.zig").handleFrames;

    pub const handleHubMessage = @import("lazer_multiplayer/transport/dispatch.zig").handleHubMessage;

    pub const finishVoid = @import("lazer_multiplayer/transport/dispatch.zig").finishVoid;

    pub const handleInvocation = @import("lazer_multiplayer/transport/dispatch.zig").handleInvocation;

    pub const createRoom = @import("lazer_multiplayer/rooms/lifecycle.zig").createRoom;

    pub const joinRoom = @import("lazer_multiplayer/rooms/lifecycle.zig").joinRoom;

    pub const leaveRoom = @import("lazer_multiplayer/rooms/lifecycle.zig").leaveRoom;

    pub const transferHost = @import("lazer_multiplayer/rooms/lifecycle.zig").transferHost;

    pub const kickUser = @import("lazer_multiplayer/rooms/lifecycle.zig").kickUser;

    pub const changeSettings = @import("lazer_multiplayer/rooms/settings.zig").changeSettings;

    pub const changeState = @import("lazer_multiplayer/rooms/gameplay.zig").changeState;

    pub const changeAvailability = @import("lazer_multiplayer/rooms/settings.zig").changeAvailability;

    pub const changeStyle = @import("lazer_multiplayer/rooms/settings.zig").changeStyle;

    pub const changeMods = @import("lazer_multiplayer/rooms/settings.zig").changeMods;

    pub const sendMatchRequest = @import("lazer_multiplayer/rooms/settings.zig").sendMatchRequest;

    pub const changeTeam = @import("lazer_multiplayer/rooms/settings.zig").changeTeam;

    pub const startMatchCountdown = @import("lazer_multiplayer/rooms/settings.zig").startMatchCountdown;

    pub const stopMatchCountdown = @import("lazer_multiplayer/rooms/settings.zig").stopMatchCountdown;

    pub const setRoomLock = @import("lazer_multiplayer/rooms/settings.zig").setRoomLock;

    pub const changeSlot = @import("lazer_multiplayer/rooms/settings.zig").changeSlot;

    pub const roll = @import("lazer_multiplayer/rooms/events.zig").roll;

    pub const matchmakingAvatarAction = @import("lazer_multiplayer/rooms/events.zig").matchmakingAvatarAction;

    pub const rankedHandReplay = @import("lazer_multiplayer/ranked/cards.zig").rankedHandReplay;

    pub const startMatch = @import("lazer_multiplayer/rooms/gameplay.zig").startMatch;

    pub const abortMatch = @import("lazer_multiplayer/rooms/gameplay.zig").abortMatch;

    pub const abortGameplay = @import("lazer_multiplayer/rooms/gameplay.zig").abortGameplay;

    pub const addPlaylistItem = @import("lazer_multiplayer/rooms/playlist.zig").addPlaylistItem;

    pub const editPlaylistItem = @import("lazer_multiplayer/rooms/playlist.zig").editPlaylistItem;

    pub const removePlaylistItem = @import("lazer_multiplayer/rooms/playlist.zig").removePlaylistItem;

    pub const voteSkip = @import("lazer_multiplayer/rooms/playlist.zig").voteSkip;

    pub const invitePlayer = @import("lazer_multiplayer/rooms/lifecycle.zig").invitePlayer;

    pub const getMatchmakingPools = @import("lazer_multiplayer/ranked/pools.zig").getMatchmakingPools;

    pub const joinMatchmakingLobby = @import("lazer_multiplayer/ranked/pools.zig").joinMatchmakingLobby;

    pub const leaveMatchmakingLobby = @import("lazer_multiplayer/ranked/pools.zig").leaveMatchmakingLobby;

    pub const publishLobbyStatus = @import("lazer_multiplayer/ranked/pools.zig").publishLobbyStatus;

    pub const issueMatchmakingDuel = @import("lazer_multiplayer/ranked/duels.zig").issueMatchmakingDuel;

    pub const acceptMatchmakingDuel = @import("lazer_multiplayer/ranked/duels.zig").acceptMatchmakingDuel;

    pub const joinMatchmakingQueue = @import("lazer_multiplayer/ranked/queue.zig").joinMatchmakingQueue;

    pub const leaveMatchmakingQueue = @import("lazer_multiplayer/ranked/queue.zig").leaveMatchmakingQueue;

    pub const declineMatchmakingInvitation = @import("lazer_multiplayer/ranked/queue.zig").declineMatchmakingInvitation;

    pub const createMatchmakingRoomLocked = @import("lazer_multiplayer/ranked/queue.zig").createMatchmakingRoomLocked;

    pub const acceptMatchmakingInvitation = @import("lazer_multiplayer/ranked/queue.zig").acceptMatchmakingInvitation;

    pub const toggleMatchmakingSelection = @import("lazer_multiplayer/ranked/cards.zig").toggleMatchmakingSelection;

    pub const discardRankedCards = @import("lazer_multiplayer/ranked/cards.zig").discardRankedCards;

    pub const playRankedCard = @import("lazer_multiplayer/ranked/cards.zig").playRankedCard;

    pub const advanceExpiredMatchCountdowns = @import("lazer_multiplayer/ranked/timers.zig").advanceExpiredMatchCountdowns;

    pub const advanceExpiredRankedPicks = @import("lazer_multiplayer/ranked/timers.zig").advanceExpiredRankedPicks;

    pub const recordArchivedRoomScore = @import("lazer_multiplayer/archive/scores.zig").recordArchivedRoomScore;

    pub const recordRoomScore = @import("lazer_multiplayer/scores/submission.zig").recordRoomScore;
};

const defaultRoomUser = @import("lazer_multiplayer/rooms/state.zig").defaultRoomUser;

pub const beatmap_availability_unknown: u8 = 0;
pub const beatmap_availability_locally_available: u8 = 4;

const beatmapAvailabilityState = @import("lazer_multiplayer/rooms/state.zig").beatmapAvailabilityState;

const resetRoomBeatmapAvailability = @import("lazer_multiplayer/rooms/state.zig").resetRoomBeatmapAvailability;

const roomBeatmapsLocallyAvailable = @import("lazer_multiplayer/rooms/state.zig").roomBeatmapsLocallyAvailable;

const nextTeamId = @import("lazer_multiplayer/rooms/state.zig").nextTeamId;

const nextPlaylistOrder = @import("lazer_multiplayer/rooms/state.zig").nextPlaylistOrder;

const advanceRoomPlaylist = @import("lazer_multiplayer/rooms/state.zig").advanceRoomPlaylist;

const jsonString = @import("lazer_multiplayer/wire/rest.zig").jsonString;

const jsonOptionalString = @import("lazer_multiplayer/wire/rest.zig").jsonOptionalString;

const beatmapStatusValue = @import("lazer_multiplayer/wire/rest.zig").beatmapStatusValue;

const jsonOptionalInteger = @import("lazer_multiplayer/wire/rest.zig").jsonOptionalInteger;

const jsonOptionalBool = @import("lazer_multiplayer/wire/rest.zig").jsonOptionalBool;

const jsonNumber = @import("lazer_multiplayer/wire/rest.zig").jsonNumber;

const jsonValueMessagePack = @import("lazer_multiplayer/wire/rest.zig").jsonValueMessagePack;

const setJsonMessagePack = @import("lazer_multiplayer/wire/rest.zig").setJsonMessagePack;

const roomUserFromJson = @import("lazer_multiplayer/wire/rest.zig").roomUserFromJson;

const restoreRoomCheckpoint = @import("lazer_multiplayer/wire/rest.zig").restoreRoomCheckpoint;

const parseRestRoom = @import("lazer_multiplayer/wire/rest.zig").parseRestRoom;

const rankedDrawCard = @import("lazer_multiplayer/ranked/state.zig").rankedDrawCard;

const rankedRemoveCard = @import("lazer_multiplayer/ranked/state.zig").rankedRemoveCard;

const parseRankedCardId = @import("lazer_multiplayer/ranked/state.zig").parseRankedCardId;

const parseRankedCardList = @import("lazer_multiplayer/ranked/state.zig").parseRankedCardList;

const rankedApplyDamage = @import("lazer_multiplayer/ranked/state.zig").rankedApplyDamage;

const rankedFinishRound = @import("lazer_multiplayer/ranked/state.zig").rankedFinishRound;

const rankedHasRoundsRemaining = @import("lazer_multiplayer/ranked/state.zig").rankedHasRoundsRemaining;

const rankedWinner = @import("lazer_multiplayer/ranked/state.zig").rankedWinner;

const recomputeMatchmakingPlacements = @import("lazer_multiplayer/ranked/state.zig").recomputeMatchmakingPlacements;

const parseSettings = @import("lazer_multiplayer/wire/parse.zig").parseSettings;

const parsePlaylistItem = @import("lazer_multiplayer/wire/parse.zig").parsePlaylistItem;

const parseRoom = @import("lazer_multiplayer/wire/parse.zig").parseRoom;

const writeSettings = @import("lazer_multiplayer/wire/messagepack.zig").writeSettings;

const writeUser = @import("lazer_multiplayer/wire/messagepack.zig").writeUser;

const writePlaylistItem = @import("lazer_multiplayer/wire/messagepack.zig").writePlaylistItem;

const writeRankedCard = @import("lazer_multiplayer/wire/messagepack.zig").writeRankedCard;

const writeRankedDamage = @import("lazer_multiplayer/wire/messagepack.zig").writeRankedDamage;

const writeRankedUser = @import("lazer_multiplayer/wire/messagepack.zig").writeRankedUser;

const writeMatchState = @import("lazer_multiplayer/wire/messagepack.zig").writeMatchState;

const writeMatchStartCountdown = @import("lazer_multiplayer/wire/messagepack.zig").writeMatchStartCountdown;

const writeRankedStageCountdown = @import("lazer_multiplayer/wire/messagepack.zig").writeRankedStageCountdown;

const writeRoom = @import("lazer_multiplayer/wire/messagepack.zig").writeRoom;

const writeApiUserJson = @import("lazer_multiplayer/wire/json.zig").writeApiUserJson;

const beatmapStatusName = @import("lazer_multiplayer/wire/json.zig").beatmapStatusName;

const matchmakingStageName = @import("lazer_multiplayer/wire/json.zig").matchmakingStageName;

const rankedStageName = @import("lazer_multiplayer/wire/json.zig").rankedStageName;

const writeRoomModeJson = @import("lazer_multiplayer/wire/json.zig").writeRoomModeJson;

const writeMessagePackJsonValue = @import("lazer_multiplayer/wire/json.zig").writeMessagePackJsonValue;

const writeMessagePackJson = @import("lazer_multiplayer/wire/json.zig").writeMessagePackJson;

const writePlaylistItemJson = @import("lazer_multiplayer/wire/json.zig").writePlaylistItemJson;

const writeIsoTimestamp = @import("lazer_multiplayer/wire/json.zig").writeIsoTimestamp;

const autoStartSeconds = @import("lazer_multiplayer/wire/json.zig").autoStartSeconds;

const roomHasEnded = @import("lazer_multiplayer/wire/json.zig").roomHasEnded;

const writeCurrentUserScore = @import("lazer_multiplayer/wire/json.zig").writeCurrentUserScore;

const writeRoomJson = @import("lazer_multiplayer/wire/json.zig").writeRoomJson;

const writeRoomLeaderboardJson = @import("lazer_multiplayer/wire/json.zig").writeRoomLeaderboardJson;

const writeRoomScorePage = @import("lazer_multiplayer/scores/serialization.zig").writeRoomScorePage;

pub const writeRoomScoreDetailJson = @import("lazer_multiplayer/scores/serialization.zig").writeRoomScoreDetailJson;

const completionRoomOwned = @import("lazer_multiplayer/transport/events.zig").completionRoomOwned;

const completionMatchmakingPoolsOwned = @import("lazer_multiplayer/transport/events.zig").completionMatchmakingPoolsOwned;

const eventQueueStatusOwned = @import("lazer_multiplayer/transport/events.zig").eventQueueStatusOwned;

const eventMatchmakingInvitationOwned = @import("lazer_multiplayer/transport/events.zig").eventMatchmakingInvitationOwned;

const eventMatchmakingDuelIssuedOwned = @import("lazer_multiplayer/transport/events.zig").eventMatchmakingDuelIssuedOwned;

const eventMatchmakingRoomReadyOwned = @import("lazer_multiplayer/transport/events.zig").eventMatchmakingRoomReadyOwned;

const eventLobbyStatusOwned = @import("lazer_multiplayer/transport/events.zig").eventLobbyStatusOwned;

const eventMatchStateOwned = @import("lazer_multiplayer/transport/events.zig").eventMatchStateOwned;

const eventRankedCountdownStartedOwned = @import("lazer_multiplayer/transport/events.zig").eventRankedCountdownStartedOwned;

const eventMatchStartCountdownOwned = @import("lazer_multiplayer/transport/events.zig").eventMatchStartCountdownOwned;

const eventRankedCountdownStoppedOwned = @import("lazer_multiplayer/transport/events.zig").eventRankedCountdownStoppedOwned;

const eventMatchRoomStateOwned = @import("lazer_multiplayer/transport/events.zig").eventMatchRoomStateOwned;

const eventTeamStateOwned = @import("lazer_multiplayer/transport/events.zig").eventTeamStateOwned;

const eventRollOwned = @import("lazer_multiplayer/transport/events.zig").eventRollOwned;

const eventMatchmakingAvatarActionOwned = @import("lazer_multiplayer/transport/events.zig").eventMatchmakingAvatarActionOwned;

const eventRankedHandReplayOwned = @import("lazer_multiplayer/transport/events.zig").eventRankedHandReplayOwned;

const eventUserOwned = @import("lazer_multiplayer/transport/events.zig").eventUserOwned;

const eventSettingsOwned = @import("lazer_multiplayer/transport/events.zig").eventSettingsOwned;

const eventPlaylistOwned = @import("lazer_multiplayer/transport/events.zig").eventPlaylistOwned;

const eventRankedCardUserOwned = @import("lazer_multiplayer/transport/events.zig").eventRankedCardUserOwned;

const eventRankedCardRevealedOwned = @import("lazer_multiplayer/transport/events.zig").eventRankedCardRevealedOwned;

const eventRankedCardPlayedOwned = @import("lazer_multiplayer/transport/events.zig").eventRankedCardPlayedOwned;

const eventStyleOwned = @import("lazer_multiplayer/transport/events.zig").eventStyleOwned;

const eventInviteOwned = @import("lazer_multiplayer/transport/events.zig").eventInviteOwned;

pub fn parseRoomPath(path: []const u8) ?i64 {
    return room_paths.parseRoomPath(path);
}

pub fn parseRoomScorePath(path: []const u8) ?RoomScorePath {
    return room_paths.parseRoomScorePath(path);
}

const HostileInvocationHarness = @import("lazer_multiplayer/transport/tests.zig").HostileInvocationHarness;

const restRoomAllocationRun = @import("lazer_multiplayer/rooms/tests.zig").restRoomAllocationRun;

const roomArchiveListAllocationRun = @import("lazer_multiplayer/archive/tests.zig").roomArchiveListAllocationRun;

const ArchivedScoreAllocationContext = @import("lazer_multiplayer/archive/tests.zig").ArchivedScoreAllocationContext;

const archivedScoreAllocationRun = @import("lazer_multiplayer/archive/tests.zig").archivedScoreAllocationRun;

test {
    _ = @import("lazer_multiplayer/wire/tests.zig");
    _ = @import("lazer_multiplayer/lifecycle_tests.zig");
    _ = @import("lazer_multiplayer/transport/tests.zig");
    _ = @import("lazer_multiplayer/rooms/tests.zig");
    _ = @import("lazer_multiplayer/archive/tests.zig");
    _ = @import("lazer_multiplayer/ranked/tests.zig");
}
