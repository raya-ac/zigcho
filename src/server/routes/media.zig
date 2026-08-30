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
    const path = ctx.path;
    const auth_owned = ctx.auth_owned;
    const host_owned = ctx.host_owned;
    const cookie_owned = ctx.cookie_owned;
    if (req.head.method == .GET) if (lazer.parseScoreDownloadPath(path)) |score_id| {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const stable_score_id = lazer.decodeStableScoreId(score_id);
        const replay = if (stable_score_id) |stable_id|
            try self.store.siteReplay(self.allocator, stable_id)
        else
            try self.store.lazerReplay(self.allocator, score_id);
        const data = replay orelse return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
        defer self.allocator.free(data);
        self.recordReplayViewBestEffort(user.id, if (stable_score_id != null) .stable else .lazer, stable_score_id orelse score_id);
        var disposition_buf: [96]u8 = undefined;
        const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"kai-{s}-score-{d}.osr\"", .{ if (stable_score_id != null) "stable" else "lazer", stable_score_id orelse score_id });
        return respond(req, .ok, "application/x-osu-replay", data, &.{
            .{ .name = "content-disposition", .value = disposition },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        });
    };
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/replays/stable/")) {
        const id_text = path["/replays/stable/".len..];
        if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
        const score_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
        const replay = (try self.store.siteReplay(self.allocator, score_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
        defer self.allocator.free(replay);
        if (self.websiteViewerId(cookie_owned)) |viewer_id| self.recordReplayViewBestEffort(viewer_id, .stable, score_id);
        var disposition_buf: [96]u8 = undefined;
        const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"kai-score-{d}.osr\"", .{score_id});
        return respond(req, .ok, "application/octet-stream", replay, &.{
            .{ .name = "content-disposition", .value = disposition },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        });
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/replays/lazer/")) {
        const id_text = path["/replays/lazer/".len..];
        if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
        const score_id = std.fmt.parseInt(i64, id_text, 10) catch return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
        const replay = (try self.store.lazerReplay(self.allocator, score_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"replay not found\"}", &.{});
        defer self.allocator.free(replay);
        if (self.websiteViewerId(cookie_owned)) |viewer_id| self.recordReplayViewBestEffort(viewer_id, .lazer, score_id);
        var disposition_buf: [96]u8 = undefined;
        const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"kai-lazer-score-{d}.osr\"", .{score_id});
        return respond(req, .ok, "application/x-osu-replay", replay, &.{
            .{ .name = "content-disposition", .value = disposition },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        });
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/ss/")) {
        const requested = screenshot.parsePath(path) orelse return respond(req, .not_found, "application/json", "{\"status\":\"Screenshot not found.\"}", &.{});
        const image = (try self.store.screenshot(self.allocator, requested.token, requested.kind.extension())) orelse return respond(req, .not_found, "application/json", "{\"status\":\"Screenshot not found.\"}", &.{});
        defer self.allocator.free(image);
        return respond(req, .ok, requested.kind.contentType(), image, &.{
            .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        });
    }
    if (req.head.method == .GET) {
        if (media_contract.parsePath(path)) |media_request| {
            var asset = (self.media_sync.get(&self.store, media_request) catch |err| {
                std.log.warn("beatmap media fetch failed set_id={d} kind={s}: {t}", .{ media_request.set_id, media_request.kind.dbName(), err });
                return respond(req, .bad_gateway, "application/json", "{\"error\":\"beatmap media upstream unavailable\"}", &.{.{ .name = "cache-control", .value = "no-store" }});
            }) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap media unavailable\"}", &.{.{ .name = "cache-control", .value = "public, max-age=300" }});
            defer asset.deinit(self.allocator);
            return respond(req, .ok, asset.content_type.value(), asset.data, &.{
                .{ .name = "cache-control", .value = "public, max-age=86400" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            });
        }
    }
    if (req.head.method == .GET and isAssetsHost(host_owned) and std.mem.startsWith(u8, path, "/banners/")) {
        const user_id = profile_banner.assetUserId(path) orelse return respond(req, .not_found, "application/json", "{\"error\":\"banner not found\"}", &.{});
        const banner = (try self.store.customBannerForUser(self.allocator, user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"banner not found\"}", &.{});
        return self.serveObjectImage(req, banner);
    }
    if (req.head.method == .GET and isAssetsHost(host_owned) and std.mem.startsWith(u8, path, "/teams/")) {
        var parts = std.mem.splitScalar(u8, path["/teams/".len..], '/');
        const id_text = parts.next() orelse return respond(req, .not_found, "application/json", "{\"error\":\"team image not found\"}", &.{});
        const kind = parts.next() orelse return respond(req, .not_found, "application/json", "{\"error\":\"team image not found\"}", &.{});
        if (parts.next() != null or (!std.mem.eql(u8, kind, "flag") and !std.mem.eql(u8, kind, "header"))) return respond(req, .not_found, "application/json", "{\"error\":\"team image not found\"}", &.{});
        const team_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .not_found, "application/json", "{\"error\":\"team image not found\"}", &.{});
        const image = (try self.store.teamAsset(self.allocator, team_id, kind)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"team image not found\"}", &.{});
        return self.serveObjectImage(req, image);
    }
    if (req.head.method == .GET and (isAvatarHost(host_owned) or std.mem.startsWith(u8, path, "/avatars/") or std.mem.startsWith(u8, path, "/avatar/"))) {
        if (avatarUserId(path)) |user_id| {
            if (try self.store.customAvatarForUser(self.allocator, user_id)) |avatar_value| {
                var avatar = avatar_value;
                defer avatar.deinit();
                var data = self.avatar_cache.get(avatar.object_key) catch |err| cache_error: {
                    std.log.warn("event=website_avatar_cache_read_failed user_id={d} error={t}", .{ user_id, err });
                    break :cache_error null;
                };
                if (data == null) {
                    const fetched = self.avatar_store.get(self.allocator, self.store.io, avatar.object_key, avatar.content_type) catch |err| {
                        std.log.warn("event=website_avatar_download_failed user_id={d} error={t}", .{ user_id, err });
                        return respond(req, .bad_gateway, "application/json", "{\"error\":\"avatar storage is not available\"}", &.{.{ .name = "cache-control", .value = "no-store" }});
                    };
                    self.avatar_cache.put(avatar.object_key, fetched) catch |err| std.log.warn("event=website_avatar_cache_write_failed user_id={d} error={t}", .{ user_id, err });
                    data = fetched;
                }
                const avatar_data = data.?;
                defer self.allocator.free(avatar_data);
                var etag_buf: [66]u8 = undefined;
                const etag = try std.fmt.bufPrint(&etag_buf, "\"{s}\"", .{&avatar.etag});
                const custom_headers = [_]std.http.Header{
                    .{ .name = "cache-control", .value = "public, max-age=300" },
                    .{ .name = "etag", .value = etag },
                    .{ .name = "x-content-type-options", .value = "nosniff" },
                };
                if (header(req, "if-none-match")) |current| if (std.mem.eql(u8, current, etag)) return respond(req, .not_modified, avatar.content_type, "", &custom_headers);
                return respond(req, .ok, avatar.content_type, avatar_data, &custom_headers);
            }
            const key = (try self.store.avatarForUser(user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"avatar not found\"}", &.{});
            const cache_headers = [_]std.http.Header{
                .{ .name = "cache-control", .value = "public, max-age=3600" },
                .{ .name = "etag", .value = if (key == 1) "\"default-avatar-1\"" else "\"default-avatar-2\"" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            };
            return if (key == 1)
                respond(req, .ok, "image/gif", default_avatar_1, &cache_headers)
            else
                respond(req, .ok, "image/jpeg", default_avatar_2, &cache_headers);
        }
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/d/")) {
        const raw_set_id = path[3..];
        const set_id_text = if (std.mem.endsWith(u8, raw_set_id, "n")) raw_set_id[0 .. raw_set_id.len - 1] else raw_set_id;
        const set_id = std.fmt.parseInt(i32, set_id_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
        if (set_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
        return self.serveBeatmapArchive(req, set_id);
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and std.mem.endsWith(u8, path, "/download")) {
        const id_text = path["/api/v2/beatmapsets/".len .. path.len - "/download".len];
        const set_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        return self.serveBeatmapArchive(req, set_id);
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmaps/") and std.mem.endsWith(u8, path, "/file")) {
        const id_text = path["/api/v2/beatmaps/".len .. path.len - "/file".len];
        const map_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const map_file = (try self.store.beatmapFileById(self.allocator, map_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap file unavailable\"}", &.{});
        defer self.allocator.free(map_file);
        var disposition_buf: [96]u8 = undefined;
        const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{d}.osu\"", .{map_id});
        const headers = [_]std.http.Header{.{ .name = "content-disposition", .value = disposition }};
        return respond(req, .ok, "application/x-osu-beatmap", map_file, &headers);
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
