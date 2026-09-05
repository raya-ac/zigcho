const std = @import("std");
const domain = @import("domain.zig");
const postgres = @import("postgres.zig");
const storage_contracts = @import("storage/contracts.zig");
const stable_score = @import("stable_score.zig");
const beatmap = @import("beatmap.zig");
const lazer = @import("lazer.zig");
const performance_calculator = @import("exact_pp.zig");
const pp_admin = @import("pp_admin.zig");
const stable_mods = @import("stable_mods.zig");
const screenshot_contract = @import("screenshot.zig");
const media_contract = @import("media_contract.zig");
const site_replay = @import("site_replay.zig");
const user_json = @import("user_json.zig");
const achievements = @import("achievements.zig");
const bss = @import("bss.zig");
const r2 = @import("r2.zig");
const object_keys = @import("object_keys.zig");
const upstream_user = @import("upstream_user.zig");
const server_control = @import("server_control.zig");
const account_roles = @import("account_roles.zig");
const anticheat_evidence = @import("anticheat_evidence.zig");
const anticheat_review = @import("anticheat_review.zig");
const stable_client = @import("stable_client.zig");
const postgres_stable_sessions = @import("postgres_stable_sessions.zig");
const database_sql = @import("database_sql");

pub const ClientHardware = storage_contracts.ClientHardware;
pub const HardwareEvidence = storage_contracts.HardwareEvidence;
pub const AnticheatSource = storage_contracts.AnticheatSource;
pub const AnticheatExclusionScope = storage_contracts.AnticheatExclusionScope;
pub const anticheat_exclusion_min_seconds = storage_contracts.anticheat_exclusion_min_seconds;
pub const anticheat_exclusion_max_seconds = storage_contracts.anticheat_exclusion_max_seconds;
pub const AnticheatReviewLabel = storage_contracts.AnticheatReviewLabel;
pub const AnticheatObservation = storage_contracts.AnticheatObservation;
pub const is_postgres = true;
pub const schema_version: u16 = 48;
pub const StableScoreGraceResult = postgres_stable_sessions.GraceResult;
pub const LazerCommentable = storage_contracts.LazerCommentable;
pub const LazerCommentTarget = storage_contracts.LazerCommentTarget;
pub const LazerCommentSort = storage_contracts.LazerCommentSort;
pub const ReplaySource = storage_contracts.ReplaySource;
pub const UpstreamUserCache = storage_contracts.UpstreamUserCache;
pub const BeatmapSetCreator = storage_contracts.BeatmapSetCreator;
pub const ConsumedLazerScoreToken = storage_contracts.ConsumedLazerScoreToken;
const pg_core = @import("storage/postgres/core/store.zig");
const pg_accounts = @import("storage/postgres/accounts/store.zig");
const pg_beatmap_catalog = @import("storage/postgres/beatmaps/catalog.zig");
const pg_beatmap_media = @import("storage/postgres/beatmaps/media.zig");
const pg_beatmap_bss = @import("storage/postgres/beatmaps/bss.zig");
const pg_score_stats = @import("storage/postgres/scores/stats.zig");
const pg_score_lazer = @import("storage/postgres/scores/lazer.zig");
const pg_score_stable = @import("storage/postgres/scores/stable.zig");
const pg_score_replays = @import("storage/postgres/scores/replays.zig");
const pg_score_achievements = @import("storage/postgres/scores/achievements.zig");
const pg_score_maintenance = @import("storage/postgres/scores/maintenance.zig");
const pg_social = @import("storage/postgres/social/store.zig");
const pg_multiplayer = @import("storage/postgres/multiplayer/store.zig");
const pg_moderation = @import("storage/postgres/moderation/store.zig");
const pg_common = @import("storage/postgres/common.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: postgres.Pool,
    object_store: r2.Storage = .{ .endpoint = "", .bucket = "", .access_key_id = "", .secret_access_key = "" },
    external_only: bool = false,

    pub const RegistrationConflicts = pg_common.RegistrationConflicts;
    pub const ServerCounts = pg_common.ServerCounts;
    pub const BeatmapCacheStats = pg_common.BeatmapCacheStats;
    pub const BeatmapCachePrune = pg_common.BeatmapCachePrune;
    pub const BeatmapMediaCacheStats = pg_common.BeatmapMediaCacheStats;
    pub const BeatmapArchiveDownload = storage_contracts.BeatmapArchiveDownload;
    pub const ObjectMigrationStats = storage_contracts.ObjectMigrationStats;
    pub const ObjectPurgeStats = storage_contracts.ObjectPurgeStats;
    pub const BeatmapForScore = storage_contracts.BeatmapForScore;
    pub const BeatmapInfo = storage_contracts.BeatmapInfo;
    pub const StableBeatmapInfo = storage_contracts.StableBeatmapInfo;
    pub const DirectMessage = storage_contracts.DirectMessage;
    pub const BeatmapSelection = storage_contracts.BeatmapSelection;
    pub const MatchmakingBeatmap = storage_contracts.MatchmakingBeatmap;
    pub const MultiplayerRoomArchive = storage_contracts.MultiplayerRoomArchive;
    pub const LazerRankedRating = storage_contracts.LazerRankedRating;
    pub const LazerRankedResult = storage_contracts.LazerRankedResult;
    pub const BeatmapRating = storage_contracts.BeatmapRating;
    pub const PpSnapshot = storage_contracts.PpSnapshot;
    pub const CustomAvatar = storage_contracts.CustomAvatar;
    pub const LazerChatWrite = storage_contracts.LazerChatWrite;
    pub const GameTokenPair = storage_contracts.GameTokenPair;
    pub const GameTokenRefresh = storage_contracts.GameTokenRefresh;
    pub const ChatCursor = storage_contracts.ChatCursor;
    pub const directStatus = storage_contracts.directStatus;
    pub const stableStatus = storage_contracts.stableStatus;
    pub const lazerStatus = storage_contracts.lazerStatus;

    pub fn open(allocator: std.mem.Allocator, io: std.Io, conninfo: []const u8) !Store {
        return .{ .allocator = allocator, .io = io, .pool = try postgres.Pool.init(allocator, io, conninfo, postgres.Pool.default_size) };
    }

    pub fn bindObjectStorage(self: *Store, object_store: r2.Storage) void {
        return pg_core.bindObjectStorage(self, object_store);
    }
    pub fn close(self: *Store) void {
        return pg_core.close(self);
    }
    pub fn rotateStableScoreSession(self: *Store, user_id: i32, token: []const u8, binding: stable_client.Binding, now: i64, grace_seconds: i64) !void {
        return pg_core.rotateStableScoreSession(self, user_id, token, binding, now, grace_seconds);
    }
    pub fn consumeStableScoreGrace(self: *Store, token: []const u8, user_id: i32, binding: stable_client.Binding, submission_checksum: []const u8, now: i64) !StableScoreGraceResult {
        return pg_core.consumeStableScoreGrace(self, token, user_id, binding, submission_checksum, now);
    }
    pub fn revokeStableScoreSessionsForUser(self: *Store, user_id: i32) !usize {
        return pg_core.revokeStableScoreSessionsForUser(self, user_id);
    }
    const refreshExternalOnly = pg_core.refreshExternalOnly;
    pub fn migrate(self: *Store) !void {
        return pg_core.migrate(self);
    }
    const finishPendingRankedStatsRebuild = pg_core.finishPendingRankedStatsRebuild;
    pub fn register(self: *Store, name: []const u8, email: []const u8, password_md5: []const u8) !i32 {
        return pg_accounts.register(self, name, email, password_md5);
    }
    const insertHardwareMatchAudit = pg_moderation.insertHardwareMatchAudit;
    pub fn createAnticheatExclusion(self: *Store, actor_id: i32, user_id: i32, scope: AnticheatExclusionScope, duration_seconds: i64, reason: []const u8) !i64 {
        return pg_moderation.createAnticheatExclusion(self, actor_id, user_id, scope, duration_seconds, reason);
    }
    pub fn anticheatExclusionTarget(self: *Store, exclusion_id: i64) !?i32 {
        return pg_moderation.anticheatExclusionTarget(self, exclusion_id);
    }
    pub fn revokeAnticheatExclusion(self: *Store, actor_id: i32, exclusion_id: i64, reason: []const u8) !void {
        return pg_moderation.revokeAnticheatExclusion(self, actor_id, exclusion_id, reason);
    }
    pub fn recordAnticheatObservation(self: *Store, user_id: i32, observation: AnticheatObservation) !i64 {
        return pg_moderation.recordAnticheatObservation(self, user_id, observation);
    }
    pub fn crossAccountReplayMatches(self: *Store, user_id: i32, digest: *const [32]u8) !u32 {
        return pg_moderation.crossAccountReplayMatches(self, user_id, digest);
    }
    pub fn recordReplayFingerprint(self: *Store, user_id: i32, score_id: i64, digest: *const [32]u8) !void {
        return pg_moderation.recordReplayFingerprint(self, user_id, score_id, digest);
    }
    pub fn crossAccountReplayContentMatches(self: *Store, user_id: i32, map_md5: []const u8, mode: u8, digest: *const [32]u8) !u32 {
        return pg_moderation.crossAccountReplayContentMatches(self, user_id, map_md5, mode, digest);
    }
    pub fn recordReplayContentFingerprint(self: *Store, user_id: i32, score_id: i64, digest: *const [32]u8) !void {
        return pg_moderation.recordReplayContentFingerprint(self, user_id, score_id, digest);
    }
    pub fn recordClientHardware(self: *Store, user_id: i32, hardware: ClientHardware) !HardwareEvidence {
        return pg_moderation.recordClientHardware(self, user_id, hardware);
    }
    pub fn recordLastFmFlag(self: *Store, user_id: i32, flags: u32) !void {
        return pg_moderation.recordLastFmFlag(self, user_id, flags);
    }
    pub fn rateBeatmap(self: *Store, user_id: i32, map_md5: []const u8, rating: ?u8) !BeatmapRating {
        return pg_beatmap_catalog.rateBeatmap(self, user_id, map_md5, rating);
    }
    const upsertBeatmapInner = pg_beatmap_catalog.upsertBeatmapInner;
    pub fn upsertBeatmap(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: []const u8) !void {
        return pg_beatmap_catalog.upsertBeatmap(self, metadata, md5, status, stars, max_combo, osu_file);
    }
    pub fn upsertBeatmapMeta(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32) !void {
        return pg_beatmap_catalog.upsertBeatmapMeta(self, metadata, md5, status, stars, max_combo);
    }
    pub fn beatmapFile(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?[]u8 {
        return pg_beatmap_catalog.beatmapFile(self, allocator, md5);
    }
    pub fn beatmapHasFile(self: *Store, md5: []const u8) !bool {
        return pg_beatmap_catalog.beatmapHasFile(self, md5);
    }
    pub fn beatmapFileById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?[]u8 {
        return pg_beatmap_catalog.beatmapFileById(self, allocator, map_id);
    }
    pub fn beatmapSelectionById(self: *Store, map_id: i32) !?BeatmapSelection {
        return pg_beatmap_catalog.beatmapSelectionById(self, map_id);
    }
    const multiplayerRoomArchiveFromResult = pg_multiplayer.multiplayerRoomArchiveFromResult;
    pub fn nextLazerMultiplayerRoomId(self: *Store) !i64 {
        return pg_multiplayer.nextLazerMultiplayerRoomId(self);
    }
    pub fn saveLazerMultiplayerRoomArchive(self: *Store, room_id: i64, owner_id: i32, category: []const u8, room_json: []const u8, leaderboard_json: []const u8, participant_ids_json: []const u8) !void {
        return pg_multiplayer.saveLazerMultiplayerRoomArchive(self, room_id, owner_id, category, room_json, leaderboard_json, participant_ids_json);
    }
    pub fn updateLazerMultiplayerRoomArchive(self: *Store, room_id: i64, room_json: []const u8, leaderboard_json: []const u8) !void {
        return pg_multiplayer.updateLazerMultiplayerRoomArchive(self, room_id, room_json, leaderboard_json);
    }
    pub fn lazerMultiplayerRoomArchive(self: *Store, allocator: std.mem.Allocator, room_id: i64) !?MultiplayerRoomArchive {
        return pg_multiplayer.lazerMultiplayerRoomArchive(self, allocator, room_id);
    }
    pub fn lazerMultiplayerRoomArchives(self: *Store, allocator: std.mem.Allocator, limit: u8) ![]MultiplayerRoomArchive {
        return pg_multiplayer.lazerMultiplayerRoomArchives(self, allocator, limit);
    }
    pub fn lazerMultiplayerRoomCheckpoints(self: *Store, allocator: std.mem.Allocator) ![]MultiplayerRoomArchive {
        return pg_multiplayer.lazerMultiplayerRoomCheckpoints(self, allocator);
    }
    pub fn deleteLazerMultiplayerRoomCheckpoint(self: *Store, room_id: i64) !void {
        return pg_multiplayer.deleteLazerMultiplayerRoomCheckpoint(self, room_id);
    }
    pub fn lazerRankedRating(self: *Store, user_id: i32, ruleset_id: u8) !LazerRankedRating {
        return pg_multiplayer.lazerRankedRating(self, user_id, ruleset_id);
    }
    pub fn applyLazerRankedResult(self: *Store, room_id: i64, ruleset_id: u8, winner_id: i32, loser_id: i32) !LazerRankedResult {
        return pg_multiplayer.applyLazerRankedResult(self, room_id, ruleset_id, winner_id, loser_id);
    }
    pub fn matchmakingBeatmaps(self: *Store, allocator: std.mem.Allocator, mode: u8, limit: u8) ![]MatchmakingBeatmap {
        return pg_multiplayer.matchmakingBeatmaps(self, allocator, mode, limit);
    }
    pub fn setScorePinned(self: *Store, user_id: i32, map_md5: []const u8, mode: u8, mods_value: i32, namespace: []const u8, pinned: bool) !i64 {
        return pg_score_stats.setScorePinned(self, user_id, map_md5, mode, mods_value, namespace, pinned);
    }
    pub fn consumedLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64) !?ConsumedLazerScoreToken {
        return pg_score_lazer.consumedLazerScoreToken(self, user_id, beatmap_id, token_id);
    }
    pub fn setScorePinnedById(self: *Store, user_id: i32, source: ReplaySource, score_id: i64, pinned: bool) !void {
        return pg_score_stats.setScorePinnedById(self, user_id, source, score_id, pinned);
    }
    const allocateBssIds = pg_beatmap_bss.allocateBssIds;
    pub fn reserveBssSubmission(self: *Store, allocator: std.mem.Allocator, user_id: i32, input: bss.ReserveInput) !bss.Reservation {
        return pg_beatmap_bss.reserveBssSubmission(self, allocator, user_id, input);
    }
    pub fn bssReservedMapIds(self: *Store, allocator: std.mem.Allocator, user_id: i32, set_id: i32) ![]i32 {
        return pg_beatmap_bss.bssReservedMapIds(self, allocator, user_id, set_id);
    }
    pub fn failBssSubmission(self: *Store, user_id: i32, set_id: i32, reason: []const u8) !void {
        return pg_beatmap_bss.failBssSubmission(self, user_id, set_id, reason);
    }
    pub fn publishBssSubmission(self: *Store, user_id: i32, set_id: i32, package: *const bss.Package, archive: []const u8, sha256: []const u8) !void {
        return pg_beatmap_bss.publishBssSubmission(self, user_id, set_id, package, archive, sha256);
    }
    pub fn upsertBeatmapArchive(self: *Store, set_id: i32, sha256: []const u8, osz_file: []const u8) !void {
        return pg_beatmap_media.upsertBeatmapArchive(self, set_id, sha256, osz_file);
    }
    pub fn beatmapSetExists(self: *Store, set_id: i32) !bool {
        return pg_beatmap_catalog.beatmapSetExists(self, set_id);
    }
    pub fn beatmapSetIdsMissingArchives(self: *Store, allocator: std.mem.Allocator, limit: u16) ![]i32 {
        return pg_beatmap_media.beatmapSetIdsMissingArchives(self, allocator, limit);
    }
    pub fn beatmapArchiveIdsMissingSize(self: *Store, allocator: std.mem.Allocator, limit: u16) ![]i32 {
        return pg_beatmap_media.beatmapArchiveIdsMissingSize(self, allocator, limit);
    }
    pub fn setBeatmapArchiveSize(self: *Store, set_id: i32, bytes: usize) !void {
        return pg_beatmap_media.setBeatmapArchiveSize(self, set_id, bytes);
    }
    pub fn beatmapMirrorPendingCount(self: *Store) !i64 {
        return pg_beatmap_media.beatmapMirrorPendingCount(self);
    }
    pub fn beatmapSetCreator(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?BeatmapSetCreator {
        return pg_beatmap_catalog.beatmapSetCreator(self, allocator, set_id);
    }
    pub fn upstreamUserCacheByName(self: *Store, name: []const u8, mode: u8, now: i64, max_age: i64) !?UpstreamUserCache {
        return pg_beatmap_catalog.upstreamUserCacheByName(self, name, mode, now, max_age);
    }
    pub fn upstreamUserCacheById(self: *Store, user_id: i32, mode: u8, now: i64, max_age: i64) !?UpstreamUserCache {
        return pg_beatmap_catalog.upstreamUserCacheById(self, user_id, mode, now, max_age);
    }
    pub fn upsertUpstreamUserProfile(self: *Store, profile: upstream_user.Profile, profile_json: []const u8, fetched_at: i64) !void {
        return pg_beatmap_catalog.upsertUpstreamUserProfile(self, profile, profile_json, fetched_at);
    }
    pub fn linkBeatmapSetCreator(self: *Store, set_id: i32, user_id: i32) !void {
        return pg_beatmap_catalog.linkBeatmapSetCreator(self, set_id, user_id);
    }
    pub fn upstreamUserProfileJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, mode: u8) !?[]u8 {
        return pg_beatmap_catalog.upstreamUserProfileJson(self, allocator, user_id, mode);
    }
    pub fn upsertBeatmapSetMetadata(self: *Store, metadata: upstream_user.SetMetadata, fetched_at: i64) !void {
        return pg_beatmap_catalog.upsertBeatmapSetMetadata(self, metadata, fetched_at);
    }
    pub fn updateBeatmapUpstreamStats(self: *Store, beatmap_id: i32, plays: i32, passes: i32, hit_length: i32) !void {
        return pg_beatmap_catalog.updateBeatmapUpstreamStats(self, beatmap_id, plays, passes, hit_length);
    }
    pub fn beatmapSetIdForMap(self: *Store, beatmap_id: i32) !?i32 {
        return pg_beatmap_catalog.beatmapSetIdForMap(self, beatmap_id);
    }
    pub fn beatmapSetIdForChecksum(self: *Store, checksum: []const u8) !?i32 {
        return pg_beatmap_catalog.beatmapSetIdForChecksum(self, checksum);
    }
    pub fn putBeatmapMedia(self: *Store, set_id: i32, kind: media_contract.Kind, content_type: media_contract.ContentType, data: []const u8) !void {
        return pg_beatmap_media.putBeatmapMedia(self, set_id, kind, content_type, data);
    }
    pub fn beatmapMedia(self: *Store, allocator: std.mem.Allocator, set_id: i32, kind: media_contract.Kind) !?media_contract.Asset {
        return pg_beatmap_media.beatmapMedia(self, allocator, set_id, kind);
    }
    pub fn beatmapMediaCacheStats(self: *Store) !BeatmapMediaCacheStats {
        return pg_beatmap_media.beatmapMediaCacheStats(self);
    }
    pub fn pruneBeatmapMedia(self: *Store, max_bytes: u64) !BeatmapCachePrune {
        return pg_beatmap_media.pruneBeatmapMedia(self, max_bytes);
    }
    pub fn beatmapArchive(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
        return pg_beatmap_media.beatmapArchive(self, allocator, set_id);
    }
    pub fn beatmapArchiveDownload(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?BeatmapArchiveDownload {
        return pg_beatmap_media.beatmapArchiveDownload(self, allocator, set_id);
    }
    pub fn streamBeatmapArchive(self: *Store, download: BeatmapArchiveDownload, writer: *std.Io.Writer) !void {
        return pg_beatmap_media.streamBeatmapArchive(self, download, writer);
    }
    pub fn hydrationRetryAllowed(self: *Store, md5: []const u8, now: i64) !bool {
        return pg_beatmap_media.hydrationRetryAllowed(self, md5, now);
    }
    pub fn recordHydrationFailure(self: *Store, md5: []const u8, set_id: i32, reason: []const u8, now: i64) !void {
        return pg_beatmap_media.recordHydrationFailure(self, md5, set_id, reason, now);
    }
    pub fn clearHydrationFailure(self: *Store, md5: []const u8) !void {
        return pg_beatmap_media.clearHydrationFailure(self, md5);
    }
    pub fn beatmapCacheStats(self: *Store) !BeatmapCacheStats {
        return pg_beatmap_media.beatmapCacheStats(self);
    }
    pub fn pruneBeatmapArchives(self: *Store, max_bytes: u64) !BeatmapCachePrune {
        return pg_beatmap_media.pruneBeatmapArchives(self, max_bytes);
    }
    const putVerifiedObject = pg_beatmap_media.putVerifiedObject;
    pub fn storeReplayObject(self: *Store, source: ReplaySource, score_id: i64, data: []const u8) !bool {
        return pg_beatmap_media.storeReplayObject(self, source, score_id, data);
    }
    pub fn migrateBeatmapObjects(self: *Store) !ObjectMigrationStats {
        return pg_beatmap_media.migrateBeatmapObjects(self);
    }
    pub fn purgeBeatmapObjectBackups(self: *Store) !ObjectPurgeStats {
        return pg_beatmap_media.purgeBeatmapObjectBackups(self);
    }
    const writeDirectText = pg_beatmap_catalog.writeDirectText;
    const appendDirectSet = pg_beatmap_catalog.appendDirectSet;
    pub fn stableSearch(self: *Store, allocator: std.mem.Allocator, search_query: []const u8, mode: i8, direct_status: u8, page: u16) ![]u8 {
        return pg_beatmap_catalog.stableSearch(self, allocator, search_query, mode, direct_status, page);
    }
    pub fn stableSearchSet(self: *Store, allocator: std.mem.Allocator, set_id: ?i32, map_id: ?i32, md5: ?[]const u8) ![]u8 {
        return pg_beatmap_catalog.stableSearchSet(self, allocator, set_id, map_id, md5);
    }
    const writeBoardRow = pg_beatmap_catalog.writeBoardRow;
    pub fn stableLeaderboard(self: *Store, allocator: std.mem.Allocator, viewer: domain.User, map_md5: []const u8, mode: u8, board_type: u8, requested_mods: i32) ![]u8 {
        return pg_beatmap_catalog.stableLeaderboard(self, allocator, viewer, map_md5, mode, board_type, requested_mods);
    }
    const appendLazerTagFields = pg_beatmap_catalog.appendLazerTagFields;
    const appendLazerMap = pg_beatmap_catalog.appendLazerMap;
    const appendLazerSet = pg_beatmap_catalog.appendLazerSet;
    pub fn lazerBeatmapSet(self: *Store, allocator: std.mem.Allocator, set_id: i32, requester_id: ?i32) !?[]u8 {
        return pg_beatmap_catalog.lazerBeatmapSet(self, allocator, set_id, requester_id);
    }
    pub fn lazerBeatmapLookup(self: *Store, allocator: std.mem.Allocator, beatmap_id: ?i32, checksum: ?[]const u8, requester_id: ?i32) !?[]u8 {
        return pg_beatmap_catalog.lazerBeatmapLookup(self, allocator, beatmap_id, checksum, requester_id);
    }
    pub fn lazerBeatmapSearch(self: *Store, allocator: std.mem.Allocator, search_query: []const u8, mode: i8, offset: u16, requester_id: ?i32) ![]u8 {
        return pg_beatmap_catalog.lazerBeatmapSearch(self, allocator, search_query, mode, offset, requester_id);
    }
    pub fn lazerBeatmapSets(self: *Store, allocator: std.mem.Allocator, set_ids: []const i32, offset: u16, requester_id: ?i32) ![]u8 {
        return pg_beatmap_catalog.lazerBeatmapSets(self, allocator, set_ids, offset, requester_id);
    }
    pub fn lazerOwnedBeatmapSearch(self: *Store, allocator: std.mem.Allocator, user_id: i32, query: []const u8, mode: i8, offset: u16, requester_id: ?i32) ![]u8 {
        return pg_beatmap_catalog.lazerOwnedBeatmapSearch(self, allocator, user_id, query, mode, offset, requester_id);
    }
    pub fn lazerUserBeatmapSetsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, kind: []const u8, offset: usize, limit: usize, requester_id: ?i32) ![]u8 {
        return pg_beatmap_catalog.lazerUserBeatmapSetsJson(self, allocator, user_id, kind, offset, limit, requester_id);
    }
    pub fn lazerMostPlayedJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, requester_id: i32, offset: u16, limit: u8) ![]u8 {
        return pg_beatmap_catalog.lazerMostPlayedJson(self, allocator, user_id, requester_id, offset, limit);
    }
    pub fn registrationConflicts(self: *Store, name: []const u8, email: []const u8) !RegistrationConflicts {
        return pg_accounts.registrationConflicts(self, name, email);
    }
    pub fn avatarForUser(self: *Store, user_id: i32) !?u8 {
        return pg_accounts.avatarForUser(self, user_id);
    }
    pub fn customAvatarForUser(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
        return pg_accounts.customAvatarForUser(self, allocator, user_id);
    }
    pub fn setCustomAvatar(self: *Store, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8) !void {
        return pg_accounts.setCustomAvatar(self, user_id, object_key, content_type, etag);
    }
    pub fn deleteCustomAvatar(self: *Store, user_id: i32) !bool {
        return pg_accounts.deleteCustomAvatar(self, user_id);
    }
    const customImageFromResult = pg_accounts.customImageFromResult;
    pub fn customBannerForUser(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
        return pg_accounts.customBannerForUser(self, allocator, user_id);
    }
    pub fn setCustomBanner(self: *Store, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8, width: u32, height: u32) !void {
        return pg_accounts.setCustomBanner(self, user_id, object_key, content_type, etag, width, height);
    }
    pub fn deleteCustomBanner(self: *Store, user_id: i32) !bool {
        return pg_accounts.deleteCustomBanner(self, user_id);
    }
    pub fn teamAsset(self: *Store, allocator: std.mem.Allocator, team_id: i32, kind: []const u8) !?CustomAvatar {
        return pg_accounts.teamAsset(self, allocator, team_id, kind);
    }
    pub fn setTeamAsset(self: *Store, team_id: i32, kind: []const u8, object_key: []const u8, content_type: []const u8, etag: [64]u8, width: u32, height: u32) !void {
        return pg_accounts.setTeamAsset(self, team_id, kind, object_key, content_type, etag, width, height);
    }
    pub fn deleteTeamAsset(self: *Store, team_id: i32, kind: []const u8) !bool {
        return pg_accounts.deleteTeamAsset(self, team_id, kind);
    }
    pub fn customAvatarUserIds(self: *Store, allocator: std.mem.Allocator) ![]i32 {
        return pg_accounts.customAvatarUserIds(self, allocator);
    }
    pub fn updateSiteProfile(self: *Store, user_id: i32, settings: domain.SiteProfileSettings) !void {
        return pg_accounts.updateSiteProfile(self, user_id, settings);
    }
    pub fn lazerProfileSummary(self: *Store, user_id: i32) !?domain.ProfileSummary {
        return pg_accounts.lazerProfileSummary(self, user_id);
    }
    pub fn lazerBatchUserVisibility(self: *Store, user_id: i32) !?domain.BatchUserVisibility {
        return pg_accounts.lazerBatchUserVisibility(self, user_id);
    }
    pub fn lazerMonthlyPlaycountsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
        return pg_accounts.lazerMonthlyPlaycountsJson(self, allocator, user_id);
    }
    pub fn lazerReplaysWatchedCountsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8) ![]u8 {
        return pg_accounts.lazerReplaysWatchedCountsJson(self, allocator, user_id, ruleset_id);
    }
    pub fn siteAccountJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        return pg_accounts.siteAccountJson(self, allocator, user_id);
    }
    pub fn updateAccountEmail(self: *Store, user_id: i32, email: []const u8) !void {
        return pg_accounts.updateAccountEmail(self, user_id, email);
    }
    pub fn updateAccountPassword(self: *Store, user_id: i32, password_md5: []const u8) !void {
        return pg_accounts.updateAccountPassword(self, user_id, password_md5);
    }
    pub fn updateAccountUsername(self: *Store, user_id: i32, new_name: []const u8) !void {
        return pg_accounts.updateAccountUsername(self, user_id, new_name);
    }
    pub fn revokeAllTokensForUser(self: *Store, user_id: i32) !usize {
        return pg_accounts.revokeAllTokensForUser(self, user_id);
    }
    pub fn teamsJson(self: *Store, allocator: std.mem.Allocator, requester_id: ?i32) ![]u8 {
        return pg_multiplayer.teamsJson(self, allocator, requester_id);
    }
    pub fn teamJson(self: *Store, allocator: std.mem.Allocator, team_id: i32, requester_id: ?i32, staff: bool) !?[]u8 {
        return pg_multiplayer.teamJson(self, allocator, team_id, requester_id, staff);
    }
    pub fn createTeam(self: *Store, user_id: i32, settings: domain.TeamSettings) !i32 {
        return pg_multiplayer.createTeam(self, user_id, settings);
    }
    pub fn updateTeam(self: *Store, actor_id: i32, team_id: i32, settings: domain.TeamSettings, staff: bool) !void {
        return pg_multiplayer.updateTeam(self, actor_id, team_id, settings, staff);
    }
    pub fn joinOrApplyTeam(self: *Store, user_id: i32, team_id: i32) !domain.TeamJoinResult {
        return pg_multiplayer.joinOrApplyTeam(self, user_id, team_id);
    }
    pub fn leaveTeam(self: *Store, user_id: i32, team_id: i32) !void {
        return pg_multiplayer.leaveTeam(self, user_id, team_id);
    }
    pub fn teamMemberAction(self: *Store, actor_id: i32, team_id: i32, target_id: i32, action: []const u8, staff: bool) !void {
        return pg_multiplayer.teamMemberAction(self, actor_id, team_id, target_id, action, staff);
    }
    pub fn disbandTeam(self: *Store, actor_id: i32, team_id: i32, staff: bool) !void {
        return pg_multiplayer.disbandTeam(self, actor_id, team_id, staff);
    }
    pub fn teamCanManage(self: *Store, actor_id: i32, team_id: i32, staff: bool) !bool {
        return pg_multiplayer.teamCanManage(self, actor_id, team_id, staff);
    }
    const credentialForSafeName = pg_accounts.credentialForSafeName;
    pub fn authenticate(self: *Store, allocator: std.mem.Allocator, name: []const u8, password_md5: []const u8) !?domain.User {
        return pg_accounts.authenticate(self, allocator, name, password_md5);
    }
    const upgradePassword = pg_accounts.upgradePassword;
    pub fn userById(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?domain.User {
        return pg_accounts.userById(self, allocator, user_id);
    }
    pub fn userByName(self: *Store, allocator: std.mem.Allocator, name: []const u8) !?domain.User {
        return pg_accounts.userByName(self, allocator, name);
    }
    pub fn siteNameHistoryJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        return pg_accounts.siteNameHistoryJson(self, allocator, user_id);
    }
    pub fn friendIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        return pg_social.friendIds(self, allocator, user_id);
    }
    pub fn addFriend(self: *Store, user_id: i32, friend_id: i32) !domain.RelationshipAddResult {
        return pg_social.addFriend(self, user_id, friend_id);
    }
    pub fn removeFriend(self: *Store, user_id: i32, friend_id: i32) !bool {
        return pg_social.removeFriend(self, user_id, friend_id);
    }
    pub fn friendsAreMutual(self: *Store, user_id: i32, friend_id: i32) !bool {
        return pg_social.friendsAreMutual(self, user_id, friend_id);
    }
    const replayViewCountWithConnection = pg_social.replayViewCountWithConnection;
    pub fn replayViewCount(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !i32 {
        return pg_social.replayViewCount(self, user_id, source, stats_mode);
    }
    pub fn recordReplayView(self: *Store, viewer_id: i32, source: ReplaySource, score_id: i64) !bool {
        return pg_social.recordReplayView(self, viewer_id, source, score_id);
    }
    pub fn blockIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        return pg_social.blockIds(self, allocator, user_id);
    }
    pub fn addBlock(self: *Store, user_id: i32, blocked_id: i32) !bool {
        return pg_social.addBlock(self, user_id, blocked_id);
    }
    pub fn removeBlock(self: *Store, user_id: i32, blocked_id: i32) !bool {
        return pg_social.removeBlock(self, user_id, blocked_id);
    }
    pub fn favouriteSetIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        return pg_beatmap_catalog.favouriteSetIds(self, allocator, user_id);
    }
    pub fn addFavourite(self: *Store, user_id: i32, set_id: i32) !bool {
        return pg_beatmap_catalog.addFavourite(self, user_id, set_id);
    }
    pub fn removeFavourite(self: *Store, user_id: i32, set_id: i32) !bool {
        return pg_beatmap_catalog.removeFavourite(self, user_id, set_id);
    }
    const stableBeatmapInfo = pg_beatmap_catalog.stableBeatmapInfo;
    pub fn stableBeatmapInfoByFilename(self: *Store, user_id: i32, filename: []const u8) !?StableBeatmapInfo {
        return pg_beatmap_catalog.stableBeatmapInfoByFilename(self, user_id, filename);
    }
    pub fn stableBeatmapInfoById(self: *Store, user_id: i32, map_id: i32) !?StableBeatmapInfo {
        return pg_beatmap_catalog.stableBeatmapInfoById(self, user_id, map_id);
    }
    pub fn addBeatmapComment(self: *Store, user_id: i32, target_type: []const u8, target_id: i64, time: f64, comment: []const u8, colour: ?[]const u8) !void {
        return pg_beatmap_catalog.addBeatmapComment(self, user_id, target_type, target_id, time, comment, colour);
    }
    pub fn beatmapComments(self: *Store, allocator: std.mem.Allocator, score_id: i64, set_id: i32, map_id: i32) ![]u8 {
        return pg_beatmap_catalog.beatmapComments(self, allocator, score_id, set_id, map_id);
    }
    pub fn addLazerComment(self: *Store, user_id: i32, target: LazerCommentTarget, parent_id: ?i64, message: []const u8) !i64 {
        return pg_beatmap_catalog.addLazerComment(self, user_id, target, parent_id, message);
    }
    pub fn lazerCommentTarget(self: *Store, comment_id: i64) !?LazerCommentTarget {
        return pg_beatmap_catalog.lazerCommentTarget(self, comment_id);
    }
    pub fn deleteLazerComment(self: *Store, user_id: i32, comment_id: i64, staff: bool) !bool {
        return pg_beatmap_catalog.deleteLazerComment(self, user_id, comment_id, staff);
    }
    pub fn setLazerCommentVote(self: *Store, user_id: i32, comment_id: i64, voted: bool) !bool {
        return pg_beatmap_catalog.setLazerCommentVote(self, user_id, comment_id, voted);
    }
    pub fn reportLazerComment(self: *Store, user_id: i32, comment_id: i64, reason: []const u8, comments: []const u8) !bool {
        return pg_beatmap_catalog.reportLazerComment(self, user_id, comment_id, reason, comments);
    }
    pub fn addLazerReport(self: *Store, reporter_id: i32, reportable_type: []const u8, reportable_id: i64, reason: []const u8, comments: []const u8) !bool {
        return pg_beatmap_catalog.addLazerReport(self, reporter_id, reportable_type, reportable_id, reason, comments);
    }
    pub fn lazerMessageExists(self: *Store, message_id: i64) !bool {
        return pg_beatmap_catalog.lazerMessageExists(self, message_id);
    }
    pub fn staffLazerReportsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_beatmap_catalog.staffLazerReportsJson(self, allocator);
    }
    pub fn resolveLazerReport(self: *Store, actor_id: i32, report_id: i64, decision: []const u8) !bool {
        return pg_beatmap_catalog.resolveLazerReport(self, actor_id, report_id, decision);
    }
    pub fn setLazerBeatmapTag(self: *Store, user_id: i32, beatmap_id: i32, tag_id: i64, selected: bool) !bool {
        return pg_beatmap_catalog.setLazerBeatmapTag(self, user_id, beatmap_id, tag_id, selected);
    }
    pub fn lazerBeatmapTagStateJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, beatmap_id: i32) !?[]u8 {
        return pg_beatmap_catalog.lazerBeatmapTagStateJson(self, allocator, user_id, beatmap_id);
    }
    pub fn lazerCommentsJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, target: LazerCommentTarget, sort: LazerCommentSort, page: u16, parent_id: i64, only_id: i64) ![]u8 {
        return pg_beatmap_catalog.lazerCommentsJson(self, allocator, viewer_id, target, sort, page, parent_id, only_id);
    }
    const directMessageAllowedWithConnection = pg_social.directMessageAllowedWithConnection;
    pub fn directMessageAllowed(self: *Store, from_id: i32, to_id: i32) !bool {
        return pg_social.directMessageAllowed(self, from_id, to_id);
    }
    pub fn storeDirectMessage(self: *Store, from_id: i32, to_id: i32, message: []const u8) !i64 {
        return pg_social.storeDirectMessage(self, from_id, to_id, message);
    }
    pub fn unreadDirectMessages(self: *Store, allocator: std.mem.Allocator, to_id: i32) ![]DirectMessage {
        return pg_social.unreadDirectMessages(self, allocator, to_id);
    }
    pub fn markDirectMessagesRead(self: *Store, to_id: i32, from_id: i32) !void {
        return pg_social.markDirectMessagesRead(self, to_id, from_id);
    }
    pub fn markDirectMessageRead(self: *Store, to_id: i32, message_id: i64) !bool {
        return pg_social.markDirectMessageRead(self, to_id, message_id);
    }
    pub fn recordPublicMessage(self: *Store, sender_id: i32, target: []const u8, message: []const u8) !void {
        return pg_social.recordPublicMessage(self, sender_id, target, message);
    }
    pub fn recordStaffAnnouncement(self: *Store, actor_id: i32, message: []const u8, reason: []const u8) !void {
        return pg_social.recordStaffAnnouncement(self, actor_id, message, reason);
    }
    pub fn recordLazerPublicMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, target: []const u8, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
        return pg_social.recordLazerPublicMessage(self, allocator, sender_id, target, message, is_action, uuid);
    }
    pub fn recordLazerRoomMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, room_id: i64, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
        return pg_social.recordLazerRoomMessage(self, allocator, sender_id, room_id, message, is_action, uuid);
    }
    pub fn recordLazerDirectMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, target_id: i32, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
        return pg_social.recordLazerDirectMessage(self, allocator, sender_id, target_id, message, is_action, uuid);
    }
    pub fn lazerDirectMessagesJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, other_id: i32, since: i64, limit: u16) ![]u8 {
        return pg_social.lazerDirectMessagesJson(self, allocator, viewer_id, other_id, since, limit);
    }
    pub fn directMessageThreadsJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, limit: u8) ![]u8 {
        return pg_social.directMessageThreadsJson(self, allocator, viewer_id, limit);
    }
    pub fn lazerAllMessagesJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, since: i64, limit: u16) ![]u8 {
        return pg_social.lazerAllMessagesJson(self, allocator, viewer_id, since, limit);
    }
    pub fn lazerAllMessagesForRoomJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, room_id: i64, since: i64, limit: u16) ![]u8 {
        return pg_social.lazerAllMessagesForRoomJson(self, allocator, viewer_id, room_id, since, limit);
    }
    pub fn lazerChatMessagesJson(self: *Store, allocator: std.mem.Allocator, channel_id: ?i64, since: i64, limit: u16) ![]u8 {
        return pg_social.lazerChatMessagesJson(self, allocator, channel_id, since, limit);
    }
    pub fn lazerRoomMessagesJson(self: *Store, allocator: std.mem.Allocator, room_id: i64, since: i64, limit: u16) ![]u8 {
        return pg_social.lazerRoomMessagesJson(self, allocator, room_id, since, limit);
    }
    pub fn lazerRoomChannelCursor(self: *Store, user_id: i32, room_id: i64) !ChatCursor {
        return pg_social.lazerRoomChannelCursor(self, user_id, room_id);
    }
    pub fn markLazerRoomChannelRead(self: *Store, user_id: i32, room_id: i64, message_id: i64) !void {
        return pg_social.markLazerRoomChannelRead(self, user_id, room_id, message_id);
    }
    pub fn lazerChannelListJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
        return pg_social.lazerChannelListJson(self, allocator, user_id);
    }
    pub fn lazerChannelCursor(self: *Store, user_id: i32, channel_id: i64) !ChatCursor {
        return pg_social.lazerChannelCursor(self, user_id, channel_id);
    }
    pub fn lazerDirectMessageCursor(self: *Store, viewer_id: i32, other_id: i32) !ChatCursor {
        return pg_social.lazerDirectMessageCursor(self, viewer_id, other_id);
    }
    pub fn markLazerChannelRead(self: *Store, user_id: i32, channel_id: i64, message_id: i64) !void {
        return pg_social.markLazerChannelRead(self, user_id, channel_id, message_id);
    }
    pub fn markLazerDirectMessageRead(self: *Store, viewer_id: i32, other_id: i32, message_id: i64) !void {
        return pg_social.markLazerDirectMessageRead(self, viewer_id, other_id, message_id);
    }
    pub fn beatmapRankContext(self: *Store, map_md5: []const u8) !?domain.BeatmapRankContext {
        return pg_moderation.beatmapRankContext(self, map_md5);
    }
    pub fn requestBeatmapRank(self: *Store, requester_id: i32, map_md5: []const u8) !domain.BeatmapRankContext {
        return pg_moderation.requestBeatmapRank(self, requester_id, map_md5);
    }
    pub fn nominateBeatmapSet(self: *Store, actor_id: i32, map_md5: []const u8, reason: []const u8) !domain.BeatmapRankContext {
        return pg_moderation.nominateBeatmapSet(self, actor_id, map_md5, reason);
    }
    pub fn applyBeatmapRankAction(self: *Store, actor_id: i32, map_md5: []const u8, action: domain.BeatmapRankAction, reason: []const u8) !domain.BeatmapRankContext {
        return pg_moderation.applyBeatmapRankAction(self, actor_id, map_md5, action, reason);
    }
    pub fn beatmapRankQueue(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_moderation.beatmapRankQueue(self, allocator);
    }
    const rankContextFromResult = pg_moderation.rankContextFromResult;
    const insertBeatmapRankEvent = pg_moderation.insertBeatmapRankEvent;
    const backfillLazerClassicScoresWithConnection = pg_score_maintenance.backfillLazerClassicScoresWithConnection;
    const rebuildRankedStats = pg_score_maintenance.rebuildRankedStats;
    pub fn recalculatePerformance(self: *Store, allocator: std.mem.Allocator) !u64 {
        return pg_score_maintenance.recalculatePerformance(self, allocator);
    }
    pub fn channelCanWrite(self: *Store, name: []const u8, privileges: u32) !bool {
        return pg_moderation.channelCanWrite(self, name, privileges);
    }
    pub fn setChannelLocked(self: *Store, actor_id: i32, name: []const u8, locked: bool, reason: []const u8) !void {
        return pg_moderation.setChannelLocked(self, actor_id, name, locked, reason);
    }
    pub fn setSilence(self: *Store, actor_id: i32, target_id: i32, silence_end: i64, action: []const u8, reason: []const u8) !void {
        return pg_moderation.setSilence(self, actor_id, target_id, silence_end, action, reason);
    }
    pub fn setRestricted(self: *Store, actor_id: i32, target_id: i32, restricted: bool, reason: []const u8) !void {
        return pg_moderation.setRestricted(self, actor_id, target_id, restricted, reason);
    }
    pub fn changePrivileges(self: *Store, actor_id: i32, target_id: i32, bits: u32, add: bool) !u32 {
        return pg_moderation.changePrivileges(self, actor_id, target_id, bits, add);
    }
    pub fn changeRole(self: *Store, actor_id: i32, target_id: i32, role: account_roles.Role, grant: bool, reason: []const u8) !account_roles.ChangeResult {
        return pg_moderation.changeRole(self, actor_id, target_id, role, grant, reason);
    }
    pub fn addModerationNote(self: *Store, actor_id: i32, target_id: i32, note: []const u8) !void {
        return pg_moderation.addModerationNote(self, actor_id, target_id, note);
    }
    pub fn recordModerationAction(self: *Store, actor_id: i32, target_id: i32, action: []const u8, detail: []const u8) !void {
        return pg_moderation.recordModerationAction(self, actor_id, target_id, action, detail);
    }
    pub fn recordAudit(self: *Store, actor_id: i32, action: []const u8, target: []const u8, detail: []const u8) !void {
        return pg_moderation.recordAudit(self, actor_id, action, target, detail);
    }
    pub fn moderationNotes(self: *Store, allocator: std.mem.Allocator, target_id: i32, limit: u8) ![]u8 {
        return pg_moderation.moderationNotes(self, allocator, target_id, limit);
    }
    pub fn createModerationAppeal(self: *Store, user_id: i32, kind: []const u8, message: []const u8) !i64 {
        return pg_moderation.createModerationAppeal(self, user_id, kind, message);
    }
    pub fn resolveModerationAppeal(self: *Store, actor_id: i32, appeal_id: i64, status: []const u8, resolution: []const u8) !void {
        return pg_moderation.resolveModerationAppeal(self, actor_id, appeal_id, status, resolution);
    }
    pub fn beatmapMd5ForSet(self: *Store, set_id: i32) !?[32]u8 {
        return pg_moderation.beatmapMd5ForSet(self, set_id);
    }
    pub fn staffAnticheatJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_moderation.staffAnticheatJson(self, allocator);
    }
    pub fn reviewAnticheatObservation(self: *Store, actor_id: i32, observation_id: i64, label: AnticheatReviewLabel, note: []const u8) !void {
        return pg_moderation.reviewAnticheatObservation(self, actor_id, observation_id, label, note);
    }
    pub fn serverControlEnabled(self: *Store, feature: server_control.Feature) !bool {
        return pg_moderation.serverControlEnabled(self, feature);
    }
    pub fn staffServerControlsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_moderation.staffServerControlsJson(self, allocator);
    }
    pub fn setServerControl(self: *Store, actor_id: i32, feature: server_control.Feature, enabled: bool, reason: []const u8) !void {
        return pg_moderation.setServerControl(self, actor_id, feature, enabled, reason);
    }
    pub fn staffOverviewJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_moderation.staffOverviewJson(self, allocator);
    }
    pub fn staffUserSearchJson(self: *Store, allocator: std.mem.Allocator, query: []const u8) ![]u8 {
        return pg_moderation.staffUserSearchJson(self, allocator, query);
    }
    pub fn staffRolesJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        return pg_moderation.staffRolesJson(self, allocator, user_id);
    }
    pub fn lazerUserSearchIds(self: *Store, allocator: std.mem.Allocator, query: []const u8, limit: u8) ![]i32 {
        return pg_moderation.lazerUserSearchIds(self, allocator, query, limit);
    }
    pub fn staffRankingJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_moderation.staffRankingJson(self, allocator);
    }
    pub fn staffAppealsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_moderation.staffAppealsJson(self, allocator);
    }
    pub fn staffUserJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        return pg_moderation.staffUserJson(self, allocator, user_id);
    }
    pub fn staffAuditJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_moderation.staffAuditJson(self, allocator);
    }
    pub fn staffChannelsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        return pg_moderation.staffChannelsJson(self, allocator);
    }
    pub fn updateCountry(self: *Store, user_id: i32, value: [2]u8) !void {
        return pg_accounts.updateCountry(self, user_id, value);
    }
    pub fn serverCounts(self: *Store) !ServerCounts {
        return pg_score_stats.serverCounts(self);
    }
    pub fn siteRankings(self: *Store, allocator: std.mem.Allocator, source: domain.SiteScoreSource, mode: u8, offset: u16) ![]u8 {
        return pg_score_stats.siteRankings(self, allocator, source, mode, offset);
    }
    pub fn lazerRankingsJson(self: *Store, allocator: std.mem.Allocator, ruleset_id: u8, kind: lazer.RankingKind, country_filter: ?[]const u8, page: u16) ![]u8 {
        return pg_score_lazer.lazerRankingsJson(self, allocator, ruleset_id, kind, country_filter, page);
    }
    const writeSiteScores = pg_score_stats.writeSiteScores;
    const readStatsHistoryWithConnection = pg_score_maintenance.readStatsHistoryWithConnection;
    const pruneStatsHistoryWithConnection = pg_score_maintenance.pruneStatsHistoryWithConnection;
    const recordStatsHistorySliceCurrentWithConnection = pg_score_maintenance.recordStatsHistorySliceCurrentWithConnection;
    const statsHistoryUserVisibleWithConnection = pg_score_maintenance.statsHistoryUserVisibleWithConnection;
    pub fn statsHistory(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !domain.StatsHistory {
        return pg_score_maintenance.statsHistory(self, user_id, source, stats_mode);
    }
    const recordAllStatsHistoryCurrentWithConnection = pg_score_maintenance.recordAllStatsHistoryCurrentWithConnection;
    const recordBeatmapStatsHistoryCurrentWithConnection = pg_score_maintenance.recordBeatmapStatsHistoryCurrentWithConnection;
    pub fn refreshStatsHistory(self: *Store) !void {
        return pg_score_maintenance.refreshStatsHistory(self);
    }
    pub fn siteProfile(self: *Store, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
        return pg_score_stats.siteProfile(self, allocator, user_id, source, stats_mode);
    }
    pub fn siteProfileForViewer(self: *Store, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8, owner_view: bool) !?[]u8 {
        return pg_score_stats.siteProfileForViewer(self, allocator, user_id, source, stats_mode, owner_view);
    }
    pub fn siteBeatmapLeaderboard(self: *Store, allocator: std.mem.Allocator, map_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
        return pg_score_stats.siteBeatmapLeaderboard(self, allocator, map_id, source, stats_mode);
    }
    const replayData = pg_score_replays.replayData;
    pub fn siteReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        return pg_score_replays.siteReplay(self, allocator, score_id);
    }
    pub fn lazerReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        return pg_score_replays.lazerReplay(self, allocator, score_id);
    }
    pub fn lazerUserScoreCounts(self: *Store, user_id: i32, ruleset_id: u8, source: domain.SiteScoreSource) !domain.UserScoreCounts {
        return pg_score_lazer.lazerUserScoreCounts(self, user_id, ruleset_id, source);
    }
    pub fn lazerRecentActivityJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, offset: u16, limit: u8) ![]u8 {
        return pg_score_lazer.lazerRecentActivityJson(self, allocator, user_id, offset, limit);
    }
    pub fn lazerUserScoresJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8, kind: lazer.UserScoreKind, source: domain.SiteScoreSource, offset: u16, limit: u8) ![]u8 {
        return pg_score_lazer.lazerUserScoresJson(self, allocator, user_id, ruleset_id, kind, source, offset, limit);
    }
    const stableClassicLeaderboardJson = pg_score_stable.stableClassicLeaderboardJson;
    pub fn lazerLeaderboardJson(self: *Store, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, exact_mods_json: []const u8, filter_mods: bool, classic: bool, requested_stable_mods: ?i32, scope: lazer.LeaderboardScope, limit: u8) ![]u8 {
        return pg_score_lazer.lazerLeaderboardJson(self, allocator, requester_id, beatmap_id, ruleset_id, namespace, exact_mods_json, filter_mods, classic, requested_stable_mods, scope, limit);
    }
    pub fn lazerScoreJson(self: *Store, allocator: std.mem.Allocator, score_id: i64, beatmap_id: i32) !?[]u8 {
        return pg_score_lazer.lazerScoreJson(self, allocator, score_id, beatmap_id);
    }
    const awardAchievementsWithConnection = pg_score_achievements.awardAchievementsWithConnection;
    const writeUserAchievementsWithConnection = pg_score_achievements.writeUserAchievementsWithConnection;
    pub fn lazerUserAchievementsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
        return pg_score_achievements.lazerUserAchievementsJson(self, allocator, user_id);
    }
    pub fn newAchievementsForScore(self: *Store, source: []const u8, score_id: i64) !achievements.Unlocks {
        return pg_score_achievements.newAchievementsForScore(self, source, score_id);
    }
    pub fn insertLazerScore(self: *Store, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        return pg_score_lazer.insertLazerScore(self, user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
    }
    const insertLazerScoreWithConnection = pg_score_lazer.insertLazerScoreWithConnection;
    const updateLazerStatsWithConnection = pg_score_lazer.updateLazerStatsWithConnection;
    const rebuildCombinedPerformanceWithConnection = pg_score_maintenance.rebuildCombinedPerformanceWithConnection;
    pub fn isLazerRoomScoreToken(token_id: i64) bool {
        return pg_score_lazer.isLazerRoomScoreToken(token_id);
    }
    pub fn createLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
        return pg_score_lazer.createLazerScoreToken(self, user_id, beatmap_id, beatmap_hash, ruleset_id, version_hash);
    }
    pub fn createLazerRoomScoreToken(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
        return pg_score_lazer.createLazerRoomScoreToken(self, user_id, beatmap_id, beatmap_hash, ruleset_id, version_hash);
    }
    pub fn discardUnusedLazerRoomScoreToken(self: *Store, user_id: i32, token_id: i64) !bool {
        return pg_score_lazer.discardUnusedLazerRoomScoreToken(self, user_id, token_id);
    }
    const createLazerScoreTokenScoped = pg_score_lazer.createLazerScoreTokenScoped;
    pub fn submitLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        return pg_score_lazer.submitLazerScoreToken(self, user_id, beatmap_id, token_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
    }
    pub fn submitLazerRoomScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        return pg_score_lazer.submitLazerRoomScoreToken(self, user_id, beatmap_id, token_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
    }
    const submitLazerScoreTokenScoped = pg_score_lazer.submitLazerScoreTokenScoped;
    pub fn statsForUser(self: *Store, user_id: i32, mode: u8) !?domain.Stats {
        return pg_score_stats.statsForUser(self, user_id, mode);
    }
    pub fn banchoStatsBatch(self: *Store, allocator: std.mem.Allocator, requests: []const storage_contracts.BanchoStatsRequest) ![]storage_contracts.BanchoStats {
        return @import("storage/postgres/scores/bancho_stats.zig").read(self, allocator, requests);
    }
    pub fn statsRulesetsForUser(self: *Store, user_id: i32) ![4]?domain.Stats {
        return pg_score_stats.statsRulesetsForUser(self, user_id);
    }
    pub fn sourceStatsForUser(self: *Store, user_id: i32, mode: u8, source: domain.SiteScoreSource) !?domain.Stats {
        return pg_score_stats.sourceStatsForUser(self, user_id, mode, source);
    }
    pub fn beatmapForScore(self: *Store, md5: []const u8) !?BeatmapForScore {
        return pg_score_stats.beatmapForScore(self, md5);
    }
    pub fn scoreLeaderboardPlacement(self: *Store, score_id: i64) !?domain.ScorePlacement {
        return pg_score_stats.scoreLeaderboardPlacement(self, score_id);
    }
    pub fn lazerScoreLeaderboardPlacement(self: *Store, score_id: i64) !?domain.ScorePlacement {
        return pg_score_lazer.lazerScoreLeaderboardPlacement(self, score_id);
    }
    pub fn beatmapInfo(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?BeatmapInfo {
        return pg_score_stats.beatmapInfo(self, allocator, md5);
    }
    pub fn beatmapInfoById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?BeatmapInfo {
        return pg_score_stats.beatmapInfoById(self, allocator, map_id);
    }
    pub fn insertStableScore(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !i64 {
        return pg_score_stable.insertStableScore(self, user_id, score, pp_value, replay_data, time_elapsed_ms);
    }
    pub fn insertStableScoreWithChart(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !domain.StableScoreInsert {
        return pg_score_stable.insertStableScoreWithChart(self, user_id, score, pp_value, replay_data, time_elapsed_ms);
    }
    pub fn stableReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        return pg_score_replays.stableReplay(self, allocator, score_id);
    }
    pub fn putScreenshot(self: *Store, user_id: i32, token: []const u8, extension: []const u8, image: []const u8) !bool {
        return pg_score_replays.putScreenshot(self, user_id, token, extension, image);
    }
    pub fn screenshot(self: *Store, allocator: std.mem.Allocator, token: []const u8, extension: []const u8) !?[]u8 {
        return pg_score_replays.screenshot(self, allocator, token, extension);
    }
    pub fn ppSnapshot(self: *Store, score_id: i64) !?PpSnapshot {
        return pg_score_stats.ppSnapshot(self, score_id);
    }
    pub fn issueToken(self: *Store, user_id: i32, scopes: []const u8, lifetime_seconds: i64) ![64]u8 {
        return pg_accounts.issueToken(self, user_id, scopes, lifetime_seconds);
    }
    pub fn issueGameTokenPair(self: *Store, user_id: i32, access_lifetime_seconds: i64, refresh_lifetime_seconds: i64, replace_existing: bool) !GameTokenPair {
        return pg_accounts.issueGameTokenPair(self, user_id, access_lifetime_seconds, refresh_lifetime_seconds, replace_existing);
    }
    pub fn rotateGameTokenPair(self: *Store, allocator: std.mem.Allocator, refresh_token: []const u8, access_lifetime_seconds: i64, refresh_lifetime_seconds: i64) !?GameTokenRefresh {
        return pg_accounts.rotateGameTokenPair(self, allocator, refresh_token, access_lifetime_seconds, refresh_lifetime_seconds);
    }
    pub fn authenticateToken(self: *Store, allocator: std.mem.Allocator, token: []const u8, required_scope: []const u8) !?domain.User {
        return pg_accounts.authenticateToken(self, allocator, token, required_scope);
    }
    pub fn consumeGameRefreshToken(self: *Store, allocator: std.mem.Allocator, token: []const u8) !?domain.User {
        return pg_accounts.consumeGameRefreshToken(self, allocator, token);
    }
    pub fn recentOauthUserIds(self: *Store, allocator: std.mem.Allocator, cutoff: i64) ![]i32 {
        return pg_accounts.recentOauthUserIds(self, allocator, cutoff);
    }
    pub fn lazerUserOnline(self: *Store, user_id: i32, cutoff: i64) !bool {
        return pg_accounts.lazerUserOnline(self, user_id, cutoff);
    }
    pub fn setLazerActivityForToken(self: *Store, token: []const u8, expected_user_id: i32, status: []const u8, detail: []const u8, beatmap_id: ?i32, ruleset_id: ?u8) !bool {
        return pg_accounts.setLazerActivityForToken(self, token, expected_user_id, status, detail, beatmap_id, ruleset_id);
    }
    pub fn clearLazerActivityForToken(self: *Store, token: []const u8, expected_user_id: i32) !bool {
        return pg_accounts.clearLazerActivityForToken(self, token, expected_user_id);
    }
    pub fn lazerActivity(self: *Store, allocator: std.mem.Allocator, user_id: i32, cutoff: i64) !?domain.LazerActivity {
        return pg_accounts.lazerActivity(self, allocator, user_id, cutoff);
    }
    pub fn revokeToken(self: *Store, token: []const u8) !bool {
        return pg_accounts.revokeToken(self, token);
    }
    pub fn revokeGameTokensForUser(self: *Store, user_id: i32) !usize {
        return pg_accounts.revokeGameTokensForUser(self, user_id);
    }
    pub fn revokeAllGameCredentialsForUser(self: *Store, user_id: i32) !usize {
        return pg_accounts.revokeAllGameCredentialsForUser(self, user_id);
    }
    pub fn revokeLazerAccessTokensForUser(self: *Store, user_id: i32) !usize {
        return pg_accounts.revokeLazerAccessTokensForUser(self, user_id);
    }
};
