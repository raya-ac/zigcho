const std = @import("std");
const domain = @import("../../../domain.zig");
const lazer = @import("../../../lazer.zig");
const user_json = @import("../../../user_json.zig");
const upstream_user = @import("../../../upstream_user.zig");
const visible_follower_count_sql = @import("../../../storage.zig").visible_follower_count_sql;
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const lazerStatus = @import("../../contracts.zig").lazerStatus;

pub fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

pub fn appendLazerTagFields(self: *Store, writer: *std.Io.Writer, beatmap_id: i32, requester_id: ?i32) !void {
    try writer.writeAll(",\"top_tag_ids\":[");
    var top: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT tag_id,count(*) FROM beatmap_tag_votes WHERE beatmap_id=?1 GROUP BY tag_id ORDER BY count(*) DESC,tag_id LIMIT 20", -1, &top, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(top);
    _ = c.sqlite3_bind_int(top, 1, beatmap_id);
    var first = true;
    while (c.sqlite3_step(top) == c.SQLITE_ROW) {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"tag_id\":{d},\"count\":{d}}}", .{ c.sqlite3_column_int64(top, 0), c.sqlite3_column_int(top, 1) });
    }
    try writer.writeAll("],\"current_user_tag_ids\":[");
    if (requester_id) |user_id| {
        var own: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT tag_id FROM beatmap_tag_votes WHERE beatmap_id=?1 AND user_id=?2 ORDER BY tag_id", -1, &own, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(own);
        _ = c.sqlite3_bind_int(own, 1, beatmap_id);
        _ = c.sqlite3_bind_int(own, 2, user_id);
        first = true;
        while (c.sqlite3_step(own) == c.SQLITE_ROW) {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{d}", .{c.sqlite3_column_int64(own, 0)});
        }
    }
    try writer.writeByte(']');
}

pub fn appendLazerMap(self: *Store, writer: *std.Io.Writer, stmt: *c.sqlite3_stmt, requester_id: ?i32) !void {
    const creator_id = c.sqlite3_column_int(stmt, 20);
    try writer.print("{{\"id\":{d},\"beatmapset_id\":{d},\"status\":", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int(stmt, 1) });
    try jsonString(writer, lazerStatus(c.sqlite3_column_int(stmt, 2)));
    try writer.writeAll(",\"checksum\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
    try writer.print(",\"user_id\":{d},\"playcount\":{d},\"passcount\":{d},\"mode_int\":{d},\"difficulty_rating\":{d},\"drain\":{d},\"cs\":{d},\"ar\":{d},\"accuracy\":{d},\"total_length\":{d},\"hit_length\":{d},\"convert\":false,\"count_circles\":{d},\"count_sliders\":{d},\"count_spinners\":{d},\"version\":", .{ creator_id, c.sqlite3_column_int64(stmt, 4), c.sqlite3_column_int64(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_double(stmt, 7), c.sqlite3_column_double(stmt, 8), c.sqlite3_column_double(stmt, 9), c.sqlite3_column_double(stmt, 10), c.sqlite3_column_double(stmt, 11), c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 22), c.sqlite3_column_int(stmt, 17), c.sqlite3_column_int(stmt, 18), c.sqlite3_column_int(stmt, 19) });
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 13)));
    try writer.print(",\"max_combo\":{d},\"last_updated\":", .{c.sqlite3_column_int(stmt, 14)});
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 15)));
    try writer.print(",\"bpm\":{d},\"owners\":[", .{c.sqlite3_column_double(stmt, 16)});
    if (creator_id > 0) {
        try writer.print("{{\"id\":{d},\"username\":", .{creator_id});
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 21)));
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    try self.appendLazerTagFields(writer, c.sqlite3_column_int(stmt, 0), requester_id);
    try writer.writeByte('}');
}

pub fn appendLazerSet(self: *Store, writer: *std.Io.Writer, set_id: i32, requester_id: ?i32) !bool {
    const set_sql = "SELECT b.set_id,min(b.artist),min(b.title),coalesce(max(owner.name),min(b.creator)),min(b.status),max(b.bpm),min(b.source),min(b.tags),coalesce(max(m.submitted_date),coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',max(b.last_update),'unixepoch'),'1970-01-01T00:00:00Z')),sum(b.plays),min((SELECT count(*) FROM favourites f WHERE f.set_id=b.set_id),2147483647),coalesce(max(m.last_updated),coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',max(b.last_update),'unixepoch'),'1970-01-01T00:00:00Z')),max(m.ranked_date),coalesce(max(m.has_video),0),coalesce(max(m.genre_id),0),coalesce(max(m.language_id),0),coalesce(max(owner.id),max(b.creator_id),0) FROM beatmaps b LEFT JOIN beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN users owner ON owner.id=submission.owner_id WHERE b.set_id=?1 GROUP BY b.set_id";
    var set_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(set_stmt);
    _ = c.sqlite3_bind_int(set_stmt, 1, set_id);
    if (c.sqlite3_step(set_stmt) != c.SQLITE_ROW) return false;
    try writer.print("{{\"id\":{d},\"status\":", .{set_id});
    try jsonString(writer, lazerStatus(c.sqlite3_column_int(set_stmt, 4)));
    try writer.writeAll(",\"title\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
    try writer.writeAll(",\"title_unicode\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
    try writer.writeAll(",\"artist\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
    try writer.writeAll(",\"artist_unicode\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
    try writer.writeAll(",\"creator\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 3)));
    const creator_id = c.sqlite3_column_int(set_stmt, 16);
    try writer.print(",\"user_id\":{d},\"covers\":{{\"cover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover.jpg\",\"cover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover@2x.jpg\",\"card\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card.jpg\",\"card@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card@2x.jpg\",\"list\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list.jpg\",\"list@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list@2x.jpg\",\"slimcover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover.jpg\",\"slimcover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover@2x.jpg\"}},\"preview_url\":\"https://b.kai.ovh/preview/{d}.mp3\",\"play_count\":{d},\"favourite_count\":{d},\"bpm\":{d},\"nsfw\":false,\"spotlight\":false,\"video\":{s},\"storyboard\":false,\"submitted_date\":", .{ creator_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, c.sqlite3_column_int64(set_stmt, 9), c.sqlite3_column_int(set_stmt, 10), c.sqlite3_column_double(set_stmt, 5), if (c.sqlite3_column_int(set_stmt, 13) != 0) "true" else "false" });
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 8)));
    try writer.writeAll(",\"last_updated\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 11)));
    try writer.writeAll(",\"ranked_date\":");
    if (c.sqlite3_column_type(set_stmt, 12) == c.SQLITE_NULL) try writer.writeAll("null") else try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 12)));
    const genre_id: i16 = @intCast(c.sqlite3_column_int(set_stmt, 14));
    const language_id: i16 = @intCast(c.sqlite3_column_int(set_stmt, 15));
    try writer.print(",\"ratings\":[],\"availability\":{{\"download_disabled\":false,\"more_information\":\"\"}},\"genre\":{{\"id\":{d},\"name\":", .{genre_id});
    try jsonString(writer, upstream_user.genreName(genre_id));
    try writer.print("}},\"language\":{{\"id\":{d},\"name\":", .{language_id});
    try jsonString(writer, upstream_user.languageName(language_id));
    try writer.writeAll("},\"source\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 6)));
    try writer.writeAll(",\"tags\":");
    try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 7)));
    try writer.writeAll(",\"related_tags\":");
    try writer.writeAll(lazer.beatmap_tags_array_json);
    // The pinned APIBeatmapSet.user setter dereferences null. Search responses
    // intentionally omit detailed mapper data when it has not been cached.
    var local_profile_stmt: ?*c.sqlite3_stmt = null;
    defer _ = c.sqlite3_finalize(local_profile_stmt);
    const local_profile_sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ " FROM beatmap_submissions submission JOIN users u ON u.id=submission.owner_id LEFT JOIN team_members tm ON tm.user_id=u.id LEFT JOIN teams t ON t.id=tm.team_id WHERE submission.set_id=?1 AND submission.state='published'";
    if (c.sqlite3_prepare_v2(self.db, local_profile_sql, -1, &local_profile_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    _ = c.sqlite3_bind_int(local_profile_stmt, 1, set_id);
    const has_local_profile = c.sqlite3_step(local_profile_stmt) == c.SQLITE_ROW;
    var profile_stmt: ?*c.sqlite3_stmt = null;
    defer _ = c.sqlite3_finalize(profile_stmt);
    if (has_local_profile) {
        try writer.writeAll(",\"user\":");
        const country = std.mem.span(c.sqlite3_column_text(local_profile_stmt, 3));
        if (country.len != 2) return error.InvalidCountry;
        const local_user: domain.User = .{
            .id = c.sqlite3_column_int(local_profile_stmt, 0),
            .name = std.mem.span(c.sqlite3_column_text(local_profile_stmt, 1)),
            .safe_name = std.mem.span(c.sqlite3_column_text(local_profile_stmt, 2)),
            .country = .{ country[0], country[1] },
            .show_country = c.sqlite3_column_int(local_profile_stmt, 12) != 0,
            .privileges = @intCast(c.sqlite3_column_int64(local_profile_stmt, 4)),
            .silence_end = c.sqlite3_column_int64(local_profile_stmt, 5),
            .restricted = c.sqlite3_column_int(local_profile_stmt, 6) != 0,
            .follower_count = c.sqlite3_column_int(local_profile_stmt, 13),
            .banner_version = c.sqlite3_column_int64(local_profile_stmt, 7),
            .team = if (c.sqlite3_column_type(local_profile_stmt, 8) == c.SQLITE_NULL) null else try domain.TeamSummary.init(c.sqlite3_column_int(local_profile_stmt, 8), std.mem.span(c.sqlite3_column_text(local_profile_stmt, 9)), std.mem.span(c.sqlite3_column_text(local_profile_stmt, 10)), c.sqlite3_column_int64(local_profile_stmt, 11)),
        };
        try user_json.writeCompact(writer, local_user, local_user.show_country);
    } else if (creator_id > 0) {
        if (c.sqlite3_prepare_v2(self.db, "SELECT profile_json FROM upstream_user_profiles WHERE user_id=?1 ORDER BY mode=0 DESC,mode LIMIT 1", -1, &profile_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(profile_stmt, 1, creator_id);
        if (c.sqlite3_step(profile_stmt) == c.SQLITE_ROW) {
            try writer.writeAll(",\"user\":");
            try writer.writeAll(std.mem.span(c.sqlite3_column_text(profile_stmt, 0)));
        }
    }
    try writer.writeAll(",\"beatmaps\":[");
    const maps_sql = "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',b.last_update,'unixepoch'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM beatmaps b LEFT JOIN beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN users owner ON owner.id=submission.owner_id WHERE b.set_id=?1 ORDER BY b.star_rating,b.id";
    var maps_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, maps_sql, -1, &maps_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(maps_stmt);
    _ = c.sqlite3_bind_int(maps_stmt, 1, set_id);
    var first = true;
    while (c.sqlite3_step(maps_stmt) == c.SQLITE_ROW) {
        if (!first) try writer.writeByte(',');
        first = false;
        try self.appendLazerMap(writer, maps_stmt.?, requester_id);
    }
    try writer.writeAll("]}");
    return true;
}

pub fn lazerBeatmapSet(self: *Store, allocator: std.mem.Allocator, set_id: i32, requester_id: ?i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (!try self.appendLazerSet(&output.writer, set_id, requester_id)) {
        output.deinit();
        return null;
    }
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn lazerBeatmapLookup(self: *Store, allocator: std.mem.Allocator, beatmap_id: ?i32, checksum: ?[]const u8, requester_id: ?i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = if (checksum != null)
        "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',b.last_update,'unixepoch'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM beatmaps b LEFT JOIN beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN users owner ON owner.id=submission.owner_id WHERE b.md5=?1"
    else
        "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',b.last_update,'unixepoch'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM beatmaps b LEFT JOIN beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN users owner ON owner.id=submission.owner_id WHERE b.id=?1";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (checksum) |hash| {
        _ = c.sqlite3_bind_text(stmt, 1, hash.ptr, @intCast(hash.len), null);
    } else {
        _ = c.sqlite3_bind_int(stmt, 1, beatmap_id orelse return null);
    }
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

    var map_output: std.Io.Writer.Allocating = .init(allocator);
    defer map_output.deinit();
    try self.appendLazerMap(&map_output.writer, stmt.?, requester_id);
    const map_json = map_output.written();
    if (map_json.len == 0 or map_json[map_json.len - 1] != '}') return error.InvalidStoredBeatmap;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(map_json[0 .. map_json.len - 1]);
    try output.writer.writeAll(",\"beatmapset\":");
    if (!try self.appendLazerSet(&output.writer, c.sqlite3_column_int(stmt, 1), requester_id)) return error.InvalidStoredBeatmap;
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn lazerBeatmapSearch(self: *Store, allocator: std.mem.Allocator, query: []const u8, mode: i8, offset: u16, requester_id: ?i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const ids_sql = "SELECT set_id FROM beatmaps WHERE (?1=-1 OR mode=?1) AND (?2='' OR instr(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower(?2))>0) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 50 OFFSET ?3";
    var ids_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, ids_sql, -1, &ids_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(ids_stmt);
    _ = c.sqlite3_bind_int(ids_stmt, 1, mode);
    _ = c.sqlite3_bind_text(ids_stmt, 2, query.ptr, @intCast(query.len), null);
    _ = c.sqlite3_bind_int64(ids_stmt, 3, offset);
    var ids: [50]i32 = undefined;
    var count: usize = 0;
    while (count < ids.len and c.sqlite3_step(ids_stmt) == c.SQLITE_ROW) : (count += 1) ids[count] = c.sqlite3_column_int(ids_stmt, 0);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"beatmapsets\":[");
    for (ids[0..count], 0..) |set_id, index| {
        if (index != 0) try output.writer.writeByte(',');
        _ = try self.appendLazerSet(&output.writer, set_id, requester_id);
    }
    const has_more = count == ids.len;
    try output.writer.print("],\"total\":{d},\"cursor\":", .{@as(usize, offset) + count + @intFromBool(has_more)});
    if (has_more) try output.writer.print("{{\"offset\":{d}}}", .{@as(usize, offset) + count}) else try output.writer.writeAll("null");
    try output.writer.writeByte('}');
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn lazerBeatmapSets(self: *Store, allocator: std.mem.Allocator, set_ids: []const i32, offset: u16, requester_id: ?i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"beatmapsets\":[");
    var count: usize = 0;
    for (set_ids) |set_id| {
        var set_output: std.Io.Writer.Allocating = .init(allocator);
        defer set_output.deinit();
        if (!try self.appendLazerSet(&set_output.writer, set_id, requester_id)) continue;
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

pub fn lazerOwnedBeatmapSearch(self: *Store, allocator: std.mem.Allocator, user_id: i32, query: []const u8, mode: i8, offset: u16, requester_id: ?i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const count_sql = "SELECT count(*) FROM (SELECT submission.set_id FROM beatmap_submissions submission JOIN beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=?1 AND submission.state='published' AND (?2=-1 OR b.mode=?2) AND (?3='' OR instr(lower(b.artist||' '||b.title||' '||b.creator||' '||b.source||' '||b.tags),lower(?3))>0) GROUP BY submission.set_id)";
    var count_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, count_sql, -1, &count_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(count_stmt);
    _ = c.sqlite3_bind_int(count_stmt, 1, user_id);
    _ = c.sqlite3_bind_int(count_stmt, 2, mode);
    _ = c.sqlite3_bind_text(count_stmt, 3, query.ptr, @intCast(query.len), null);
    if (c.sqlite3_step(count_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    const total: usize = @intCast(c.sqlite3_column_int64(count_stmt, 0));

    const ids_sql = "SELECT submission.set_id FROM beatmap_submissions submission JOIN beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=?1 AND submission.state='published' AND (?2=-1 OR b.mode=?2) AND (?3='' OR instr(lower(b.artist||' '||b.title||' '||b.creator||' '||b.source||' '||b.tags),lower(?3))>0) GROUP BY submission.set_id,submission.updated_at ORDER BY submission.updated_at DESC,submission.set_id DESC LIMIT 50 OFFSET ?4";
    var ids_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, ids_sql, -1, &ids_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(ids_stmt);
    _ = c.sqlite3_bind_int(ids_stmt, 1, user_id);
    _ = c.sqlite3_bind_int(ids_stmt, 2, mode);
    _ = c.sqlite3_bind_text(ids_stmt, 3, query.ptr, @intCast(query.len), null);
    _ = c.sqlite3_bind_int(ids_stmt, 4, offset);
    var ids: [50]i32 = undefined;
    var fetched: usize = 0;
    while (fetched < ids.len and c.sqlite3_step(ids_stmt) == c.SQLITE_ROW) : (fetched += 1) ids[fetched] = c.sqlite3_column_int(ids_stmt, 0);

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"beatmapsets\":[");
    var written: usize = 0;
    for (ids[0..fetched]) |set_id| {
        var set_output: std.Io.Writer.Allocating = .init(allocator);
        defer set_output.deinit();
        if (!try self.appendLazerSet(&set_output.writer, set_id, requester_id)) continue;
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try output.writer.writeAll(set_output.written());
    }
    const next_offset = @as(usize, offset) + fetched;
    try output.writer.print("],\"total\":{d},\"cursor\":", .{total});
    if (next_offset < total) try output.writer.print("{{\"offset\":{d}}}", .{next_offset}) else try output.writer.writeAll("null");
    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

pub fn lazerUserBeatmapSetsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, kind: []const u8, offset: usize, limit: usize, requester_id: ?i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const sql = "SELECT submission.set_id FROM beatmap_submissions submission JOIN beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=?1 AND submission.state='published' GROUP BY submission.set_id,submission.updated_at HAVING ?2='all' OR (?2='ranked' AND min(b.status) IN(3,4)) OR (?2='loved' AND min(b.status)=6) OR (?2='pending' AND min(b.status)=2) OR (?2='graveyard' AND min(b.status)=1) OR (?2='nominated' AND min(b.status)=5) ORDER BY submission.updated_at DESC,submission.set_id DESC LIMIT ?3 OFFSET ?4";
    var ids: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &ids, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(ids);
    _ = c.sqlite3_bind_int(ids, 1, user_id);
    _ = c.sqlite3_bind_text(ids, 2, kind.ptr, @intCast(kind.len), null);
    _ = c.sqlite3_bind_int64(ids, 3, @intCast(limit));
    _ = c.sqlite3_bind_int64(ids, 4, @intCast(offset));
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    while (c.sqlite3_step(ids) == c.SQLITE_ROW) {
        var set: std.Io.Writer.Allocating = .init(allocator);
        defer set.deinit();
        if (!try self.appendLazerSet(&set.writer, c.sqlite3_column_int(ids, 0), requester_id)) continue;
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try output.writer.writeAll(set.written());
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}
