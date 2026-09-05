const std = @import("std");
const domain = @import("domain.zig");
const r2 = @import("r2.zig");
pub const is_postgres = false;
pub const schema_version: u16 = 46;

pub const visible_follower_count_sql = "CASE WHEN u.restricted=0 AND u.id!=3 THEN (SELECT count(*) FROM friends relation JOIN users follower ON follower.id=relation.user_id WHERE relation.friend_id=u.id AND relation.user_id!=u.id AND follower.restricted=0) ELSE 0 END";

pub const ConsumedLazerScoreToken = @import("storage/contracts.zig").ConsumedLazerScoreToken;

pub const LazerCommentable = @import("storage/contracts.zig").LazerCommentable;

pub const LazerCommentTarget = @import("storage/contracts.zig").LazerCommentTarget;

pub const LazerCommentSort = @import("storage/contracts.zig").LazerCommentSort;
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const ReplaySource = @import("storage/contracts.zig").ReplaySource;

pub const UpstreamUserCache = @import("storage/contracts.zig").UpstreamUserCache;

pub const BeatmapSetCreator = @import("storage/contracts.zig").BeatmapSetCreator;

pub const ranked_play_default_rating = @import("storage/contracts.zig").ranked_play_default_rating;
pub const ranked_play_rating_delta = @import("storage/contracts.zig").ranked_play_rating_delta;

pub const RankedPlayRating = @import("storage/contracts.zig").RankedPlayRating;

pub const RankedPlayResult = @import("storage/contracts.zig").RankedPlayResult;

pub const validateRankedPlayResult = @import("storage/contracts.zig").validateRankedPlayResult;

pub const max_replay_object_bytes: usize = 32 * 1024 * 1024;

pub fn hasOauthScope(scopes: []const u8, wanted: []const u8) bool {
    var values = std.mem.splitScalar(u8, scopes, ' ');
    while (values.next()) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

pub fn hasGameAccessScopes(scopes: []const u8) bool {
    return hasOauthScope(scopes, "identify") and hasOauthScope(scopes, "scores:write");
}

pub fn randomOauthToken(io: std.Io) ![64]u8 {
    var raw: [32]u8 = undefined;
    try std.Io.randomSecure(io, &raw);
    var token: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&token, "{x}", .{raw}) catch unreachable;
    return token;
}

pub fn randomOauthClientId(io: std.Io) !i32 {
    var raw: [4]u8 = undefined;
    try std.Io.randomSecure(io, &raw);
    const value = std.mem.readInt(u32, &raw, .little) & std.math.maxInt(i32);
    return @intCast(if (value == 0) 1 else value);
}

pub fn customImageFromSqlite(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !Store.CustomAvatar {
    const content_type = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
    errdefer allocator.free(content_type);
    const etag_value = std.mem.span(c.sqlite3_column_text(stmt, 1));
    if (etag_value.len != 64) return error.InvalidAvatarEtag;
    var etag: [64]u8 = undefined;
    @memcpy(&etag, etag_value);
    const object_key = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
    return .{
        .allocator = allocator,
        .content_type = content_type,
        .etag = etag,
        .object_key = object_key,
        .updated_at = c.sqlite3_column_int64(stmt, 3),
        .width = @intCast(c.sqlite3_column_int64(stmt, 4)),
        .height = @intCast(c.sqlite3_column_int64(stmt, 5)),
    };
}

pub const ClientHardware = @import("storage/contracts.zig").ClientHardware;

pub const HardwareEvidence = @import("storage/contracts.zig").HardwareEvidence;

pub const AnticheatSource = @import("storage/contracts.zig").AnticheatSource;

pub const anticheat_exclusion_min_seconds = @import("storage/contracts.zig").anticheat_exclusion_min_seconds;
pub const anticheat_exclusion_max_seconds = @import("storage/contracts.zig").anticheat_exclusion_max_seconds;

pub const AnticheatExclusionScope = @import("storage/contracts.zig").AnticheatExclusionScope;

pub const validateAnticheatExclusion = @import("storage/contracts.zig").validateAnticheatExclusion;

pub const validateAnticheatExclusionRevocation = @import("storage/contracts.zig").validateAnticheatExclusionRevocation;

pub const canManageAnticheatExclusion = @import("storage/contracts.zig").canManageAnticheatExclusion;

pub const AnticheatReviewLabel = @import("storage/contracts.zig").AnticheatReviewLabel;

pub const AnticheatObservation = @import("storage/contracts.zig").AnticheatObservation;

pub const validateAnticheatObservation = @import("storage/contracts.zig").validateAnticheatObservation;

pub const Store = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    io: std.Io,
    object_store: r2.Storage = .{ .endpoint = "", .bucket = "", .access_key_id = "", .secret_access_key = "" },
    mutex: std.Io.Mutex = .init,

    pub const CustomAvatar = @import("storage/contracts.zig").CustomAvatar;

    pub const LazerChatWrite = @import("storage/contracts.zig").LazerChatWrite;

    pub const GameTokenPair = @import("storage/contracts.zig").GameTokenPair;

    pub const GameTokenRefresh = @import("storage/contracts.zig").GameTokenRefresh;

    pub const ChatCursor = @import("storage/contracts.zig").ChatCursor;

    pub const BeatmapArchiveDownload = @import("storage/contracts.zig").BeatmapArchiveDownload;

    pub const MultiplayerRoomArchive = @import("storage/contracts.zig").MultiplayerRoomArchive;
    pub const LazerRankedRating = @import("storage/contracts.zig").LazerRankedRating;
    pub const LazerRankedResult = @import("storage/contracts.zig").LazerRankedResult;

    pub const Credential = @import("storage/sqlite/accounts/authentication.zig").Credential;

    pub const open = @import("storage/sqlite/core.zig").open;
    pub const bindObjectStorage = @import("storage/sqlite/core.zig").bindObjectStorage;
    pub const close = @import("storage/sqlite/core.zig").close;
    pub const exec = @import("storage/sqlite/core.zig").exec;
    pub const migrate = @import("storage/sqlite/schema.zig").migrate;

    pub const hasLazerPerformanceColumns = @import("storage/sqlite/schema.zig").hasLazerPerformanceColumns;

    pub const hasScoreStarRatingColumns = @import("storage/sqlite/schema.zig").hasScoreStarRatingColumns;

    pub const hasLazerChatSchema = @import("storage/sqlite/schema.zig").hasLazerChatSchema;

    pub const hasLazerDirectMessageColumns = @import("storage/sqlite/schema.zig").hasLazerDirectMessageColumns;

    pub const hasDirectMessageChatLink = @import("storage/sqlite/schema.zig").hasDirectMessageChatLink;

    pub const hasSiteProfileSchema = @import("storage/sqlite/schema.zig").hasSiteProfileSchema;

    pub const hasExpandedSiteProfileSchema = @import("storage/sqlite/schema.zig").hasExpandedSiteProfileSchema;

    pub const hasAccountTeamSchema = @import("storage/sqlite/schema.zig").hasAccountTeamSchema;

    pub const hasUpstreamBeatmapSchema = @import("storage/sqlite/schema.zig").hasUpstreamBeatmapSchema;

    pub const hasAnticheatReviewSchema = @import("storage/sqlite/schema.zig").hasAnticheatReviewSchema;

    pub const hasAnticheatGameplaySchema = @import("storage/sqlite/schema.zig").hasAnticheatGameplaySchema;

    pub const hasAvatarColumn = @import("storage/sqlite/schema.zig").hasAvatarColumn;

    pub const hasBeatmapStatusFrozenColumn = @import("storage/sqlite/schema.zig").hasBeatmapStatusFrozenColumn;

    pub const hasBeatmapArchiveAccessColumn = @import("storage/sqlite/schema.zig").hasBeatmapArchiveAccessColumn;

    pub const hasBeatmapArchiveSizeColumn = @import("storage/sqlite/schema.zig").hasBeatmapArchiveSizeColumn;

    pub const hasLazerLeaderboardColumns = @import("storage/sqlite/schema.zig").hasLazerLeaderboardColumns;

    pub const hasLazerTotalScoreWithoutModsColumn = @import("storage/sqlite/schema.zig").hasLazerTotalScoreWithoutModsColumn;

    pub const hasLazerScoreSemanticMarker = @import("storage/sqlite/schema.zig").hasLazerScoreSemanticMarker;

    pub const finishExistingLazerScoreSemanticsMigration = @import("storage/sqlite/schema.zig").finishExistingLazerScoreSemanticsMigration;

    pub const backfillLazerClassicScores = @import("storage/sqlite/schema.zig").backfillLazerClassicScores;

    pub const rebuildScoreStats = @import("storage/sqlite/schema.zig").rebuildScoreStats;

    pub const register = @import("storage/sqlite/accounts/authentication.zig").register;

    pub const recordClientHardware = @import("storage/sqlite/moderation/anticheat.zig").recordClientHardware;

    pub const insertHardwareMatchAuditLocked = @import("storage/sqlite/moderation/anticheat.zig").insertHardwareMatchAuditLocked;

    pub const insertAuditLocked = @import("storage/sqlite/moderation/anticheat.zig").insertAuditLocked;

    pub const requireAnticheatExclusionAuthorityLocked = @import("storage/sqlite/moderation/anticheat.zig").requireAnticheatExclusionAuthorityLocked;

    pub const createAnticheatExclusion = @import("storage/sqlite/moderation/anticheat.zig").createAnticheatExclusion;

    pub const anticheatExclusionTarget = @import("storage/sqlite/moderation/anticheat.zig").anticheatExclusionTarget;

    pub const revokeAnticheatExclusion = @import("storage/sqlite/moderation/anticheat.zig").revokeAnticheatExclusion;

    pub const recordAnticheatObservation = @import("storage/sqlite/moderation/anticheat.zig").recordAnticheatObservation;

    pub const crossAccountReplayMatches = @import("storage/sqlite/moderation/anticheat.zig").crossAccountReplayMatches;

    pub const recordReplayFingerprint = @import("storage/sqlite/moderation/anticheat.zig").recordReplayFingerprint;

    pub const crossAccountReplayContentMatches = @import("storage/sqlite/moderation/anticheat.zig").crossAccountReplayContentMatches;

    pub const recordReplayContentFingerprint = @import("storage/sqlite/moderation/anticheat.zig").recordReplayContentFingerprint;

    pub const RegistrationConflicts = @import("storage/contracts.zig").RegistrationConflicts;

    pub const registrationConflicts = @import("storage/sqlite/accounts/authentication.zig").registrationConflicts;

    pub const avatarForUser = @import("storage/sqlite/accounts/images.zig").avatarForUser;

    pub const customAvatarForUser = @import("storage/sqlite/accounts/images.zig").customAvatarForUser;

    pub const setCustomAvatar = @import("storage/sqlite/accounts/images.zig").setCustomAvatar;

    pub const deleteCustomAvatar = @import("storage/sqlite/accounts/images.zig").deleteCustomAvatar;

    pub const customBannerForUser = @import("storage/sqlite/accounts/images.zig").customBannerForUser;

    pub const setCustomBanner = @import("storage/sqlite/accounts/images.zig").setCustomBanner;

    pub const deleteCustomBanner = @import("storage/sqlite/accounts/images.zig").deleteCustomBanner;

    pub const teamAsset = @import("storage/sqlite/accounts/images.zig").teamAsset;

    pub const setTeamAsset = @import("storage/sqlite/accounts/images.zig").setTeamAsset;

    pub const deleteTeamAsset = @import("storage/sqlite/accounts/images.zig").deleteTeamAsset;

    pub const updateSiteProfile = @import("storage/sqlite/accounts/profiles.zig").updateSiteProfile;

    pub const lazerProfileSummary = @import("storage/sqlite/accounts/profiles.zig").lazerProfileSummary;

    pub const lazerBatchUserVisibility = @import("storage/sqlite/accounts/profiles.zig").lazerBatchUserVisibility;

    pub const lazerMonthlyPlaycountsJson = @import("storage/sqlite/accounts/profiles.zig").lazerMonthlyPlaycountsJson;

    pub const lazerReplaysWatchedCountsJson = @import("storage/sqlite/accounts/profiles.zig").lazerReplaysWatchedCountsJson;

    pub const siteAccountJson = @import("storage/sqlite/accounts/profiles.zig").siteAccountJson;

    pub const updateAccountEmail = @import("storage/sqlite/accounts/authentication.zig").updateAccountEmail;

    pub const updateAccountPassword = @import("storage/sqlite/accounts/authentication.zig").updateAccountPassword;

    pub const updateAccountUsername = @import("storage/sqlite/accounts/authentication.zig").updateAccountUsername;

    pub const revokeAllTokensForUser = @import("storage/sqlite/accounts/authentication.zig").revokeAllTokensForUser;

    pub const teamsJson = @import("storage/sqlite/accounts/teams.zig").teamsJson;

    pub const teamJson = @import("storage/sqlite/accounts/teams.zig").teamJson;

    pub const createTeam = @import("storage/sqlite/accounts/teams.zig").createTeam;

    pub const updateTeam = @import("storage/sqlite/accounts/teams.zig").updateTeam;

    pub const joinOrApplyTeam = @import("storage/sqlite/accounts/teams.zig").joinOrApplyTeam;

    pub const leaveTeam = @import("storage/sqlite/accounts/teams.zig").leaveTeam;

    pub const teamMemberAction = @import("storage/sqlite/accounts/teams.zig").teamMemberAction;

    pub const disbandTeam = @import("storage/sqlite/accounts/teams.zig").disbandTeam;

    pub const teamCanManage = @import("storage/sqlite/accounts/teams.zig").teamCanManage;

    pub const authenticate = @import("storage/sqlite/accounts/authentication.zig").authenticate;

    pub const credentialForSafeName = @import("storage/sqlite/accounts/authentication.zig").credentialForSafeName;

    pub const userById = @import("storage/sqlite/accounts/authentication.zig").userById;

    pub const userByName = @import("storage/sqlite/accounts/authentication.zig").userByName;

    pub const siteNameHistoryJson = @import("storage/sqlite/accounts/profiles.zig").siteNameHistoryJson;

    pub const friendIds = @import("storage/sqlite/social/relationships.zig").friendIds;

    pub const addFriend = @import("storage/sqlite/social/relationships.zig").addFriend;

    pub const removeFriend = @import("storage/sqlite/social/relationships.zig").removeFriend;

    pub const friendsAreMutual = @import("storage/sqlite/social/relationships.zig").friendsAreMutual;

    pub const replayViewCountLocked = @import("storage/sqlite/scores/replays.zig").replayViewCountLocked;

    pub const replayViewCount = @import("storage/sqlite/scores/replays.zig").replayViewCount;

    pub const recordReplayView = @import("storage/sqlite/scores/replays.zig").recordReplayView;

    pub const blockIds = @import("storage/sqlite/social/relationships.zig").blockIds;

    pub const addBlock = @import("storage/sqlite/social/relationships.zig").addBlock;

    pub const removeBlock = @import("storage/sqlite/social/relationships.zig").removeBlock;

    pub const favouriteSetIds = @import("storage/sqlite/social/relationships.zig").favouriteSetIds;

    pub const addFavourite = @import("storage/sqlite/social/relationships.zig").addFavourite;

    pub const removeFavourite = @import("storage/sqlite/social/relationships.zig").removeFavourite;

    pub const StableBeatmapInfo = @import("storage/contracts.zig").StableBeatmapInfo;

    pub const stableGrade = @import("storage/contracts.zig").stableGrade;

    pub const stableBeatmapInfoLocked = @import("storage/sqlite/beatmaps/catalog.zig").stableBeatmapInfoLocked;

    pub const stableBeatmapInfoByFilename = @import("storage/sqlite/beatmaps/catalog.zig").stableBeatmapInfoByFilename;

    pub const stableBeatmapInfoById = @import("storage/sqlite/beatmaps/catalog.zig").stableBeatmapInfoById;

    pub const addBeatmapComment = @import("storage/sqlite/social/comments.zig").addBeatmapComment;

    pub const beatmapComments = @import("storage/sqlite/social/comments.zig").beatmapComments;

    pub const addLazerComment = @import("storage/sqlite/social/comments.zig").addLazerComment;

    pub const lazerCommentTarget = @import("storage/sqlite/social/comments.zig").lazerCommentTarget;

    pub const deleteLazerComment = @import("storage/sqlite/social/comments.zig").deleteLazerComment;

    pub const setLazerCommentVote = @import("storage/sqlite/social/comments.zig").setLazerCommentVote;

    pub const reportLazerComment = @import("storage/sqlite/social/comments.zig").reportLazerComment;

    pub const addLazerReport = @import("storage/sqlite/social/comments.zig").addLazerReport;

    pub const lazerMessageExists = @import("storage/sqlite/social/comments.zig").lazerMessageExists;

    pub const staffLazerReportsJson = @import("storage/sqlite/social/comments.zig").staffLazerReportsJson;

    pub const resolveLazerReport = @import("storage/sqlite/social/comments.zig").resolveLazerReport;

    pub const setLazerBeatmapTag = @import("storage/sqlite/social/comments.zig").setLazerBeatmapTag;

    pub const lazerBeatmapTagStateJson = @import("storage/sqlite/social/comments.zig").lazerBeatmapTagStateJson;

    pub const lazerCommentsJson = @import("storage/sqlite/social/comments.zig").lazerCommentsJson;

    pub const DirectMessage = @import("storage/contracts.zig").DirectMessage;

    pub const directMessageAllowedLocked = @import("storage/sqlite/social/messages.zig").directMessageAllowedLocked;

    pub const directMessageAllowed = @import("storage/sqlite/social/messages.zig").directMessageAllowed;

    pub const storeDirectMessage = @import("storage/sqlite/social/messages.zig").storeDirectMessage;

    pub const unreadDirectMessages = @import("storage/sqlite/social/messages.zig").unreadDirectMessages;

    pub const markDirectMessagesRead = @import("storage/sqlite/social/messages.zig").markDirectMessagesRead;

    pub const markDirectMessageRead = @import("storage/sqlite/social/messages.zig").markDirectMessageRead;

    pub const recordPublicMessage = @import("storage/sqlite/social/messages.zig").recordPublicMessage;

    pub const recordStaffAnnouncement = @import("storage/sqlite/social/messages.zig").recordStaffAnnouncement;

    pub const recordLazerPublicMessage = @import("storage/sqlite/social/chat.zig").recordLazerPublicMessage;

    pub const recordLazerRoomMessage = @import("storage/sqlite/social/chat.zig").recordLazerRoomMessage;

    pub const recordLazerDirectMessage = @import("storage/sqlite/social/chat.zig").recordLazerDirectMessage;

    pub const lazerDirectMessagesJson = @import("storage/sqlite/social/chat.zig").lazerDirectMessagesJson;

    pub const directMessageThreadsJson = @import("storage/sqlite/social/chat.zig").directMessageThreadsJson;

    pub const lazerAllMessagesJson = @import("storage/sqlite/social/chat.zig").lazerAllMessagesJson;

    pub const lazerAllMessagesForRoomJson = @import("storage/sqlite/social/chat.zig").lazerAllMessagesForRoomJson;

    pub const lazerChatMessagesJson = @import("storage/sqlite/social/chat.zig").lazerChatMessagesJson;

    pub const lazerRoomMessagesJson = @import("storage/sqlite/social/chat.zig").lazerRoomMessagesJson;

    pub const lazerRoomChannelCursor = @import("storage/sqlite/social/channels.zig").lazerRoomChannelCursor;

    pub const markLazerRoomChannelRead = @import("storage/sqlite/social/channels.zig").markLazerRoomChannelRead;

    pub const lazerChannelListJson = @import("storage/sqlite/social/channels.zig").lazerChannelListJson;

    pub const lazerChannelCursor = @import("storage/sqlite/social/channels.zig").lazerChannelCursor;

    pub const lazerDirectMessageCursor = @import("storage/sqlite/social/channels.zig").lazerDirectMessageCursor;

    pub const markLazerChannelRead = @import("storage/sqlite/social/channels.zig").markLazerChannelRead;

    pub const markLazerDirectMessageRead = @import("storage/sqlite/social/channels.zig").markLazerDirectMessageRead;

    pub const beatmapRankContext = @import("storage/sqlite/beatmaps/ranking.zig").beatmapRankContext;

    pub const requestBeatmapRank = @import("storage/sqlite/beatmaps/ranking.zig").requestBeatmapRank;

    pub const nominateBeatmapSet = @import("storage/sqlite/beatmaps/ranking.zig").nominateBeatmapSet;

    pub const applyBeatmapRankAction = @import("storage/sqlite/beatmaps/ranking.zig").applyBeatmapRankAction;

    pub const beatmapRankQueue = @import("storage/sqlite/beatmaps/ranking.zig").beatmapRankQueue;

    pub const rankContextLocked = @import("storage/sqlite/beatmaps/ranking.zig").rankContextLocked;

    pub const activeRankCountLocked = @import("storage/sqlite/beatmaps/ranking.zig").activeRankCountLocked;

    pub const clearBeatmapNominationsLocked = @import("storage/sqlite/beatmaps/ranking.zig").clearBeatmapNominationsLocked;

    pub const resolveBeatmapRequestsLocked = @import("storage/sqlite/beatmaps/ranking.zig").resolveBeatmapRequestsLocked;

    pub const insertBeatmapRankEventLocked = @import("storage/sqlite/beatmaps/ranking.zig").insertBeatmapRankEventLocked;

    pub const channelCanWrite = @import("storage/sqlite/moderation/actions.zig").channelCanWrite;

    pub const setChannelLocked = @import("storage/sqlite/moderation/actions.zig").setChannelLocked;

    pub const setSilence = @import("storage/sqlite/moderation/actions.zig").setSilence;

    pub const setRestricted = @import("storage/sqlite/moderation/actions.zig").setRestricted;

    pub const changePrivileges = @import("storage/sqlite/moderation/actions.zig").changePrivileges;

    pub const changeRole = @import("storage/sqlite/moderation/actions.zig").changeRole;

    pub const addModerationNote = @import("storage/sqlite/moderation/actions.zig").addModerationNote;

    pub const recordModerationAction = @import("storage/sqlite/moderation/actions.zig").recordModerationAction;

    pub const recordAudit = @import("storage/sqlite/moderation/actions.zig").recordAudit;

    pub const moderationNotes = @import("storage/sqlite/moderation/actions.zig").moderationNotes;

    pub const createModerationAppeal = @import("storage/sqlite/moderation/actions.zig").createModerationAppeal;

    pub const resolveModerationAppeal = @import("storage/sqlite/moderation/actions.zig").resolveModerationAppeal;

    pub const beatmapMd5ForSet = @import("storage/sqlite/moderation/actions.zig").beatmapMd5ForSet;

    pub const staffAnticheatJson = @import("storage/sqlite/moderation/anticheat.zig").staffAnticheatJson;

    pub const reviewAnticheatObservation = @import("storage/sqlite/moderation/anticheat.zig").reviewAnticheatObservation;

    pub const serverControlEnabled = @import("storage/sqlite/moderation/controls.zig").serverControlEnabled;

    pub const staffServerControlsJson = @import("storage/sqlite/moderation/controls.zig").staffServerControlsJson;

    pub const setServerControl = @import("storage/sqlite/moderation/controls.zig").setServerControl;

    pub const staffOverviewJson = @import("storage/sqlite/moderation/queries.zig").staffOverviewJson;

    pub const staffUserSearchJson = @import("storage/sqlite/moderation/queries.zig").staffUserSearchJson;

    pub const staffRolesJson = @import("storage/sqlite/moderation/queries.zig").staffRolesJson;

    pub const lazerUserSearchIds = @import("storage/sqlite/moderation/queries.zig").lazerUserSearchIds;

    pub const staffRankingJson = @import("storage/sqlite/moderation/queries.zig").staffRankingJson;

    pub const staffAppealsJson = @import("storage/sqlite/moderation/queries.zig").staffAppealsJson;

    pub const staffUserJson = @import("storage/sqlite/moderation/queries.zig").staffUserJson;

    pub const staffAuditJson = @import("storage/sqlite/moderation/queries.zig").staffAuditJson;

    pub const staffChannelsJson = @import("storage/sqlite/moderation/queries.zig").staffChannelsJson;

    pub const updateCountry = @import("storage/sqlite/accounts/profiles.zig").updateCountry;

    pub const ServerCounts = @import("storage/contracts.zig").ServerCounts;

    pub const BeatmapCacheStats = @import("storage/contracts.zig").BeatmapCacheStats;

    pub const BeatmapCachePrune = @import("storage/contracts.zig").BeatmapCachePrune;

    pub const BeatmapMediaCacheStats = @import("storage/contracts.zig").BeatmapMediaCacheStats;

    pub const ObjectMigrationStats = @import("storage/contracts.zig").ObjectMigrationStats;

    pub const ObjectPurgeStats = @import("storage/contracts.zig").ObjectPurgeStats;

    pub const serverCounts = @import("storage/sqlite/accounts/rankings.zig").serverCounts;

    pub const customAvatarUserIds = @import("storage/sqlite/accounts/rankings.zig").customAvatarUserIds;

    pub const siteRankings = @import("storage/sqlite/accounts/rankings.zig").siteRankings;

    pub const lazerRankingsJson = @import("storage/sqlite/accounts/rankings.zig").lazerRankingsJson;

    pub const prepareSiteScores = @import("storage/sqlite/scores/website.zig").prepareSiteScores;

    pub const writeSiteScores = @import("storage/sqlite/scores/website.zig").writeSiteScores;

    pub const readStatsHistoryLocked = @import("storage/sqlite/scores/history.zig").readStatsHistoryLocked;

    pub const pruneStatsHistoryLocked = @import("storage/sqlite/scores/history.zig").pruneStatsHistoryLocked;

    pub const recordStatsHistorySliceCurrentLocked = @import("storage/sqlite/scores/history.zig").recordStatsHistorySliceCurrentLocked;

    pub const statsHistoryLocked = @import("storage/sqlite/scores/history.zig").statsHistoryLocked;

    pub const statsHistory = @import("storage/sqlite/scores/history.zig").statsHistory;

    pub const recordAllStatsHistoryCurrentLocked = @import("storage/sqlite/scores/history.zig").recordAllStatsHistoryCurrentLocked;

    pub const recordBeatmapStatsHistoryCurrentLocked = @import("storage/sqlite/scores/history.zig").recordBeatmapStatsHistoryCurrentLocked;

    pub const refreshStatsHistory = @import("storage/sqlite/scores/history.zig").refreshStatsHistory;

    pub const siteProfile = @import("storage/sqlite/accounts/profiles.zig").siteProfile;

    pub const siteProfileForViewer = @import("storage/sqlite/accounts/profiles.zig").siteProfileForViewer;

    pub const siteBeatmapLeaderboard = @import("storage/sqlite/scores/website.zig").siteBeatmapLeaderboard;

    pub const replayData = @import("storage/sqlite/scores/replays.zig").replayData;

    pub const siteReplay = @import("storage/sqlite/scores/replays.zig").siteReplay;

    pub const lazerReplay = @import("storage/sqlite/scores/replays.zig").lazerReplay;

    pub const upgradePassword = @import("storage/sqlite/accounts/tokens.zig").upgradePassword;

    pub const issueToken = @import("storage/sqlite/accounts/tokens.zig").issueToken;

    pub const insertGameTokenLocked = @import("storage/sqlite/accounts/tokens.zig").insertGameTokenLocked;

    pub const issueGameTokenPair = @import("storage/sqlite/accounts/tokens.zig").issueGameTokenPair;

    pub const rotateGameTokenPair = @import("storage/sqlite/accounts/tokens.zig").rotateGameTokenPair;

    pub const authenticateToken = @import("storage/sqlite/accounts/tokens.zig").authenticateToken;

    pub const consumeGameRefreshToken = @import("storage/sqlite/accounts/tokens.zig").consumeGameRefreshToken;

    pub const recentOauthUserIds = @import("storage/sqlite/accounts/presence.zig").recentOauthUserIds;

    pub const lazerUserOnline = @import("storage/sqlite/accounts/presence.zig").lazerUserOnline;

    pub const setLazerActivityForToken = @import("storage/sqlite/accounts/presence.zig").setLazerActivityForToken;

    pub const clearLazerActivityForToken = @import("storage/sqlite/accounts/presence.zig").clearLazerActivityForToken;

    pub const lazerActivity = @import("storage/sqlite/accounts/presence.zig").lazerActivity;

    pub const statsForUser = @import("storage/sqlite/scores/statistics.zig").statsForUser;

    pub const statsRulesetsForUser = @import("storage/sqlite/scores/statistics.zig").statsRulesetsForUser;

    pub const sourceStatsForUser = @import("storage/sqlite/scores/statistics.zig").sourceStatsForUser;

    pub const revokeToken = @import("storage/sqlite/accounts/tokens.zig").revokeToken;

    pub const revokeGameTokensForUser = @import("storage/sqlite/accounts/tokens.zig").revokeGameTokensForUser;

    pub const revokeLazerAccessTokensForUser = @import("storage/sqlite/accounts/tokens.zig").revokeLazerAccessTokensForUser;

    pub const lazerUserScoreCounts = @import("storage/sqlite/scores/lazer_profiles.zig").lazerUserScoreCounts;

    pub const lazerRecentActivityJson = @import("storage/sqlite/scores/lazer_profiles.zig").lazerRecentActivityJson;

    pub const lazerUserScoresJson = @import("storage/sqlite/scores/lazer_profiles.zig").lazerUserScoresJson;

    pub const stableClassicLeaderboardJsonLocked = @import("storage/sqlite/scores/leaderboards.zig").stableClassicLeaderboardJsonLocked;

    pub const lazerLeaderboardJson = @import("storage/sqlite/scores/leaderboards.zig").lazerLeaderboardJson;

    pub const lazerScoreJson = @import("storage/sqlite/scores/lazer_profiles.zig").lazerScoreJson;

    pub const awardAchievementsLocked = @import("storage/sqlite/scores/achievements.zig").awardAchievementsLocked;

    pub const writeUserAchievementsLocked = @import("storage/sqlite/scores/achievements.zig").writeUserAchievementsLocked;

    pub const lazerUserAchievementsJson = @import("storage/sqlite/scores/achievements.zig").lazerUserAchievementsJson;

    pub const newAchievementsForScore = @import("storage/sqlite/scores/achievements.zig").newAchievementsForScore;

    pub const insertLazerScore = @import("storage/sqlite/scores/submission.zig").insertLazerScore;

    pub const insertLazerScoreLocked = @import("storage/sqlite/scores/submission.zig").insertLazerScoreLocked;

    pub const updateLazerStatsLocked = @import("storage/sqlite/scores/submission.zig").updateLazerStatsLocked;

    pub const rebuildCombinedPerformanceLocked = @import("storage/sqlite/scores/submission.zig").rebuildCombinedPerformanceLocked;

    pub const lazer_room_score_token_tag = @import("storage/contracts.zig").lazer_room_score_token_tag;
    pub const lazer_room_score_token_mask = @import("storage/contracts.zig").lazer_room_score_token_mask;
    pub const lazer_room_score_token_payload_mask = @import("storage/contracts.zig").lazer_room_score_token_payload_mask;

    pub const isLazerRoomScoreToken = @import("storage/contracts.zig").isLazerRoomScoreToken;

    pub const createLazerScoreToken = @import("storage/sqlite/scores/tokens.zig").createLazerScoreToken;

    pub const createLazerRoomScoreToken = @import("storage/sqlite/scores/tokens.zig").createLazerRoomScoreToken;

    pub const discardUnusedLazerRoomScoreToken = @import("storage/sqlite/scores/tokens.zig").discardUnusedLazerRoomScoreToken;

    pub const createLazerScoreTokenScoped = @import("storage/sqlite/scores/tokens.zig").createLazerScoreTokenScoped;

    pub const submitLazerScoreToken = @import("storage/sqlite/scores/tokens.zig").submitLazerScoreToken;

    pub const submitLazerRoomScoreToken = @import("storage/sqlite/scores/tokens.zig").submitLazerRoomScoreToken;

    pub const submitLazerScoreTokenScoped = @import("storage/sqlite/scores/tokens.zig").submitLazerScoreTokenScoped;

    pub const consumedLazerScoreToken = @import("storage/sqlite/scores/tokens.zig").consumedLazerScoreToken;

    pub const BeatmapForScore = @import("storage/contracts.zig").BeatmapForScore;

    pub const BeatmapRating = @import("storage/contracts.zig").BeatmapRating;

    pub const rateBeatmap = @import("storage/sqlite/beatmaps/catalog.zig").rateBeatmap;

    pub const recordLastFmFlag = @import("storage/sqlite/beatmaps/catalog.zig").recordLastFmFlag;

    pub const upsertBeatmap = @import("storage/sqlite/beatmaps/catalog.zig").upsertBeatmap;

    pub const upsertBeatmapMeta = @import("storage/sqlite/beatmaps/catalog.zig").upsertBeatmapMeta;

    pub const beatmapFile = @import("storage/sqlite/beatmaps/catalog.zig").beatmapFile;

    pub const beatmapHasFile = @import("storage/sqlite/beatmaps/catalog.zig").beatmapHasFile;

    pub const beatmapFileById = @import("storage/sqlite/beatmaps/catalog.zig").beatmapFileById;

    pub const BeatmapSelection = @import("storage/contracts.zig").BeatmapSelection;

    pub const MatchmakingBeatmap = @import("storage/contracts.zig").MatchmakingBeatmap;

    pub const multiplayerRoomArchiveFromStatement = @import("storage/sqlite/multiplayer/archives.zig").multiplayerRoomArchiveFromStatement;

    pub const nextLazerMultiplayerRoomId = @import("storage/sqlite/multiplayer/archives.zig").nextLazerMultiplayerRoomId;

    pub const saveLazerMultiplayerRoomArchive = @import("storage/sqlite/multiplayer/archives.zig").saveLazerMultiplayerRoomArchive;

    pub const lazerMultiplayerRoomArchive = @import("storage/sqlite/multiplayer/archives.zig").lazerMultiplayerRoomArchive;

    pub const lazerMultiplayerRoomArchives = @import("storage/sqlite/multiplayer/archives.zig").lazerMultiplayerRoomArchives;

    pub const lazerMultiplayerRoomCheckpoints = @import("storage/sqlite/multiplayer/archives.zig").lazerMultiplayerRoomCheckpoints;

    pub const deleteLazerMultiplayerRoomCheckpoint = @import("storage/sqlite/multiplayer/archives.zig").deleteLazerMultiplayerRoomCheckpoint;

    pub const updateLazerMultiplayerRoomArchive = @import("storage/sqlite/multiplayer/archives.zig").updateLazerMultiplayerRoomArchive;

    pub const lazerRankedRating = @import("storage/sqlite/multiplayer/archives.zig").lazerRankedRating;

    pub const applyLazerRankedResult = @import("storage/sqlite/multiplayer/archives.zig").applyLazerRankedResult;

    pub const matchmakingBeatmaps = @import("storage/sqlite/multiplayer/maps.zig").matchmakingBeatmaps;

    pub const beatmapSelectionById = @import("storage/sqlite/multiplayer/maps.zig").beatmapSelectionById;

    pub const setScorePinned = @import("storage/sqlite/scores/pins.zig").setScorePinned;

    pub const setScorePinnedById = @import("storage/sqlite/scores/pins.zig").setScorePinnedById;

    pub const allocateBssIdsLocked = @import("storage/sqlite/beatmaps/submissions.zig").allocateBssIdsLocked;

    pub const reserveBssSubmission = @import("storage/sqlite/beatmaps/submissions.zig").reserveBssSubmission;

    pub const bssReservedMapIds = @import("storage/sqlite/beatmaps/submissions.zig").bssReservedMapIds;

    pub const failBssSubmission = @import("storage/sqlite/beatmaps/submissions.zig").failBssSubmission;

    pub const publishBssSubmission = @import("storage/sqlite/beatmaps/submissions.zig").publishBssSubmission;

    pub const upsertBeatmapArchive = @import("storage/sqlite/beatmaps/archives.zig").upsertBeatmapArchive;

    pub const beatmapSetExists = @import("storage/sqlite/beatmaps/archives.zig").beatmapSetExists;

    pub const beatmapSetIdsMissingArchives = @import("storage/sqlite/beatmaps/archives.zig").beatmapSetIdsMissingArchives;

    pub const beatmapArchiveIdsMissingSize = @import("storage/sqlite/beatmaps/archives.zig").beatmapArchiveIdsMissingSize;

    pub const setBeatmapArchiveSize = @import("storage/sqlite/beatmaps/archives.zig").setBeatmapArchiveSize;

    pub const beatmapMirrorPendingCount = @import("storage/sqlite/beatmaps/archives.zig").beatmapMirrorPendingCount;

    pub const beatmapSetCreator = @import("storage/sqlite/beatmaps/upstream.zig").beatmapSetCreator;

    pub const upstreamUserCacheByName = @import("storage/sqlite/beatmaps/upstream.zig").upstreamUserCacheByName;

    pub const upstreamUserCacheById = @import("storage/sqlite/beatmaps/upstream.zig").upstreamUserCacheById;

    pub const upsertUpstreamUserProfile = @import("storage/sqlite/beatmaps/upstream.zig").upsertUpstreamUserProfile;

    pub const linkBeatmapSetCreator = @import("storage/sqlite/beatmaps/upstream.zig").linkBeatmapSetCreator;

    pub const upstreamUserProfileJson = @import("storage/sqlite/beatmaps/upstream.zig").upstreamUserProfileJson;

    pub const upsertBeatmapSetMetadata = @import("storage/sqlite/beatmaps/upstream.zig").upsertBeatmapSetMetadata;

    pub const updateBeatmapUpstreamStats = @import("storage/sqlite/beatmaps/upstream.zig").updateBeatmapUpstreamStats;

    pub const beatmapSetIdForMap = @import("storage/sqlite/beatmaps/catalog.zig").beatmapSetIdForMap;

    pub const beatmapSetIdForChecksum = @import("storage/sqlite/beatmaps/catalog.zig").beatmapSetIdForChecksum;

    pub const putBeatmapMedia = @import("storage/sqlite/beatmaps/media.zig").putBeatmapMedia;

    pub const beatmapMedia = @import("storage/sqlite/beatmaps/media.zig").beatmapMedia;

    pub const beatmapMediaCacheStats = @import("storage/sqlite/beatmaps/media.zig").beatmapMediaCacheStats;

    pub const pruneBeatmapMedia = @import("storage/sqlite/beatmaps/media.zig").pruneBeatmapMedia;

    pub const mediaCacheSizeLocked = @import("storage/sqlite/beatmaps/media.zig").mediaCacheSizeLocked;

    pub const beatmapArchive = @import("storage/sqlite/beatmaps/archives.zig").beatmapArchive;

    pub const beatmapArchiveDownload = @import("storage/sqlite/beatmaps/archives.zig").beatmapArchiveDownload;

    pub const streamBeatmapArchive = @import("storage/sqlite/beatmaps/archives.zig").streamBeatmapArchive;

    pub const hydrationRetryAllowed = @import("storage/sqlite/beatmaps/archives.zig").hydrationRetryAllowed;

    pub const recordHydrationFailure = @import("storage/sqlite/beatmaps/archives.zig").recordHydrationFailure;

    pub const clearHydrationFailure = @import("storage/sqlite/beatmaps/archives.zig").clearHydrationFailure;

    pub const beatmapCacheStats = @import("storage/sqlite/beatmaps/archives.zig").beatmapCacheStats;

    pub const pruneBeatmapArchives = @import("storage/sqlite/beatmaps/archives.zig").pruneBeatmapArchives;

    pub const cacheSizeLocked = @import("storage/sqlite/beatmaps/archives.zig").cacheSizeLocked;

    pub const putVerifiedObject = @import("storage/sqlite/objects.zig").putVerifiedObject;

    pub const storeReplayObject = @import("storage/sqlite/objects.zig").storeReplayObject;

    pub const migrateBeatmapObjects = @import("storage/sqlite/objects.zig").migrateBeatmapObjects;

    pub const purgeBeatmapObjectBackups = @import("storage/sqlite/objects.zig").purgeBeatmapObjectBackups;

    pub const beatmapForScore = @import("storage/sqlite/beatmaps/catalog.zig").beatmapForScore;

    pub const BeatmapInfo = @import("storage/contracts.zig").BeatmapInfo;

    pub const scoreLeaderboardPlacement = @import("storage/sqlite/scores/leaderboards.zig").scoreLeaderboardPlacement;

    pub const lazerScoreLeaderboardPlacement = @import("storage/sqlite/scores/leaderboards.zig").lazerScoreLeaderboardPlacement;

    pub const beatmapInfo = @import("storage/sqlite/beatmaps/catalog.zig").beatmapInfo;

    pub const beatmapInfoById = @import("storage/sqlite/beatmaps/catalog.zig").beatmapInfoById;

    pub const insertStableScore = @import("storage/sqlite/scores/submission.zig").insertStableScore;

    pub const stableReplay = @import("storage/sqlite/scores/replays.zig").stableReplay;

    pub const putScreenshot = @import("storage/sqlite/accounts/images.zig").putScreenshot;

    pub const screenshot = @import("storage/sqlite/accounts/images.zig").screenshot;

    pub const PpSnapshot = @import("storage/contracts.zig").PpSnapshot;

    pub const ppSnapshot = @import("storage/sqlite/scores/statistics.zig").ppSnapshot;

    pub const writeDirectText = @import("storage/sqlite/beatmaps/stable_listing.zig").writeDirectText;

    pub const directStatus = @import("storage/contracts.zig").directStatus;

    pub const stableStatus = @import("storage/contracts.zig").stableStatus;

    pub const appendDirectSet = @import("storage/sqlite/beatmaps/stable_listing.zig").appendDirectSet;

    pub const stableSearch = @import("storage/sqlite/beatmaps/stable_listing.zig").stableSearch;

    pub const stableSearchSet = @import("storage/sqlite/beatmaps/stable_listing.zig").stableSearchSet;

    pub const jsonString = @import("storage/sqlite/beatmaps/lazer_listing.zig").jsonString;

    pub const lazerStatus = @import("storage/contracts.zig").lazerStatus;

    pub const appendLazerTagFields = @import("storage/sqlite/beatmaps/lazer_listing.zig").appendLazerTagFields;

    pub const appendLazerMap = @import("storage/sqlite/beatmaps/lazer_listing.zig").appendLazerMap;

    pub const appendLazerSet = @import("storage/sqlite/beatmaps/lazer_listing.zig").appendLazerSet;

    pub const lazerBeatmapSet = @import("storage/sqlite/beatmaps/lazer_listing.zig").lazerBeatmapSet;

    pub const lazerBeatmapLookup = @import("storage/sqlite/beatmaps/lazer_listing.zig").lazerBeatmapLookup;

    pub const lazerBeatmapSearch = @import("storage/sqlite/beatmaps/lazer_listing.zig").lazerBeatmapSearch;

    pub const lazerBeatmapSets = @import("storage/sqlite/beatmaps/lazer_listing.zig").lazerBeatmapSets;

    pub const lazerOwnedBeatmapSearch = @import("storage/sqlite/beatmaps/lazer_listing.zig").lazerOwnedBeatmapSearch;

    pub const lazerUserBeatmapSetsJson = @import("storage/sqlite/beatmaps/lazer_listing.zig").lazerUserBeatmapSetsJson;

    pub const lazerMostPlayedJson = @import("storage/sqlite/accounts/profiles.zig").lazerMostPlayedJson;

    pub const stableLeaderboard = @import("storage/sqlite/scores/leaderboards.zig").stableLeaderboard;
};

pub fn bindBoard(stmt: *c.sqlite3_stmt, map_md5: []const u8, mode: u8, namespace: []const u8, board_type: u8, mods: i32, viewer: *const domain.User) void {
    _ = c.sqlite3_bind_text(stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
    _ = c.sqlite3_bind_int(stmt, 4, board_type);
    _ = c.sqlite3_bind_int(stmt, 5, mods);
    _ = c.sqlite3_bind_int(stmt, 6, viewer.id);
    _ = c.sqlite3_bind_text(stmt, 7, viewer.country[0..].ptr, 2, null);
}

pub fn writeBoardRow(w: *std.Io.Writer, stmt: *c.sqlite3_stmt, rank: i32, is_pp: bool) !void {
    const score_val: i64 = if (is_pp) @intFromFloat(c.sqlite3_column_double(stmt, 2)) else c.sqlite3_column_int64(stmt, 2);
    try w.print("{d}|{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}", .{ c.sqlite3_column_int64(stmt, 0), std.mem.span(c.sqlite3_column_text(stmt, 1)), score_val, c.sqlite3_column_int(stmt, 3), c.sqlite3_column_int(stmt, 4), c.sqlite3_column_int(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int(stmt, 8), c.sqlite3_column_int(stmt, 9), c.sqlite3_column_int(stmt, 10), c.sqlite3_column_int(stmt, 11), c.sqlite3_column_int(stmt, 12), rank, c.sqlite3_column_int64(stmt, 13), c.sqlite3_column_int(stmt, 14) });
}
