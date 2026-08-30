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

fn dispatch(self: anytype, req: *std.http.Server.Request, ctx: *const Context) !void {
    const target = ctx.target;
    const path = ctx.path;
    const auth_owned = ctx.auth_owned;
    const host_owned = ctx.host_owned;
    if ((req.head.method == .GET or req.head.method == .HEAD) and !std.mem.eql(u8, path, "/") and web_auth.protocolHost(host_owned) and routing.websitePage(path)) {
        const location = try std.fmt.allocPrint(self.allocator, "https://kai.ovh{s}", .{target});
        defer self.allocator.free(location);
        return respond(req, .permanent_redirect, "text/plain", "", &.{.{ .name = "location", .value = location }});
    }
    if (web_auth.realtimeHost(host_owned) and std.mem.eql(u8, path, "/multiplayer/negotiate")) {
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
        const json = try lazer_multiplayer.negotiateJson(self.allocator, self.store.io);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (web_auth.realtimeHost(host_owned) and std.mem.eql(u8, path, "/multiplayer")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
        const key = switch (req.upgradeRequested()) {
            .websocket => |maybe_key| maybe_key orelse return respond(req, .bad_request, "application/json", "{\"error\":\"websocket key required\"}", &.{}),
            else => return respond(req, .bad_request, "application/json", "{\"error\":\"websocket upgrade required\"}", &.{}),
        };
        var socket = try req.respondWebSocket(.{ .key = key });
        try socket.flush();
        self.lazer_multiplayer.serve(user, &socket) catch |err| {
            std.log.info("event=lazer_multiplayer_connection_closed user_id={d} error={t}", .{ user.id, err });
        };
        return;
    }
    if (web_auth.realtimeHost(host_owned) and std.mem.eql(u8, path, "/spectator/negotiate")) {
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
        const json = try lazer_multiplayer.negotiateJson(self.allocator, self.store.io);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (web_auth.realtimeHost(host_owned) and std.mem.eql(u8, path, "/spectator")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
        const key = switch (req.upgradeRequested()) {
            .websocket => |maybe_key| maybe_key orelse return respond(req, .bad_request, "application/json", "{\"error\":\"websocket key required\"}", &.{}),
            else => return respond(req, .bad_request, "application/json", "{\"error\":\"websocket upgrade required\"}", &.{}),
        };
        var socket = try req.respondWebSocket(.{ .key = key });
        try socket.flush();
        self.lazer_spectator.serve(user, &socket) catch |err| {
            std.log.info("event=lazer_spectator_connection_closed user_id={d} error={t}", .{ user.id, err });
        };
        return;
    }
    if (std.mem.eql(u8, path, "/notification-endpoint")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
        const key = switch (req.upgradeRequested()) {
            .websocket => |maybe_key| maybe_key orelse return respond(req, .bad_request, "application/json", "{\"error\":\"websocket key required\"}", &.{}),
            else => return respond(req, .bad_request, "application/json", "{\"error\":\"websocket upgrade required\"}", &.{}),
        };
        var socket = try req.respondWebSocket(.{ .key = key });
        try socket.flush();
        lazer_notifications.serve(self.allocator, user.id, &socket) catch |err| {
            std.log.info("event=lazer_notifications_connection_closed user_id={d} error={t}", .{ user.id, err });
        };
        return;
    }
    if (req.head.method == .GET and (std.mem.eql(u8, path, "/api/v2/rooms") or lazer_multiplayer.parseRoomPath(path) != null)) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"authentication required\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"account restricted\"}", &.{});
        const room_id = lazer_multiplayer.parseRoomPath(path);
        const list_filter = if (room_id == null)
            lazer_multiplayer.roomListFilter(user.id, queryField(target, "mode") orelse "open", queryField(target, "status"), queryField(target, "category") orelse "") catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid room filter\"}", &.{})
        else
            null;
        const json = (try self.lazer_multiplayer.roomsJson(self.allocator, room_id, list_filter, user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room not found\"}", &.{});
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
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
