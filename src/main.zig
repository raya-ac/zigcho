const std = @import("std");
const storage = @import("storage.zig");
const sessions_mod = @import("sessions.zig");
const bancho = @import("bancho.zig");
const lazer = @import("lazer.zig");
const multipart = @import("multipart.zig");
const score_crypto = @import("score_crypto.zig");
const stable_score = @import("stable_score.zig");
const rate_limit = @import("rate_limit.zig");
const pp = @import("pp.zig");
const status_page = @embedFile("status.html");

const App = struct {
    allocator: std.mem.Allocator,
    store: storage.Store,
    sessions: sessions_mod.Sessions,
    limiter: rate_limit.Limiter,

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

    fn requestRule(req: *const std.http.Server.Request, path: []const u8) ?rate_limit.Rule {
        if (req.head.method == .POST and std.mem.eql(u8, path, "/users")) return rate_limit.registration;
        if (req.head.method == .POST and (std.mem.eql(u8, path, "/oauth/token") or std.mem.eql(u8, path, "/oauth/revoke"))) return rate_limit.token;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/api/v2/scores")) return rate_limit.score;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return rate_limit.score;
        if (req.head.method == .GET and std.mem.eql(u8, path, "/api/v2/beatmapsets/search")) return rate_limit.authenticated;
        if (req.head.method == .GET and (std.mem.startsWith(u8, path, "/d/") or std.mem.startsWith(u8, path, "/api/v2/beatmapsets/") or std.mem.startsWith(u8, path, "/api/v2/beatmaps/"))) return rate_limit.download;
        if (req.head.method == .POST and std.mem.eql(u8, path, "/")) {
            return if (header(req, "osu-token") == null) rate_limit.login else rate_limit.authenticated;
        }
        if (std.mem.eql(u8, path, "/api/v2/me") or std.mem.eql(u8, path, "/web/osu-osz2-getscores.php") or std.mem.eql(u8, path, "/web/osu-getreplay.php") or std.mem.eql(u8, path, "/web/osu-search.php") or std.mem.eql(u8, path, "/web/osu-search-set.php")) return rate_limit.authenticated;
        return null;
    }

    fn bodyLimit(path: []const u8) usize {
        if (std.mem.eql(u8, path, "/users") or std.mem.eql(u8, path, "/oauth/token") or std.mem.eql(u8, path, "/oauth/revoke")) return 8 * 1024;
        if (std.mem.eql(u8, path, "/api/v2/scores")) return 1024 * 1024;
        if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php")) return 20 * 1024 * 1024;
        if (std.mem.eql(u8, path, "/")) return 1024 * 1024;
        return 64 * 1024;
    }

    fn serve(self: *App, req: *std.http.Server.Request) !void {
        const target = try self.allocator.dupe(u8, req.head.target);
        defer self.allocator.free(target);
        const path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
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
        const body: []u8 = if (req.head.method.requestHasBody()) b: {
            const r = req.readerExpectContinue(&.{}) catch return error.BadBody;
            break :b r.allocRemaining(self.allocator, .limited(bodyLimit(path))) catch |err| switch (err) {
                error.StreamTooLong => return respond(req, .payload_too_large, "application/json", "{\"error\":\"request body too large\"}", &.{}),
                else => return err,
            };
        } else &.{};
        defer if (body.len > 0) self.allocator.free(body);

        if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/api/v1/status")) {
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            defer self.sessions.mutex.unlock(self.sessions.io);
            var buf: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"service\":\"zigcho\",\"online\":{d},\"protocol\":19}}", .{self.sessions.items.items.len});
            return respond(req, .ok, "application/json", json, &.{});
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
            const name = field(body, "name") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"name required\"}", &.{});
            const email = field(body, "email") orelse "";
            const password = field(body, "password_md5") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"password_md5 required\"}", &.{});
            if (name.len < 2 or name.len > 32 or password.len != 32) return respond(req, .bad_request, "application/json", "{\"error\":\"invalid fields\"}", &.{});
            const id = self.store.register(name, email, password) catch |err| return respond(req, if (err == error.UserExists) .conflict else .internal_server_error, "application/json", "{\"error\":\"registration failed\"}", &.{});
            var out: [96]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d},\"name\":\"{s}\"}}", .{ id, name });
            return respond(req, .created, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/oauth/token") and req.head.method == .POST) {
            const grant = field(body, "grant_type") orelse "password";
            if (!std.mem.eql(u8, grant, "password")) return respond(req, .bad_request, "application/json", "{\"error\":\"unsupported_grant_type\"}", &.{});
            const name = field(body, "username") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            const password = field(body, "password_md5") orelse field(body, "password") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            const user = (try self.store.authenticate(self.allocator, name, password)) orelse return respond(req, .unauthorized, "application/json", "{\"error\":\"invalid_grant\"}", &.{});
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
            const token = field(body, "token") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            _ = try self.store.revokeToken(token);
            return respond(req, .ok, "application/json", "{}", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/mods")) return respond(req, .ok, "application/json", "{\"mods\":[{\"acronym\":\"RX\",\"name\":\"Relax\",\"description\":\"Server-side cursor relax\",\"ranked\":false,\"score_multiplier\":0.0,\"settings\":{}}],\"custom_mod_contract\":{\"acronym\":\"2-8 uppercase ASCII characters\",\"settings\":\"arbitrary JSON object\",\"leaderboard\":\"custom namespace\",\"ranked\":false}}", &.{});
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
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d},\"username\":\"{s}\",\"country_code\":\"{s}\",\"is_active\":true,\"is_online\":true,\"statistics_rulesets\":{{}}}}", .{ user.id, user.name, user.country });
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
            const ns = lazer.validateScore(parsed.value) catch return respond(req, .unprocessable_entity, "application/json", "{\"error\":\"invalid_score_or_mod\"}", &.{});
            const ns_name = @tagName(ns);
            const id = try self.store.insertLazerScore(user.id, parsed.value, body, ns_name);
            var out: [192]u8 = undefined;
            const json = try std.fmt.bufPrint(&out, "{{\"id\":{d},\"user_id\":{d},\"rank_namespace\":\"{s}\",\"ranked\":false}}", .{ id, user.id, ns_name });
            return respond(req, .created, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/") and req.head.method == .POST) {
            if (osu_token_owned) |token| {
                const session = self.sessions.byToken(token) orelse return respond(req, .unauthorized, "application/octet-stream", "", &.{});
                const bytes = try bancho.poll(self.allocator, &self.sessions, session, body);
                defer self.allocator.free(bytes);
                return respond(req, .ok, "application/octet-stream", bytes, &.{});
            }
            const result = try bancho.login(self.allocator, &self.store, &self.sessions, body);
            defer self.allocator.free(result.body);
            const token_headers = [_]std.http.Header{
                .{ .name = "cho-token", .value = result.token },
                .{ .name = "osu-token", .value = result.token },
            };
            return respond(req, .ok, "application/octet-stream", result.body, &token_headers);
        }
        if (std.mem.eql(u8, path, "/web/bancho_connect.php")) return respond(req, .ok, "text/plain", "ok", &.{});
        if (std.mem.eql(u8, path, "/web/check-updates.php")) return respond(req, .ok, "application/json", "{\"latest\":null}", &.{});
        if (std.mem.eql(u8, path, "/web/osu-getfriends.php") or std.mem.eql(u8, path, "/web/osu-getfavourites.php")) return respond(req, .ok, "text/plain", "", &.{});
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
            const mode_text = queryField(target, "m") orelse "0";
            const board_text = queryField(target, "v") orelse "1";
            const mods_text = queryField(target, "mods") orelse "0";
            const mode = std.fmt.parseInt(u8, mode_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const board_type = std.fmt.parseInt(u8, board_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
            const mods = std.fmt.parseInt(i32, mods_text, 10) catch return respond(req, .bad_request, "text/plain", "", &.{});
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
            const listing = try self.store.stableLeaderboard(self.allocator, user, map_md5, mode, board_type, mods);
            defer self.allocator.free(listing);
            return respond(req, .ok, "text/plain", listing, &.{});
        }
        if (std.mem.eql(u8, path, "/web/osu-submit-modular-selector.php") and req.head.method == .POST) {
            const content_type = content_type_owned orelse return respond(req, .bad_request, "text/plain", "error: no", &.{});
            const boundary = multipart.boundaryFromContentType(content_type) catch return respond(req, .bad_request, "text/plain", "error: no", &.{});
            var form = multipart.parse(self.allocator, body, boundary) catch return respond(req, .bad_request, "text/plain", "error: no", &.{});
            defer form.deinit();
            const encrypted = form.nth("score", 0) orelse return respond(req, .bad_request, "text/plain", "error: no", &.{});
            const replay = form.nth("score", 1) orelse return respond(req, .bad_request, "text/plain", "error: no", &.{});
            if (encrypted.filename != null or replay.filename == null or replay.data.len == 0 or replay.data.len > 16 * 1024 * 1024) return respond(req, .bad_request, "text/plain", "error: no", &.{});
            const iv = (form.first("iv") orelse return respond(req, .bad_request, "text/plain", "error: no", &.{})).data;
            const client_hash_encrypted = (form.first("s") orelse return respond(req, .bad_request, "text/plain", "error: no", &.{})).data;
            const password = (form.first("pass") orelse return respond(req, .unauthorized, "text/plain", "", &.{})).data;
            const osu_version = (form.first("osuver") orelse return respond(req, .bad_request, "text/plain", "error: no", &.{})).data;
            const updated_map_hash = (form.first("bmk") orelse return respond(req, .bad_request, "text/plain", "error: no", &.{})).data;
            const storyboard_hash = if (form.first("sbk")) |part| part.data else "";
            var decrypted = score_crypto.decrypt(self.allocator, encrypted.data, client_hash_encrypted, iv, osu_version) catch return respond(req, .bad_request, "text/plain", "error: no", &.{});
            defer decrypted.deinit();
            const score = stable_score.parse(decrypted.score_data) catch return respond(req, .bad_request, "text/plain", "error: no", &.{});
            if (!std.mem.eql(u8, score.map_md5, updated_map_hash)) return respond(req, .bad_request, "text/plain", "error: beatmap", &.{});
            const user = (try self.store.authenticate(self.allocator, score.username, password)) orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            defer self.allocator.free(user.name);
            defer self.allocator.free(user.safe_name);
            const session_token = score_token_owned orelse osu_token_owned orelse return respond(req, .unauthorized, "text/plain", "", &.{});
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            const active = if (self.sessions.byToken(session_token)) |session| session.user.id == user.id else false;
            self.sessions.mutex.unlock(self.sessions.io);
            if (!active) return respond(req, .unauthorized, "text/plain", "", &.{});
            if (!score.verifyChecksum(osu_version, decrypted.client_hash, storyboard_hash)) return respond(req, .bad_request, "text/plain", "error: no", &.{});
            const beatmap = (try self.store.beatmapForScore(score.map_md5)) orelse return respond(req, .ok, "text/plain", "error: beatmap", &.{});
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
            const score_id = self.store.insertStableScore(user.id, score, performance.pp, replay.data) catch |err| return respond(req, .ok, "text/plain", if (err == error.DuplicateScore) "error: no" else "error: no", &.{});
            if (!score.passed) return respond(req, .ok, "text/plain", "error: no", &.{});
            var result_buf: [1024]u8 = undefined;
            const result = try std.fmt.bufPrint(&result_buf, "beatmapId:{d}|beatmapSetId:{d}|beatmapPlaycount:{d}|beatmapPasscount:{d}|approvedDate:|\n|chartId:beatmap|chartUrl:|chartName:Beatmap Ranking|rankBefore:|rankAfter:|rankedScoreBefore:|rankedScoreAfter:{d}|totalScoreBefore:|totalScoreAfter:{d}|maxComboBefore:|maxComboAfter:{d}|accuracyBefore:|accuracyAfter:{d:.2}|ppBefore:|ppAfter:{d:.2}|onlineScoreId:{d}|\n|chartId:overall|chartUrl:|chartName:Overall Ranking|achievements-new:", .{ beatmap.id, beatmap.set_id, beatmap.plays + 1, beatmap.passes + 1, score.total_score, score.total_score, score.max_combo, score.accuracy() * 100.0, performance.pp, score_id });
            return respond(req, .ok, "text/plain", result, &.{});
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
        if (std.mem.eql(u8, path, "/")) {
            const headers = [_]std.http.Header{
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "content-security-policy", .value = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'" },
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

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const bind = if (args.len > 1) args[1] else "127.0.0.1";
    const port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 8080;
    const db_path: [:0]const u8 = if (args.len > 3) try allocator.dupeZ(u8, args[3]) else "zigcho.db";
    defer if (args.len > 3) allocator.free(db_path);
    var store = try storage.Store.open(allocator, init.io, db_path);
    defer store.close();
    try store.migrate();
    var app: App = .{
        .allocator = allocator,
        .store = store,
        .sessions = sessions_mod.Sessions.init(allocator, init.io),
        .limiter = rate_limit.Limiter.init(allocator, init.io),
    };
    defer app.limiter.deinit();
    defer app.sessions.deinit();
    const address = try std.Io.net.IpAddress.parse(bind, port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var connections: std.Io.Group = .init;
    defer connections.cancel(init.io);
    std.log.info("zigcho listening on http://{s}:{d}", .{ bind, port });
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
