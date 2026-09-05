const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const common = @import("../common.zig");

const MatchmakingBeatmap = storage_contracts.MatchmakingBeatmap;
const MultiplayerRoomArchive = storage_contracts.MultiplayerRoomArchive;
const LazerRankedRating = storage_contracts.LazerRankedRating;
const LazerRankedResult = storage_contracts.LazerRankedResult;

pub fn multiplayerRoomArchiveFromResult(allocator: std.mem.Allocator, result: postgres.Result, row: usize) !MultiplayerRoomArchive {
    const category = try allocator.dupe(u8, result.value(row, 2));
    errdefer allocator.free(category);
    const room_json = try allocator.dupe(u8, result.value(row, 3));
    errdefer allocator.free(room_json);
    const leaderboard_json = try allocator.dupe(u8, result.value(row, 4));
    errdefer allocator.free(leaderboard_json);
    const participant_ids_json = try allocator.dupe(u8, result.value(row, 5));
    errdefer allocator.free(participant_ids_json);
    return .{
        .allocator = allocator,
        .room_id = try result.int(i64, row, 0),
        .owner_id = try result.int(i32, row, 1),
        .category = category,
        .room_json = room_json,
        .leaderboard_json = leaderboard_json,
        .participant_ids_json = participant_ids_json,
        .ended_at = try result.int(i64, row, 6),
    };
}

pub fn nextLazerMultiplayerRoomId(self: anytype) !i64 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT greatest(coalesce((SELECT max(room_id) FROM zigcho.lazer_multiplayer_room_history),0),coalesce((SELECT max(room_id) FROM zigcho.lazer_ranked_matches),0))+1");
    defer result.deinit();
    if (result.rows() != 1) return error.DatabaseQueryFailed;
    return result.int(i64, 0, 0);
}

pub fn saveLazerMultiplayerRoomArchive(self: anytype, room_id: i64, owner_id: i32, category: []const u8, room_json: []const u8, leaderboard_json: []const u8, participant_ids_json: []const u8) !void {
    if (room_id <= 0 or owner_id <= 0 or room_json.len == 0 or room_json.len > 8 * 1024 * 1024 or leaderboard_json.len == 0 or leaderboard_json.len > 512 * 1024 or participant_ids_json.len == 0 or participant_ids_json.len > 4096) return error.InvalidMultiplayerArchive;
    if (!std.mem.eql(u8, category, "normal") and !std.mem.eql(u8, category, "realtime") and !std.mem.eql(u8, category, "spotlight") and !std.mem.eql(u8, category, "featured_artist")) return error.InvalidMultiplayerArchive;
    var room_buf: [24]u8 = undefined;
    var owner_buf: [16]u8 = undefined;
    const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
    const owner_id_text = try std.fmt.bufPrint(&owner_buf, "{d}", .{owner_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_multiplayer_room_history(room_id,owner_id,category,room_json,leaderboard_json,participant_ids_json,ended_at) VALUES($1,$2,$3,$4::jsonb,$5::jsonb,$6::jsonb,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(room_id) DO UPDATE SET owner_id=excluded.owner_id,category=excluded.category,room_json=excluded.room_json,leaderboard_json=excluded.leaderboard_json,participant_ids_json=excluded.participant_ids_json,ended_at=excluded.ended_at", &.{ room_id_text, owner_id_text, category, room_json, leaderboard_json, participant_ids_json });
    result.deinit();
}

pub fn updateLazerMultiplayerRoomArchive(self: anytype, room_id: i64, room_json: []const u8, leaderboard_json: []const u8) !void {
    if (room_id <= 0 or room_json.len == 0 or room_json.len > 8 * 1024 * 1024 or leaderboard_json.len == 0 or leaderboard_json.len > 512 * 1024) return error.InvalidMultiplayerArchive;
    var room_buf: [24]u8 = undefined;
    const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.lazer_multiplayer_room_history SET room_json=$2::jsonb,leaderboard_json=$3::jsonb WHERE room_id=$1 AND coalesce((room_json->>'zigcho_resumable')::boolean,false)=false RETURNING room_id", &.{ room_id_text, room_json, leaderboard_json });
    defer result.deinit();
    if (result.rows() != 1) return error.InvalidMultiplayerArchive;
}

pub fn lazerMultiplayerRoomArchive(self: anytype, allocator: std.mem.Allocator, room_id: i64) !?MultiplayerRoomArchive {
    if (room_id <= 0) return null;
    var room_buf: [24]u8 = undefined;
    const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT room_id,owner_id,category,room_json::text,leaderboard_json::text,participant_ids_json::text,ended_at FROM zigcho.lazer_multiplayer_room_history WHERE room_id=$1 AND coalesce((room_json->>'zigcho_resumable')::boolean,false)=false", &.{room_id_text});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try multiplayerRoomArchiveFromResult(allocator, result, 0);
}

pub fn lazerMultiplayerRoomArchives(self: anytype, allocator: std.mem.Allocator, limit: u8) ![]MultiplayerRoomArchive {
    if (limit == 0) return allocator.alloc(MultiplayerRoomArchive, 0);
    var limit_buf: [4]u8 = undefined;
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT room_id,owner_id,category,room_json::text,leaderboard_json::text,participant_ids_json::text,ended_at FROM zigcho.lazer_multiplayer_room_history WHERE coalesce((room_json->>'zigcho_resumable')::boolean,false)=false ORDER BY ended_at DESC,room_id DESC LIMIT $1", &.{limit_text});
    defer result.deinit();
    const archives = try allocator.alloc(MultiplayerRoomArchive, result.rows());
    var initialized: usize = 0;
    errdefer {
        for (archives[0..initialized]) |*archive| archive.deinit();
        allocator.free(archives);
    }
    for (archives, 0..) |*archive, row| {
        archive.* = try multiplayerRoomArchiveFromResult(allocator, result, row);
        initialized += 1;
    }
    return archives;
}

pub fn lazerMultiplayerRoomCheckpoints(self: anytype, allocator: std.mem.Allocator) ![]MultiplayerRoomArchive {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT room_id,owner_id,category,room_json::text,leaderboard_json::text,participant_ids_json::text,ended_at FROM zigcho.lazer_multiplayer_room_history WHERE coalesce((room_json->>'zigcho_resumable')::boolean,false)=true ORDER BY room_id LIMIT 64");
    defer result.deinit();
    const checkpoints = try allocator.alloc(MultiplayerRoomArchive, result.rows());
    var initialized: usize = 0;
    errdefer {
        for (checkpoints[0..initialized]) |*checkpoint| checkpoint.deinit();
        allocator.free(checkpoints);
    }
    for (checkpoints, 0..) |*checkpoint, row| {
        checkpoint.* = try multiplayerRoomArchiveFromResult(allocator, result, row);
        initialized += 1;
    }
    return checkpoints;
}

pub fn deleteLazerMultiplayerRoomCheckpoint(self: anytype, room_id: i64) !void {
    if (room_id <= 0) return error.InvalidMultiplayerArchive;
    var room_buf: [24]u8 = undefined;
    const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_multiplayer_room_history WHERE room_id=$1 AND coalesce((room_json->>'zigcho_resumable')::boolean,false)=true", &.{room_id_text});
    result.deinit();
}

pub fn lazerRankedRating(self: anytype, user_id: i32, ruleset_id: u8) !LazerRankedRating {
    if (user_id <= 0 or ruleset_id > 3) return error.InvalidRankedPlayUser;
    var user_buf: [16]u8 = undefined;
    var ruleset_buf: [4]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const ruleset = try std.fmt.bufPrint(&ruleset_buf, "{d}", .{ruleset_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT rating,games_played,wins,losses FROM zigcho.lazer_ranked_ratings WHERE user_id=$1 AND ruleset_id=$2", &.{ user, ruleset });
    defer result.deinit();
    if (result.rows() == 0) return .{};
    return .{
        .rating = try result.int(i32, 0, 0),
        .games_played = try result.int(i32, 0, 1),
        .wins = try result.int(i32, 0, 2),
        .losses = try result.int(i32, 0, 3),
    };
}

pub fn applyLazerRankedResult(self: anytype, room_id: i64, ruleset_id: u8, winner_id: i32, loser_id: i32) !LazerRankedResult {
    try storage_contracts.validateRankedPlayResult(room_id, ruleset_id, winner_id, loser_id);
    var room_buf: [24]u8 = undefined;
    var ruleset_buf: [4]u8 = undefined;
    var winner_buf: [16]u8 = undefined;
    var loser_buf: [16]u8 = undefined;
    const room = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
    const ruleset = try std.fmt.bufPrint(&ruleset_buf, "{d}", .{ruleset_id});
    const winner = try std.fmt.bufPrint(&winner_buf, "{d}", .{winner_id});
    const loser = try std.fmt.bufPrint(&loser_buf, "{d}", .{loser_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    var committed = false;
    defer if (!committed) postgres.exec(lease.conn, "ROLLBACK") catch {};

    var advisory = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{room});
    advisory.deinit();
    var existing = try postgres.queryParams(self.allocator, lease.conn, "SELECT ruleset_id,winner_id,loser_id,winner_rating_before,winner_rating_after,loser_rating_before,loser_rating_after FROM zigcho.lazer_ranked_matches WHERE room_id=$1", &.{room});
    if (existing.rows() != 0) {
        if (try existing.int(u8, 0, 0) != ruleset_id or try existing.int(i32, 0, 1) != winner_id or try existing.int(i32, 0, 2) != loser_id) {
            existing.deinit();
            return error.RankedPlayResultConflict;
        }
        const stored: LazerRankedResult = .{
            .applied = false,
            .winner_rating_before = try existing.int(i32, 0, 3),
            .winner_rating_after = try existing.int(i32, 0, 4),
            .loser_rating_before = try existing.int(i32, 0, 5),
            .loser_rating_after = try existing.int(i32, 0, 6),
        };
        existing.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        committed = true;
        return stored;
    }
    existing.deinit();

    var initialise = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_ranked_ratings(user_id,ruleset_id) VALUES($1,$3),($2,$3) ON CONFLICT(user_id,ruleset_id) DO NOTHING", &.{ winner, loser, ruleset });
    initialise.deinit();
    var ratings = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id,rating FROM zigcho.lazer_ranked_ratings WHERE ruleset_id=$3 AND user_id IN($1,$2) ORDER BY user_id FOR UPDATE", &.{ winner, loser, ruleset });
    defer ratings.deinit();
    if (ratings.rows() != 2) return error.DatabaseQueryFailed;
    var winner_rating_before: ?i32 = null;
    var loser_rating_before: ?i32 = null;
    for (0..ratings.rows()) |row| {
        const user_id = try ratings.int(i32, row, 0);
        if (user_id == winner_id) winner_rating_before = try ratings.int(i32, row, 1);
        if (user_id == loser_id) loser_rating_before = try ratings.int(i32, row, 1);
    }
    const winner_before = winner_rating_before orelse return error.DatabaseQueryFailed;
    const loser_before = loser_rating_before orelse return error.DatabaseQueryFailed;
    const winner_after = std.math.add(i32, winner_before, storage_contracts.ranked_play_rating_delta) catch return error.RankedPlayRatingOverflow;
    const loser_after = std.math.sub(i32, loser_before, storage_contracts.ranked_play_rating_delta) catch return error.RankedPlayRatingOverflow;
    var winner_after_buf: [16]u8 = undefined;
    var loser_after_buf: [16]u8 = undefined;
    const winner_after_text = try std.fmt.bufPrint(&winner_after_buf, "{d}", .{winner_after});
    const loser_after_text = try std.fmt.bufPrint(&loser_after_buf, "{d}", .{loser_after});
    var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.lazer_ranked_ratings SET rating=CASE user_id WHEN $1 THEN $4::integer ELSE $5::integer END,games_played=games_played+1,wins=wins+CASE WHEN user_id=$1 THEN 1 ELSE 0 END,losses=losses+CASE WHEN user_id=$2 THEN 1 ELSE 0 END,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE ruleset_id=$3 AND user_id IN($1,$2) RETURNING user_id", &.{ winner, loser, ruleset, winner_after_text, loser_after_text });
    defer update.deinit();
    if (update.rows() != 2) return error.DatabaseQueryFailed;
    var winner_before_buf: [16]u8 = undefined;
    var loser_before_buf: [16]u8 = undefined;
    const winner_before_text = try std.fmt.bufPrint(&winner_before_buf, "{d}", .{winner_before});
    const loser_before_text = try std.fmt.bufPrint(&loser_before_buf, "{d}", .{loser_before});
    var match = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_ranked_matches(room_id,ruleset_id,winner_id,loser_id,winner_rating_before,winner_rating_after,loser_rating_before,loser_rating_after) VALUES($1,$2,$3,$4,$5,$6,$7,$8)", &.{ room, ruleset, winner, loser, winner_before_text, winner_after_text, loser_before_text, loser_after_text });
    match.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    committed = true;
    return .{
        .applied = true,
        .winner_rating_before = winner_before,
        .winner_rating_after = winner_after,
        .loser_rating_before = loser_before,
        .loser_rating_after = loser_after,
    };
}

pub fn matchmakingBeatmaps(self: anytype, allocator: std.mem.Allocator, mode: u8, limit: u8) ![]MatchmakingBeatmap {
    if (mode > 3 or limit == 0 or limit > 32) return error.InvalidMatchmakingPool;
    var mode_buf: [4]u8 = undefined;
    var limit_buf: [4]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,md5,mode,star_rating FROM zigcho.beatmaps WHERE status IN(3,4) AND mode=$1 AND osu_file IS NOT NULL ORDER BY star_rating,id LIMIT $2", &.{ mode_text, limit_text });
    defer result.deinit();
    const maps = try allocator.alloc(MatchmakingBeatmap, result.rows());
    errdefer allocator.free(maps);
    for (maps, 0..) |*map, row| {
        const md5 = result.value(row, 1);
        if (md5.len != 32) return error.InvalidBeatmap;
        map.* = .{
            .id = try result.int(i32, row, 0),
            .md5 = undefined,
            .mode = try result.int(u8, row, 2),
            .stars = try result.float(f64, row, 3),
        };
        @memcpy(&map.md5, md5);
    }
    return maps;
}

pub fn teamsJson(self: anytype, allocator: std.mem.Allocator, requester_id: ?i32) ![]u8 {
    var requester_buf: [24]u8 = undefined;
    const requester = if (requester_id) |id| try std.fmt.bufPrint(&requester_buf, "{d}", .{id}) else null;
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT t.id,t.name,t.short_name,t.description,t.is_open,t.default_ruleset_id,t.leader_id,t.created_at,t.updated_at,(SELECT count(*) FROM zigcho.team_members m WHERE m.team_id=t.id),coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0),EXISTS(SELECT 1 FROM zigcho.team_members m WHERE m.team_id=t.id AND m.user_id=$1),EXISTS(SELECT 1 FROM zigcho.team_applications a WHERE a.team_id=t.id AND a.user_id=$1) FROM zigcho.teams t ORDER BY (SELECT count(*) FROM zigcho.team_members m WHERE m.team_id=t.id) DESC,lower(t.name),t.id", &.{requester});
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        const team_id = try result.int(i32, row, 0);
        const flag_version = try result.int(i64, row, 10);
        try output.writer.print("{{\"id\":{d},\"name\":", .{team_id});
        try common.jsonString(&output.writer, result.value(row, 1));
        try output.writer.writeAll(",\"short_name\":");
        try common.jsonString(&output.writer, result.value(row, 2));
        try output.writer.writeAll(",\"description\":");
        try common.jsonString(&output.writer, result.value(row, 3));
        try output.writer.print(",\"is_open\":{},\"default_ruleset_id\":{d},\"leader_id\":{d},\"created_at\":{d},\"updated_at\":{d},\"member_count\":{d},\"flag_url\":", .{ try result.boolean(row, 4), try result.int(u8, row, 5), try result.int(i32, row, 6), try result.int(i64, row, 7), try result.int(i64, row, 8), try result.int(i32, row, 9) });
        if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ team_id, flag_version }) else try output.writer.writeAll("null");
        try output.writer.print(",\"member\":{},\"applied\":{}}}", .{ try result.boolean(row, 11), try result.boolean(row, 12) });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn teamJson(self: anytype, allocator: std.mem.Allocator, team_id: i32, requester_id: ?i32, staff: bool) !?[]u8 {
    var id_buf: [24]u8 = undefined;
    var requester_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{team_id});
    const requester = if (requester_id) |value| try std.fmt.bufPrint(&requester_buf, "{d}", .{value}) else null;
    var lease = self.pool.acquire();
    defer lease.release();
    var team = try postgres.queryParams(allocator, lease.conn, "SELECT t.id,t.name,t.short_name,t.url,t.description,t.is_open,t.default_ruleset_id,t.leader_id,t.created_at,t.updated_at,coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0),coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='header'),0),EXISTS(SELECT 1 FROM zigcho.team_members m WHERE m.team_id=t.id AND m.user_id=$2),EXISTS(SELECT 1 FROM zigcho.team_applications a WHERE a.team_id=t.id AND a.user_id=$2) FROM zigcho.teams t WHERE t.id=$1", &.{ id, requester });
    defer team.deinit();
    if (team.rows() == 0) return null;
    const leader_id = try team.int(i32, 0, 7);
    const can_manage = staff or (requester_id != null and requester_id.? == leader_id);
    var members = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,m.joined_at FROM zigcho.team_members m JOIN zigcho.users u ON u.id=m.user_id WHERE m.team_id=$1 ORDER BY CASE WHEN u.id=(SELECT leader_id FROM zigcho.teams WHERE id=$1) THEN 0 ELSE 1 END,m.joined_at,u.id", &.{id});
    defer members.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"id\":{d},\"name\":", .{team_id});
    try common.jsonString(&output.writer, team.value(0, 1));
    try output.writer.writeAll(",\"short_name\":");
    try common.jsonString(&output.writer, team.value(0, 2));
    try output.writer.writeAll(",\"url\":");
    try common.jsonString(&output.writer, team.value(0, 3));
    try output.writer.writeAll(",\"description\":");
    try common.jsonString(&output.writer, team.value(0, 4));
    const flag_version = try team.int(i64, 0, 10);
    const header_version = try team.int(i64, 0, 11);
    try output.writer.print(",\"is_open\":{},\"default_ruleset_id\":{d},\"leader_id\":{d},\"created_at\":{d},\"updated_at\":{d},\"flag_url\":", .{ try team.boolean(0, 5), try team.int(u8, 0, 6), leader_id, try team.int(i64, 0, 8), try team.int(i64, 0, 9) });
    if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ team_id, flag_version }) else try output.writer.writeAll("null");
    try output.writer.writeAll(",\"header_url\":");
    if (header_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/header?v={d}\"", .{ team_id, header_version }) else try output.writer.writeAll("null");
    try output.writer.print(",\"member\":{},\"applied\":{},\"can_manage\":{},\"members\":[", .{ try team.boolean(0, 12), try team.boolean(0, 13), can_manage });
    for (0..members.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        const member_id = try members.int(i32, row, 0);
        try output.writer.print("{{\"id\":{d},\"name\":", .{member_id});
        try common.jsonString(&output.writer, members.value(row, 1));
        try output.writer.writeAll(",\"country\":");
        try common.jsonString(&output.writer, members.value(row, 2));
        try output.writer.print(",\"privileges\":{d},\"joined_at\":{d},\"leader\":{}}}", .{ try members.int(u32, row, 3), try members.int(i64, row, 4), member_id == leader_id });
    }
    try output.writer.writeAll("],\"applications\":[");
    if (can_manage) {
        var applications = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,u.country,a.created_at FROM zigcho.team_applications a JOIN zigcho.users u ON u.id=a.user_id WHERE a.team_id=$1 ORDER BY a.created_at,u.id", &.{id});
        defer applications.deinit();
        for (0..applications.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"name\":", .{try applications.int(i32, row, 0)});
            try common.jsonString(&output.writer, applications.value(row, 1));
            try output.writer.writeAll(",\"country\":");
            try common.jsonString(&output.writer, applications.value(row, 2));
            try output.writer.print(",\"created_at\":{d}}}", .{try applications.int(i64, row, 3)});
        }
    }
    try output.writer.writeAll("]}");
    return @as(?[]u8, try output.toOwnedSlice());
}

pub fn createTeam(self: anytype, user_id: i32, settings: domain.TeamSettings) !i32 {
    var buffers: [4][24]u8 = undefined;
    var cursor: usize = 0;
    const user = try common.param(&buffers, &cursor, user_id);
    const is_open = if (settings.is_open) "true" else "false";
    const ruleset = try common.param(&buffers, &cursor, settings.default_ruleset_id);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var insert = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.teams(name,short_name,url,description,is_open,default_ruleset_id,leader_id) SELECT $1,$2,$3,$4,$5,$6,$7 WHERE NOT EXISTS(SELECT 1 FROM zigcho.team_members WHERE user_id=$7) RETURNING id", &.{ settings.name, settings.short_name, settings.url, settings.description, is_open, ruleset, user }) catch |err| switch (err) {
        error.UniqueViolation => return error.TeamExists,
        else => return err,
    };
    defer insert.deinit();
    if (insert.rows() != 1) return error.AlreadyInTeam;
    const team_id = try insert.int(i32, 0, 0);
    const team = try common.param(&buffers, &cursor, team_id);
    var member = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.team_members(user_id,team_id) VALUES($1,$2)", &.{ user, team });
    member.deinit();
    var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_applications WHERE user_id=$1", &.{user});
    clear.deinit();
    try common.insertAudit(self.allocator, lease.conn, user_id, "team.create", user_id, "team created");
    try postgres.exec(lease.conn, "COMMIT");
    return team_id;
}

pub fn updateTeam(self: anytype, actor_id: i32, team_id: i32, settings: domain.TeamSettings, staff: bool) !void {
    var buffers: [4][24]u8 = undefined;
    var cursor: usize = 0;
    const actor = try common.param(&buffers, &cursor, actor_id);
    const team = try common.param(&buffers, &cursor, team_id);
    const ruleset = try common.param(&buffers, &cursor, settings.default_ruleset_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.teams SET name=$1,short_name=$2,url=$3,description=$4,is_open=$5,default_ruleset_id=$6,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,updated_at+1) WHERE id=$7 AND (leader_id=$8 OR $9::boolean) RETURNING id", &.{ settings.name, settings.short_name, settings.url, settings.description, if (settings.is_open) "true" else "false", ruleset, team, actor, if (staff) "true" else "false" }) catch |err| switch (err) {
        error.UniqueViolation => return error.TeamExists,
        else => return err,
    };
    defer result.deinit();
    if (result.rows() != 1) return error.TeamPermissionDenied;
}

pub fn joinOrApplyTeam(self: anytype, user_id: i32, team_id: i32) !domain.TeamJoinResult {
    var buffers: [2][24]u8 = undefined;
    var cursor: usize = 0;
    const user = try common.param(&buffers, &cursor, user_id);
    const team = try common.param(&buffers, &cursor, team_id);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var found = try postgres.queryParams(self.allocator, lease.conn, "SELECT is_open FROM zigcho.teams WHERE id=$1 FOR UPDATE", &.{team});
    defer found.deinit();
    if (found.rows() != 1) return error.TeamNotFound;
    const team_open = try found.boolean(0, 0);
    var result = postgres.queryParams(self.allocator, lease.conn, if (team_open) "INSERT INTO zigcho.team_members(user_id,team_id) VALUES($1,$2)" else "INSERT INTO zigcho.team_applications(user_id,team_id) VALUES($1,$2)", &.{ user, team }) catch |err| switch (err) {
        error.UniqueViolation => return if (team_open) error.AlreadyInTeam else error.AlreadyApplied,
        else => return err,
    };
    result.deinit();
    if (team_open) {
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_applications WHERE user_id=$1", &.{user});
        clear.deinit();
    }
    try postgres.exec(lease.conn, "COMMIT");
    return if (team_open) .joined else .applied;
}

pub fn leaveTeam(self: anytype, user_id: i32, team_id: i32) !void {
    var buffers: [2][24]u8 = undefined;
    var cursor: usize = 0;
    const user = try common.param(&buffers, &cursor, user_id);
    const team = try common.param(&buffers, &cursor, team_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_members WHERE user_id=$1 AND team_id=$2 AND user_id!=(SELECT leader_id FROM zigcho.teams WHERE id=$2) RETURNING user_id", &.{ user, team });
    defer result.deinit();
    if (result.rows() != 1) return error.TeamLeaderCannotLeave;
}

pub fn teamMemberAction(self: anytype, actor_id: i32, team_id: i32, target_id: i32, action: []const u8, staff: bool) !void {
    var buffers: [3][24]u8 = undefined;
    var cursor: usize = 0;
    const actor = try common.param(&buffers, &cursor, actor_id);
    const team = try common.param(&buffers, &cursor, team_id);
    const target = try common.param(&buffers, &cursor, target_id);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var auth = try postgres.queryParams(self.allocator, lease.conn, "SELECT leader_id FROM zigcho.teams WHERE id=$1 AND (leader_id=$2 OR $3::boolean) FOR UPDATE", &.{ team, actor, if (staff) "true" else "false" });
    defer auth.deinit();
    if (auth.rows() != 1) return error.TeamPermissionDenied;
    const leader_id = try auth.int(i32, 0, 0);
    if (std.mem.eql(u8, action, "approve")) {
        var result = postgres.queryParams(self.allocator, lease.conn, "WITH moved AS (DELETE FROM zigcho.team_applications WHERE user_id=$1 AND team_id=$2 RETURNING user_id,team_id) INSERT INTO zigcho.team_members(user_id,team_id) SELECT user_id,team_id FROM moved RETURNING user_id", &.{ target, team }) catch |err| switch (err) {
            error.UniqueViolation => return error.AlreadyInTeam,
            else => return err,
        };
        defer result.deinit();
        if (result.rows() != 1) return error.TeamApplicationNotFound;
    } else if (std.mem.eql(u8, action, "reject")) {
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_applications WHERE user_id=$1 AND team_id=$2 RETURNING user_id", &.{ target, team });
        defer result.deinit();
        if (result.rows() != 1) return error.TeamApplicationNotFound;
    } else if (std.mem.eql(u8, action, "remove")) {
        if (target_id == leader_id) return error.TeamLeaderCannotLeave;
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_members WHERE user_id=$1 AND team_id=$2 RETURNING user_id", &.{ target, team });
        defer result.deinit();
        if (result.rows() != 1) return error.TeamMemberNotFound;
    } else if (std.mem.eql(u8, action, "transfer")) {
        if (!staff and actor_id != leader_id) return error.TeamPermissionDenied;
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.teams SET leader_id=$1,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,updated_at+1) WHERE id=$2 AND EXISTS(SELECT 1 FROM zigcho.team_members WHERE team_id=$2 AND user_id=$1) RETURNING id", &.{ target, team });
        defer result.deinit();
        if (result.rows() != 1) return error.TeamMemberNotFound;
    } else return error.InvalidTeamAction;
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn disbandTeam(self: anytype, actor_id: i32, team_id: i32, staff: bool) !void {
    var buffers: [2][24]u8 = undefined;
    var cursor: usize = 0;
    const actor = try common.param(&buffers, &cursor, actor_id);
    const team = try common.param(&buffers, &cursor, team_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.teams WHERE id=$1 AND (leader_id=$2 OR $3::boolean) RETURNING id", &.{ team, actor, if (staff) "true" else "false" });
    defer result.deinit();
    if (result.rows() != 1) return error.TeamPermissionDenied;
}

pub fn teamCanManage(self: anytype, actor_id: i32, team_id: i32, staff: bool) !bool {
    var buffers: [2][24]u8 = undefined;
    var cursor: usize = 0;
    const actor = try common.param(&buffers, &cursor, actor_id);
    const team = try common.param(&buffers, &cursor, team_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.teams WHERE id=$1 AND (leader_id=$2 OR $3::boolean)", &.{ team, actor, if (staff) "true" else "false" });
    defer result.deinit();
    return result.rows() != 0;
}
