const std = @import("std");
const bss = @import("../../../bss.zig");
const object_keys = @import("../../../object_keys.zig");
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;

pub fn allocateBssIdsLocked(self: *Store, kind: []const u8, count: u16) !i32 {
    if (count == 0 or (!std.mem.eql(u8, kind, "set") and !std.mem.eql(u8, kind, "beatmap"))) return error.InvalidBssReservation;
    var counter: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT next_id FROM bss_counters WHERE kind=?1", -1, &counter, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(counter);
    _ = c.sqlite3_bind_text(counter, 1, kind.ptr, @intCast(kind.len), null);
    if (c.sqlite3_step(counter) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    var start: i64 = @max(@as(i64, bss.private_id_floor), c.sqlite3_column_int64(counter, 0));

    var high: ?*c.sqlite3_stmt = null;
    const high_sql = if (std.mem.eql(u8, kind, "set"))
        "SELECT max(value) FROM (SELECT max(set_id) value FROM beatmaps UNION ALL SELECT max(set_id) value FROM beatmap_submissions)"
    else
        "SELECT max(value) FROM (SELECT max(id) value FROM beatmaps UNION ALL SELECT max(beatmap_id) value FROM beatmap_submission_maps)";
    if (c.sqlite3_prepare_v2(self.db, high_sql, -1, &high, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(high);
    if (c.sqlite3_step(high) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    if (c.sqlite3_column_type(high, 0) != c.SQLITE_NULL) start = @max(start, c.sqlite3_column_int64(high, 0) + 1);
    const next = std.math.add(i64, start, count) catch return error.BssIdentifierExhausted;
    if (start > std.math.maxInt(i32) or next > @as(i64, std.math.maxInt(i32)) + 1) return error.BssIdentifierExhausted;

    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE bss_counters SET next_id=?2 WHERE kind=?1", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    _ = c.sqlite3_bind_text(update, 1, kind.ptr, @intCast(kind.len), null);
    _ = c.sqlite3_bind_int64(update, 2, next);
    if (c.sqlite3_step(update) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.DatabaseQueryFailed;
    return @intCast(start);
}

pub fn reserveBssSubmission(self: *Store, allocator: std.mem.Allocator, user_id: i32, input: bss.ReserveInput) !bss.Reservation {
    if (user_id <= 0) return error.InvalidUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};

    const total = input.keep_ids.len + input.create_count;
    if (total == 0 or total > bss.max_beatmaps) return error.InvalidBssReservation;
    const ids = try allocator.alloc(i32, total);
    errdefer allocator.free(ids);
    var set_id: i32 = undefined;
    var revision: u32 = 1;
    var reissued_legacy_set: ?i32 = null;
    var reused_legacy_replacement = false;
    if (input.set_id) |existing_set| {
        var old_revision: i64 = 0;
        var reissue = false;
        var replacement_set_id: ?i32 = null;
        {
            var submission: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT owner_id,revision,state,(SELECT count(*) FROM beatmaps WHERE set_id=?1),replacement_set_id FROM beatmap_submissions WHERE set_id=?1", -1, &submission, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(submission);
            _ = c.sqlite3_bind_int(submission, 1, existing_set);
            if (c.sqlite3_step(submission) != c.SQLITE_ROW) return error.BssSubmissionNotFound;
            if (c.sqlite3_column_int(submission, 0) != user_id) return error.BssNotOwner;
            old_revision = c.sqlite3_column_int64(submission, 1);
            reissue = existing_set < bss.private_id_floor and
                std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(submission, 2)), "failed") and
                c.sqlite3_column_int64(submission, 3) == 0;
            replacement_set_id = if (c.sqlite3_column_type(submission, 4) == c.SQLITE_NULL) null else c.sqlite3_column_int(submission, 4);
        }
        if (old_revision <= 0 or old_revision >= std.math.maxInt(u32)) return error.BssIdentifierExhausted;

        var owned: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmap_submission_maps WHERE set_id=?1 AND beatmap_id=?2", -1, &owned, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(owned);
        for (input.keep_ids, 0..) |id, index| {
            _ = c.sqlite3_reset(owned);
            _ = c.sqlite3_clear_bindings(owned);
            _ = c.sqlite3_bind_int(owned, 1, existing_set);
            _ = c.sqlite3_bind_int(owned, 2, id);
            if (c.sqlite3_step(owned) != c.SQLITE_ROW) return error.BssBeatmapNotOwned;
            if (!reissue) ids[index] = id;
        }
        if (reissue) {
            if (replacement_set_id) |replacement| {
                var replacement_stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "SELECT owner_id,revision,(SELECT count(*) FROM beatmap_submission_maps WHERE set_id=?1 AND active=1) FROM beatmap_submissions WHERE set_id=?1", -1, &replacement_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
                defer _ = c.sqlite3_finalize(replacement_stmt);
                _ = c.sqlite3_bind_int(replacement_stmt, 1, replacement);
                if (c.sqlite3_step(replacement_stmt) != c.SQLITE_ROW or c.sqlite3_column_int(replacement_stmt, 0) != user_id or c.sqlite3_column_int64(replacement_stmt, 2) != @as(i64, @intCast(total))) return error.InvalidBssReservation;
                const replacement_revision = c.sqlite3_column_int64(replacement_stmt, 1);
                if (replacement_revision <= 0 or replacement_revision >= std.math.maxInt(u32)) return error.BssIdentifierExhausted;
                revision = @intCast(replacement_revision + 1);
                set_id = replacement;
                var replacement_maps: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "SELECT beatmap_id FROM beatmap_submission_maps WHERE set_id=?1 AND active=1 ORDER BY position,beatmap_id", -1, &replacement_maps, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
                defer _ = c.sqlite3_finalize(replacement_maps);
                _ = c.sqlite3_bind_int(replacement_maps, 1, replacement);
                var replacement_index: usize = 0;
                while (c.sqlite3_step(replacement_maps) == c.SQLITE_ROW) : (replacement_index += 1) {
                    if (replacement_index >= ids.len) return error.InvalidBssReservation;
                    ids[replacement_index] = c.sqlite3_column_int(replacement_maps, 0);
                }
                if (replacement_index != ids.len) return error.InvalidBssReservation;
                reused_legacy_replacement = true;
            } else {
                reissued_legacy_set = existing_set;
                set_id = try self.allocateBssIdsLocked("set", 1);
                revision = 1;
            }
        } else {
            revision = @intCast(old_revision + 1);
            set_id = existing_set;
            var deactivate: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_submission_maps SET active=0 WHERE set_id=?1", -1, &deactivate, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(deactivate);
            _ = c.sqlite3_bind_int(deactivate, 1, set_id);
            if (c.sqlite3_step(deactivate) != c.SQLITE_DONE) return error.DatabaseQueryFailed;

            var keep: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_submission_maps SET active=1,position=?3 WHERE set_id=?1 AND beatmap_id=?2", -1, &keep, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(keep);
            for (input.keep_ids, 0..) |id, position| {
                _ = c.sqlite3_reset(keep);
                _ = c.sqlite3_clear_bindings(keep);
                _ = c.sqlite3_bind_int(keep, 1, set_id);
                _ = c.sqlite3_bind_int(keep, 2, id);
                _ = c.sqlite3_bind_int64(keep, 3, @intCast(position));
                if (c.sqlite3_step(keep) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.DatabaseQueryFailed;
            }
        }
    } else {
        set_id = try self.allocateBssIdsLocked("set", 1);
    }
    if (input.set_id == null or reissued_legacy_set != null) {
        var create: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO beatmap_submissions(set_id,owner_id,target,notify_replies) VALUES(?1,?2,?3,?4)", -1, &create, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(create);
        _ = c.sqlite3_bind_int(create, 1, set_id);
        _ = c.sqlite3_bind_int(create, 2, user_id);
        _ = c.sqlite3_bind_text(create, 3, input.target.database().ptr, @intCast(input.target.database().len), null);
        _ = c.sqlite3_bind_int(create, 4, @intFromBool(input.notify_replies));
        if (c.sqlite3_step(create) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    const allocate_count: u16 = if (reissued_legacy_set != null) @intCast(total) else if (reused_legacy_replacement) 0 else input.create_count;
    if (allocate_count > 0) {
        const first = try self.allocateBssIdsLocked("beatmap", allocate_count);
        var insert: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO beatmap_submission_maps(set_id,beatmap_id,position) VALUES(?1,?2,?3)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(insert);
        for (0..allocate_count) |offset| {
            const id: i32 = first + @as(i32, @intCast(offset));
            const position = if (reissued_legacy_set != null) offset else input.keep_ids.len + offset;
            ids[position] = id;
            _ = c.sqlite3_reset(insert);
            _ = c.sqlite3_clear_bindings(insert);
            _ = c.sqlite3_bind_int(insert, 1, set_id);
            _ = c.sqlite3_bind_int(insert, 2, id);
            _ = c.sqlite3_bind_int64(insert, 3, @intCast(position));
            if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }
    }
    if (reissued_legacy_set) |legacy_set| {
        var alias: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_submissions SET replacement_set_id=?3,updated_at=unixepoch() WHERE set_id=?1 AND owner_id=?2 AND state='failed' AND replacement_set_id IS NULL", -1, &alias, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(alias);
        _ = c.sqlite3_bind_int(alias, 1, legacy_set);
        _ = c.sqlite3_bind_int(alias, 2, user_id);
        _ = c.sqlite3_bind_int(alias, 3, set_id);
        if (c.sqlite3_step(alias) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.DatabaseQueryFailed;
    }
    if (input.set_id != null) {
        var update: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_submissions SET target=?2,notify_replies=?3,state='reserved',revision=?4,last_error='',updated_at=unixepoch() WHERE set_id=?1 AND owner_id=?5", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(update);
        _ = c.sqlite3_bind_int(update, 1, set_id);
        _ = c.sqlite3_bind_text(update, 2, input.target.database().ptr, @intCast(input.target.database().len), null);
        _ = c.sqlite3_bind_int(update, 3, @intFromBool(input.notify_replies));
        _ = c.sqlite3_bind_int64(update, 4, revision);
        _ = c.sqlite3_bind_int(update, 5, user_id);
        if (c.sqlite3_step(update) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.DatabaseQueryFailed;
    }
    try self.exec("COMMIT");
    return .{ .allocator = allocator, .set_id = set_id, .beatmap_ids = ids, .revision = revision };
}

pub fn bssReservedMapIds(self: *Store, allocator: std.mem.Allocator, user_id: i32, set_id: i32) ![]i32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var owner: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT owner_id FROM beatmap_submissions WHERE set_id=?1", -1, &owner, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(owner);
    _ = c.sqlite3_bind_int(owner, 1, set_id);
    if (c.sqlite3_step(owner) != c.SQLITE_ROW) return error.BssSubmissionNotFound;
    if (c.sqlite3_column_int(owner, 0) != user_id) return error.BssNotOwner;
    var count_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM beatmap_submission_maps WHERE set_id=?1 AND active=1", -1, &count_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(count_stmt);
    _ = c.sqlite3_bind_int(count_stmt, 1, set_id);
    if (c.sqlite3_step(count_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    const count: usize = @intCast(c.sqlite3_column_int64(count_stmt, 0));
    if (count == 0 or count > bss.max_beatmaps) return error.InvalidBssReservation;
    const ids = try allocator.alloc(i32, count);
    errdefer allocator.free(ids);
    var rows: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT beatmap_id FROM beatmap_submission_maps WHERE set_id=?1 AND active=1 ORDER BY position,beatmap_id", -1, &rows, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(rows);
    _ = c.sqlite3_bind_int(rows, 1, set_id);
    var index: usize = 0;
    while (c.sqlite3_step(rows) == c.SQLITE_ROW) : (index += 1) {
        if (index >= ids.len) return error.DatabaseQueryFailed;
        ids[index] = c.sqlite3_column_int(rows, 0);
    }
    if (index != ids.len) return error.DatabaseQueryFailed;
    return ids;
}

pub fn failBssSubmission(self: *Store, user_id: i32, set_id: i32, reason: []const u8) !void {
    const trimmed = std.mem.trim(u8, reason, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 500) return error.InvalidBssFailure;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_submissions SET state='failed',last_error=?3,updated_at=unixepoch() WHERE set_id=?1 AND owner_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, set_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_text(stmt, 3, trimmed.ptr, @intCast(trimmed.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.BssNotOwner;
}

pub fn publishBssSubmission(self: *Store, user_id: i32, set_id: i32, package: *const bss.Package, archive: []const u8, sha256: []const u8) !void {
    if (archive.len == 0 or archive.len > bss.max_upload_bytes or package.maps.len == 0 or package.maps.len > bss.max_beatmaps or !object_keys.validSha256(sha256)) return error.InvalidBssArchive;
    if (self.object_store.enabled()) {
        const object_key = try object_keys.archive(self.allocator, set_id, sha256);
        defer self.allocator.free(object_key);
        try self.object_store.put(self.allocator, self.io, object_key, "application/octet-stream", archive);
    }
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};

    var submission: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT submission.owner_id,submission.target,owner.name FROM beatmap_submissions submission JOIN users owner ON owner.id=submission.owner_id WHERE submission.set_id=?1", -1, &submission, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(submission);
    _ = c.sqlite3_bind_int(submission, 1, set_id);
    if (c.sqlite3_step(submission) != c.SQLITE_ROW) return error.BssSubmissionNotFound;
    if (c.sqlite3_column_int(submission, 0) != user_id) return error.BssNotOwner;
    const target = bss.Target.parse(std.mem.span(c.sqlite3_column_text(submission, 1))) orelse return error.DatabaseQueryFailed;
    const owner_name = std.mem.span(c.sqlite3_column_text(submission, 2));

    var active_count: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM beatmap_submission_maps WHERE set_id=?1 AND active=1", -1, &active_count, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(active_count);
    _ = c.sqlite3_bind_int(active_count, 1, set_id);
    if (c.sqlite3_step(active_count) != c.SQLITE_ROW or c.sqlite3_column_int64(active_count, 0) != package.maps.len) return error.BssRevisionMismatch;

    var active_map: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmap_submission_maps WHERE set_id=?1 AND beatmap_id=?2 AND active=1", -1, &active_map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(active_map);
    const upsert_sql = "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,creator_id=NULL,status=excluded.status,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners";
    var upsert: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, upsert_sql, -1, &upsert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(upsert);
    var stats_eligibility_changed = false;
    for (package.maps) |map| {
        if (map.metadata.set_id != set_id) return error.BssRevisionMismatch;
        _ = c.sqlite3_reset(active_map);
        _ = c.sqlite3_clear_bindings(active_map);
        _ = c.sqlite3_bind_int(active_map, 1, set_id);
        _ = c.sqlite3_bind_int(active_map, 2, map.metadata.id);
        if (c.sqlite3_step(active_map) != c.SQLITE_ROW) return error.BssRevisionMismatch;
        var previous_map: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT b.status,EXISTS(SELECT 1 FROM scores s WHERE s.map_md5=b.md5) OR EXISTS(SELECT 1 FROM lazer_scores l WHERE l.beatmap_id=b.id) FROM beatmaps b WHERE b.id=?1", -1, &previous_map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(previous_map, 1, map.metadata.id);
        if (c.sqlite3_step(previous_map) == c.SQLITE_ROW and c.sqlite3_column_int(previous_map, 1) != 0) {
            const old_status = c.sqlite3_column_int(previous_map, 0);
            const new_status = target.status();
            stats_eligibility_changed = stats_eligibility_changed or (old_status >= 3) != (new_status >= 3) or (old_status == 3 or old_status == 4) != (new_status == 3 or new_status == 4);
        }
        _ = c.sqlite3_finalize(previous_map);
        _ = c.sqlite3_reset(upsert);
        _ = c.sqlite3_clear_bindings(upsert);
        _ = c.sqlite3_bind_int(upsert, 1, map.metadata.id);
        _ = c.sqlite3_bind_int(upsert, 2, set_id);
        _ = c.sqlite3_bind_text(upsert, 3, &map.md5, map.md5.len, null);
        _ = c.sqlite3_bind_text(upsert, 4, map.metadata.artist.ptr, @intCast(map.metadata.artist.len), null);
        _ = c.sqlite3_bind_text(upsert, 5, map.metadata.title.ptr, @intCast(map.metadata.title.len), null);
        _ = c.sqlite3_bind_text(upsert, 6, map.metadata.version.ptr, @intCast(map.metadata.version.len), null);
        _ = c.sqlite3_bind_text(upsert, 7, owner_name.ptr, @intCast(owner_name.len), null);
        _ = c.sqlite3_bind_int(upsert, 8, target.status());
        _ = c.sqlite3_bind_int(upsert, 9, map.metadata.total_length);
        _ = c.sqlite3_bind_int64(upsert, 10, map.max_combo);
        _ = c.sqlite3_bind_int(upsert, 11, map.metadata.mode);
        _ = c.sqlite3_bind_double(upsert, 12, map.metadata.bpm);
        _ = c.sqlite3_bind_double(upsert, 13, map.metadata.cs);
        _ = c.sqlite3_bind_double(upsert, 14, map.metadata.ar);
        _ = c.sqlite3_bind_double(upsert, 15, map.metadata.od);
        _ = c.sqlite3_bind_double(upsert, 16, map.metadata.hp);
        _ = c.sqlite3_bind_double(upsert, 17, map.stars);
        _ = c.sqlite3_bind_text(upsert, 18, map.metadata.source.ptr, @intCast(map.metadata.source.len), null);
        _ = c.sqlite3_bind_text(upsert, 19, map.metadata.tags.ptr, @intCast(map.metadata.tags.len), null);
        _ = c.sqlite3_bind_blob(upsert, 20, map.contents.ptr, @intCast(map.contents.len), null);
        _ = c.sqlite3_bind_int64(upsert, 21, map.metadata.count_circles);
        _ = c.sqlite3_bind_int64(upsert, 22, map.metadata.count_sliders);
        _ = c.sqlite3_bind_int64(upsert, 23, map.metadata.count_spinners);
        if (c.sqlite3_step(upsert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    if (stats_eligibility_changed) {
        try self.rebuildScoreStats(false);
        try self.recordAllStatsHistoryCurrentLocked();
    }

    var archive_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES(?1,?2,?3,?4,unixepoch()) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,object_bytes=excluded.object_bytes,imported_at=unixepoch(),last_accessed_at=unixepoch()", -1, &archive_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(archive_stmt);
    _ = c.sqlite3_bind_int(archive_stmt, 1, set_id);
    _ = c.sqlite3_bind_text(archive_stmt, 2, sha256.ptr, @intCast(sha256.len), null);
    _ = c.sqlite3_bind_blob(archive_stmt, 3, archive.ptr, @intCast(archive.len), null);
    _ = c.sqlite3_bind_int64(archive_stmt, 4, @intCast(archive.len));
    if (c.sqlite3_step(archive_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;

    if (target == .pending) {
        var request: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO beatmap_rank_requests(set_id,map_id,requester_id) VALUES(?1,?2,?3)", -1, &request, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(request, 1, set_id);
        _ = c.sqlite3_bind_int(request, 2, package.maps[0].metadata.id);
        _ = c.sqlite3_bind_int(request, 3, user_id);
        if (c.sqlite3_step(request) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const inserted = c.sqlite3_changes(self.db) == 1;
        _ = c.sqlite3_finalize(request);
        if (inserted) try self.insertBeatmapRankEventLocked(set_id, user_id, "request", target.status(), target.status(), "lazer BSS pending submission");
    } else {
        var close_requests: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_rank_requests SET active=0,resolved_at=unixepoch() WHERE set_id=?1 AND active=1", -1, &close_requests, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(close_requests, 1, set_id);
        if (c.sqlite3_step(close_requests) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(close_requests);
        var close_nominations: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_nominations SET active=0,updated_at=unixepoch() WHERE set_id=?1 AND active=1", -1, &close_nominations, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(close_nominations, 1, set_id);
        if (c.sqlite3_step(close_nominations) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(close_nominations);
    }
    var complete: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_submissions SET state='published',last_error='',updated_at=unixepoch(),uploaded_at=unixepoch() WHERE set_id=?1 AND owner_id=?2", -1, &complete, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(complete);
    _ = c.sqlite3_bind_int(complete, 1, set_id);
    _ = c.sqlite3_bind_int(complete, 2, user_id);
    if (c.sqlite3_step(complete) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.BssRevisionMismatch;
    try self.exec("COMMIT");
}
