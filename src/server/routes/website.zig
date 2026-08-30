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
const requestServerRestart = lifecycle.requestRestart;

fn dispatch(self: anytype, req: *std.http.Server.Request, ctx: *const Context) !void {
    const target = ctx.target;
    const path = ctx.path;
    const auth_owned = ctx.auth_owned;
    const content_type_owned = ctx.content_type_owned;
    const host_owned = ctx.host_owned;
    const cookie_owned = ctx.cookie_owned;
    const csrf_owned = ctx.csrf_owned;
    const origin_owned = ctx.origin_owned;
    const body = ctx.body;
    if (std.mem.eql(u8, path, "/api/v1/appeals")) {
        const no_store = [_]std.http.Header{
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "pragma", .value = "no-cache" },
        };
        if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        if (!web_auth.sameOrigin(origin_owned, host_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid origin\"}", &no_store);
        const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"username required\"}", &no_store);
        defer self.allocator.free(name);
        const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"password"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"password required\"}", &no_store);
        defer self.allocator.free(password);
        const kind = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"kind"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"appeal kind required\"}", &no_store);
        defer self.allocator.free(kind);
        const message = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"appeal message required\"}", &no_store);
        defer self.allocator.free(message);
        if ((!std.mem.eql(u8, kind, "restriction") and !std.mem.eql(u8, kind, "hwid")) or !validWebText(message, 20, 2000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid appeal\"}", &no_store);
        const password_md5 = web_auth.passwordCredential(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
        const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
        defer freeUser(self.allocator, user);
        if (!user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"this account is not restricted\"}", &no_store);
        const appeal_id = self.store.createModerationAppeal(user.id, kind, std.mem.trim(u8, message, " \t\r\n")) catch |err| return respond(req, if (err == error.AppealAlreadyOpen) .conflict else .internal_server_error, "application/json", if (err == error.AppealAlreadyOpen) "{\"error\":\"an appeal of this type is already open\"}" else "{\"error\":\"appeal could not be saved\"}", &no_store);
        std.log.info("event=appeal_submitted appeal_id={d} user_id={d} kind={s}", .{ appeal_id, user.id, kind });
        var response_buf: [64]u8 = undefined;
        const response_json = try std.fmt.bufPrint(&response_buf, "{{\"ok\":true,\"id\":{d}}}", .{appeal_id});
        return respond(req, .created, "application/json", response_json, &no_store);
    }
    if (std.mem.eql(u8, path, "/api/v1/session")) {
        const no_store = [_]std.http.Header{
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "pragma", .value = "no-cache" },
        };
        if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
        if (req.head.method == .POST) {
            if (!web_auth.sameOrigin(origin_owned, host_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid origin\"}", &no_store);
            const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"username required\"}", &no_store);
            defer self.allocator.free(name);
            const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"password"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"password required\"}", &no_store);
            defer self.allocator.free(password);
            const password_md5 = web_auth.passwordCredential(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            const existing = (try self.store.userByName(self.allocator, name)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            const user_id = existing.id;
            freeUser(self.allocator, existing);
            const mutex = self.gameSessionMutex(user_id);
            mutex.lockUncancelable(self.store.io);
            defer mutex.unlock(self.store.io);
            const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            defer freeUser(self.allocator, user);
            if (user.id != user_id) return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            if (user.id == 3) return respond(req, .forbidden, "application/json", "{\"error\":\"account login unavailable\"}", &no_store);
            const token = try self.store.issueToken(user.id, web_auth.player_scope, web_auth.player_lifetime_seconds);
            const csrf = web_auth.csrfToken(&token);
            const json = try web_auth.sessionJson(self.allocator, user, csrf);
            defer self.allocator.free(json);
            var cookie_buf: [256]u8 = undefined;
            const cookie = try std.fmt.bufPrint(&cookie_buf, "{s}={s}; Path=/; Max-Age={d}; Secure; HttpOnly; SameSite=Strict", .{ web_auth.player_cookie_name, &token, web_auth.player_lifetime_seconds });
            std.log.info("event=website_session_created user_id={d}", .{user.id});
            return respond(req, .ok, "application/json", json, &.{
                .{ .name = "set-cookie", .value = cookie },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            });
        }
        const token = web_auth.playerSessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
        if (req.head.method == .GET) {
            const user = (try self.store.authenticateToken(self.allocator, token, web_auth.player_scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            defer freeUser(self.allocator, user);
            const csrf = web_auth.csrfToken(token);
            const json = try web_auth.sessionJson(self.allocator, user, csrf);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }
        if (req.head.method == .DELETE) {
            if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
            _ = try self.store.revokeToken(token);
            return respond(req, .no_content, "application/json", "", &.{
                .{ .name = "set-cookie", .value = "__Host-kai-account=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict" },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            });
        }
        return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
    }
    if (std.mem.eql(u8, path, "/api/v1/multiplayer/rooms") or parseWebsiteRoomPath(path) != null) {
        const no_store = [_]std.http.Header{
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "pragma", .value = "no-cache" },
        };
        if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        if (parseWebsiteRoomPath(path)) |room_id| {
            const room = (try self.lazer_multiplayer.roomsJson(self.allocator, room_id, null, 0)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room not found\"}", &no_store);
            defer self.allocator.free(room);
            const leaderboard = (try self.lazer_multiplayer.roomLeaderboardJson(self.allocator, 0, room_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room not found\"}", &no_store);
            defer self.allocator.free(leaderboard);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"room\":");
            try output.writer.writeAll(room);
            try output.writer.writeAll(",\"scores\":");
            try output.writer.writeAll(leaderboard);
            try output.writer.writeByte('}');
            return respond(req, .ok, "application/json", output.written(), &no_store);
        }
        const rooms_value = try self.lazer_multiplayer.roomsJson(self.allocator, null, .{ .requester_id = 0, .mode = .open }, 0);
        const rooms = rooms_value orelse "[]";
        defer if (rooms_value != null) self.allocator.free(rooms);
        return respond(req, .ok, "application/json", rooms, &no_store);
    }
    if (std.mem.eql(u8, path, "/api/v1/chat/channels") or std.mem.eql(u8, path, "/api/v1/chat/messages") or std.mem.eql(u8, path, "/api/v1/chat/read") or std.mem.eql(u8, path, "/api/v1/chat/threads") or std.mem.eql(u8, path, "/api/v1/chat/dms") or std.mem.eql(u8, path, "/api/v1/chat/dms/read")) {
        const no_store = [_]std.http.Header{
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "pragma", .value = "no-cache" },
        };
        if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
        const token = web_auth.playerSessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"sign in required\"}", &no_store);
        const user = (try self.store.authenticateToken(self.allocator, token, web_auth.player_scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"session ended\"}", &no_store);
        defer freeUser(self.allocator, user);

        if (std.mem.eql(u8, path, "/api/v1/chat/channels")) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
            const json = try self.store.lazerChannelListJson(self.allocator, user.id);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }

        if (std.mem.eql(u8, path, "/api/v1/chat/threads")) {
            if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
            const json = try self.store.directMessageThreadsJson(self.allocator, user.id, 100);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }

        if (std.mem.eql(u8, path, "/api/v1/chat/dms") and req.head.method == .GET) {
            const other_id = std.fmt.parseInt(i32, queryField(target, "user") orelse "", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
            if (other_id <= 0 or other_id == user.id) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
            var other = (try self.store.userById(self.allocator, other_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
            defer freeUser(self.allocator, other);
            if (other.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
            try self.markOnline(&other);
            const since = std.fmt.parseInt(i64, queryField(target, "since") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid cursor\"}", &no_store);
            if (since < 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid cursor\"}", &no_store);
            const messages = try self.store.lazerDirectMessagesJson(self.allocator, user.id, other.id, since, 100);
            defer self.allocator.free(messages);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"user\":");
            try user_json.writeCompact(&output.writer, other, other.show_country);
            try output.writer.writeAll(",\"messages\":");
            try output.writer.writeAll(messages);
            try output.writer.writeByte('}');
            return respond(req, .ok, "application/json", output.written(), &no_store);
        }

        if (std.mem.eql(u8, path, "/api/v1/chat/messages") and req.head.method == .GET) {
            const channel_id = std.fmt.parseInt(i64, queryField(target, "channel") orelse "", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid channel\"}", &no_store);
            if (!lazer.validChannelId(channel_id)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid channel\"}", &no_store);
            const since = std.fmt.parseInt(i64, queryField(target, "since") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid cursor\"}", &no_store);
            if (since < 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid cursor\"}", &no_store);
            const json = try self.store.lazerChatMessagesJson(self.allocator, channel_id, since, 100);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }

        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);

        if (std.mem.eql(u8, path, "/api/v1/chat/dms/read")) {
            const other_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"user"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player required\"}", &no_store);
            defer self.allocator.free(other_text);
            const other_id = std.fmt.parseInt(i32, other_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
            if (other_id <= 0 or other_id == user.id) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
            const other = (try self.store.userById(self.allocator, other_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
            defer freeUser(self.allocator, other);
            try self.store.markDirectMessagesRead(user.id, other.id);
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }

        if (std.mem.eql(u8, path, "/api/v1/chat/dms")) {
            if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted accounts cannot chat\"}", &no_store);
            const now = std.Io.Clock.real.now(self.sessions.io).toSeconds();
            if (user.silence_end > now) return respond(req, .forbidden, "application/json", "{\"error\":\"you are silenced\"}", &no_store);
            const other_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"user"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player required\"}", &no_store);
            defer self.allocator.free(other_text);
            const other_id = std.fmt.parseInt(i32, other_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
            if (other_id <= 0 or other_id == user.id) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
            const other = (try self.store.userById(self.allocator, other_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
            defer freeUser(self.allocator, other);
            if (other.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
            const message_owned = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"message required\"}", &no_store);
            defer self.allocator.free(message_owned);
            const message = std.mem.trim(u8, message_owned, " \t\r\n");
            if (!validWebText(message, 1, 2000) or std.mem.indexOfScalar(u8, message, 0) != null) return respond(req, .bad_request, "application/json", "{\"error\":\"message must be 1-2000 characters\"}", &no_store);
            const uuid = try randomMessageUuid(self.sessions.io);
            const written = self.store.recordLazerDirectMessage(self.allocator, user.id, other.id, message, false, &uuid) catch |err| return switch (err) {
                error.DirectMessageBlocked => respond(req, .forbidden, "application/json", "{\"error\":\"direct messages are blocked\"}", &no_store),
                error.ChatUuidConflict => respond(req, .conflict, "application/json", "{\"error\":\"message could not be retried\"}", &no_store),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"message could not be sent\"}", &no_store),
            };
            defer self.allocator.free(written.json);
            if (written.inserted) {
                if (written.direct_message_id) |message_id| self.deliverDirectMessageToStable(user, other.id, message_id, message) catch |err|
                    std.log.warn("event=website_dm_stable_delivery_failed user_id={d} target_id={d} error={t}", .{ user.id, other.id, err });
                if (other.id == 3) self.recordLazerBotReply(user, message, false);
            }
            return respond(req, .created, "application/json", written.json, &no_store);
        }

        const channel_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"channel"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"channel required\"}", &no_store);
        defer self.allocator.free(channel_text);
        const channel_id = std.fmt.parseInt(i64, channel_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid channel\"}", &no_store);
        const channel_name = lazer.channelName(channel_id) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid channel\"}", &no_store);

        if (std.mem.eql(u8, path, "/api/v1/chat/read")) {
            const message_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"message required\"}", &no_store);
            defer self.allocator.free(message_text);
            const message_id = std.fmt.parseInt(i64, message_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid message\"}", &no_store);
            self.store.markLazerChannelRead(user.id, channel_id, message_id) catch |err| return switch (err) {
                error.ChatMessageNotFound => respond(req, .not_found, "application/json", "{\"error\":\"message not found\"}", &no_store),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"read state unavailable\"}", &no_store),
            };
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }

        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted accounts cannot chat\"}", &no_store);
        const now = std.Io.Clock.real.now(self.sessions.io).toSeconds();
        if (user.silence_end > now) return respond(req, .forbidden, "application/json", "{\"error\":\"you are silenced\"}", &no_store);
        const message_owned = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"message required\"}", &no_store);
        defer self.allocator.free(message_owned);
        const message = std.mem.trim(u8, message_owned, " \t\r\n");
        if (!validWebText(message, 1, 2000) or std.mem.indexOfScalar(u8, message, 0) != null) return respond(req, .bad_request, "application/json", "{\"error\":\"message must be 1-2000 characters\"}", &no_store);
        const uuid = try randomMessageUuid(self.sessions.io);
        const written = self.store.recordLazerPublicMessage(self.allocator, user.id, channel_name, message, false, &uuid) catch |err| return switch (err) {
            error.ChannelReadOnly => respond(req, .forbidden, "application/json", "{\"error\":\"that channel is read only\"}", &no_store),
            error.UnknownChannel => respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &no_store),
            else => respond(req, .internal_server_error, "application/json", "{\"error\":\"message could not be sent\"}", &no_store),
        };
        defer self.allocator.free(written.json);
        self.broadcastLazerChatToStable(user, channel_name, message) catch |err| std.log.warn("event=website_chat_stable_broadcast_failed user_id={d} channel={s} error={t}", .{ user.id, channel_name, err });
        return respond(req, .created, "application/json", written.json, &no_store);
    }
    const account_pin_path = parsePinPath(path);
    if (std.mem.eql(u8, path, "/api/v1/account") or std.mem.eql(u8, path, "/api/v1/account/avatar") or std.mem.eql(u8, path, "/api/v1/account/banner") or std.mem.eql(u8, path, "/api/v1/account/email") or std.mem.eql(u8, path, "/api/v1/account/password") or std.mem.eql(u8, path, "/api/v1/account/username") or account_pin_path != null) {
        const no_store = [_]std.http.Header{
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "pragma", .value = "no-cache" },
        };
        if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
        const token = web_auth.playerSessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
        const user = (try self.store.authenticateToken(self.allocator, token, web_auth.player_scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
        defer freeUser(self.allocator, user);
        if (account_pin_path) |pin| {
            if (req.head.method != .PUT and req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
            if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
            self.store.setScorePinnedById(user.id, pin.source, pin.id, req.head.method == .PUT) catch |err| return switch (err) {
                error.TooManyPinnedScores => respond(req, .conflict, "application/json", "{\"error\":\"you can pin three plays per mode and score type\"}", &no_store),
                error.NoPassedScore => respond(req, .not_found, "application/json", "{\"error\":\"that passed score is not yours\"}", &no_store),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"pin could not be changed\"}", &no_store),
            };
            return respond(req, .ok, "application/json", if (req.head.method == .PUT) "{\"ok\":true,\"pinned\":true}" else "{\"ok\":true,\"pinned\":false}", &no_store);
        }
        if (std.mem.eql(u8, path, "/api/v1/account/email") or std.mem.eql(u8, path, "/api/v1/account/password") or std.mem.eql(u8, path, "/api/v1/account/username")) {
            if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
            if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
            const current_password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"current_password"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"current password required\"}", &no_store);
            defer self.allocator.free(current_password);
            const current_md5 = web_auth.passwordCredential(current_password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"current password is wrong\"}", &no_store);
            const mutex = self.gameSessionMutex(user.id);
            mutex.lockUncancelable(self.store.io);
            defer mutex.unlock(self.store.io);
            const verified = (try self.store.authenticate(self.allocator, user.name, &current_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"current password is wrong\"}", &no_store);
            defer freeUser(self.allocator, verified);
            if (verified.id != user.id) return respond(req, .unauthorized, "application/json", "{\"error\":\"current password is wrong\"}", &no_store);
            if (std.mem.eql(u8, path, "/api/v1/account/email")) {
                const email_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"email"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"email required\"}", &no_store);
                defer self.allocator.free(email_value);
                const email = std.mem.trim(u8, email_value, " \t\r\n");
                if (!registration.validEmail(email)) return respond(req, .bad_request, "application/json", "{\"error\":\"that email is not valid\"}", &no_store);
                self.store.updateAccountEmail(user.id, email) catch |err| return respond(req, if (err == error.EmailExists) .conflict else .internal_server_error, "application/json", if (err == error.EmailExists) "{\"error\":\"that email is already in use\"}" else "{\"error\":\"email could not be changed\"}", &no_store);
                const json = (try self.store.siteAccountJson(self.allocator, user.id)).?;
                defer self.allocator.free(json);
                std.log.info("event=website_email_updated user_id={d}", .{user.id});
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (std.mem.eql(u8, path, "/api/v1/account/password")) {
                const new_password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"new_password"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"new password required\"}", &no_store);
                defer self.allocator.free(new_password);
                if (!registration.validPassword(new_password)) return respond(req, .bad_request, "application/json", "{\"error\":\"use 8-32 characters with more than 3 unique characters\"}", &no_store);
                const password_md5 = web_auth.passwordCredential(new_password) catch return respond(req, .bad_request, "application/json", "{\"error\":\"new password is not valid\"}", &no_store);
                var prepared = try bancho.prepareSuppression(self.allocator, "your password changed. sign in again.");
                defer prepared.deinit();
                try self.store.updateAccountPassword(user.id, &password_md5);
                _ = self.finishDisconnectPrepared(user.id, &prepared);
                std.log.info("event=website_password_updated user_id={d}", .{user.id});
                return respond(req, .ok, "application/json", "{\"ok\":true,\"reauthenticate\":true}", &.{
                    .{ .name = "set-cookie", .value = "__Host-kai-account=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict" },
                    .{ .name = "cache-control", .value = "no-store" },
                });
            }
            const username_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"username required\"}", &no_store);
            defer self.allocator.free(username_value);
            const username = std.mem.trim(u8, username_value, " \t\r\n");
            if (!registration.validUsername(username)) return respond(req, .bad_request, "application/json", "{\"error\":\"use 2-15 allowed username characters\"}", &no_store);
            var prepared = try bancho.prepareSuppression(self.allocator, "your username changed. sign in again with the new name.");
            defer prepared.deinit();
            self.store.updateAccountUsername(user.id, username) catch |err| return switch (err) {
                error.UsernameExists => respond(req, .conflict, "application/json", "{\"error\":\"that username is already in use\"}", &no_store),
                error.PremiumRequired => respond(req, .payment_required, "application/json", "{\"error\":\"the free username change was already used; premium is required for another\"}", &no_store),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"username could not be changed\"}", &no_store),
            };
            _ = self.finishDisconnectPrepared(user.id, &prepared);
            std.log.info("event=website_username_updated user_id={d}", .{user.id});
            return respond(req, .ok, "application/json", "{\"ok\":true,\"reauthenticate\":true}", &.{
                .{ .name = "set-cookie", .value = "__Host-kai-account=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict" },
                .{ .name = "cache-control", .value = "no-store" },
            });
        }
        if (std.mem.eql(u8, path, "/api/v1/account")) {
            if (req.head.method == .GET) {
                const json = (try self.store.siteAccountJson(self.allocator, user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"account not found\"}", &no_store);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
                const bio_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"bio"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"bio required\"}", &no_store);
                defer self.allocator.free(bio_value);
                const title_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_title"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"profile title required\"}", &no_store);
                defer self.allocator.free(title_value);
                const pronouns_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_pronouns"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"pronouns required\"}", &no_store);
                defer self.allocator.free(pronouns_value);
                const location_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_location"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"location required\"}", &no_store);
                defer self.allocator.free(location_value);
                const website_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_website"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"website required\"}", &no_store);
                defer self.allocator.free(website_value);
                const accent_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_accent"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"accent required\"}", &no_store);
                defer self.allocator.free(accent_value);
                const mode_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"preferred_mode"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"main mode required\"}", &no_store);
                defer self.allocator.free(mode_value);
                const source_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"profile_source"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"score view required\"}", &no_store);
                defer self.allocator.free(source_value);
                const avatar_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"avatar_key"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"default avatar required\"}", &no_store);
                defer self.allocator.free(avatar_value);
                const show_country_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"show_country"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"country privacy required\"}", &no_store);
                defer self.allocator.free(show_country_value);
                const show_stats_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"show_profile_stats"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"stats privacy required\"}", &no_store);
                defer self.allocator.free(show_stats_value);
                const show_recent_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"show_recent_scores"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"recent plays privacy required\"}", &no_store);
                defer self.allocator.free(show_recent_value);
                const bio = std.mem.trim(u8, bio_value, " \t\r\n");
                const profile_title = std.mem.trim(u8, title_value, " \t\r\n");
                const profile_pronouns = std.mem.trim(u8, pronouns_value, " \t\r\n");
                const profile_location = std.mem.trim(u8, location_value, " \t\r\n");
                const profile_website = std.mem.trim(u8, website_value, " \t\r\n");
                const profile_accent = domain.parseProfileAccent(accent_value) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid profile accent\"}", &no_store);
                const preferred_mode = std.fmt.parseInt(u8, mode_value, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid main mode\"}", &no_store);
                const profile_source = domain.parseSiteScoreSource(source_value) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid score view\"}", &no_store);
                const avatar_key = std.fmt.parseInt(u8, avatar_value, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid default avatar\"}", &no_store);
                const show_country = std.mem.eql(u8, show_country_value, "1");
                const show_profile_stats = std.mem.eql(u8, show_stats_value, "1");
                const show_recent_scores = std.mem.eql(u8, show_recent_value, "1");
                if ((!show_country and !std.mem.eql(u8, show_country_value, "0")) or (!show_profile_stats and !std.mem.eql(u8, show_stats_value, "0")) or (!show_recent_scores and !std.mem.eql(u8, show_recent_value, "0")) or !validWebText(bio, 0, 500) or !validWebLine(profile_title, 40) or !validWebLine(profile_pronouns, 32) or !validWebLine(profile_location, 60) or !validProfileWebsite(profile_website) or preferred_mode > 3 or (avatar_key != 1 and avatar_key != 2)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid profile settings\"}", &no_store);
                try self.store.updateSiteProfile(user.id, .{ .bio = bio, .title = profile_title, .pronouns = profile_pronouns, .location = profile_location, .website = profile_website, .accent = profile_accent, .preferred_mode = preferred_mode, .profile_source = profile_source, .avatar_key = avatar_key, .show_country = show_country, .show_profile_stats = show_profile_stats, .show_recent_scores = show_recent_scores });
                self.lazer_multiplayer.setUserCountryVisibility(user.id, user.country, show_country);
                bancho.setUserCountryVisibility(self.allocator, &self.sessions, user.id, user.country, show_country);
                const json = (try self.store.siteAccountJson(self.allocator, user.id)).?;
                defer self.allocator.free(json);
                std.log.info("event=website_profile_updated user_id={d}", .{user.id});
                return respond(req, .ok, "application/json", json, &no_store);
            }
            return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        }
        if ((req.head.method != .PUT and req.head.method != .DELETE) or !web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, if (req.head.method == .PUT or req.head.method == .DELETE) .forbidden else .method_not_allowed, "application/json", if (req.head.method == .PUT or req.head.method == .DELETE) "{\"error\":\"invalid request\"}" else "{\"error\":\"method not allowed\"}", &no_store);
        if (std.mem.eql(u8, path, "/api/v1/account/banner")) {
            if (req.head.method == .PUT) {
                const image = profile_banner.validate(content_type_owned, body) catch |err| return respond(req, .bad_request, "application/json", switch (err) {
                    error.InvalidAvatarSize => "{\"error\":\"profile banners must be under 4 mb\"}",
                    error.InvalidAvatarDimensions => "{\"error\":\"profile banners must fit inside 2000 by 500 px\"}",
                    error.InvalidAvatarContentType => "{\"error\":\"the image type does not match its file\"}",
                    else => "{\"error\":\"use a valid png, jpeg, or gif image\"}",
                }, &no_store);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
                const etag = std.fmt.bytesToHex(digest, .lower);
                const object_key = try object_keys.banner(self.allocator, user.id, image.content_type, &etag);
                defer self.allocator.free(object_key);
                const previous = try self.store.customBannerForUser(self.allocator, user.id);
                defer if (previous) |value| {
                    var banner = value;
                    banner.deinit();
                };
                self.avatar_store.put(self.allocator, self.store.io, object_key, image.content_type, body) catch return respond(req, .bad_gateway, "application/json", "{\"error\":\"banner storage is not available\"}", &no_store);
                self.store.setCustomBanner(user.id, object_key, image.content_type, etag, image.width, image.height) catch |err| {
                    const replaces_existing = if (previous) |banner| std.mem.eql(u8, banner.object_key, object_key) else false;
                    if (!replaces_existing) self.avatar_store.delete(self.allocator, self.store.io, object_key) catch {};
                    return err;
                };
                self.avatar_cache.put(object_key, body) catch |err| std.log.warn("event=website_banner_cache_write_failed user_id={d} error={t}", .{ user.id, err });
                if (previous) |banner| if (!std.mem.eql(u8, banner.object_key, object_key)) {
                    self.avatar_cache.remove(banner.object_key);
                    self.avatar_store.delete(self.allocator, self.store.io, banner.object_key) catch |err| std.log.warn("event=website_banner_old_object_delete_failed user_id={d} error={t}", .{ user.id, err });
                };
                std.log.info("event=website_banner_updated user_id={d} bytes={d}", .{ user.id, body.len });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
            const previous = try self.store.customBannerForUser(self.allocator, user.id);
            defer if (previous) |value| {
                var banner = value;
                banner.deinit();
            };
            _ = try self.store.deleteCustomBanner(user.id);
            if (previous) |banner| {
                self.avatar_cache.remove(banner.object_key);
                self.avatar_store.delete(self.allocator, self.store.io, banner.object_key) catch |err| std.log.warn("event=website_banner_object_delete_failed user_id={d} error={t}", .{ user.id, err });
            }
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }
        if (req.head.method == .PUT) {
            const image = profile_avatar.validate(content_type_owned, body) catch return respond(req, .bad_request, "application/json", "{\"error\":\"use a valid png, jpeg, or gif up to 2 mb and 4096 px\"}", &no_store);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
            const etag = std.fmt.bytesToHex(digest, .lower);
            const extension = if (std.mem.eql(u8, image.content_type, "image/png")) "png" else if (std.mem.eql(u8, image.content_type, "image/gif")) "gif" else "jpg";
            var object_key_buf: [128]u8 = undefined;
            const object_key = try std.fmt.bufPrint(&object_key_buf, "{d}/{s}.{s}", .{ user.id, &etag, extension });
            const previous = try self.store.customAvatarForUser(self.allocator, user.id);
            defer if (previous) |avatar_value| {
                var avatar = avatar_value;
                avatar.deinit();
            };
            self.avatar_store.put(self.allocator, self.store.io, object_key, image.content_type, body) catch |err| {
                std.log.warn("event=website_avatar_upload_failed user_id={d} error={t}", .{ user.id, err });
                return respond(req, .bad_gateway, "application/json", "{\"error\":\"avatar storage is not available\"}", &no_store);
            };
            self.store.setCustomAvatar(user.id, object_key, image.content_type, etag) catch |err| {
                const replaces_existing_object = if (previous) |avatar| std.mem.eql(u8, avatar.object_key, object_key) else false;
                if (!replaces_existing_object) self.avatar_store.delete(self.allocator, self.store.io, object_key) catch {};
                return err;
            };
            self.avatar_cache.put(object_key, body) catch |err| std.log.warn("event=website_avatar_cache_write_failed user_id={d} error={t}", .{ user.id, err });
            if (previous) |avatar| if (!std.mem.eql(u8, avatar.object_key, object_key)) {
                self.avatar_cache.remove(avatar.object_key);
                self.avatar_store.delete(self.allocator, self.store.io, avatar.object_key) catch |err| std.log.warn("event=website_avatar_old_object_delete_failed user_id={d} error={t}", .{ user.id, err });
            };
            std.log.info("event=website_avatar_updated user_id={d} bytes={d} type={s}", .{ user.id, body.len, image.content_type });
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }
        const previous = try self.store.customAvatarForUser(self.allocator, user.id);
        defer if (previous) |avatar_value| {
            var avatar = avatar_value;
            avatar.deinit();
        };
        _ = try self.store.deleteCustomAvatar(user.id);
        if (previous) |avatar| {
            self.avatar_cache.remove(avatar.object_key);
            self.avatar_store.delete(self.allocator, self.store.io, avatar.object_key) catch |err| std.log.warn("event=website_avatar_object_delete_failed user_id={d} error={t}", .{ user.id, err });
        }
        std.log.info("event=website_avatar_reset user_id={d}", .{user.id});
        return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
    }
    const website_team_path = parseTeamPath(path, "/api/v1/teams/");
    const lazer_team_path = parseTeamPath(path, "/api/v2/teams/");
    if (std.mem.eql(u8, path, "/api/v1/teams") or std.mem.eql(u8, path, "/api/v2/teams") or website_team_path != null or lazer_team_path != null) {
        const no_store = [_]std.http.Header{.{ .name = "cache-control", .value = "no-store" }};
        const is_lazer_route = std.mem.startsWith(u8, path, "/api/v2/teams");
        var requester: ?domain.User = null;
        var requester_token: ?[]const u8 = null;
        var requester_is_staff = false;
        if (is_lazer_route) {
            requester = try self.lazerUser(auth_owned, "identify");
        } else if (web_auth.playerSessionToken(cookie_owned)) |session_token| {
            requester = try self.store.authenticateToken(self.allocator, session_token, web_auth.player_scope);
            requester_token = session_token;
        } else if (web_auth.sessionToken(cookie_owned)) |session_token| {
            requester = try self.store.authenticateToken(self.allocator, session_token, web_auth.scope);
            if (requester) |staff_user| {
                if (!web_auth.allowed(staff_user) or !web_auth.canAdmin(staff_user)) {
                    freeUser(self.allocator, staff_user);
                    requester = null;
                } else {
                    requester_token = session_token;
                    requester_is_staff = true;
                }
            }
        }
        defer if (requester) |value| freeUser(self.allocator, value);
        const route = if (is_lazer_route) lazer_team_path else website_team_path;
        if (req.head.method == .GET) {
            if (route) |team_path| {
                if (team_path.action.len != 0) return respond(req, .not_found, "application/json", "{\"error\":\"team not found\"}", &no_store);
                const json = (try self.store.teamJson(self.allocator, team_path.id, if (requester) |value| value.id else null, requester_is_staff or if (requester) |value| web_auth.canAdmin(value) else false)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"team not found\"}", &no_store);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            const json = try self.store.teamsJson(self.allocator, if (requester) |value| value.id else null);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }
        if (is_lazer_route) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        const session_token = requester_token orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"sign in required\"}", &no_store);
        const actor = requester orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"sign in required\"}", &no_store);
        if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(session_token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
        if (route == null and req.head.method == .POST) {
            const name_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"name"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"team name required\"}", &no_store);
            defer self.allocator.free(name_value);
            const tag_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"short_name"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"team tag required\"}", &no_store);
            defer self.allocator.free(tag_value);
            const url_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"url"})) orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(url_value);
            const description_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"description"})) orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(description_value);
            const open_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"is_open"})) orelse try self.allocator.dupe(u8, "1");
            defer self.allocator.free(open_value);
            const mode_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"default_ruleset_id"})) orelse try self.allocator.dupe(u8, "0");
            defer self.allocator.free(mode_value);
            const settings: domain.TeamSettings = .{ .name = std.mem.trim(u8, name_value, " \t\r\n"), .short_name = std.mem.trim(u8, tag_value, " \t\r\n"), .url = std.mem.trim(u8, url_value, " \t\r\n"), .description = std.mem.trim(u8, description_value, " \t\r\n"), .is_open = std.mem.eql(u8, open_value, "1"), .default_ruleset_id = std.fmt.parseInt(u8, mode_value, 10) catch 255 };
            if ((!settings.is_open and !std.mem.eql(u8, open_value, "0")) or !domain.validTeamSettings(settings)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid team settings\"}", &no_store);
            const team_id = self.store.createTeam(actor.id, settings) catch |err| return respond(req, if (err == error.TeamExists or err == error.AlreadyInTeam) .conflict else .internal_server_error, "application/json", if (err == error.TeamExists) "{\"error\":\"that team name or tag already exists\"}" else if (err == error.AlreadyInTeam) "{\"error\":\"leave your current team first\"}" else "{\"error\":\"team could not be created\"}", &no_store);
            var response_buf: [64]u8 = undefined;
            const json = try std.fmt.bufPrint(&response_buf, "{{\"ok\":true,\"id\":{d}}}", .{team_id});
            return respond(req, .created, "application/json", json, &no_store);
        }
        const team_path = route orelse return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        const is_admin = requester_is_staff or web_auth.canAdmin(actor);
        if (std.mem.eql(u8, team_path.action, "join") and req.head.method == .POST) {
            const result = self.store.joinOrApplyTeam(actor.id, team_path.id) catch |err| return respond(req, if (err == error.TeamNotFound) .not_found else .conflict, "application/json", if (err == error.TeamNotFound) "{\"error\":\"team not found\"}" else "{\"error\":\"you already joined a team or applied\"}", &no_store);
            return respond(req, if (result == .joined) .ok else .accepted, "application/json", if (result == .joined) "{\"ok\":true,\"state\":\"joined\"}" else "{\"ok\":true,\"state\":\"applied\"}", &no_store);
        }
        if (std.mem.eql(u8, team_path.action, "leave") and req.head.method == .POST) {
            self.store.leaveTeam(actor.id, team_path.id) catch return respond(req, .conflict, "application/json", "{\"error\":\"the team leader must transfer leadership or disband the team\"}", &no_store);
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }
        if (std.mem.eql(u8, team_path.action, "members") and req.head.method == .POST) {
            const user_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"user_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player required\"}", &no_store);
            defer self.allocator.free(user_value);
            const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &no_store);
            defer self.allocator.free(action);
            const target_id = std.fmt.parseInt(i32, user_value, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
            self.store.teamMemberAction(actor.id, team_path.id, target_id, action, is_admin) catch |err| return respond(req, if (err == error.TeamPermissionDenied) .forbidden else .conflict, "application/json", if (err == error.TeamPermissionDenied) "{\"error\":\"team management access required\"}" else "{\"error\":\"team member action was not accepted\"}", &no_store);
            var audit_target_buf: [32]u8 = undefined;
            const audit_target = try std.fmt.bufPrint(&audit_target_buf, "team:{d}", .{team_path.id});
            try self.store.recordAudit(actor.id, "team.member", audit_target, action);
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }
        if ((std.mem.eql(u8, team_path.action, "flag") or std.mem.eql(u8, team_path.action, "header")) and (req.head.method == .PUT or req.head.method == .DELETE)) {
            if (!try self.store.teamCanManage(actor.id, team_path.id, is_admin)) return respond(req, .forbidden, "application/json", "{\"error\":\"team management access required\"}", &no_store);
            const kind: team_image.Kind = if (std.mem.eql(u8, team_path.action, "flag")) .flag else .header;
            if (req.head.method == .PUT) {
                const image = team_image.validate(kind, content_type_owned, body) catch |err| return respond(req, .bad_request, "application/json", switch (err) {
                    error.InvalidAvatarSize => if (kind == .flag) "{\"error\":\"team flags must be under 200 kb\"}" else "{\"error\":\"team headers must be under 4 mb\"}",
                    error.InvalidAvatarDimensions => if (kind == .flag) "{\"error\":\"team flags must fit inside 512 by 256 px\"}" else "{\"error\":\"team headers must fit inside 2000 by 500 px\"}",
                    error.InvalidAvatarContentType => "{\"error\":\"the image type does not match its file\"}",
                    else => "{\"error\":\"use a valid png, jpeg, or gif image\"}",
                }, &no_store);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
                const etag = std.fmt.bytesToHex(digest, .lower);
                const object_key = try object_keys.teamAsset(self.allocator, team_path.id, team_path.action, image.content_type, &etag);
                defer self.allocator.free(object_key);
                const previous = try self.store.teamAsset(self.allocator, team_path.id, team_path.action);
                defer if (previous) |value| {
                    var old = value;
                    old.deinit();
                };
                self.avatar_store.put(self.allocator, self.store.io, object_key, image.content_type, body) catch return respond(req, .bad_gateway, "application/json", "{\"error\":\"team image storage is not available\"}", &no_store);
                self.store.setTeamAsset(team_path.id, team_path.action, object_key, image.content_type, etag, image.width, image.height) catch |err| {
                    self.avatar_store.delete(self.allocator, self.store.io, object_key) catch {};
                    return err;
                };
                self.avatar_cache.put(object_key, body) catch {};
                if (previous) |old| if (!std.mem.eql(u8, old.object_key, object_key)) {
                    self.avatar_cache.remove(old.object_key);
                    self.avatar_store.delete(self.allocator, self.store.io, old.object_key) catch {};
                };
            } else {
                const previous = try self.store.teamAsset(self.allocator, team_path.id, team_path.action);
                defer if (previous) |value| {
                    var old = value;
                    old.deinit();
                };
                _ = try self.store.deleteTeamAsset(team_path.id, team_path.action);
                if (previous) |old| {
                    self.avatar_cache.remove(old.object_key);
                    self.avatar_store.delete(self.allocator, self.store.io, old.object_key) catch {};
                }
            }
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }
        if (team_path.action.len == 0 and req.head.method == .POST) {
            const name_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"name"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"team name required\"}", &no_store);
            defer self.allocator.free(name_value);
            const tag_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"short_name"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"team tag required\"}", &no_store);
            defer self.allocator.free(tag_value);
            const url_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"url"})) orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(url_value);
            const description_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"description"})) orelse try self.allocator.dupe(u8, "");
            defer self.allocator.free(description_value);
            const open_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"is_open"})) orelse try self.allocator.dupe(u8, "1");
            defer self.allocator.free(open_value);
            const mode_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"default_ruleset_id"})) orelse try self.allocator.dupe(u8, "0");
            defer self.allocator.free(mode_value);
            const settings: domain.TeamSettings = .{ .name = std.mem.trim(u8, name_value, " \t\r\n"), .short_name = std.mem.trim(u8, tag_value, " \t\r\n"), .url = std.mem.trim(u8, url_value, " \t\r\n"), .description = std.mem.trim(u8, description_value, " \t\r\n"), .is_open = std.mem.eql(u8, open_value, "1"), .default_ruleset_id = std.fmt.parseInt(u8, mode_value, 10) catch 255 };
            if ((!settings.is_open and !std.mem.eql(u8, open_value, "0")) or !domain.validTeamSettings(settings)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid team settings\"}", &no_store);
            self.store.updateTeam(actor.id, team_path.id, settings, is_admin) catch |err| return respond(req, if (err == error.TeamPermissionDenied) .forbidden else if (err == error.TeamExists) .conflict else .internal_server_error, "application/json", if (err == error.TeamPermissionDenied) "{\"error\":\"team management access required\"}" else if (err == error.TeamExists) "{\"error\":\"that team name or tag already exists\"}" else "{\"error\":\"team could not be updated\"}", &no_store);
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }
        if (team_path.action.len == 0 and req.head.method == .DELETE) {
            const flag = try self.store.teamAsset(self.allocator, team_path.id, "flag");
            defer if (flag) |value| {
                var old = value;
                old.deinit();
            };
            const header_image = try self.store.teamAsset(self.allocator, team_path.id, "header");
            defer if (header_image) |value| {
                var old = value;
                old.deinit();
            };
            self.store.disbandTeam(actor.id, team_path.id, is_admin) catch return respond(req, .forbidden, "application/json", "{\"error\":\"team management access required\"}", &no_store);
            if (flag) |old| self.avatar_store.delete(self.allocator, self.store.io, old.object_key) catch {};
            if (header_image) |old| self.avatar_store.delete(self.allocator, self.store.io, old.object_key) catch {};
            return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
        }
        return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
    }
    if (std.mem.eql(u8, path, "/api/v1/staff/session")) {
        const no_store = [_]std.http.Header{
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "pragma", .value = "no-cache" },
        };
        if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
        if (req.head.method == .POST) {
            if (!web_auth.sameOrigin(origin_owned, host_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid origin\"}", &no_store);
            const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"username required\"}", &no_store);
            defer self.allocator.free(name);
            const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"password"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"password required\"}", &no_store);
            defer self.allocator.free(password);
            const password_md5 = web_auth.passwordCredential(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            const existing = (try self.store.userByName(self.allocator, name)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            const user_id = existing.id;
            freeUser(self.allocator, existing);
            const mutex = self.gameSessionMutex(user_id);
            mutex.lockUncancelable(self.store.io);
            defer mutex.unlock(self.store.io);
            const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            if (user.id != user_id) return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
            if (!web_auth.allowed(user)) return respond(req, .forbidden, "application/json", "{\"error\":\"staff access required\"}", &no_store);
            const token = try self.store.issueToken(user.id, web_auth.scope, web_auth.lifetime_seconds);
            std.log.info("event=staff_session_created user_id={d}", .{user.id});
            const csrf = web_auth.csrfToken(&token);
            const json = try web_auth.sessionJson(self.allocator, user, csrf);
            defer self.allocator.free(json);
            var cookie_buf: [256]u8 = undefined;
            const cookie = try std.fmt.bufPrint(&cookie_buf, "{s}={s}; Path=/; Max-Age={d}; Secure; HttpOnly; SameSite=Strict", .{ web_auth.cookie_name, &token, web_auth.lifetime_seconds });
            const headers = [_]std.http.Header{
                .{ .name = "set-cookie", .value = cookie },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            return respond(req, .ok, "application/json", json, &headers);
        }
        const token = web_auth.sessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
        if (req.head.method == .GET) {
            const user = (try self.store.authenticateToken(self.allocator, token, web_auth.scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            if (!web_auth.allowed(user)) {
                _ = try self.store.revokeToken(token);
                return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
            }
            const csrf = web_auth.csrfToken(token);
            const json = try web_auth.sessionJson(self.allocator, user, csrf);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }
        if (req.head.method == .DELETE) {
            if (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(token, csrf_owned)) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);
            _ = try self.store.revokeToken(token);
            const headers = [_]std.http.Header{
                .{ .name = "set-cookie", .value = "__Host-kai-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict" },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            return respond(req, .no_content, "application/json", "", &headers);
        }
        return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
    }
    if (std.mem.startsWith(u8, path, "/api/v1/staff/")) {
        const no_store = [_]std.http.Header{
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "pragma", .value = "no-cache" },
        };
        if (!web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &no_store);
        const staff_token = web_auth.sessionToken(cookie_owned) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
        const staff_user = (try self.store.authenticateToken(self.allocator, staff_token, web_auth.scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
        defer freeUser(self.allocator, staff_user);
        if (!web_auth.allowed(staff_user)) {
            _ = try self.store.revokeToken(staff_token);
            return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &no_store);
        }
        if (req.head.method == .POST and (!web_auth.sameOrigin(origin_owned, host_owned) or !web_auth.csrfMatches(staff_token, csrf_owned))) return respond(req, .forbidden, "application/json", "{\"error\":\"invalid request\"}", &no_store);

        if (std.mem.eql(u8, path, "/api/v1/staff/infrastructure")) {
            if (!web_auth.canDevelop(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"developer access required\"}", &no_store);
            if (req.head.method == .GET) {
                const json = try self.staffInfrastructureJson();
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const kind = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"kind"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"control kind required\"}", &no_store);
                defer self.allocator.free(kind);
                const reason_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &no_store);
                defer self.allocator.free(reason_value);
                const reason = std.mem.trim(u8, reason_value, " \t\r\n");
                if (!validWebText(reason, 3, 500)) return respond(req, .bad_request, "application/json", "{\"error\":\"reason must be between 3 and 500 characters\"}", &no_store);
                if (std.mem.eql(u8, kind, "feature")) {
                    const feature_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"feature"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"feature required\"}", &no_store);
                    defer self.allocator.free(feature_value);
                    const state_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"state"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"state required\"}", &no_store);
                    defer self.allocator.free(state_value);
                    const feature = server_control.Feature.parse(feature_value) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"unknown feature\"}", &no_store);
                    const enabled = if (std.mem.eql(u8, state_value, "enabled")) true else if (std.mem.eql(u8, state_value, "disabled")) false else return respond(req, .bad_request, "application/json", "{\"error\":\"state must be enabled or disabled\"}", &no_store);
                    try self.setFeatureControl(staff_user.id, feature, enabled, reason);
                    std.log.warn("event=staff_feature_control actor_id={d} feature={s} state={s}", .{ staff_user.id, feature.key(), state_value });
                    return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
                }
                if (!std.mem.eql(u8, kind, "operation")) return respond(req, .bad_request, "application/json", "{\"error\":\"unknown control kind\"}", &no_store);
                const operation = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"operation"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"operation required\"}", &no_store);
                defer self.allocator.free(operation);
                if (std.mem.eql(u8, operation, "announcement")) {
                    const message_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"announcement required\"}", &no_store);
                    defer self.allocator.free(message_value);
                    const message = std.mem.trim(u8, message_value, " \t\r\n");
                    if (!validWebText(message, 3, 500)) return respond(req, .bad_request, "application/json", "{\"error\":\"announcement must be between 3 and 500 characters\"}", &no_store);
                    try self.store.recordStaffAnnouncement(staff_user.id, message, reason);
                    bancho.publishAnnouncement(self.allocator, &self.sessions, message) catch |err|
                        std.log.warn("event=staff_announcement_live_delivery_failed actor_id={d} error={t}", .{ staff_user.id, err });
                } else if (std.mem.eql(u8, operation, "refresh_changelog")) {
                    self.changelog_feed.refresh() catch return respond(req, .bad_gateway, "application/json", "{\"error\":\"changelog refresh failed\"}", &no_store);
                    try self.store.recordAudit(staff_user.id, "infra.refresh_changelog", "server", reason);
                } else if (std.mem.eql(u8, operation, "refresh_matchmaking")) {
                    self.lazer_multiplayer.refreshMatchmakingMaps() catch return respond(req, .bad_gateway, "application/json", "{\"error\":\"matchmaking refresh failed\"}", &no_store);
                    try self.store.recordAudit(staff_user.id, "infra.refresh_matchmaking", "server", reason);
                } else if (std.mem.eql(u8, operation, "refresh_rank_history")) {
                    self.store.refreshStatsHistory() catch return respond(req, .internal_server_error, "application/json", "{\"error\":\"rank history refresh failed\"}", &no_store);
                    try self.store.recordAudit(staff_user.id, "infra.refresh_rank_history", "server", reason);
                } else if (std.mem.eql(u8, operation, "restart")) {
                    const confirmation = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"confirmation"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"type restart zigcho to confirm\"}", &no_store);
                    defer self.allocator.free(confirmation);
                    if (!std.mem.eql(u8, std.mem.trim(u8, confirmation, " \t\r\n"), "restart zigcho")) return respond(req, .bad_request, "application/json", "{\"error\":\"type restart zigcho to confirm\"}", &no_store);
                    try self.store.recordAudit(staff_user.id, "infra.restart", "server", reason);
                    std.log.warn("event=staff_server_restart actor_id={d} reason={s}", .{ staff_user.id, reason });
                    try respond(req, .accepted, "application/json", "{\"ok\":true,\"state\":\"restarting\"}", &no_store);
                    requestServerRestart();
                    return;
                } else return respond(req, .bad_request, "application/json", "{\"error\":\"unknown operation\"}", &no_store);
                std.log.info("event=staff_infrastructure_operation actor_id={d} operation={s}", .{ staff_user.id, operation });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/pp")) {
            if (!web_auth.canDevelop(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"developer access required\"}", &no_store);
            if (req.head.method == .GET) {
                var metadata: [384]u8 = undefined;
                const json = try std.fmt.bufPrint(
                    &metadata,
                    "{{\"policy\":\"{s}\",\"engine\":\"{s}\",\"max_map_bytes\":{d},\"max_mods_json_bytes\":{d},\"max_preview_items\":{d},\"max_recalculation_items\":{d},\"live\":true,\"apply\":false}}",
                    .{ pp_admin.policy_version, pp_admin.upstream_engine_version, pp_admin.max_map_bytes, pp_admin.max_mods_json_bytes, pp_admin.max_preview_items, pp_admin.max_recalculation_items },
                );
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const parsed = std.json.parseFromSlice(StaffPpPreviewRequest, self.allocator, body, .{ .ignore_unknown_fields = false }) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid pp preview input\"}", &no_store);
                defer parsed.deinit();
                const input = parsed.value;
                if (input.beatmap_id <= 0 or input.mode > 3) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap or mode\"}", &no_store);
                const map_file = (try self.store.beatmapFileById(self.allocator, input.beatmap_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap payload not found\"}", &no_store);
                defer self.allocator.free(map_file);
                const result = pp_admin.compare(self.allocator, map_file, .{
                    .source = input.source,
                    .namespace = input.namespace,
                    .input = .{
                        .mode = input.mode,
                        .lazer = if (input.source == .lazer) 1 else 0,
                        .mods = input.mods,
                        .max_combo = input.max_combo,
                        .large_tick_hits = input.large_tick_hits,
                        .small_tick_hits = input.small_tick_hits,
                        .slider_end_hits = input.slider_end_hits,
                        .n_geki = input.n_geki,
                        .n_katu = input.n_katu,
                        .n300 = input.n300,
                        .n100 = input.n100,
                        .n50 = input.n50,
                        .misses = input.misses,
                        .legacy_total_score = input.legacy_total_score,
                    },
                    .mods_json = if (input.source == .lazer) input.mods_json else "",
                }) catch |err| {
                    std.log.warn("event=staff_pp_preview_failed actor_id={d} beatmap_id={d} error={t}", .{ staff_user.id, input.beatmap_id, err });
                    return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"pp preview could not be calculated\"}", &no_store);
                };
                const json = try staffPpComparisonJson(self.allocator, result);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/overview") and req.head.method == .GET) {
            const json = try self.store.staffOverviewJson(self.allocator);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/roles")) {
            if (!web_auth.canDevelop(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"developer access required\"}", &no_store);
            if (req.head.method == .GET) {
                const user_text = queryField(target, "user") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player id required\"}", &no_store);
                const target_id = std.fmt.parseInt(i32, user_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player id\"}", &no_store);
                if (target_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player id\"}", &no_store);
                const json = (try self.store.staffRolesJson(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const user_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"user_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player required\"}", &no_store);
                defer self.allocator.free(user_text);
                const role_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"role"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"role required\"}", &no_store);
                defer self.allocator.free(role_text);
                const state_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"state"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"state required\"}", &no_store);
                defer self.allocator.free(state_text);
                const reason_value = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &no_store);
                defer self.allocator.free(reason_value);
                const target_id = std.fmt.parseInt(i32, user_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
                const role = account_roles.Role.parse(role_text) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"unknown role\"}", &no_store);
                const grant = if (std.mem.eql(u8, state_text, "grant")) true else if (std.mem.eql(u8, state_text, "revoke")) false else return respond(req, .bad_request, "application/json", "{\"error\":\"state must be grant or revoke\"}", &no_store);
                const reason = std.mem.trim(u8, reason_value, " \t\r\n");
                if (target_id <= 0 or !account_roles.validReason(reason)) return respond(req, .bad_request, "application/json", "{\"error\":\"reason must be between 3 and 500 characters\"}", &no_store);
                const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
                defer freeUser(self.allocator, target_user);
                if (!web_auth.canManage(staff_user, target_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"bot and self role changes are blocked\"}", &no_store);
                const transition = self.gameSessionMutex(target_id);
                transition.lockUncancelable(self.store.io);
                defer transition.unlock(self.store.io);
                const result = self.store.changeRole(staff_user.id, target_id, role, grant, reason) catch |err| switch (err) {
                    error.RoleStateUnchanged => return respond(req, .conflict, "application/json", "{\"error\":\"player already has that role state\"}", &no_store),
                    error.InvalidRoleChange => return respond(req, .bad_request, "application/json", "{\"error\":\"invalid role change\"}", &no_store),
                    else => return err,
                };
                self.sessions.mutex.lockUncancelable(self.sessions.io);
                defer self.sessions.mutex.unlock(self.sessions.io);
                if (self.sessions.byUser(target_id)) |online| {
                    online.user.privileges = result.privileges;
                    var packet = protocol.Writer.init(self.allocator);
                    defer packet.deinit();
                    try packet.packetInt(.privileges, stableClientPrivileges(result.privileges));
                    try online.enqueue(self.allocator, packet.bytes());
                }
                std.log.warn("event=staff_role_change actor_id={d} target_id={d} role={s} state={s} staff_sessions_revoked={}", .{ staff_user.id, target_id, @tagName(role), state_text, result.staff_sessions_revoked });
                var response_buf: [128]u8 = undefined;
                const response = try std.fmt.bufPrint(&response_buf, "{{\"ok\":true,\"privileges\":{d},\"staff_sessions_revoked\":{}}}", .{ result.privileges, result.staff_sessions_revoked });
                return respond(req, .ok, "application/json", response, &no_store);
            }
            return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &no_store);
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/users") and req.head.method == .GET) {
            if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
            const encoded_query = queryField(target, "q") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"search text required\"}", &no_store);
            const query_buffer = try self.allocator.dupe(u8, encoded_query);
            defer self.allocator.free(query_buffer);
            for (query_buffer) |*char| if (char.* == '+') {
                char.* = ' ';
            };
            const query = std.mem.trim(u8, std.Uri.percentDecodeInPlace(query_buffer), " \t\r\n");
            if (query.len < 1 or query.len > 32) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid search\"}", &no_store);
            const json = try self.store.staffUserSearchJson(self.allocator, query);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/ranking")) {
            if (!web_auth.canRank(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"ranking access required\"}", &no_store);
            if (req.head.method == .GET) {
                const json = try self.store.staffRankingJson(self.allocator);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const set_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"set_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"set required\"}", &no_store);
                defer self.allocator.free(set_text);
                const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &no_store);
                defer self.allocator.free(action);
                const reason = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &no_store);
                defer self.allocator.free(reason);
                const set_id = std.fmt.parseInt(i32, set_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid set\"}", &no_store);
                if (set_id <= 0 or !validWebText(reason, 3, 1000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid ranking action\"}", &no_store);
                const md5 = (try self.store.beatmapMd5ForSet(set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &no_store);
                const trimmed_reason = std.mem.trim(u8, reason, " \t\r\n");
                if (std.mem.eql(u8, action, "nominate")) {
                    _ = self.store.nominateBeatmapSet(staff_user.id, &md5, trimmed_reason) catch return respond(req, .conflict, "application/json", "{\"error\":\"nomination was not accepted\"}", &no_store);
                } else {
                    const rank_action: domain.BeatmapRankAction = if (std.mem.eql(u8, action, "pending")) .pending else if (std.mem.eql(u8, action, "qualify")) .qualify else if (std.mem.eql(u8, action, "rank")) .rank else if (std.mem.eql(u8, action, "approve")) .approve else if (std.mem.eql(u8, action, "love")) .love else if (std.mem.eql(u8, action, "veto")) .veto else if (std.mem.eql(u8, action, "rollback") and web_auth.canAdmin(staff_user)) .rollback else return respond(req, .bad_request, "application/json", "{\"error\":\"invalid ranking action\"}", &no_store);
                    _ = self.store.applyBeatmapRankAction(staff_user.id, &md5, rank_action, trimmed_reason) catch return respond(req, .conflict, "application/json", "{\"error\":\"ranking transition was not accepted\"}", &no_store);
                }
                std.log.info("event=staff_ranking_action actor_id={d} set_id={d} action={s}", .{ staff_user.id, set_id, action });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/moderation")) {
            if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
            if (req.head.method == .GET) {
                const user_text = queryField(target, "user") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player required\"}", &no_store);
                var target_id = std.fmt.parseInt(i32, user_text, 10) catch 0;
                if (target_id <= 0) {
                    const encoded = try self.allocator.dupe(u8, user_text);
                    defer self.allocator.free(encoded);
                    for (encoded) |*char| if (char.* == '+') {
                        char.* = ' ';
                    };
                    const decoded = std.Uri.percentDecodeInPlace(encoded);
                    const found = (try self.store.userByName(self.allocator, decoded)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
                    defer freeUser(self.allocator, found);
                    target_id = found.id;
                }
                const json = (try self.store.staffUserJson(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const user_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"user_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"player required\"}", &no_store);
                defer self.allocator.free(user_text);
                const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &no_store);
                defer self.allocator.free(action);
                const reason = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &no_store);
                defer self.allocator.free(reason);
                const target_id = std.fmt.parseInt(i32, user_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid player\"}", &no_store);
                if (!validWebText(reason, 3, 1000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid reason\"}", &no_store);
                const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &no_store);
                defer freeUser(self.allocator, target_user);
                if (!web_auth.canManage(staff_user, target_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"protected player\"}", &no_store);
                const trimmed_reason = std.mem.trim(u8, reason, " \t\r\n");
                if (std.mem.eql(u8, action, "revoke_sessions")) {
                    if (!web_auth.canAdmin(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"admin access required\"}", &no_store);
                    _ = try self.disconnectUser(target_id, trimmed_reason, .all);
                    try self.store.recordModerationAction(staff_user.id, target_id, "account.sessions_revoke", trimmed_reason);
                } else if (std.mem.eql(u8, action, "reset_avatar") or std.mem.eql(u8, action, "reset_banner")) {
                    if (!web_auth.canAdmin(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"admin access required\"}", &no_store);
                    const is_avatar = std.mem.eql(u8, action, "reset_avatar");
                    const previous = if (is_avatar) try self.store.customAvatarForUser(self.allocator, target_id) else try self.store.customBannerForUser(self.allocator, target_id);
                    defer if (previous) |value| {
                        var image = value;
                        image.deinit();
                    };
                    if (previous == null) return respond(req, .conflict, "application/json", if (is_avatar) "{\"error\":\"player has no custom avatar\"}" else "{\"error\":\"player has no custom banner\"}", &no_store);
                    _ = if (is_avatar) try self.store.deleteCustomAvatar(target_id) else try self.store.deleteCustomBanner(target_id);
                    if (previous) |image| {
                        self.avatar_cache.remove(image.object_key);
                        self.avatar_store.delete(self.allocator, self.store.io, image.object_key) catch |err| std.log.warn("event=staff_profile_object_delete_failed user_id={d} kind={s} error={t}", .{ target_id, if (is_avatar) "avatar" else "banner", err });
                    }
                    try self.store.recordModerationAction(staff_user.id, target_id, if (is_avatar) "account.avatar_reset" else "account.banner_reset", trimmed_reason);
                } else if (std.mem.eql(u8, action, "kick")) {
                    if (!try self.disconnectUser(target_id, trimmed_reason, .game)) return respond(req, .conflict, "application/json", "{\"error\":\"player is not online\"}", &no_store);
                    try self.store.recordModerationAction(staff_user.id, target_id, "account.kick", trimmed_reason);
                } else if (std.mem.eql(u8, action, "note")) {
                    try self.store.addModerationNote(staff_user.id, target_id, trimmed_reason);
                } else if (std.mem.eql(u8, action, "silence") or std.mem.eql(u8, action, "unsilence")) {
                    var seconds: i64 = 0;
                    if (std.mem.eql(u8, action, "silence")) {
                        const duration = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"duration"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"duration required\"}", &no_store);
                        defer self.allocator.free(duration);
                        seconds = std.fmt.parseInt(i64, duration, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid duration\"}", &no_store);
                        if (seconds < 60 or seconds > 365 * 86400) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid duration\"}", &no_store);
                    }
                    const silence_end = if (seconds == 0) @as(i64, 0) else std.Io.Clock.real.now(self.store.io).toSeconds() + seconds;
                    try self.store.setSilence(staff_user.id, target_id, silence_end, if (seconds == 0) "account.unsilence" else "account.silence", trimmed_reason);
                    self.sessions.mutex.lockUncancelable(self.sessions.io);
                    defer self.sessions.mutex.unlock(self.sessions.io);
                    if (self.sessions.byUser(target_id)) |online| {
                        online.user.silence_end = silence_end;
                        var packet = protocol.Writer.init(self.allocator);
                        defer packet.deinit();
                        try packet.packetInt(.silence_end, @intCast(@min(seconds, std.math.maxInt(i32))));
                        try online.enqueue(self.allocator, packet.bytes());
                        if (seconds > 0) {
                            packet.list.clearRetainingCapacity();
                            try packet.packetInt(.user_silenced, target_id);
                            try self.sessions.broadcast(packet.bytes(), null);
                        }
                    }
                } else if (std.mem.eql(u8, action, "restrict") or std.mem.eql(u8, action, "unrestrict")) {
                    if (!web_auth.canAdmin(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"admin access required\"}", &no_store);
                    const restricted = std.mem.eql(u8, action, "restrict");
                    if (target_user.restricted == restricted) return respond(req, .conflict, "application/json", "{\"error\":\"player already has that state\"}", &no_store);
                    const mutex = self.gameSessionMutex(target_id);
                    mutex.lockUncancelable(self.store.io);
                    defer mutex.unlock(self.store.io);
                    if (restricted) {
                        var prepared = try bancho.prepareSuppression(self.allocator, trimmed_reason);
                        defer prepared.deinit();
                        try self.store.setRestricted(staff_user.id, target_id, true, trimmed_reason);
                        _ = self.finishDisconnectPrepared(target_id, &prepared);
                    } else {
                        try self.store.setRestricted(staff_user.id, target_id, false, trimmed_reason);
                        self.sessions.mutex.lockUncancelable(self.sessions.io);
                        defer self.sessions.mutex.unlock(self.sessions.io);
                        if (self.sessions.byUser(target_id)) |online| online.user.restricted = false;
                    }
                } else return respond(req, .bad_request, "application/json", "{\"error\":\"invalid moderation action\"}", &no_store);
                std.log.info("event=staff_moderation_action actor_id={d} target_id={d} action={s}", .{ staff_user.id, target_id, action });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/appeals")) {
            if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
            if (req.head.method == .GET) {
                const json = try self.store.staffAppealsJson(self.allocator);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const id_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"appeal_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"appeal required\"}", &no_store);
                defer self.allocator.free(id_text);
                const decision = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"decision"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"decision required\"}", &no_store);
                defer self.allocator.free(decision);
                const resolution = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"resolution"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"resolution required\"}", &no_store);
                defer self.allocator.free(resolution);
                const appeal_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid appeal\"}", &no_store);
                if ((!std.mem.eql(u8, decision, "accepted") and !std.mem.eql(u8, decision, "denied")) or !validWebText(resolution, 3, 2000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid decision\"}", &no_store);
                self.store.resolveModerationAppeal(staff_user.id, appeal_id, decision, std.mem.trim(u8, resolution, " \t\r\n")) catch return respond(req, .conflict, "application/json", "{\"error\":\"appeal is not open\"}", &no_store);
                std.log.info("event=staff_appeal_decision actor_id={d} appeal_id={d} decision={s}", .{ staff_user.id, appeal_id, decision });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/reports")) {
            if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
            if (req.head.method == .GET) {
                const json = try self.store.staffLazerReportsJson(self.allocator);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const id_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"report_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"report required\"}", &no_store);
                defer self.allocator.free(id_text);
                const decision = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"decision"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"decision required\"}", &no_store);
                defer self.allocator.free(decision);
                const report_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid report\"}", &no_store);
                if (report_id <= 0 or (!std.mem.eql(u8, decision, "resolved") and !std.mem.eql(u8, decision, "dismissed"))) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid decision\"}", &no_store);
                if (!try self.store.resolveLazerReport(staff_user.id, report_id, decision)) return respond(req, .conflict, "application/json", "{\"error\":\"report is not open\"}", &no_store);
                std.log.info("event=staff_lazer_report_decision actor_id={d} report_id={d} decision={s}", .{ staff_user.id, report_id, decision });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/anticheat")) {
            if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
            if (req.head.method == .GET) {
                const json = try self.store.staffAnticheatJson(self.allocator);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const id_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"observation_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"observation required\"}", &no_store);
                defer self.allocator.free(id_text);
                const label_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"label"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"label required\"}", &no_store);
                defer self.allocator.free(label_text);
                const note = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"note"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"review note required\"}", &no_store);
                defer self.allocator.free(note);
                const observation_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid observation\"}", &no_store);
                const label = storage.AnticheatReviewLabel.parse(label_text) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid review label\"}", &no_store);
                if (!validWebText(note, 3, 1000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid review note\"}", &no_store);
                self.store.reviewAnticheatObservation(staff_user.id, observation_id, label, note) catch |err| switch (err) {
                    error.AnticheatObservationNotFound => return respond(req, .not_found, "application/json", "{\"error\":\"observation not found\"}", &no_store),
                    else => return err,
                };
                std.log.info("event=staff_anticheat_review actor_id={d} observation_id={d} label={s}", .{ staff_user.id, observation_id, label.text() });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/audit") and req.head.method == .GET) {
            if (!web_auth.canModerate(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"moderation access required\"}", &no_store);
            const json = try self.store.staffAuditJson(self.allocator);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &no_store);
        }
        if (std.mem.eql(u8, path, "/api/v1/staff/channels")) {
            if (!web_auth.canAdmin(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"admin access required\"}", &no_store);
            if (req.head.method == .GET) {
                const json = try self.store.staffChannelsJson(self.allocator);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &no_store);
            }
            if (req.head.method == .POST) {
                const channel = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"channel"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"channel required\"}", &no_store);
                defer self.allocator.free(channel);
                const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &no_store);
                defer self.allocator.free(action);
                const reason = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &no_store);
                defer self.allocator.free(reason);
                if ((!std.mem.eql(u8, action, "lock") and !std.mem.eql(u8, action, "unlock")) or !validWebText(reason, 3, 1000)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid channel action\"}", &no_store);
                self.store.setChannelLocked(staff_user.id, channel, std.mem.eql(u8, action, "lock"), std.mem.trim(u8, reason, " \t\r\n")) catch return respond(req, .bad_request, "application/json", "{\"error\":\"unknown channel\"}", &no_store);
                std.log.info("event=staff_channel_action actor_id={d} channel={s} action={s}", .{ staff_user.id, channel, action });
                return respond(req, .ok, "application/json", "{\"ok\":true}", &no_store);
            }
        }
        const known_staff_path = std.mem.eql(u8, path, "/api/v1/staff/infrastructure") or
            std.mem.eql(u8, path, "/api/v1/staff/pp") or
            std.mem.eql(u8, path, "/api/v1/staff/overview") or
            std.mem.eql(u8, path, "/api/v1/staff/users") or
            std.mem.eql(u8, path, "/api/v1/staff/ranking") or
            std.mem.eql(u8, path, "/api/v1/staff/moderation") or
            std.mem.eql(u8, path, "/api/v1/staff/appeals") or
            std.mem.eql(u8, path, "/api/v1/staff/reports") or
            std.mem.eql(u8, path, "/api/v1/staff/anticheat") or
            std.mem.eql(u8, path, "/api/v1/staff/audit") or
            std.mem.eql(u8, path, "/api/v1/staff/channels");
        return respond(req, if (known_staff_path) .method_not_allowed else .not_found, "application/json", if (known_staff_path) "{\"error\":\"method not allowed\"}" else "{\"error\":\"not found\"}", &no_store);
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v1/rankings")) {
        const source = domain.parseSiteScoreSource(queryField(target, "source") orelse "all") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid source\"}", &.{});
        const mode = std.fmt.parseInt(u8, queryField(target, "mode") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
        const offset = beatmapSearchOffset(target) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
        if (!domain.validSiteMode(source, mode) or offset > 10_000) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid rankings\"}", &.{});
        const listing = try self.store.siteRankings(self.allocator, source, mode, offset);
        defer self.allocator.free(listing);
        return respond(req, .ok, "application/json", listing, &.{});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/users/") and std.mem.endsWith(u8, path, "/name-history")) {
        const prefix = "/api/v1/users/";
        const suffix = "/name-history";
        const encoded_identifier = path[prefix.len .. path.len - suffix.len];
        if (encoded_identifier.len == 0 or encoded_identifier.len > 96 or std.mem.indexOfScalar(u8, encoded_identifier, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
        const identifier_buffer = try self.allocator.dupe(u8, encoded_identifier);
        defer self.allocator.free(identifier_buffer);
        const identifier = std.Uri.percentDecodeInPlace(identifier_buffer);
        if (identifier.len < 1 or identifier.len > 32 or std.mem.indexOfScalar(u8, identifier, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
        const user_id = std.fmt.parseInt(i32, identifier, 10) catch resolve: {
            const found = (try self.store.userByName(self.allocator, identifier)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
            defer freeUser(self.allocator, found);
            break :resolve found.id;
        };
        if (user_id <= 0) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
        const history = (try self.store.siteNameHistoryJson(self.allocator, user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
        defer self.allocator.free(history);
        return respond(req, .ok, "application/json", history, &.{.{ .name = "cache-control", .value = "public, max-age=60" }});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/users/")) {
        const encoded_identifier = path["/api/v1/users/".len..];
        if (encoded_identifier.len == 0 or encoded_identifier.len > 96 or std.mem.indexOfScalar(u8, encoded_identifier, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
        const identifier_buffer = try self.allocator.dupe(u8, encoded_identifier);
        defer self.allocator.free(identifier_buffer);
        const identifier = std.Uri.percentDecodeInPlace(identifier_buffer);
        if (identifier.len < 1 or identifier.len > 32 or std.mem.indexOfScalar(u8, identifier, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
        const user_id = std.fmt.parseInt(i32, identifier, 10) catch resolve: {
            const found = (try self.store.userByName(self.allocator, identifier)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
            defer self.allocator.free(found.name);
            defer self.allocator.free(found.safe_name);
            break :resolve found.id;
        };
        if (user_id <= 0) return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
        const source = domain.parseSiteScoreSource(queryField(target, "source") orelse "all") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid source\"}", &.{});
        const mode = std.fmt.parseInt(u8, queryField(target, "mode") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
        if (!domain.validSiteMode(source, mode)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
        const viewer_id: ?i32 = viewer: {
            const token = web_auth.playerSessionToken(cookie_owned) orelse break :viewer null;
            const viewer_user = (try self.store.authenticateToken(self.allocator, token, web_auth.player_scope)) orelse break :viewer null;
            defer freeUser(self.allocator, viewer_user);
            break :viewer viewer_user.id;
        };
        const profile = if (user_id == 3) bot_profile: {
            const bot_user = (try self.store.userById(self.allocator, user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
            defer freeUser(self.allocator, bot_user);
            break :bot_profile try user_json.siteBotProfileOwned(self.allocator, bot_user);
        } else player_profile: {
            break :player_profile (try self.store.siteProfileForViewer(self.allocator, user_id, source, mode, viewer_id != null and viewer_id.? == user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
        };
        defer self.allocator.free(profile);
        const with_presence = try self.attachProfilePresence(profile, user_id, viewer_id);
        defer self.allocator.free(with_presence);
        return respond(req, .ok, "application/json", with_presence, &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/beatmapsets/")) {
        const set_id = std.fmt.parseInt(i32, path["/api/v1/beatmapsets/".len..], 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
        if (set_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
        if (!try self.store.beatmapSetExists(set_id)) _ = self.map_sync.ensureBySetId(&self.store, set_id) catch |err|
            std.log.warn("event=site_beatmap_set_hydration_failed set_id={d} error={t}", .{ set_id, err });
        self.ensureMapperForSet(set_id);
        const set = (try self.store.lazerBeatmapSet(self.allocator, set_id, null)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
        defer self.allocator.free(set);
        return respond(req, .ok, "application/json", set, &.{});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/beatmaps/") and std.mem.endsWith(u8, path, "/leaderboard")) {
        const id_text = path["/api/v1/beatmaps/".len .. path.len - "/leaderboard".len];
        if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap\"}", &.{});
        const map_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap\"}", &.{});
        const source = domain.parseSiteScoreSource(queryField(target, "source") orelse "all") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid source\"}", &.{});
        const mode = std.fmt.parseInt(u8, queryField(target, "mode") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
        if (map_id <= 0 or !domain.validSiteMode(source, mode)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid leaderboard\"}", &.{});
        const board = (try self.store.siteBeatmapLeaderboard(self.allocator, map_id, source, mode)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap not found for that ruleset\"}", &.{});
        defer self.allocator.free(board);
        return respond(req, .ok, "application/json", board, &.{});
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
