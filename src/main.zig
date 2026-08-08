const std = @import("std");
const storage = @import("storage.zig");
const sessions_mod = @import("sessions.zig");
const bancho = @import("bancho.zig");
const lazer = @import("lazer.zig");
const multipart = @import("multipart.zig");
const score_crypto = @import("score_crypto.zig");
const stable_score = @import("stable_score.zig");

const App = struct {
    allocator: std.mem.Allocator,
    store: storage.Store,
    sessions: sessions_mod.Sessions,

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

    fn serve(self: *App, req: *std.http.Server.Request) !void {
        const target = req.head.target;
        const path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
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
            break :b try r.allocRemaining(self.allocator, .limited(20 * 1024 * 1024));
        } else &.{};
        defer if (body.len > 0) self.allocator.free(body);

        if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/api/v1/status")) {
            self.sessions.mutex.lockUncancelable(self.sessions.io);
            defer self.sessions.mutex.unlock(self.sessions.io);
            var buf: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"service\":\"zigcho\",\"online\":{d},\"protocol\":19}}", .{self.sessions.items.items.len});
            return respond(req, .ok, "application/json", json, &.{});
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
            return respond(req, .ok, "application/json", json, &.{});
        }
        if (std.mem.eql(u8, path, "/oauth/revoke") and req.head.method == .POST) {
            const token = field(body, "token") orelse return respond(req, .bad_request, "application/json", "{\"error\":\"invalid_request\"}", &.{});
            _ = try self.store.revokeToken(token);
            return respond(req, .ok, "application/json", "{}", &.{});
        }
        if (std.mem.eql(u8, path, "/api/v2/mods")) return respond(req, .ok, "application/json", "{\"mods\":[{\"acronym\":\"RX\",\"name\":\"Relax\",\"description\":\"Server-side cursor relax\",\"ranked\":false,\"score_multiplier\":0.0,\"settings\":{}}],\"custom_mod_contract\":{\"acronym\":\"2-8 uppercase ASCII characters\",\"settings\":\"arbitrary JSON object\",\"leaderboard\":\"custom namespace\",\"ranked\":false}}", &.{});
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
        if (std.mem.eql(u8, path, "/web/osu-search.php")) return respond(req, .ok, "text/plain", "0", &.{});
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
            const score_id = self.store.insertStableScore(user.id, score, replay.data) catch |err| return respond(req, .ok, "text/plain", if (err == error.DuplicateScore) "error: no" else "error: no", &.{});
            if (!score.passed) return respond(req, .ok, "text/plain", "error: no", &.{});
            var result_buf: [1024]u8 = undefined;
            const result = try std.fmt.bufPrint(&result_buf, "beatmapId:{d}|beatmapSetId:{d}|beatmapPlaycount:{d}|beatmapPasscount:{d}|approvedDate:|\n|chartId:beatmap|chartUrl:|chartName:Beatmap Ranking|rankBefore:|rankAfter:|rankedScoreBefore:|rankedScoreAfter:{d}|totalScoreBefore:|totalScoreAfter:{d}|maxComboBefore:|maxComboAfter:{d}|accuracyBefore:|accuracyAfter:{d:.2}|ppBefore:|ppAfter:|onlineScoreId:{d}|\n|chartId:overall|chartUrl:|chartName:Overall Ranking|achievements-new:", .{ beatmap.id, beatmap.set_id, beatmap.plays + 1, beatmap.passes + 1, score.total_score, score.total_score, score.max_combo, score.accuracy() * 100.0, score_id });
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
        if (std.mem.eql(u8, path, "/")) return respond(req, .ok, "application/json", "{\"name\":\"zigcho\",\"docs\":\"/README.md\",\"health\":\"/health\"}", &.{});
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
    var app: App = .{ .allocator = allocator, .store = store, .sessions = sessions_mod.Sessions.init(allocator, init.io) };
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
