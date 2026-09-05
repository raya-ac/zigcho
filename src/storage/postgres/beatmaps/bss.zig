const std = @import("std");
const postgres = @import("../../../postgres.zig");
const beatmap = @import("../../../beatmap.zig");
const lazer = @import("../../../lazer.zig");
const bss = @import("../../../bss.zig");
const object_keys = @import("../../../object_keys.zig");
const pg_score_maintenance = @import("../scores/maintenance.zig");
const pg_moderation = @import("../moderation/store.zig");

pub fn allocateBssIds(self: anytype, conn: *postgres.c.PGconn, kind: []const u8, count: u16) !i32 {
    if (count == 0 or (!std.mem.eql(u8, kind, "set") and !std.mem.eql(u8, kind, "beatmap"))) return error.InvalidBssReservation;
    var counter = try postgres.queryParams(self.allocator, conn, "SELECT next_id FROM zigcho.bss_counters WHERE kind=$1 FOR UPDATE", &.{kind});
    defer counter.deinit();
    if (counter.rows() != 1) return error.DatabaseQueryFailed;
    var start: i64 = @max(@as(i64, bss.private_id_floor), try counter.int(i64, 0, 0));
    var high = try postgres.query(conn, if (std.mem.eql(u8, kind, "set"))
        "SELECT greatest(coalesce((SELECT max(set_id) FROM zigcho.beatmaps),0),coalesce((SELECT max(set_id) FROM zigcho.beatmap_submissions),0))"
    else
        "SELECT greatest(coalesce((SELECT max(id) FROM zigcho.beatmaps),0),coalesce((SELECT max(beatmap_id) FROM zigcho.beatmap_submission_maps),0))");
    defer high.deinit();
    start = @max(start, try high.int(i64, 0, 0) + 1);
    const next = std.math.add(i64, start, count) catch return error.BssIdentifierExhausted;
    if (start > std.math.maxInt(i32) or next > @as(i64, std.math.maxInt(i32)) + 1) return error.BssIdentifierExhausted;
    var next_buf: [24]u8 = undefined;
    const next_text = try std.fmt.bufPrint(&next_buf, "{d}", .{next});
    var update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.bss_counters SET next_id=$2 WHERE kind=$1 RETURNING 1", &.{ kind, next_text });
    defer update.deinit();
    if (update.rows() != 1) return error.DatabaseQueryFailed;
    return @intCast(start);
}

pub fn reserveBssSubmission(self: anytype, allocator: std.mem.Allocator, user_id: i32, input: bss.ReserveInput) !bss.Reservation {
    const total = input.keep_ids.len + input.create_count;
    if (user_id <= 0 or total == 0 or total > bss.max_beatmaps) return error.InvalidBssReservation;
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    const ids = try allocator.alloc(i32, total);
    errdefer allocator.free(ids);
    var set_id: i32 = undefined;
    var revision: u32 = 1;
    var reissued_legacy_set: ?i32 = null;
    var reused_legacy_replacement = false;
    if (input.set_id) |existing_set| {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{existing_set});
        var submission = try postgres.queryParams(self.allocator, lease.conn, "SELECT owner_id,revision,state,(SELECT count(*) FROM zigcho.beatmaps WHERE set_id=$1),replacement_set_id FROM zigcho.beatmap_submissions WHERE set_id=$1 FOR UPDATE", &.{set});
        defer submission.deinit();
        if (submission.rows() == 0) return error.BssSubmissionNotFound;
        if (try submission.int(i32, 0, 0) != user_id) return error.BssNotOwner;
        const old_revision = try submission.int(i64, 0, 1);
        if (old_revision <= 0 or old_revision >= std.math.maxInt(u32)) return error.BssIdentifierExhausted;
        const reissue = existing_set < bss.private_id_floor and
            std.mem.eql(u8, submission.value(0, 2), "failed") and
            (try submission.int(i64, 0, 3)) == 0;
        for (input.keep_ids, 0..) |id, index| {
            var id_buf: [24]u8 = undefined;
            const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
            var owned = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND beatmap_id=$2", &.{ set, id_text });
            defer owned.deinit();
            if (owned.rows() == 0) return error.BssBeatmapNotOwned;
            if (!reissue) ids[index] = id;
        }
        if (reissue) {
            if (!submission.isNull(0, 4)) {
                const replacement = try submission.int(i32, 0, 4);
                var replacement_buf: [24]u8 = undefined;
                const replacement_text = try std.fmt.bufPrint(&replacement_buf, "{d}", .{replacement});
                var replacement_result = try postgres.queryParams(self.allocator, lease.conn, "SELECT owner_id,revision,(SELECT count(*) FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND active) FROM zigcho.beatmap_submissions WHERE set_id=$1 FOR UPDATE", &.{replacement_text});
                defer replacement_result.deinit();
                if (replacement_result.rows() != 1 or (try replacement_result.int(i32, 0, 0)) != user_id or (try replacement_result.int(usize, 0, 2)) != total) return error.InvalidBssReservation;
                const replacement_revision = try replacement_result.int(i64, 0, 1);
                if (replacement_revision <= 0 or replacement_revision >= std.math.maxInt(u32)) return error.BssIdentifierExhausted;
                revision = @intCast(replacement_revision + 1);
                set_id = replacement;
                var replacement_maps = try postgres.queryParams(self.allocator, lease.conn, "SELECT beatmap_id FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND active ORDER BY position,beatmap_id", &.{replacement_text});
                defer replacement_maps.deinit();
                if (replacement_maps.rows() != ids.len) return error.InvalidBssReservation;
                for (ids, 0..) |*id, row| id.* = try replacement_maps.int(i32, row, 0);
                reused_legacy_replacement = true;
            } else {
                reissued_legacy_set = existing_set;
                set_id = try allocateBssIds(self, lease.conn, "set", 1);
                revision = 1;
            }
        } else {
            revision = @intCast(old_revision + 1);
            set_id = existing_set;
            var deactivate = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submission_maps SET active=false WHERE set_id=$1", &.{set});
            deactivate.deinit();
            for (input.keep_ids, 0..) |id, position| {
                var id_buf: [24]u8 = undefined;
                var position_buf: [24]u8 = undefined;
                const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
                const position_text = try std.fmt.bufPrint(&position_buf, "{d}", .{position});
                var keep = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submission_maps SET active=true,position=$3 WHERE set_id=$1 AND beatmap_id=$2 RETURNING 1", &.{ set, id_text, position_text });
                defer keep.deinit();
                if (keep.rows() != 1) return error.DatabaseQueryFailed;
            }
        }
    } else {
        set_id = try allocateBssIds(self, lease.conn, "set", 1);
    }
    if (input.set_id == null or reissued_legacy_set != null) {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var create = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_submissions(set_id,owner_id,target,notify_replies) VALUES($1,$2,$3,$4::boolean)", &.{ set, user, input.target.database(), if (input.notify_replies) "true" else "false" });
        create.deinit();
    }
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const allocate_count: u16 = if (reissued_legacy_set != null) @intCast(total) else if (reused_legacy_replacement) 0 else input.create_count;
    if (allocate_count > 0) {
        const first = try allocateBssIds(self, lease.conn, "beatmap", allocate_count);
        for (0..allocate_count) |offset| {
            const id: i32 = first + @as(i32, @intCast(offset));
            const position = if (reissued_legacy_set != null) offset else input.keep_ids.len + offset;
            ids[position] = id;
            var id_buf: [24]u8 = undefined;
            var position_buf: [24]u8 = undefined;
            const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
            const position_text = try std.fmt.bufPrint(&position_buf, "{d}", .{position});
            var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_submission_maps(set_id,beatmap_id,position) VALUES($1,$2,$3)", &.{ set, id_text, position_text });
            insert.deinit();
        }
    }
    if (reissued_legacy_set) |legacy_set| {
        var legacy_buf: [24]u8 = undefined;
        const legacy = try std.fmt.bufPrint(&legacy_buf, "{d}", .{legacy_set});
        var alias = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submissions SET replacement_set_id=$3,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND owner_id=$2 AND state='failed' AND replacement_set_id IS NULL RETURNING 1", &.{ legacy, user, set });
        defer alias.deinit();
        if (alias.rows() != 1) return error.DatabaseQueryFailed;
    }
    if (input.set_id != null) {
        var revision_buf: [24]u8 = undefined;
        const revision_text = try std.fmt.bufPrint(&revision_buf, "{d}", .{revision});
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submissions SET target=$2,notify_replies=$3::boolean,state='reserved',revision=$4,last_error='',updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND owner_id=$5 RETURNING 1", &.{ set, input.target.database(), if (input.notify_replies) "true" else "false", revision_text, user });
        defer update.deinit();
        if (update.rows() != 1) return error.DatabaseQueryFailed;
    }
    try postgres.exec(lease.conn, "COMMIT");
    return .{ .allocator = allocator, .set_id = set_id, .beatmap_ids = ids, .revision = revision };
}

pub fn bssReservedMapIds(self: anytype, allocator: std.mem.Allocator, user_id: i32, set_id: i32) ![]i32 {
    var user_buf: [24]u8 = undefined;
    var set_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT m.beatmap_id FROM zigcho.beatmap_submissions s JOIN zigcho.beatmap_submission_maps m ON m.set_id=s.set_id WHERE s.set_id=$1 AND s.owner_id=$2 AND m.active ORDER BY m.position,m.beatmap_id", &.{ set, user });
    defer result.deinit();
    if (result.rows() == 0) {
        var owner = try postgres.queryParams(self.allocator, lease.conn, "SELECT owner_id FROM zigcho.beatmap_submissions WHERE set_id=$1", &.{set});
        defer owner.deinit();
        if (owner.rows() == 0) return error.BssSubmissionNotFound;
        if (try owner.int(i32, 0, 0) != user_id) return error.BssNotOwner;
        return error.InvalidBssReservation;
    }
    if (result.rows() > bss.max_beatmaps) return error.InvalidBssReservation;
    const ids = try allocator.alloc(i32, result.rows());
    for (ids, 0..) |*id, row| id.* = try result.int(i32, row, 0);
    return ids;
}

pub fn failBssSubmission(self: anytype, user_id: i32, set_id: i32, reason: []const u8) !void {
    const trimmed = std.mem.trim(u8, reason, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 500) return error.InvalidBssFailure;
    var user_buf: [24]u8 = undefined;
    var set_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submissions SET state='failed',last_error=$3,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND owner_id=$2 RETURNING 1", &.{ set, user, trimmed });
    defer result.deinit();
    if (result.rows() != 1) return error.BssNotOwner;
}

pub fn publishBssSubmission(self: anytype, user_id: i32, set_id: i32, package: *const bss.Package, archive: []const u8, sha256: []const u8) !void {
    if (archive.len == 0 or archive.len > bss.max_upload_bytes or package.maps.len == 0 or package.maps.len > bss.max_beatmaps or !object_keys.validSha256(sha256)) return error.InvalidBssArchive;
    var object_written = false;
    if (self.object_store.enabled()) {
        const object_key = try object_keys.archive(self.allocator, set_id, sha256);
        defer self.allocator.free(object_key);
        try self.object_store.put(self.allocator, self.io, object_key, "application/octet-stream", archive);
        object_written = true;
    }
    if (self.external_only and !object_written) return error.BssObjectStorageRequired;

    var user_buf: [24]u8 = undefined;
    var set_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try pg_score_maintenance.history_updates.lockMaintenance(lease.conn);
    var submission = try postgres.queryParams(self.allocator, lease.conn, "SELECT submission.owner_id,submission.target,owner.name FROM zigcho.beatmap_submissions submission JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE submission.set_id=$1 FOR UPDATE OF submission", &.{set});
    defer submission.deinit();
    if (submission.rows() == 0) return error.BssSubmissionNotFound;
    if (try submission.int(i32, 0, 0) != user_id) return error.BssNotOwner;
    const target = bss.Target.parse(submission.value(0, 1)) orelse return error.DatabaseQueryFailed;
    const owner_name = submission.value(0, 2);
    var count = try postgres.queryParams(self.allocator, lease.conn, "SELECT count(*) FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND active", &.{set});
    defer count.deinit();
    if (try count.int(usize, 0, 0) != package.maps.len) return error.BssRevisionMismatch;

    const upsert_sql = "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES($1,$2,$3,$4,$5,$6,$7,$8,extract(epoch FROM clock_timestamp())::bigint,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,creator_id=NULL,status=excluded.status,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners";
    var stats_eligibility_changed = false;
    for (package.maps) |map| {
        if (map.metadata.set_id != set_id) return error.BssRevisionMismatch;
        var map_id_buf: [24]u8 = undefined;
        const map_id = try std.fmt.bufPrint(&map_id_buf, "{d}", .{map.metadata.id});
        var active = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND beatmap_id=$2 AND active", &.{ set, map_id });
        defer active.deinit();
        if (active.rows() != 1) return error.BssRevisionMismatch;
        var previous_map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.status,EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.map_md5=b.md5) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.beatmap_id=b.id) FROM zigcho.beatmaps b WHERE b.id=$1 FOR UPDATE", &.{map_id});
        defer previous_map.deinit();
        if (previous_map.rows() != 0 and try previous_map.boolean(0, 1)) {
            const old_status = try previous_map.int(i32, 0, 0);
            const new_status = target.status();
            stats_eligibility_changed = stats_eligibility_changed or (old_status >= 3) != (new_status >= 3) or (old_status == 3 or old_status == 4) != (new_status == 3 or new_status == 4);
        }
        const encoded = try postgres.encodeBytea(self.allocator, map.contents);
        defer self.allocator.free(encoded);
        var status_buf: [8]u8 = undefined;
        var length_buf: [24]u8 = undefined;
        var combo_buf: [24]u8 = undefined;
        var mode_buf: [8]u8 = undefined;
        var bpm_buf: [48]u8 = undefined;
        var cs_buf: [48]u8 = undefined;
        var ar_buf: [48]u8 = undefined;
        var od_buf: [48]u8 = undefined;
        var hp_buf: [48]u8 = undefined;
        var stars_buf: [48]u8 = undefined;
        var circles_buf: [24]u8 = undefined;
        var sliders_buf: [24]u8 = undefined;
        var spinners_buf: [24]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buf, "{d}", .{target.status()});
        const total_length = try std.fmt.bufPrint(&length_buf, "{d}", .{map.metadata.total_length});
        const max_combo = try std.fmt.bufPrint(&combo_buf, "{d}", .{map.max_combo});
        const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{map.metadata.mode});
        const bpm = try std.fmt.bufPrint(&bpm_buf, "{d}", .{map.metadata.bpm});
        const cs = try std.fmt.bufPrint(&cs_buf, "{d}", .{map.metadata.cs});
        const ar = try std.fmt.bufPrint(&ar_buf, "{d}", .{map.metadata.ar});
        const od = try std.fmt.bufPrint(&od_buf, "{d}", .{map.metadata.od});
        const hp = try std.fmt.bufPrint(&hp_buf, "{d}", .{map.metadata.hp});
        const stars = try std.fmt.bufPrint(&stars_buf, "{d}", .{map.stars});
        const circles = try std.fmt.bufPrint(&circles_buf, "{d}", .{map.metadata.count_circles});
        const sliders = try std.fmt.bufPrint(&sliders_buf, "{d}", .{map.metadata.count_sliders});
        const spinners = try std.fmt.bufPrint(&spinners_buf, "{d}", .{map.metadata.count_spinners});
        var upsert = try postgres.queryParams(self.allocator, lease.conn, upsert_sql, &.{ map_id, set, &map.md5, map.metadata.artist, map.metadata.title, map.metadata.version, owner_name, status, total_length, max_combo, mode, bpm, cs, ar, od, hp, stars, map.metadata.source, map.metadata.tags, encoded, circles, sliders, spinners });
        upsert.deinit();
    }
    if (stats_eligibility_changed) {
        try pg_score_maintenance.rebuildRankedStats(self, lease.conn, false);
        try pg_score_maintenance.recordAllStatsHistoryCurrentWithConnection(self, lease.conn);
    }
    var size_buf: [32]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "{d}", .{archive.len});
    if (self.external_only and object_written) {
        var stored = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES($1,$2,NULL,$3,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=NULL,object_bytes=excluded.object_bytes,imported_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, size });
        stored.deinit();
    } else {
        const encoded_archive = try postgres.encodeBytea(self.allocator, archive);
        defer self.allocator.free(encoded_archive);
        var stored = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES($1,$2,$3,$4,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,object_bytes=excluded.object_bytes,imported_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, encoded_archive, size });
        stored.deinit();
    }
    if (target == .pending) {
        var first_map_buf: [24]u8 = undefined;
        const first_map = try std.fmt.bufPrint(&first_map_buf, "{d}", .{package.maps[0].metadata.id});
        var request = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_rank_requests(set_id,map_id,requester_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING 1", &.{ set, first_map, user });
        const inserted = request.rows() == 1;
        request.deinit();
        if (inserted) try pg_moderation.insertBeatmapRankEvent(self.allocator, lease.conn, set_id, user_id, "request", target.status(), target.status(), "lazer BSS pending submission");
    } else {
        var close_requests = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_rank_requests SET active=false,resolved_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND active", &.{set});
        close_requests.deinit();
        var close_nominations = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_nominations SET active=false,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND active", &.{set});
        close_nominations.deinit();
    }
    var complete = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submissions SET state='published',last_error='',updated_at=extract(epoch FROM clock_timestamp())::bigint,uploaded_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND owner_id=$2 RETURNING 1", &.{ set, user });
    defer complete.deinit();
    if (complete.rows() != 1) return error.BssRevisionMismatch;
    try postgres.exec(lease.conn, "COMMIT");
}
