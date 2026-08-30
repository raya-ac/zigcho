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

const Context = @import("../http/context.zig").Context;
const Result = @import("result.zig").Result;
const primitives = @import("../http/primitives.zig");
const support = @import("../support.zig");
const lifecycle = @import("../lifecycle.zig");

const header = primitives.header;
const respond = primitives.respond;
const respondWithoutContinue = primitives.respondWithoutContinue;
const rejectStableScore = primitives.rejectStableScore;
const rejectStableScoreError = primitives.rejectStableScoreError;
const field = primitives.field;
const queryField = primitives.queryField;
const beatmapSearchOffset = primitives.beatmapSearchOffset;
const userPathWithSuffix = primitives.userPathWithSuffix;
const userBeatmapsetPath = primitives.userBeatmapsetPath;
const beatmapTagPath = primitives.beatmapTagPath;
const lazerRulesetId = primitives.lazerRulesetId;
const isAvatarHost = primitives.isAvatarHost;
const isAssetsHost = primitives.isAssetsHost;
const isBeatmapMirrorHost = primitives.isBeatmapMirrorHost;
const isBssHost = primitives.isBssHost;
const bssStorageFailure = primitives.bssStorageFailure;
const isLocalMetricsHost = primitives.isLocalMetricsHost;
const avatarUserId = primitives.avatarUserId;

const freeUser = support.freeUser;
const rollbackFailedLazerLogin = support.rollbackFailedLazerLogin;
const randomMessageUuid = support.randomMessageUuid;
const parseWebsiteRoomPath = support.parseWebsiteRoomPath;
const parseTeamPath = support.parseTeamPath;
const parsePinPath = support.parsePinPath;
const ppNamespace = support.ppNamespace;
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
const StaffPpPreviewRequest = support.StaffPpPreviewRequest;

fn dispatch(self: anytype, req: *std.http.Server.Request, ctx: *const Context) !void {
    const path = ctx.path;
    const content_type_owned = ctx.content_type_owned;
    const body = ctx.body;
    if (std.mem.eql(u8, path, "/users") and req.head.method == .POST) {
        const check = try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"check"});
        defer if (check) |value| self.allocator.free(value);
        const stable_registration = check != null;
        const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "name", "user[username]" })) orelse return respond(req, .bad_request, if (stable_registration) "text/plain" else "application/json", if (stable_registration) "Missing required params" else "{\"error\":\"name required\"}", &.{});
        defer self.allocator.free(name);
        const email = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "email", "user[user_email]" })) orelse if (stable_registration) return respond(req, .bad_request, "text/plain", "Missing required params", &.{}) else try self.allocator.dupe(u8, "");
        defer self.allocator.free(email);
        const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "password_md5", "user[password]" })) orelse return respond(req, .bad_request, if (stable_registration) "text/plain" else "application/json", if (stable_registration) "Missing required params" else "{\"error\":\"password required\"}", &.{});
        defer self.allocator.free(password);
        if (check) |check_value| {
            const result = registration.stableRequest(&self.store, name, email, password, check_value) catch |err| return respond(req, if (err == error.InvalidCheck) .bad_request else .internal_server_error, "text/plain", if (err == error.InvalidCheck) "Invalid check value" else "registration failed", &.{});
            switch (result) {
                .ok => return respond(req, .ok, "text/plain", "ok", &.{}),
                .validation_failed => |validation| {
                    var error_buffer: [768]u8 = undefined;
                    const error_json = try registration.writeStableErrors(&error_buffer, validation);
                    return respond(req, .bad_request, "application/json", error_json, &.{});
                },
            }
        }
        const password_md5 = form_urlencoded.credentialMd5(password) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid fields\"}", &.{});
        if (!registration.validUsername(name) or !registration.validEmail(email) or !registration.validCredential(password)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid fields\"}", &.{});
        const id = self.store.register(name, email, &password_md5) catch |err| return respond(req, if (err == error.UserExists) .conflict else .internal_server_error, "application/json", "{\"error\":\"registration failed\"}", &.{});
        var out: [256]u8 = undefined;
        const json = try user_json.registration(&out, id, name);
        return respond(req, .created, "application/json", json, &.{});
    }
    if (std.mem.eql(u8, path, "/oauth/token") and req.head.method == .POST) {
        const grant = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"grant_type"})) orelse try self.allocator.dupe(u8, "password");
        defer self.allocator.free(grant);
        if (std.mem.eql(u8, grant, "refresh_token")) {
            const refresh = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"refresh_token"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            defer self.allocator.free(refresh);
            const owner = (try self.store.authenticateToken(self.allocator, refresh, "")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
            defer freeUser(self.allocator, owner);
            const mutex = self.gameSessionMutex(owner.id);
            mutex.lockUncancelable(self.store.io);
            defer mutex.unlock(self.store.io);
            const rotated = (try self.store.rotateGameTokenPair(self.allocator, refresh, lazer_access_lifetime_seconds, lazer_refresh_lifetime_seconds)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
            defer freeUser(self.allocator, rotated.user);
            if (rotated.user.id != owner.id) return error.TokenOwnerChanged;
            return self.respondLazerOAuthTokens(req, rotated.tokens);
        }
        if (!std.mem.eql(u8, grant, "password")) return respond(req, .bad_request, "application/json", "{\"error\":\"unsupported_grant_type\"}", &.{});
        const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
        defer self.allocator.free(name);
        const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "password_md5", "password" })) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
        defer self.allocator.free(password);
        const password_md5 = form_urlencoded.credentialMd5(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
        const existing = (try self.store.userByName(self.allocator, name)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
        const user_id = existing.id;
        freeUser(self.allocator, existing);
        const mutex = self.gameSessionMutex(user_id);
        mutex.lockUncancelable(self.store.io);
        defer mutex.unlock(self.store.io);
        const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.id != user_id) return error.LoginUserChanged;
        const tokens = try self.issueLazerOAuthTokens(user.id, true);
        errdefer rollbackFailedLazerLogin(self.allocator, &self.store, &self.sessions, user.id, tokens);
        try self.takeOverGameSessionsLocked(user.id, "lazer");
        try bancho.publishLazerPresence(self.allocator, &self.store, &self.sessions, user);
        return self.respondLazerOAuthTokens(req, tokens);
    }
    if (std.mem.eql(u8, path, "/oauth/revoke") and req.head.method == .POST) {
        const token = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"token"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
        defer self.allocator.free(token);
        // Revocation accepts either half of a game-token pair. Resolve the
        // owner without imposing the bearer-only `identify` scope so a
        // refresh-token logout also removes its published presence.
        const user = try self.store.authenticateToken(self.allocator, token, "");
        defer if (user) |value| freeUser(self.allocator, value);
        if (user) |value| {
            const mutex = self.gameSessionMutex(value.id);
            mutex.lockUncancelable(self.store.io);
            defer mutex.unlock(self.store.io);
            const revoked = try self.store.revokeToken(token);
            if (!revoked) return respond(req, .ok, "application/json", "{}", &.{});
            const cutoff = std.Io.Clock.real.now(self.store.io).toSeconds() - 120;
            if (!try self.store.lazerUserOnline(value.id, cutoff)) {
                _ = self.lazer_multiplayer.disconnectUser(value.id);
                _ = self.lazer_spectator.disconnectUser(value.id);
                try bancho.publishLazerLogout(self.allocator, &self.sessions, value.id);
            }
        } else _ = try self.store.revokeToken(token);
        return respond(req, .ok, "application/json", "{}", &.{});
    }
    return error.UnmatchedRouteStage;
}

pub fn handle(self: anytype, req: *std.http.Server.Request, ctx: *const Context) !Result {
    dispatch(self, req, ctx) catch |err| return switch (err) {
        error.UnmatchedRouteStage => .unmatched,
        else => err,
    };
    return .handled;
}
