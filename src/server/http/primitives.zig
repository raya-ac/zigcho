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
const freeUser = support.freeUser;

pub fn header(req: *const std.http.Server.Request, wanted: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, wanted)) return h.value;
    return null;
}

pub fn respond(req: *std.http.Server.Request, status: std.http.Status, content_type: []const u8, body: []const u8, headers: []const std.http.Header) !void {
    var all: [8]std.http.Header = undefined;
    all[0] = .{ .name = "content-type", .value = content_type };
    if (headers.len > all.len - 1) return error.TooManyHeaders;
    @memcpy(all[1..][0..headers.len], headers);
    try req.respond(body, .{ .status = status, .extra_headers = all[0 .. headers.len + 1], .keep_alive = false });
}

pub fn respondWithoutContinue(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    req.head.expect = null;
    return respond(req, status, "application/json", body, &.{});
}

pub fn serveObjectImage(self: anytype, req: *std.http.Server.Request, image_value: storage.Store.CustomAvatar) !void {
    var stored = image_value;
    defer stored.deinit();
    var data = self.avatar_cache.get(stored.object_key) catch |err| cache_error: {
        std.log.warn("event=object_image_cache_read_failed key={s} error={t}", .{ stored.object_key, err });
        break :cache_error null;
    };
    if (data == null) {
        const fetched = self.avatar_store.getWithLimit(self.allocator, self.store.io, stored.object_key, stored.content_type, profile_banner.max_bytes) catch |err| {
            std.log.warn("event=object_image_download_failed key={s} error={t}", .{ stored.object_key, err });
            return respond(req, .bad_gateway, "application/json", "{\"error\":\"image storage is not available\"}", &.{.{ .name = "cache-control", .value = "no-store" }});
        };
        self.avatar_cache.put(stored.object_key, fetched) catch |err| std.log.warn("event=object_image_cache_write_failed key={s} error={t}", .{ stored.object_key, err });
        data = fetched;
    }
    const bytes = data.?;
    defer self.allocator.free(bytes);
    var etag_buf: [66]u8 = undefined;
    const etag = try std.fmt.bufPrint(&etag_buf, "\"{s}\"", .{&stored.etag});
    const headers = [_]std.http.Header{
        .{ .name = "cache-control", .value = "public, max-age=300" },
        .{ .name = "etag", .value = etag },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    if (header(req, "if-none-match")) |current| if (std.mem.eql(u8, current, etag)) return respond(req, .not_modified, stored.content_type, "", &headers);
    return respond(req, .ok, stored.content_type, bytes, &headers);
}

pub fn serveBeatmapArchive(self: anytype, req: *std.http.Server.Request, set_id: i32) !void {
    if (set_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
    const download_optional = self.store.beatmapArchiveDownload(self.allocator, set_id) catch |err| {
        std.log.warn("event=beatmap_archive_download_metadata_failed set_id={d} error={t}", .{ set_id, err });
        return respond(req, .bad_gateway, "application/json", "{\"error\":\"beatmap mirror storage unavailable\"}", &.{});
    };
    if (download_optional == null) {
        _ = self.map_sync.queueMirrorArchive(&self.store, set_id) catch |err|
            std.log.warn("event=beatmap_mirror_background_queue_failed set_id={d} error={t}", .{ set_id, err });
        var upstream_buffer: [128]u8 = undefined;
        const upstream = try std.fmt.bufPrint(&upstream_buffer, "https://beatmaps.akatsuki.gg/api/d/{d}", .{set_id});
        return respond(req, .temporary_redirect, "text/plain", "", &.{
            .{ .name = "location", .value = upstream },
            .{ .name = "cache-control", .value = "private, no-store" },
            .{ .name = "x-zigcho-mirror-cache", .value = "fill" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        });
    }
    var download = download_optional.?;
    defer download.deinit();
    self.map_sync.recordMirrorCacheHit(download.bytes);
    var disposition_buf: [96]u8 = undefined;
    const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{d}.osz\"", .{set_id});
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/x-osu-beatmap-archive" },
        .{ .name = "content-disposition", .value = disposition },
        .{ .name = "cache-control", .value = "public, max-age=3600" },
        .{ .name = "cdn-cache-control", .value = "public, max-age=86400" },
        .{ .name = "x-zigcho-mirror-cache", .value = "hit" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };
    var stream_buffer: [64 * 1024]u8 = undefined;
    var body_writer = try req.respondStreaming(&stream_buffer, .{
        .content_length = download.bytes,
        .respond_options = .{ .status = .ok, .extra_headers = &headers, .keep_alive = false },
    });
    try body_writer.flush();
    self.store.streamBeatmapArchive(download, &body_writer.writer) catch |err| {
        std.log.warn("event=beatmap_archive_stream_failed set_id={d} bytes={d} error={t}", .{ set_id, download.bytes, err });
        return err;
    };
    try body_writer.end();
}

pub const GeoResult = @import("geolocation.zig").Result;
pub const lookupGeo = @import("geolocation.zig").lookup;

pub fn rejectStableScore(req: *std.http.Server.Request, reason: []const u8, body_len: usize) !void {
    std.log.warn("stable score rejected: reason={s} body_bytes={d}", .{ reason, body_len });
    return respond(req, .bad_request, "text/plain", "error: no", &.{});
}

pub fn rejectStableScoreError(req: *std.http.Server.Request, reason: []const u8, err: anyerror, body_len: usize) !void {
    std.log.warn("stable score rejected: reason={s} error={t} body_bytes={d}", .{ reason, err, body_len });
    return respond(req, .bad_request, "text/plain", "error: no", &.{});
}

pub fn field(body: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |part| {
        const eq = std.mem.findScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], key)) return part[eq + 1 ..];
    }
    return null;
}

pub fn queryField(target: []const u8, key: []const u8) ?[]const u8 {
    const query_start = std.mem.findScalar(u8, target, '?') orelse return null;
    return field(target[query_start + 1 ..], key);
}

pub fn beatmapSearchOffset(target: []const u8) !u16 {
    const value = queryField(target, "cursor%5Boffset%5D") orelse queryField(target, "cursor[offset]") orelse queryField(target, "offset") orelse "0";
    const offset = std.fmt.parseInt(u16, value, 10) catch return error.InvalidSearchOffset;
    if (offset > 10_000 or offset % 50 != 0) return error.InvalidSearchOffset;
    return offset;
}

pub const UserBeatmapsetPath = struct { user_id: i32, kind: []const u8 };
pub const BeatmapTagPath = struct { beatmap_id: i32, tag_id: i32 };

pub fn userPathWithSuffix(path: []const u8, suffix: []const u8) ?i32 {
    const prefix = "/api/v2/users/";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const id_text = path[prefix.len .. path.len - suffix.len];
    if (id_text.len == 0 or std.mem.indexOfScalar(u8, id_text, '/') != null) return null;
    const id = std.fmt.parseInt(i32, id_text, 10) catch return null;
    return if (id > 0) id else null;
}

pub fn userBeatmapsetPath(path: []const u8) ?UserBeatmapsetPath {
    const prefix = "/api/v2/users/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
    const id = std.fmt.parseInt(i32, rest[0..slash], 10) catch return null;
    const resource = "beatmapsets/";
    const tail = rest[slash + 1 ..];
    if (id <= 0 or !std.mem.startsWith(u8, tail, resource) or tail.len == resource.len) return null;
    const kind = tail[resource.len..];
    if (std.mem.indexOfScalar(u8, kind, '/') != null) return null;
    return .{ .user_id = id, .kind = kind };
}

pub fn beatmapTagPath(path: []const u8) ?BeatmapTagPath {
    const prefix = "/api/v2/beatmaps/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const separator = "/tags/";
    const middle = std.mem.indexOf(u8, rest, separator) orelse return null;
    const beatmap_id = std.fmt.parseInt(i32, rest[0..middle], 10) catch return null;
    const tag_text = rest[middle + separator.len ..];
    if (std.mem.indexOfScalar(u8, tag_text, '/') != null) return null;
    const tag_id = std.fmt.parseInt(i32, tag_text, 10) catch return null;
    if (beatmap_id <= 0 or tag_id <= 0) return null;
    return .{ .beatmap_id = beatmap_id, .tag_id = tag_id };
}

pub fn lazerRulesetId(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "osu")) return 0;
    if (std.mem.eql(u8, name, "taiko")) return 1;
    if (std.mem.eql(u8, name, "fruits")) return 2;
    if (std.mem.eql(u8, name, "mania")) return 3;
    return null;
}

pub fn isAvatarHost(value: ?[]const u8) bool {
    const host = value orelse return false;
    const end = std.mem.findScalar(u8, host, ':') orelse host.len;
    return std.ascii.eqlIgnoreCase(host[0..end], "a.kai.ovh");
}

pub fn isAssetsHost(value: ?[]const u8) bool {
    const host = value orelse return false;
    const end = std.mem.findScalar(u8, host, ':') orelse host.len;
    return std.ascii.eqlIgnoreCase(host[0..end], "assets.kai.ovh");
}

pub fn isBeatmapMirrorHost(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const end = std.mem.findScalar(u8, raw, ':') orelse raw.len;
    return std.ascii.eqlIgnoreCase(raw[0..end], "beatmaps.kai.ovh");
}

pub fn isBssHost(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const end = std.mem.findScalar(u8, raw, ':') orelse raw.len;
    const host = raw[0..end];
    return std.ascii.eqlIgnoreCase(host, "bss.kai.ovh") or std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
}

pub fn bssStorageFailure(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.startsWith(u8, name, "R2") or
        std.mem.startsWith(u8, name, "Connection") or
        std.mem.startsWith(u8, name, "Tls") or
        std.mem.startsWith(u8, name, "Http") or
        std.mem.startsWith(u8, name, "Dns") or
        std.mem.startsWith(u8, name, "Certificate") or
        std.mem.eql(u8, name, "BssObjectStorageRequired");
}

pub fn storeBssMedia(self: anytype, set_id: i32, media: bss.PreparedMedia) !void {
    try beatmap_media.storeLocalMedia(&self.store, set_id, media);
}

pub fn isLocalMetricsHost(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const host = if (raw.len > 0 and raw[0] == '[') raw else if (std.mem.findScalar(u8, raw, ':')) |colon| raw[0..colon] else raw;
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.startsWith(u8, host, "[::1]");
}

pub fn avatarUserId(path: []const u8) ?i32 {
    const value = if (std.mem.startsWith(u8, path, "/avatars/"))
        path["/avatars/".len..]
    else if (std.mem.startsWith(u8, path, "/avatar/"))
        path["/avatar/".len..]
    else if (path.len > 1)
        path[1..]
    else
        return null;
    if (value.len == 0) return null;
    return std.fmt.parseInt(i32, value, 10) catch null;
}
