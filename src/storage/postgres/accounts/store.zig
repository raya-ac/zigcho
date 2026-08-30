const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const sqlite_storage = @import("../../../storage.zig");
const postgres_stable_sessions = @import("../../../postgres_stable_sessions.zig");
const common = @import("../common.zig");

const CustomAvatar = sqlite_storage.Store.CustomAvatar;
const GameTokenPair = sqlite_storage.Store.GameTokenPair;
const GameTokenRefresh = sqlite_storage.Store.GameTokenRefresh;
const RegistrationConflicts = common.RegistrationConflicts;

fn hasOauthScope(scopes: []const u8, wanted: []const u8) bool {
    var values = std.mem.splitScalar(u8, scopes, ' ');
    while (values.next()) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn hasGameAccessScopes(scopes: []const u8) bool {
    return hasOauthScope(scopes, "identify") and hasOauthScope(scopes, "scores:write");
}

fn randomOauthToken(io: std.Io) ![64]u8 {
    var raw: [32]u8 = undefined;
    try std.Io.randomSecure(io, &raw);
    var token: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&token, "{x}", .{raw}) catch unreachable;
    return token;
}

fn randomOauthClientId(io: std.Io) !i32 {
    var raw: [4]u8 = undefined;
    try std.Io.randomSecure(io, &raw);
    const value = std.mem.readInt(u32, &raw, .little) & std.math.maxInt(i32);
    return @intCast(if (value == 0) 1 else value);
}

const Credential = struct {
    allocator: std.mem.Allocator,
    user: ?domain.User,
    password_hash: []u8,
    password_salt: []u8,

    fn deinit(self: *Credential) void {
        if (self.user) |user| {
            self.allocator.free(user.name);
            self.allocator.free(user.safe_name);
        }
        self.allocator.free(self.password_hash);
        self.allocator.free(self.password_salt);
        self.* = undefined;
    }

    fn takeUser(self: *Credential) domain.User {
        const user = self.user.?;
        self.user = null;
        return user;
    }
};

pub fn register(self: anytype, name: []const u8, email: []const u8, password_md5: []const u8) !i32 {
    const safe = try domain.safeName(self.allocator, name);
    defer self.allocator.free(safe);
    var hash_buffer: [256]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
    const hash_bytea = try postgres.encodeBytea(self.allocator, hash);
    defer self.allocator.free(hash_bytea);
    const salt_bytea = try postgres.encodeBytea(self.allocator, "argon2id");
    defer self.allocator.free(salt_bytea);
    var random_byte: [1]u8 = undefined;
    try std.Io.randomSecure(self.io, &random_byte);
    var avatar_buf: [2]u8 = undefined;
    const avatar = try std.fmt.bufPrint(&avatar_buf, "{d}", .{1 + (random_byte[0] & 1)});

    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var result = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.users(name,safe_name,email,password_hash,password_salt,avatar_key) VALUES($1,$2,$3,$4,$5,$6) RETURNING id", &.{ name, safe, email, hash_bytea, salt_bytea, avatar }) catch |err| switch (err) {
        error.UniqueViolation => return error.UserExists,
        else => return err,
    };
    defer result.deinit();
    const id = try result.int(i32, 0, 0);
    var id_buf: [24]u8 = undefined;
    const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
    var stats_result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.stats(user_id,mode) SELECT $1,mode FROM unnest(ARRAY[0,1,2,3,4,5,6,8]) AS mode", &.{id_text});
    stats_result.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    return id;
}

pub fn registrationConflicts(self: anytype, name: []const u8, email: []const u8) !RegistrationConflicts {
    const safe = try domain.safeName(self.allocator, name);
    defer self.allocator.free(safe);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT EXISTS(SELECT 1 FROM zigcho.users WHERE safe_name=$1),EXISTS(SELECT 1 FROM zigcho.users WHERE email=$2)", &.{ safe, email });
    defer result.deinit();
    return .{ .username = try result.boolean(0, 0), .email = try result.boolean(0, 1) };
}

pub fn avatarForUser(self: anytype, user_id: i32) !?u8 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT avatar_key FROM zigcho.users WHERE id=$1", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    const key = try result.int(u8, 0, 0);
    if (key < 1 or key > 2) return error.InvalidAvatarKey;
    return key;
}

pub fn customAvatarForUser(self: anytype, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT content_type,etag,object_key,updated_at FROM zigcho.user_avatars WHERE user_id=$1", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    const content_type = try allocator.dupe(u8, result.value(0, 0));
    errdefer allocator.free(content_type);
    const etag_value = result.value(0, 1);
    if (etag_value.len != 64) return error.InvalidAvatarEtag;
    var etag: [64]u8 = undefined;
    @memcpy(&etag, etag_value);
    const object_key = try allocator.dupe(u8, result.value(0, 2));
    return .{ .allocator = allocator, .content_type = content_type, .etag = etag, .object_key = object_key, .updated_at = try result.int(i64, 0, 3) };
}

pub fn setCustomAvatar(self: anytype, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8) !void {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.user_avatars(user_id,object_key,content_type,etag) VALUES($1,$2,$3,$4) ON CONFLICT(user_id) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,zigcho.user_avatars.updated_at+1)", &.{ id, object_key, content_type, &etag });
    result.deinit();
}

pub fn deleteCustomAvatar(self: anytype, user_id: i32) !bool {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.user_avatars WHERE user_id=$1 RETURNING user_id", &.{id});
    defer result.deinit();
    return result.rows() != 0;
}

pub fn customImageFromResult(allocator: std.mem.Allocator, result: postgres.Result) !CustomAvatar {
    const content_type = try allocator.dupe(u8, result.value(0, 0));
    errdefer allocator.free(content_type);
    const etag_value = result.value(0, 1);
    if (etag_value.len != 64) return error.InvalidAvatarEtag;
    var etag: [64]u8 = undefined;
    @memcpy(&etag, etag_value);
    const object_key = try allocator.dupe(u8, result.value(0, 2));
    return .{
        .allocator = allocator,
        .content_type = content_type,
        .etag = etag,
        .object_key = object_key,
        .updated_at = try result.int(i64, 0, 3),
        .width = try result.int(u32, 0, 4),
        .height = try result.int(u32, 0, 5),
    };
}

pub fn customBannerForUser(self: anytype, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT content_type,etag,object_key,updated_at,width,height FROM zigcho.user_banners WHERE user_id=$1", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try customImageFromResult(allocator, result);
}

pub fn setCustomBanner(self: anytype, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8, width: u32, height: u32) !void {
    var buffers: [3][64]u8 = undefined;
    var cursor: usize = 0;
    const id = try common.param(&buffers, &cursor, user_id);
    const width_text = try common.param(&buffers, &cursor, width);
    const height_text = try common.param(&buffers, &cursor, height);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.user_banners(user_id,object_key,content_type,etag,width,height) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(user_id) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,width=excluded.width,height=excluded.height,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,zigcho.user_banners.updated_at+1)", &.{ id, object_key, content_type, &etag, width_text, height_text });
    result.deinit();
}

pub fn deleteCustomBanner(self: anytype, user_id: i32) !bool {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.user_banners WHERE user_id=$1 RETURNING user_id", &.{id});
    defer result.deinit();
    return result.rows() != 0;
}

pub fn teamAsset(self: anytype, allocator: std.mem.Allocator, team_id: i32, kind: []const u8) !?CustomAvatar {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{team_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT content_type,etag,object_key,updated_at,width,height FROM zigcho.team_assets WHERE team_id=$1 AND kind=$2", &.{ id, kind });
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try customImageFromResult(allocator, result);
}

pub fn setTeamAsset(self: anytype, team_id: i32, kind: []const u8, object_key: []const u8, content_type: []const u8, etag: [64]u8, width: u32, height: u32) !void {
    var buffers: [3][64]u8 = undefined;
    var cursor: usize = 0;
    const id = try common.param(&buffers, &cursor, team_id);
    const width_text = try common.param(&buffers, &cursor, width);
    const height_text = try common.param(&buffers, &cursor, height);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.team_assets(team_id,kind,object_key,content_type,etag,width,height) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(team_id,kind) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,width=excluded.width,height=excluded.height,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,zigcho.team_assets.updated_at+1)", &.{ id, kind, object_key, content_type, &etag, width_text, height_text });
    result.deinit();
}

pub fn deleteTeamAsset(self: anytype, team_id: i32, kind: []const u8) !bool {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{team_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_assets WHERE team_id=$1 AND kind=$2 RETURNING team_id", &.{ id, kind });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn customAvatarUserIds(self: anytype, allocator: std.mem.Allocator) ![]i32 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT user_id FROM zigcho.user_avatars ORDER BY user_id");
    defer result.deinit();
    var ids: std.ArrayList(i32) = .empty;
    errdefer ids.deinit(allocator);
    try ids.ensureTotalCapacity(allocator, result.rows());
    for (0..result.rows()) |row| ids.appendAssumeCapacity(try result.int(i32, row, 0));
    return ids.toOwnedSlice(allocator);
}

pub fn updateSiteProfile(self: anytype, user_id: i32, settings: domain.SiteProfileSettings) !void {
    var id_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    var avatar_buf: [4]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{settings.preferred_mode});
    const avatar = try std.fmt.bufPrint(&avatar_buf, "{d}", .{settings.avatar_key});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET bio=$1,profile_title=$2,profile_pronouns=$3,profile_location=$4,profile_website=$5,profile_accent=$6,preferred_mode=$7,profile_source=$8,avatar_key=$9,show_country=$10,show_profile_stats=$11,show_recent_scores=$12 WHERE id=$13 AND id!=3 RETURNING id", &.{ settings.bio, settings.title, settings.pronouns, settings.location, settings.website, @tagName(settings.accent), mode, @tagName(settings.profile_source), avatar, if (settings.show_country) "true" else "false", if (settings.show_profile_stats) "true" else "false", if (settings.show_recent_scores) "true" else "false", id });
    defer result.deinit();
    if (result.rows() != 1) return error.UserNotFound;
}

pub fn lazerProfileSummary(self: anytype, user_id: i32) !?domain.ProfileSummary {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql =
        "SELECT u.created_at,coalesce(u.last_login,0),coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.preferred_mode,u.profile_title,u.profile_location,u.profile_website,u.show_country,u.show_profile_stats,u.show_recent_scores," ++
        "(SELECT count(*) FROM zigcho.favourites f WHERE f.user_id=u.id)," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status) IN(3,4)) sets)," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=6) sets)," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=2) sets)," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=1) sets)," ++
        "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=5) sets)," ++
        "(SELECT count(*) FROM (SELECT b.id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=u.id UNION SELECT s.beatmap_id FROM zigcho.lazer_scores s WHERE s.user_id=u.id) played)," ++
        common.visible_follower_count_sql ++ " " ++
        "FROM zigcho.users u WHERE u.id=$1";
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    var summary = try domain.ProfileSummary.init(
        try result.int(i64, 0, 0),
        try result.int(i64, 0, 1),
        try result.int(i64, 0, 2),
        try result.int(u8, 0, 3),
        result.value(0, 4),
        result.value(0, 5),
        result.value(0, 6),
    );
    summary.show_country = try result.boolean(0, 7);
    summary.show_profile_stats = try result.boolean(0, 8);
    summary.show_recent_scores = try result.boolean(0, 9);
    summary.favourite_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 10)));
    summary.ranked_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 11)));
    summary.loved_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 12)));
    summary.pending_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 13)));
    summary.graveyard_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 14)));
    summary.nominated_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 15)));
    summary.played_beatmap_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 16)));
    summary.follower_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 17)));
    return summary;
}

pub fn lazerBatchUserVisibility(self: anytype, user_id: i32) !?domain.BatchUserVisibility {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = "SELECT coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.show_country,u.show_profile_stats," ++ common.visible_follower_count_sql ++ " FROM zigcho.users u WHERE u.id=$1";
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{
        .avatar_version = try result.int(i64, 0, 0),
        .show_country = try result.boolean(0, 1),
        .show_profile_stats = try result.boolean(0, 2),
        .follower_count = try result.int(i32, 0, 3),
    };
}

pub fn lazerMonthlyPlaycountsJson(self: anytype, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const sql =
        "WITH plays AS (SELECT submitted_at FROM zigcho.scores WHERE user_id=$1 UNION ALL SELECT submitted_at FROM zigcho.lazer_scores WHERE user_id=$1) " ++
        "SELECT to_char(date_trunc('month',to_timestamp(submitted_at) AT TIME ZONE 'UTC'),'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),count(*) FROM plays GROUP BY date_trunc('month',to_timestamp(submitted_at) AT TIME ZONE 'UTC') ORDER BY 1";
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{id});
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"start_date\":");
        try common.jsonString(&output.writer, result.value(row, 0));
        try output.writer.print(",\"count\":{d}}}", .{try result.int(i64, row, 1)});
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerReplaysWatchedCountsJson(self: anytype, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8) ![]u8 {
    if (ruleset_id > 3) return error.InvalidRulesetId;
    var buffers: [2][24]u8 = undefined;
    const id = try std.fmt.bufPrint(&buffers[0], "{d}", .{user_id});
    const mode = try std.fmt.bufPrint(&buffers[1], "{d}", .{ruleset_id});
    const sql =
        "SELECT to_char(date_trunc('month',to_timestamp(viewed_at) AT TIME ZONE 'UTC'),'YYYY-MM-DD'),count(*) FROM zigcho.score_replay_views " ++
        "WHERE owner_id=$1 AND mode=$2 AND rank_namespace='vanilla' " ++
        "GROUP BY date_trunc('month',to_timestamp(viewed_at) AT TIME ZONE 'UTC') ORDER BY 1";
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ id, mode });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"start_date\":");
        try common.jsonString(&output.writer, result.value(row, 0));
        try output.writer.print(",\"count\":{d}}}", .{try result.int(i64, row, 1)});
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn siteAccountJson(self: anytype, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,u.email,u.country,u.privileges,u.bio,u.preferred_mode,u.profile_source,u.avatar_key,EXISTS(SELECT 1 FROM zigcho.user_avatars a WHERE a.user_id=u.id),coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),0),u.created_at,coalesce(u.last_login,0),u.profile_title,u.profile_pronouns,u.profile_location,u.profile_website,u.profile_accent,u.show_country,u.show_profile_stats,u.show_recent_scores,u.username_changes,EXISTS(SELECT 1 FROM zigcho.user_banners b WHERE b.user_id=u.id),coalesce((SELECT updated_at FROM zigcho.user_banners b WHERE b.user_id=u.id),0),tm.team_id,t.name,t.short_name,(t.leader_id=u.id) FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1 AND u.id!=3", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{try result.int(i32, 0, 0)});
    try common.jsonString(&output.writer, result.value(0, 1));
    try output.writer.writeAll(",\"email\":");
    if (result.isNull(0, 2)) try output.writer.writeAll("null") else try common.jsonString(&output.writer, result.value(0, 2));
    try output.writer.writeAll(",\"country\":");
    try common.jsonString(&output.writer, result.value(0, 3));
    try output.writer.print(",\"privileges\":{d},\"bio\":", .{try result.int(u32, 0, 4)});
    try common.jsonString(&output.writer, result.value(0, 5));
    try output.writer.writeAll(",\"profile_source\":");
    try common.jsonString(&output.writer, result.value(0, 7));
    try output.writer.print(",\"preferred_mode\":{d},\"avatar_key\":{d},\"has_custom_avatar\":{},\"avatar_version\":{d},\"created_at\":{d},\"last_login\":{d},\"profile_title\":", .{ try result.int(u8, 0, 6), try result.int(u8, 0, 8), try result.boolean(0, 9), try result.int(i64, 0, 10), try result.int(i64, 0, 11), try result.int(i64, 0, 12) });
    try common.jsonString(&output.writer, result.value(0, 13));
    try output.writer.writeAll(",\"profile_pronouns\":");
    try common.jsonString(&output.writer, result.value(0, 14));
    try output.writer.writeAll(",\"profile_location\":");
    try common.jsonString(&output.writer, result.value(0, 15));
    try output.writer.writeAll(",\"profile_website\":");
    try common.jsonString(&output.writer, result.value(0, 16));
    try output.writer.writeAll(",\"profile_accent\":");
    try common.jsonString(&output.writer, result.value(0, 17));
    const changes = try result.int(i32, 0, 21);
    const privileges = try result.int(u32, 0, 4);
    try output.writer.print(",\"show_country\":{},\"show_profile_stats\":{},\"show_recent_scores\":{},\"username_changes\":{d},\"username_change_free\":{},\"username_change_allowed\":{},\"has_custom_banner\":{},\"banner_version\":{d},\"team\":", .{ try result.boolean(0, 18), try result.boolean(0, 19), try result.boolean(0, 20), changes, changes == 0, changes == 0 or (privileges & (1 << 5)) != 0, try result.boolean(0, 22), try result.int(i64, 0, 23) });
    if (result.isNull(0, 24)) {
        try output.writer.writeAll("null");
    } else {
        try output.writer.print("{{\"id\":{d},\"name\":", .{try result.int(i32, 0, 24)});
        try common.jsonString(&output.writer, result.value(0, 25));
        try output.writer.writeAll(",\"short_name\":");
        try common.jsonString(&output.writer, result.value(0, 26));
        try output.writer.print(",\"leader\":{}}}", .{try result.boolean(0, 27)});
    }
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return @as(?[]u8, try list.toOwnedSlice(allocator));
}

pub fn updateAccountEmail(self: anytype, user_id: i32, email: []const u8) !void {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var result = postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET email=$1 WHERE id=$2 AND id!=3 RETURNING id", &.{ email, id }) catch |err| switch (err) {
        error.UniqueViolation => return error.EmailExists,
        else => return err,
    };
    defer result.deinit();
    if (result.rows() != 1) return error.UserNotFound;
    try common.insertAudit(self.allocator, lease.conn, user_id, "account.email", user_id, "email changed");
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn updateAccountPassword(self: anytype, user_id: i32, password_md5: []const u8) !void {
    var hash_buffer: [256]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
    const hash_bytea = try postgres.encodeBytea(self.allocator, hash);
    defer self.allocator.free(hash_bytea);
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var token_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
    token_lock.deinit();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET password_hash=$1,password_salt=convert_to('argon2id','UTF8') WHERE id=$2 AND id!=3 RETURNING id", &.{ hash_bytea, id });
    defer result.deinit();
    if (result.rows() != 1) return error.UserNotFound;
    try common.insertAudit(self.allocator, lease.conn, user_id, "account.password", user_id, "password changed");
    var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL", &.{id});
    revoke.deinit();
    var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
    clear.deinit();
    _ = try postgres_stable_sessions.revokeWithConnection(self.allocator, lease.conn, user_id, std.Io.Clock.real.now(self.io).toSeconds());
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn updateAccountUsername(self: anytype, user_id: i32, new_name: []const u8) !void {
    const safe = try domain.safeName(self.allocator, new_name);
    defer self.allocator.free(safe);
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var token_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
    token_lock.deinit();
    var current = try postgres.queryParams(self.allocator, lease.conn, "SELECT name,username_changes,privileges FROM zigcho.users WHERE id=$1 AND id!=3 FOR UPDATE", &.{id});
    defer current.deinit();
    if (current.rows() != 1) return error.UserNotFound;
    if (try current.int(i32, 0, 1) != 0 and (try current.int(u32, 0, 2)) & (1 << 5) == 0) return error.PremiumRequired;
    var update = postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET name=$1,safe_name=$2,username_changes=username_changes+1,username_changed_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$3 RETURNING id", &.{ new_name, safe, id }) catch |err| switch (err) {
        error.UniqueViolation => return error.UsernameExists,
        else => return err,
    };
    defer update.deinit();
    var history = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.user_name_changes(user_id,old_name,new_name) VALUES($1,$2,$3)", &.{ id, current.value(0, 0), new_name });
    history.deinit();
    try common.insertAudit(self.allocator, lease.conn, user_id, "account.username", user_id, "username changed");
    var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL", &.{id});
    revoke.deinit();
    var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
    clear.deinit();
    _ = try postgres_stable_sessions.revokeWithConnection(self.allocator, lease.conn, user_id, std.Io.Clock.real.now(self.io).toSeconds());
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn revokeAllTokensForUser(self: anytype, user_id: i32) !usize {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var token_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
    token_lock.deinit();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL RETURNING 1", &.{id});
    const revoked = result.rows();
    result.deinit();
    var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
    clear.deinit();
    const stable_revoked = try postgres_stable_sessions.revokeWithConnection(self.allocator, lease.conn, user_id, std.Io.Clock.real.now(self.io).toSeconds());
    try postgres.exec(lease.conn, "COMMIT");
    return revoked + stable_revoked;
}

pub fn credentialForSafeName(self: anytype, allocator: std.mem.Allocator, safe: []const u8) !?Credential {
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ common.visible_follower_count_sql ++ ",u.password_hash,u.password_salt FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.safe_name=$1";
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{safe});
    defer result.deinit();
    if (result.rows() == 0) return null;
    const user = try common.userFromResult(allocator, result, 0);
    errdefer {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    }
    const password_hash = try postgres.decodeBytea(allocator, result.value(0, 14));
    errdefer allocator.free(password_hash);
    const password_salt = try postgres.decodeBytea(allocator, result.value(0, 15));
    return .{ .allocator = allocator, .user = user, .password_hash = password_hash, .password_salt = password_salt };
}

pub fn authenticate(self: anytype, allocator: std.mem.Allocator, name: []const u8, password_md5: []const u8) !?domain.User {
    const safe = try domain.safeName(allocator, name);
    defer allocator.free(safe);
    var credential = (try credentialForSafeName(self, allocator, safe)) orelse return null;
    defer credential.deinit();
    var upgrade = false;
    if (credential.password_hash.len > 0 and credential.password_hash[0] == '$') {
        std.crypto.pwhash.argon2.strVerify(credential.password_hash, password_md5, .{ .allocator = allocator }, self.io) catch return null;
    } else {
        var actual: [32]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(credential.password_salt);
        hash.update(password_md5);
        hash.final(&actual);
        if (credential.password_hash.len != 32 or !std.crypto.timing_safe.eql([32]u8, actual, credential.password_hash[0..32].*)) return null;
        upgrade = true;
    }
    const user_id = credential.user.?.id;
    if (upgrade) try upgradePassword(self, user_id, password_md5, credential.password_hash);
    return credential.takeUser();
}

pub fn upgradePassword(self: anytype, user_id: i32, password_md5: []const u8, previous_hash: []const u8) !void {
    var hash_buffer: [256]u8 = undefined;
    const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
    const hash_bytea = try postgres.encodeBytea(self.allocator, hash);
    defer self.allocator.free(hash_bytea);
    const salt_bytea = try postgres.encodeBytea(self.allocator, "argon2id");
    defer self.allocator.free(salt_bytea);
    const previous_bytea = try postgres.encodeBytea(self.allocator, previous_hash);
    defer self.allocator.free(previous_bytea);
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET password_hash=$1,password_salt=$2 WHERE id=$3 AND password_hash=$4", &.{ hash_bytea, salt_bytea, id, previous_bytea });
    result.deinit();
}

pub fn userById(self: anytype, allocator: std.mem.Allocator, user_id: i32) !?domain.User {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ common.visible_follower_count_sql ++ " FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1";
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try common.userFromResult(allocator, result, 0);
}

pub fn userByName(self: anytype, allocator: std.mem.Allocator, name: []const u8) !?domain.User {
    const safe = try domain.safeName(allocator, name);
    defer allocator.free(safe);
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ common.visible_follower_count_sql ++ " FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.safe_name=$1";
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{safe});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try common.userFromResult(allocator, result, 0);
}

pub fn siteNameHistoryJson(self: anytype, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql =
        "SELECT u.id,u.name,h.old_name,h.changed_at FROM zigcho.users u " ++
        "LEFT JOIN LATERAL (SELECT old_name,changed_at,id FROM zigcho.user_name_changes WHERE user_id=u.id ORDER BY changed_at DESC,id DESC LIMIT 20) h ON true " ++
        "WHERE u.id=$1 AND u.id!=3 AND NOT u.restricted ORDER BY h.changed_at DESC,h.id DESC";
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{try result.int(i32, 0, 0)});
    try common.jsonString(&output.writer, result.value(0, 1));
    try output.writer.writeAll(",\"history\":[");
    var first = true;
    for (0..result.rows()) |row| {
        if (result.isNull(row, 2)) continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.writeAll("{\"name\":");
        try common.jsonString(&output.writer, result.value(row, 2));
        try output.writer.print(",\"changed_at\":{d}}}", .{try result.int(i64, row, 3)});
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return @as(?[]u8, try list.toOwnedSlice(allocator));
}

pub fn updateCountry(self: anytype, user_id: i32, value: [2]u8) !void {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET country=$1,last_login=extract(epoch FROM clock_timestamp())::bigint WHERE id=$2", &.{ value[0..], id });
    result.deinit();
}

pub fn issueToken(self: anytype, user_id: i32, scopes: []const u8, lifetime_seconds: i64) ![64]u8 {
    var raw: [32]u8 = undefined;
    try std.Io.randomSecure(self.io, &raw);
    var token: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&token, "{x}", .{raw}) catch unreachable;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token, &digest, .{});
    const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
    defer self.allocator.free(digest_bytea);
    var id_buf: [24]u8 = undefined;
    var expiry_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    const expiry = try std.fmt.bufPrint(&expiry_buf, "{d}", .{now_seconds + lifetime_seconds});
    var used_buf: [32]u8 = undefined;
    const used = try std.fmt.bufPrint(&used_buf, "{d}", .{now_seconds});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = if (std.mem.indexOf(u8, scopes, "scores:write") != null)
        try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,expires_at,last_used_at) VALUES($1,$2,$3,$4,$5)", &.{ digest_bytea, id, scopes, expiry, used })
    else
        try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,expires_at) VALUES($1,$2,$3,$4)", &.{ digest_bytea, id, scopes, expiry });
    result.deinit();
    return token;
}

pub fn issueGameTokenPair(self: anytype, user_id: i32, access_lifetime_seconds: i64, refresh_lifetime_seconds: i64, replace_existing: bool) !GameTokenPair {
    if (user_id <= 0 or access_lifetime_seconds <= 0 or refresh_lifetime_seconds <= 0) return error.InvalidOauthTokenPair;
    const access = try randomOauthToken(self.io);
    const refresh = try randomOauthToken(self.io);
    const client_id = try randomOauthClientId(self.io);
    var access_digest: [32]u8 = undefined;
    var refresh_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&access, &access_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(&refresh, &refresh_digest, .{});
    const access_bytea = try postgres.encodeBytea(self.allocator, &access_digest);
    defer self.allocator.free(access_bytea);
    const refresh_bytea = try postgres.encodeBytea(self.allocator, &refresh_digest);
    defer self.allocator.free(refresh_bytea);
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    var user_buf: [24]u8 = undefined;
    var client_buf: [24]u8 = undefined;
    var now_buf: [32]u8 = undefined;
    var access_expiry_buf: [32]u8 = undefined;
    var refresh_expiry_buf: [32]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const client = try std.fmt.bufPrint(&client_buf, "{d}", .{client_id});
    const now = try std.fmt.bufPrint(&now_buf, "{d}", .{now_seconds});
    const access_expiry = try std.fmt.bufPrint(&access_expiry_buf, "{d}", .{now_seconds + access_lifetime_seconds});
    const refresh_expiry = try std.fmt.bufPrint(&refresh_expiry_buf, "{d}", .{now_seconds + refresh_lifetime_seconds});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{user});
    lock.deinit();
    if (replace_existing) {
        var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)')", &.{user});
        revoke.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{user});
        clear.deinit();
    }
    var access_insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,client_id,expires_at,last_used_at) VALUES($1,$2,'identify scores:write',$3,$4,$5)", &.{ access_bytea, user, client, access_expiry, now });
    access_insert.deinit();
    var refresh_insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,client_id,expires_at) VALUES($1,$2,'game:refresh',$3,$4)", &.{ refresh_bytea, user, client, refresh_expiry });
    refresh_insert.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    return .{ .access = access, .refresh = refresh };
}

pub fn rotateGameTokenPair(self: anytype, allocator: std.mem.Allocator, refresh_token: []const u8, access_lifetime_seconds: i64, refresh_lifetime_seconds: i64) !?GameTokenRefresh {
    if (refresh_token.len != 64 or access_lifetime_seconds <= 0 or refresh_lifetime_seconds <= 0) return null;
    var old_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(refresh_token, &old_digest, .{});
    const old_bytea = try postgres.encodeBytea(self.allocator, &old_digest);
    defer self.allocator.free(old_bytea);
    const access = try randomOauthToken(self.io);
    const refresh = try randomOauthToken(self.io);
    const new_client_id = try randomOauthClientId(self.io);
    var access_digest: [32]u8 = undefined;
    var refresh_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&access, &access_digest, .{});
    std.crypto.hash.sha2.Sha256.hash(&refresh, &refresh_digest, .{});
    const access_bytea = try postgres.encodeBytea(self.allocator, &access_digest);
    defer self.allocator.free(access_bytea);
    const refresh_bytea = try postgres.encodeBytea(self.allocator, &refresh_digest);
    defer self.allocator.free(refresh_bytea);
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    const rotated_user_id: i32 = rotate: {
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var current = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id,client_id FROM zigcho.oauth_tokens WHERE token_hash=$1 AND scopes='game:refresh' AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint", &.{old_bytea});
        if (current.rows() == 0) {
            current.deinit();
            try postgres.exec(lease.conn, "ROLLBACK");
            return null;
        }
        const user_id = try current.int(i32, 0, 0);
        const legacy = current.isNull(0, 1);
        const old_client_id = if (legacy) @as(i32, 0) else try current.int(i32, 0, 1);
        current.deinit();
        var user_buf: [24]u8 = undefined;
        var old_client_buf: [24]u8 = undefined;
        var new_client_buf: [24]u8 = undefined;
        var now_buf: [32]u8 = undefined;
        var access_expiry_buf: [32]u8 = undefined;
        var refresh_expiry_buf: [32]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const old_client = try std.fmt.bufPrint(&old_client_buf, "{d}", .{old_client_id});
        const new_client = try std.fmt.bufPrint(&new_client_buf, "{d}", .{new_client_id});
        const now = try std.fmt.bufPrint(&now_buf, "{d}", .{now_seconds});
        const access_expiry = try std.fmt.bufPrint(&access_expiry_buf, "{d}", .{now_seconds + access_lifetime_seconds});
        const refresh_expiry = try std.fmt.bufPrint(&refresh_expiry_buf, "{d}", .{now_seconds + refresh_lifetime_seconds});
        var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{user_text});
        lock.deinit();
        var consume = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND scopes='game:refresh' AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint RETURNING 1", &.{old_bytea});
        const consumed = consume.rows() != 0;
        consume.deinit();
        if (!consumed) {
            try postgres.exec(lease.conn, "ROLLBACK");
            return null;
        }
        var revoke = if (legacy)
            try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND client_id IS NULL AND revoked_at IS NULL AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)'", &.{user_text})
        else
            try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND client_id=$2 AND revoked_at IS NULL AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)'", &.{ user_text, old_client });
        revoke.deinit();
        var access_insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,client_id,expires_at,last_used_at) VALUES($1,$2,'identify scores:write',$3,$4,$5)", &.{ access_bytea, user_text, new_client, access_expiry, now });
        access_insert.deinit();
        var refresh_insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,client_id,expires_at) VALUES($1,$2,'game:refresh',$3,$4)", &.{ refresh_bytea, user_text, new_client, refresh_expiry });
        refresh_insert.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        break :rotate user_id;
    };
    const user = (try self.userById(allocator, rotated_user_id)) orelse return error.UserNotFound;
    return .{ .user = user, .tokens = .{ .access = access, .refresh = refresh } };
}

pub fn authenticateToken(self: anytype, allocator: std.mem.Allocator, token: []const u8, required_scope: []const u8) !?domain.User {
    if (token.len != 64) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
    defer self.allocator.free(digest_bytea);
    var now_buf: [32]u8 = undefined;
    const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
    const now = try std.fmt.bufPrint(&now_buf, "{d}", .{now_seconds});
    var lease = self.pool.acquire();
    defer lease.release();
    const user = result: {
        const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,team.name,team.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=team.id AND ta.kind='flag'),0),u.show_country," ++ common.visible_follower_count_sql ++ ",t.scopes FROM zigcho.oauth_tokens t JOIN zigcho.users u ON u.id=t.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams team ON team.id=tm.team_id WHERE t.token_hash=$1 AND t.revoked_at IS NULL AND t.expires_at>$2";
        var query_result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ digest_bytea, now });
        defer query_result.deinit();
        if (query_result.rows() == 0) return null;
        var allowed = required_scope.len == 0;
        var scopes = std.mem.splitScalar(u8, query_result.value(0, 14), ' ');
        while (scopes.next()) |scope| if (std.mem.eql(u8, scope, required_scope) or std.mem.eql(u8, scope, "*")) {
            allowed = true;
            break;
        };
        if (!allowed) return null;
        break :result try common.userFromResult(allocator, query_result, 0);
    };
    errdefer {
        allocator.free(user.name);
        allocator.free(user.safe_name);
    }
    var stale_buf: [32]u8 = undefined;
    const stale = try std.fmt.bufPrint(&stale_buf, "{d}", .{now_seconds - 30});
    var touch = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET last_used_at=$1 WHERE token_hash=$2 AND (last_used_at IS NULL OR last_used_at<$3)", &.{ now, digest_bytea, stale });
    touch.deinit();
    return user;
}

pub fn consumeGameRefreshToken(self: anytype, allocator: std.mem.Allocator, token: []const u8) !?domain.User {
    if (token.len != 64) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
    defer self.allocator.free(digest_bytea);
    const user_id: i32 = consume: {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND scopes='game:refresh' AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint RETURNING user_id", &.{digest_bytea});
        defer result.deinit();
        if (result.rows() == 0) return null;
        break :consume try result.int(i32, 0, 0);
    };
    return self.userById(allocator, user_id);
}

pub fn recentOauthUserIds(self: anytype, allocator: std.mem.Allocator, cutoff: i64) ![]i32 {
    var cutoff_buf: [32]u8 = undefined;
    const cutoff_value = try std.fmt.bufPrint(&cutoff_buf, "{d}", .{cutoff});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT DISTINCT t.user_id FROM zigcho.oauth_tokens t JOIN zigcho.users u ON u.id=t.user_id WHERE t.last_used_at>=$1 AND t.revoked_at IS NULL AND t.expires_at>extract(epoch FROM clock_timestamp())::bigint AND t.scopes ~ '(^| )identify( |$)' AND t.scopes ~ '(^| )scores:write( |$)' AND u.restricted=false ORDER BY t.user_id", &.{cutoff_value});
    defer result.deinit();
    var ids: std.ArrayList(i32) = .empty;
    errdefer ids.deinit(allocator);
    try ids.ensureTotalCapacity(allocator, result.rows());
    for (0..result.rows()) |row| ids.appendAssumeCapacity(try result.int(i32, row, 0));
    return ids.toOwnedSlice(allocator);
}

pub fn lazerUserOnline(self: anytype, user_id: i32, cutoff: i64) !bool {
    var id_buf: [24]u8 = undefined;
    var cutoff_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const cutoff_value = try std.fmt.bufPrint(&cutoff_buf, "{d}", .{cutoff});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.oauth_tokens WHERE user_id=$1 AND last_used_at>=$2 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)' LIMIT 1", &.{ id, cutoff_value });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn setLazerActivityForToken(self: anytype, token: []const u8, expected_user_id: i32, status: []const u8, detail: []const u8, beatmap_id: ?i32, ruleset_id: ?u8) !bool {
    if (token.len != 64 or expected_user_id <= 0) return false;
    if (!domain.validLazerActivity(status, detail, beatmap_id, ruleset_id)) return error.InvalidLazerActivity;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
    defer self.allocator.free(digest_bytea);
    var id_buf: [24]u8 = undefined;
    var beatmap_buf: [24]u8 = undefined;
    var ruleset_buf: [8]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{expected_user_id});
    const beatmap_value: ?[]const u8 = if (beatmap_id) |value| try std.fmt.bufPrint(&beatmap_buf, "{d}", .{value}) else null;
    const ruleset_value: ?[]const u8 = if (ruleset_id) |value| try std.fmt.bufPrint(&ruleset_buf, "{d}", .{value}) else null;
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var owner = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.oauth_tokens WHERE token_hash=$1 AND user_id=$2 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)' FOR UPDATE", &.{ digest_bytea, id });
    if (owner.rows() == 0) {
        owner.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return false;
    }
    owner.deinit();
    var activity = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_presence(user_id,status,detail,beatmap_id,ruleset_id,updated_at) VALUES($1,$2,$3,$4,$5,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(user_id) DO UPDATE SET status=excluded.status,detail=excluded.detail,beatmap_id=excluded.beatmap_id,ruleset_id=excluded.ruleset_id,updated_at=excluded.updated_at", &.{ id, status, detail, beatmap_value, ruleset_value });
    activity.deinit();
    var touch = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET last_used_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND user_id=$2 AND revoked_at IS NULL RETURNING 1", &.{ digest_bytea, id });
    defer touch.deinit();
    if (touch.rows() != 1) return error.DatabaseQueryFailed;
    try postgres.exec(lease.conn, "COMMIT");
    return true;
}

pub fn clearLazerActivityForToken(self: anytype, token: []const u8, expected_user_id: i32) !bool {
    if (token.len != 64 or expected_user_id <= 0) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
    defer self.allocator.free(digest_bytea);
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{expected_user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var owner = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.oauth_tokens WHERE token_hash=$1 AND user_id=$2 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)' FOR UPDATE", &.{ digest_bytea, id });
    if (owner.rows() == 0) {
        owner.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return false;
    }
    owner.deinit();
    var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
    clear.deinit();
    var touch = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET last_used_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND user_id=$2 AND revoked_at IS NULL RETURNING 1", &.{ digest_bytea, id });
    defer touch.deinit();
    if (touch.rows() != 1) return error.DatabaseQueryFailed;
    try postgres.exec(lease.conn, "COMMIT");
    return true;
}

pub fn lazerActivity(self: anytype, allocator: std.mem.Allocator, user_id: i32, cutoff: i64) !?domain.LazerActivity {
    var id_buf: [24]u8 = undefined;
    var cutoff_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const cutoff_value = try std.fmt.bufPrint(&cutoff_buf, "{d}", .{cutoff});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT status,detail,beatmap_id,ruleset_id FROM zigcho.lazer_presence WHERE user_id=$1 AND updated_at>=$2", &.{ id, cutoff_value });
    defer result.deinit();
    if (result.rows() == 0) return null;
    const status = try allocator.dupe(u8, result.value(0, 0));
    errdefer allocator.free(status);
    const detail = try allocator.dupe(u8, result.value(0, 1));
    return .{
        .allocator = allocator,
        .status = status,
        .detail = detail,
        .beatmap_id = if (result.isNull(0, 2)) null else try result.int(i32, 0, 2),
        .ruleset_id = if (result.isNull(0, 3)) null else try result.int(u8, 0, 3),
    };
}

pub fn revokeToken(self: anytype, token: []const u8) !bool {
    if (token.len != 64) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
    defer self.allocator.free(digest_bytea);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var current = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id,scopes FROM zigcho.oauth_tokens WHERE token_hash=$1 AND revoked_at IS NULL", &.{digest_bytea});
    if (current.rows() == 0) {
        current.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return false;
    }
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{try current.int(i32, 0, 0)});
    const game_lookup = hasGameAccessScopes(current.value(0, 1)) or hasOauthScope(current.value(0, 1), "game:refresh");
    current.deinit();
    if (game_lookup) {
        var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
        lock.deinit();
    }
    var locked = try postgres.queryParams(self.allocator, lease.conn, "SELECT scopes,client_id FROM zigcho.oauth_tokens WHERE token_hash=$1 AND revoked_at IS NULL FOR UPDATE", &.{digest_bytea});
    if (locked.rows() == 0) {
        locked.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return false;
    }
    const scopes = locked.value(0, 0);
    const game_session = hasGameAccessScopes(scopes) or hasOauthScope(scopes, "game:refresh");
    const legacy_game_session = game_session and locked.isNull(0, 1);
    const client_id = if (legacy_game_session or !game_session) @as(i32, 0) else try locked.int(i32, 0, 1);
    locked.deinit();
    var client_buf: [24]u8 = undefined;
    const client = try std.fmt.bufPrint(&client_buf, "{d}", .{client_id});
    var result = if (game_session)
        if (legacy_game_session)
            try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND client_id IS NULL AND revoked_at IS NULL AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)') RETURNING 1", &.{id})
        else
            try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND client_id=$2 AND revoked_at IS NULL AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)') RETURNING 1", &.{ id, client })
    else
        try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND revoked_at IS NULL RETURNING 1", &.{digest_bytea});
    const revoked = result.rows() != 0;
    result.deinit();
    if (game_session and revoked) {
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1 AND NOT EXISTS(SELECT 1 FROM zigcho.oauth_tokens WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)')", &.{id});
        clear.deinit();
    }
    try postgres.exec(lease.conn, "COMMIT");
    return revoked;
}

pub fn revokeGameTokensForUser(self: anytype, user_id: i32) !usize {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
    lock.deinit();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)') RETURNING 1", &.{id});
    const revoked = result.rows();
    result.deinit();
    var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
    clear.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    return revoked;
}

pub fn revokeAllGameCredentialsForUser(self: anytype, user_id: i32) !usize {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
    lock.deinit();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)') RETURNING 1", &.{id});
    const oauth_revoked = result.rows();
    result.deinit();
    const stable_revoked = try postgres_stable_sessions.revokeWithConnection(self.allocator, lease.conn, user_id, std.Io.Clock.real.now(self.io).toSeconds());
    var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
    clear.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    return oauth_revoked + stable_revoked;
}

pub fn revokeLazerAccessTokensForUser(self: anytype, user_id: i32) !usize {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)' RETURNING 1", &.{id});
    const revoked = result.rows();
    result.deinit();
    var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
    clear.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    return revoked;
}
