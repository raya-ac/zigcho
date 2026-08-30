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
const featureUnavailable = @import("../app/control.zig").featureUnavailable;

fn dispatch(self: anytype, req: *std.http.Server.Request, ctx: *const Context) !void {
    const target = ctx.target;
    const path = ctx.path;
    const auth_owned = ctx.auth_owned;
    const content_type_owned = ctx.content_type_owned;
    const body = ctx.body;
    if (std.mem.eql(u8, path, "/api/v2/mods")) return respond(req, .ok, "application/json", "{\"mods\":[{\"acronym\":\"RX\",\"name\":\"Relax\",\"description\":\"server accepted; separate relax leaderboard\",\"ranked\":true,\"score_multiplier\":0.0,\"settings\":{}},{\"acronym\":\"AP\",\"name\":\"Autopilot\",\"description\":\"server accepted; separate autopilot leaderboard\",\"ranked\":true,\"score_multiplier\":0.0,\"settings\":{}},{\"acronym\":\"CL\",\"name\":\"Classic\",\"description\":\"Stable score leaderboard\",\"ranked\":true,\"score_multiplier\":1.0,\"settings\":{}}],\"custom_mod_contract\":{\"acronym\":\"2-8 uppercase ASCII characters\",\"settings\":\"arbitrary JSON object\",\"leaderboard\":\"custom namespace\",\"ranked\":true}}", &.{});
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/seasonal-backgrounds")) return respond(req, .ok, "application/json", "{\"backgrounds\":[]}", &.{});
    if (std.mem.eql(u8, path, "/api/v2/session/verify") or std.mem.eql(u8, path, "/api/v2/session/verify/reissue") or std.mem.eql(u8, path, "/api/v2/session/verify/mail-fallback")) {
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        return respond(req, .ok, "application/json", "{}", &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/search")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (!std.mem.eql(u8, queryField(target, "mode") orelse "user", "user")) return respond(req, .bad_request, "application/json", "{\"error\":\"unsupported search mode\"}", &.{});
        const encoded = queryField(target, "query") orelse "";
        const query_buffer = try self.allocator.dupe(u8, encoded);
        defer self.allocator.free(query_buffer);
        for (query_buffer) |*char| if (char.* == '+') {
            char.* = ' ';
        };
        const query = std.mem.trim(u8, std.Uri.percentDecodeInPlace(query_buffer), " \t\r\n");
        if (query.len == 0 or query.len > 32) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid search\"}", &.{});
        const ids = try self.store.lazerUserSearchIds(self.allocator, query, 20);
        defer self.allocator.free(ids);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.print("{{\"total\":{d},\"user\":{{\"data\":[", .{ids.len});
        var written: usize = 0;
        for (ids) |id| {
            var found = (try self.store.userById(self.allocator, id)) orelse continue;
            defer freeUser(self.allocator, found);
            try self.markOnline(&found);
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try user_json.writeCompact(&output.writer, found, found.id == user.id or found.show_country);
        }
        try output.writer.writeAll("]}}");
        return respond(req, .ok, "application/json", output.written(), &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/news")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const year = if (queryField(target, "year")) |value| blk: {
            const parsed = std.fmt.parseInt(u16, value, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid year\"}", &.{});
            if (parsed < 2000 or parsed > 2100) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid year\"}", &.{});
            break :blk @as(?u16, parsed);
        } else null;
        const json = try self.changelog_feed.newsJson(self.allocator, year);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/spotlights")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        return respond(req, .ok, "application/json", "{\"spotlights\":[]}", &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/rankings/kudosu")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        return respond(req, .ok, "application/json", "{\"ranking\":[]}", &.{});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/wiki/")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const rest = path["/api/v2/wiki/".len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid wiki path\"}", &.{});
        if (slash == 0 or slash + 1 >= rest.len or rest.len > 512) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid wiki path\"}", &.{});
        const locale = rest[0..slash];
        const article_buffer = try self.allocator.dupe(u8, rest[slash + 1 ..]);
        defer self.allocator.free(article_buffer);
        const article = std.Uri.percentDecodeInPlace(article_buffer);
        const json = (try lazer_wiki.pageJson(self.allocator, locale, article)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"wiki page not found\"}", &.{});
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/chat/updates")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const since = std.fmt.parseInt(i64, queryField(target, "since") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid since\"}", &.{});
        if (since < 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid since\"}", &.{});
        const presence = try self.store.lazerChannelListJson(self.allocator, user.id);
        defer self.allocator.free(presence);
        const messages = if (queryField(target, "channel")) |channel_text| channel_messages: {
            const channel_id = std.fmt.parseInt(i64, channel_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid channel\"}", &.{});
            if (lazer.roomChannelRoom(channel_id) != null) {
                const room_id = self.lazer_multiplayer.roomChannelAccess(user.id, channel_id) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
                break :channel_messages try self.store.lazerRoomMessagesJson(self.allocator, room_id, since, 100);
            }
            if (lazer.privateChannelUser(channel_id)) |target_id| break :channel_messages try self.store.lazerDirectMessagesJson(self.allocator, user.id, target_id, since, 100);
            if (!lazer.validChannelId(channel_id)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid channel\"}", &.{});
            break :channel_messages try self.store.lazerChatMessagesJson(self.allocator, channel_id, since, 100);
        } else if (self.lazer_multiplayer.currentRoomId(user.id)) |room_id|
            try self.store.lazerAllMessagesForRoomJson(self.allocator, user.id, room_id, since, 100)
        else
            try self.store.lazerAllMessagesJson(self.allocator, user.id, since, 100);
        defer self.allocator.free(messages);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"presence\":");
        try output.writer.writeAll(presence);
        try output.writer.writeAll(",\"messages\":");
        try output.writer.writeAll(messages);
        try output.writer.writeByte('}');
        return respond(req, .ok, "application/json", output.written(), &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/web/osu-getseasonal.php")) return respond(req, .ok, "application/json", "[]", &.{});
    if (req.head.method == .GET and std.mem.eql(u8, path, "/menu-content.json")) return respond(req, .ok, "application/json", "{\"images\":[]}", &.{});
    if (std.mem.eql(u8, path, "/api/v2/notifications")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        return respond(req, .ok, "application/json", "{\"has_more\":false,\"notifications\":[],\"notification_endpoint\":\"wss://api.kai.ovh/notification-endpoint\"}", &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/comments")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (req.head.method == .GET) {
            const commentable_text = queryField(target, "commentable_type") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"commentable_type required\"}", &.{});
            const commentable = storage.LazerCommentable.parse(commentable_text) orelse return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid commentable_type\"}", &.{});
            const commentable_id = std.fmt.parseInt(i64, queryField(target, "commentable_id") orelse "", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid commentable_id\"}", &.{});
            const page = std.fmt.parseInt(u16, queryField(target, "page") orelse "1", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid page\"}", &.{});
            const parent_id = std.fmt.parseInt(i64, queryField(target, "parent_id") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid parent_id\"}", &.{});
            const sort = storage.LazerCommentSort.parse(queryField(target, "sort") orelse "new") orelse return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid sort\"}", &.{});
            if (commentable_id <= 0 or page == 0 or parent_id < 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid comment query\"}", &.{});
            if (commentable == .beatmapset and (commentable_id > std.math.maxInt(i32) or !try self.store.beatmapSetExists(@intCast(commentable_id)))) return respond(req, .not_found, "application/json", "{\"error\":\"beatmapset not found\"}", &.{});
            const json = try self.store.lazerCommentsJson(self.allocator, user.id, .{ .commentable = commentable, .id = commentable_id }, sort, page, parent_id, 0);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});
        const now = std.Io.Clock.real.now(self.sessions.io).toSeconds();
        if (user.silence_end > now) return respond(req, .forbidden, "application/json", "{\"error\":\"silenced\"}", &.{});
        const commentable_owned = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"comment[commentable_type]"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"commentable_type required\"}", &.{});
        defer self.allocator.free(commentable_owned);
        const commentable = storage.LazerCommentable.parse(commentable_owned) orelse return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid commentable_type\"}", &.{});
        const id_owned = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"comment[commentable_id]"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"commentable_id required\"}", &.{});
        defer self.allocator.free(id_owned);
        const commentable_id = std.fmt.parseInt(i64, id_owned, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid commentable_id\"}", &.{});
        const message_owned = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"comment[message]"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"message required\"}", &.{});
        defer self.allocator.free(message_owned);
        const message = std.mem.trim(u8, message_owned, " \t\r\n");
        const parent_owned = try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"comment[parent_id]"});
        defer if (parent_owned) |value| self.allocator.free(value);
        const parent_id: ?i64 = if (parent_owned) |value| std.fmt.parseInt(i64, value, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid parent_id\"}", &.{}) else null;
        if (commentable_id <= 0 or message.len == 0 or message.len > 1000 or !std.unicode.utf8ValidateSlice(message) or std.mem.indexOfScalar(u8, message, 0) != null) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid comment\"}", &.{});
        if (commentable == .beatmapset and (commentable_id > std.math.maxInt(i32) or !try self.store.beatmapSetExists(@intCast(commentable_id)))) return respond(req, .not_found, "application/json", "{\"error\":\"beatmapset not found\"}", &.{});
        const comment_target: storage.LazerCommentTarget = .{ .commentable = commentable, .id = commentable_id };
        const comment_id = self.store.addLazerComment(user.id, comment_target, parent_id, message) catch |err| return switch (err) {
            error.CommentParentNotFound => respond(req, .not_found, "application/json", "{\"error\":\"parent comment not found\"}", &.{}),
            else => respond(req, .internal_server_error, "application/json", "{\"error\":\"comment unavailable\"}", &.{}),
        };
        const json = try self.store.lazerCommentsJson(self.allocator, user.id, comment_target, .new, 1, 0, comment_id);
        defer self.allocator.free(json);
        return respond(req, .created, "application/json", json, &.{});
    }
    if (lazer.parseCommentVotePath(path)) |comment_id| {
        if (req.head.method != .POST and req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const comment_target = (try self.store.lazerCommentTarget(comment_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"comment not found\"}", &.{});
        _ = try self.store.setLazerCommentVote(user.id, comment_id, req.head.method == .POST);
        const json = try self.store.lazerCommentsJson(self.allocator, user.id, comment_target, .new, 1, 0, comment_id);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (lazer.parseCommentPath(path)) |comment_id| {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const comment_target = (try self.store.lazerCommentTarget(comment_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"comment not found\"}", &.{});
        if (req.head.method == .GET) {
            const json = try self.store.lazerCommentsJson(self.allocator, user.id, comment_target, .new, 1, 0, comment_id);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        if (!try self.store.deleteLazerComment(user.id, comment_id, web_auth.canModerate(user))) return respond(req, .forbidden, "application/json", "{\"error\":\"comment cannot be deleted\"}", &.{});
        const json = try self.store.lazerCommentsJson(self.allocator, user.id, comment_target, .new, 1, 0, comment_id);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/reports")) {
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const reportable_type = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reportable_type"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reportable_type required\"}", &.{});
        defer self.allocator.free(reportable_type);
        if (!std.mem.eql(u8, reportable_type, "comment") and !std.mem.eql(u8, reportable_type, "user") and !std.mem.eql(u8, reportable_type, "message")) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"unsupported report type\"}", &.{});
        const id_owned = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reportable_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reportable_id required\"}", &.{});
        defer self.allocator.free(id_owned);
        const reportable_id = std.fmt.parseInt(i64, id_owned, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid reportable_id\"}", &.{});
        const reason = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"reason"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"reason required\"}", &.{});
        defer self.allocator.free(reason);
        const comments = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"comments"})) orelse try self.allocator.dupe(u8, "");
        defer self.allocator.free(comments);
        if (reportable_id <= 0 or reason.len == 0 or reason.len > 64 or comments.len > 1000 or !std.unicode.utf8ValidateSlice(comments)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid report\"}", &.{});
        if (std.mem.eql(u8, reportable_type, "comment") and (try self.store.lazerCommentTarget(reportable_id)) == null) return respond(req, .not_found, "application/json", "{\"error\":\"comment not found\"}", &.{});
        if (std.mem.eql(u8, reportable_type, "message") and !try self.store.lazerMessageExists(reportable_id)) return respond(req, .not_found, "application/json", "{\"error\":\"message not found\"}", &.{});
        if (std.mem.eql(u8, reportable_type, "user")) {
            if (reportable_id > std.math.maxInt(i32)) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            const reported_user = (try self.store.userById(self.allocator, @intCast(reportable_id))) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer freeUser(self.allocator, reported_user);
        }
        if (!try self.store.addLazerReport(user.id, reportable_type, reportable_id, reason, comments)) return respond(req, .conflict, "application/json", "{\"error\":\"report already submitted\"}", &.{});
        if (std.mem.eql(u8, reportable_type, "comment")) _ = try self.store.reportLazerComment(user.id, reportable_id, reason, comments);
        return respond(req, .created, "application/json", "{}", &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/friends")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (req.head.method == .GET) {
            const json = try self.friendRelationsJson(user.id);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const target_id = std.fmt.parseInt(i32, queryField(target, "target") orelse "", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid target\"}", &.{});
        const target_user = switch (try player_routes.follow(self.allocator, &self.store, user.id, target_id)) {
            .not_found => return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{}),
            .ineligible => return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"user cannot be followed\"}", &.{}),
            .target => |fresh| fresh,
        };
        defer freeUser(self.allocator, target_user);
        const json = try self.friendMutationJson(user.id, target_user);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (lazer.parseFriendPath(path)) |target_id| {
        if (req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (target_id == 3) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"kai stays available\"}", &.{});
        _ = try self.store.removeFriend(user.id, target_id);
        return respond(req, .no_content, "application/json", "", &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/blocks")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (req.head.method == .GET) {
            const json = try self.blockRelationsJson(user.id);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const target_id = std.fmt.parseInt(i32, queryField(target, "target") orelse "", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid target\"}", &.{});
        const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        defer freeUser(self.allocator, target_user);
        if (target_user.id == user.id or target_user.id == 3) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"user cannot be blocked\"}", &.{});
        _ = try self.store.addBlock(user.id, target_user.id);
        return respond(req, .no_content, "application/json", "", &.{});
    }
    if (lazer.parseBlockPath(path)) |target_id| {
        if (req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        _ = try self.store.removeBlock(user.id, target_id);
        return respond(req, .no_content, "application/json", "", &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/me/beatmapset-favourites")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const json = try self.favouriteSetsJson(user.id);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (lazer.parseFavouritePath(path)) |set_id| {
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const action = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"action"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"action required\"}", &.{});
        defer self.allocator.free(action);
        if (std.mem.eql(u8, action, "favourite"))
            _ = try self.store.addFavourite(user.id, set_id)
        else if (std.mem.eql(u8, action, "unfavourite"))
            _ = try self.store.removeFavourite(user.id, set_id)
        else
            return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid action\"}", &.{});
        return respond(req, .no_content, "application/json", "", &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/chat/channels")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (req.head.method == .GET) {
            const channels = try self.store.lazerChannelListJson(self.allocator, user.id);
            defer self.allocator.free(channels);
            return respond(req, .ok, "application/json", channels, &.{});
        }
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const kind = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"type"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"type required\"}", &.{});
        defer self.allocator.free(kind);
        if (!std.ascii.eqlIgnoreCase(kind, "PM") and !std.mem.eql(u8, kind, "5")) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"unsupported channel type\"}", &.{});
        const target_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"target_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"target required\"}", &.{});
        defer self.allocator.free(target_text);
        const target_id = std.fmt.parseInt(i32, target_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid target\"}", &.{});
        if (target_id == user.id) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"cannot message yourself\"}", &.{});
        const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        defer freeUser(self.allocator, target_user);
        if (target_user.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        const messages = try self.store.lazerDirectMessagesJson(self.allocator, user.id, target_id, 0, 50);
        defer self.allocator.free(messages);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.print("{{\"channel_id\":{d},\"recent_messages\":", .{lazer.privateChannelId(target_id).?});
        try output.writer.writeAll(messages);
        try output.writer.writeByte('}');
        return respond(req, .ok, "application/json", output.written(), &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/chat/new")) {
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});
        const now = std.Io.Clock.real.now(self.sessions.io).toSeconds();
        if (user.silence_end > now) return respond(req, .forbidden, "application/json", "{\"error\":\"silenced\"}", &.{});
        const target_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"target_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"target required\"}", &.{});
        defer self.allocator.free(target_text);
        const target_id = std.fmt.parseInt(i32, target_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid target\"}", &.{});
        if (target_id == user.id) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"cannot message yourself\"}", &.{});
        const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        defer freeUser(self.allocator, target_user);
        if (target_user.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        const content = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"message required\"}", &.{});
        defer self.allocator.free(content);
        const uuid = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"uuid"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"uuid required\"}", &.{});
        defer self.allocator.free(uuid);
        const action_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"is_action"})) orelse try self.allocator.dupe(u8, "false");
        defer self.allocator.free(action_text);
        const is_action = if (std.mem.eql(u8, action_text, "true")) true else if (std.mem.eql(u8, action_text, "false")) false else return respond(req, .bad_request, "application/json", "{\"error\":\"invalid action\"}", &.{});
        if (content.len == 0 or content.len > 2000 or !std.unicode.utf8ValidateSlice(content) or std.mem.indexOfScalar(u8, content, 0) != null) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid message\"}", &.{});
        if (!lazer.validMessageUuid(uuid)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid uuid\"}", &.{});
        const written = self.store.recordLazerDirectMessage(self.allocator, user.id, target_id, content, is_action, uuid) catch |err| return switch (err) {
            error.ChatUuidConflict => respond(req, .conflict, "application/json", "{\"error\":\"message uuid conflict\"}", &.{}),
            error.InvalidDirectMessage => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid target\"}", &.{}),
            error.DirectMessageBlocked => respond(req, .forbidden, "application/json", "{\"error\":\"direct messages are blocked\"}", &.{}),
            else => respond(req, .internal_server_error, "application/json", "{\"error\":\"message unavailable\"}", &.{}),
        };
        defer self.allocator.free(written.json);
        if (written.inserted) {
            if (written.direct_message_id) |message_id| self.deliverDirectMessageToStable(user, target_id, message_id, content) catch |err|
                std.log.warn("event=lazer_dm_stable_delivery_failed user_id={d} target_id={d} error={t}", .{ user.id, target_id, err });
            if (target_id == 3) self.recordLazerBotReply(user, content, is_action);
        }
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.print("{{\"new_channel_id\":{d},\"message\":", .{lazer.privateChannelId(target_id).?});
        try output.writer.writeAll(written.json);
        try output.writer.writeByte('}');
        return respond(req, .created, "application/json", output.written(), &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/presence")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const presence = try self.lazerPresenceJson(user.id);
        defer self.allocator.free(presence);
        return respond(req, .ok, "application/json", presence, &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (std.mem.startsWith(u8, path, "/api/v2/presence/")) {
        if (req.head.method != .PUT and req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const expected_user_id = std.fmt.parseInt(i32, path["/api/v2/presence/".len..], 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user\"}", &.{});
        const authorization = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        if (!std.mem.startsWith(u8, authorization, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        const token = authorization["Bearer ".len..];
        if (req.head.method == .DELETE) {
            if (!try self.store.clearLazerActivityForToken(token, expected_user_id)) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            return respond(req, .no_content, "application/json", "", &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        const status = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"status"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"status required\"}", &.{});
        defer self.allocator.free(status);
        const detail = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"detail"})) orelse try self.allocator.dupe(u8, "");
        defer self.allocator.free(detail);
        const beatmap_text = try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"beatmap_id"});
        defer if (beatmap_text) |value| self.allocator.free(value);
        const ruleset_text = try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"ruleset_id"});
        defer if (ruleset_text) |value| self.allocator.free(value);
        const beatmap_id: ?i32 = if (beatmap_text) |value| std.fmt.parseInt(i32, value, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid activity\"}", &.{}) else null;
        const ruleset_id: ?u8 = if (ruleset_text) |value| std.fmt.parseInt(u8, value, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid activity\"}", &.{}) else null;
        const stored = self.store.setLazerActivityForToken(token, expected_user_id, status, detail, beatmap_id, ruleset_id) catch |err| return switch (err) {
            error.InvalidLazerActivity => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid activity\"}", &.{}),
            else => err,
        };
        if (!stored) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        return respond(req, .no_content, "application/json", "", &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (lazer.parseChannelUserPath(path)) |channel_path| {
        if (req.head.method != .PUT and req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (channel_path.user_id != user.id) return respond(req, .forbidden, "application/json", "{\"error\":\"channel user mismatch\"}", &.{});
        if (lazer.roomChannelRoom(channel_path.channel_id) != null) {
            _ = self.lazer_multiplayer.roomChannelAccess(user.id, channel_path.channel_id) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
        } else if (lazer.privateChannelUser(channel_path.channel_id)) |other_id| {
            const other = (try self.store.userById(self.allocator, other_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            defer freeUser(self.allocator, other);
            if (other.restricted or other.id == user.id) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
        }
        return respond(req, .ok, "application/json", "{}", &.{});
    }
    if (req.head.method == .GET) if (lazer.parseChannelPath(path)) |channel_id| {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (lazer.roomChannelRoom(channel_id) != null) {
            const room_id = self.lazer_multiplayer.roomChannelAccess(user.id, channel_id) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            const users = (try self.lazer_multiplayer.roomChannelUsersJson(self.allocator, user.id, channel_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            defer self.allocator.free(users);
            const cursor = try self.store.lazerRoomChannelCursor(user.id, room_id);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"channel\":");
            try lazer.writeRoomChatChannel(&output.writer, room_id, cursor.last_message_id, cursor.last_read_id);
            try output.writer.writeAll(",\"users\":");
            try output.writer.writeAll(users);
            try output.writer.writeByte('}');
            return respond(req, .ok, "application/json", output.written(), &.{});
        }
        if (lazer.privateChannelUser(channel_id)) |other_id| {
            if (other_id == user.id) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            var other = (try self.store.userById(self.allocator, other_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            defer freeUser(self.allocator, other);
            if (other.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            try self.markOnline(&other);
            const cursor = try self.store.lazerDirectMessageCursor(user.id, other.id);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"channel\":");
            try lazer.writePrivateChatChannel(&output.writer, channel_id, other.name, cursor.last_message_id, cursor.last_read_id);
            try output.writer.writeAll(",\"users\":[");
            try user_json.writeCompact(&output.writer, user, true);
            try output.writer.writeByte(',');
            try user_json.writeCompact(&output.writer, other, other.show_country);
            try output.writer.writeAll("]}");
            return respond(req, .ok, "application/json", output.written(), &.{});
        }
        var kai = (try self.store.userById(self.allocator, 3)) orelse return respond(req, .service_unavailable, "application/json", "{\"error\":\"channel presence unavailable\"}", &.{});
        defer freeUser(self.allocator, kai);
        try self.markOnline(&kai);
        const cursor = try self.store.lazerChannelCursor(user.id, channel_id);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"channel\":");
        try lazer.writeChatChannel(&output.writer, channel_id, cursor.last_message_id, cursor.last_read_id);
        try output.writer.writeAll(",\"users\":[");
        try user_json.writeCompact(&output.writer, user, true);
        try output.writer.writeByte(',');
        try user_json.writeCompact(&output.writer, kai, true);
        try output.writer.writeAll("]}");
        return respond(req, .ok, "application/json", output.written(), &.{});
    };
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/chat/messages")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const since = std.fmt.parseInt(i64, queryField(target, "since") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid since\"}", &.{});
        if (since < 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid since\"}", &.{});
        const messages = if (self.lazer_multiplayer.currentRoomId(user.id)) |room_id|
            try self.store.lazerAllMessagesForRoomJson(self.allocator, user.id, room_id, since, 100)
        else
            try self.store.lazerAllMessagesJson(self.allocator, user.id, since, 100);
        defer self.allocator.free(messages);
        return respond(req, .ok, "application/json", messages, &.{});
    }
    if (lazer.parseChannelReadPath(path)) |channel_path| {
        if (req.head.method != .PUT) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (lazer.roomChannelRoom(channel_path.channel_id) != null) {
            const room_id = self.lazer_multiplayer.roomChannelAccess(user.id, channel_path.channel_id) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            self.store.markLazerRoomChannelRead(user.id, room_id, channel_path.message_id) catch |err| return switch (err) {
                error.ChatMessageNotFound => respond(req, .not_found, "application/json", "{\"error\":\"chat message not found\"}", &.{}),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"read state unavailable\"}", &.{}),
            };
        } else if (lazer.privateChannelUser(channel_path.channel_id)) |other_id|
            self.store.markLazerDirectMessageRead(user.id, other_id, channel_path.message_id) catch |err| return switch (err) {
                error.ChatMessageNotFound => respond(req, .not_found, "application/json", "{\"error\":\"chat message not found\"}", &.{}),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"read state unavailable\"}", &.{}),
            }
        else
            self.store.markLazerChannelRead(user.id, channel_path.channel_id, channel_path.message_id) catch |err| return switch (err) {
                error.ChatMessageNotFound => respond(req, .not_found, "application/json", "{\"error\":\"chat message not found\"}", &.{}),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"read state unavailable\"}", &.{}),
            };
        return respond(req, .ok, "application/json", "{}", &.{});
    }
    if (lazer.parseChannelMessagesPath(path)) |channel_path| {
        if (req.head.method != .GET and req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const room_id: ?i64 = if (lazer.roomChannelRoom(channel_path.channel_id) != null)
            self.lazer_multiplayer.roomChannelAccess(user.id, channel_path.channel_id) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{})
        else
            null;
        const private_target_id = lazer.privateChannelUser(channel_path.channel_id);
        if (private_target_id) |target_id| {
            if (target_id == user.id) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            const target_user = (try self.store.userById(self.allocator, target_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
            defer freeUser(self.allocator, target_user);
            if (target_user.restricted) return respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{});
        }
        if (req.head.method == .GET) {
            const messages = if (room_id) |id|
                try self.store.lazerRoomMessagesJson(self.allocator, id, 0, 50)
            else if (private_target_id) |target_id|
                try self.store.lazerDirectMessagesJson(self.allocator, user.id, target_id, 0, 50)
            else
                try self.store.lazerChatMessagesJson(self.allocator, channel_path.channel_id, 0, 50);
            defer self.allocator.free(messages);
            return respond(req, .ok, "application/json", messages, &.{});
        }
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});
        const now = std.Io.Clock.real.now(self.sessions.io).toSeconds();
        if (user.silence_end > now) return respond(req, .forbidden, "application/json", "{\"error\":\"silenced\"}", &.{});
        const content = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"message"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"message required\"}", &.{});
        defer self.allocator.free(content);
        const uuid = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"uuid"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"uuid required\"}", &.{});
        defer self.allocator.free(uuid);
        const action_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"is_action"})) orelse try self.allocator.dupe(u8, "false");
        defer self.allocator.free(action_text);
        const is_action = if (std.mem.eql(u8, action_text, "true")) true else if (std.mem.eql(u8, action_text, "false")) false else return respond(req, .bad_request, "application/json", "{\"error\":\"invalid action\"}", &.{});
        if (content.len == 0 or content.len > 2000 or !std.unicode.utf8ValidateSlice(content) or std.mem.indexOfScalar(u8, content, 0) != null) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid message\"}", &.{});
        if (!lazer.validMessageUuid(uuid)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid uuid\"}", &.{});
        const written = (if (room_id) |id|
            self.store.recordLazerRoomMessage(self.allocator, user.id, id, content, is_action, uuid)
        else if (private_target_id) |target_id|
            self.store.recordLazerDirectMessage(self.allocator, user.id, target_id, content, is_action, uuid)
        else
            self.store.recordLazerPublicMessage(self.allocator, user.id, lazer.channelName(channel_path.channel_id).?, content, is_action, uuid)) catch |err| return switch (err) {
            error.ChannelReadOnly => respond(req, .forbidden, "application/json", "{\"error\":\"channel is read-only\"}", &.{}),
            error.ChatUuidConflict => respond(req, .conflict, "application/json", "{\"error\":\"message uuid conflict\"}", &.{}),
            error.DirectMessageBlocked => respond(req, .forbidden, "application/json", "{\"error\":\"direct messages are blocked\"}", &.{}),
            error.UnknownChannel => respond(req, .not_found, "application/json", "{\"error\":\"channel not found\"}", &.{}),
            else => respond(req, .internal_server_error, "application/json", "{\"error\":\"message unavailable\"}", &.{}),
        };
        defer self.allocator.free(written.json);
        if (written.inserted and private_target_id == null and room_id == null) {
            const channel_name = lazer.channelName(channel_path.channel_id).?;
            self.broadcastLazerChatToStable(user, channel_name, content) catch |err|
                std.log.warn("event=lazer_chat_stable_broadcast_failed channel={s} error={t}", .{ channel_name, err });
        }
        if (written.inserted) if (private_target_id) |target_id| {
            if (written.direct_message_id) |message_id| self.deliverDirectMessageToStable(user, target_id, message_id, content) catch |err|
                std.log.warn("event=lazer_dm_stable_delivery_failed user_id={d} target_id={d} error={t}", .{ user.id, target_id, err });
            if (target_id == 3) self.recordLazerBotReply(user, content, is_action);
        };
        return respond(req, .created, "application/json", written.json, &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/chat/ack")) {
        if (req.head.method != .POST) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        return respond(req, .ok, "application/json", "{\"silences\":[]}", &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/tags")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        return respond(req, .ok, "application/json", "{\"tags\":" ++ lazer.beatmap_tags_array_json ++ "}", &.{});
    }
    if (beatmapTagPath(path)) |tag_path| {
        if (req.head.method != .PUT and req.head.method != .DELETE) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});
        if (!lazer.validBeatmapTagId(tag_path.tag_id)) return respond(req, .not_found, "application/json", "{\"error\":\"tag not found\"}", &.{});
        _ = self.store.setLazerBeatmapTag(user.id, tag_path.beatmap_id, tag_path.tag_id, req.head.method == .PUT) catch |err| switch (err) {
            error.BeatmapNotFound => return respond(req, .not_found, "application/json", "{\"error\":\"beatmap not found\"}", &.{}),
            error.InvalidBeatmapTag => return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid tag\"}", &.{}),
            else => return err,
        };
        return respond(req, .no_content, "application/json", "", &.{});
    }
    if (req.head.method == .GET and (std.mem.eql(u8, path, "/api/v2/users") or std.mem.eql(u8, path, "/api/v2/users/") or std.mem.eql(u8, path, "/api/v2/users/lookup") or std.mem.eql(u8, path, "/api/v2/users/lookup/"))) {
        const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, requester);
        const lookup_route = std.mem.eql(u8, path, "/api/v2/users/lookup") or std.mem.eql(u8, path, "/api/v2/users/lookup/");
        const requested_ruleset = if (lookup_route)
            lazer.lookupRulesetId(queryField(target, "ruleset_id")) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid ruleset id\"}", &.{})
        else
            null;
        const ids = lazer.queryIds(self.allocator, target, 50) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user ids\"}", &.{});
        defer self.allocator.free(ids);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"users\":[");
        var written: usize = 0;
        for (ids) |id| {
            if (try self.store.userById(self.allocator, id)) |local_value| {
                var found = local_value;
                defer freeUser(self.allocator, found);
                if (found.restricted and found.id != requester.id) continue;
                try self.markOnline(&found);
                const visibility = (try self.store.lazerBatchUserVisibility(found.id)) orelse continue;
                const owner = found.id == requester.id;
                const can_view_stats = !found.restricted and found.id != 3 and (owner or visibility.show_profile_stats);
                if (written != 0) try output.writer.writeByte(',');
                written += 1;
                if (lookup_route) {
                    const stats = if (requested_ruleset) |ruleset_id| if (can_view_stats) try self.store.statsForUser(found.id, ruleset_id) else null else null;
                    try user_json.writeLookup(&output.writer, found, stats, requested_ruleset, visibility, owner);
                } else {
                    const stats = if (can_view_stats) try self.store.statsRulesetsForUser(found.id) else [_]?domain.Stats{null} ** 4;
                    try user_json.writeBatchWithRulesets(&output.writer, found, stats, visibility, owner);
                }
                continue;
            }
            const upstream_ruleset = requested_ruleset orelse 0;
            const upstream_id = self.map_sync.ensureUpstreamProfileById(&self.store, id, upstream_ruleset) catch |err| failed: {
                std.log.warn("event=upstream_user_batch_failed user_id={d} mode={d} error={t}", .{ id, upstream_ruleset, err });
                break :failed null;
            };
            const resolved_id = upstream_id orelse continue;
            const profile = (try self.store.upstreamUserProfileJson(self.allocator, resolved_id, upstream_ruleset)) orelse continue;
            defer self.allocator.free(profile);
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            if (lookup_route and requested_ruleset != null) {
                const lookup = try upstream_user.lookupJsonOwned(self.allocator, profile, upstream_ruleset);
                defer self.allocator.free(lookup);
                try output.writer.writeAll(lookup);
            } else {
                try output.writer.writeAll(profile);
            }
        }
        try output.writer.writeAll("],\"cursor\":null}");
        return respond(req, .ok, "application/json", output.written(), &.{});
    }
    if (req.head.method == .GET) if (userPathWithSuffix(path, "/kudosu")) |profile_user_id| {
        const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, requester);
        const profile_user = (try self.store.userById(self.allocator, profile_user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        defer freeUser(self.allocator, profile_user);
        if (profile_user.restricted and profile_user.id != requester.id) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        return respond(req, .ok, "application/json", "[]", &.{});
    };
    if (req.head.method == .GET) if (userPathWithSuffix(path, "/beatmapsets/most_played")) |profile_user_id| {
        const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, requester);
        const profile_user = (try self.store.userById(self.allocator, profile_user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        defer freeUser(self.allocator, profile_user);
        if (profile_user.restricted and profile_user.id != requester.id) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        const profile_summary = (try self.store.lazerProfileSummary(profile_user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        if (profile_user.id != requester.id and (!profile_summary.show_profile_stats or !profile_summary.show_recent_scores)) return respond(req, .ok, "application/json", "[]", &.{});
        const offset = std.fmt.parseInt(u16, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
        const limit = std.fmt.parseInt(u8, queryField(target, "limit") orelse "50", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
        if (offset > 10_000 or limit == 0 or limit > 100) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid pagination\"}", &.{});
        const json = try self.store.lazerMostPlayedJson(self.allocator, profile_user_id, requester.id, offset, limit);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    };
    if (req.head.method == .GET) if (userBeatmapsetPath(path)) |beatmapset_path| {
        if (std.mem.eql(u8, beatmapset_path.kind, "most_played")) {} else {
            const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer freeUser(self.allocator, requester);
            const profile_user = (try self.store.userById(self.allocator, beatmapset_path.user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer freeUser(self.allocator, profile_user);
            if (profile_user.restricted and profile_user.id != requester.id) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            const offset = std.fmt.parseInt(usize, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
            const limit = std.fmt.parseInt(usize, queryField(target, "limit") orelse "50", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
            if (offset > 10_000 or limit == 0 or limit > 100) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid pagination\"}", &.{});
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeByte('[');
            if (std.mem.eql(u8, beatmapset_path.kind, "favourite")) {
                const ids = try self.store.favouriteSetIds(self.allocator, beatmapset_path.user_id);
                defer self.allocator.free(ids);
                const end = @min(ids.len, offset + limit);
                var written: usize = 0;
                if (offset < end) for (ids[offset..end]) |set_id| {
                    const set = (try self.store.lazerBeatmapSet(self.allocator, set_id, requester.id)) orelse continue;
                    defer self.allocator.free(set);
                    if (written != 0) try output.writer.writeByte(',');
                    written += 1;
                    try output.writer.writeAll(set);
                };
            } else {
                if (!std.mem.eql(u8, beatmapset_path.kind, "ranked") and !std.mem.eql(u8, beatmapset_path.kind, "loved") and !std.mem.eql(u8, beatmapset_path.kind, "pending") and !std.mem.eql(u8, beatmapset_path.kind, "guest") and !std.mem.eql(u8, beatmapset_path.kind, "graveyard") and !std.mem.eql(u8, beatmapset_path.kind, "nominated")) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set type\"}", &.{});
                const sets = try self.store.lazerUserBeatmapSetsJson(self.allocator, beatmapset_path.user_id, beatmapset_path.kind, offset, limit, requester.id);
                defer self.allocator.free(sets);
                try output.writer.writeAll(sets[1 .. sets.len - 1]);
            }
            try output.writer.writeByte(']');
            return respond(req, .ok, "application/json", output.written(), &.{});
        }
    };
    if (req.head.method == .GET) if (lazer.parseUserRecentActivityPath(path)) |profile_user_id| {
        const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, requester);
        const profile_user = (try self.store.userById(self.allocator, profile_user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        defer freeUser(self.allocator, profile_user);
        if (profile_user.restricted and profile_user.id != requester.id) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        const profile_summary = (try self.store.lazerProfileSummary(profile_user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        if (profile_user.id != requester.id and !profile_summary.show_recent_scores) return respond(req, .ok, "application/json", "[]", &.{});
        const offset = std.fmt.parseInt(u16, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
        const limit = std.fmt.parseInt(u8, queryField(target, "limit") orelse "50", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
        if (limit == 0 or limit > 100 or offset > 10_000) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid pagination\"}", &.{});
        const json = try self.store.lazerRecentActivityJson(self.allocator, profile_user.id, offset, limit);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    };
    if (req.head.method == .GET) if (lazer.parseUserScoresPath(path)) |score_path| {
        const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, requester);
        const profile_user = (try self.store.userById(self.allocator, score_path.user_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        defer freeUser(self.allocator, profile_user);
        if (profile_user.restricted and profile_user.id != requester.id) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        const profile_summary = (try self.store.lazerProfileSummary(profile_user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        if (profile_user.id != requester.id) {
            if (score_path.kind == .recent and !profile_summary.show_recent_scores) return respond(req, .ok, "application/json", "[]", &.{});
            if (score_path.kind != .recent and !profile_summary.show_profile_stats) return respond(req, .ok, "application/json", "[]", &.{});
        }
        const ruleset_id = lazerRulesetId(queryField(target, "mode") orelse "osu") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
        const offset = std.fmt.parseInt(u16, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
        const limit = std.fmt.parseInt(u8, queryField(target, "limit") orelse "50", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
        if (limit == 0 or limit > 100 or offset > 10_000) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid pagination\"}", &.{});
        const score_source = domain.parseSiteScoreSource(queryField(target, "source") orelse "all") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid score source\"}", &.{});
        if (score_source == .scorev2) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid score source\"}", &.{});
        const json = try self.store.lazerUserScoresJson(self.allocator, profile_user.id, ruleset_id, score_path.kind, score_source, offset, limit);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    };
    if (req.head.method == .GET) if (lazer.parseUserPath(path)) |user_path| {
        const requester = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, requester);
        const key = queryField(target, "key") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"lookup key required\"}", &.{});
        const lookup_buffer = try self.allocator.dupe(u8, user_path.lookup);
        defer self.allocator.free(lookup_buffer);
        const lookup = std.Uri.percentDecodeInPlace(lookup_buffer);
        const profile_user = if (std.mem.eql(u8, key, "id")) by_id: {
            const id = std.fmt.parseInt(i32, lookup, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user id\"}", &.{});
            if (id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user id\"}", &.{});
            break :by_id try self.store.userById(self.allocator, id);
        } else if (std.mem.eql(u8, key, "username"))
            try self.store.userByName(self.allocator, lookup)
        else
            return respond(req, .bad_request, "application/json", "{\"error\":\"invalid lookup key\"}", &.{});
        if (profile_user == null) {
            const upstream_id = if (std.mem.eql(u8, key, "id")) by_id: {
                const id = std.fmt.parseInt(i32, lookup, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user id\"}", &.{});
                break :by_id self.map_sync.ensureUpstreamProfileById(&self.store, id, user_path.ruleset_id) catch |err| failed: {
                    std.log.warn("event=upstream_user_profile_failed user_id={d} mode={d} error={t}", .{ id, user_path.ruleset_id, err });
                    break :failed null;
                };
            } else self.map_sync.ensureUpstreamProfileByName(&self.store, lookup, user_path.ruleset_id) catch |err| failed: {
                std.log.warn("event=upstream_user_profile_failed username={s} mode={d} error={t}", .{ lookup, user_path.ruleset_id, err });
                break :failed null;
            };
            const resolved_id = upstream_id orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            const profile = (try self.store.upstreamUserProfileJson(self.allocator, resolved_id, user_path.ruleset_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
            defer self.allocator.free(profile);
            return respond(req, .ok, "application/json", profile, &.{});
        }
        var found = profile_user.?;
        defer freeUser(self.allocator, found);
        if (found.restricted and found.id != requester.id) return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        try self.markOnline(&found);
        const stats = try self.store.statsForUser(found.id, user_path.ruleset_id);
        const stable_stats = try self.store.sourceStatsForUser(found.id, user_path.ruleset_id, .stable);
        const lazer_stats = try self.store.sourceStatsForUser(found.id, user_path.ruleset_id, .lazer);
        const score_counts = try self.store.lazerUserScoreCounts(found.id, user_path.ruleset_id, .all);
        const stable_counts = try self.store.lazerUserScoreCounts(found.id, user_path.ruleset_id, .stable);
        const lazer_counts = try self.store.lazerUserScoreCounts(found.id, user_path.ruleset_id, .lazer);
        const achievements_json = try self.store.lazerUserAchievementsJson(self.allocator, found.id);
        defer self.allocator.free(achievements_json);
        const monthly_playcounts_json = try self.store.lazerMonthlyPlaycountsJson(self.allocator, found.id);
        defer self.allocator.free(monthly_playcounts_json);
        const replays_watched_counts_json = try self.store.lazerReplaysWatchedCountsJson(self.allocator, found.id, user_path.ruleset_id);
        defer self.allocator.free(replays_watched_counts_json);
        const profile_summary = (try self.store.lazerProfileSummary(found.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        const profile_owner = found.id == requester.id;
        const stats_history = if (!found.restricted and (profile_owner or profile_summary.show_profile_stats))
            try self.store.statsHistory(found.id, .all, user_path.ruleset_id)
        else
            domain.StatsHistory{};
        const json = try user_json.profileOwnedWithView(self.allocator, found, stats, score_counts, .{
            .stable_stats = stable_stats,
            .lazer_stats = lazer_stats,
            .stable_counts = stable_counts,
            .lazer_counts = lazer_counts,
        }, achievements_json, .{ .summary = profile_summary, .requested_ruleset = user_path.ruleset_id, .owner = profile_owner, .monthly_playcounts_json = monthly_playcounts_json, .replays_watched_counts_json = replays_watched_counts_json, .stats_history = stats_history });
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    };
    if (req.head.method == .GET and (std.mem.eql(u8, path, "/api/v2/beatmaps") or std.mem.eql(u8, path, "/api/v2/beatmaps/"))) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const ids = lazer.queryIds(self.allocator, target, 50) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap ids\"}", &.{});
        defer self.allocator.free(ids);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"beatmaps\":[");
        var written: usize = 0;
        for (ids) |id| {
            self.ensureMapperForMap(id);
            var found = try self.store.lazerBeatmapLookup(self.allocator, id, null, user.id);
            if (found == null) {
                _ = self.map_sync.ensureByBeatmapId(&self.store, id, null) catch |err|
                    std.log.warn("event=lazer_beatmap_batch_hydration_failed beatmap_id={d} error={t}", .{ id, err });
                self.ensureMapperForMap(id);
                found = try self.store.lazerBeatmapLookup(self.allocator, id, null, user.id);
            }
            const beatmap = found orelse continue;
            defer self.allocator.free(beatmap);
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try output.writer.writeAll(beatmap);
        }
        try output.writer.writeAll("],\"cursor\":null}");
        return respond(req, .ok, "application/json", output.written(), &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmaps/lookup")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const checksum = queryField(target, "checksum");
        if (checksum) |value| if (!lazer.validHash(value)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid checksum\"}", &.{});
        var beatmap_id: ?i32 = if (queryField(target, "id")) |value| std.fmt.parseInt(i32, value, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap id\"}", &.{}) else null;
        if (beatmap_id) |value| if (value <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap id\"}", &.{});
        const encoded_filename = queryField(target, "filename");
        if (checksum == null and beatmap_id == null and encoded_filename == null) return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap lookup required\"}", &.{});
        var filename_buffer: ?[]u8 = null;
        defer if (filename_buffer) |value| self.allocator.free(value);
        if (encoded_filename) |encoded| {
            if (encoded.len == 0 or encoded.len > 1024) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid filename\"}", &.{});
            const owned = try self.allocator.dupe(u8, encoded);
            filename_buffer = owned;
            for (owned) |*char| {
                if (char.* == '+') char.* = ' ';
            }
            const filename = std.Uri.percentDecodeInPlace(owned);
            if (!std.unicode.utf8ValidateSlice(filename) or std.mem.indexOfScalar(u8, filename, 0) != null) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid filename\"}", &.{});
            if (beatmap_id == null) {
                if (try self.store.stableBeatmapInfoByFilename(user.id, filename)) |info| {
                    beatmap_id = info.id;
                }
            }
        }
        if (beatmap_id) |id| self.ensureMapperForMap(id);
        if (beatmap_id == null) if (checksum) |value| if (try self.store.beatmapSetIdForChecksum(value)) |set_id| self.ensureMapperForSet(set_id);
        var found = try self.store.lazerBeatmapLookup(self.allocator, beatmap_id, checksum, user.id);
        if (found == null) if (beatmap_id) |id| {
            _ = self.map_sync.ensureByBeatmapId(&self.store, id, checksum) catch |err|
                std.log.warn("event=lazer_beatmap_lookup_hydration_failed beatmap_id={d} error={t}", .{ id, err });
            self.ensureMapperForMap(id);
            found = try self.store.lazerBeatmapLookup(self.allocator, id, null, user.id);
        } else if (checksum) |value| {
            _ = self.map_sync.ensureByChecksum(&self.store, value) catch |err|
                std.log.warn("event=lazer_beatmap_checksum_hydration_failed checksum={s} error={t}", .{ value, err });
            if (try self.store.beatmapSetIdForChecksum(value)) |set_id| self.ensureMapperForSet(set_id);
            found = try self.store.lazerBeatmapLookup(self.allocator, null, value, user.id);
        };
        const response = found orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap not found\"}", &.{});
        defer self.allocator.free(response);
        return respond(req, .ok, "application/json", response, &.{});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/rankings/") and std.mem.endsWith(u8, path, "/charts")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const spotlight_id = std.fmt.parseInt(i32, queryField(target, "spotlight") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid spotlight\"}", &.{});
        var output: [384]u8 = undefined;
        const json = try std.fmt.bufPrint(&output, "{{\"ranking\":[],\"spotlight\":{{\"id\":{d},\"name\":\"zigcho!lazer\",\"type\":\"theme\",\"mode_specific\":false,\"start_date\":\"2026-01-01T00:00:00Z\",\"end_date\":\"2027-01-01T00:00:00Z\",\"participant_count\":0}},\"beatmapsets\":[]}}", .{@max(1, spotlight_id)});
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (req.head.method == .GET) if (lazer.parseRankingPath(path)) |ranking_path| {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const page = std.fmt.parseInt(u16, queryField(target, "page") orelse "1", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid page\"}", &.{});
        if (page == 0 or page > 200) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid page\"}", &.{});
        var country_buffer: [2]u8 = undefined;
        var country_filter: ?[]const u8 = null;
        if (queryField(target, "country")) |value| {
            if (ranking_path.kind == .country or value.len != 2 or !std.ascii.isAlphabetic(value[0]) or !std.ascii.isAlphabetic(value[1])) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid country\"}", &.{});
            country_buffer = .{ std.ascii.toUpper(value[0]), std.ascii.toUpper(value[1]) };
            country_filter = &country_buffer;
        }
        const json = try self.store.lazerRankingsJson(self.allocator, ranking_path.ruleset_id, ranking_path.kind, country_filter, page);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    };
    if (req.head.method == .GET) if (lazer.parseLeaderboardPath(path)) |leaderboard_path| {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const ruleset_id = lazerRulesetId(queryField(target, "mode") orelse "osu") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
        const raw_limit = std.fmt.parseInt(u16, queryField(target, "limit") orelse "50", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
        if (raw_limit == 0 or raw_limit > 100) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid limit\"}", &.{});
        const scope = lazer.LeaderboardScope.parse(queryField(target, "type") orelse "global") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"unsupported leaderboard scope\"}", &.{});
        const mod_filter = lazer.leaderboardModFilter(self.allocator, target) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid leaderboard mods\"}", &.{});
        defer mod_filter.deinit(self.allocator);
        const json = try self.store.lazerLeaderboardJson(self.allocator, user.id, leaderboard_path.beatmap_id, ruleset_id, mod_filter.namespace, mod_filter.exact_json, mod_filter.selected, mod_filter.classic, mod_filter.stable_bits, scope, @intCast(raw_limit));
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    };
    if (lazer.parseSoloScorePath(path)) |solo_path| {
        const user = (try self.lazerUser(auth_owned, "scores:write")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});

        if (solo_path.token_id == null and req.head.method == .POST) {
            const version_hash = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"version_hash"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"version_hash required\"}", &.{});
            defer self.allocator.free(version_hash);
            const beatmap_hash = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"beatmap_hash"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap_hash required\"}", &.{});
            defer self.allocator.free(beatmap_hash);
            const ruleset_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"ruleset_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"ruleset_id required\"}", &.{});
            defer self.allocator.free(ruleset_text);
            if (!lazer.validHash(version_hash) or !lazer.validHash(beatmap_hash)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid score token hashes\"}", &.{});
            const ruleset_id = std.fmt.parseInt(i64, ruleset_text, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid ruleset_id\"}", &.{});
            if (ruleset_id < 0 or ruleset_id > 3) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid ruleset_id\"}", &.{});
            const pp_ready = self.map_sync.ensureFileByBeatmapId(&self.store, solo_path.beatmap_id, beatmap_hash) catch |err| {
                if (err == error.BeatmapHashMismatch) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"beatmap hash mismatch\"}", &.{});
                std.log.warn("event=lazer_score_token_hydration_failed beatmap_id={d} error={t}", .{ solo_path.beatmap_id, err });
                return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
            };
            if (!pp_ready) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
            const token_id = self.store.createLazerScoreToken(user.id, solo_path.beatmap_id, beatmap_hash, ruleset_id, version_hash) catch |err| return switch (err) {
                error.BeatmapNotFound => respond(req, .not_found, "application/json", "{\"error\":\"beatmap not found\"}", &.{}),
                error.BeatmapHashMismatch => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"beatmap hash mismatch\"}", &.{}),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"score token unavailable\"}", &.{}),
            };
            var out: [96]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d}}}", .{token_id});
            return respond(req, .created, "application/json", json, &.{});
        }
        if (solo_path.token_id) |token_id| {
            if (req.head.method != .PUT) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            if (storage.Store.isLazerRoomScoreToken(token_id)) return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid or expired score token\"}", &.{});
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_json\"}", &.{});
            defer parsed.deinit();
            var score = lazer.parseSoloScore(parsed.value, solo_path.beatmap_id) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_score_or_mod\"}", &.{});
            const replay_data = lazer.decodeReplay(self.allocator, parsed.value.object, score.ruleset_id) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_replay\"}", &.{});
            defer self.allocator.free(replay_data);
            const mods_json = try lazer.jsonField(self.allocator, parsed.value.object, "mods", "[]");
            defer self.allocator.free(mods_json);
            const statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "statistics", "{}");
            defer self.allocator.free(statistics_json);
            const maximum_statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "maximum_statistics", "{}");
            defer self.allocator.free(maximum_statistics_json);
            const pauses_json = try lazer.jsonField(self.allocator, parsed.value.object, "pauses", "[]");
            defer self.allocator.free(pauses_json);
            const pp_ready = self.map_sync.ensureFileByBeatmapId(&self.store, solo_path.beatmap_id, null) catch |err| {
                std.log.warn("event=lazer_score_submit_hydration_failed beatmap_id={d} token_id={d} error={t}", .{ solo_path.beatmap_id, token_id, err });
                return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
            };
            if (!pp_ready) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
            const performance = lazerPerformance(self.allocator, &self.store, score, mods_json) catch |err| {
                std.log.warn("event=lazer_score_performance_failed beatmap_id={d} token_id={d} error={t}", .{ solo_path.beatmap_id, token_id, err });
                return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"performance calculation failed\"}", &.{});
            };
            score.achievement_stars = performance.stars;
            score.achievement_mods = performance.mods;
            score.achievement_perfect = performance.max_combo > 0 and score.max_combo >= performance.max_combo;
            const score_id = self.store.submitLazerScoreToken(user.id, solo_path.beatmap_id, token_id, score, performance.pp, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data) catch |err| return switch (err) {
                error.InvalidLazerScoreToken, error.ForeignLazerScoreToken, error.LazerScoreTokenExpired => respond(req, .unauthorized, "application/json", "{\"error\":\"invalid or expired score token\"}", &.{}),
                error.LazerScoreTokenUsed => respond(req, .conflict, "application/json", "{\"error\":\"score token already used\"}", &.{}),
                error.LazerScoreTokenMismatch => respond(req, .unprocessable_entity, "application/json", "{\"error\":\"score token does not match submission\"}", &.{}),
                else => respond(req, .internal_server_error, "application/json", "{\"error\":\"score submission failed\"}", &.{}),
            };
            if (replay_data.len != 0) {
                _ = self.store.storeReplayObject(.lazer, score_id, replay_data) catch |err| failed: {
                    std.log.warn("event=replay_object_write_failed source=lazer score_id={d} error={t}", .{ score_id, err });
                    break :failed false;
                };
            }
            const placement = self.afterLazerScore(user, score_id, score, performance.pp, mods_json);
            const json = try self.lazerScoreResponse(user.id, score_id, placement);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
    }
    if (lazer_multiplayer.parseRoomLeaderboardPath(path)) |room_id| {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const json = (try self.lazer_multiplayer.roomLeaderboardJson(self.allocator, user.id, room_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room not found\"}", &.{});
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (lazer_multiplayer.parseRoomUserScorePath(path)) |user_score_path| {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const context = self.lazer_multiplayer.scoreContext(user.id, user_score_path.room_id, user_score_path.playlist_item_id) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room or playlist item not found\"}", &.{});
        const score_id = self.lazer_multiplayer.roomScoreIdForUser(user.id, user_score_path.room_id, user_score_path.playlist_item_id, user_score_path.user_id) orelse return respond(req, .not_found, "application/json", "{\"error\":\"score not found\"}", &.{});
        const json = (try self.lazerRoomScoreDetailJson(user.id, user_score_path.room_id, user_score_path.playlist_item_id, context.beatmap_id, score_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"score not found\"}", &.{});
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
    }
    if (lazer_multiplayer.parseRoomScorePath(path)) |room_score_path| {
        if (!self.lazer_multiplayer.isEnabled()) return featureUnavailable(req, .lazer_multiplayer);
        const required_scope: []const u8 = if (req.head.method == .GET) "identify" else "scores:write";
        const user = (try self.lazerUser(auth_owned, required_scope)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (user.restricted) return respond(req, .forbidden, "application/json", "{\"error\":\"restricted\"}", &.{});
        const score_context = (if (req.head.method == .GET)
            self.lazer_multiplayer.scoreContext(user.id, room_score_path.room_id, room_score_path.playlist_item_id)
        else if (req.head.method == .POST)
            self.lazer_multiplayer.scoreTokenContext(user.id, room_score_path.room_id, room_score_path.playlist_item_id)
        else if (room_score_path.token_id) |token_id|
            self.lazer_multiplayer.scoreSubmissionContext(user.id, room_score_path.room_id, room_score_path.playlist_item_id, token_id)
        else
            null) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room, playlist item, or score token not found\"}", &.{});

        if (room_score_path.token_id == null and req.head.method == .GET) {
            const ids = (try self.lazer_multiplayer.roomScoreIds(self.allocator, user.id, room_score_path.room_id, room_score_path.playlist_item_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"room or playlist item not found\"}", &.{});
            defer self.allocator.free(ids);
            const own_score_id = self.lazer_multiplayer.roomScoreIdForUser(user.id, room_score_path.room_id, room_score_path.playlist_item_id, user.id);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.writeAll("{\"scores\":[");
            var written: usize = 0;
            for (ids) |score_id| {
                const score_json = (try self.store.lazerScoreJson(self.allocator, score_id, score_context.beatmap_id)) orelse continue;
                defer self.allocator.free(score_json);
                if (written != 0) try output.writer.writeByte(',');
                written += 1;
                try output.writer.writeAll(score_json);
            }
            try output.writer.print("],\"total\":{d},\"user_score\":", .{ids.len});
            if (own_score_id) |score_id| {
                if (try self.lazerRoomScoreDetailJson(user.id, room_score_path.room_id, room_score_path.playlist_item_id, score_context.beatmap_id, score_id)) |own_json| {
                    defer self.allocator.free(own_json);
                    try output.writer.writeAll(own_json);
                } else try output.writer.writeAll("null");
            } else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"params\":{},\"cursor\":null}");
            return respond(req, .ok, "application/json", output.written(), &.{.{ .name = "cache-control", .value = "no-store" }});
        }

        if (room_score_path.token_id == null and req.head.method == .POST) {
            const version_hash = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"version_hash"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"version_hash required\"}", &.{});
            defer self.allocator.free(version_hash);
            const beatmap_hash = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"beatmap_hash"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap_hash required\"}", &.{});
            defer self.allocator.free(beatmap_hash);
            const beatmap_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"beatmap_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap_id required\"}", &.{});
            defer self.allocator.free(beatmap_text);
            const ruleset_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"ruleset_id"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"ruleset_id required\"}", &.{});
            defer self.allocator.free(ruleset_text);
            const beatmap_id = std.fmt.parseInt(i32, beatmap_text, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid beatmap_id\"}", &.{});
            const ruleset_id = std.fmt.parseInt(u8, ruleset_text, 10) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid ruleset_id\"}", &.{});
            if (beatmap_id != score_context.beatmap_id or ruleset_id != score_context.ruleset_id or !lazer.validHash(version_hash) or !lazer.validHash(beatmap_hash)) return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"score token does not match room\"}", &.{});
            const pp_ready = self.map_sync.ensureFileByBeatmapId(&self.store, beatmap_id, beatmap_hash) catch |err| {
                std.log.warn("event=lazer_room_score_token_hydration_failed room_id={d} beatmap_id={d} error={t}", .{ room_score_path.room_id, beatmap_id, err });
                return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
            };
            if (!pp_ready) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
            const token_id = self.store.createLazerRoomScoreToken(user.id, beatmap_id, beatmap_hash, ruleset_id, version_hash) catch return respond(req, .internal_server_error, "application/json", "{\"error\":\"score token unavailable\"}", &.{});
            self.lazer_multiplayer.bindRoomScoreToken(user.id, room_score_path.room_id, room_score_path.playlist_item_id, token_id) catch |err| {
                std.log.warn("event=lazer_room_score_token_bind_failed room_id={d} playlist_item_id={d} user_id={d} token_id={d} error={t}", .{ room_score_path.room_id, room_score_path.playlist_item_id, user.id, token_id, err });
                const discarded = self.store.discardUnusedLazerRoomScoreToken(user.id, token_id) catch |discard_err| {
                    std.log.err("event=lazer_room_score_token_discard_failed user_id={d} token_id={d} error={t}", .{ user.id, token_id, discard_err });
                    return respond(req, .internal_server_error, "application/json", "{\"error\":\"score token cleanup failed\"}", &.{});
                };
                if (!discarded) std.log.err("event=lazer_room_score_token_discard_missing user_id={d} token_id={d}", .{ user.id, token_id });
                return switch (err) {
                    error.MultiplayerDisabled, error.ServerShuttingDown => featureUnavailable(req, .lazer_multiplayer),
                    else => respond(req, .internal_server_error, "application/json", "{\"error\":\"score token unavailable\"}", &.{}),
                };
            };
            var out: [96]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d}}}", .{token_id});
            return respond(req, .created, "application/json", json, &.{});
        }

        if (room_score_path.token_id) |token_id| {
            if (req.head.method == .GET) {
                if (!self.lazer_multiplayer.roomContainsScore(user.id, room_score_path.room_id, room_score_path.playlist_item_id, token_id)) return respond(req, .not_found, "application/json", "{\"error\":\"score not found\"}", &.{});
                const json = (try self.lazerRoomScoreDetailJson(user.id, room_score_path.room_id, room_score_path.playlist_item_id, score_context.beatmap_id, token_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"score not found\"}", &.{});
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &.{.{ .name = "cache-control", .value = "no-store" }});
            }
            if (req.head.method != .PUT) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
            if (!storage.Store.isLazerRoomScoreToken(token_id)) return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid or expired score token\"}", &.{});
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_json\"}", &.{});
            defer parsed.deinit();
            var score = lazer.parseSoloScore(parsed.value, score_context.beatmap_id) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_score_or_mod\"}", &.{});
            const replay_data = lazer.decodeReplay(self.allocator, parsed.value.object, score.ruleset_id) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_replay\"}", &.{});
            defer self.allocator.free(replay_data);
            const mods_json = try lazer.jsonField(self.allocator, parsed.value.object, "mods", "[]");
            defer self.allocator.free(mods_json);
            const statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "statistics", "{}");
            defer self.allocator.free(statistics_json);
            const maximum_statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "maximum_statistics", "{}");
            defer self.allocator.free(maximum_statistics_json);
            const pauses_json = try lazer.jsonField(self.allocator, parsed.value.object, "pauses", "[]");
            defer self.allocator.free(pauses_json);
            const performance = lazerPerformance(self.allocator, &self.store, score, mods_json) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"performance calculation failed\"}", &.{});
            score.achievement_stars = performance.stars;
            score.achievement_mods = performance.mods;
            score.achievement_perfect = performance.max_combo > 0 and score.max_combo >= performance.max_combo;
            var recovered = false;
            var room_total_score = score.total_score;
            var room_accuracy = score.accuracy;
            var room_max_combo: i32 = @intCast(score.max_combo);
            var room_passed = score.passed;
            const score_id = self.store.submitLazerRoomScoreToken(user.id, score_context.beatmap_id, token_id, score, performance.pp, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data) catch |err| switch (err) {
                error.InvalidLazerScoreToken, error.ForeignLazerScoreToken, error.LazerScoreTokenExpired => return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid or expired score token\"}", &.{}),
                error.LazerScoreTokenUsed => recovered_score: {
                    const existing = (self.store.consumedLazerScoreToken(user.id, score_context.beatmap_id, token_id) catch return respond(req, .internal_server_error, "application/json", "{\"error\":\"score recovery failed\"}", &.{})) orelse return respond(req, .conflict, "application/json", "{\"error\":\"score token already used\"}", &.{});
                    recovered = true;
                    room_total_score = existing.total_score;
                    room_accuracy = existing.accuracy;
                    room_max_combo = existing.max_combo;
                    room_passed = existing.passed;
                    break :recovered_score existing.score_id;
                },
                error.LazerScoreTokenMismatch => return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"score token does not match submission\"}", &.{}),
                else => return respond(req, .internal_server_error, "application/json", "{\"error\":\"score submission failed\"}", &.{}),
            };
            if (!recovered and replay_data.len != 0) {
                _ = self.store.storeReplayObject(.lazer, score_id, replay_data) catch |err| failed: {
                    std.log.warn("event=replay_object_write_failed source=lazer score_id={d} error={t}", .{ score_id, err });
                    break :failed false;
                };
            }
            self.lazer_multiplayer.recordRoomScore(user.id, room_score_path.room_id, room_score_path.playlist_item_id, .{
                .token_id = token_id,
                .score_id = score_id,
                // MultiplayerScore.TotalScore is the submitted standardised
                // lazer score. Legacy totals remain a stats/profile concern.
                .total_score = room_total_score,
                .accuracy = room_accuracy,
                .max_combo = room_max_combo,
                .passed = room_passed,
            }) catch |err| {
                std.log.err("event=lazer_multiplayer_score_archive_failed room_id={d} playlist_item_id={d} user_id={d} score_id={d} error={t}", .{ room_score_path.room_id, room_score_path.playlist_item_id, user.id, score_id, err });
                return switch (err) {
                    error.MultiplayerDisabled, error.ServerShuttingDown => featureUnavailable(req, .lazer_multiplayer),
                    else => respond(req, .internal_server_error, "application/json", "{\"error\":\"multiplayer score persistence failed\"}", &.{}),
                };
            };
            if (recovered) {
                const json = try self.lazerScoreResponse(user.id, score_id, null);
                defer self.allocator.free(json);
                return respond(req, .ok, "application/json", json, &.{});
            }
            const placement = self.afterLazerScore(user, score_id, score, performance.pp, mods_json);
            const json = try self.lazerScoreResponse(user.id, score_id, placement);
            defer self.allocator.free(json);
            return respond(req, .ok, "application/json", json, &.{});
        }
        return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmapsets/search")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const mode = std.fmt.parseInt(i8, queryField(target, "m") orelse "-1", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
        const offset = beatmapSearchOffset(target) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
        if (mode < -1 or mode > 3) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid search\"}", &.{});
        const category = lazer.beatmapSearchCategory(queryField(target, "s") orelse "any") catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid category\"}", &.{});
        const sort = lazer.beatmapSearchSort(queryField(target, "sort") orelse "ranked_desc") catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid sort\"}", &.{});
        const encoded_query = queryField(target, "q") orelse "";
        const query_buf = try self.allocator.dupe(u8, encoded_query);
        defer self.allocator.free(query_buf);
        for (query_buf) |*char| {
            if (char.* == '+') char.* = ' ';
        }
        const query = std.Uri.percentDecodeInPlace(query_buf);
        if (!std.unicode.utf8ValidateSlice(query) or std.mem.indexOfScalar(u8, query, 0) != null) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid search\"}", &.{});
        if (category.source == .mine) {
            const listing = try self.store.lazerOwnedBeatmapSearch(self.allocator, user.id, query, mode, offset, user.id);
            defer self.allocator.free(listing);
            return respond(req, .ok, "application/json", listing, &.{});
        }
        if (category.source == .favourites) {
            const favourite_ids = try self.store.favouriteSetIds(self.allocator, user.id);
            defer self.allocator.free(favourite_ids);
            const start: usize = @min(offset, favourite_ids.len);
            const end: usize = @min(favourite_ids.len, start + 50);
            const listing = try self.store.lazerBeatmapSets(self.allocator, favourite_ids[start..end], offset, user.id);
            defer self.allocator.free(listing);
            return respond(req, .ok, "application/json", listing, &.{});
        }
        const upstream_ids: ?[]i32 = self.map_sync.searchSets(&self.store, query, mode, offset, category.upstream_status, sort) catch |err| failed: {
            std.log.warn("event=lazer_beatmap_search_upstream_failed mode={d} offset={d} error={t}", .{ mode, offset, err });
            break :failed null;
        };
        defer if (upstream_ids) |ids| self.allocator.free(ids);
        const listing = if (upstream_ids) |ids|
            try self.store.lazerBeatmapSets(self.allocator, ids, offset, user.id)
        else
            try self.store.lazerBeatmapSearch(self.allocator, query, mode, offset, user.id);
        defer self.allocator.free(listing);
        return respond(req, .ok, "application/json", listing, &.{});
    }
    if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmapsets/lookup")) {
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const map_text = queryField(target, "beatmap_id") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"beatmap id required\"}", &.{});
        const map_id = std.fmt.parseInt(i32, map_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap id\"}", &.{});
        if (map_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap id\"}", &.{});
        var set_id = try self.store.beatmapSetIdForMap(map_id);
        if (set_id == null) {
            _ = self.map_sync.ensureByBeatmapId(&self.store, map_id, null) catch |err|
                std.log.warn("event=lazer_beatmap_set_lookup_hydration_failed beatmap_id={d} error={t}", .{ map_id, err });
            set_id = try self.store.beatmapSetIdForMap(map_id);
        }
        const resolved_set_id = set_id orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
        self.ensureMapperForSet(resolved_set_id);
        const listing = (try self.store.lazerBeatmapSet(self.allocator, resolved_set_id, user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
        defer self.allocator.free(listing);
        return respond(req, .ok, "application/json", listing, &.{});
    }
    if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and !std.mem.endsWith(u8, path, "/download")) {
        const set_id = std.fmt.parseInt(i32, path["/api/v2/beatmapsets/".len..], 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
        if (set_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        if (!try self.store.beatmapSetExists(set_id)) {
            _ = self.map_sync.ensureBySetId(&self.store, set_id) catch |err|
                std.log.warn("event=lazer_beatmap_set_hydration_failed set_id={d} error={t}", .{ set_id, err });
        }
        self.ensureMapperForSet(set_id);
        const response = (try self.store.lazerBeatmapSet(self.allocator, set_id, user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
        defer self.allocator.free(response);
        return respond(req, .ok, "application/json", response, &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/me") or std.mem.eql(u8, path, "/api/v2/me/") or std.mem.startsWith(u8, path, "/api/v2/me/")) {
        if (req.head.method != .GET) return respond(req, .method_not_allowed, "application/json", "{\"error\":\"method not allowed\"}", &.{});
        if (std.mem.startsWith(u8, path, "/api/v2/me/") and path.len > "/api/v2/me/".len and lazerRulesetId(path["/api/v2/me/".len..]) == null) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const stats = try self.lazerStats(user.id);
        const achievements_json = try self.store.lazerUserAchievementsJson(self.allocator, user.id);
        defer self.allocator.free(achievements_json);
        const profile_summary = (try self.store.lazerProfileSummary(user.id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"user not found\"}", &.{});
        const json = try user_json.meOwnedWithProfile(self.allocator, user, stats, achievements_json, profile_summary);
        defer self.allocator.free(json);
        return respond(req, .ok, "application/json", json, &.{});
    }
    if (std.mem.eql(u8, path, "/api/v2/scores") and req.head.method == .POST) {
        const user = (try self.lazerUser(auth_owned, "scores:write")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
        defer freeUser(self.allocator, user);
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_json\"}", &.{});
        defer parsed.deinit();
        var score = lazer.parseScore(parsed.value) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_score_or_mod\"}", &.{});
        const mods_json = try lazer.jsonField(self.allocator, parsed.value.object, "mods", "[]");
        defer self.allocator.free(mods_json);
        const statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "statistics", "{}");
        defer self.allocator.free(statistics_json);
        const maximum_statistics_json = try lazer.jsonField(self.allocator, parsed.value.object, "maximum_statistics", "{}");
        defer self.allocator.free(maximum_statistics_json);
        const pauses_json = try lazer.jsonField(self.allocator, parsed.value.object, "pauses", "[]");
        defer self.allocator.free(pauses_json);
        const ns_name = @tagName(score.namespace);
        const pp_ready = self.map_sync.ensureFileByBeatmapId(&self.store, @intCast(score.beatmap_id), null) catch |err| {
            std.log.warn("event=lazer_legacy_score_hydration_failed beatmap_id={d} error={t}", .{ score.beatmap_id, err });
            return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
        };
        if (!pp_ready) return respond(req, .service_unavailable, "application/json", "{\"error\":\"beatmap payload unavailable\"}", &.{});
        const performance = lazerPerformance(self.allocator, &self.store, score, mods_json) catch |err| {
            std.log.warn("event=lazer_legacy_score_performance_failed beatmap_id={d} error={t}", .{ score.beatmap_id, err });
            return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"performance calculation failed\"}", &.{});
        };
        score.achievement_stars = performance.stars;
        score.achievement_mods = performance.mods;
        score.achievement_perfect = performance.max_combo > 0 and score.max_combo >= performance.max_combo;
        const id = try self.store.insertLazerScore(user.id, score, performance.pp, mods_json, statistics_json, maximum_statistics_json, pauses_json, &.{});
        self.lazer_spectator.scoreProcessed(user.id, id);
        var out: [192]u8 = undefined;
        const json = try std.fmt.bufPrint(&out, "{{\"id\":{d},\"user_id\":{d},\"rank_namespace\":\"{s}\",\"ranked\":true}}", .{ id, user.id, ns_name });
        return respond(req, .created, "application/json", json, &.{});
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
