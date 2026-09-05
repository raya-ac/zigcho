const std = @import("std");
const anticheat_review = @import("../../../anticheat_review.zig");
const c = @import("../../../storage.zig").c;
const ClientHardware = @import("../../contracts.zig").ClientHardware;
const HardwareEvidence = @import("../../contracts.zig").HardwareEvidence;
const AnticheatExclusionScope = @import("../../contracts.zig").AnticheatExclusionScope;
const validateAnticheatExclusion = @import("../../contracts.zig").validateAnticheatExclusion;
const validateAnticheatExclusionRevocation = @import("../../contracts.zig").validateAnticheatExclusionRevocation;
const canManageAnticheatExclusion = @import("../../contracts.zig").canManageAnticheatExclusion;
const AnticheatReviewLabel = @import("../../contracts.zig").AnticheatReviewLabel;
const AnticheatObservation = @import("../../contracts.zig").AnticheatObservation;
const validateAnticheatObservation = @import("../../contracts.zig").validateAnticheatObservation;
const Store = @import("../../../storage.zig").Store;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn recordClientHardware(self: *Store, user_id: i32, hardware: ClientHardware) !HardwareEvidence {
    var matched: std.ArrayList(i32) = .empty;
    errdefer matched.deinit(self.allocator);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    try self.exec("DELETE FROM audit_log WHERE id IN (SELECT id FROM audit_log WHERE action='anticheat.hardware_match' AND created_at<unixepoch()-15552000 ORDER BY created_at,id LIMIT 128)");

    if (hardware.actionable) {
        var match_stmt: ?*c.sqlite3_stmt = null;
        const match_sql = "SELECT DISTINCT user_id FROM client_hardware WHERE user_id!=?1 AND user_id!=3 AND adapters_md5=?2 AND uninstall_md5=?3 AND disk_signature_md5=?4 ORDER BY user_id";
        if (c.sqlite3_prepare_v2(self.db, match_sql, -1, &match_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(match_stmt);
        _ = c.sqlite3_bind_int(match_stmt, 1, user_id);
        _ = c.sqlite3_bind_text(match_stmt, 2, hardware.adapters_md5.ptr, @intCast(hardware.adapters_md5.len), null);
        _ = c.sqlite3_bind_text(match_stmt, 3, hardware.uninstall_md5.ptr, @intCast(hardware.uninstall_md5.len), null);
        _ = c.sqlite3_bind_text(match_stmt, 4, hardware.disk_signature_md5.ptr, @intCast(hardware.disk_signature_md5.len), null);
        while (c.sqlite3_step(match_stmt) == c.SQLITE_ROW) try matched.append(self.allocator, c.sqlite3_column_int(match_stmt, 0));
    }

    var insert_stmt: ?*c.sqlite3_stmt = null;
    const insert_sql = "INSERT INTO client_hardware(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5,client_version,running_under_wine) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5) DO UPDATE SET client_version=excluded.client_version,running_under_wine=excluded.running_under_wine,last_seen=unixepoch(),occurrences=occurrences+1";
    if (c.sqlite3_prepare_v2(self.db, insert_sql, -1, &insert_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(insert_stmt);
    _ = c.sqlite3_bind_int(insert_stmt, 1, user_id);
    _ = c.sqlite3_bind_text(insert_stmt, 2, hardware.osu_path_md5.ptr, @intCast(hardware.osu_path_md5.len), null);
    _ = c.sqlite3_bind_text(insert_stmt, 3, hardware.adapters_md5.ptr, @intCast(hardware.adapters_md5.len), null);
    _ = c.sqlite3_bind_text(insert_stmt, 4, hardware.uninstall_md5.ptr, @intCast(hardware.uninstall_md5.len), null);
    _ = c.sqlite3_bind_text(insert_stmt, 5, hardware.disk_signature_md5.ptr, @intCast(hardware.disk_signature_md5.len), null);
    _ = c.sqlite3_bind_text(insert_stmt, 6, hardware.client_version.ptr, @intCast(hardware.client_version.len), null);
    _ = c.sqlite3_bind_int(insert_stmt, 7, @intFromBool(hardware.running_under_wine));
    if (c.sqlite3_step(insert_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;

    if (matched.items.len != 0) {
        for (matched.items) |matched_user_id| {
            try self.insertHardwareMatchAuditLocked(user_id, matched_user_id, matched.items.len);
            try self.insertHardwareMatchAuditLocked(matched_user_id, user_id, matched.items.len);
        }
    }

    const owned_matches = try matched.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_matches);
    try self.exec("COMMIT");
    return .{ .allocator = self.allocator, .matched_user_ids = owned_matches };
}

pub fn insertHardwareMatchAuditLocked(self: *Store, target_user_id: i32, matched_user_id: i32, match_count: usize) !void {
    var detail_buf: [128]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "mode=observe exact_hardware_match matched_user:{d} match_count:{d}", .{ matched_user_id, match_count });
    var target_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_user_id});
    var recent: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM audit_log WHERE actor_id=3 AND action='anticheat.hardware_match' AND target=?1 AND detail=?2 AND created_at>=unixepoch()-86400 LIMIT 1", -1, &recent, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(recent);
    _ = c.sqlite3_bind_text(recent, 1, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(recent, 2, detail.ptr, @intCast(detail.len), null);
    if (c.sqlite3_step(recent) == c.SQLITE_ROW) return;
    try self.insertAuditLocked(3, "anticheat.hardware_match", target_user_id, detail);
}

pub fn insertAuditLocked(self: *Store, actor_id: i32, action: []const u8, target_user_id: i32, detail: []const u8) !void {
    var target_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_user_id});
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,?2,?3,?4)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, actor_id);
    _ = c.sqlite3_bind_text(stmt, 2, action.ptr, @intCast(action.len), null);
    _ = c.sqlite3_bind_text(stmt, 3, target.ptr, @intCast(target.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, detail.ptr, @intCast(detail.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn requireAnticheatExclusionAuthorityLocked(self: *Store, actor_id: i32, user_id: i32) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT id,restricted,privileges FROM users WHERE id IN(?1,?2) ORDER BY id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, actor_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    var found: u8 = 0;
    var actor_restricted = false;
    var actor_privileges: u32 = 0;
    var user_privileges: u32 = 0;
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => {
            const id = c.sqlite3_column_int(stmt, 0);
            const raw_privileges = c.sqlite3_column_int64(stmt, 2);
            if (raw_privileges < 0 or raw_privileges > std.math.maxInt(u32)) return error.DatabaseQueryFailed;
            if (id == actor_id) {
                actor_restricted = c.sqlite3_column_int(stmt, 1) != 0;
                actor_privileges = @intCast(raw_privileges);
                found |= 1;
            } else if (id == user_id) {
                user_privileges = @intCast(raw_privileges);
                found |= 2;
            }
        },
        c.SQLITE_DONE => break,
        else => return error.DatabaseQueryFailed,
    };
    if (found != 3) return error.AnticheatExclusionUserNotFound;
    if (!canManageAnticheatExclusion(actor_id, user_id, actor_restricted, actor_privileges, user_privileges)) return error.AnticheatExclusionForbidden;
}

pub fn createAnticheatExclusion(self: *Store, actor_id: i32, user_id: i32, scope: AnticheatExclusionScope, duration_seconds: i64, reason: []const u8) !i64 {
    const trimmed = try validateAnticheatExclusion(actor_id, user_id, duration_seconds, reason);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};

    try self.requireAnticheatExclusionAuthorityLocked(actor_id, user_id);

    const scope_text = scope.text();
    var overlap: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM anticheat_review_exclusions WHERE user_id=?1 AND revoked_at IS NULL AND expires_at>unixepoch() AND (scope='all' OR ?2='all' OR scope=?2) LIMIT 1", -1, &overlap, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(overlap);
    _ = c.sqlite3_bind_int(overlap, 1, user_id);
    _ = c.sqlite3_bind_text(overlap, 2, scope_text.ptr, @intCast(scope_text.len), null);
    switch (c.sqlite3_step(overlap)) {
        c.SQLITE_ROW => return error.AnticheatExclusionOverlap,
        c.SQLITE_DONE => {},
        else => return error.DatabaseQueryFailed,
    }

    var insert: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO anticheat_review_exclusions(user_id,scope,reason,created_by,expires_at) VALUES(?1,?2,?3,?4,unixepoch()+?5) RETURNING id,expires_at", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(insert);
    _ = c.sqlite3_bind_int(insert, 1, user_id);
    _ = c.sqlite3_bind_text(insert, 2, scope_text.ptr, @intCast(scope_text.len), null);
    _ = c.sqlite3_bind_text(insert, 3, trimmed.ptr, @intCast(trimmed.len), null);
    _ = c.sqlite3_bind_int(insert, 4, actor_id);
    _ = c.sqlite3_bind_int64(insert, 5, duration_seconds);
    if (c.sqlite3_step(insert) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    const exclusion_id = c.sqlite3_column_int64(insert, 0);
    const expires_at = c.sqlite3_column_int64(insert, 1);
    if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var detail_buf: [760]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "exclusion_id={d} scope={s} expires_at={d} reason={s}", .{ exclusion_id, scope_text, expires_at, trimmed });
    try self.insertAuditLocked(actor_id, "anticheat.review_exclusion.create", user_id, detail);
    try self.exec("COMMIT");
    return exclusion_id;
}

pub fn anticheatExclusionTarget(self: *Store, exclusion_id: i64) !?i32 {
    if (exclusion_id <= 0) return null;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT user_id FROM anticheat_review_exclusions WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, exclusion_id);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => c.sqlite3_column_int(stmt, 0),
        c.SQLITE_DONE => null,
        else => error.DatabaseQueryFailed,
    };
}

pub fn revokeAnticheatExclusion(self: *Store, actor_id: i32, exclusion_id: i64, reason: []const u8) !void {
    const trimmed = try validateAnticheatExclusionRevocation(actor_id, exclusion_id, reason);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var target: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT user_id FROM anticheat_review_exclusions WHERE id=?1", -1, &target, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(target);
    _ = c.sqlite3_bind_int64(target, 1, exclusion_id);
    if (c.sqlite3_step(target) != c.SQLITE_ROW) return error.AnticheatExclusionNotActive;
    const target_user_id = c.sqlite3_column_int(target, 0);
    if (c.sqlite3_step(target) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    try self.requireAnticheatExclusionAuthorityLocked(actor_id, target_user_id);
    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE anticheat_review_exclusions SET revoked_by=?1,revoked_at=unixepoch(),revoke_reason=?2 WHERE id=?3 AND user_id!=?1 AND user_id!=3 AND revoked_at IS NULL AND expires_at>unixepoch() RETURNING user_id,scope", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    _ = c.sqlite3_bind_int(update, 1, actor_id);
    _ = c.sqlite3_bind_text(update, 2, trimmed.ptr, @intCast(trimmed.len), null);
    _ = c.sqlite3_bind_int64(update, 3, exclusion_id);
    if (c.sqlite3_step(update) != c.SQLITE_ROW) return error.AnticheatExclusionNotActive;
    const user_id = c.sqlite3_column_int(update, 0);
    const scope = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(update, 1)));
    defer self.allocator.free(scope);
    if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    var detail_buf: [720]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "exclusion_id={d} scope={s} reason={s}", .{ exclusion_id, scope, trimmed });
    try self.insertAuditLocked(actor_id, "anticheat.review_exclusion.revoke", user_id, detail);
    try self.exec("COMMIT");
}

pub fn recordAnticheatObservation(self: *Store, user_id: i32, observation: AnticheatObservation) !i64 {
    try validateAnticheatObservation(user_id, observation);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    // Null-score signals can repeat on every reconnect or lastfm poll. Keep
    // one identical pending signal per user and day, while score-linked
    // evidence remains unique and durable. Cleanup is deliberately bounded
    // so an observation write can never turn into a large maintenance job.
    try self.exec("DELETE FROM anticheat_observations WHERE id IN (SELECT id FROM anticheat_observations WHERE score_id IS NULL AND source!='stable_score' AND ((review_label!='pending' AND reviewed_at<unixepoch()-15552000) OR (review_label='pending' AND created_at<unixepoch()-7776000)) ORDER BY created_at,id LIMIT 128)");
    try self.exec("DELETE FROM audit_log WHERE id IN (SELECT id FROM audit_log WHERE ((action='anticheat.observe' AND detail LIKE '% score_id=0 mode=observe %') OR action IN('anticheat.hardware_match','stable.lastfm_flag')) AND created_at<unixepoch()-15552000 ORDER BY created_at,id LIMIT 128)");
    const source = observation.source.text();
    var review_exclusion_id: ?i64 = null;
    var exclusion: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT id FROM anticheat_review_exclusions WHERE user_id=?1 AND revoked_at IS NULL AND expires_at>unixepoch() AND (scope='all' OR scope=?2) ORDER BY (scope=?2) DESC,created_at DESC,id DESC LIMIT 1", -1, &exclusion, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(exclusion);
    _ = c.sqlite3_bind_int(exclusion, 1, user_id);
    _ = c.sqlite3_bind_text(exclusion, 2, source.ptr, @intCast(source.len), null);
    switch (c.sqlite3_step(exclusion)) {
        c.SQLITE_ROW => review_exclusion_id = c.sqlite3_column_int64(exclusion, 0),
        c.SQLITE_DONE => {},
        else => return error.DatabaseQueryFailed,
    }
    if (observation.score_id == null) {
        var existing: ?*c.sqlite3_stmt = null;
        const existing_sql = "SELECT id FROM anticheat_observations WHERE user_id=?1 AND score_id IS NULL AND review_label='pending' AND source=?3 AND module=?4 AND action=?5 AND sample_weight=?6 AND reason=?7 AND risk_score=?8 AND confidence_bps=?9 AND evidence=?10 AND decision_flags=?11 AND rule_revision=?12 AND objects_checked=?13 AND matched_clicks=?14 AND mean_abs_timing_error_milli=?15 AND timing_stddev_milli=?16 AND exact_timing_bps=?17 AND center_hits_bps=?18 AND mean_center_distance_milli=?19 AND snap_events=?20 AND replay_match_count=?21 AND key_press_count=?22 AND key_hold_count=?23 AND mean_hold_duration_milli=?24 AND hold_duration_stddev_milli=?25 AND alternation_bps=?26 AND target_distance_stddev_milli=?27 AND velocity_spike_count=?28 AND movement_velocity_stddev_milli=?29 AND coalesce(review_exclusion_id,0)=?30 AND created_at>=unixepoch()-86400 ORDER BY id DESC LIMIT 1";
        if (c.sqlite3_prepare_v2(self.db, existing_sql, -1, &existing, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(existing);
        _ = c.sqlite3_bind_int(existing, 1, user_id);
        _ = c.sqlite3_bind_null(existing, 2);
        _ = c.sqlite3_bind_text(existing, 3, source.ptr, @intCast(source.len), null);
        _ = c.sqlite3_bind_text(existing, 4, observation.module.ptr, @intCast(observation.module.len), null);
        _ = c.sqlite3_bind_int64(existing, 5, observation.action);
        _ = c.sqlite3_bind_int64(existing, 6, observation.sample_weight);
        _ = c.sqlite3_bind_int64(existing, 7, observation.reason);
        _ = c.sqlite3_bind_int64(existing, 8, observation.risk_score);
        _ = c.sqlite3_bind_int64(existing, 9, observation.confidence_bps);
        _ = c.sqlite3_bind_int64(existing, 10, @intCast(observation.evidence));
        _ = c.sqlite3_bind_int64(existing, 11, @intCast(observation.decision_flags));
        _ = c.sqlite3_bind_int64(existing, 12, observation.rule_revision);
        _ = c.sqlite3_bind_int64(existing, 13, observation.objects_checked);
        _ = c.sqlite3_bind_int64(existing, 14, observation.matched_clicks);
        _ = c.sqlite3_bind_int64(existing, 15, observation.mean_abs_timing_error_milli);
        _ = c.sqlite3_bind_int64(existing, 16, observation.timing_stddev_milli);
        _ = c.sqlite3_bind_int64(existing, 17, observation.exact_timing_bps);
        _ = c.sqlite3_bind_int64(existing, 18, observation.center_hits_bps);
        _ = c.sqlite3_bind_int64(existing, 19, observation.mean_center_distance_milli);
        _ = c.sqlite3_bind_int64(existing, 20, observation.snap_events);
        _ = c.sqlite3_bind_int64(existing, 21, observation.replay_match_count);
        _ = c.sqlite3_bind_int64(existing, 22, observation.key_press_count);
        _ = c.sqlite3_bind_int64(existing, 23, observation.key_hold_count);
        _ = c.sqlite3_bind_int64(existing, 24, observation.mean_hold_duration_milli);
        _ = c.sqlite3_bind_int64(existing, 25, observation.hold_duration_stddev_milli);
        _ = c.sqlite3_bind_int64(existing, 26, observation.alternation_bps);
        _ = c.sqlite3_bind_int64(existing, 27, observation.target_distance_stddev_milli);
        _ = c.sqlite3_bind_int64(existing, 28, observation.velocity_spike_count);
        _ = c.sqlite3_bind_int64(existing, 29, observation.movement_velocity_stddev_milli);
        _ = c.sqlite3_bind_int64(existing, 30, review_exclusion_id orelse 0);
        if (c.sqlite3_step(existing) == c.SQLITE_ROW) {
            const observation_id = c.sqlite3_column_int64(existing, 0);
            try self.exec("COMMIT");
            return observation_id;
        }
    }
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO anticheat_observations(user_id,score_id,source,module,action,sample_weight,reason,risk_score,confidence_bps,evidence,decision_flags,rule_revision,objects_checked,matched_clicks,mean_abs_timing_error_milli,timing_stddev_milli,exact_timing_bps,center_hits_bps,mean_center_distance_milli,snap_events,replay_match_count,key_press_count,key_hold_count,mean_hold_duration_milli,hold_duration_stddev_milli,alternation_bps,target_distance_stddev_milli,velocity_spike_count,movement_velocity_stddev_milli,review_exclusion_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30)";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, user_id);
    if (observation.score_id) |score_id|
        _ = c.sqlite3_bind_int64(stmt, 2, score_id)
    else
        _ = c.sqlite3_bind_null(stmt, 2);
    _ = c.sqlite3_bind_text(stmt, 3, source.ptr, @intCast(source.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, observation.module.ptr, @intCast(observation.module.len), null);
    _ = c.sqlite3_bind_int64(stmt, 5, observation.action);
    _ = c.sqlite3_bind_int64(stmt, 6, observation.sample_weight);
    _ = c.sqlite3_bind_int64(stmt, 7, observation.reason);
    _ = c.sqlite3_bind_int64(stmt, 8, observation.risk_score);
    _ = c.sqlite3_bind_int64(stmt, 9, observation.confidence_bps);
    _ = c.sqlite3_bind_int64(stmt, 10, @intCast(observation.evidence));
    _ = c.sqlite3_bind_int64(stmt, 11, @intCast(observation.decision_flags));
    _ = c.sqlite3_bind_int64(stmt, 12, observation.rule_revision);
    _ = c.sqlite3_bind_int64(stmt, 13, observation.objects_checked);
    _ = c.sqlite3_bind_int64(stmt, 14, observation.matched_clicks);
    _ = c.sqlite3_bind_int64(stmt, 15, observation.mean_abs_timing_error_milli);
    _ = c.sqlite3_bind_int64(stmt, 16, observation.timing_stddev_milli);
    _ = c.sqlite3_bind_int64(stmt, 17, observation.exact_timing_bps);
    _ = c.sqlite3_bind_int64(stmt, 18, observation.center_hits_bps);
    _ = c.sqlite3_bind_int64(stmt, 19, observation.mean_center_distance_milli);
    _ = c.sqlite3_bind_int64(stmt, 20, observation.snap_events);
    _ = c.sqlite3_bind_int64(stmt, 21, observation.replay_match_count);
    _ = c.sqlite3_bind_int64(stmt, 22, observation.key_press_count);
    _ = c.sqlite3_bind_int64(stmt, 23, observation.key_hold_count);
    _ = c.sqlite3_bind_int64(stmt, 24, observation.mean_hold_duration_milli);
    _ = c.sqlite3_bind_int64(stmt, 25, observation.hold_duration_stddev_milli);
    _ = c.sqlite3_bind_int64(stmt, 26, observation.alternation_bps);
    _ = c.sqlite3_bind_int64(stmt, 27, observation.target_distance_stddev_milli);
    _ = c.sqlite3_bind_int64(stmt, 28, observation.velocity_spike_count);
    _ = c.sqlite3_bind_int64(stmt, 29, observation.movement_velocity_stddev_milli);
    if (review_exclusion_id) |id|
        _ = c.sqlite3_bind_int64(stmt, 30, id)
    else
        _ = c.sqlite3_bind_null(stmt, 30);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    const observation_id = c.sqlite3_last_insert_rowid(self.db);
    var detail_buf: [560]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "observation_id={d} module={s} source={s} score_id={d} mode=observe action={d} sample_weight={d} reason={d} risk={d} confidence_bps={d} evidence={d} replay_match_count={d} rule_revision={d} review_exclusion_id={d}", .{
        observation_id,
        observation.module,
        source,
        observation.score_id orelse 0,
        observation.action,
        observation.sample_weight,
        observation.reason,
        observation.risk_score,
        observation.confidence_bps,
        observation.evidence,
        observation.replay_match_count,
        observation.rule_revision,
        review_exclusion_id orelse 0,
    });
    try self.insertAuditLocked(3, "anticheat.observe", user_id, detail);
    try self.exec("COMMIT");
    return observation_id;
}

pub fn crossAccountReplayMatches(self: *Store, user_id: i32, digest: *const [32]u8) !u32 {
    if (user_id <= 0) return error.InvalidUser;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT count(DISTINCT other_fp.user_id) FROM anticheat_replay_fingerprints current_fp JOIN scores current_score ON current_score.id=current_fp.score_id JOIN anticheat_replay_fingerprints other_fp ON other_fp.replay_sha256=current_fp.replay_sha256 AND other_fp.user_id!=current_fp.user_id AND other_fp.user_id!=3 JOIN scores other_score ON other_score.id=other_fp.score_id WHERE current_fp.replay_sha256=?1 AND current_fp.user_id=?2 AND current_score.passed=1 AND other_score.passed=1 AND other_score.map_md5=current_score.map_md5 AND other_score.mode=current_score.mode";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, digest, digest.len, null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return @intCast(@min(@as(i64, 100_000), c.sqlite3_column_int64(stmt, 0)));
}

pub fn recordReplayFingerprint(self: *Store, user_id: i32, score_id: i64, digest: *const [32]u8) !void {
    if (user_id <= 0 or score_id <= 0) return error.InvalidReplayFingerprint;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO anticheat_replay_fingerprints(score_id,user_id,replay_sha256) SELECT id,user_id,?1 FROM scores WHERE id=?2 AND user_id=?3 ON CONFLICT(score_id) DO NOTHING";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, digest, digest.len, null);
    _ = c.sqlite3_bind_int64(stmt, 2, score_id);
    _ = c.sqlite3_bind_int(stmt, 3, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn crossAccountReplayContentMatches(self: *Store, user_id: i32, map_md5: []const u8, mode: u8, digest: *const [32]u8) !u32 {
    if (user_id <= 0 or map_md5.len != 32 or mode > 3) return error.InvalidReplayFingerprint;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT count(DISTINCT fp.user_id) FROM anticheat_replay_fingerprints fp JOIN scores score ON score.id=fp.score_id WHERE fp.replay_content_sha256=?1 AND fp.user_id!=?2 AND fp.user_id!=3 AND score.passed=1 AND score.map_md5=?3 AND score.mode=?4";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, digest, digest.len, null);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_text(stmt, 3, map_md5.ptr, @intCast(map_md5.len), null);
    _ = c.sqlite3_bind_int(stmt, 4, mode);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return @intCast(@min(@as(i64, 100_000), c.sqlite3_column_int64(stmt, 0)));
}

pub fn recordReplayContentFingerprint(self: *Store, user_id: i32, score_id: i64, digest: *const [32]u8) !void {
    if (user_id <= 0 or score_id <= 0) return error.InvalidReplayFingerprint;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "UPDATE anticheat_replay_fingerprints SET replay_content_sha256=?1 WHERE score_id=?2 AND user_id=?3";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, digest, digest.len, null);
    _ = c.sqlite3_bind_int64(stmt, 2, score_id);
    _ = c.sqlite3_bind_int(stmt, 3, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.InvalidReplayFingerprint;
}

pub fn staffAnticheatJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var pending_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT (SELECT count(*) FROM anticheat_observations WHERE review_label='pending' AND review_exclusion_id IS NULL),(SELECT count(*) FROM anticheat_observations WHERE review_label='pending' AND review_exclusion_id IS NOT NULL)", -1, &pending_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(pending_stmt);
    if (c.sqlite3_step(pending_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    const pending = c.sqlite3_column_int64(pending_stmt, 0);
    const suppressed_pending = c.sqlite3_column_int64(pending_stmt, 1);

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT o.id,o.user_id,u.name,coalesce(o.score_id,0),o.source,o.module,o.action,o.sample_weight,o.reason,o.risk_score,o.confidence_bps,o.evidence,o.decision_flags,o.rule_revision,o.objects_checked,o.matched_clicks,o.mean_abs_timing_error_milli,o.timing_stddev_milli,o.exact_timing_bps,o.center_hits_bps,o.mean_center_distance_milli,o.snap_events,o.replay_match_count,o.key_press_count,o.key_hold_count,o.mean_hold_duration_milli,o.hold_duration_stddev_milli,o.alternation_bps,o.target_distance_stddev_milli,o.velocity_spike_count,o.movement_velocity_stddev_milli,o.review_label,coalesce(reviewer.name,''),o.review_note,coalesce(o.reviewed_at,0),o.created_at,coalesce(x.id,0),coalesce(x.scope,''),coalesce(x.reason,''),coalesce(creator.name,''),coalesce(x.created_at,0),coalesce(x.expires_at,0),coalesce(revoker.name,''),coalesce(x.revoked_at,0),coalesce(x.revoke_reason,'') FROM anticheat_observations o JOIN users u ON u.id=o.user_id LEFT JOIN users reviewer ON reviewer.id=o.reviewer_id LEFT JOIN anticheat_review_exclusions x ON x.id=o.review_exclusion_id LEFT JOIN users creator ON creator.id=x.created_by LEFT JOIN users revoker ON revoker.id=x.revoked_by WHERE o.id IN(SELECT id FROM anticheat_observations WHERE review_label='pending' AND review_exclusion_id IS NULL ORDER BY created_at DESC,id DESC LIMIT 250) OR o.id IN(SELECT id FROM anticheat_observations WHERE review_label='pending' AND review_exclusion_id IS NOT NULL ORDER BY created_at DESC,id DESC LIMIT 250) OR o.id IN(SELECT id FROM anticheat_observations WHERE review_label!='pending' ORDER BY created_at DESC,id DESC LIMIT 250) ORDER BY (o.review_label='pending' AND o.review_exclusion_id IS NULL) DESC,(o.review_label='pending' AND o.review_exclusion_id IS NOT NULL) DESC,o.created_at DESC,o.id DESC";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"pending\":{d},\"suppressed_pending\":{d},\"policy\":", .{ pending, suppressed_pending });
    try anticheat_review.writePolicyJson(&output.writer);
    try output.writer.writeAll(",\"exclusions\":[");
    var exclusions: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT x.id,x.user_id,u.name,x.scope,x.reason,creator.name,x.created_at,x.expires_at,coalesce(revoker.name,''),coalesce(x.revoked_at,0),x.revoke_reason,(x.revoked_at IS NULL AND x.expires_at>unixepoch()) FROM anticheat_review_exclusions x JOIN users u ON u.id=x.user_id JOIN users creator ON creator.id=x.created_by LEFT JOIN users revoker ON revoker.id=x.revoked_by WHERE x.id IN(SELECT id FROM anticheat_review_exclusions WHERE revoked_at IS NULL AND expires_at>unixepoch() ORDER BY created_at DESC,id DESC LIMIT 200) OR x.id IN(SELECT id FROM anticheat_review_exclusions WHERE revoked_at IS NOT NULL OR expires_at<=unixepoch() ORDER BY created_at DESC,id DESC LIMIT 200) ORDER BY (x.revoked_at IS NULL AND x.expires_at>unixepoch()) DESC,x.created_at DESC,x.id DESC", -1, &exclusions, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(exclusions);
    var first_exclusion = true;
    while (c.sqlite3_step(exclusions) == c.SQLITE_ROW) {
        if (!first_exclusion) try output.writer.writeByte(',');
        first_exclusion = false;
        try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ c.sqlite3_column_int64(exclusions, 0), c.sqlite3_column_int(exclusions, 1) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(exclusions, 2)));
        try output.writer.writeAll(",\"scope\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(exclusions, 3)));
        try output.writer.writeAll(",\"reason\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(exclusions, 4)));
        try output.writer.writeAll(",\"created_by\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(exclusions, 5)));
        try output.writer.print(",\"created_at\":{d},\"expires_at\":{d},\"revoked_by\":", .{ c.sqlite3_column_int64(exclusions, 6), c.sqlite3_column_int64(exclusions, 7) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(exclusions, 8)));
        try output.writer.print(",\"revoked_at\":{d},\"revoke_reason\":", .{c.sqlite3_column_int64(exclusions, 9)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(exclusions, 10)));
        try output.writer.print(",\"active\":{}}}", .{c.sqlite3_column_int(exclusions, 11) != 0});
    }
    try output.writer.writeAll("],\"observations\":[");
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ c.sqlite3_column_int64(stmt, 0), c.sqlite3_column_int(stmt, 1) });
        try std.json.Stringify.value(std.mem.span(c.sqlite3_column_text(stmt, 2)), .{}, &output.writer);
        try output.writer.print(",\"score_id\":{d},\"source\":", .{c.sqlite3_column_int64(stmt, 3)});
        try std.json.Stringify.value(std.mem.span(c.sqlite3_column_text(stmt, 4)), .{}, &output.writer);
        try output.writer.writeAll(",\"module\":");
        try std.json.Stringify.value(std.mem.span(c.sqlite3_column_text(stmt, 5)), .{}, &output.writer);
        try output.writer.print(",\"action\":{d},\"sample_weight\":{d},\"reason\":{d},\"risk\":{d},\"confidence_bps\":{d},\"evidence\":{d},\"decision_flags\":{d},\"rule_revision\":{d},\"objects\":{d},\"clicks\":{d},\"mean_timing_milli\":{d},\"timing_stddev_milli\":{d},\"exact_timing_bps\":{d},\"center_hits_bps\":{d},\"mean_center_distance_milli\":{d},\"snaps\":{d},\"replay_match_count\":{d},\"key_press_count\":{d},\"key_hold_count\":{d},\"mean_hold_duration_milli\":{d},\"hold_duration_stddev_milli\":{d},\"alternation_bps\":{d},\"target_distance_stddev_milli\":{d},\"velocity_spike_count\":{d},\"movement_velocity_stddev_milli\":{d},\"review_label\":", .{
            c.sqlite3_column_int64(stmt, 6),  c.sqlite3_column_int64(stmt, 7),  c.sqlite3_column_int64(stmt, 8),  c.sqlite3_column_int64(stmt, 9),
            c.sqlite3_column_int64(stmt, 10), c.sqlite3_column_int64(stmt, 11), c.sqlite3_column_int64(stmt, 12), c.sqlite3_column_int64(stmt, 13),
            c.sqlite3_column_int64(stmt, 14), c.sqlite3_column_int64(stmt, 15), c.sqlite3_column_int64(stmt, 16), c.sqlite3_column_int64(stmt, 17),
            c.sqlite3_column_int64(stmt, 18), c.sqlite3_column_int64(stmt, 19), c.sqlite3_column_int64(stmt, 20), c.sqlite3_column_int64(stmt, 21),
            c.sqlite3_column_int64(stmt, 22), c.sqlite3_column_int64(stmt, 23), c.sqlite3_column_int64(stmt, 24), c.sqlite3_column_int64(stmt, 25),
            c.sqlite3_column_int64(stmt, 26), c.sqlite3_column_int64(stmt, 27), c.sqlite3_column_int64(stmt, 28), c.sqlite3_column_int64(stmt, 29),
            c.sqlite3_column_int64(stmt, 30),
        });
        try std.json.Stringify.value(std.mem.span(c.sqlite3_column_text(stmt, 31)), .{}, &output.writer);
        try output.writer.writeAll(",\"meaning\":");
        try anticheat_review.writeObservationJson(&output.writer, .{
            .action = @intCast(c.sqlite3_column_int64(stmt, 6)),
            .reason = @intCast(c.sqlite3_column_int64(stmt, 8)),
            .risk_score = @intCast(c.sqlite3_column_int64(stmt, 9)),
            .confidence_bps = @intCast(c.sqlite3_column_int64(stmt, 10)),
            .evidence = @intCast(c.sqlite3_column_int64(stmt, 11)),
            .decision_flags = @intCast(c.sqlite3_column_int64(stmt, 12)),
            .rule_revision = @intCast(c.sqlite3_column_int64(stmt, 13)),
            .metrics = .{
                .objects_checked = @intCast(c.sqlite3_column_int64(stmt, 14)),
                .matched_clicks = @intCast(c.sqlite3_column_int64(stmt, 15)),
                .mean_abs_timing_error_milli = @intCast(c.sqlite3_column_int64(stmt, 16)),
                .timing_stddev_milli = @intCast(c.sqlite3_column_int64(stmt, 17)),
                .exact_timing_bps = @intCast(c.sqlite3_column_int64(stmt, 18)),
                .center_hits_bps = @intCast(c.sqlite3_column_int64(stmt, 19)),
                .mean_center_distance_milli = @intCast(c.sqlite3_column_int64(stmt, 20)),
                .snap_events = @intCast(c.sqlite3_column_int64(stmt, 21)),
                .replay_match_count = @intCast(c.sqlite3_column_int64(stmt, 22)),
                .key_press_count = @intCast(c.sqlite3_column_int64(stmt, 23)),
                .key_hold_count = @intCast(c.sqlite3_column_int64(stmt, 24)),
                .mean_hold_duration_milli = @intCast(c.sqlite3_column_int64(stmt, 25)),
                .hold_duration_stddev_milli = @intCast(c.sqlite3_column_int64(stmt, 26)),
                .alternation_bps = @intCast(c.sqlite3_column_int64(stmt, 27)),
                .target_distance_stddev_milli = @intCast(c.sqlite3_column_int64(stmt, 28)),
                .velocity_spike_count = @intCast(c.sqlite3_column_int64(stmt, 29)),
                .movement_velocity_stddev_milli = @intCast(c.sqlite3_column_int64(stmt, 30)),
            },
        });
        try output.writer.writeAll(",\"reviewer\":");
        try std.json.Stringify.value(std.mem.span(c.sqlite3_column_text(stmt, 32)), .{}, &output.writer);
        try output.writer.writeAll(",\"review_note\":");
        try std.json.Stringify.value(std.mem.span(c.sqlite3_column_text(stmt, 33)), .{}, &output.writer);
        try output.writer.print(",\"reviewed_at\":{d},\"created_at\":{d}", .{ c.sqlite3_column_int64(stmt, 34), c.sqlite3_column_int64(stmt, 35) });
        const exclusion_id = c.sqlite3_column_int64(stmt, 36);
        if (exclusion_id == 0) {
            try output.writer.writeAll(",\"review_suppressed\":false,\"review_exclusion\":null");
        } else {
            try output.writer.print(",\"review_suppressed\":true,\"review_exclusion\":{{\"id\":{d},\"scope\":", .{exclusion_id});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 37)));
            try output.writer.writeAll(",\"reason\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 38)));
            try output.writer.writeAll(",\"created_by\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 39)));
            try output.writer.print(",\"created_at\":{d},\"expires_at\":{d},\"revoked_by\":", .{ c.sqlite3_column_int64(stmt, 40), c.sqlite3_column_int64(stmt, 41) });
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 42)));
            try output.writer.print(",\"revoked_at\":{d},\"revoke_reason\":", .{c.sqlite3_column_int64(stmt, 43)});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 44)));
            try output.writer.writeByte('}');
        }
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn reviewAnticheatObservation(self: *Store, actor_id: i32, observation_id: i64, label: AnticheatReviewLabel, note: []const u8) !void {
    const trimmed = std.mem.trim(u8, note, " \t\r\n");
    if (actor_id <= 0 or observation_id <= 0 or trimmed.len < 3 or trimmed.len > 1000 or !std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidAnticheatReview;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var lookup: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT user_id FROM anticheat_observations WHERE id=?1", -1, &lookup, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(lookup);
    _ = c.sqlite3_bind_int64(lookup, 1, observation_id);
    if (c.sqlite3_step(lookup) != c.SQLITE_ROW) return error.AnticheatObservationNotFound;
    const user_id = c.sqlite3_column_int(lookup, 0);

    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE anticheat_observations SET review_label=?1,reviewer_id=?2,review_note=?3,reviewed_at=unixepoch() WHERE id=?4", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    const label_text = label.text();
    _ = c.sqlite3_bind_text(update, 1, label_text.ptr, @intCast(label_text.len), null);
    _ = c.sqlite3_bind_int(update, 2, actor_id);
    _ = c.sqlite3_bind_text(update, 3, trimmed.ptr, @intCast(trimmed.len), null);
    _ = c.sqlite3_bind_int64(update, 4, observation_id);
    if (c.sqlite3_step(update) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.DatabaseQueryFailed;
    var detail_buf: [1120]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "observation_id={d} label={s} note={s}", .{ observation_id, label_text, trimmed });
    try self.insertAuditLocked(actor_id, "anticheat.review", user_id, detail);
    try self.exec("COMMIT");
}
