const d = @import("../deps.zig");
const std = d.std;
const domain = d.domain;
const bss = d.bss;
const proxy = d.proxy;
const routing = d.routing;
const web_auth = d.web_auth;
const server_control_route = d.server_control_route;

const Context = @import("context.zig").Context;
const primitives = @import("primitives.zig");
const support = @import("../support.zig");
const control = @import("../app/control.zig");
const prebody = @import("../routes/prebody.zig");
const platform = @import("../routes/platform.zig");
const website = @import("../routes/website.zig");
const media = @import("../routes/media.zig");
const oauth = @import("../routes/oauth.zig");
const lazer_routes = @import("../routes/lazer.zig");
const stable_routes = @import("../routes/stable.zig");
const fallback = @import("../routes/fallback.zig");

const header = primitives.header;
const respond = primitives.respond;
const respondWithoutContinue = primitives.respondWithoutContinue;
const isBssHost = primitives.isBssHost;
const queryField = primitives.queryField;
const requestRule = control.requestRule;
const bodyLimit = control.bodyLimit;
const featureUnavailable = control.featureUnavailable;
const freeUser = support.freeUser;

pub fn bssPathForRequest(method: std.http.Method, host: ?[]const u8, path: []const u8) ?bss.Path {
    if (method == .GET and web_auth.websiteHost(host) and routing.websitePage(path)) return null;
    return bss.parsePath(path);
}

pub fn serve(self: anytype, req: *std.http.Server.Request, peer_ip: ?[]const u8) !void {
    const target = try self.allocator.dupe(u8, req.head.target);
    defer self.allocator.free(target);
    const raw_path = if (std.mem.findScalar(u8, target, '?')) |q| target[0..q] else target;
    const path = routing.canonicalPath(raw_path);
    const trusted_proxy = proxy.trustsForwardedHeaders(peer_ip);
    const required_features = server_control_route.required(req.head.method, path, header(req, "osu-token") != null);
    for (required_features.slice()) |feature| {
        if (!try self.store.serverControlEnabled(feature)) return featureUnavailable(req, feature);
    }
    if (requestRule(req, path)) |rule| {
        const client = proxy.clientKey(peer_ip, trusted_proxy, header(req, "cf-connecting-ip"), header(req, "x-forwarded-for"), header(req, "x-real-ip"));
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
    const realtime_access_token = if (std.mem.eql(u8, path, "/multiplayer") or std.mem.eql(u8, path, "/multiplayer/negotiate") or std.mem.eql(u8, path, "/spectator") or std.mem.eql(u8, path, "/spectator/negotiate") or std.mem.eql(u8, path, "/notification-endpoint")) queryField(target, "access_token") else null;
    const auth_owned: ?[]u8 = if (header(req, "authorization")) |v|
        try self.allocator.dupe(u8, v)
    else if (realtime_access_token) |token|
        try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token})
    else
        null;
    defer if (auth_owned) |v| self.allocator.free(v);
    const osu_token_owned: ?[]u8 = if (header(req, "osu-token")) |v| try self.allocator.dupe(u8, v) else null;
    defer if (osu_token_owned) |v| self.allocator.free(v);
    const score_token_owned: ?[]u8 = if (header(req, "token")) |v| try self.allocator.dupe(u8, v) else null;
    defer if (score_token_owned) |v| self.allocator.free(v);
    const content_type_owned: ?[]u8 = if (req.head.content_type) |v| try self.allocator.dupe(u8, v) else null;
    defer if (content_type_owned) |v| self.allocator.free(v);
    const country_owned: ?[]u8 = if (proxy.countryHeader(trusted_proxy, header(req, "cf-ipcountry"))) |v| try self.allocator.dupe(u8, v) else null;
    defer if (country_owned) |v| self.allocator.free(v);
    const host_owned: ?[]u8 = if (header(req, "host")) |v| try self.allocator.dupe(u8, v) else null;
    defer if (host_owned) |v| self.allocator.free(v);
    const cookie_owned: ?[]u8 = if (header(req, "cookie")) |v| try self.allocator.dupe(u8, v) else null;
    defer if (cookie_owned) |v| self.allocator.free(v);
    const csrf_owned: ?[]u8 = if (header(req, "x-csrf-token")) |v| try self.allocator.dupe(u8, v) else null;
    defer if (csrf_owned) |v| self.allocator.free(v);
    const origin_owned: ?[]u8 = if (header(req, "origin")) |v| try self.allocator.dupe(u8, v) else null;
    defer if (origin_owned) |v| self.allocator.free(v);
    const client_ip_owned: ?[]u8 = if (proxy.clientIp(peer_ip, trusted_proxy, header(req, "cf-connecting-ip"), header(req, "x-forwarded-for"), header(req, "x-real-ip"))) |v| try self.allocator.dupe(u8, v) else null;
    defer if (client_ip_owned) |v| self.allocator.free(v);
    var ctx: Context = .{
        .target = target,
        .raw_path = raw_path,
        .path = path,
        .trusted_proxy = trusted_proxy,
        .auth_owned = auth_owned,
        .osu_token_owned = osu_token_owned,
        .score_token_owned = score_token_owned,
        .content_type_owned = content_type_owned,
        .country_owned = country_owned,
        .host_owned = host_owned,
        .cookie_owned = cookie_owned,
        .csrf_owned = csrf_owned,
        .origin_owned = origin_owned,
        .client_ip_owned = client_ip_owned,
    };
    if (try prebody.handle(self, req, &ctx) == .handled) return;
    const bss_path = bssPathForRequest(req.head.method, host_owned, path);
    var bss_user: ?domain.User = null;
    defer if (bss_user) |user| freeUser(self.allocator, user);
    if (bss_path) |route| {
        if (!isBssHost(host_owned)) return respondWithoutContinue(req, .not_found, "{\"error\":\"not found\"}");
        const method_allowed = switch (route) {
            .collection => req.head.method == .PUT,
            .set => req.head.method == .PUT or req.head.method == .PATCH,
        };
        if (!method_allowed) return respondWithoutContinue(req, .method_not_allowed, "{\"error\":\"method not allowed\"}");
        const user = (try self.lazerUser(auth_owned, "identify")) orelse return respondWithoutContinue(req, .unauthorized, "{\"error\":\"authentication required\"}");
        if (user.restricted) {
            freeUser(self.allocator, user);
            return respondWithoutContinue(req, .forbidden, "{\"error\":\"account restricted\"}");
        }
        if (user.privileges & bss.premium_privilege == 0) {
            freeUser(self.allocator, user);
            return respondWithoutContinue(req, .forbidden, "{\"error\":\"premium required\"}");
        }
        bss_user = user;
    }

    const body_is_framed = req.head.content_length != null or req.head.transfer_encoding != .none;
    const body: []u8 = if (req.head.method.requestHasBody() and body_is_framed) b: {
        const r = req.readerExpectContinue(&.{}) catch return error.BadBody;
        break :b r.allocRemaining(self.allocator, .limited(bodyLimit(path))) catch |err| switch (err) {
            error.StreamTooLong => return respond(req, .payload_too_large, "application/json", "{\"error\":\"request body too large\"}", &.{}),
            else => return err,
        };
    } else &.{};
    defer if (body.len > 0) self.allocator.free(body);

    ctx.bss_path = bss_path;
    ctx.bss_user = bss_user;
    ctx.body = body;

    // These stages are intentionally kept in the exact order from the old
    // monolithic dispatcher. Route precedence is a client-facing contract.
    if (try platform.handle(self, req, &ctx) == .handled) return;
    if (try website.handle(self, req, &ctx) == .handled) return;
    if (try media.handle(self, req, &ctx) == .handled) return;
    if (try oauth.handle(self, req, &ctx) == .handled) return;
    if (try lazer_routes.handle(self, req, &ctx) == .handled) return;
    if (try stable_routes.handle(self, req, &ctx) == .handled) return;
    _ = try fallback.handle(self, req, &ctx);
}
