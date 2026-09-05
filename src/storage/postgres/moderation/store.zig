const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const stable_score = @import("../../../stable_score.zig");
const beatmap = @import("../../../beatmap.zig");
const server_control = @import("../../../server_control.zig");
const account_roles = @import("../../../account_roles.zig");
const anticheat_review = @import("../../../anticheat_review.zig");
const postgres_stable_sessions = @import("../../../postgres_stable_sessions.zig");
const common = @import("../common.zig");
const pg_score_maintenance = @import("../scores/maintenance.zig");

const ClientHardware = storage_contracts.ClientHardware;
const HardwareEvidence = storage_contracts.HardwareEvidence;
const AnticheatExclusionScope = storage_contracts.AnticheatExclusionScope;
const AnticheatReviewLabel = storage_contracts.AnticheatReviewLabel;
const AnticheatObservation = storage_contracts.AnticheatObservation;
const schema_version = common.schema_version;

pub fn insertHardwareMatchAudit(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, target_user_id: i32, detail: []const u8) !void {
    var target_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_user_id});
    var result = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) SELECT 3,'anticheat.hardware_match',$1,$2 WHERE NOT EXISTS(SELECT 1 FROM zigcho.audit_log WHERE actor_id=3 AND action='anticheat.hardware_match' AND target=$1 AND detail=$2 AND created_at>=extract(epoch FROM clock_timestamp())::bigint-86400)", &.{ target, detail });
    result.deinit();
}

fn requireAnticheatExclusionAuthority(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, actor_id: i32, user_id: i32, actor: []const u8, user: []const u8) !void {
    var result = try postgres.queryParams(allocator, conn, "SELECT id,restricted,privileges FROM zigcho.users WHERE id IN($1,$2) ORDER BY id FOR UPDATE", &.{ actor, user });
    defer result.deinit();
    if (result.rows() != 2) return error.AnticheatExclusionUserNotFound;
    var found: u8 = 0;
    var actor_restricted = false;
    var actor_privileges: u32 = 0;
    var user_privileges: u32 = 0;
    for (0..result.rows()) |row| {
        const id = try result.int(i32, row, 0);
        if (id == actor_id) {
            actor_restricted = try result.boolean(row, 1);
            actor_privileges = try result.int(u32, row, 2);
            found |= 1;
        } else if (id == user_id) {
            user_privileges = try result.int(u32, row, 2);
            found |= 2;
        }
    }
    if (found != 3) return error.AnticheatExclusionUserNotFound;
    if (!storage_contracts.canManageAnticheatExclusion(actor_id, user_id, actor_restricted, actor_privileges, user_privileges)) return error.AnticheatExclusionForbidden;
}

pub fn createAnticheatExclusion(self: anytype, actor_id: i32, user_id: i32, scope: AnticheatExclusionScope, duration_seconds: i64, reason: []const u8) !i64 {
    const trimmed = try storage_contracts.validateAnticheatExclusion(actor_id, user_id, duration_seconds, reason);
    var actor_buf: [24]u8 = undefined;
    var user_buf: [24]u8 = undefined;
    var duration_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const duration = try std.fmt.bufPrint(&duration_buf, "{d}", .{duration_seconds});
    const scope_text = scope.text();
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try requireAnticheatExclusionAuthority(self.allocator, lease.conn, actor_id, user_id, actor, user);
    var overlap = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.anticheat_review_exclusions WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND (scope='all' OR $2='all' OR scope=$2) LIMIT 1", &.{ user, scope_text });
    defer overlap.deinit();
    if (overlap.rows() != 0) return error.AnticheatExclusionOverlap;
    var insert = try postgres.queryParams(self.allocator, lease.conn, "WITH stamp AS (SELECT extract(epoch FROM statement_timestamp())::bigint AS now) INSERT INTO zigcho.anticheat_review_exclusions(user_id,scope,reason,created_by,created_at,expires_at) SELECT $1,$2,$3,$4,now,now+$5::bigint FROM stamp RETURNING id,expires_at", &.{ user, scope_text, trimmed, actor, duration });
    defer insert.deinit();
    const exclusion_id = try insert.int(i64, 0, 0);
    const expires_at = try insert.int(i64, 0, 1);
    var detail_buf: [760]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "exclusion_id={d} scope={s} expires_at={d} reason={s}", .{ exclusion_id, scope_text, expires_at, trimmed });
    try common.insertAudit(self.allocator, lease.conn, actor_id, "anticheat.review_exclusion.create", user_id, detail);
    try postgres.exec(lease.conn, "COMMIT");
    return exclusion_id;
}

pub fn anticheatExclusionTarget(self: anytype, exclusion_id: i64) !?i32 {
    if (exclusion_id <= 0) return null;
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{exclusion_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id FROM zigcho.anticheat_review_exclusions WHERE id=$1", &.{id});
    defer result.deinit();
    return if (result.rows() == 0) null else try result.int(i32, 0, 0);
}

pub fn revokeAnticheatExclusion(self: anytype, actor_id: i32, exclusion_id: i64, reason: []const u8) !void {
    const trimmed = try storage_contracts.validateAnticheatExclusionRevocation(actor_id, exclusion_id, reason);
    var actor_buf: [24]u8 = undefined;
    var id_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{exclusion_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var target = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id FROM zigcho.anticheat_review_exclusions WHERE id=$1", &.{id});
    defer target.deinit();
    if (target.rows() == 0) return error.AnticheatExclusionNotActive;
    const user_id = try target.int(i32, 0, 0);
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    try requireAnticheatExclusionAuthority(self.allocator, lease.conn, actor_id, user_id, actor, user);
    var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.anticheat_review_exclusions SET revoked_by=$1,revoked_at=extract(epoch FROM clock_timestamp())::bigint,revoke_reason=$2 WHERE id=$3 AND user_id=$4 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint RETURNING scope", &.{ actor, trimmed, id, user });
    defer update.deinit();
    if (update.rows() == 0) return error.AnticheatExclusionNotActive;
    var detail_buf: [720]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "exclusion_id={d} scope={s} reason={s}", .{ exclusion_id, update.value(0, 0), trimmed });
    try common.insertAudit(self.allocator, lease.conn, actor_id, "anticheat.review_exclusion.revoke", user_id, detail);
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn recordAnticheatObservation(self: anytype, user_id: i32, observation: AnticheatObservation) !i64 {
    try storage_contracts.validateAnticheatObservation(user_id, observation);
    var buffers: [33][64]u8 = undefined;
    var cursor: usize = 0;
    var params: [30]?[]const u8 = undefined;
    params[0] = try common.param(&buffers, &cursor, user_id);
    params[1] = if (observation.score_id) |score_id| try common.param(&buffers, &cursor, score_id) else null;
    params[2] = observation.source.text();
    params[3] = observation.module;
    params[4] = try common.param(&buffers, &cursor, observation.action);
    params[5] = try common.param(&buffers, &cursor, observation.sample_weight);
    params[6] = try common.param(&buffers, &cursor, observation.reason);
    params[7] = try common.param(&buffers, &cursor, observation.risk_score);
    params[8] = try common.param(&buffers, &cursor, observation.confidence_bps);
    params[9] = try common.param(&buffers, &cursor, observation.evidence);
    params[10] = try common.param(&buffers, &cursor, observation.decision_flags);
    params[11] = try common.param(&buffers, &cursor, observation.rule_revision);
    params[12] = try common.param(&buffers, &cursor, observation.objects_checked);
    params[13] = try common.param(&buffers, &cursor, observation.matched_clicks);
    params[14] = try common.param(&buffers, &cursor, observation.mean_abs_timing_error_milli);
    params[15] = try common.param(&buffers, &cursor, observation.timing_stddev_milli);
    params[16] = try common.param(&buffers, &cursor, observation.exact_timing_bps);
    params[17] = try common.param(&buffers, &cursor, observation.center_hits_bps);
    params[18] = try common.param(&buffers, &cursor, observation.mean_center_distance_milli);
    params[19] = try common.param(&buffers, &cursor, observation.snap_events);
    params[20] = try common.param(&buffers, &cursor, observation.replay_match_count);
    params[21] = try common.param(&buffers, &cursor, observation.key_press_count);
    params[22] = try common.param(&buffers, &cursor, observation.key_hold_count);
    params[23] = try common.param(&buffers, &cursor, observation.mean_hold_duration_milli);
    params[24] = try common.param(&buffers, &cursor, observation.hold_duration_stddev_milli);
    params[25] = try common.param(&buffers, &cursor, observation.alternation_bps);
    params[26] = try common.param(&buffers, &cursor, observation.target_distance_stddev_milli);
    params[27] = try common.param(&buffers, &cursor, observation.velocity_spike_count);
    params[28] = try common.param(&buffers, &cursor, observation.movement_velocity_stddev_milli);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var user_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE id=$1 FOR UPDATE", &.{params[0]});
    defer user_lock.deinit();
    try postgres.exec(lease.conn, "DELETE FROM zigcho.anticheat_observations WHERE id IN (SELECT id FROM zigcho.anticheat_observations WHERE score_id IS NULL AND source!='stable_score' AND ((review_label!='pending' AND reviewed_at<extract(epoch FROM clock_timestamp())::bigint-15552000) OR (review_label='pending' AND created_at<extract(epoch FROM clock_timestamp())::bigint-7776000)) ORDER BY created_at,id LIMIT 128)");
    try postgres.exec(lease.conn, "DELETE FROM zigcho.audit_log WHERE id IN (SELECT id FROM zigcho.audit_log WHERE ((action='anticheat.observe' AND detail LIKE '% score_id=0 mode=observe %') OR action IN('anticheat.hardware_match','stable.lastfm_flag')) AND created_at<extract(epoch FROM clock_timestamp())::bigint-15552000 ORDER BY created_at,id LIMIT 128)");
    var active_exclusion = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.anticheat_review_exclusions WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND (scope='all' OR scope=$2) ORDER BY (scope=$2) DESC,created_at DESC,id DESC LIMIT 1", &.{ params[0], params[2] });
    defer active_exclusion.deinit();
    params[29] = if (active_exclusion.rows() == 0) null else try common.param(&buffers, &cursor, try active_exclusion.int(i64, 0, 0));
    if (observation.score_id == null) {
        const coalesce_params = [_]?[]const u8{ params[0], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19], params[20], params[21], params[22], params[23], params[24], params[25], params[26], params[27], params[28], params[29] };
        var existing = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.anticheat_observations WHERE user_id=$1 AND score_id IS NULL AND review_label='pending' AND source=$2 AND module=$3 AND action=$4 AND sample_weight=$5 AND reason=$6 AND risk_score=$7 AND confidence_bps=$8 AND evidence=$9 AND decision_flags=$10 AND rule_revision=$11 AND objects_checked=$12 AND matched_clicks=$13 AND mean_abs_timing_error_milli=$14 AND timing_stddev_milli=$15 AND exact_timing_bps=$16 AND center_hits_bps=$17 AND mean_center_distance_milli=$18 AND snap_events=$19 AND replay_match_count=$20 AND key_press_count=$21 AND key_hold_count=$22 AND mean_hold_duration_milli=$23 AND hold_duration_stddev_milli=$24 AND alternation_bps=$25 AND target_distance_stddev_milli=$26 AND velocity_spike_count=$27 AND movement_velocity_stddev_milli=$28 AND coalesce(review_exclusion_id,0)=coalesce($29::bigint,0) AND created_at>=extract(epoch FROM clock_timestamp())::bigint-86400 ORDER BY id DESC LIMIT 1", &coalesce_params);
        defer existing.deinit();
        if (existing.rows() != 0) {
            const observation_id = try existing.int(i64, 0, 0);
            try postgres.exec(lease.conn, "COMMIT");
            return observation_id;
        }
    }
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.anticheat_observations(user_id,score_id,source,module,action,sample_weight,reason,risk_score,confidence_bps,evidence,decision_flags,rule_revision,objects_checked,matched_clicks,mean_abs_timing_error_milli,timing_stddev_milli,exact_timing_bps,center_hits_bps,mean_center_distance_milli,snap_events,replay_match_count,key_press_count,key_hold_count,mean_hold_duration_milli,hold_duration_stddev_milli,alternation_bps,target_distance_stddev_milli,velocity_spike_count,movement_velocity_stddev_milli,review_exclusion_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30) RETURNING id", &params);
    defer result.deinit();
    const observation_id = try result.int(i64, 0, 0);
    var detail_buf: [560]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "observation_id={d} module={s} source={s} score_id={d} mode=observe action={d} sample_weight={d} reason={d} risk={d} confidence_bps={d} evidence={d} replay_match_count={d} rule_revision={d} review_exclusion_id={s}", .{
        observation_id,
        observation.module,
        observation.source.text(),
        observation.score_id orelse 0,
        observation.action,
        observation.sample_weight,
        observation.reason,
        observation.risk_score,
        observation.confidence_bps,
        observation.evidence,
        observation.replay_match_count,
        observation.rule_revision,
        params[29] orelse "0",
    });
    try common.insertAudit(self.allocator, lease.conn, 3, "anticheat.observe", user_id, detail);
    try postgres.exec(lease.conn, "COMMIT");
    return observation_id;
}

pub fn crossAccountReplayMatches(self: anytype, user_id: i32, digest: *const [32]u8) !u32 {
    if (user_id <= 0) return error.InvalidUser;
    const encoded = try postgres.encodeBytea(self.allocator, digest);
    defer self.allocator.free(encoded);
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT least(count(DISTINCT other_fp.user_id),100000) FROM zigcho.anticheat_replay_fingerprints current_fp JOIN zigcho.scores current_score ON current_score.id=current_fp.score_id JOIN zigcho.anticheat_replay_fingerprints other_fp ON other_fp.replay_sha256=current_fp.replay_sha256 AND other_fp.user_id!=current_fp.user_id AND other_fp.user_id!=3 JOIN zigcho.scores other_score ON other_score.id=other_fp.score_id WHERE current_fp.replay_sha256=$1 AND current_fp.user_id=$2 AND current_score.passed AND other_score.passed AND other_score.map_md5=current_score.map_md5 AND other_score.mode=current_score.mode", &.{ encoded, user });
    defer result.deinit();
    return @intCast(try result.int(i64, 0, 0));
}

pub fn recordReplayFingerprint(self: anytype, user_id: i32, score_id: i64, digest: *const [32]u8) !void {
    if (user_id <= 0 or score_id <= 0) return error.InvalidReplayFingerprint;
    const encoded = try postgres.encodeBytea(self.allocator, digest);
    defer self.allocator.free(encoded);
    var user_buf: [24]u8 = undefined;
    var score_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.anticheat_replay_fingerprints(score_id,user_id,replay_sha256) SELECT id,user_id,$1 FROM zigcho.scores WHERE id=$2 AND user_id=$3 ON CONFLICT(score_id) DO NOTHING", &.{ encoded, score, user });
    result.deinit();
}

pub fn crossAccountReplayContentMatches(self: anytype, user_id: i32, map_md5: []const u8, mode: u8, digest: *const [32]u8) !u32 {
    if (user_id <= 0 or map_md5.len != 32 or mode > 3) return error.InvalidReplayFingerprint;
    const encoded = try postgres.encodeBytea(self.allocator, digest);
    defer self.allocator.free(encoded);
    var user_buf: [24]u8 = undefined;
    var mode_buf: [8]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT least(count(DISTINCT fp.user_id),100000) FROM zigcho.anticheat_replay_fingerprints fp JOIN zigcho.scores score ON score.id=fp.score_id WHERE fp.replay_content_sha256=$1 AND fp.user_id!=$2 AND fp.user_id!=3 AND score.passed AND score.map_md5=$3 AND score.mode=$4", &.{ encoded, user, map_md5, mode_text });
    defer result.deinit();
    return @intCast(try result.int(i64, 0, 0));
}

pub fn recordReplayContentFingerprint(self: anytype, user_id: i32, score_id: i64, digest: *const [32]u8) !void {
    if (user_id <= 0 or score_id <= 0) return error.InvalidReplayFingerprint;
    const encoded = try postgres.encodeBytea(self.allocator, digest);
    defer self.allocator.free(encoded);
    var user_buf: [24]u8 = undefined;
    var score_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.anticheat_replay_fingerprints SET replay_content_sha256=$1 WHERE score_id=$2 AND user_id=$3 RETURNING score_id", &.{ encoded, score, user });
    defer result.deinit();
    if (result.rows() != 1) return error.InvalidReplayFingerprint;
}

pub fn recordClientHardware(self: anytype, user_id: i32, hardware: ClientHardware) !HardwareEvidence {
    var matched: std.ArrayList(i32) = .empty;
    errdefer matched.deinit(self.allocator);
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const wine = if (hardware.running_under_wine) "true" else "false";

    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try postgres.exec(lease.conn, "LOCK TABLE zigcho.client_hardware IN SHARE ROW EXCLUSIVE MODE");
    try postgres.exec(lease.conn, "DELETE FROM zigcho.audit_log WHERE id IN (SELECT id FROM zigcho.audit_log WHERE action='anticheat.hardware_match' AND created_at<extract(epoch FROM clock_timestamp())::bigint-15552000 ORDER BY created_at,id LIMIT 128)");

    if (hardware.actionable) {
        var matches = try postgres.queryParams(self.allocator, lease.conn, "SELECT DISTINCT user_id FROM zigcho.client_hardware WHERE user_id!=$1 AND user_id!=3 AND adapters_md5=$2 AND uninstall_md5=$3 AND disk_signature_md5=$4 ORDER BY user_id", &.{ id, hardware.adapters_md5, hardware.uninstall_md5, hardware.disk_signature_md5 });
        defer matches.deinit();
        for (0..matches.rows()) |row| try matched.append(self.allocator, try matches.int(i32, row, 0));
    }

    var upsert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.client_hardware(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5,client_version,running_under_wine) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5) DO UPDATE SET client_version=excluded.client_version,running_under_wine=excluded.running_under_wine,last_seen=extract(epoch FROM clock_timestamp())::bigint,occurrences=zigcho.client_hardware.occurrences+1", &.{ id, hardware.osu_path_md5, hardware.adapters_md5, hardware.uninstall_md5, hardware.disk_signature_md5, hardware.client_version, wine });
    upsert.deinit();

    if (matched.items.len != 0) {
        var detail_buf: [128]u8 = undefined;
        for (matched.items) |matched_user_id| {
            const detail = try std.fmt.bufPrint(&detail_buf, "mode=observe exact_hardware_match matched_user:{d} match_count:{d}", .{ matched_user_id, matched.items.len });
            try insertHardwareMatchAudit(self.allocator, lease.conn, user_id, detail);
            const matched_detail = try std.fmt.bufPrint(&detail_buf, "mode=observe exact_hardware_match matched_user:{d} match_count:{d}", .{ user_id, matched.items.len });
            try insertHardwareMatchAudit(self.allocator, lease.conn, matched_user_id, matched_detail);
        }
    }

    const owned_matches = try matched.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_matches);
    try postgres.exec(lease.conn, "COMMIT");
    return .{ .allocator = self.allocator, .matched_user_ids = owned_matches };
}

pub fn recordLastFmFlag(self: anytype, user_id: i32, flags: u32) !void {
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var user_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE id=$1 FOR UPDATE", &.{user});
    defer user_lock.deinit();
    try postgres.exec(lease.conn, "DELETE FROM zigcho.audit_log WHERE id IN (SELECT id FROM zigcho.audit_log WHERE action='stable.lastfm_flag' AND created_at<extract(epoch FROM clock_timestamp())::bigint-15552000 ORDER BY created_at,id LIMIT 128)");
    var target_buf: [24]u8 = undefined;
    var detail_buf: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
    const detail = try std.fmt.bufPrint(&detail_buf, "flags:{d}", .{flags});
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) SELECT $1,'stable.lastfm_flag',$2,$3 WHERE NOT EXISTS(SELECT 1 FROM zigcho.audit_log WHERE actor_id=$1 AND action='stable.lastfm_flag' AND target=$2 AND detail=$3 AND created_at>=extract(epoch FROM clock_timestamp())::bigint-86400)", &.{ user, target, detail });
    result.deinit();
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn beatmapRankContext(self: anytype, map_md5: []const u8) !?domain.BeatmapRankContext {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM zigcho.beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=b.set_id AND n.active) FROM zigcho.beatmaps b WHERE b.md5=$1", &.{map_md5});
    defer result.deinit();
    if (result.rows() == 0) return null;
    return try rankContextFromResult(result);
}

pub fn requestBeatmapRank(self: anytype, requester_id: i32, map_md5: []const u8) !domain.BeatmapRankContext {
    var actor_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{requester_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM zigcho.beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=b.set_id AND n.active) FROM zigcho.beatmaps b WHERE b.md5=$1 FOR UPDATE", &.{map_md5});
    defer map.deinit();
    if (map.rows() == 0) return error.BeatmapNotFound;
    var context = try rankContextFromResult(map);
    if (context.status != @intFromEnum(domain.RankedStatus.pending)) return error.BeatmapNotPending;
    var set_buf: [24]u8 = undefined;
    var map_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{context.set_id});
    const map_id = try std.fmt.bufPrint(&map_buf, "{d}", .{context.map_id});
    var inserted = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_rank_requests(set_id,map_id,requester_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING 1", &.{ set, map_id, actor });
    defer inserted.deinit();
    if (inserted.rows() == 0) return error.BeatmapAlreadyRequested;
    try insertBeatmapRankEvent(self.allocator, lease.conn, context.set_id, requester_id, "request", context.status, context.status, "player request");
    context.requests += 1;
    try postgres.exec(lease.conn, "COMMIT");
    return context;
}

pub fn nominateBeatmapSet(self: anytype, actor_id: i32, map_md5: []const u8, reason: []const u8) !domain.BeatmapRankContext {
    var actor_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM zigcho.beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=b.set_id AND n.active) FROM zigcho.beatmaps b WHERE b.md5=$1 FOR UPDATE", &.{map_md5});
    defer map.deinit();
    if (map.rows() == 0) return error.BeatmapNotFound;
    var context = try rankContextFromResult(map);
    if (context.status != @intFromEnum(domain.RankedStatus.pending)) return error.BeatmapNotPending;
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{context.set_id});
    var inserted = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_nominations(set_id,nominator_id,active) VALUES($1,$2,true) ON CONFLICT(set_id,nominator_id) DO UPDATE SET active=true,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE NOT zigcho.beatmap_nominations.active RETURNING 1", &.{ set, actor });
    defer inserted.deinit();
    if (inserted.rows() == 0) return error.BeatmapAlreadyNominated;
    try insertBeatmapRankEvent(self.allocator, lease.conn, context.set_id, actor_id, "nominate", context.status, context.status, reason);
    context.nominations += 1;
    try postgres.exec(lease.conn, "COMMIT");
    return context;
}

pub fn applyBeatmapRankAction(self: anytype, actor_id: i32, map_md5: []const u8, action: domain.BeatmapRankAction, reason: []const u8) !domain.BeatmapRankContext {
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try pg_score_maintenance.history_updates.lockMaintenance(lease.conn);
    var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM zigcho.beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=b.set_id AND n.active) FROM zigcho.beatmaps b WHERE b.md5=$1 FOR UPDATE", &.{map_md5});
    defer map.deinit();
    if (map.rows() == 0) return error.BeatmapNotFound;
    var context = try rankContextFromResult(map);
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{context.set_id});
    var locked = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,status FROM zigcho.beatmaps WHERE set_id=$1 FOR UPDATE", &.{set});
    defer locked.deinit();
    if (locked.rows() == 0) return error.BeatmapNotFound;
    const current = context.status;
    var target: i8 = current;
    const action_name: []const u8 = switch (action) {
        .pending => "pending",
        .qualify => "qualify",
        .rank => "rank",
        .approve => "approve",
        .love => "love",
        .veto => "veto",
        .rollback => "rollback",
    };
    switch (action) {
        .pending, .veto => target = @intFromEnum(domain.RankedStatus.pending),
        .qualify => target = @intFromEnum(domain.RankedStatus.qualified),
        .rank => target = @intFromEnum(domain.RankedStatus.ranked),
        .approve => target = @intFromEnum(domain.RankedStatus.approved),
        .love => target = @intFromEnum(domain.RankedStatus.loved),
        .rollback => {
            var previous = try postgres.queryParams(self.allocator, lease.conn, "SELECT from_status FROM zigcho.beatmap_rank_events WHERE set_id=$1 AND from_status!=to_status ORDER BY id DESC LIMIT 1", &.{set});
            defer previous.deinit();
            if (previous.rows() == 0) return error.NothingToRollback;
            target = try previous.int(i8, 0, 0);
        },
    }
    var status_buf: [8]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buf, "{d}", .{target});
    var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET status=$1,status_frozen=true,last_update=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$2 RETURNING 1", &.{ status, set });
    defer update.deinit();
    if (update.rows() == 0) return error.BeatmapNotFound;
    if (action != .qualify) {
        var cleared = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_nominations SET active=false,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND active", &.{set});
        cleared.deinit();
        context.nominations = 0;
    }
    if (action == .rank or action == .approve or action == .love) {
        var resolved = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_rank_requests SET active=false,resolved_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND active", &.{set});
        resolved.deinit();
        context.requests = 0;
    }
    try pg_score_maintenance.rebuildRankedStats(self, lease.conn, false);
    try pg_score_maintenance.recordAllStatsHistoryCurrentWithConnection(self, lease.conn);
    try insertBeatmapRankEvent(self.allocator, lease.conn, context.set_id, actor_id, action_name, current, target, reason);
    context.status = target;
    try postgres.exec(lease.conn, "COMMIT");
    return context;
}

pub fn beatmapRankQueue(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT r.set_id,count(*),min(r.created_at),min(b.artist),min(b.title),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=r.set_id AND n.active) FROM zigcho.beatmap_rank_requests r JOIN zigcho.beatmaps b ON b.set_id=r.set_id WHERE r.active GROUP BY r.set_id ORDER BY min(r.created_at),r.set_id LIMIT 50");
    defer result.deinit();
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (0..result.rows()) |row| {
        if (output.items.len != 0) try output.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "set {d} | {d} request(s) | {d}/2 noms | {s} - {s}", .{ try result.int(i32, row, 0), try result.int(i32, row, 1), try result.int(i32, row, 5), result.value(row, 3), result.value(row, 4) });
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}

pub fn rankContextFromResult(result: postgres.Result) !domain.BeatmapRankContext {
    return .{ .map_id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .status = try result.int(i8, 0, 2), .requests = try result.int(u32, 0, 3), .nominations = try result.int(u32, 0, 4) };
}

pub fn insertBeatmapRankEvent(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, set_id: i32, actor_id: i32, action: []const u8, from_status: i8, to_status: i8, reason: []const u8) !void {
    var set_buf: [24]u8 = undefined;
    var actor_buf: [24]u8 = undefined;
    var from_buf: [8]u8 = undefined;
    var to_buf: [8]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const from = try std.fmt.bufPrint(&from_buf, "{d}", .{from_status});
    const to = try std.fmt.bufPrint(&to_buf, "{d}", .{to_status});
    var event = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.beatmap_rank_events(set_id,actor_id,action,from_status,to_status,reason) VALUES($1,$2,$3,$4,$5,$6)", &.{ set, actor, action, from, to, reason });
    event.deinit();
    var target_buf: [40]u8 = undefined;
    var audit_action_buf: [64]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "beatmapset:{d}", .{set_id});
    const audit_action = try std.fmt.bufPrint(&audit_action_buf, "beatmap.{s}", .{action});
    var audit = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, audit_action, target, reason });
    audit.deinit();
}

pub fn channelCanWrite(self: anytype, name: []const u8, privileges: u32) !bool {
    var priv_buf: [24]u8 = undefined;
    const priv_text = try std.fmt.bufPrint(&priv_buf, "{d}", .{privileges});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT CASE WHEN locked THEN ($2::bigint & 8192)=8192 ELSE ($2::bigint & write_privileges)=write_privileges END FROM zigcho.chat_channels WHERE name=$1", &.{ name, priv_text });
    defer result.deinit();
    if (result.rows() == 0) return true;
    return result.boolean(0, 0);
}

pub fn setChannelLocked(self: anytype, actor_id: i32, name: []const u8, locked: bool, reason: []const u8) !void {
    var actor_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.chat_channels SET locked=$1,updated_by=$2,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE name=$3 RETURNING 1", &.{ if (locked) "true" else "false", actor, name });
    defer update.deinit();
    if (update.rows() == 0) return error.InvalidChannel;
    var audit = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, if (locked) "channel.lock" else "channel.unlock", name, reason });
    audit.deinit();
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn setSilence(self: anytype, actor_id: i32, target_id: i32, silence_end: i64, action: []const u8, reason: []const u8) !void {
    var target_buf: [24]u8 = undefined;
    var end_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
    const end = try std.fmt.bufPrint(&end_buf, "{d}", .{silence_end});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET silence_end=$1 WHERE id=$2 AND id!=3 RETURNING 1", &.{ end, target });
    defer update.deinit();
    if (update.rows() == 0) return error.InvalidModerationTarget;
    try common.insertAudit(self.allocator, lease.conn, actor_id, action, target_id, reason);
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn setRestricted(self: anytype, actor_id: i32, target_id: i32, restricted: bool, reason: []const u8) !void {
    var target_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    try pg_score_maintenance.history_updates.lockMaintenance(lease.conn);
    var token_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{target});
    token_lock.deinit();
    var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET restricted=$1 WHERE id=$2 AND id!=3 RETURNING 1", &.{ if (restricted) "true" else "false", target });
    defer update.deinit();
    if (update.rows() == 0) return error.InvalidModerationTarget;
    try common.insertAudit(self.allocator, lease.conn, actor_id, if (restricted) "account.restrict" else "account.unrestrict", target_id, reason);
    if (restricted) {
        var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)')", &.{target});
        revoke.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{target});
        clear.deinit();
        _ = try postgres_stable_sessions.revokeWithConnection(self.allocator, lease.conn, target_id, std.Io.Clock.real.now(self.io).toSeconds());
    }
    try pg_score_maintenance.recordAllStatsHistoryCurrentWithConnection(self, lease.conn);
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn changePrivileges(self: anytype, actor_id: i32, target_id: i32, bits: u32, add: bool) !u32 {
    const role = account_roles.Role.fromBit(bits) orelse return error.InvalidRoleChange;
    return (try self.changeRole(actor_id, target_id, role, add, "legacy typed role command")).privileges;
}

pub fn changeRole(self: anytype, actor_id: i32, target_id: i32, role: account_roles.Role, grant: bool, reason: []const u8) !account_roles.ChangeResult {
    if (actor_id <= 0 or target_id <= 0 or !account_roles.validReason(reason)) return error.InvalidRoleChange;
    const definition = role.definition();
    const trimmed_reason = std.mem.trim(u8, reason, " \t\r\n");
    var actor_buf: [24]u8 = undefined;
    var target_buf: [24]u8 = undefined;
    var bit_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
    const bit = try std.fmt.bufPrint(&bit_buf, "{d}", .{definition.bit});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    const sql = if (grant)
        "UPDATE zigcho.users SET privileges=privileges | $1::bigint WHERE id=$2 AND id!=3 AND (privileges & $1::bigint)=0 RETURNING privileges"
    else
        "UPDATE zigcho.users SET privileges=privileges & ~$1::bigint WHERE id=$2 AND id!=3 AND (privileges & $1::bigint)!=0 RETURNING privileges";
    var update = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ bit, target });
    defer update.deinit();
    if (update.rows() == 0) return error.RoleStateUnchanged;
    const privileges = try update.int(u32, 0, 0);
    var staff_sessions_revoked = false;
    if (!account_roles.isStaff(privileges)) {
        var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND scopes='web:staff' AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint RETURNING token_hash", &.{target});
        defer revoke.deinit();
        staff_sessions_revoked = revoke.rows() != 0;
    }
    const detail = try std.fmt.allocPrint(self.allocator, "{s} role:{s} bit:{d} permanent:{} reason:{s}", .{ if (grant) "grant" else "revoke", @tagName(role), definition.bit, definition.permanent, trimmed_reason });
    defer self.allocator.free(detail);
    var audit = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,'account.role','user:'||$2,$3)", &.{ actor, target, detail });
    audit.deinit();
    try postgres.exec(lease.conn, "COMMIT");
    return .{ .privileges = privileges, .staff_sessions_revoked = staff_sessions_revoked };
}

pub fn addModerationNote(self: anytype, actor_id: i32, target_id: i32, note: []const u8) !void {
    var lease = self.pool.acquire();
    defer lease.release();
    try common.insertAudit(self.allocator, lease.conn, actor_id, "account.note", target_id, note);
}

pub fn recordModerationAction(self: anytype, actor_id: i32, target_id: i32, action: []const u8, detail: []const u8) !void {
    var lease = self.pool.acquire();
    defer lease.release();
    try common.insertAudit(self.allocator, lease.conn, actor_id, action, target_id, detail);
}

pub fn recordAudit(self: anytype, actor_id: i32, action: []const u8, target: []const u8, detail: []const u8) !void {
    var actor_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, action, target, detail });
    result.deinit();
}

pub fn moderationNotes(self: anytype, allocator: std.mem.Allocator, target_id: i32, limit: u8) ![]u8 {
    var target_buf: [24]u8 = undefined;
    var limit_buf: [4]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_id});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT created_at,action,coalesce(actor_id,0),coalesce(detail,'') FROM zigcho.audit_log WHERE target=$1 ORDER BY id DESC LIMIT $2", &.{ target, limit_text });
    defer result.deinit();
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (0..result.rows()) |row| {
        if (output.items.len != 0) try output.append(allocator, '\n');
        const line = try std.fmt.allocPrint(allocator, "{d} | {s} | by {d} | {s}", .{
            try result.int(i64, row, 0),
            result.value(row, 1),
            try result.int(i32, row, 2),
            result.value(row, 3),
        });
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}

pub fn createModerationAppeal(self: anytype, user_id: i32, kind: []const u8, message: []const u8) !i64 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.moderation_appeals(user_id,kind,message) VALUES($1,$2,$3) RETURNING id", &.{ id, kind, message }) catch |err| switch (err) {
        error.UniqueViolation => return error.AppealAlreadyOpen,
        else => return err,
    };
    defer result.deinit();
    return result.int(i64, 0, 0);
}

pub fn resolveModerationAppeal(self: anytype, actor_id: i32, appeal_id: i64, status: []const u8, resolution: []const u8) !void {
    var actor_buf: [24]u8 = undefined;
    var appeal_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const appeal = try std.fmt.bufPrint(&appeal_buf, "{d}", .{appeal_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.moderation_appeals SET status=$1,reviewer_id=$2,resolution=$3,resolved_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$4 AND status='open' RETURNING user_id", &.{ status, actor, resolution, appeal });
    defer update.deinit();
    if (update.rows() == 0) return error.AppealNotOpen;
    const target_id = try update.int(i32, 0, 0);
    try common.insertAudit(self.allocator, lease.conn, actor_id, if (std.mem.eql(u8, status, "accepted")) "appeal.accept" else "appeal.deny", target_id, resolution);
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn beatmapMd5ForSet(self: anytype, set_id: i32) !?[32]u8 {
    var set_buf: [24]u8 = undefined;
    const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT md5 FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY id LIMIT 1", &.{set});
    defer result.deinit();
    if (result.rows() == 0) return null;
    const value = result.value(0, 0);
    if (value.len != 32) return error.InvalidBeatmapHash;
    var out: [32]u8 = undefined;
    @memcpy(&out, value);
    return out;
}

pub fn staffAnticheatJson(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var result = try postgres.query(lease.conn, "SELECT o.id,o.user_id,u.name,coalesce(o.score_id,0),o.source,o.module,o.action,o.sample_weight,o.reason,o.risk_score,o.confidence_bps,o.evidence,o.decision_flags,o.rule_revision,o.objects_checked,o.matched_clicks,o.mean_abs_timing_error_milli,o.timing_stddev_milli,o.exact_timing_bps,o.center_hits_bps,o.mean_center_distance_milli,o.snap_events,o.replay_match_count,o.key_press_count,o.key_hold_count,o.mean_hold_duration_milli,o.hold_duration_stddev_milli,o.alternation_bps,o.target_distance_stddev_milli,o.velocity_spike_count,o.movement_velocity_stddev_milli,o.review_label,coalesce(reviewer.name,''),o.review_note,coalesce(o.reviewed_at,0),o.created_at,coalesce(x.id,0),coalesce(x.scope,''),coalesce(x.reason,''),coalesce(creator.name,''),coalesce(x.created_at,0),coalesce(x.expires_at,0),coalesce(revoker.name,''),coalesce(x.revoked_at,0),coalesce(x.revoke_reason,'') FROM zigcho.anticheat_observations o JOIN zigcho.users u ON u.id=o.user_id LEFT JOIN zigcho.users reviewer ON reviewer.id=o.reviewer_id LEFT JOIN zigcho.anticheat_review_exclusions x ON x.id=o.review_exclusion_id LEFT JOIN zigcho.users creator ON creator.id=x.created_by LEFT JOIN zigcho.users revoker ON revoker.id=x.revoked_by WHERE o.id IN(SELECT id FROM zigcho.anticheat_observations WHERE review_label='pending' AND review_exclusion_id IS NULL ORDER BY created_at DESC,id DESC LIMIT 250) OR o.id IN(SELECT id FROM zigcho.anticheat_observations WHERE review_label='pending' AND review_exclusion_id IS NOT NULL ORDER BY created_at DESC,id DESC LIMIT 250) OR o.id IN(SELECT id FROM zigcho.anticheat_observations WHERE review_label!='pending' ORDER BY created_at DESC,id DESC LIMIT 250) ORDER BY (o.review_label='pending' AND o.review_exclusion_id IS NULL) DESC,(o.review_label='pending' AND o.review_exclusion_id IS NOT NULL) DESC,o.created_at DESC,o.id DESC");
    defer result.deinit();
    var pending_result = try postgres.query(lease.conn, "SELECT count(*) FILTER(WHERE review_label='pending' AND review_exclusion_id IS NULL),count(*) FILTER(WHERE review_label='pending' AND review_exclusion_id IS NOT NULL) FROM zigcho.anticheat_observations");
    defer pending_result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"pending\":{d},\"suppressed_pending\":{d},\"policy\":", .{ try pending_result.int(i64, 0, 0), try pending_result.int(i64, 0, 1) });
    try anticheat_review.writePolicyJson(&output.writer);
    try output.writer.writeAll(",\"exclusions\":[");
    var exclusions = try postgres.query(lease.conn, "SELECT x.id,x.user_id,u.name,x.scope,x.reason,creator.name,x.created_at,x.expires_at,coalesce(revoker.name,''),coalesce(x.revoked_at,0),x.revoke_reason,(x.revoked_at IS NULL AND x.expires_at>extract(epoch FROM transaction_timestamp())::bigint) FROM zigcho.anticheat_review_exclusions x JOIN zigcho.users u ON u.id=x.user_id JOIN zigcho.users creator ON creator.id=x.created_by LEFT JOIN zigcho.users revoker ON revoker.id=x.revoked_by WHERE x.id IN(SELECT id FROM zigcho.anticheat_review_exclusions WHERE revoked_at IS NULL AND expires_at>extract(epoch FROM transaction_timestamp())::bigint ORDER BY created_at DESC,id DESC LIMIT 200) OR x.id IN(SELECT id FROM zigcho.anticheat_review_exclusions WHERE revoked_at IS NOT NULL OR expires_at<=extract(epoch FROM transaction_timestamp())::bigint ORDER BY created_at DESC,id DESC LIMIT 200) ORDER BY (x.revoked_at IS NULL AND x.expires_at>extract(epoch FROM transaction_timestamp())::bigint) DESC,x.created_at DESC,x.id DESC");
    defer exclusions.deinit();
    for (0..exclusions.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ try exclusions.int(i64, row, 0), try exclusions.int(i32, row, 1) });
        try common.jsonString(&output.writer, exclusions.value(row, 2));
        try output.writer.writeAll(",\"scope\":");
        try common.jsonString(&output.writer, exclusions.value(row, 3));
        try output.writer.writeAll(",\"reason\":");
        try common.jsonString(&output.writer, exclusions.value(row, 4));
        try output.writer.writeAll(",\"created_by\":");
        try common.jsonString(&output.writer, exclusions.value(row, 5));
        try output.writer.print(",\"created_at\":{d},\"expires_at\":{d},\"revoked_by\":", .{ try exclusions.int(i64, row, 6), try exclusions.int(i64, row, 7) });
        try common.jsonString(&output.writer, exclusions.value(row, 8));
        try output.writer.print(",\"revoked_at\":{d},\"revoke_reason\":", .{try exclusions.int(i64, row, 9)});
        try common.jsonString(&output.writer, exclusions.value(row, 10));
        try output.writer.print(",\"active\":{}}}", .{try exclusions.boolean(row, 11)});
    }
    try output.writer.writeAll("],\"observations\":[");
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ try result.int(i64, row, 0), try result.int(i32, row, 1) });
        try common.jsonString(&output.writer, result.value(row, 2));
        try output.writer.print(",\"score_id\":{d},\"source\":", .{try result.int(i64, row, 3)});
        try common.jsonString(&output.writer, result.value(row, 4));
        try output.writer.writeAll(",\"module\":");
        try common.jsonString(&output.writer, result.value(row, 5));
        try output.writer.print(",\"action\":{d},\"sample_weight\":{d},\"reason\":{d},\"risk\":{d},\"confidence_bps\":{d},\"evidence\":{d},\"decision_flags\":{d},\"rule_revision\":{d},\"objects\":{d},\"clicks\":{d},\"mean_timing_milli\":{d},\"timing_stddev_milli\":{d},\"exact_timing_bps\":{d},\"center_hits_bps\":{d},\"mean_center_distance_milli\":{d},\"snaps\":{d},\"replay_match_count\":{d},\"key_press_count\":{d},\"key_hold_count\":{d},\"mean_hold_duration_milli\":{d},\"hold_duration_stddev_milli\":{d},\"alternation_bps\":{d},\"target_distance_stddev_milli\":{d},\"velocity_spike_count\":{d},\"movement_velocity_stddev_milli\":{d},\"review_label\":", .{
            try result.int(i32, row, 6),  try result.int(i32, row, 7),  try result.int(i32, row, 8),  try result.int(i32, row, 9),
            try result.int(i64, row, 10), try result.int(i64, row, 11), try result.int(i32, row, 12), try result.int(i32, row, 13),
            try result.int(i32, row, 14), try result.int(i32, row, 15), try result.int(i32, row, 16), try result.int(i32, row, 17),
            try result.int(i32, row, 18), try result.int(i32, row, 19), try result.int(i32, row, 20), try result.int(i32, row, 21),
            try result.int(i32, row, 22), try result.int(i32, row, 23), try result.int(i32, row, 24), try result.int(i32, row, 25),
            try result.int(i32, row, 26), try result.int(i32, row, 27), try result.int(i32, row, 28), try result.int(i32, row, 29),
            try result.int(i32, row, 30),
        });
        try common.jsonString(&output.writer, result.value(row, 31));
        try output.writer.writeAll(",\"meaning\":");
        try anticheat_review.writeObservationJson(&output.writer, .{
            .action = try result.int(u32, row, 6),
            .reason = try result.int(u32, row, 8),
            .risk_score = try result.int(u32, row, 9),
            .confidence_bps = try result.int(u32, row, 10),
            .evidence = try result.int(u64, row, 11),
            .decision_flags = try result.int(u64, row, 12),
            .rule_revision = try result.int(u32, row, 13),
            .metrics = .{
                .objects_checked = try result.int(u32, row, 14),
                .matched_clicks = try result.int(u32, row, 15),
                .mean_abs_timing_error_milli = try result.int(u32, row, 16),
                .timing_stddev_milli = try result.int(u32, row, 17),
                .exact_timing_bps = try result.int(u32, row, 18),
                .center_hits_bps = try result.int(u32, row, 19),
                .mean_center_distance_milli = try result.int(u32, row, 20),
                .snap_events = try result.int(u32, row, 21),
                .replay_match_count = try result.int(u32, row, 22),
                .key_press_count = try result.int(u32, row, 23),
                .key_hold_count = try result.int(u32, row, 24),
                .mean_hold_duration_milli = try result.int(u32, row, 25),
                .hold_duration_stddev_milli = try result.int(u32, row, 26),
                .alternation_bps = try result.int(u32, row, 27),
                .target_distance_stddev_milli = try result.int(u32, row, 28),
                .velocity_spike_count = try result.int(u32, row, 29),
                .movement_velocity_stddev_milli = try result.int(u32, row, 30),
            },
        });
        try output.writer.writeAll(",\"reviewer\":");
        try common.jsonString(&output.writer, result.value(row, 32));
        try output.writer.writeAll(",\"review_note\":");
        try common.jsonString(&output.writer, result.value(row, 33));
        try output.writer.print(",\"reviewed_at\":{d},\"created_at\":{d}", .{ try result.int(i64, row, 34), try result.int(i64, row, 35) });
        const exclusion_id = try result.int(i64, row, 36);
        if (exclusion_id == 0) {
            try output.writer.writeAll(",\"review_suppressed\":false,\"review_exclusion\":null");
        } else {
            try output.writer.print(",\"review_suppressed\":true,\"review_exclusion\":{{\"id\":{d},\"scope\":", .{exclusion_id});
            try common.jsonString(&output.writer, result.value(row, 37));
            try output.writer.writeAll(",\"reason\":");
            try common.jsonString(&output.writer, result.value(row, 38));
            try output.writer.writeAll(",\"created_by\":");
            try common.jsonString(&output.writer, result.value(row, 39));
            try output.writer.print(",\"created_at\":{d},\"expires_at\":{d},\"revoked_by\":", .{ try result.int(i64, row, 40), try result.int(i64, row, 41) });
            try common.jsonString(&output.writer, result.value(row, 42));
            try output.writer.print(",\"revoked_at\":{d},\"revoke_reason\":", .{try result.int(i64, row, 43)});
            try common.jsonString(&output.writer, result.value(row, 44));
            try output.writer.writeByte('}');
        }
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    try postgres.exec(lease.conn, "COMMIT");
    return output.toOwnedSlice();
}

pub fn reviewAnticheatObservation(self: anytype, actor_id: i32, observation_id: i64, label: AnticheatReviewLabel, note: []const u8) !void {
    const trimmed = std.mem.trim(u8, note, " \t\r\n");
    if (actor_id <= 0 or observation_id <= 0 or trimmed.len < 3 or trimmed.len > 1000 or !std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidAnticheatReview;
    var actor_buf: [24]u8 = undefined;
    var id_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{observation_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.anticheat_observations SET review_label=$1,reviewer_id=$2,review_note=$3,reviewed_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$4 RETURNING user_id", &.{ label.text(), actor, trimmed, id });
    defer result.deinit();
    if (result.rows() == 0) return error.AnticheatObservationNotFound;
    const user_id = try result.int(i32, 0, 0);
    var detail_buf: [1120]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "observation_id={d} label={s} note={s}", .{ observation_id, label.text(), trimmed });
    try common.insertAudit(self.allocator, lease.conn, actor_id, "anticheat.review", user_id, detail);
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn serverControlEnabled(self: anytype, feature: server_control.Feature) !bool {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT enabled FROM zigcho.server_controls WHERE key=$1", &.{feature.key()});
    defer result.deinit();
    return result.rows() == 0 or try result.boolean(0, 0);
}

pub fn staffServerControlsJson(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"schema\":{d},\"controls\":[", .{schema_version});
    for (server_control.definitions, 0..) |definition, index| {
        if (index != 0) try output.writer.writeByte(',');
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT c.enabled,c.reason,c.updated_at,coalesce(u.name,'system') FROM zigcho.server_controls c LEFT JOIN zigcho.users u ON u.id=c.updated_by WHERE c.key=$1", &.{definition.feature.key()});
        defer result.deinit();
        try output.writer.writeAll("{\"key\":");
        try common.jsonString(&output.writer, definition.feature.key());
        try output.writer.writeAll(",\"label\":");
        try common.jsonString(&output.writer, definition.label);
        try output.writer.writeAll(",\"group\":");
        try common.jsonString(&output.writer, definition.group);
        try output.writer.writeAll(",\"description\":");
        try common.jsonString(&output.writer, definition.description);
        if (result.rows() != 0) {
            try output.writer.print(",\"enabled\":{},\"reason\":", .{try result.boolean(0, 0)});
            try common.jsonString(&output.writer, result.value(0, 1));
            try output.writer.print(",\"updated_at\":{d},\"updated_by\":", .{try result.int(i64, 0, 2)});
            try common.jsonString(&output.writer, result.value(0, 3));
        } else {
            try output.writer.writeAll(",\"enabled\":true,\"reason\":\"\",\"updated_at\":0,\"updated_by\":\"system\"");
        }
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

pub fn setServerControl(self: anytype, actor_id: i32, feature: server_control.Feature, enabled: bool, reason: []const u8) !void {
    var actor_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    var target_buf: [80]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "feature:{s}", .{feature.key()});
    var detail_buf: [560]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "state={s} reason={s}", .{ if (enabled) "enabled" else "disabled", reason });
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var update = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.server_controls(key,enabled,reason,updated_by,updated_at) VALUES($1,$2,$3,$4,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(key) DO UPDATE SET enabled=excluded.enabled,reason=excluded.reason,updated_by=excluded.updated_by,updated_at=excluded.updated_at", &.{ feature.key(), if (enabled) "true" else "false", reason, actor });
    update.deinit();
    var audit = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,'infra.feature',$2,$3)", &.{ actor, target, detail });
    audit.deinit();
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn staffOverviewJson(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT (SELECT count(*) FROM zigcho.moderation_appeals WHERE status='open'),(SELECT count(DISTINCT set_id) FROM zigcho.beatmap_rank_requests WHERE active),(SELECT count(*) FROM zigcho.users WHERE restricted),(SELECT count(*) FROM zigcho.users WHERE silence_end>extract(epoch FROM clock_timestamp())::bigint),(SELECT count(*) FROM zigcho.audit_log WHERE created_at>=extract(epoch FROM clock_timestamp())::bigint-86400),(SELECT count(*) FROM zigcho.client_hardware),(SELECT count(*) FROM zigcho.anticheat_observations WHERE review_label='pending' AND review_exclusion_id IS NULL),(SELECT count(*) FROM zigcho.lazer_reports WHERE status='open')");
    defer result.deinit();
    return std.fmt.allocPrint(allocator, "{{\"open_appeals\":{d},\"ranking_sets\":{d},\"restricted_users\":{d},\"silenced_users\":{d},\"audit_24h\":{d},\"hardware_records\":{d},\"anticheat_pending\":{d},\"open_reports\":{d}}}", .{ try result.int(i64, 0, 0), try result.int(i64, 0, 1), try result.int(i64, 0, 2), try result.int(i64, 0, 3), try result.int(i64, 0, 4), try result.int(i64, 0, 5), try result.int(i64, 0, 6), try result.int(i64, 0, 7) });
}

pub fn staffUserSearchJson(self: anytype, allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    const safe = try domain.safeName(allocator, query);
    defer allocator.free(safe);
    var id_buf: [24]u8 = undefined;
    const numeric_id = std.fmt.parseInt(i32, query, 10) catch 0;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{numeric_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,u.country,u.privileges,u.restricted,u.silence_end,coalesce(u.last_login,0),coalesce(t.short_name,'') FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1 OR position(lower($2) in lower(u.name))>0 OR position($3 in u.safe_name)>0 ORDER BY CASE WHEN u.id=$1 THEN 0 WHEN u.safe_name=$3 THEN 1 WHEN lower(u.name)=lower($2) THEN 2 WHEN position($3 in u.safe_name)=1 THEN 3 ELSE 4 END,u.restricted,u.id LIMIT 20", &.{ id, query, safe });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"name\":", .{try result.int(i32, row, 0)});
        try common.jsonString(&output.writer, result.value(row, 1));
        try output.writer.writeAll(",\"country\":");
        try common.jsonString(&output.writer, result.value(row, 2));
        try output.writer.print(",\"privileges\":{d},\"restricted\":{},\"silence_end\":{d},\"last_login\":{d},\"team\":", .{ try result.int(u32, row, 3), try result.boolean(row, 4), try result.int(i64, row, 5), try result.int(i64, row, 6) });
        try common.jsonString(&output.writer, result.value(row, 7));
        try output.writer.writeByte('}');
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn staffRolesJson(self: anytype, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
    var id_buf: [24]u8 = undefined;
    var target_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var user = try postgres.queryParams(allocator, lease.conn, "SELECT id,name,country,privileges,restricted,created_at,coalesce(last_login,0) FROM zigcho.users WHERE id=$1 AND id!=3", &.{id});
    defer user.deinit();
    if (user.rows() == 0) return null;
    const privileges = try user.int(u32, 0, 3);
    var audit = try postgres.queryParams(allocator, lease.conn, "SELECT a.id,coalesce(actor.name,'system'),coalesce(a.detail,''),a.created_at FROM zigcho.audit_log a LEFT JOIN zigcho.users actor ON actor.id=a.actor_id WHERE a.target=$1 AND a.action='account.role' ORDER BY a.id DESC LIMIT 100", &.{target});
    defer audit.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"user\":{{\"id\":{d},\"name\":", .{try user.int(i32, 0, 0)});
    try common.jsonString(&output.writer, user.value(0, 1));
    try output.writer.writeAll(",\"country\":");
    try common.jsonString(&output.writer, user.value(0, 2));
    try output.writer.print(",\"privileges\":{d},\"restricted\":{},\"created_at\":{d},\"last_login\":{d}}},\"roles\":", .{ privileges, try user.boolean(0, 4), try user.int(i64, 0, 5), try user.int(i64, 0, 6) });
    try account_roles.writeCatalogJson(&output.writer, privileges);
    try output.writer.writeAll(",\"audit\":[");
    for (0..audit.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"actor\":", .{try audit.int(i64, row, 0)});
        try common.jsonString(&output.writer, audit.value(row, 1));
        try output.writer.writeAll(",\"detail\":");
        try common.jsonString(&output.writer, audit.value(row, 2));
        try output.writer.print(",\"created_at\":{d}}}", .{try audit.int(i64, row, 3)});
    }
    try output.writer.writeAll("]}");
    const owned = try output.toOwnedSlice();
    return owned;
}

pub fn lazerUserSearchIds(self: anytype, allocator: std.mem.Allocator, query: []const u8, limit: u8) ![]i32 {
    const safe = try domain.safeName(allocator, query);
    defer allocator.free(safe);
    var limit_buf: [8]u8 = undefined;
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    var rows = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE NOT restricted AND id!=3 AND (position(lower($1) in lower(name))>0 OR position($2 in safe_name)>0) ORDER BY CASE WHEN safe_name=$2 THEN 0 WHEN lower(name)=lower($1) THEN 1 WHEN position($2 in safe_name)=1 THEN 2 ELSE 3 END,id LIMIT $3", &.{ query, safe, limit_text });
    defer rows.deinit();
    const ids = try allocator.alloc(i32, rows.rows());
    errdefer allocator.free(ids);
    for (ids, 0..) |*id, row| id.* = try rows.int(i32, row, 0);
    return ids;
}

pub fn staffRankingJson(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var queue = try postgres.query(lease.conn, "SELECT r.set_id,min(b.status),count(*),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=r.set_id AND n.active),min(b.artist),min(b.title),min(b.creator),min(b.md5),min(r.created_at) FROM zigcho.beatmap_rank_requests r JOIN zigcho.beatmaps b ON b.set_id=r.set_id WHERE r.active GROUP BY r.set_id ORDER BY min(r.created_at),r.set_id LIMIT 100");
    defer queue.deinit();
    var history = try postgres.query(lease.conn, "SELECT e.id,e.set_id,e.action,e.from_status,e.to_status,e.reason,e.created_at,u.name FROM zigcho.beatmap_rank_events e JOIN zigcho.users u ON u.id=e.actor_id ORDER BY e.id DESC LIMIT 100");
    defer history.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"queue\":[");
    for (0..queue.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"set_id\":{d},\"status\":{d},\"requests\":{d},\"nominations\":{d},\"artist\":", .{ try queue.int(i32, row, 0), try queue.int(i8, row, 1), try queue.int(i32, row, 2), try queue.int(i32, row, 3) });
        try common.jsonString(&output.writer, queue.value(row, 4));
        try output.writer.writeAll(",\"title\":");
        try common.jsonString(&output.writer, queue.value(row, 5));
        try output.writer.writeAll(",\"creator\":");
        try common.jsonString(&output.writer, queue.value(row, 6));
        try output.writer.writeAll(",\"map_md5\":");
        try common.jsonString(&output.writer, queue.value(row, 7));
        try output.writer.print(",\"created_at\":{d}}}", .{try queue.int(i64, row, 8)});
    }
    try output.writer.writeAll("],\"history\":[");
    for (0..history.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"set_id\":{d},\"action\":", .{ try history.int(i64, row, 0), try history.int(i32, row, 1) });
        try common.jsonString(&output.writer, history.value(row, 2));
        try output.writer.print(",\"from_status\":{d},\"to_status\":{d},\"reason\":", .{ try history.int(i8, row, 3), try history.int(i8, row, 4) });
        try common.jsonString(&output.writer, history.value(row, 5));
        try output.writer.print(",\"created_at\":{d},\"actor\":", .{try history.int(i64, row, 6)});
        try common.jsonString(&output.writer, history.value(row, 7));
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn staffAppealsJson(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT a.id,a.user_id,u.name,u.country,a.kind,a.message,a.status,coalesce(r.name,''),coalesce(a.resolution,''),a.created_at,coalesce(a.resolved_at,0) FROM zigcho.moderation_appeals a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN zigcho.users r ON r.id=a.reviewer_id ORDER BY CASE a.status WHEN 'open' THEN 0 ELSE 1 END,a.created_at,a.id LIMIT 200");
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"appeals\":[");
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ try result.int(i64, row, 0), try result.int(i32, row, 1) });
        for (2..9) |column| {
            try common.jsonString(&output.writer, result.value(row, column));
            const names = [_][]const u8{ "country", "kind", "message", "status", "reviewer", "resolution" };
            if (column < 8) try output.writer.print(",\"{s}\":", .{names[column - 2]});
        }
        try output.writer.print(",\"created_at\":{d},\"resolved_at\":{d}}}", .{ try result.int(i64, row, 9), try result.int(i64, row, 10) });
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn staffUserJson(self: anytype, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var target_buf: [24]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var user = try postgres.queryParams(allocator, lease.conn, "SELECT id,name,country,privileges,silence_end,restricted,created_at,coalesce(last_login,0),(SELECT count(DISTINCT h2.user_id) FROM zigcho.client_hardware h1 JOIN zigcho.client_hardware h2 ON h2.user_id!=h1.user_id AND h2.adapters_md5=h1.adapters_md5 AND h2.uninstall_md5=h1.uninstall_md5 AND h2.disk_signature_md5=h1.disk_signature_md5 WHERE h1.user_id=u.id) FROM zigcho.users u WHERE id=$1 AND id!=3", &.{id});
    defer user.deinit();
    if (user.rows() == 0) return null;
    var hardware = try postgres.queryParams(allocator, lease.conn, "SELECT right(adapters_md5,8),right(uninstall_md5,8),right(disk_signature_md5,8),client_version,running_under_wine,first_seen,last_seen,occurrences FROM zigcho.client_hardware WHERE user_id=$1 ORDER BY last_seen DESC LIMIT 50", &.{id});
    defer hardware.deinit();
    var audit = try postgres.queryParams(allocator, lease.conn, "SELECT a.id,coalesce(actor.name,'system'),a.action,coalesce(a.detail,''),a.created_at FROM zigcho.audit_log a LEFT JOIN zigcho.users actor ON actor.id=a.actor_id WHERE a.target=$1 ORDER BY a.id DESC LIMIT 100", &.{target});
    defer audit.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"user\":{{\"id\":{d},\"name\":", .{try user.int(i32, 0, 0)});
    try common.jsonString(&output.writer, user.value(0, 1));
    try output.writer.writeAll(",\"country\":");
    try common.jsonString(&output.writer, user.value(0, 2));
    try output.writer.print(",\"privileges\":{d},\"silence_end\":{d},\"restricted\":{},\"created_at\":{d},\"last_login\":{d},\"exact_hardware_matches\":{d}}},\"hardware\":[", .{ try user.int(u32, 0, 3), try user.int(i64, 0, 4), try user.boolean(0, 5), try user.int(i64, 0, 6), try user.int(i64, 0, 7), try user.int(i64, 0, 8) });
    for (0..hardware.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"adapter\":");
        try common.jsonString(&output.writer, hardware.value(row, 0));
        try output.writer.writeAll(",\"uninstall\":");
        try common.jsonString(&output.writer, hardware.value(row, 1));
        try output.writer.writeAll(",\"disk\":");
        try common.jsonString(&output.writer, hardware.value(row, 2));
        try output.writer.writeAll(",\"client\":");
        try common.jsonString(&output.writer, hardware.value(row, 3));
        try output.writer.print(",\"wine\":{},\"first_seen\":{d},\"last_seen\":{d},\"occurrences\":{d}}}", .{ try hardware.boolean(row, 4), try hardware.int(i64, row, 5), try hardware.int(i64, row, 6), try hardware.int(i32, row, 7) });
    }
    try output.writer.writeAll("],\"audit\":[");
    for (0..audit.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"actor\":", .{try audit.int(i64, row, 0)});
        try common.jsonString(&output.writer, audit.value(row, 1));
        try output.writer.writeAll(",\"action\":");
        try common.jsonString(&output.writer, audit.value(row, 2));
        try output.writer.writeAll(",\"detail\":");
        try common.jsonString(&output.writer, audit.value(row, 3));
        try output.writer.print(",\"created_at\":{d}}}", .{try audit.int(i64, row, 4)});
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return try list.toOwnedSlice(allocator);
}

pub fn staffAuditJson(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT a.id,coalesce(u.name,'system'),a.action,coalesce(a.target,''),coalesce(a.detail,''),a.created_at FROM zigcho.audit_log a LEFT JOIN zigcho.users u ON u.id=a.actor_id ORDER BY a.id DESC LIMIT 250");
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"events\":[");
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"id\":{d},\"actor\":", .{try result.int(i64, row, 0)});
        for (1..5) |column| {
            try common.jsonString(&output.writer, result.value(row, column));
            const names = [_][]const u8{ "action", "target", "detail" };
            if (column < 4) try output.writer.print(",\"{s}\":", .{names[column - 1]});
        }
        try output.writer.print(",\"created_at\":{d}}}", .{try result.int(i64, row, 5)});
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn staffChannelsJson(self: anytype, allocator: std.mem.Allocator) ![]u8 {
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT name,topic,write_privileges,locked,updated_at FROM zigcho.chat_channels ORDER BY name");
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"channels\":[");
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try output.writer.writeAll("{\"name\":");
        try common.jsonString(&output.writer, result.value(row, 0));
        try output.writer.writeAll(",\"topic\":");
        try common.jsonString(&output.writer, result.value(row, 1));
        try output.writer.print(",\"write_privileges\":{d},\"locked\":{},\"updated_at\":{d}}}", .{ try result.int(u32, row, 2), try result.boolean(row, 3), try result.int(i64, row, 4) });
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
