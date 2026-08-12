const std = @import("std");
const domain = @import("domain.zig");
const storage = @import("runtime_storage.zig");
const sqlite_storage = @import("storage.zig");
const sessions_mod = @import("sessions.zig");
const bancho = @import("bancho.zig");
const lazer = @import("lazer.zig");
const multipart = @import("multipart.zig");
const score_crypto = @import("score_crypto.zig");
const stable_score = @import("stable_score.zig");
const stable_response = @import("stable_response.zig");
const rate_limit = @import("rate_limit.zig");
const pp = @import("pp.zig");
const status_page = @embedFile("status.html");
const form_urlencoded = @import("form_urlencoded.zig");
const registration = @import("registration.zig");
const routing = @import("routing.zig");
const beatmap_sync = @import("beatmap_sync.zig");
const webhook = @import("webhook.zig");
const protocol = @import("protocol.zig");
const country = @import("country.zig");
const log = @import("logutil.zig");
const config_mod = @import("config.zig");
const web_auth = @import("web_auth.zig");
const default_avatar_1 = @embedFile("assets/avatars/default-1.gif");
const default_avatar_2 = @embedFile("assets/avatars/default-2.jpg");

fn freeUser(allocator: std.mem.Allocator, user: domain.User) void {
    allocator.free(user.name);
    allocator.free(user.safe_name);
}

fn intLines(allocator: std.mem.Allocator, values: []const i32) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (values, 0..) |value, index| {
        if (index != 0) try output.writer.writeByte('\n');
        try output.writer.print("{d}", .{value});
    }
    return output.toOwnedSlice();
}

fn validWebText(value: []const u8, minimum: usize, maximum: usize) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len >= minimum and trimmed.len <= maximum and std.unicode.utf8ValidateSlice(trimmed);
}

fn stableClientPrivileges(server: u32) u8 {
    var client: u8 = 1 << 2;
    if (server & 1 != 0) client |= 1 << 0;
    if (server & ((1 << 4) | (1 << 5)) != 0) client |= 1 << 2;
    if (server & (1 << 12) != 0) client |= 1 << 1;
    if (server & (1 << 13) != 0) client |= 1 << 4;
    if (server & (1 << 14) != 0) client |= 1 << 3;
    return client;
}

fn scoreLog(user_name: []const u8, score: stable_score.Submission, pp_value: f64, placement: ?domain.ScorePlacement) void {
    const grade_color = if (std.mem.eql(u8, score.grade, "XH") or std.mem.eql(u8, score.grade, "X")) log.yellow else if (std.mem.eql(u8, score.grade, "SH") or std.mem.eql(u8, score.grade, "S")) log.cyan else if (std.mem.eql(u8, score.grade, "A")) log.green else if (std.mem.eql(u8, score.grade, "B")) log.blue else log.red;
    std.debug.print("{s}  ┌─ SCORE {s} ────────────────────────────{s}\n", .{ if (score.passed) log.green else log.red, if (score.passed) "SUBMIT" else "FAIL", log.reset });
    std.debug.print("{s}  │ {s}►{s} user    : {s}{s}{s}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, log.bold, user_name, log.reset });
    std.debug.print("{s}  │ {s}►{s} grade   : {s}{s}{s}{s}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, grade_color, score.grade, log.bold, log.reset });
    std.debug.print("{s}  │ {s}►{s} pp      : {s}{d:.2}{s}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, log.bold, pp_value, log.reset });
    if (placement) |p|
        std.debug.print("{s}  │ {s}►{s} map rank: #{d}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, p.rank + 1 })
    else
        std.debug.print("{s}  │ {s}►{s} map rank: not on the board\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset });
    std.debug.print("{s}  │ {s}►{s} combo   : {d}x\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, score.max_combo });
    std.debug.print("{s}  │ {s}►{s} acc     : {d:.2}%\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, score.accuracy() * 100.0 });
    std.debug.print("{s}  │ {s}►{s} score   : {d}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, score.total_score });
    std.debug.print("{s}  │ {s}►{s} 300/100/50/miss : {d}/{d}/{d}/{d}\n", .{ if (score.passed) log.green else log.red, log.dim, log.reset, score.n300, score.n100, score.n50, score.nmiss });
    std.debug.print("{s}  └──────────────────────────────────────────────{s}\n", .{ if (score.passed) log.green else log.red, log.reset });
}

fn announceScore(allocator: std.mem.Allocator, sessions: *sessions_mod.Sessions, user_name: []const u8, score: stable_score.Submission, pp_value: f64, placement: domain.ScorePlacement, info: storage.Store.BeatmapInfo) !void {
    var text_buf: [768]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "{s} set #{d} on {s} - {s} [{s}] with {d:.2}pp ({d:.2}%)", .{ user_name, placement.rank + 1, info.artist, info.title, info.version, pp_value, score.accuracy() * 100.0 });
    try bancho.publishAnnouncement(allocator, sessions, text);
}

const App = struct {
    allocator: std.mem.Allocator,
    store: storage.Store,
    sessions: sessions_mod.Sessions,
    limiter: rate_limit.Limiter,
    map_sync: beatmap_sync.Sync,
    score_webhook: webhook.Webhook,
    geo_client: std.http.Client,
    started_at: i64,

    fn header(req: *const std.http.Server.Request, wanted: []const u8) ?[]const u8 {
        var it = req.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, wanted)) return h.value;
        return null;
    }

    fn respond(req: *std.http.Server.Request, status: std.http.Status, content_type: []const u8, body: []const u8, headers: []const std.http.Header) !void {
        var all: [8]std.http.Header = undefined;
        all[0] = .{ .name = "content-type", .value = content_type };
        if (headers.len > all.len - 1) return error.TooManyHeaders;
        @memcpy(all[1..][0..headers.len], headers);
        try req.respond(body, .{ .status = status, .extra_headers = all[0 .. headers.len + 1], .keep_alive = false });
    }

    const GeoResult = struct { lon: f32, lat: f32 };

    fn lookupGeo(self: *App, ip: []const u8) GeoResult {
        const url = std.fmt.allocPrint(self.allocator, "http://ip-api.com/line/{s}?fields=status,lat,lon", .{ip}) catch return .{ .lon = 0, .lat = 0 };
        defer self.allocator.free(url);
        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        const result = self.geo_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &writer,
            .headers = .{
                .user_agent = .{ .override = "zigcho/0.1" },
            },
        }) catch return .{ .lon = 0, .lat = 0 };
        if (result.status != .ok) return .{ .lon = 0, .lat = 0 };
        const body_str = buf[0..writer.end];
        var lines = std.mem.splitScalar(u8, body_str, '\n');
        const status = std.mem.trim(u8, lines.next() orelse "", "\r ");
        if (!std.mem.eql(u8, status, "success")) return .{ .lon = 0, .lat = 0 };
        const lat_str = std.mem.trim(u8, lines.next() orelse "0", "\r ");
        const lon_str = std.mem.trim(u8, lines.next() orelse "0", "\r ");
        const lat = std.fmt.parseFloat(f32, lat_str) catch 0;
        const lon = std.fmt.parseFloat(f32, lon_str) catch 0;
        std.debug.print("{s}  ┌─ GEOLOCATION ──────────────────────────────────{s}\n", .{ log.blue, log.reset });
        std.debug.print("{s}  │ {s}►{s} ip  : {s}{s}\n", .{ log.blue, log.dim, log.reset, ip, log.reset });
        std.debug.print("{s}  │ {s}✓{s} lat : {d:.4}  lon : {d:.4}{s}\n", .{ log.blue, log.green, log.reset, lat, lon, log.reset });
        std.debug.print("{s}  └──────────────────────────────────────────────{s}\n", .{ log.blue, log.reset });
        return .{ .lon = lon, .lat = lat };
    }

    fn rejectStableScore(req: *std.http.Server.Request, reason: []const u8, body_len: usize) !void {
        std.log.warn("stable score rejected: reason={s} body_bytes={d}", .{ reason, body_len });
        return respond(req, .bad_request, "text/plain", "error: no", &.{});
    }

    fn rejectStableScoreError(req: *std.http.Server.Request, reason: []const u8, err: anyerror, body_len: usize) !void {
        std.log.warn("stable score rejected: reason={s} error={t} body_bytes={d}", .{ reason, err, body_len });
        return respond(req, .bad_request, "text/plain", "error: no", &.{});
    }

    fn field(body: []const u8, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, body, '&');
        while (it.next()) |part| {
            const eq = std.mem.findScalar(u8, part, '=') orelse continue;
            if (std.mem.eql(u8, part[0..eq], key)) return part[eq + 1 ..];
        }
        return null;
    }

    fn queryField(target: []const u8, key: []const u8) ?[]const u8 {
        const query_start = std.mem.findScalar(u8, target, '?') orelse return null;
        return field(target[query_start + 1 ..], key);
    }

    fn validSiteMode(mode: u8) bool {
        return mode <= 6 or mode == 8;
    }

    fn isAvatarHost(value: ?[]const u8) bool {
        const host = value orelse return false;
        const end = std.mem.findScalar(u8, host, ':') orelse host.len;
        return std.ascii.eqlIgnoreCase(host[0..end], "a.kai.ovh");
    }

    fn isLocalMetricsHost(value: ?[]const u8) bool {
        const raw = value orelse return false;
        const host = if (raw.len > 0 and raw[0] == '[') raw else if (std.mem.findScalar(u8, raw, ':')) |colon| raw[0..colon] else raw;
        return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.startsWith(u8, host, "[::1]");
    }

    fn avatarUserId(path: []const u8) ?i32 {
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

    fn userOnline(self: *App, user_id: i32) bool {
        self.sessions.mutex.lockUncancelable(self.sessions.io);
        defer self.sessions.mutex.unlock(self.sessions.io);
        return self.sessions.byUser(user_id) != null;
    }

    fn requestRule(req: *const std.http.Server.Request, path: []const u8) ?rate_limit.Rule {
        if (req.head.method == .POST and std.mem.eql(u8, path, "/users")) return rate_limit.registration;
        if (req.head.method == .POST and (std.mem.eql(u8, path, "/oauth/token") or std.mem.eql(u8, path, "/oauth/revoke"))) return rate_limit.token;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/staff/session")) return rate_limit.web_session;
        if (req.head.method == .POST and std.mem.startsWith(u8, path, "/api/v1/staff/")) return rate_limit.web_action;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v1/appeals")) return rate_limit.appeal;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v2/scores")) return rate_limit.score;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return rate_limit.score;
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmapsets/search")) return rate_limit.authenticated;
        if (req.head.method == .GET and (std.mem.eql(u8, path, "/web/osu-getfriends.php") or std.mem.eql(u8, path, "/web/osu-getfavourites.php") or std.mem.eql(u8, path, "/web/osu-addfavourite.php"))) return rate_limit.authenticated;
        if (req.head.method == .GET and (std.mem.startsWith(u8, path, "/d/") or std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") or std.mem.startsWith(u8, path, "/api/v2/beatmaps/"))) return rate_limit.download;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/")) {
            return if (header(req, "osu-token") == null) rate_limit.login else rate_limit.authenticated;
        }
        if (std.mem.eql(u8, path, "/api/v2/me") or std.mem.eql(u8, path, "/web/osu-osz2-getscores.php") or std.mem.eql(u8, path, "/web/osu-getreplay.php") or std.mem.eql(u8, path, "/web/osu-search.php") or std.mem.eql(u8, path, "/web/osu-search-set.php") or std.mem.eql(u8, path, "/web/osu-rate.php") or std.mem.eql(u8, path, "/web/lastfm.php")) return rate_limit.authenticated;
        return null;
    }

    fn bodyLimit(path: []const u8) usize {
        if (std.mem.eql(u8, path, "/users") or std.mem.eql(u8, path, "/oauth/token") or std.mem.eql(u8, path, "/oauth/revoke") or std.mem.eql(u8, path, "/api/v1/staff/session") or std.mem.eql(u8, path, "/api/v1/appeals") or std.mem.startsWith(u8, path, "/api/v1/staff/")) return 8 * 1024;
        if (std.mem.eql(u8, path, "/api/v2/scores")) return 1024 * 1024;
        if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return 20 * 1024 * 1024;
        if (std.mem.eql(u8, path, "/")) return 1024 * 1024;
        return 64 * 1024;
    }

    fn serve(self: *App, req: *std.http.Server.Request) !void {
        const target = try self.allocator.dupe(u8, req.head.target);
        defer self.allocator.free(target);
        const raw_path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
        const path = routing.canonicalPath(raw_path);
        if (requestRule(req, path)) |rule| {
            const client = rate_limit.clientKey(header(req, "cf-connecting-ip"), header(req, "x-forwarded-for"), header(req, "x-real-ip"));
            const decision = self.limiter.check(client, rule) catch return respond(req, .service_unavailable, "application/json", "{\"error\":\"rate limiter unavailable\"}", &.{});
            if (!decision.allowed) {
                var retry_buf: [16]u8 = undefined;
                var limit_buf: [16]u8 = undefined;
                const retry = try std.fmt.bufPrint(&retry_buf, "{d}", .{decision.retry_after});
                const limit = try std.fmt.bufPrint(&limit_buf, "{d}", .{decision.limit});
                const headers = [_]std.http.Header{
                    .{ .name = "retry-after", .value = retry },
                    .{ .name = "x-ratelimit-limit", .value = limit },
                    .{ .name = "x-ratelimit-remaining", .value = "0" },
                };
                return respond(req, .too_many_requests, "application/json", "{\"error\":\"rate limit exceeded\"}", &headers);
            }
        }
        const auth_owned: ?[]u8 = if (header(req, "authorization")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (auth_owned) |v| self.allocator.free(v);
        const osu_token_owned: ?[]u8 = if (header(req, "osu-token")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (osu_token_owned) |v| self.allocator.free(v);
        const score_token_owned: ?[]u8 = if (header(req, "token")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (score_token_owned) |v| self.allocator.free(v);
        const content_type_owned: ?[]u8 = if (req.head.content_type) |v| try self.allocator.dupe(u8, v) else null;
        defer if (content_type_owned) |v| self.allocator.free(v);
        const country_owned: ?[]u8 = if (header(req, "cf-ipcountry")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (country_owned) |v| self.allocator.free(v);
        const host_owned: ?[]u8 = if (header(req, "host")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (host_owned) |v| self.allocator.free(v);
        const cookie_owned: ?[]u8 = if (header(req, "cookie")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (cookie_owned) |v| self.allocator.free(v);
        const csrf_owned: ?[]u8 = if (header(req, "x-csrf-token")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (csrf_owned) |v| self.allocator.free(v);
        const origin_owned: ?[]u8 = if (header(req, "origin")) |v| try self.allocator.dupe(u8, v) else null;
        defer if (origin_owned) |v| self.allocator.free(v);
        const client_ip: ?[]const u8 = if (header(req, "cf-connecting-ip")) |v| v else if (header(req, "x-forwarded-for")) |v| blk: {
            const trimmed = std.mem.trim(u8, v, " ");
            if (std.mem.indexOfScalar(u8, trimmed, ',')) |comma| break :blk std.mem.trim(u8, trimmed[0..comma], " ");
            break :blk trimmed;
        } else if (header(req, "x-real-ip")) |v| v else null;
        if ((req.head.method == .GET or req.head.method == .HEAD) and web_auth.protocolHost(host_owned) and routing.websitePage(path)) {
            const location = try std.fmt.allocPrint(self.allocator, "https://kai.ovh{s}", .{target});
            defer self.allocator.free(location);
            return respond(req, .permanent_redirect, "text/plain", "", &.{.{ .name = "location", .value = location }});
        }
        const body: []u8 = if (req.head.method.requestHasBody()) b: {
            const r = req.readerExpectContinue(&.{}) catch return error.BadBody;
            break :b r.allocRemaining(self.allocator, .limited(bodyLimit(path))) catch |err| switch (err) {
                error.StreamTooLong => return respond(req, .payload_too_large, "application/json", "{\"error\":\"request body too large\"}", &.{}),
                else => return err,
            };
        } else &.{};
        defer if (body.len > 0) self.allocator.free(body);

        if (std.mem.eql(u8, path, "/health")) {
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            defer self.sessions.mutex.unlock(self.sessions.io);
            var buf: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"service\":\"zigcho\",\"online\":{d},\"protocol\":19}}", .{self.sessions.humanCount()});
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/metrics")) {
            if (req.head.method != .GET or !isLocalMetricsHost(host_owned)) return respond(req, .not_found, "text/plain", "not found\n", &.{});
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            const online = self.sessions.humanCount();
            self.sessions.mutex.unlock(self.sessions.io);
            const counts = try self.store.serverCounts();
            const cache = try self.store.beatmapCacheStats();
            const hydration = self.map_sync.metrics();
            const uptime = @max(@as(i64, 0), std.Io.Clock.real.now(self.store.io).toSeconds() - self.started_at);
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            try output.writer.print(
                "# HELP zigcho_up Whether the server can answer requests.\n" ++
                    "# TYPE zigcho_up gauge\nzigcho_up 1\n" ++
                    "# TYPE zigcho_online_users gauge\nzigcho_online_users {d}\n" ++
                    "# TYPE zigcho_accounts gauge\nzigcho_accounts {d}\n" ++
                    "# TYPE zigcho_plays gauge\nzigcho_plays {d}\n" ++
                    "# TYPE zigcho_passed_plays gauge\nzigcho_passed_plays {d}\n" ++
                    "# TYPE zigcho_beatmaps gauge\nzigcho_beatmaps {d}\n" ++
                    "# TYPE zigcho_beatmap_cache_entries gauge\nzigcho_beatmap_cache_entries {d}\n" ++
                    "# TYPE zigcho_beatmap_cache_bytes gauge\nzigcho_beatmap_cache_bytes {d}\n" ++
                    "# TYPE zigcho_beatmap_hydration_blocked gauge\nzigcho_beatmap_hydration_blocked {d}\n" ++
                    "# TYPE zigcho_beatmap_hydration_attempts counter\nzigcho_beatmap_hydration_attempts {d}\n" ++
                    "# TYPE zigcho_beatmap_hydration_successes counter\nzigcho_beatmap_hydration_successes {d}\n" ++
                    "# TYPE zigcho_beatmap_hydration_failures counter\nzigcho_beatmap_hydration_failures {d}\n" ++
                    "# TYPE zigcho_beatmap_hydration_backoff_skips counter\nzigcho_beatmap_hydration_backoff_skips {d}\n" ++
                    "# TYPE zigcho_beatmap_cache_pruned_entries counter\nzigcho_beatmap_cache_pruned_entries {d}\n" ++
                    "# TYPE zigcho_beatmap_cache_pruned_bytes counter\nzigcho_beatmap_cache_pruned_bytes {d}\n" ++
                    "# TYPE zigcho_uptime_seconds counter\nzigcho_uptime_seconds {d}\n",
                .{ online, counts.users, counts.plays, counts.passed, counts.maps, cache.entries, cache.bytes, cache.hydration_failures, hydration.attempts, hydration.successes, hydration.failures, hydration.backoff_skips, hydration.pruned_entries, hydration.pruned_bytes, uptime },
            );
            return respond(req, .ok, "text/plain; version=0.0.4; charset=utf-8", output.written(), &.{.{ .name = "cache-control", .value = "no-store" }});
        }
        if (std.mem.eql(u8, path, "/api/v1/status")) {
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            const online = self.sessions.humanCount();
            self.sessions.mutex.unlock(self.sessions.io);
            const counts = try self.store.serverCounts();
            var buf: [384]u8 = undefined;
            const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"service\":\"zigcho\",\"stage\":\"debug alpha\",\"online\":{d},\"users\":{d},\"plays\":{d},\"passed\":{d},\"maps\":{d},\"protocol\":19}}", .{ online, counts.users, counts.plays, counts.passed, counts.maps });
            return respond(req, .ok, "application/json", json, &.{});
        }
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
                const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid credentials\"}", &no_store);
                defer self.allocator.free(user.name);
                defer self.allocator.free(user.safe_name);
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

            if (std.mem.eql(u8, path, "/api/v1/staff/overview") and req.head.method == .GET) {
                const json = try self.store.staffOverviewJson(self.allocator);
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
                    if (std.mem.eql(u8, action, "note")) {
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
                        try self.store.setRestricted(staff_user.id, target_id, restricted, trimmed_reason);
                        self.sessions.mutex.lockUncancelable(self.sessions.io);
                        defer self.sessions.mutex.unlock(self.sessions.io);
                        if (self.sessions.byUser(target_id)) |online| {
                            online.user.restricted = restricted;
                            var packet = protocol.Writer.init(self.allocator);
                            defer packet.deinit();
                            if (restricted) {
                                try packet.packetEmpty(.account_restricted);
                                var visibility = protocol.Writer.init(self.allocator);
                                defer visibility.deinit();
                                const start = try visibility.begin(.user_logout);
                                try visibility.int(i32, target_id);
                                try visibility.byte(0);
                                visibility.finish(start);
                                try self.sessions.broadcast(visibility.bytes(), online);
                            }
                            try packet.packetInt(.restart, 0);
                            try online.enqueue(self.allocator, packet.bytes());
                        }
                    } else if (std.mem.eql(u8, action, "add_privilege") or std.mem.eql(u8, action, "remove_privilege")) {
                        if (!web_auth.canDevelop(staff_user)) return respond(req, .forbidden, "application/json", "{\"error\":\"developer access required\"}", &no_store);
                        const bits_text = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"bits"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"privilege bits required\"}", &no_store);
                        defer self.allocator.free(bits_text);
                        const bits = std.fmt.parseInt(u32, bits_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid privilege bits\"}", &no_store);
                        const allowed_bits: u32 = 1 | 2 | (1 << 4) | (1 << 5) | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 13) | (1 << 14);
                        if (bits == 0 or bits & ~allowed_bits != 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid privilege bits\"}", &no_store);
                        const privileges = try self.store.changePrivileges(staff_user.id, target_id, bits, std.mem.eql(u8, action, "add_privilege"));
                        self.sessions.mutex.lockUncancelable(self.sessions.io);
                        defer self.sessions.mutex.unlock(self.sessions.io);
                        if (self.sessions.byUser(target_id)) |online| {
                            online.user.privileges = privileges;
                            var packet = protocol.Writer.init(self.allocator);
                            defer packet.deinit();
                            try packet.packetInt(.privileges, stableClientPrivileges(privileges));
                            try online.enqueue(self.allocator, packet.bytes());
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
            const known_staff_path = std.mem.eql(u8, path, "/api/v1/staff/overview") or
                std.mem.eql(u8, path, "/api/v1/staff/ranking") or
                std.mem.eql(u8, path, "/api/v1/staff/moderation") or
                std.mem.eql(u8, path, "/api/v1/staff/appeals") or
                std.mem.eql(u8, path, "/api/v1/staff/audit") or
                std.mem.eql(u8, path, "/api/v1/staff/channels");
            return respond(req, if (known_staff_path) .method_not_allowed else .not_found, "application/json", if (known_staff_path) "{\"error\":\"method not allowed\"}" else "{\"error\":\"not found\"}", &no_store);
        }
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v1/rankings")) {
            const mode = std.fmt.parseInt(u8, queryField(target, "mode") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            const offset = std.fmt.parseInt(u16, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
            if (!validSiteMode(mode) or offset > 10_000) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid rankings\"}", &.{});
            const listing = try self.store.siteRankings(self.allocator, mode, offset);
            defer self.allocator.free(listing);
            return respond(req, .ok, "application/json", listing, &.{});
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/users/")) {
            const user_id = std.fmt.parseInt(i32, path["/api/v1/users/".len..], 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user\"}", &.{});
            if (user_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid user\"}", &.{});
            const mode = std.fmt.parseInt(u8, queryField(target, "mode") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            if (!validSiteMode(mode)) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            const profile = (try self.store.siteProfile(self.allocator, user_id, mode)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"player not found\"}", &.{});
            defer self.allocator.free(profile);
            return respond(req, .ok, "application/json", profile, &.{});
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v1/beatmapsets/")) {
            const set_id = std.fmt.parseInt(i32, path["/api/v1/beatmapsets/".len..], 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            if (set_id <= 0) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            const set = (try self.store.lazerBeatmapSet(self.allocator, set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
            defer self.allocator.free(set);
            return respond(req, .ok, "application/json", set, &.{});
        }
        if (req.head.method == .GET and (isAvatarHost(host_owned) or std.mem.startsWith(u8, path, "/avatars/") or std.mem.startsWith(u8, path, "/avatar/"))) {
            if (avatarUserId(path)) |user_id| {
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
            const set_id = std.fmt.parseInt(i32, path[3..], 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const archive = (try self.store.beatmapArchive(self.allocator, set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap archive unavailable\"}", &.{});
            defer self.allocator.free(archive);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{d}.osz\"", .{set_id});
            const headers = [_]std.http.Header{.{ .name = "content-disposition", .value = disposition }};
            return respond(req, .ok, "application/x-osu-beatmap-archive", archive, &headers);
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and std.mem.endsWith(u8, path, "/download")) {
            const id_text = path["/api/v2/beatmapsets/".len .. path.len - "/download".len];
            const set_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const archive = (try self.store.beatmapArchive(self.allocator, set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap archive unavailable\"}", &.{});
            defer self.allocator.free(archive);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{d}.osz\"", .{set_id});
            const headers = [_]std.http.Header{.{ .name = "content-disposition", .value = disposition }};
            return respond(req, .ok, "application/x-osu-beatmap-archive", archive, &headers);
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmaps/") and std.mem.endsWith(u8, path, "/file")) {
            const id_text = path["/api/v2/beatmaps/".len .. path.len - "/file".len];
            const map_id = std.fmt.parseInt(i32, id_text, 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap\"}", &.{});
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const map_file = (try self.store.beatmapFileById(self.allocator, map_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap file unavailable\"}", &.{});
            defer self.allocator.free(map_file);
            var disposition_buf: [96]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{d}.osu\"", .{map_id});
            const headers = [_]std.http.Header{.{ .name = "content-disposition", .value = disposition }};
            return respond(req, .ok, "application/x-osu-beatmap", map_file, &headers);
        }
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
            if (name.len < 2 or name.len > 32 or email.len > 254) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid fields\"}", &.{});
            const id = self.store.register(name, email, &password_md5) catch |err| return respond(req, if (err == error.UserExists) .conflict else .internal_server_error, "application/json", "{\"error\":\"registration failed\"}", &.{});
            var out: [96]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d},\"name\":\"{s}\"}}", .{ id, name });
            return respond(req, .created, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/oauth/token") and req.head.method == .POST) {
            const grant = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"grant_type"})) orelse try self.allocator.dupe(u8, "password");
            defer self.allocator.free(grant);
            if (!std.mem.eql(u8, grant, "password")) return respond(req, .bad_request, "application/json", "{\"error\":\"unsupported_grant_type\"}", &.{});
            const name = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"username"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            defer self.allocator.free(name);
            const password = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{ "password_md5", "password" })) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            defer self.allocator.free(password);
            const password_md5 = form_urlencoded.credentialMd5(password) catch return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
            const user = (try self.store.authenticate(self.allocator, name, &password_md5)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const token = try self.store.issueToken(user.id, "identify scores:write", 3600);
            var out: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"identify scores:write\",\"access_token\":\"{s}\"}}", .{token});
            const token_headers = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "pragma", .value = "no-cache" },
            };
            return respond(req, .ok, "application/json", json, &token_headers);
        }
        if (std.mem.eql(u8, path, "/oauth/revoke") and req.head.method == .POST) {
            const token = (try form_urlencoded.requestField(self.allocator, body, content_type_owned, &.{"token"})) orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            defer self.allocator.free(token);
            _ = try self.store.revokeToken(token);
            return respond(req, .ok, "application/json", "{}", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/mods")) return respond(req, .ok, "application/json", "{\"mods\":[{\"acronym\":\"RX\",\"name\":\"Relax\",\"description\":\"Server-side cursor relax\",\"ranked\":false,\"score_multiplier\":0.0,\"settings\":{}}],\"custom_mod_contract\":{\"acronym\":\"2-8 uppercase ASCII characters\",\"settings\":\"arbitrary JSON object\",\"leaderboard\":\"custom namespace\",\"ranked\":false}}", &.{});
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/seasonal-backgrounds")) return respond(req, .ok, "application/json", "{\"backgrounds\":[]}", &.{});
        if (req.head.method == .GET and std.mem.eql(u8, path, "/web/osu-getseasonal.php")) return respond(req, .ok, "application/json", "[]", &.{});
        if (req.head.method == .GET and std.mem.eql(u8, path, "/menu-content.json")) return respond(req, .ok, "application/json", "{\"images\":[]}", &.{});
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmapsets/search")) {
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const mode = std.fmt.parseInt(i8, queryField(target, "m") orelse "-1", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid mode\"}", &.{});
            const offset = std.fmt.parseInt(u16, queryField(target, "offset") orelse "0", 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid offset\"}", &.{});
            if (mode < -1 or mode > 3 or offset > 10_000) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid search\"}", &.{});
            const encoded_query = queryField(target, "q") orelse "";
            const query_buf = try self.allocator.dupe(u8, encoded_query);
            defer self.allocator.free(query_buf);
            for (query_buf) |*char| {
                if (char.* == '+') char.* = ' ';
            }
            const query = std.Uri.percentDecodeInPlace(query_buf);
            const listing = try self.store.lazerBeatmapSearch(self.allocator, query, mode, offset);
            defer self.allocator.free(listing);
            return respond(req, .ok, "application/json", listing, &.{});
        }
        if (req.head.method == .GET and std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") and !std.mem.endsWith(u8, path, "/download")) {
            const set_id = std.fmt.parseInt(i32, path["/api/v2/beatmapsets/".len..], 10) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid beatmap set\"}", &.{});
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const listing = (try self.store.lazerBeatmapSet(self.allocator, set_id)) orelse return respond(req, .not_found, "application/json", "{\"error\":\"beatmap set not found\"}", &.{});
            defer self.allocator.free(listing);
            return respond(req, .ok, "application/json", listing, &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/me")) {
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "identify")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            var out: [512]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d},\"username\":\"{s}\",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":\"{s}\",\"is_active\":true,\"is_online\":true,\"statistics_rulesets\":{{}}}}", .{ user.id, user.name, user.id, user.country });
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/scores") and req.head.method == .POST) {
            const auth = auth_owned orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            if (!std.mem.startsWith(u8, auth, "Bearer ")) return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            const user = (try self.store.authenticateToken(self.allocator, auth[7..], "scores:write")) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"unauthorized\"}", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_json\"}", &.{});
            defer parsed.deinit();
            const score = lazer.parseScore(parsed.value) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_score_or_mod\"}", &.{});
            const ns_name = @tagName(score.namespace);
            const id = try self.store.insertLazerScore(user.id, score, body);
            var out: [192]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d},\"user_id\":{d},\"rank_namespace\":\"{s}\",\"ranked\":false}}", .{ id, user.id, ns_name });
            return respond(req, .created, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/") and req.head.method == .POST) {
            if (osu_token_owned) |token| {
                const bytes = (try bancho.pollByToken(self.allocator, &self.store, &self.sessions, token, body)) orelse {
                    var restart = protocol.Writer.init(self.allocator);
                    defer restart.deinit();
                    try restart.packetString(.notification, "Server has restarted.");
                    const rs = try restart.begin(.restart);
                    try restart.int(i32, 0);
                    restart.finish(rs);
                    return respond(req, .ok, "application/octet-stream", restart.bytes(), &.{});
                };
                defer self.allocator.free(bytes);
                return respond(req, .ok, "application/octet-stream", bytes, &.{});
            }
            const geo = if (client_ip) |ip| self.lookupGeo(ip) else GeoResult{ .lon = 0, .lat = 0 };
            var result = try bancho.login(self.allocator, &self.store, &self.sessions, body, if (country_owned) |value| country.normalized(value) else null, geo.lon, geo.lat);
            defer result.deinit();
            const token_headers = [_]std.http.Header{
                .{ .name = "cho-token", .value = result.token },
                .{ .name = "osu-token", .value = result.token },
            };
            return respond(req, .ok, "application/octet-stream", result.body, &token_headers);
        }
        if (std.mem.eql(u8, path, "/web/bancho_connect.php")) return respond(req, .ok, "text/plain", "ok", &.{});
        if (std.mem.eql(u8, path, "/web/check-updates.php")) return respond(req, .ok, "application/json", "{\"latest\":null}", &.{});
        if (std.mem.eql(u8, path, "/web/lastfm.php") and req.head.method == .GET) {
            const action = queryField(target, "action") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            if (!std.mem.eql(u8, action, "np") and !std.mem.eql(u8, action, "scrobble")) return respond(req, .bad_request, "text/plain", "", &.{});
            const encoded_name = queryField(target, "us") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const password = queryField(target, "ha") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            const beatmap_or_flag = queryField(target, "b") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const name_buf = try self.allocator.dupe(u8, encoded_name);
            defer self.allocator.free(name_buf);
            for (name_buf) |*char| if (char.* == '+') {
                char.* = ' ';
            };
            const name = std.Uri.percentDecodeInPlace(name_buf);
            const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "", &.{});
            if (beatmap_or_flag.len == 0 or beatmap_or_flag[0] != 'a') return respond(req, .ok, "text/plain", "-3", &.{});
            const flags = std.fmt.parseInt(u32, beatmap_or_flag[1..], 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            if (flags != 0) {
                try self.store.recordLastFmFlag(user.id, flags);
            }
            std.log.info("lastfm: user_id={d} action={s} flags={d} b={s}", .{ user.id, action, flags, beatmap_or_flag });
            const hq_flags: u32 = (@as(u32, 1) << 17) | (@as(u32, 1) << 18);
            if (flags & hq_flags != 0) {
                _ = try self.store.restrictForClientFlag(user.id, flags);
                bancho.disconnectRestrictedUser(self.allocator, &self.sessions, user.id);
            }
            const hq_or_registry: u32 = hq_flags | (@as(u32, 1) << 19);
            return respond(req, .ok, "text/plain", if (flags & hq_or_registry != 0) "-3" else "", &.{});
        }
        if (std.mem.eql(u8, path, "/web/osu-rate.php") and req.head.method == .GET) {
            const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const password = queryField(target, "p") orelse return respond(req, .unauthorized, "text/plain", "auth fail", &.{});
            const map_md5 = queryField(target, "c") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            if (map_md5.len != 32) return respond(req, .bad_request, "text/plain", "", &.{});
            const rating: ?u8 = if (queryField(target, "v")) |value| std.fmt.parseInt(u8, value, 10) catch return respond(req, .bad_request, "text/plain", "", &.{}) else null;
            if (rating) |value| if (value < 1 or value > 10) return respond(req, .bad_request, "text/plain", "", &.{});
            const name_buf = try self.allocator.dupe(u8, encoded_name);
            defer self.allocator.free(name_buf);
            for (name_buf) |*char| if (char.* == '+') {
                char.* = ' ';
            };
            const name = std.Uri.percentDecodeInPlace(name_buf);
            const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "auth fail", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "auth fail", &.{});
            return switch (try self.store.rateBeatmap(user.id, map_md5, rating)) {
                .no_exist => respond(req, .ok, "text/plain", "no exist", &.{}),
                .not_ranked => respond(req, .ok, "text/plain", "not ranked", &.{}),
                .can_rate => respond(req, .ok, "text/plain", "ok", &.{}),
                .already_voted => |average| voted: {
                    var rating_buf: [64]u8 = undefined;
                    const response = try std.fmt.bufPrint(&rating_buf, "alreadyvoted\n{d}", .{average});
                    break :voted respond(req, .ok, "text/plain", response, &.{});
                },
            };
        }
        if (req.head.method == .GET and (std.mem.eql(u8, path, "/web/osu-getfriends.php") or std.mem.eql(u8, path, "/web/osu-getfavourites.php") or std.mem.eql(u8, path, "/web/osu-addfavourite.php"))) {
            const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const password = queryField(target, "h") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            const name_buf = try self.allocator.dupe(u8, encoded_name);
            defer self.allocator.free(name_buf);
            for (name_buf) |*char| if (char.* == '+') {
                char.* = ' ';
            };
            const name = std.Uri.percentDecodeInPlace(name_buf);
            const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            defer freeUser(self.allocator, user);
            if (!self.userOnline(user.id)) return respond(req, .unauthorized, "text/plain", "", &.{});
            if (std.mem.eql(u8, path, "/web/osu-addfavourite.php")) {
                const set_id = std.fmt.parseInt(i32, queryField(target, "a") orelse return respond(req, .bad_request, "text/plain", "", &.{}), 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
                if (set_id <= 0) return respond(req, .bad_request, "text/plain", "", &.{});
                return respond(req, .ok, "text/plain", if (try self.store.addFavourite(user.id, set_id)) "Added favourite!" else "You've already favourited this beatmap!", &.{});
            }
            const ids = if (std.mem.eql(u8, path, "/web/osu-getfriends.php")) try self.store.friendIds(self.allocator, user.id) else try self.store.favouriteSetIds(self.allocator, user.id);
            defer self.allocator.free(ids);
            const response = try intLines(self.allocator, ids);
            defer self.allocator.free(response);
            return respond(req, .ok, "text/plain", response, &.{});
        }
        if ((std.mem.eql(u8, path, "/web/osu-search.php") or std.mem.eql(u8, path, "/web/osu-search-set.php")) and req.head.method == .GET) {
            const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const password = queryField(target, "h") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            const name_buf = try self.allocator.dupe(u8, encoded_name);
            defer self.allocator.free(name_buf);
            for (name_buf) |*char| {
                if (char.* == '+') char.* = ' ';
            }
            const name = std.Uri.percentDecodeInPlace(name_buf);
            const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            if (std.mem.eql(u8, path, "/web/osu-search.php")) {
                const direct_status = std.fmt.parseInt(u8, queryField(target, "r") orelse "4", 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
                const mode = std.fmt.parseInt(i8, queryField(target, "m") orelse "-1", 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
                const page = std.fmt.parseInt(u16, queryField(target, "p") orelse "0", 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
                if (direct_status > 8 or mode < -1 or mode > 3 or page > 1000) return respond(req, .bad_request, "text/plain", "", &.{});
                const encoded_query = queryField(target, "q") orelse "";
                const query_buf = try self.allocator.dupe(u8, encoded_query);
                defer self.allocator.free(query_buf);
                for (query_buf) |*char| {
                    if (char.* == '+') char.* = ' ';
                }
                const decoded_query = std.Uri.percentDecodeInPlace(query_buf);
                const query = if (std.mem.eql(u8, decoded_query, "Newest") or std.mem.eql(u8, decoded_query, "Top Rated") or std.mem.eql(u8, decoded_query, "Most Played")) "" else decoded_query;
                const listing = try self.store.stableSearch(self.allocator, query, mode, direct_status, page);
                defer self.allocator.free(listing);
                return respond(req, .ok, "text/plain", listing, &.{});
            }
            const set_id: ?i32 = if (queryField(target, "s")) |value| std.fmt.parseInt(i32, value, 10) catch return respond(req, .bad_request, "text/plain", "", &.{}) else null;
            const map_id: ?i32 = if (queryField(target, "b")) |value| std.fmt.parseInt(i32, value, 10) catch return respond(req, .bad_request, "text/plain", "", &.{}) else null;
            const checksum = queryField(target, "c");
            if (set_id == null and map_id == null and checksum == null) return respond(req, .bad_request, "text/plain", "", &.{});
            if (checksum) |value| if (value.len != 32) return respond(req, .bad_request, "text/plain", "", &.{});
            const listing = try self.store.stableSearchSet(self.allocator, set_id, map_id, checksum);
            defer self.allocator.free(listing);
            return respond(req, .ok, "text/plain", listing, &.{});
        }
        if (std.mem.eql(u8, path, "/web/osu-osz2-getscores.php") and req.head.method == .GET) {
            const encoded_name = queryField(target, "us") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const password = queryField(target, "ha") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            const map_md5 = queryField(target, "c") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const set_id_text = queryField(target, "i") orelse "0";
            const mode_text = queryField(target, "m") orelse "0";
            const board_text = queryField(target, "v") orelse "1";
            const mods_text = queryField(target, "mods") orelse "0";
            const mode = std.fmt.parseInt(u8, mode_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const board_type = std.fmt.parseInt(u8, board_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const mods = std.fmt.parseInt(i32, mods_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const set_id = std.fmt.parseInt(i32, set_id_text, 10) catch 0;
            if (mode > 3 or board_type > 4 or map_md5.len != 32) return respond(req, .bad_request, "text/plain", "", &.{});
            const name_buf = try self.allocator.dupe(u8, encoded_name);
            defer self.allocator.free(name_buf);
            for (name_buf) |*char| {
                if (char.* == '+') char.* = ' ';
            }
            const name = std.Uri.percentDecodeInPlace(name_buf);
            const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            if (try beatmap_sync.needsHydration(&self.store, map_md5)) {
                std.debug.print("{s}  ┌─ LEADERBOARD ──────────────────────────────────{s}\n", .{ log.cyan, log.reset });
                std.debug.print("{s}  │ {s}►{s} user : {s}{s}{s}\n", .{ log.cyan, log.dim, log.reset, log.green, user.name, log.reset });
                std.debug.print("{s}  │ {s}►{s} map  : {s}{s}\n", .{ log.cyan, log.dim, log.reset, log.dim, map_md5 });
                std.debug.print("{s}  │ {s}►{s} hydrating...{s}\n", .{ log.cyan, log.dim, log.reset, log.dim });
                _ = self.map_sync.ensure(&self.store, map_md5, if (set_id > 0) set_id else null) catch |err| {
                    std.debug.print("{s}  │ {s}✗ hydration failed: {t}{s}\n", .{ log.red, log.reset, err, log.reset });
                };
            }
            const listing = try self.store.stableLeaderboard(self.allocator, user, map_md5, mode, board_type, mods);
            defer self.allocator.free(listing);
            return respond(req, .ok, "text/plain", listing, &.{});
        }
        if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php") and req.head.method == .POST) {
            const content_type = content_type_owned orelse return rejectStableScore(req, "missing_content_type", body.len);
            const boundary = multipart.boundaryFromContentType(content_type) catch |err| return rejectStableScoreError(req, "invalid_boundary", err, body.len);
            var form = multipart.parse(self.allocator, body, boundary) catch |err| return rejectStableScoreError(req, "invalid_multipart", err, body.len);
            defer form.deinit();
            const encrypted = form.nth("score", 0) orelse return rejectStableScore(req, "missing_encrypted_score", body.len);
            const replay = form.nth("score", 1) orelse return rejectStableScore(req, "missing_replay", body.len);
            if (encrypted.filename != null) return rejectStableScore(req, "encrypted_score_is_file", body.len);
            if (replay.filename == null) return rejectStableScore(req, "replay_is_not_file", body.len);
            const iv = (form.first("iv") orelse return rejectStableScore(req, "missing_iv", body.len)).data;
            const client_hash_encrypted = (form.first("s") orelse return rejectStableScore(req, "missing_client_hash", body.len)).data;
            const password = (form.first("pass") orelse {
                std.log.warn("stable score rejected: reason=missing_password body_bytes={d}", .{body.len});
                return respond(req, .unauthorized, "text/plain", "", &.{});
            }).data;
            const osu_version = (form.first("osuver") orelse return rejectStableScore(req, "missing_osu_version", body.len)).data;
            const updated_map_hash = (form.first("bmk") orelse return rejectStableScore(req, "missing_updated_map_hash", body.len)).data;
            const storyboard_hash = if (form.first("sbk")) |part| part.data else "";
            const score_time = std.fmt.parseInt(u32, (form.first("st") orelse return rejectStableScore(req, "missing_score_time", body.len)).data, 10) catch return rejectStableScore(req, "invalid_score_time", body.len);
            const fail_time = std.fmt.parseInt(u32, (form.first("ft") orelse return rejectStableScore(req, "missing_fail_time", body.len)).data, 10) catch return rejectStableScore(req, "invalid_fail_time", body.len);
            var decrypted = score_crypto.decrypt(self.allocator, encrypted.data, client_hash_encrypted, iv, osu_version) catch |err| return rejectStableScoreError(req, "decrypt_failed", err, body.len);
            defer decrypted.deinit();
            const score = stable_score.parse(decrypted.score_data) catch |err| {
                std.log.warn("stable score rejected: reason=score_parse_failed error={t} fields={d} plaintext_bytes={d} body_bytes={d}", .{ err, std.mem.count(u8, decrypted.score_data, ":") + 1, decrypted.score_data.len, body.len });
                return respond(req, .bad_request, "text/plain", "error: no", &.{});
            };
            if (!stable_score.replayLengthAccepted(score.passed, replay.data.len)) {
                return rejectStableScore(req, if (replay.data.len == 0) "passed_score_missing_replay" else "replay_too_large", body.len);
            }
            if (!std.mem.eql(u8, score.map_md5, updated_map_hash)) {
                std.log.warn("stable score rejected: reason=beatmap_hash_mismatch body_bytes={d}", .{body.len});
                return respond(req, .bad_request, "text/plain", "error: beatmap", &.{});
            }
            const auth_username = if (score.username.len > 0 and score.username[score.username.len - 1] == ' ') score.username[0 .. score.username.len - 1] else score.username;
            const user = (try self.store.authenticate(self.allocator, auth_username, password)) orelse {
                std.log.warn("stable score rejected: reason=invalid_credentials body_bytes={d}", .{body.len});
                return respond(req, .ok, "text/plain", "error: no", &.{});
            };
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            switch (self.sessions.authorizeScoreToken(score_token_owned, user.id)) {
                .exact, .stale_online => {},
                .missing => {
                    std.log.warn("stable score rejected: reason=missing_session_token body_bytes={d}", .{body.len});
                    return respond(req, .unauthorized, "text/plain", "", &.{});
                },
                .foreign_live => {
                    std.log.warn("stable score rejected: reason=foreign_session_token user_id={d} body_bytes={d}", .{ user.id, body.len });
                    return respond(req, .unauthorized, "text/plain", "", &.{});
                },
                .offline => {
                    std.log.warn("stable score rejected: reason=inactive_session body_bytes={d}", .{body.len});
                    return respond(req, .ok, "text/plain", "error: no", &.{});
                },
            }
            if (!score.verifyChecksum(osu_version, decrypted.client_hash, storyboard_hash)) return rejectStableScore(req, "checksum_mismatch", body.len);
            const map_file = (try self.store.beatmapFile(self.allocator, score.map_md5)) orelse return respond(req, .ok, "text/plain", "error: beatmap", &.{});
            defer self.allocator.free(map_file);
            const performance = pp.calculate(map_file, .{
                .mode = score.mode,
                .lazer = 0,
                .mods = @intCast(score.mods),
                .max_combo = @intCast(score.max_combo),
                .n_geki = @intCast(score.ngeki),
                .n_katu = @intCast(score.nkatu),
                .n300 = @intCast(score.n300),
                .n100 = @intCast(score.n100),
                .n50 = @intCast(score.n50),
                .misses = @intCast(score.nmiss),
                .legacy_total_score = @intCast(@min(score.total_score, std.math.maxInt(u32))),
            }) catch return respond(req, .ok, "text/plain", "error: beatmap", &.{});
            const stats_mode = stable_score.statsMode(score.mode, score.mods) orelse return respond(req, .ok, "text/plain", "error: no", &.{});
            const before_stats = (try self.store.statsForUser(user.id, stats_mode)) orelse domain.Stats{};
            const score_id = self.store.insertStableScore(user.id, score, performance.pp, replay.data, if (score.passed) score_time else fail_time) catch |err| {
                std.log.warn("stable score insert failed: {t}", .{err});
                return respond(req, .ok, "text/plain", "error: no", &.{});
            };
            const after_stats = (try self.store.statsForUser(user.id, stats_mode)) orelse domain.Stats{};
            const placement = try self.store.scoreLeaderboardPlacement(score_id);
            bancho.publishStats(self.allocator, &self.store, &self.sessions, user.id, score.mode, score.mods) catch {};
            scoreLog(user.name, score, performance.pp, placement);
            if (!score.passed) return respond(req, .ok, "text/plain", "error: no", &.{});
            const map_state = (try self.store.beatmapForScore(score.map_md5)) orelse return respond(req, .ok, "text/plain", "error: no", &.{});
            const placed = placement orelse return respond(req, .ok, "text/plain", "error: no", &.{});
            if (webhook.shouldAnnounceScore(placed, performance.pp)) {
                if (try self.store.beatmapInfo(self.allocator, score.map_md5)) |info| {
                    defer self.allocator.free(info.artist);
                    defer self.allocator.free(info.title);
                    defer self.allocator.free(info.version);
                    announceScore(self.allocator, &self.sessions, user.name, score, performance.pp, placed, info) catch {};
                    self.score_webhook.postScore(.{
                        .username = user.name,
                        .user_id = user.id,
                        .grade = score.grade,
                        .mods = score.mods,
                        .mode = score.mode,
                        .rank = placed.rank + 1,
                        .total_score = score.total_score,
                        .max_combo = score.max_combo,
                        .beatmap_max_combo = info.max_combo,
                        .accuracy = score.accuracy(),
                        .pp = performance.pp,
                        .stars = info.star_rating,
                        .perfect = score.perfect,
                        .artist = info.artist,
                        .title = info.title,
                        .version = info.version,
                        .set_id = info.set_id,
                    });
                }
            }
            const response_body = try stable_response.scoreSubmission(self.allocator, user.id, score_id, score, .{ .id = map_state.id, .set_id = map_state.set_id, .plays = map_state.plays, .passes = map_state.passes }, placed, before_stats, after_stats, performance.pp);
            defer self.allocator.free(response_body);
            return respond(req, .ok, "text/plain", response_body, &.{});
        }
        if (std.mem.eql(u8, path, "/web/osu-getreplay.php") and req.head.method == .GET) {
            const encoded_name = queryField(target, "u") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const password = queryField(target, "h") orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            const score_id_text = queryField(target, "c") orelse return respond(req, .bad_request, "text/plain", "", &.{});
            const score_id = std.fmt.parseInt(i64, score_id_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const name_buf = try self.allocator.dupe(u8, encoded_name);
            defer self.allocator.free(name_buf);
            for (name_buf) |*c| {
                if (c.* == '+') c.* = ' ';
            }
            const name = std.Uri.percentDecodeInPlace(name_buf);
            const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const replay = (try self.store.replay(self.allocator, score_id)) orelse return respond(req, .not_found, "text/plain", "", &.{});
            defer self.allocator.free(replay);
            return respond(req, .ok, "application/octet-stream", replay, &.{});
        }
        if (req.head.method == .GET and routing.websitePage(path)) {
            if ((std.mem.eql(u8, path, "/staff") or std.mem.eql(u8, path, "/appeal")) and !web_auth.websiteHost(host_owned)) return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &.{});
            const headers = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "content-security-policy", .value = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' https://a.kai.ovh; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
            };
            return respond(req, .ok, "text/html; charset=utf-8", status_page, &headers);
        }
        return respond(req, .not_found, "application/json", "{\"error\":\"not found\"}", &.{});
    }
};

fn serveConnection(app: *App, stream_value: std.Io.net.Stream, io: std.Io) void {
    var stream = stream_value;
    defer stream.close(io);
    var recv: [64 * 1024]u8 = undefined;
    var send: [64 * 1024]u8 = undefined;
    var cr = stream.reader(io, &recv);
    var cw = stream.writer(io, &send);
    var server: std.http.Server = .init(&cr.interface, &cw.interface);
    var req = server.receiveHead() catch return;
    app.serve(&req) catch |err| std.log.err("request failed: {t}", .{err});
}

fn recalcAllScores(allocator: std.mem.Allocator, store: *sqlite_storage.Store) !void {
    const c = sqlite_storage.c;
    std.debug.print("recalculating all scores with akatsuki-pp...\n", .{});
    const scores_sql = "SELECT id,user_id,map_md5,mode,mods,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,score FROM scores WHERE passed=1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(store.db, scores_sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var count: u32 = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(stmt, 0);
        const map_md5 = std.mem.span(c.sqlite3_column_text(stmt, 2));
        const mode: u8 = @intCast(c.sqlite3_column_int(stmt, 3));
        const mods = c.sqlite3_column_int(stmt, 4);
        const max_combo: u32 = @intCast(c.sqlite3_column_int(stmt, 5));
        const n300: u32 = @intCast(c.sqlite3_column_int(stmt, 6));
        const n100: u32 = @intCast(c.sqlite3_column_int(stmt, 7));
        const n50: u32 = @intCast(c.sqlite3_column_int(stmt, 8));
        const nmiss: u32 = @intCast(c.sqlite3_column_int(stmt, 9));
        const ngeki: u32 = @intCast(c.sqlite3_column_int(stmt, 10));
        const nkatu: u32 = @intCast(c.sqlite3_column_int(stmt, 11));
        const total_score: u32 = @intCast(c.sqlite3_column_int64(stmt, 12));
        const md5_copy = try allocator.dupe(u8, map_md5);
        defer allocator.free(md5_copy);
        const map_file = (try store.beatmapFile(allocator, md5_copy)) orelse {
            std.debug.print("  score {d}: no .osu file, skipping\n", .{id});
            continue;
        };
        defer allocator.free(map_file);
        const result = pp.calculate(map_file, .{
            .mode = mode,
            .lazer = 0,
            .mods = @intCast(mods),
            .max_combo = max_combo,
            .n_geki = ngeki,
            .n_katu = nkatu,
            .n300 = n300,
            .n100 = n100,
            .n50 = n50,
            .misses = nmiss,
            .legacy_total_score = total_score,
        }) catch {
            std.debug.print("  score {d}: pp calc failed, skipping\n", .{id});
            continue;
        };
        const update_sql = "UPDATE scores SET pp=?1 WHERE id=?2";
        var up: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, update_sql, -1, &up, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_double(up, 1, result.pp);
        _ = c.sqlite3_bind_int64(up, 2, id);
        if (c.sqlite3_step(up) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(up);
        std.debug.print("  score {d}: pp={d:.2} stars={d:.2}\n", .{ id, result.pp, result.stars });
        count += 1;
    }
    std.debug.print("recalculated {d} scores. rebuilding stats...\n", .{count});
    try store.exec("BEGIN IMMEDIATE");
    try recalcStats(store);
    try store.exec("COMMIT");
    std.debug.print("done.\n", .{});
}

fn recalcStats(store: *sqlite_storage.Store) !void {
    const c = sqlite_storage.c;
    const modes_sql = "SELECT DISTINCT user_id,mode FROM stats";
    var m_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(store.db, modes_sql, -1, &m_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(m_stmt);
    while (c.sqlite3_step(m_stmt) == c.SQLITE_ROW) {
        const uid = c.sqlite3_column_int(m_stmt, 0);
        const stats_mode = c.sqlite3_column_int(m_stmt, 1);
        const vanilla_mode: i32 = switch (stats_mode) {
            0, 1, 2, 3 => stats_mode,
            4, 5, 6 => stats_mode - 4,
            8 => 0,
            else => continue,
        };
        const namespace: ?[]const u8 = switch (stats_mode) {
            0, 1, 2, 3 => "vanilla",
            4, 5, 6 => "relax",
            8 => "autopilot",
            else => null,
        };
        if (namespace == null) continue;
        const ns = namespace.?;
        const pp_sql = "SELECT s.pp,s.accuracy FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND b.status IN (3,4) ORDER BY s.pp DESC,s.id ASC";
        var pp_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, pp_sql, -1, &pp_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(pp_stmt);
        _ = c.sqlite3_bind_int(pp_stmt, 1, uid);
        _ = c.sqlite3_bind_int(pp_stmt, 2, vanilla_mode);
        _ = c.sqlite3_bind_text(pp_stmt, 3, ns.ptr, @intCast(ns.len), null);
        var total_pp: f64 = 0;
        var weighted_accuracy: f64 = 0;
        var weight: f64 = 1;
        var score_count: u32 = 0;
        while (c.sqlite3_step(pp_stmt) == c.SQLITE_ROW) {
            total_pp += c.sqlite3_column_double(pp_stmt, 0) * weight;
            weighted_accuracy += c.sqlite3_column_double(pp_stmt, 1) * weight;
            weight *= 0.95;
            score_count += 1;
        }
        const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
        const bonus_accuracy = if (score_count > 0) 1.0 / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count)))) else 0;
        const set_sql = "UPDATE stats SET pp=?1,accuracy=?2 WHERE user_id=?3 AND mode=?4";
        var set_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int64(set_stmt, 1, @intFromFloat(@round(total_pp + bonus_pp)));
        _ = c.sqlite3_bind_double(set_stmt, 2, weighted_accuracy * bonus_accuracy);
        _ = c.sqlite3_bind_int(set_stmt, 3, uid);
        _ = c.sqlite3_bind_int(set_stmt, 4, stats_mode);
        if (c.sqlite3_step(set_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(set_stmt);
        std.debug.print("  user {d} mode {d} ({s}): pp={d}\n", .{ uid, stats_mode, ns, @round(total_pp + bonus_pp) });
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len > 1 and std.mem.eql(u8, args[1], "check")) {
        if (args.len > 2) return error.UnexpectedCheckArgument;
        const database: [:0]const u8 = if (storage.is_postgres)
            std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
        else
            "zigcho.db";
        var store = try storage.Store.open(allocator, init.io, database);
        defer store.close();
        try store.migrate();
        const kai = (try store.userById(allocator, 3)) orelse return error.SystemBotMissing;
        defer {
            allocator.free(kai.name);
            allocator.free(kai.safe_name);
        }
        if (!std.mem.eql(u8, kai.safe_name, "kai")) return error.InvalidSystemBot;
        const counts = try store.serverCounts();
        std.log.info("event=preflight_ok storage={s} accounts={d} plays={d} passed={d} beatmaps={d}", .{
            if (storage.is_postgres) "postgres" else "sqlite",
            counts.users,
            counts.plays,
            counts.passed,
            counts.maps,
        });
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "recalc")) {
        if (storage.is_postgres) {
            if (args.len > 2) return error.PostgresUrlMustUseEnvironment;
            const conninfo = std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl);
            var store = try storage.Store.open(allocator, init.io, conninfo);
            defer store.close();
            try store.migrate();
            const count = try store.recalculatePerformance(allocator);
            std.log.info("event=postgres_pp_recalc_complete scores={d}", .{count});
        } else {
            const db_path: [:0]const u8 = if (args.len > 2) try allocator.dupeZ(u8, args[2]) else "zigcho.db";
            defer if (args.len > 2) allocator.free(db_path);
            var store = try sqlite_storage.Store.open(allocator, init.io, db_path);
            defer store.close();
            try store.migrate();
            try recalcAllScores(allocator, &store);
        }
        return;
    }
    const bind = if (args.len > 1) args[1] else "127.0.0.1";
    const port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 8080;
    const default_database: [:0]const u8 = if (storage.is_postgres)
        std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
    else
        "zigcho.db";
    const db_path: [:0]const u8 = if (args.len > 3) try allocator.dupeZ(u8, args[3]) else default_database;
    defer if (args.len > 3) allocator.free(db_path);
    var store = try storage.Store.open(allocator, init.io, db_path);
    defer store.close();
    try store.migrate();
    var config = try config_mod.load(allocator, init.io);
    defer config.deinit();
    var app: App = .{
        .allocator = allocator,
        .store = store,
        .sessions = sessions_mod.Sessions.init(allocator, init.io),
        .limiter = rate_limit.Limiter.init(allocator, init.io),
        .map_sync = beatmap_sync.Sync.init(allocator, init.io, config.osu_api_key, config.beatmap_cache_max_bytes),
        .score_webhook = webhook.Webhook.init(allocator, init.io, config.score_webhook),
        .geo_client = .{ .allocator = allocator, .io = init.io },
        .started_at = std.Io.Clock.real.now(init.io).toSeconds(),
    };
    var kai = (try app.store.userById(allocator, 3)) orelse return error.SystemBotMissing;
    kai.country = .{ 'I', 'S' };
    const kai_session = try app.sessions.createBot(kai);
    kai_session.longitude = -21.9426; // reykjavik
    kai_session.latitude = 64.1466;
    defer app.score_webhook.deinit();
    defer app.map_sync.deinit();
    defer app.geo_client.deinit();
    defer app.limiter.deinit();
    defer app.sessions.deinit();
    const address = try std.Io.net.IpAddress.parse(bind, port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var connections: std.Io.Group = .init;
    defer connections.cancel(init.io);
    std.log.info("event=server_started bind={s} port={d} storage={s}", .{ bind, port, if (storage.is_postgres) "postgres" else "sqlite" });
    while (true) {
        const stream = listener.accept(init.io) catch |err| {
            std.log.err("accept: {t}", .{err});
            continue;
        };
        connections.concurrent(init.io, serveConnection, .{ &app, stream, init.io }) catch |err| {
            std.log.err("spawn connection: {t}", .{err});
            var rejected = stream;
            rejected.close(init.io);
        };
    }
}
