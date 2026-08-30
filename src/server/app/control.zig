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

pub fn featureUnavailable(req: *std.http.Server.Request, feature: server_control.Feature) !void {
    var body: [160]u8 = undefined;
    const json = try std.fmt.bufPrint(&body, "{{\"error\":\"{s} is temporarily disabled\",\"feature\":\"{s}\"}}", .{ server_control.definition(feature).label, feature.key() });
    const headers = [_]std.http.Header{
        .{ .name = "retry-after", .value = "60" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    return respond(req, .service_unavailable, "application/json", json, &headers);
}

pub fn setFeatureControl(self: anytype, actor_id: i32, feature: server_control.Feature, enabled: bool, reason: []const u8) !void {
    self.server_control_mutex.lockUncancelable(self.store.io);
    defer self.server_control_mutex.unlock(self.store.io);
    try self.store.setServerControl(actor_id, feature, enabled, reason);
    switch (feature) {
        .lazer_multiplayer => self.lazer_multiplayer.setEnabled(enabled),
        .spectator => self.lazer_spectator.setEnabled(enabled),
        else => {},
    }
}

pub fn requestRule(req: *const std.http.Server.Request, path: []const u8) ?rate_limit.Rule {
    if ((req.head.method == .PUT or req.head.method == .PATCH) and bss.parsePath(path) != null) return rate_limit.media_upload;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/users")) return rate_limit.registration;
    if (req.head.method == .POST and (std.mem.eql(u8, path, "/oauth/token") or std.mem.eql(u8, path, "/oauth/revoke"))) return rate_limit.token;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/staff/session")) return rate_limit.web_session;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/session")) return rate_limit.web_session;
    if ((req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/account")) or ((req.head.method == .PUT or req.head.method == .DELETE) and std.mem.eql(u8, path, "/api/v1/account/avatar"))) return rate_limit.web_action;
    if (req.head.method == .POST and std.mem.startsWith(u8, path, "/api/v1/staff/")) return rate_limit.web_action;
    if ((req.head.method == .POST or req.head.method == .PUT or req.head.method == .DELETE) and std.mem.startsWith(u8, path, "/api/v1/account")) return rate_limit.web_action;
    if ((req.head.method == .POST or req.head.method == .PUT or req.head.method == .DELETE) and std.mem.startsWith(u8, path, "/api/v1/teams")) return rate_limit.web_action;
    if (req.head.method == .POST and std.mem.startsWith(u8, path, "/api/v1/chat/")) return rate_limit.web_action;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/appeals")) return rate_limit.appeal;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v2/scores")) return rate_limit.score;
    if ((req.head.method == .POST or req.head.method == .PUT) and lazer.parseSoloScorePath(path) != null) return rate_limit.score;
    if ((req.head.method == .POST or req.head.method == .PUT) and lazer_multiplayer.parseRoomScorePath(path) != null) return rate_limit.score;
    if (std.mem.eql(u8, path, "/multiplayer") or std.mem.eql(u8, path, "/multiplayer/negotiate") or std.mem.eql(u8, path, "/spectator") or std.mem.eql(u8, path, "/spectator/negotiate") or std.mem.eql(u8, path, "/notification-endpoint") or std.mem.startsWith(u8, path, "/api/v2/rooms")) return rate_limit.authenticated;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return rate_limit.score;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/web/osu-screenshot.php")) return rate_limit.media_upload;
    if (req.head.method == .GET and (std.mem.eql(u8, path, "/web/osu-getfriends.php") or std.mem.eql(u8, path, "/web/osu-getfavourites.php") or std.mem.eql(u8, path, "/web/osu-addfavourite.php"))) return rate_limit.authenticated;
    if (req.head.method == .GET and routing.lazerBeatmapMetadata(path)) return rate_limit.beatmap_metadata;
    if (req.head.method == .GET and (std.mem.startsWith(u8, path, "/d/") or std.mem.startsWith(u8, path, "/ss/") or std.mem.startsWith(u8, path, "/replays/") or std.mem.startsWith(u8, path, "/beatmaps/") or std.mem.startsWith(u8, path, "/preview/") or std.mem.startsWith(u8, path, "/thumb/") or lazer.parseScoreDownloadPath(path) != null or (std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and std.mem.endsWith(u8, path, "/download")))) return rate_limit.download;
    if (req.head.method == .POST and std.mem.eql(u8, path, "/")) {
        return if (header(req, "osu-token") == null) rate_limit.login else rate_limit.authenticated;
    }
    if (std.mem.startsWith(u8, path, "/api/v2/me") or std.mem.eql(u8, path, "/api/v2/notifications") or std.mem.startsWith(u8, path, "/api/v2/friends") or std.mem.startsWith(u8, path, "/api/v2/blocks") or std.mem.eql(u8, path, "/api/v2/presence") or std.mem.startsWith(u8, path, "/api/v2/presence/") or lazer.parseFavouritePath(path) != null or std.mem.startsWith(u8, path, "/api/v2/chat/") or std.mem.startsWith(u8, path, "/api/v2/comments") or std.mem.eql(u8, path, "/api/v2/reports") or std.mem.eql(u8, path, "/api/v2/users") or std.mem.startsWith(u8, path, "/api/v2/users/") or std.mem.eql(u8, path, "/web/osu-osz2-getscores.php") or std.mem.eql(u8, path, "/web/osu-getreplay.php") or std.mem.eql(u8, path, "/web/osu-search.php") or std.mem.eql(u8, path, "/web/osu-search-set.php") or std.mem.eql(u8, path, "/web/osu-rate.php") or std.mem.eql(u8, path, "/web/lastfm.php") or std.mem.eql(u8, path, "/web/osu-getbeatmapinfo.php") or std.mem.eql(u8, path, "/web/osu-comment.php") or std.mem.eql(u8, path, "/web/osu-markasread.php")) return rate_limit.authenticated;
    return null;
}

pub fn bodyLimit(path: []const u8) usize {
    if (bss.parsePath(path) != null) return bss.max_upload_bytes + 1024 * 1024;
    if (std.mem.eql(u8, path, "/api/v1/staff/pp")) return pp_admin.max_mods_json_bytes + 8 * 1024;
    if (std.mem.eql(u8, path, "/api/v1/account/avatar")) return profile_avatar.max_bytes;
    if (std.mem.eql(u8, path, "/api/v1/account/banner")) return profile_banner.max_bytes;
    if (std.mem.startsWith(u8, path, "/api/v1/teams/") and (std.mem.endsWith(u8, path, "/flag") or std.mem.endsWith(u8, path, "/header"))) return team_image.header_max_bytes;
    if (std.mem.eql(u8, path, "/api/v1/teams") or std.mem.startsWith(u8, path, "/api/v1/teams/")) return 16 * 1024;
    if (std.mem.eql(u8, path, "/users") or std.mem.eql(u8, path, "/oauth/token") or std.mem.eql(u8, path, "/oauth/revoke") or std.mem.eql(u8, path, "/api/v1/session") or std.mem.startsWith(u8, path, "/api/v1/account/") or std.mem.eql(u8, path, "/api/v1/account") or std.mem.startsWith(u8, path, "/api/v1/chat/") or std.mem.eql(u8, path, "/api/v1/staff/session") or std.mem.eql(u8, path, "/api/v1/appeals") or std.mem.startsWith(u8, path, "/api/v1/staff/") or std.mem.eql(u8, path, "/api/v2/presence") or std.mem.startsWith(u8, path, "/api/v2/presence/")) return 8 * 1024;
    if (std.mem.eql(u8, path, "/api/v2/scores")) return 1024 * 1024;
    if (lazer.parseSoloScorePath(path) != null) return lazer.max_score_body_bytes;
    if (lazer_multiplayer.parseRoomScorePath(path) != null) return lazer.max_score_body_bytes;
    if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return 20 * 1024 * 1024;
    if (std.mem.eql(u8, path, "/web/osu-getbeatmapinfo.php")) return 32 * 1024 * 1024;
    if (std.mem.eql(u8, path, "/web/osu-screenshot.php")) return screenshot.max_bytes + 256 * 1024;
    if (std.mem.eql(u8, path, "/")) return 1024 * 1024;
    return 64 * 1024;
}
