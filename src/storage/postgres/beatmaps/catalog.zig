const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const beatmap = @import("../../../beatmap.zig");
const lazer = @import("../../../lazer.zig");
const stable_mods = @import("../../../stable_mods.zig");
const user_json = @import("../../../user_json.zig");
const upstream_user = @import("../../../upstream_user.zig");
const common = @import("../common.zig");
const pg_score_maintenance = @import("../scores/maintenance.zig");

const LazerCommentable = storage_contracts.LazerCommentable;
const LazerCommentTarget = storage_contracts.LazerCommentTarget;
const LazerCommentSort = storage_contracts.LazerCommentSort;
const UpstreamUserCache = storage_contracts.UpstreamUserCache;
const BeatmapSetCreator = storage_contracts.BeatmapSetCreator;
const StableBeatmapInfo = storage_contracts.StableBeatmapInfo;
const BeatmapSelection = storage_contracts.BeatmapSelection;
const BeatmapRating = storage_contracts.BeatmapRating;
const directListingStatus = storage_contracts.directListingStatus;
const stableStatus = storage_contracts.stableStatus;
const lazerStatus = storage_contracts.lazerStatus;

pub fn rateBeatmap(self: anytype, user_id: i32, map_md5: []const u8, rating: ?u8) !BeatmapRating {
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT status FROM zigcho.beatmaps WHERE md5=$1", &.{map_md5});
    defer map.deinit();
    if (map.rows() == 0) return .no_exist;
    if (try map.int(i32, 0, 0) < 3) return .not_ranked;
    if (rating) |value| {
        if (value < 1 or value > 10) return error.InvalidRating;
        var rating_buf: [4]u8 = undefined;
        const rating_text = try std.fmt.bufPrint(&rating_buf, "{d}", .{value});
        var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.ratings(user_id,map_md5,rating) VALUES($1,$2,$3) ON CONFLICT(user_id,map_md5) DO NOTHING", &.{ user, map_md5, rating_text });
        insert.deinit();
    } else {
        var existing = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.ratings WHERE user_id=$1 AND map_md5=$2", &.{ user, map_md5 });
        defer existing.deinit();
        if (existing.rows() == 0) return .can_rate;
    }
    var average = try postgres.queryParams(self.allocator, lease.conn, "SELECT avg(rating) FROM zigcho.ratings WHERE map_md5=$1", &.{map_md5});
    defer average.deinit();
    if (average.rows() == 0 or average.isNull(0, 0)) return error.DatabaseQueryFailed;
    return .{ .already_voted = try average.float(f64, 0, 0) };
}

pub fn upsertBeatmapInner(self: anytype, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: ?[]const u8, update_existing: bool) !void {
    var buffers: [32][64]u8 = undefined;
    var cursor: usize = 0;
    const map_id = try common.param(&buffers, &cursor, metadata.id);
    const set_id = try common.param(&buffers, &cursor, metadata.set_id);
    const status_text = try common.param(&buffers, &cursor, status);
    const total_length = try common.param(&buffers, &cursor, metadata.total_length);
    const combo = try common.param(&buffers, &cursor, max_combo);
    const mode = try common.param(&buffers, &cursor, metadata.mode);
    const bpm = try common.param(&buffers, &cursor, metadata.bpm);
    const cs = try common.param(&buffers, &cursor, metadata.cs);
    const ar = try common.param(&buffers, &cursor, metadata.ar);
    const od = try common.param(&buffers, &cursor, metadata.od);
    const hp = try common.param(&buffers, &cursor, metadata.hp);
    const star_rating = try common.param(&buffers, &cursor, stars);
    const circles = try common.param(&buffers, &cursor, metadata.count_circles);
    const sliders = try common.param(&buffers, &cursor, metadata.count_sliders);
    const spinners = try common.param(&buffers, &cursor, metadata.count_spinners);
    var encoded_file: ?[]u8 = null;
    if (osu_file) |bytes| encoded_file = try postgres.encodeBytea(self.allocator, bytes);
    defer if (encoded_file) |bytes| self.allocator.free(bytes);
    const file_param: ?[]const u8 = if (encoded_file) |bytes| bytes else null;
    const sql = if (update_existing)
        "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES($1,$2,$3,$4,$5,$6,$7,$8,extract(epoch FROM clock_timestamp())::bigint,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,status=CASE WHEN zigcho.beatmaps.status_frozen THEN zigcho.beatmaps.status ELSE excluded.status END,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners"
    else
        "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES($1,$2,$3,$4,$5,$6,$7,$8,extract(epoch FROM clock_timestamp())::bigint,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) ON CONFLICT(id) DO NOTHING";
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    if (update_existing) try pg_score_maintenance.history_updates.lockMaintenance(lease.conn);
    var previous = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.status,b.status_frozen,EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.map_md5=b.md5) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.beatmap_id=b.id) FROM zigcho.beatmaps b WHERE b.id=$1 FOR UPDATE", &.{map_id});
    defer previous.deinit();
    const previous_status: ?i8 = if (previous.rows() == 0) null else try previous.int(i8, 0, 0);
    const previous_frozen = previous.rows() != 0 and try previous.boolean(0, 1);
    const had_scores = previous.rows() != 0 and try previous.boolean(0, 2);
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ map_id, set_id, md5, metadata.artist, metadata.title, metadata.version, metadata.creator, status_text, total_length, combo, mode, bpm, cs, ar, od, hp, star_rating, metadata.source, metadata.tags, file_param, circles, sliders, spinners });
    result.deinit();
    if (update_existing) if (previous_status) |old_status| {
        const effective_status = if (previous_frozen) old_status else status;
        const leaderboard_changed = (old_status >= 3) != (effective_status >= 3);
        const ranked_changed = (old_status == 3 or old_status == 4) != (effective_status == 3 or effective_status == 4);
        if (had_scores and (leaderboard_changed or ranked_changed)) {
            try pg_score_maintenance.rebuildRankedStats(self, lease.conn, false);
            try pg_score_maintenance.recordBeatmapStatsHistoryCurrentWithConnection(self, lease.conn, metadata.id, md5);
        }
    };
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn upsertBeatmap(self: anytype, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: []const u8) !void {
    return upsertBeatmapInner(self, metadata, md5, status, stars, max_combo, osu_file, true);
}

pub fn upsertBeatmapMeta(self: anytype, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32) !void {
    return upsertBeatmapInner(self, metadata, md5, status, stars, max_combo, null, false);
}

pub fn beatmapFile(self: anytype, allocator: std.mem.Allocator, md5: []const u8) !?[]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT osu_file FROM zigcho.beatmaps WHERE md5=$1 AND osu_file IS NOT NULL", &.{md5});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try postgres.decodeBytea(allocator, result.value(0, 0));
}

pub fn beatmapHasFile(self: anytype, md5: []const u8) !bool {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE md5=$1 AND osu_file IS NOT NULL", &.{md5});
    defer result.deinit();
    return result.rows() != 0;
}

pub fn beatmapFileById(self: anytype, allocator: std.mem.Allocator, map_id: i32) !?[]u8 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT osu_file FROM zigcho.beatmaps WHERE id=$1 AND osu_file IS NOT NULL", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try postgres.decodeBytea(allocator, result.value(0, 0));
}

pub fn beatmapSelectionById(self: anytype, map_id: i32) !?BeatmapSelection {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT md5,set_id,status,mode FROM zigcho.beatmaps WHERE id=$1", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    const md5 = result.value(0, 0);
    if (md5.len != 32) return error.InvalidBeatmap;
    var selection: BeatmapSelection = .{
        .md5 = undefined,
        .set_id = try result.int(i32, 0, 1),
        .status = try result.int(i8, 0, 2),
        .mode = try result.int(u8, 0, 3),
    };
    @memcpy(&selection.md5, md5);
    return selection;
}

pub fn beatmapSetExists(self: anytype, set_id: i32) !bool {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE set_id=$1 LIMIT 1", &.{set});
    defer result.deinit();
    return result.rows() != 0;
}

pub fn beatmapSetCreator(self: anytype, allocator: std.mem.Allocator, set_id: i32) !?BeatmapSetCreator {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT coalesce(max(owner.name),b.creator),min(b.mode),coalesce(max(owner.id),max(b.creator_id)),max(owner.id) IS NOT NULL FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.set_id=$1 GROUP BY b.creator ORDER BY count(*) DESC,b.creator LIMIT 1", &.{set});
    defer result.deinit();
    if (result.rows() == 0) return null;
    const name = try allocator.dupe(u8, result.value(0, 0));
    return .{
        .allocator = allocator,
        .name = name,
        .mode = try result.int(u8, 0, 1),
        .user_id = if (result.isNull(0, 2)) null else try result.int(i32, 0, 2),
        .is_local = try result.boolean(0, 3),
    };
}

pub fn upstreamUserCacheByName(self: anytype, name: []const u8, mode: u8, now: i64, max_age: i64) !?UpstreamUserCache {
    if (mode > 3 or now < 0 or max_age < 0) return error.InvalidUpstreamUser;
    var mode_buf: [4]u8 = undefined;
    var now_buf: [32]u8 = undefined;
    var age_buf: [32]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
    const age_text = try std.fmt.bufPrint(&age_buf, "{d}", .{max_age});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.id,coalesce(p.fetched_at>=$3::bigint-$4::bigint,false) FROM zigcho.upstream_users u LEFT JOIN zigcho.upstream_user_profiles p ON p.user_id=u.id AND p.mode=$2 WHERE lower(u.username)=lower($1) ORDER BY u.fetched_at DESC,u.id LIMIT 1", &.{ name, mode_text, now_text, age_text });
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{ .id = try result.int(i32, 0, 0), .fresh = try result.boolean(0, 1) };
}

pub fn upstreamUserCacheById(self: anytype, user_id: i32, mode: u8, now: i64, max_age: i64) !?UpstreamUserCache {
    if (user_id <= 0 or mode > 3 or now < 0 or max_age < 0) return error.InvalidUpstreamUser;
    var id_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    var now_buf: [32]u8 = undefined;
    var age_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
    const age_text = try std.fmt.bufPrint(&age_buf, "{d}", .{max_age});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.id,coalesce(p.fetched_at>=$3::bigint-$4::bigint,false) FROM zigcho.upstream_users u LEFT JOIN zigcho.upstream_user_profiles p ON p.user_id=u.id AND p.mode=$2 WHERE u.id=$1", &.{ id, mode_text, now_text, age_text });
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{ .id = try result.int(i32, 0, 0), .fresh = try result.boolean(0, 1) };
}

pub fn upsertUpstreamUserProfile(self: anytype, profile: upstream_user.Profile, profile_json: []const u8, fetched_at: i64) !void {
    try upstream_user.validate(profile);
    if (fetched_at < 0 or profile_json.len == 0 or profile_json.len > 128 * 1024 or !std.unicode.utf8ValidateSlice(profile_json)) return error.InvalidUpstreamUser;
    var id_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    var fetched_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{profile.id});
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{profile.mode});
    const fetched = try std.fmt.bufPrint(&fetched_buf, "{d}", .{fetched_at});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var user_result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.upstream_users(id,username,country,join_date,fetched_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(id) DO UPDATE SET username=excluded.username,country=excluded.country,join_date=excluded.join_date,fetched_at=excluded.fetched_at", &.{ id, profile.username, profile.country[0..], profile.join_date, fetched });
    user_result.deinit();
    var profile_result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.upstream_user_profiles(user_id,mode,profile_json,fetched_at) VALUES($1,$2,$3::jsonb,$4) ON CONFLICT(user_id,mode) DO UPDATE SET profile_json=excluded.profile_json,fetched_at=excluded.fetched_at", &.{ id, mode_text, profile_json, fetched });
    profile_result.deinit();
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn linkBeatmapSetCreator(self: anytype, set_id: i32, user_id: i32) !void {
    if (set_id <= 0 or user_id <= 0) return error.InvalidUpstreamUser;
    var set_buf: [24]u8 = undefined;
    var id_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET creator_id=$2 WHERE set_id=$1 AND EXISTS(SELECT 1 FROM zigcho.upstream_users WHERE id=$2)", &.{ set, id });
    result.deinit();
}

pub fn upstreamUserProfileJson(self: anytype, allocator: std.mem.Allocator, user_id: i32, mode: u8) !?[]u8 {
    if (user_id <= 0 or mode > 3) return null;
    var id_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT profile_json::text FROM zigcho.upstream_user_profiles WHERE user_id=$1 ORDER BY mode=$2::int DESC,mode=0 DESC,mode LIMIT 1", &.{ id, mode_text });
    defer result.deinit();
    if (result.rows() == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, result.value(0, 0)));
}

pub fn upsertBeatmapSetMetadata(self: anytype, metadata: upstream_user.SetMetadata, fetched_at: i64) !void {
    if (metadata.set_id <= 0 or metadata.favourites < 0 or metadata.genre_id < 0 or metadata.language_id < 0 or fetched_at < 0 or metadata.submitted_date.len != 20 or metadata.last_updated.len != 20 or (metadata.ranked_date != null and metadata.ranked_date.?.len != 20)) return error.InvalidBeatmapSetMetadata;
    var set_buf: [24]u8 = undefined;
    var favourites_buf: [24]u8 = undefined;
    var genre_buf: [8]u8 = undefined;
    var language_buf: [8]u8 = undefined;
    var fetched_buf: [32]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{metadata.set_id});
    const favourites = try std.fmt.bufPrint(&favourites_buf, "{d}", .{metadata.favourites});
    const genre = try std.fmt.bufPrint(&genre_buf, "{d}", .{metadata.genre_id});
    const language = try std.fmt.bufPrint(&language_buf, "{d}", .{metadata.language_id});
    const fetched = try std.fmt.bufPrint(&fetched_buf, "{d}", .{fetched_at});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmapset_metadata(set_id,favourites,submitted_date,last_updated,ranked_date,has_video,genre_id,language_id,fetched_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(set_id) DO UPDATE SET favourites=excluded.favourites,submitted_date=excluded.submitted_date,last_updated=excluded.last_updated,ranked_date=excluded.ranked_date,has_video=excluded.has_video,genre_id=excluded.genre_id,language_id=excluded.language_id,fetched_at=excluded.fetched_at", &.{ set, favourites, metadata.submitted_date, metadata.last_updated, metadata.ranked_date, if (metadata.has_video) "true" else "false", genre, language, fetched });
    result.deinit();
}

pub fn updateBeatmapUpstreamStats(self: anytype, beatmap_id: i32, plays: i32, passes: i32, hit_length: i32) !void {
    if (beatmap_id <= 0 or plays < 0 or passes < 0 or passes > plays or hit_length < 0) return error.InvalidBeatmapSetMetadata;
    var map_buf: [24]u8 = undefined;
    var plays_buf: [24]u8 = undefined;
    var passes_buf: [24]u8 = undefined;
    var hit_buf: [24]u8 = undefined;
    const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
    const play_count = try std.fmt.bufPrint(&plays_buf, "{d}", .{plays});
    const pass_count = try std.fmt.bufPrint(&passes_buf, "{d}", .{passes});
    const hit = try std.fmt.bufPrint(&hit_buf, "{d}", .{hit_length});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET upstream_plays=$2,upstream_passes=$3,hit_length=$4 WHERE id=$1", &.{ map, play_count, pass_count, hit });
    result.deinit();
}

pub fn beatmapSetIdForMap(self: anytype, beatmap_id: i32) !?i32 {
    var map_buf: [24]u8 = undefined;
    const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE id=$1", &.{map});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try result.int(i32, 0, 0);
}

pub fn beatmapSetIdForChecksum(self: anytype, checksum: []const u8) !?i32 {
    if (!lazer.validHash(checksum)) return null;
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE md5=$1", &.{checksum});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try result.int(i32, 0, 0);
}

pub fn writeDirectText(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |char| try writer.writeByte(switch (char) {
        '|' => 'I',
        '\r', '\n' => ' ',
        else => char,
    });
}

pub fn appendDirectSet(self: anytype, conn: *postgres.c.PGconn, writer: *std.Io.Writer, set_id: i32) !bool {
    return appendDirectSetFields(self, conn, writer, set_id, true);
}

fn appendDirectSetFields(self: anytype, conn: *postgres.c.PGconn, writer: *std.Io.Writer, set_id: i32, include_difficulties: bool) !bool {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var set_result = try postgres.queryParams(self.allocator, conn, "SELECT artist,title,creator,status,coalesce(to_char(to_timestamp(last_update) AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS'),'1970-01-01 00:00:00') FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY star_rating LIMIT 1", &.{set});
    defer set_result.deinit();
    if (set_result.rows() == 0) return false;
    try writer.print("{d}.osz|", .{set_id});
    try writeDirectText(writer, set_result.value(0, 0));
    try writer.writeByte('|');
    try writeDirectText(writer, set_result.value(0, 1));
    try writer.writeByte('|');
    try writeDirectText(writer, set_result.value(0, 2));
    const status = try set_result.int(i32, 0, 3);
    try writer.print("|{d}|10.0|{s}|{d}|0|0|0|0|0", .{ if (include_difficulties) directListingStatus(status) else stableStatus(status), set_result.value(0, 4), set_id });
    if (!include_difficulties) return true;
    try writer.writeByte('|');

    var maps = try postgres.queryParams(self.allocator, conn, "SELECT star_rating,version,cs,od,ar,hp,mode FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY star_rating,id", &.{set});
    defer maps.deinit();
    for (0..maps.rows()) |row| {
        if (row != 0) try writer.writeByte(',');
        try writer.print("[{d:.2}⭐] ", .{try maps.float(f64, row, 0)});
        try writeDirectText(writer, maps.value(row, 1));
        try writer.print(" {{cs: {d} / od: {d} / ar: {d} / hp: {d}}}@{d}", .{ try maps.float(f64, row, 2), try maps.float(f64, row, 3), try maps.float(f64, row, 4), try maps.float(f64, row, 5), try maps.int(i32, row, 6) });
    }
    return true;
}

pub fn stableSearch(self: anytype, allocator: std.mem.Allocator, search_query: []const u8, mode: i8, direct_status: u8, page: u16) ![]u8 {
    var mode_buf: [4]u8 = undefined;
    var status_buf: [4]u8 = undefined;
    var offset_buf: [24]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const status_text = try std.fmt.bufPrint(&status_buf, "{d}", .{direct_status});
    const offset = try std.fmt.bufPrint(&offset_buf, "{d}", .{@as(u32, page) * 100});
    var lease = self.pool.acquire();
    defer lease.release();
    var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE EXISTS(SELECT 1 FROM zigcho.beatmap_archives a WHERE a.set_id=zigcho.beatmaps.set_id) AND ($1::int=-1 OR mode=$1::int) AND ($2='' OR strpos(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower($2))>0) AND (($3::int=4 AND status IN(3,4,5,6)) OR ($3::int IN(0,7) AND status IN(3,4)) OR ($3::int IN(2,5) AND status=2) OR ($3::int=3 AND status=5) OR ($3::int=8 AND status=6)) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 100 OFFSET $4", &.{ mode_text, search_query, status_text, offset });
    defer ids.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{d}", .{if (ids.rows() == 100) @as(usize, 101) else ids.rows()});
    for (0..ids.rows()) |row| {
        try output.writer.writeByte('\n');
        _ = try appendDirectSet(self, lease.conn, &output.writer, try ids.int(i32, row, 0));
    }
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn stableSearchSet(self: anytype, allocator: std.mem.Allocator, set_id: ?i32, map_id: ?i32, md5: ?[]const u8) ![]u8 {
    var set_buf: [24]u8 = undefined;
    var map_buf: [24]u8 = undefined;
    const set: ?[]const u8 = if (set_id) |value| try std.fmt.bufPrint(&set_buf, "{d}", .{value}) else null;
    const map: ?[]const u8 = if (map_id) |value| try std.fmt.bufPrint(&map_buf, "{d}", .{value}) else null;
    var lease = self.pool.acquire();
    defer lease.release();
    var found = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE ($1::int IS NOT NULL AND set_id=$1::int) OR ($2::int IS NOT NULL AND id=$2::int) OR ($3::text IS NOT NULL AND md5=$3::text) LIMIT 1", &.{ set, map, md5 });
    defer found.deinit();
    if (found.rows() == 0) return allocator.dupe(u8, "");
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    _ = try appendDirectSetFields(self, lease.conn, &output.writer, try found.int(i32, 0, 0), false);
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn writeBoardRow(writer: *std.Io.Writer, result: postgres.Result, row: usize, rank: i32, uses_pp: bool) !void {
    const score_value: i64 = if (uses_pp) @intFromFloat(try result.float(f64, row, 2)) else try result.int(i64, row, 2);
    try writer.print("{d}|{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}", .{
        try result.int(i64, row, 0),
        result.value(row, 1),
        score_value,
        try result.int(i32, row, 3),
        try result.int(i32, row, 4),
        try result.int(i32, row, 5),
        try result.int(i32, row, 6),
        try result.int(i32, row, 7),
        try result.int(i32, row, 8),
        try result.int(i32, row, 9),
        @intFromBool(try result.boolean(row, 10)),
        try result.int(i32, row, 11),
        try result.int(i32, row, 12),
        rank,
        try result.int(i64, row, 13),
        @intFromBool(try result.boolean(row, 14)),
    });
}

pub fn stableLeaderboard(self: anytype, allocator: std.mem.Allocator, viewer: domain.User, map_md5: []const u8, mode: u8, board_type: u8, requested_mods: i32) ![]u8 {
    var mode_buf: [4]u8 = undefined;
    var board_buf: [4]u8 = undefined;
    var mods_buf: [16]u8 = undefined;
    var viewer_buf: [24]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const board = try std.fmt.bufPrint(&board_buf, "{d}", .{board_type});
    const mods = try std.fmt.bufPrint(&mods_buf, "{d}", .{requested_mods});
    const viewer_id = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer.id});
    const namespace = stable_mods.namespace(requested_mods);
    const uses_pp = std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot");
    const filter = " FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.map_md5=$1 AND s.mode=$2 AND s.passed AND s.best AND s.rank_namespace=$3 AND ($4::int!=2 OR s.mods=$5) AND ($4::int!=3 OR s.user_id=$6 OR EXISTS(SELECT 1 FROM zigcho.friends f JOIN zigcho.users friend_sender ON friend_sender.id=f.user_id JOIN zigcho.users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=$6 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND NOT friend_sender.restricted AND NOT friend_target.restricted)) AND ($4::int!=4 OR u.country=$7)";
    const params = &.{ map_md5, mode_text, namespace, board, mods, viewer_id, viewer.country[0..] };
    var lease = self.pool.acquire();
    defer lease.release();
    var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,status,artist,title,version,coalesce((SELECT avg(rating) FROM zigcho.ratings WHERE map_md5=$1),0) FROM zigcho.beatmaps WHERE md5=$1", &.{map_md5});
    defer map.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    if (map.rows() == 0) {
        try writer.writeAll("-1|false");
        var missing = output.toArrayList();
        return missing.toOwnedSlice(allocator);
    }
    const map_id = try map.int(i32, 0, 0);
    const set_id = try map.int(i32, 0, 1);
    const status = try map.int(i32, 0, 2);
    const client_status = stableStatus(status);
    if (status < 3) {
        try writer.print("{d}|false", .{client_status});
        var unavailable = output.toArrayList();
        return unavailable.toOwnedSlice(allocator);
    }

    var count = try postgres.queryParams(self.allocator, lease.conn, "SELECT least(count(*),50)" ++ filter, params);
    defer count.deinit();
    const row_count = try count.int(i32, 0, 0);
    try writer.print("{d}|false|{d}|{d}|{d}|0|\n0\n{s} - {s} [{s}]\n", .{ client_status, map_id, set_id, row_count, map.value(0, 3), map.value(0, 4), map.value(0, 5) });
    try storage_contracts.writeStableRating(writer, try map.float(f64, 0, 6));
    try writer.writeByte('\n');

    var personal = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
        "SELECT s.id,s.pp" ++ filter ++ " AND s.user_id=$6 ORDER BY s.pp DESC,s.id ASC LIMIT 1"
    else
        "SELECT s.id,s.score" ++ filter ++ " AND s.user_id=$6 ORDER BY s.score DESC,s.id ASC LIMIT 1", params);
    defer personal.deinit();
    if (personal.rows() != 0) {
        const personal_id = try personal.int(i64, 0, 0);
        var metric_buf: [64]u8 = undefined;
        var score_id_buf: [24]u8 = undefined;
        const metric = if (uses_pp)
            try std.fmt.bufPrint(&metric_buf, "{d}", .{try personal.float(f64, 0, 1)})
        else
            try std.fmt.bufPrint(&metric_buf, "{d}", .{try personal.int(i64, 0, 1)});
        const personal_id_text = try std.fmt.bufPrint(&score_id_buf, "{d}", .{personal_id});
        const rank_params = &.{ map_md5, mode_text, namespace, board, mods, viewer_id, viewer.country[0..], metric, personal_id_text };
        var personal_rank = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
            "SELECT count(*)+1" ++ filter ++ " AND (s.pp>$8 OR (s.pp=$8 AND s.id<$9))"
        else
            "SELECT count(*)+1" ++ filter ++ " AND (s.score>$8 OR (s.score=$8 AND s.id<$9))", rank_params);
        defer personal_rank.deinit();
        var personal_row = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
            "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1"
        else
            "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1", &.{personal_id_text});
        defer personal_row.deinit();
        if (personal_row.rows() == 0) return error.DatabaseQueryFailed;
        try writeBoardRow(writer, personal_row, 0, try personal_rank.int(i32, 0, 0), uses_pp);
    }
    try writer.writeByte('\n');
    var rows = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
        "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id))" ++ filter ++ " ORDER BY s.pp DESC,s.id ASC LIMIT 50"
    else
        "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id))" ++ filter ++ " ORDER BY s.score DESC,s.id ASC LIMIT 50", params);
    defer rows.deinit();
    for (0..rows.rows()) |row| {
        if (row != 0) try writer.writeByte('\n');
        try writeBoardRow(writer, rows, row, @intCast(row + 1), uses_pp);
    }
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn appendLazerTagFields(self: anytype, conn: *postgres.c.PGconn, writer: *std.Io.Writer, beatmap_id: i32, requester_id: ?i32) !void {
    var map_buf: [24]u8 = undefined;
    const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
    var top = try postgres.queryParams(self.allocator, conn, "SELECT tag_id,count(*) FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 GROUP BY tag_id ORDER BY count(*) DESC,tag_id LIMIT 20", &.{map});
    defer top.deinit();
    try writer.writeAll(",\"top_tag_ids\":[");
    for (0..top.rows()) |top_row| {
        if (top_row != 0) try writer.writeByte(',');
        try writer.print("{{\"tag_id\":{d},\"count\":{d}}}", .{ try top.int(i64, top_row, 0), try top.int(i64, top_row, 1) });
    }
    try writer.writeAll("],\"current_user_tag_ids\":[");
    if (requester_id) |user_id| {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var own = try postgres.queryParams(self.allocator, conn, "SELECT tag_id FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 AND user_id=$2 ORDER BY tag_id", &.{ map, user });
        defer own.deinit();
        for (0..own.rows()) |own_row| {
            if (own_row != 0) try writer.writeByte(',');
            try writer.print("{d}", .{try own.int(i64, own_row, 0)});
        }
    }
    try writer.writeByte(']');
}

pub fn appendLazerMap(self: anytype, conn: *postgres.c.PGconn, writer: *std.Io.Writer, result: postgres.Result, row: usize, requester_id: ?i32) !void {
    const creator_id = try result.int(i32, row, 20);
    try writer.print("{{\"id\":{d},\"beatmapset_id\":{d},\"status\":", .{ try result.int(i32, row, 0), try result.int(i32, row, 1) });
    try common.jsonString(writer, lazerStatus(try result.int(i32, row, 2)));
    try writer.writeAll(",\"checksum\":");
    try common.jsonString(writer, result.value(row, 3));
    try writer.print(",\"user_id\":{d},\"playcount\":{d},\"passcount\":{d},\"mode_int\":{d},\"difficulty_rating\":{d},\"drain\":{d},\"cs\":{d},\"ar\":{d},\"accuracy\":{d},\"total_length\":{d},\"hit_length\":{d},\"convert\":false,\"count_circles\":{d},\"count_sliders\":{d},\"count_spinners\":{d},\"version\":", .{ creator_id, try result.int(i64, row, 4), try result.int(i64, row, 5), try result.int(i32, row, 6), try result.float(f64, row, 7), try result.float(f64, row, 8), try result.float(f64, row, 9), try result.float(f64, row, 10), try result.float(f64, row, 11), try result.int(i32, row, 12), try result.int(i32, row, 22), try result.int(i32, row, 17), try result.int(i32, row, 18), try result.int(i32, row, 19) });
    try common.jsonString(writer, result.value(row, 13));
    try writer.print(",\"max_combo\":{d},\"last_updated\":", .{try result.int(i32, row, 14)});
    try common.jsonString(writer, result.value(row, 15));
    try writer.print(",\"bpm\":{d},\"owners\":[", .{try result.float(f64, row, 16)});
    if (creator_id > 0) {
        try writer.print("{{\"id\":{d},\"username\":", .{creator_id});
        try common.jsonString(writer, result.value(row, 21));
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    try appendLazerTagFields(self, conn, writer, try result.int(i32, row, 0), requester_id);
    try writer.writeByte('}');
}

pub fn appendLazerSet(self: anytype, conn: *postgres.c.PGconn, writer: *std.Io.Writer, set_id: i32, requester_id: ?i32) !bool {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var set_result = try postgres.queryParams(self.allocator, conn, "SELECT b.set_id,min(b.artist),min(b.title),coalesce(max(owner.name),min(b.creator)),min(b.status),max(b.bpm),min(b.source),min(b.tags),coalesce(max(m.submitted_date),coalesce(to_char(to_timestamp(max(b.last_update)) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),sum(b.plays),least((SELECT count(*) FROM zigcho.favourites f WHERE f.set_id=b.set_id),2147483647),coalesce(max(m.last_updated),coalesce(to_char(to_timestamp(max(b.last_update)) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),max(m.ranked_date),coalesce(bool_or(m.has_video),false),coalesce(max(m.genre_id),0),coalesce(max(m.language_id),0),coalesce(max(owner.id),max(b.creator_id),0) FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.set_id=$1 GROUP BY b.set_id", &.{set});
    defer set_result.deinit();
    if (set_result.rows() == 0) return false;
    try writer.print("{{\"id\":{d},\"status\":", .{set_id});
    try common.jsonString(writer, lazerStatus(try set_result.int(i32, 0, 4)));
    try writer.writeAll(",\"title\":");
    try common.jsonString(writer, set_result.value(0, 2));
    try writer.writeAll(",\"title_unicode\":");
    try common.jsonString(writer, set_result.value(0, 2));
    try writer.writeAll(",\"artist\":");
    try common.jsonString(writer, set_result.value(0, 1));
    try writer.writeAll(",\"artist_unicode\":");
    try common.jsonString(writer, set_result.value(0, 1));
    try writer.writeAll(",\"creator\":");
    try common.jsonString(writer, set_result.value(0, 3));
    const creator_id = try set_result.int(i32, 0, 16);
    try writer.print(",\"user_id\":{d},\"covers\":{{\"cover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover.jpg\",\"cover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover@2x.jpg\",\"card\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card.jpg\",\"card@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card@2x.jpg\",\"list\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list.jpg\",\"list@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list@2x.jpg\",\"slimcover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover.jpg\",\"slimcover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover@2x.jpg\"}},\"preview_url\":\"https://b.kai.ovh/preview/{d}.mp3\",\"play_count\":{d},\"favourite_count\":{d},\"bpm\":{d},\"nsfw\":false,\"spotlight\":false,\"video\":{s},\"storyboard\":false,\"submitted_date\":", .{ creator_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, try set_result.int(i64, 0, 9), try set_result.int(i32, 0, 10), try set_result.float(f64, 0, 5), if (try set_result.boolean(0, 13)) "true" else "false" });
    try common.jsonString(writer, set_result.value(0, 8));
    try writer.writeAll(",\"last_updated\":");
    try common.jsonString(writer, set_result.value(0, 11));
    try writer.writeAll(",\"ranked_date\":");
    if (set_result.isNull(0, 12)) try writer.writeAll("null") else try common.jsonString(writer, set_result.value(0, 12));
    const genre_id = try set_result.int(i16, 0, 14);
    const language_id = try set_result.int(i16, 0, 15);
    try writer.print(",\"ratings\":[],\"availability\":{{\"download_disabled\":false,\"more_information\":\"\"}},\"genre\":{{\"id\":{d},\"name\":", .{genre_id});
    try common.jsonString(writer, upstream_user.genreName(genre_id));
    try writer.print("}},\"language\":{{\"id\":{d},\"name\":", .{language_id});
    try common.jsonString(writer, upstream_user.languageName(language_id));
    try writer.writeAll("},\"source\":");
    try common.jsonString(writer, set_result.value(0, 6));
    try writer.writeAll(",\"tags\":");
    try common.jsonString(writer, set_result.value(0, 7));
    try writer.writeAll(",\"related_tags\":");
    try writer.writeAll(lazer.beatmap_tags_array_json);
    // The pinned APIBeatmapSet.user setter dereferences null. Search responses
    // intentionally omit detailed mapper data when it has not been cached.
    const local_profile_sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ common.visible_follower_count_sql ++ " FROM zigcho.beatmap_submissions submission JOIN zigcho.users u ON u.id=submission.owner_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE submission.set_id=$1 AND submission.state='published'";
    var local_profile = try postgres.queryParams(self.allocator, conn, local_profile_sql, &.{set});
    defer local_profile.deinit();
    if (local_profile.rows() != 0) {
        try writer.writeAll(",\"user\":");
        const local_user = try common.userFromResult(self.allocator, local_profile, 0);
        defer self.allocator.free(local_user.name);
        defer self.allocator.free(local_user.safe_name);
        try user_json.writeCompact(writer, local_user, local_user.show_country);
    } else if (creator_id > 0) {
        var creator_buf: [24]u8 = undefined;
        const creator = try std.fmt.bufPrint(&creator_buf, "{d}", .{creator_id});
        var profile = try postgres.queryParams(self.allocator, conn, "SELECT profile_json::text FROM zigcho.upstream_user_profiles WHERE user_id=$1 ORDER BY mode=0 DESC,mode LIMIT 1", &.{creator});
        defer profile.deinit();
        if (profile.rows() != 0) {
            try writer.writeAll(",\"user\":");
            try writer.writeAll(profile.value(0, 0));
        }
    }
    try writer.writeAll(",\"beatmaps\":[");
    var maps = try postgres.queryParams(self.allocator, conn, "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.set_id=$1 ORDER BY b.star_rating,b.id", &.{set});
    defer maps.deinit();
    for (0..maps.rows()) |row| {
        if (row != 0) try writer.writeByte(',');
        try appendLazerMap(self, conn, writer, maps, row, requester_id);
    }
    try writer.writeAll("]}");
    return true;
}

pub fn lazerBeatmapSet(self: anytype, allocator: std.mem.Allocator, set_id: i32, requester_id: ?i32) !?[]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (!try appendLazerSet(self, lease.conn, &output.writer, set_id, requester_id)) {
        output.deinit();
        return null;
    }
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn lazerBeatmapLookup(self: anytype, allocator: std.mem.Allocator, beatmap_id: ?i32, checksum: ?[]const u8, requester_id: ?i32) !?[]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var id_buf: [24]u8 = undefined;
    const value = checksum orelse try std.fmt.bufPrint(&id_buf, "{d}", .{beatmap_id orelse return null});
    const sql = if (checksum != null)
        "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.md5=$1"
    else
        "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.id=$1";
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{value});
    defer result.deinit();
    if (result.rows() == 0) return null;

    var map_output: std.Io.Writer.Allocating = .init(allocator);
    defer map_output.deinit();
    try appendLazerMap(self, lease.conn, &map_output.writer, result, 0, requester_id);
    const map_json = map_output.written();
    if (map_json.len == 0 or map_json[map_json.len - 1] != '}') return error.InvalidStoredBeatmap;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(map_json[0 .. map_json.len - 1]);
    try output.writer.writeAll(",\"beatmapset\":");
    if (!try appendLazerSet(self, lease.conn, &output.writer, try result.int(i32, 0, 1), requester_id)) return error.InvalidStoredBeatmap;
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn lazerBeatmapSearch(self: anytype, allocator: std.mem.Allocator, search_query: []const u8, mode: i8, offset: u16, requester_id: ?i32) ![]u8 {
    var mode_buf: [4]u8 = undefined;
    var offset_buf: [24]u8 = undefined;
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
    var lease = self.pool.acquire();
    defer lease.release();
    var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE ($1::int=-1 OR mode=$1::int) AND ($2='' OR strpos(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower($2))>0) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 50 OFFSET $3", &.{ mode_text, search_query, offset_text });
    defer ids.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"beatmapsets\":[");
    for (0..ids.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        _ = try appendLazerSet(self, lease.conn, &output.writer, try ids.int(i32, row, 0), requester_id);
    }
    const has_more = ids.rows() == 50;
    try output.writer.print("],\"total\":{d},\"cursor\":", .{@as(usize, offset) + ids.rows() + @intFromBool(has_more)});
    if (has_more) try output.writer.print("{{\"offset\":{d}}}", .{@as(usize, offset) + ids.rows()}) else try output.writer.writeAll("null");
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn lazerBeatmapSets(self: anytype, allocator: std.mem.Allocator, set_ids: []const i32, offset: u16, requester_id: ?i32) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"beatmapsets\":[");
    var count: usize = 0;
    for (set_ids) |set_id| {
        var set_output: std.Io.Writer.Allocating = .init(allocator);
        defer set_output.deinit();
        if (!try appendLazerSet(self, lease.conn, &set_output.writer, set_id, requester_id)) continue;
        if (count != 0) try output.writer.writeByte(',');
        try output.writer.writeAll(set_output.written());
        count += 1;
    }
    const has_more = set_ids.len == 50 and count == set_ids.len;
    try output.writer.print("],\"total\":{d},\"cursor\":", .{@as(usize, offset) + count + @intFromBool(has_more)});
    if (has_more) try output.writer.print("{{\"offset\":{d}}}", .{@as(usize, offset) + count}) else try output.writer.writeAll("null");
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn lazerOwnedBeatmapSearch(self: anytype, allocator: std.mem.Allocator, user_id: i32, query: []const u8, mode: i8, offset: u16, requester_id: ?i32) ![]u8 {
    var user_buf: [24]u8 = undefined;
    var mode_buf: [4]u8 = undefined;
    var offset_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
    var lease = self.pool.acquire();
    defer lease.release();
    var count = try postgres.queryParams(self.allocator, lease.conn, "SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=$1 AND submission.state='published' AND ($2::int=-1 OR b.mode=$2::int) AND ($3='' OR strpos(lower(b.artist||' '||b.title||' '||b.creator||' '||b.source||' '||b.tags),lower($3))>0) GROUP BY submission.set_id) owned", &.{ user, mode_text, query });
    defer count.deinit();
    const total: usize = @intCast(try count.int(i64, 0, 0));
    var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=$1 AND submission.state='published' AND ($2::int=-1 OR b.mode=$2::int) AND ($3='' OR strpos(lower(b.artist||' '||b.title||' '||b.creator||' '||b.source||' '||b.tags),lower($3))>0) GROUP BY submission.set_id,submission.updated_at ORDER BY submission.updated_at DESC,submission.set_id DESC LIMIT 50 OFFSET $4", &.{ user, mode_text, query, offset_text });
    defer ids.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"beatmapsets\":[");
    var written: usize = 0;
    for (0..ids.rows()) |row| {
        var set_output: std.Io.Writer.Allocating = .init(allocator);
        defer set_output.deinit();
        if (!try appendLazerSet(self, lease.conn, &set_output.writer, try ids.int(i32, row, 0), requester_id)) continue;
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try output.writer.writeAll(set_output.written());
    }
    const next_offset = @as(usize, offset) + ids.rows();
    try output.writer.print("],\"total\":{d},\"cursor\":", .{total});
    if (next_offset < total) try output.writer.print("{{\"offset\":{d}}}", .{next_offset}) else try output.writer.writeAll("null");
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub fn lazerUserBeatmapSetsJson(self: anytype, allocator: std.mem.Allocator, user_id: i32, kind: []const u8, offset: usize, limit: usize, requester_id: ?i32) ![]u8 {
    var user_buf: [24]u8 = undefined;
    var offset_buf: [24]u8 = undefined;
    var limit_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=$1 AND submission.state='published' GROUP BY submission.set_id,submission.updated_at HAVING $2='all' OR ($2='ranked' AND min(b.status) IN(3,4)) OR ($2='loved' AND min(b.status)=6) OR ($2='pending' AND min(b.status)=2) OR ($2='graveyard' AND min(b.status)=1) OR ($2='nominated' AND min(b.status)=5) ORDER BY submission.updated_at DESC,submission.set_id DESC LIMIT $3 OFFSET $4", &.{ user, kind, limit_text, offset_text });
    defer ids.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    for (0..ids.rows()) |row| {
        var set_output: std.Io.Writer.Allocating = .init(allocator);
        defer set_output.deinit();
        if (!try appendLazerSet(self, lease.conn, &set_output.writer, try ids.int(i32, row, 0), requester_id)) continue;
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try output.writer.writeAll(set_output.written());
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerMostPlayedJson(self: anytype, allocator: std.mem.Allocator, user_id: i32, requester_id: i32, offset: u16, limit: u8) ![]u8 {
    var user_buf: [24]u8 = undefined;
    var offset_buf: [24]u8 = undefined;
    var limit_buf: [8]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    var rows = try postgres.queryParams(self.allocator, lease.conn, "WITH plays AS (SELECT b.id beatmap_id,count(*) plays FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 GROUP BY b.id UNION ALL SELECT beatmap_id,count(*) FROM zigcho.lazer_scores WHERE user_id=$1 GROUP BY beatmap_id), totals AS (SELECT beatmap_id,sum(plays) plays FROM plays GROUP BY beatmap_id) SELECT beatmap_id,plays FROM totals ORDER BY plays DESC,beatmap_id LIMIT $2 OFFSET $3", &.{ user, limit_text, offset_text });
    defer rows.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    for (0..rows.rows()) |row| {
        const beatmap_id = try rows.int(i32, row, 0);
        var map_buf: [24]u8 = undefined;
        const map_id = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.id=$1", &.{map_id});
        defer map.deinit();
        if (map.rows() == 0) continue;
        var set: std.Io.Writer.Allocating = .init(allocator);
        defer set.deinit();
        if (!try appendLazerSet(self, lease.conn, &set.writer, try map.int(i32, 0, 1), requester_id)) continue;
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try output.writer.print("{{\"beatmap_id\":{d},\"count\":{d},\"beatmap\":", .{ beatmap_id, try rows.int(i64, row, 1) });
        try appendLazerMap(self, lease.conn, &output.writer, map, 0, requester_id);
        try output.writer.writeAll(",\"beatmapset\":");
        try output.writer.writeAll(set.written());
        try output.writer.writeByte('}');
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn favouriteSetIds(self: anytype, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT set_id FROM zigcho.favourites WHERE user_id=$1 ORDER BY created_at,set_id LIMIT 10000", &.{id});
    defer result.deinit();
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(allocator);
    for (0..result.rows()) |row| try list.append(allocator, try result.int(i32, row, 0));
    return list.toOwnedSlice(allocator);
}

pub fn addFavourite(self: anytype, user_id: i32, set_id: i32) !bool {
    if (set_id <= 0) return error.InvalidBeatmapSet;
    var user_buf: [24]u8 = undefined;
    var set_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.favourites(user_id,set_id) VALUES($1,$2) ON CONFLICT DO NOTHING RETURNING 1", &.{ user, set });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn removeFavourite(self: anytype, user_id: i32, set_id: i32) !bool {
    if (set_id <= 0) return error.InvalidBeatmapSet;
    var user_buf: [24]u8 = undefined;
    var set_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.favourites WHERE user_id=$1 AND set_id=$2 RETURNING 1", &.{ user, set });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn stableBeatmapInfo(self: anytype, user_id: i32, field: []const u8, by_id: bool) !?StableBeatmapInfo {
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = if (by_id)
        "SELECT id,set_id,md5,status FROM zigcho.beatmaps WHERE id=CAST($1 AS integer)"
    else
        "SELECT id,set_id,md5,status FROM zigcho.beatmaps WHERE artist || ' - ' || title || ' (' || creator || ') [' || version || '].osu'=$1";
    var map = try postgres.queryParams(self.allocator, lease.conn, sql, &.{field});
    defer map.deinit();
    if (map.rows() == 0) return null;
    const md5_text = map.value(0, 2);
    if (md5_text.len != 32) return error.InvalidBeatmapChecksum;
    const db_status = try map.int(i32, 0, 3);
    var info: StableBeatmapInfo = .{
        .id = try map.int(i32, 0, 0),
        .set_id = try map.int(i32, 0, 1),
        .md5 = undefined,
        .status = switch (stableStatus(db_status)) {
            0 => 0,
            2 => 1,
            3 => 2,
            4 => 3,
            5 => 4,
            else => 0,
        },
        .grades = .{ "N", "N", "N", "N" },
    };
    @memcpy(&info.md5, md5_text);
    var scores = try postgres.queryParams(self.allocator, lease.conn, "SELECT mode,mods,accuracy,n300,n100,n50,nmiss FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND rank_namespace='vanilla' AND passed AND best AND mode BETWEEN 0 AND 3", &.{ user, md5_text });
    defer scores.deinit();
    for (0..scores.rows()) |row| {
        const mode = try scores.int(u8, row, 0);
        info.grades[mode] = storage_contracts.stableGrade(mode, try scores.int(i32, row, 1), try scores.float(f64, row, 2), try scores.int(i32, row, 3), try scores.int(i32, row, 4), try scores.int(i32, row, 5), try scores.int(i32, row, 6));
    }
    return info;
}

pub fn stableBeatmapInfoByFilename(self: anytype, user_id: i32, filename: []const u8) !?StableBeatmapInfo {
    return stableBeatmapInfo(self, user_id, filename, false);
}

pub fn stableBeatmapInfoById(self: anytype, user_id: i32, map_id: i32) !?StableBeatmapInfo {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
    return stableBeatmapInfo(self, user_id, id, true);
}

pub fn addBeatmapComment(self: anytype, user_id: i32, target_type: []const u8, target_id: i64, time: f64, comment: []const u8, colour: ?[]const u8) !void {
    var user_buf: [24]u8 = undefined;
    var target_buf: [32]u8 = undefined;
    var time_buf: [64]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
    const time_text = try std.fmt.bufPrint(&time_buf, "{d}", .{time});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = if (colour) |value|
        try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_comments(target_id,target_type,user_id,time,comment,colour) VALUES($1,$2,$3,$4,$5,$6)", &.{ target, target_type, user, time_text, comment, value })
    else
        try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_comments(target_id,target_type,user_id,time,comment) VALUES($1,$2,$3,$4,$5)", &.{ target, target_type, user, time_text, comment });
    result.deinit();
}

pub fn beatmapComments(self: anytype, allocator: std.mem.Allocator, score_id: i64, set_id: i32, map_id: i32) ![]u8 {
    var score_buf: [32]u8 = undefined;
    var set_buf: [24]u8 = undefined;
    var map_buf: [24]u8 = undefined;
    const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const map_id_text = try std.fmt.bufPrint(&map_buf, "{d}", .{map_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT c.time,c.target_type,u.privileges,c.colour,c.comment FROM zigcho.beatmap_comments c JOIN zigcho.users u ON u.id=c.user_id WHERE (c.target_type='replay' AND c.target_id=$1) OR (c.target_type='song' AND c.target_id=$2) OR (c.target_type='map' AND c.target_id=$3) ORDER BY c.id LIMIT 1000", &.{ score, set, map_id_text });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte('\n');
        const privileges = try result.int(u32, row, 2);
        const format = if (privileges & (1 << 11) != 0) "bat" else if (privileges & (1 << 4) != 0) "supporter" else "";
        try output.writer.print("{d}\t{s}\t{s}", .{ try result.float(f64, row, 0), result.value(row, 1), format });
        if (!result.isNull(row, 3)) try output.writer.print("|{s}", .{result.value(row, 3)});
        try output.writer.print("\t{s}", .{result.value(row, 4)});
    }
    return output.toOwnedSlice();
}

pub fn addLazerComment(self: anytype, user_id: i32, target: LazerCommentTarget, parent_id: ?i64, message: []const u8) !i64 {
    if (message.len == 0 or message.len > 1000 or !std.unicode.utf8ValidateSlice(message)) return error.InvalidComment;
    var user_buf: [24]u8 = undefined;
    var target_buf: [32]u8 = undefined;
    var parent_buf: [32]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const target_id = try std.fmt.bufPrint(&target_buf, "{d}", .{target.id});
    const parent = if (parent_id) |value| try std.fmt.bufPrint(&parent_buf, "{d}", .{value}) else null;
    var lease = self.pool.acquire();
    defer lease.release();
    if (parent) |parent_text| {
        var check = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.lazer_comments WHERE id=$1 AND commentable_type=$2 AND commentable_id=$3 AND deleted_at IS NULL", &.{ parent_text, target.commentable.text(), target_id });
        defer check.deinit();
        if (check.rows() == 0) return error.CommentParentNotFound;
    }
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_comments(commentable_type,commentable_id,user_id,parent_id,message) VALUES($1,$2,$3,$4,$5) RETURNING id", &.{ target.commentable.text(), target_id, user, parent, message });
    defer result.deinit();
    return try result.int(i64, 0, 0);
}

pub fn lazerCommentTarget(self: anytype, comment_id: i64) !?LazerCommentTarget {
    var id_buf: [32]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{comment_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT commentable_type,commentable_id FROM zigcho.lazer_comments WHERE id=$1", &.{id});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return .{ .commentable = LazerCommentable.parse(result.value(0, 0)) orelse return error.InvalidStoredComment, .id = try result.int(i64, 0, 1) };
}

pub fn deleteLazerComment(self: anytype, user_id: i32, comment_id: i64, staff: bool) !bool {
    var user_buf: [24]u8 = undefined;
    var id_buf: [32]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{comment_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, if (staff)
        "UPDATE zigcho.lazer_comments SET message='',deleted_at=extract(epoch FROM clock_timestamp())::bigint,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$1 AND deleted_at IS NULL RETURNING 1"
    else
        "UPDATE zigcho.lazer_comments SET message='',deleted_at=extract(epoch FROM clock_timestamp())::bigint,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL RETURNING 1", if (staff) &.{id} else &.{ id, user });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn setLazerCommentVote(self: anytype, user_id: i32, comment_id: i64, voted: bool) !bool {
    var user_buf: [24]u8 = undefined;
    var id_buf: [32]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{comment_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, if (voted)
        "INSERT INTO zigcho.lazer_comment_votes(comment_id,user_id) SELECT $1,$2 WHERE EXISTS(SELECT 1 FROM zigcho.lazer_comments WHERE id=$1 AND deleted_at IS NULL) ON CONFLICT DO NOTHING RETURNING 1"
    else
        "DELETE FROM zigcho.lazer_comment_votes WHERE comment_id=$1 AND user_id=$2 RETURNING 1", &.{ id, user });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn reportLazerComment(self: anytype, user_id: i32, comment_id: i64, reason: []const u8, comments: []const u8) !bool {
    var user_buf: [24]u8 = undefined;
    var id_buf: [32]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{comment_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_comment_reports(comment_id,reporter_id,reason,comments) SELECT $1,$2,$3,$4 WHERE EXISTS(SELECT 1 FROM zigcho.lazer_comments WHERE id=$1) ON CONFLICT DO NOTHING RETURNING 1", &.{ id, user, reason, comments });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn addLazerReport(self: anytype, reporter_id: i32, reportable_type: []const u8, reportable_id: i64, reason: []const u8, comments: []const u8) !bool {
    var reporter_buf: [24]u8 = undefined;
    var target_buf: [24]u8 = undefined;
    const reporter = try std.fmt.bufPrint(&reporter_buf, "{d}", .{reporter_id});
    const target = try std.fmt.bufPrint(&target_buf, "{d}", .{reportable_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_reports(reporter_id,reportable_type,reportable_id,reason,comments) VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING RETURNING id", &.{ reporter, reportable_type, target, reason, comments });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn lazerMessageExists(self: anytype, message_id: i64) !bool {
    if (message_id <= 0) return false;
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{message_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT EXISTS(SELECT 1 FROM zigcho.chat_messages WHERE id=$1) OR EXISTS(SELECT 1 FROM zigcho.direct_messages WHERE id=$1)", &.{id});
    defer result.deinit();
    return try result.boolean(0, 0);
}

pub fn staffLazerReportsJson(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT r.id,r.reporter_id,reporter.name,reporter.country,r.reportable_type,r.reportable_id," ++
        "CASE r.reportable_type WHEN 'user' THEN coalesce((SELECT name FROM zigcho.users WHERE id=r.reportable_id::integer),'missing user') " ++
        "WHEN 'message' THEN left(coalesce((SELECT message FROM zigcho.chat_messages WHERE id=r.reportable_id),(SELECT message FROM zigcho.direct_messages WHERE id=r.reportable_id),'missing message'),180) " ++
        "ELSE left(coalesce((SELECT message FROM zigcho.lazer_comments WHERE id=r.reportable_id),'missing comment'),180) END," ++
        "r.reason,r.comments,r.status,r.created_at,coalesce(r.resolved_at,0),coalesce(resolver.name,'') " ++
        "FROM zigcho.lazer_reports r JOIN zigcho.users reporter ON reporter.id=r.reporter_id LEFT JOIN zigcho.users resolver ON resolver.id=r.resolver_id " ++
        "ORDER BY CASE r.status WHEN 'open' THEN 0 ELSE 1 END,r.created_at DESC,r.id DESC LIMIT 300");
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"reports\":[");
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"reporter_id\":{d},\"reporter\":", .{ try result.int(i64, row, 0), try result.int(i32, row, 1) });
        try common.jsonString(&output.writer, result.value(row, 2));
        try output.writer.writeAll(",\"country\":");
        try common.jsonString(&output.writer, result.value(row, 3));
        try output.writer.writeAll(",\"reportable_type\":");
        try common.jsonString(&output.writer, result.value(row, 4));
        try output.writer.print(",\"reportable_id\":{d},\"target\":", .{try result.int(i64, row, 5)});
        try common.jsonString(&output.writer, result.value(row, 6));
        try output.writer.writeAll(",\"reason\":");
        try common.jsonString(&output.writer, result.value(row, 7));
        try output.writer.writeAll(",\"comments\":");
        try common.jsonString(&output.writer, result.value(row, 8));
        try output.writer.writeAll(",\"status\":");
        try common.jsonString(&output.writer, result.value(row, 9));
        try output.writer.print(",\"created_at\":{d},\"resolved_at\":{d},\"resolver\":", .{ try result.int(i64, row, 10), try result.int(i64, row, 11) });
        try common.jsonString(&output.writer, result.value(row, 12));
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn resolveLazerReport(self: anytype, actor_id: i32, report_id: i64, decision: []const u8) !bool {
    if (!std.mem.eql(u8, decision, "resolved") and !std.mem.eql(u8, decision, "dismissed")) return error.InvalidReportDecision;
    var actor_buf: [24]u8 = undefined;
    var id_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{report_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.lazer_reports SET status=$1,resolved_at=extract(epoch FROM clock_timestamp())::bigint,resolver_id=$2 WHERE id=$3 AND status='open' RETURNING reporter_id", &.{ decision, actor, id });
    defer result.deinit();
    if (result.rows() == 0) {
        try postgres.exec(lease.conn, "ROLLBACK");
        return false;
    }
    var detail_buf: [128]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "report_id={d} decision={s}", .{ report_id, decision });
    try common.insertAudit(self.allocator, lease.conn, actor_id, "lazer.report_review", try result.int(i32, 0, 0), detail);
    try postgres.exec(lease.conn, "COMMIT");
    return true;
}

pub fn setLazerBeatmapTag(self: anytype, user_id: i32, beatmap_id: i32, tag_id: i64, selected: bool) !bool {
    if (!lazer.validBeatmapTagId(tag_id) or beatmap_id <= 0 or user_id <= 0) return error.InvalidBeatmapTag;
    var user_buf: [24]u8 = undefined;
    var map_buf: [24]u8 = undefined;
    var tag_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
    const tag = try std.fmt.bufPrint(&tag_buf, "{d}", .{tag_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE id=$1", &.{map});
    defer exists.deinit();
    if (exists.rows() == 0) return error.BeatmapNotFound;
    var result = try postgres.queryParams(self.allocator, lease.conn, if (selected)
        "INSERT INTO zigcho.beatmap_tag_votes(beatmap_id,user_id,tag_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING 1"
    else
        "DELETE FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 AND user_id=$2 AND tag_id=$3 RETURNING 1", &.{ map, user, tag });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn lazerBeatmapTagStateJson(self: anytype, allocator: std.mem.Allocator, user_id: i32, beatmap_id: i32) !?[]u8 {
    var user_buf: [24]u8 = undefined;
    var map_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE id=$1", &.{map});
    defer exists.deinit();
    if (exists.rows() == 0) return null;
    var top = try postgres.queryParams(self.allocator, lease.conn, "SELECT tag_id,count(*) FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 GROUP BY tag_id ORDER BY count(*) DESC,tag_id LIMIT 20", &.{map});
    defer top.deinit();
    var own = try postgres.queryParams(self.allocator, lease.conn, "SELECT tag_id FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 AND user_id=$2 ORDER BY tag_id", &.{ map, user });
    defer own.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"top_tag_ids\":[");
    for (0..top.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"tag_id\":{d},\"count\":{d}}}", .{ try top.int(i64, row, 0), try top.int(i64, row, 1) });
    }
    try output.writer.writeAll("],\"current_user_tag_ids\":[");
    for (0..own.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{d}", .{try own.int(i64, row, 0)});
    }
    try output.writer.writeAll("]}");
    return @as(?[]u8, try output.toOwnedSlice());
}

pub fn lazerCommentsJson(self: anytype, allocator: std.mem.Allocator, viewer_id: i32, target: LazerCommentTarget, sort: LazerCommentSort, page: u16, parent_id: i64, only_id: i64) ![]u8 {
    if (page == 0 or page > 1000 or parent_id < 0 or only_id < 0) return error.InvalidCommentQuery;
    var target_buf: [32]u8 = undefined;
    var parent_buf: [32]u8 = undefined;
    var only_buf: [32]u8 = undefined;
    var viewer_buf: [24]u8 = undefined;
    var offset_buf: [32]u8 = undefined;
    const target_id = try std.fmt.bufPrint(&target_buf, "{d}", .{target.id});
    const parent = try std.fmt.bufPrint(&parent_buf, "{d}", .{parent_id});
    const only = try std.fmt.bufPrint(&only_buf, "{d}", .{only_id});
    const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
    const offset = try std.fmt.bufPrint(&offset_buf, "{d}", .{(@as(i64, page) - 1) * 50});
    const base_sql = "SELECT c.id,c.parent_id,c.user_id,c.message,to_char(to_timestamp(c.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),to_char(to_timestamp(c.updated_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),CASE WHEN c.deleted_at IS NULL THEN NULL ELSE to_char(to_timestamp(c.deleted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') END,(SELECT count(*) FROM zigcho.lazer_comments r WHERE r.parent_id=c.id),(SELECT count(*) FROM zigcho.lazer_comment_votes v WHERE v.comment_id=c.id),EXISTS(SELECT 1 FROM zigcho.lazer_comment_votes v WHERE v.comment_id=c.id AND v.user_id=$5) FROM zigcho.lazer_comments c JOIN zigcho.users u ON u.id=c.user_id WHERE c.commentable_type=$1 AND c.commentable_id=$2 AND NOT u.restricted AND (($4::bigint>0 AND c.id=$4::bigint) OR ($4::bigint=0 AND (($3::bigint>0 AND c.parent_id=$3::bigint) OR ($3::bigint=0 AND c.parent_id IS NULL))))";
    const sql = switch (sort) {
        .new => base_sql ++ " ORDER BY c.created_at DESC,c.id DESC LIMIT 51 OFFSET $6::int",
        .old => base_sql ++ " ORDER BY c.created_at ASC,c.id ASC LIMIT 51 OFFSET $6::int",
        .top => base_sql ++ " ORDER BY (SELECT count(*) FROM zigcho.lazer_comment_votes v WHERE v.comment_id=c.id) DESC,c.created_at DESC,c.id DESC LIMIT 51 OFFSET $6::int",
    };
    var lease = self.pool.acquire();
    defer lease.release();
    var rows = try postgres.queryParams(allocator, lease.conn, sql, &.{ target.commentable.text(), target_id, parent, only, viewer, offset });
    defer rows.deinit();
    var count = try postgres.queryParams(allocator, lease.conn, "SELECT count(*),count(*) FILTER(WHERE parent_id IS NULL) FROM zigcho.lazer_comments WHERE commentable_type=$1 AND commentable_id=$2", &.{ target.commentable.text(), target_id });
    defer count.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"commentable_meta\":[{{\"id\":{d},\"owner_id\":null,\"owner_title\":null,\"title\":", .{target.id});
    var title_buf: [96]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "{s} #{d}", .{ target.commentable.text(), target.id });
    try common.jsonString(&output.writer, title);
    try output.writer.writeAll(",\"type\":");
    try common.jsonString(&output.writer, target.commentable.text());
    try output.writer.writeAll(",\"url\":");
    var url_buf: [128]u8 = undefined;
    const url = if (target.commentable == .beatmapset) try std.fmt.bufPrint(&url_buf, "https://kai.ovh/beatmapsets/{d}", .{target.id}) else try std.fmt.bufPrint(&url_buf, "https://kai.ovh/", .{});
    try common.jsonString(&output.writer, url);
    try output.writer.writeAll(",\"current_user_attributes\":{\"can_new_comment_reason\":null}}],\"comments\":[");
    const visible_rows = @min(rows.rows(), 50);
    var user_ids: std.ArrayList(i32) = .empty;
    defer user_ids.deinit(allocator);
    var voted_ids: std.ArrayList(i64) = .empty;
    defer voted_ids.deinit(allocator);
    for (0..visible_rows) |row| {
        if (row != 0) try output.writer.writeByte(',');
        const comment_id = try rows.int(i64, row, 0);
        const user_id = try rows.int(i32, row, 2);
        if (std.mem.indexOfScalar(i32, user_ids.items, user_id) == null) try user_ids.append(allocator, user_id);
        if (try rows.boolean(row, 9)) try voted_ids.append(allocator, comment_id);
        try output.writer.print("{{\"id\":{d},\"parent_id\":", .{comment_id});
        if (rows.isNull(row, 1)) try output.writer.writeAll("null") else try output.writer.print("{d}", .{try rows.int(i64, row, 1)});
        try output.writer.print(",\"user_id\":{d},\"message\":", .{user_id});
        try common.jsonString(&output.writer, rows.value(row, 3));
        try output.writer.print(",\"message_html\":null,\"replies_count\":{d},\"votes_count\":{d},\"commentable_type\":", .{ try rows.int(i32, row, 7), try rows.int(i32, row, 8) });
        try common.jsonString(&output.writer, target.commentable.text());
        try output.writer.print(",\"commentable_id\":{d},\"legacy_name\":null,\"created_at\":", .{target.id});
        try common.jsonString(&output.writer, rows.value(row, 4));
        try output.writer.writeAll(",\"updated_at\":");
        try common.jsonString(&output.writer, rows.value(row, 5));
        try output.writer.writeAll(",\"deleted_at\":");
        if (rows.isNull(row, 6)) try output.writer.writeAll("null") else try common.jsonString(&output.writer, rows.value(row, 6));
        try output.writer.writeAll(",\"edited_at\":null,\"edited_by_id\":null,\"pinned\":false}");
    }
    try output.writer.print("],\"has_more\":{},\"has_more_id\":null,\"user_follow\":false,\"included_comments\":[],\"pinned_comments\":[],\"user_votes\":[", .{rows.rows() > 50});
    for (voted_ids.items, 0..) |id, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{d}", .{id});
    }
    try output.writer.writeAll("],\"users\":[");
    for (user_ids.items, 0..) |id, index| {
        var id_buf: [24]u8 = undefined;
        const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
        const user_sql = "SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,u.restricted," ++ common.visible_follower_count_sql ++ " FROM zigcho.users u WHERE u.id=$1";
        var user_row = try postgres.queryParams(allocator, lease.conn, user_sql, &.{id_text});
        defer user_row.deinit();
        if (user_row.rows() == 0) continue;
        if (index != 0) try output.writer.writeByte(',');
        const country = user_row.value(0, 2);
        const user_value: domain.User = .{ .id = id, .name = user_row.value(0, 1), .safe_name = "", .country = .{ country[0], country[1] }, .privileges = try user_row.int(u32, 0, 3), .restricted = try user_row.boolean(0, 4), .follower_count = try user_row.int(i32, 0, 5) };
        try user_json.writeCompact(&output.writer, user_value, true);
    }
    try output.writer.print("],\"total\":{d},\"top_level_count\":{d}}}", .{ try count.int(i32, 0, 0), try count.int(i32, 0, 1) });
    return output.toOwnedSlice();
}
