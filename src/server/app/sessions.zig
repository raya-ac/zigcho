const d = @import("../deps.zig");
const std = d.std;
const builtin = d.builtin;
const domain = d.domain;
const storage = d.storage;
const sqlite_storage = d.sqlite_storage;
const sessions_mod = d.sessions_mod;
const bancho = d.bancho;
const lazer = d.lazer;
const lazer_bot = d.lazer_bot;
const lazer_multiplayer = d.lazer_multiplayer;
const lazer_notifications = d.lazer_notifications;
const lazer_spectator = d.lazer_spectator;
const multipart = d.multipart;
const score_crypto = d.score_crypto;
const stable_score = d.stable_score;
const stable_mods = d.stable_mods;
const stable_response = d.stable_response;
const server_control = d.server_control;
const server_control_route = d.server_control_route;
const account_roles = d.account_roles;
const achievements = d.achievements;
const changelog = d.changelog;
const lazer_wiki = d.lazer_wiki;
const rate_limit = d.rate_limit;
const pp = d.pp;
const pp_admin = d.pp_admin;
const screenshot = d.screenshot;
const index_page = d.index_page;
const form_urlencoded = d.form_urlencoded;
const registration = d.registration;
const routing = d.routing;
const beatmap_sync = d.beatmap_sync;
const beatmap_media = d.beatmap_media;
const bss = d.bss;
const irc = d.irc;
const media_contract = d.media_contract;
const webhook = d.webhook;
const protocol = d.protocol;
const country = d.country;
const log = d.log;
const config_mod = d.config_mod;
const web_auth = d.web_auth;
const proxy = d.proxy;
const user_json = d.user_json;
const upstream_user = d.upstream_user;
const profile_avatar = d.profile_avatar;
const profile_banner = d.profile_banner;
const team_image = d.team_image;
const avatar_cache = d.avatar_cache;
const r2 = d.r2;
const object_keys = d.object_keys;
const anticheat_abi = d.anticheat_abi;
const anticheat_evidence = d.anticheat_evidence;
const anticheat_plugin = d.anticheat_plugin;
const anticheat_replay = d.anticheat_replay;
const player_routes = d.player_routes;
const http_boundary = d.http_boundary;
const stable_score_auth = d.stable_score_auth;
const stable_login = d.stable_login;
const default_avatar_1 = d.default_avatar_1;
const default_avatar_2 = d.default_avatar_2;
const lazer_access_lifetime_seconds = d.lazer_access_lifetime_seconds;
const lazer_refresh_lifetime_seconds = d.lazer_refresh_lifetime_seconds;

const support = @import("../support.zig");
const primitives = @import("../http/primitives.zig");
const respond = primitives.respond;
const header = primitives.header;
const freeUser = support.freeUser;
const rollbackFailedLazerLogin = support.rollbackFailedLazerLogin;
const randomMessageUuid = support.randomMessageUuid;
const parseWebsiteRoomPath = support.parseWebsiteRoomPath;
const parseTeamPath = support.parseTeamPath;
const parsePinPath = support.parsePinPath;
const ppNamespace = support.ppNamespace;
const lazerPpNamespace = support.lazerPpNamespace;
const staffPpComparisonJson = support.staffPpComparisonJson;
const lazerPerformance = support.lazerPerformance;
const intLines = support.intLines;
const validWebText = support.validWebText;
const validWebLine = support.validWebLine;
const validProfileWebsite = support.validProfileWebsite;
const stableClientPrivileges = support.stableClientPrivileges;
const scoreLog = support.scoreLog;
const announceScore = support.announceScore;
const announceLazerScore = support.announceLazerScore;
const game_session_lock_count = 64;

pub fn userOnline(self: anytype, user_id: i32) bool {
    self.sessions.mutex.lockUncancelable(self.sessions.io);
    defer self.sessions.mutex.unlock(self.sessions.io);
    return self.sessions.onlineByUser(user_id) != null;
}

pub fn userOnlineCombined(self: anytype, user_id: i32) !bool {
    if (user_id == 3 or self.userOnline(user_id)) return true;
    const cutoff = std.Io.Clock.real.now(self.store.io).toSeconds() - 120;
    return self.store.lazerUserOnline(user_id, cutoff);
}

pub fn markOnline(self: anytype, user: *domain.User) !void {
    user.online = try self.userOnlineCombined(user.id);
}

pub fn ensureMapperForSet(self: anytype, set_id: i32) void {
    _ = self.map_sync.ensureMapperProfile(&self.store, set_id) catch |err| switch (err) {
        error.OsuApiNotConfigured, error.UpstreamUserNotFound => {},
        else => std.log.warn("event=beatmap_mapper_profile_failed set_id={d} error={t}", .{ set_id, err }),
    };
}

pub fn ensureMapperForMap(self: anytype, beatmap_id: i32) void {
    const set_id = self.store.beatmapSetIdForMap(beatmap_id) catch |err| {
        std.log.warn("event=beatmap_mapper_lookup_failed beatmap_id={d} error={t}", .{ beatmap_id, err });
        return;
    };
    if (set_id) |id| self.ensureMapperForSet(id);
}

pub fn combinedOnlineCount(self: anytype) !usize {
    const cutoff = std.Io.Clock.real.now(self.store.io).toSeconds() - 120;
    const stable_ids = try self.sessions.onlineUserIds(self.allocator);
    defer self.allocator.free(stable_ids);
    const lazer_ids = try self.store.recentOauthUserIds(self.allocator, cutoff);
    defer self.allocator.free(lazer_ids);
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(self.allocator);
    try ids.ensureTotalCapacity(self.allocator, stable_ids.len + lazer_ids.len);
    for (stable_ids) |id| if (id != 3 and std.mem.indexOfScalar(i32, ids.items, id) == null) ids.appendAssumeCapacity(id);
    for (lazer_ids) |id| if (id != 3 and std.mem.indexOfScalar(i32, ids.items, id) == null) ids.appendAssumeCapacity(id);
    return ids.items.len;
}

pub fn staffInfrastructureJson(self: anytype) ![]u8 {
    const online = try self.combinedOnlineCount();
    self.sessions.mutex.lockUncancelable(self.sessions.io);
    const stable_online = self.sessions.humanCount();
    self.sessions.mutex.unlock(self.sessions.io);
    const cutoff = std.Io.Clock.real.now(self.store.io).toSeconds() - 120;
    const lazer_ids = try self.store.recentOauthUserIds(self.allocator, cutoff);
    defer self.allocator.free(lazer_ids);
    const counts = try self.store.serverCounts();
    const cache = try self.store.beatmapCacheStats();
    const media_cache = try self.store.beatmapMediaCacheStats();
    const hydration = self.map_sync.metrics();
    const media = self.media_sync.metrics();
    const multiplayer = self.lazer_multiplayer.runtimeCounts();
    const spectator_connections = self.lazer_spectator.connectionCount();
    const http_active = self.http_gate.active.load(.acquire);
    const http_rejected = self.http_gate.rejected.load(.acquire);
    const http_timed_out = self.http_gate.timed_out.load(.acquire);
    const controls = try self.store.staffServerControlsJson(self.allocator);
    defer self.allocator.free(controls);
    const uptime = @max(@as(i64, 0), std.Io.Clock.real.now(self.store.io).toSeconds() - self.started_at);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer output.deinit();
    try output.writer.print(
        "{{\"runtime\":{{\"uptime_seconds\":{d},\"online\":{d},\"stable_online\":{d},\"lazer_online\":{d},\"irc_connections\":{d},\"http_connections\":{d},\"http_connection_limit\":{d},\"http_rejected\":{d},\"http_timeouts\":{d},\"multiplayer_connections\":{d},\"multiplayer_rooms\":{d},\"multiplayer_queued\":{d},\"pending_matches\":{d},\"spectator_connections\":{d},\"anticheat_loaded\":{},\"anticheat_sample_modulus\":{d},\"restart_supported\":true}},",
        .{ uptime, online, stable_online, lazer_ids.len, self.irc_clients.load(.acquire), http_active, self.http_gate.limit, http_rejected, http_timed_out, multiplayer.connections, multiplayer.rooms, multiplayer.queued, multiplayer.pending_matches, spectator_connections, self.anticheat != null, self.anticheat_allow_sample_modulus },
    );
    try output.writer.print(
        "\"storage\":{{\"schema\":{d},\"users\":{d},\"plays\":{d},\"passed\":{d},\"maps\":{d},\"beatmap_cache_entries\":{d},\"beatmap_cache_bytes\":{d},\"media_cache_entries\":{d},\"media_cache_bytes\":{d},\"hydration_blocked\":{d}}},",
        .{ storage.schema_version, counts.users, counts.plays, counts.passed, counts.maps, cache.entries, cache.bytes, media_cache.entries, media_cache.bytes, cache.hydration_failures },
    );
    try output.writer.print(
        "\"pipeline\":{{\"hydration_attempts\":{d},\"hydration_successes\":{d},\"hydration_failures\":{d},\"mirror_hits\":{d},\"mirror_misses\":{d},\"mirror_fills\":{d},\"mirror_failures\":{d},\"mirror_bytes_served\":{d},\"media_attempts\":{d},\"media_successes\":{d},\"media_failures\":{d}}},\"state\":{s}}}",
        .{ hydration.attempts, hydration.successes, hydration.failures, hydration.mirror_hits, hydration.mirror_misses, hydration.mirror_fills, hydration.mirror_failures, hydration.mirror_bytes_served, media.attempts, media.successes, media.failures, controls },
    );
    return output.toOwnedSlice();
}

pub fn gameSessionMutex(self: anytype, user_id: i32) *std.Io.Mutex {
    std.debug.assert(user_id > 0);
    const index: usize = @intCast(@mod(user_id, game_session_lock_count));
    return &self.game_session_mutexes[index];
}

pub const DisconnectScope = enum { game, all };

pub fn finishDisconnectPrepared(self: anytype, user_id: i32, prepared: *bancho.PreparedSuppression) bool {
    const stable = bancho.suppressPrepared(&self.sessions, user_id, prepared);
    const multiplayer = self.lazer_multiplayer.disconnectUser(user_id);
    const spectator = self.lazer_spectator.disconnectUser(user_id);
    return stable or multiplayer or spectator;
}

pub fn disconnectUserLocked(self: anytype, user_id: i32, message: []const u8, scope: DisconnectScope) !bool {
    var prepared = try bancho.prepareSuppression(self.allocator, message);
    defer prepared.deinit();
    const revoked = switch (scope) {
        .game => if (comptime storage.is_postgres)
            try self.store.revokeAllGameCredentialsForUser(user_id)
        else
            try self.store.revokeGameTokensForUser(user_id),
        .all => try self.store.revokeAllTokensForUser(user_id),
    };
    return self.finishDisconnectPrepared(user_id, &prepared) or revoked != 0;
}

pub fn disconnectUser(self: anytype, user_id: i32, message: []const u8, scope: DisconnectScope) !bool {
    const mutex = self.gameSessionMutex(user_id);
    mutex.lockUncancelable(self.store.io);
    defer mutex.unlock(self.store.io);
    return self.disconnectUserLocked(user_id, message, scope);
}

/// The caller owns the per-user game-session mutex across authentication's
/// commit point, token issuance, takeover and presence publication.
pub fn takeOverGameSessionsLocked(self: anytype, user_id: i32, entering_client: []const u8) !void {
    if (std.mem.eql(u8, entering_client, "stable")) {
        _ = try self.store.revokeGameTokensForUser(user_id);
        bancho.forgetLazerPresence(&self.sessions, user_id);
    }
    _ = self.lazer_multiplayer.disconnectUser(user_id);
    _ = self.lazer_spectator.disconnectUser(user_id);
    if (std.mem.eql(u8, entering_client, "lazer")) {
        if (comptime storage.is_postgres) _ = try self.store.revokeStableScoreSessionsForUser(user_id);
        _ = try bancho.suppressForTakeover(self.allocator, &self.sessions, user_id, "This account signed in from lazer, so this client has been disconnected.");
    }
    std.log.info("event=cross_client_session_takeover user_id={d} entering_client={s}", .{ user_id, entering_client });
}

pub fn activateStableLoginLocked(self: anytype, result: *const bancho.LoginResult) !void {
    if (result.user_id <= 0) return;
    if (comptime storage.is_postgres) {
        const binding = result.client_binding orelse return error.StableLoginClientBindingMissing;
        const now = std.Io.Clock.real.now(self.store.io).toSeconds();
        try self.store.rotateStableScoreSession(result.user_id, result.token, binding, now, stable_score_auth.grace_lifetime_seconds);
        errdefer _ = self.store.revokeStableScoreSessionsForUser(result.user_id) catch |err| {
            std.log.err("event=stable_login_activation_compensation_failed user_id={d} error={t}", .{ result.user_id, err });
        };
        try self.takeOverGameSessionsLocked(result.user_id, "stable");
    } else try self.takeOverGameSessionsLocked(result.user_id, "stable");
}

pub fn stableLoginAndTakeover(self: anytype, body: []const u8, login_country: ?[2]u8, longitude: f32, latitude: f32) !bancho.LoginResult {
    const name = stable_login.username(body);
    const existing = if (name.len == 0) null else try self.store.userByName(self.allocator, name);
    if (existing) |user| {
        const user_id = user.id;
        freeUser(self.allocator, user);
        const mutex = self.gameSessionMutex(user_id);
        mutex.lockUncancelable(self.store.io);
        defer mutex.unlock(self.store.io);
        var result = try bancho.loginExpectedUser(self.allocator, &self.store, &self.sessions, body, login_country, longitude, latitude, user_id);
        errdefer result.deinit();
        self.activateStableLoginLocked(&result) catch |err| {
            _ = bancho.rollbackLogin(self.allocator, &self.sessions, result.user_id, result.token);
            return err;
        };
        return result;
    }

    // A registration can commit between the lookup and authentication.
    // If that rare race succeeds, discard its unguarded session and repeat
    // the login under the newly known user's transition lock.
    var first = try bancho.login(self.allocator, &self.store, &self.sessions, body, login_country, longitude, latitude);
    if (first.user_id <= 0) return first;
    const user_id = first.user_id;
    _ = bancho.rollbackLogin(self.allocator, &self.sessions, user_id, first.token);
    first.deinit();
    const mutex = self.gameSessionMutex(user_id);
    mutex.lockUncancelable(self.store.io);
    defer mutex.unlock(self.store.io);
    var result = try bancho.loginExpectedUser(self.allocator, &self.store, &self.sessions, body, login_country, longitude, latitude, user_id);
    errdefer result.deinit();
    self.activateStableLoginLocked(&result) catch |err| {
        _ = bancho.rollbackLogin(self.allocator, &self.sessions, result.user_id, result.token);
        return err;
    };
    return result;
}

pub fn issueLazerOAuthTokens(self: anytype, user_id: i32, replace_existing: bool) !storage.Store.GameTokenPair {
    return self.store.issueGameTokenPair(user_id, lazer_access_lifetime_seconds, lazer_refresh_lifetime_seconds, replace_existing);
}

pub fn respondLazerOAuthTokens(_: anytype, req: *std.http.Server.Request, tokens: storage.Store.GameTokenPair) !void {
    var out: [384]u8 = undefined;
    const json = try std.fmt.bufPrint(&out, "{{\"token_type\":\"Bearer\",\"expires_in\":{d},\"scope\":\"identify scores:write\",\"access_token\":\"{s}\",\"refresh_token\":\"{s}\"}}", .{ lazer_access_lifetime_seconds, &tokens.access, &tokens.refresh });
    const token_headers = [_]std.http.Header{
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "pragma", .value = "no-cache" },
    };
    return respond(req, .ok, "application/json", json, &token_headers);
}
