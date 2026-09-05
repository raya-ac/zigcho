const d = @import("deps.zig");
const std = d.std;
const storage = d.storage;
const sessions_mod = d.sessions_mod;
const lazer_bot = d.lazer_bot;
const lazer_multiplayer = d.lazer_multiplayer;
const lazer_spectator = d.lazer_spectator;
const rate_limit = d.rate_limit;
const beatmap_sync = d.beatmap_sync;
const beatmap_media = d.beatmap_media;
const webhook = d.webhook;
const anticheat_plugin = d.anticheat_plugin;
const r2 = d.r2;
const avatar_cache = d.avatar_cache;
const changelog = d.changelog;
const http_boundary = d.http_boundary;
const HttpGate = http_boundary.Gate;

const anticheat = @import("app/anticheat.zig");
const sessions = @import("app/sessions.zig");
const lazer_support = @import("app/lazer.zig");
const control = @import("app/control.zig");
const primitives = @import("http/primitives.zig");
const router = @import("http/router.zig");

const game_session_lock_count = 64;

pub const App = struct {
    allocator: std.mem.Allocator,
    store: storage.Store,
    sessions: sessions_mod.Sessions,
    lazer_bot: lazer_bot.Manager,
    lazer_multiplayer: lazer_multiplayer.Manager,
    lazer_spectator: lazer_spectator.Manager,
    limiter: rate_limit.Limiter,
    map_sync: beatmap_sync.Sync,
    media_sync: beatmap_media.Sync,
    score_webhook: webhook.Webhook,
    anticheat: ?anticheat_plugin.Host,
    anticheat_allow_sample_modulus: u32,
    avatar_store: r2.Storage,
    avatar_cache: avatar_cache.Cache,
    geo_client: std.http.Client,
    geo_gate: HttpGate = .init(@import("http/geolocation.zig").max_concurrent),
    changelog_feed: changelog.Feed,
    started_at: i64,
    irc_clients: std.atomic.Value(u32) = .init(0),
    http_gate: HttpGate,
    http_header_timeout_seconds: u16,
    http_request_timeout_seconds: u16,
    http_long_request_timeout_seconds: u16,
    game_session_mutexes: [game_session_lock_count]std.Io.Mutex = [_]std.Io.Mutex{.init} ** game_session_lock_count,
    server_control_mutex: std.Io.Mutex = .init,

    pub const anticheatNamespace = anticheat.anticheatNamespace;
    pub const stableScoreEvidence = anticheat.stableScoreEvidence;
    pub const stableGameplayEvidence = anticheat.stableGameplayEvidence;
    pub const persistHostAnticheatObservation = anticheat.persistHostAnticheatObservation;
    pub const observeStableSignal = anticheat.observeStableSignal;
    pub const observeStableLogin = anticheat.observeStableLogin;
    pub const observeStableLastFmFlags = anticheat.observeStableLastFmFlags;
    pub const StableGameplayObservation = anticheat.StableGameplayObservation;
    pub const observeStableGameplay = anticheat.observeStableGameplay;
    pub const persistAnticheatObservation = anticheat.persistAnticheatObservation;
    pub const userOnline = sessions.userOnline;
    pub const userOnlineCombined = sessions.userOnlineCombined;
    pub const markOnline = sessions.markOnline;
    pub const ensureMapperForSet = sessions.ensureMapperForSet;
    pub const ensureMapperForMap = sessions.ensureMapperForMap;
    pub const combinedOnlineCount = sessions.combinedOnlineCount;
    pub const staffInfrastructureJson = sessions.staffInfrastructureJson;
    pub const gameSessionMutex = sessions.gameSessionMutex;
    pub const DisconnectScope = sessions.DisconnectScope;
    pub const finishDisconnectPrepared = sessions.finishDisconnectPrepared;
    pub const disconnectUserLocked = sessions.disconnectUserLocked;
    pub const disconnectUser = sessions.disconnectUser;
    pub const takeOverGameSessionsLocked = sessions.takeOverGameSessionsLocked;
    pub const activateStableLoginLocked = sessions.activateStableLoginLocked;
    pub const stableLoginAndTakeover = sessions.stableLoginAndTakeover;
    pub const issueLazerOAuthTokens = sessions.issueLazerOAuthTokens;
    pub const respondLazerOAuthTokens = sessions.respondLazerOAuthTokens;
    pub const stableActionName = lazer_support.stableActionName;
    pub const profilePresenceJson = lazer_support.profilePresenceJson;
    pub const attachProfilePresence = lazer_support.attachProfilePresence;
    pub const afterLazerScore = lazer_support.afterLazerScore;
    pub const lazerScoreResponse = lazer_support.lazerScoreResponse;
    pub const lazerRoomScoreDetailJson = lazer_support.lazerRoomScoreDetailJson;
    pub const broadcastLazerChatToStable = lazer_support.broadcastLazerChatToStable;
    pub const deliverDirectMessageToStable = lazer_support.deliverDirectMessageToStable;
    pub const lazerUser = lazer_support.lazerUser;
    pub const websiteViewerId = lazer_support.websiteViewerId;
    pub const recordReplayViewBestEffort = lazer_support.recordReplayViewBestEffort;
    pub const lazerStats = lazer_support.lazerStats;
    pub const lazerPresenceJson = lazer_support.lazerPresenceJson;
    pub const recordLazerBotReply = lazer_support.recordLazerBotReply;
    pub const friendRelationsJson = lazer_support.friendRelationsJson;
    pub const blockRelationsJson = lazer_support.blockRelationsJson;
    pub const friendMutationJson = lazer_support.friendMutationJson;
    pub const favouriteSetsJson = lazer_support.favouriteSetsJson;
    pub const featureUnavailable = control.featureUnavailable;
    pub const setFeatureControl = control.setFeatureControl;
    pub const requestRule = control.requestRule;
    pub const bodyLimit = control.bodyLimit;
    pub const header = primitives.header;
    pub const respond = primitives.respond;
    pub const respondWithoutContinue = primitives.respondWithoutContinue;
    pub const serveObjectImage = primitives.serveObjectImage;
    pub const serveBeatmapArchive = primitives.serveBeatmapArchive;
    pub const GeoResult = primitives.GeoResult;
    pub const lookupGeo = primitives.lookupGeo;
    pub const rejectStableScore = primitives.rejectStableScore;
    pub const rejectStableScoreError = primitives.rejectStableScoreError;
    pub const field = primitives.field;
    pub const queryField = primitives.queryField;
    pub const beatmapSearchOffset = primitives.beatmapSearchOffset;
    pub const UserBeatmapsetPath = primitives.UserBeatmapsetPath;
    pub const BeatmapTagPath = primitives.BeatmapTagPath;
    pub const userPathWithSuffix = primitives.userPathWithSuffix;
    pub const userBeatmapsetPath = primitives.userBeatmapsetPath;
    pub const beatmapTagPath = primitives.beatmapTagPath;
    pub const lazerRulesetId = primitives.lazerRulesetId;
    pub const isAvatarHost = primitives.isAvatarHost;
    pub const isAssetsHost = primitives.isAssetsHost;
    pub const isBeatmapMirrorHost = primitives.isBeatmapMirrorHost;
    pub const isBssHost = primitives.isBssHost;
    pub const bssStorageFailure = primitives.bssStorageFailure;
    pub const storeBssMedia = primitives.storeBssMedia;
    pub const isLocalMetricsHost = primitives.isLocalMetricsHost;
    pub const avatarUserId = primitives.avatarUserId;
    pub const serve = router.serve;
    pub const bssPathForRequest = router.bssPathForRequest;
};
