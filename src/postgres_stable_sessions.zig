const std = @import("std");
const postgres = @import("postgres.zig");
const stable_client = @import("stable_client.zig");

pub const GraceResult = enum {
    accepted,
    unknown,
    foreign,
    version_mismatch,
    hardware_mismatch,
    current_not_grace,
    expired,
    consumed,
    revoked,
};

fn validToken(token: []const u8) bool {
    if (token.len != 64) return false;
    for (token) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}

fn validChecksum(checksum: []const u8) bool {
    if (checksum.len != 32) return false;
    for (checksum) |char| if (!std.ascii.isDigit(char) and (char < 'a' or char > 'f')) return false;
    return true;
}

fn tokenBytea(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return postgres.encodeBytea(allocator, &digest);
}

pub fn rotate(allocator: std.mem.Allocator, pool: *postgres.Pool, user_id: i32, token: []const u8, binding: stable_client.Binding, now: i64, grace_seconds: i64) !void {
    if (user_id <= 0 or !validToken(token) or now <= 0 or grace_seconds <= 0 or grace_seconds > 900) return error.InvalidStableScoreSession;
    const token_hash = try tokenBytea(allocator, token);
    defer allocator.free(token_hash);
    const hardware = try postgres.encodeBytea(allocator, &binding.hardware_digest);
    defer allocator.free(hardware);
    var user_buf: [24]u8 = undefined;
    var now_buf: [24]u8 = undefined;
    var expiry_buf: [24]u8 = undefined;
    var retention_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
    const expiry = try std.fmt.bufPrint(&expiry_buf, "{d}", .{now + grace_seconds});
    const retention = try std.fmt.bufPrint(&retention_buf, "{d}", .{now - 86_400});

    var lease = pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var lock = try postgres.queryParams(allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{user});
    lock.deinit();
    // Only the immediately previous login can bridge a reconnect. A second
    // reconnect retires an older unused claim instead of growing a token chain.
    var revoke_old_grace = try postgres.queryParams(allocator, lease.conn, "UPDATE zigcho.stable_score_sessions SET revoked_at=$2 WHERE user_id=$1 AND grace_expires_at IS NOT NULL AND consumed_at IS NULL AND revoked_at IS NULL", &.{ user, now_text });
    revoke_old_grace.deinit();
    var grant_grace = try postgres.queryParams(allocator, lease.conn, "UPDATE zigcho.stable_score_sessions SET grace_expires_at=$2 WHERE user_id=$1 AND grace_expires_at IS NULL AND revoked_at IS NULL", &.{ user, expiry });
    grant_grace.deinit();
    var inserted = try postgres.queryParams(allocator, lease.conn, "INSERT INTO zigcho.stable_score_sessions(token_hash,user_id,version_date,hardware_digest,issued_at) VALUES($1,$2,$3,$4,$5)", &.{ token_hash, user, &binding.version_date, hardware, now_text });
    inserted.deinit();
    var pruned = try postgres.queryParams(allocator, lease.conn, "DELETE FROM zigcho.stable_score_sessions WHERE user_id=$1 AND issued_at<$2 AND (revoked_at IS NOT NULL OR consumed_at IS NOT NULL OR grace_expires_at<$2)", &.{ user, retention });
    pruned.deinit();
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn consume(allocator: std.mem.Allocator, pool: *postgres.Pool, token: []const u8, user_id: i32, binding: stable_client.Binding, submission_checksum: []const u8, now: i64) !GraceResult {
    if (user_id <= 0 or !validToken(token) or !validChecksum(submission_checksum) or now <= 0) return .unknown;
    const token_hash = try tokenBytea(allocator, token);
    defer allocator.free(token_hash);
    var lease = pool.acquire();
    defer lease.release();

    var owner = try postgres.queryParams(allocator, lease.conn, "SELECT user_id FROM zigcho.stable_score_sessions WHERE token_hash=$1", &.{token_hash});
    if (owner.rows() == 0) {
        owner.deinit();
        return .unknown;
    }
    const token_user_id = try owner.int(i32, 0, 0);
    owner.deinit();
    if (token_user_id != user_id) return .foreign;

    var user_buf: [24]u8 = undefined;
    var now_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var lock = try postgres.queryParams(allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{user});
    lock.deinit();
    var row = try postgres.queryParams(allocator, lease.conn, "SELECT version_date,hardware_digest,grace_expires_at,consumed_at,submission_checksum,revoked_at FROM zigcho.stable_score_sessions WHERE token_hash=$1 AND user_id=$2 FOR UPDATE", &.{ token_hash, user });
    if (row.rows() == 0) {
        row.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return .unknown;
    }
    const version = row.value(0, 0);
    if (version.len != binding.version_date.len or !std.crypto.timing_safe.eql([8]u8, version[0..8].*, binding.version_date)) {
        row.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return .version_mismatch;
    }
    const stored_hardware = try postgres.decodeBytea(allocator, row.value(0, 1));
    defer allocator.free(stored_hardware);
    if (stored_hardware.len != binding.hardware_digest.len or !std.crypto.timing_safe.eql([32]u8, stored_hardware[0..32].*, binding.hardware_digest)) {
        row.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return .hardware_mismatch;
    }
    if (!row.isNull(0, 5)) {
        row.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return .revoked;
    }
    if (row.isNull(0, 2)) {
        row.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return .current_not_grace;
    }
    const grace_expires_at = try row.int(i64, 0, 2);
    if (grace_expires_at <= now) {
        row.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return .expired;
    }
    if (!row.isNull(0, 3)) {
        // A lost HTTP response may make Stable retry the same logical score.
        // Keep that idempotent while refusing a second checksum on this token.
        const previous_checksum = row.value(0, 4);
        const same_submission = previous_checksum.len == submission_checksum.len and std.crypto.timing_safe.eql([32]u8, previous_checksum[0..32].*, submission_checksum[0..32].*);
        row.deinit();
        try postgres.exec(lease.conn, "ROLLBACK");
        return if (same_submission) .accepted else .consumed;
    }
    row.deinit();
    var consumed = try postgres.queryParams(allocator, lease.conn, "UPDATE zigcho.stable_score_sessions SET consumed_at=$2,submission_checksum=$4 WHERE token_hash=$1 AND user_id=$3 AND consumed_at IS NULL AND revoked_at IS NULL AND grace_expires_at>$2 RETURNING 1", &.{ token_hash, now_text, user, submission_checksum });
    const accepted = consumed.rows() == 1;
    consumed.deinit();
    if (!accepted) {
        try postgres.exec(lease.conn, "ROLLBACK");
        return .consumed;
    }
    try postgres.exec(lease.conn, "COMMIT");
    return .accepted;
}

pub fn revokeWithConnection(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, user_id: i32, now: i64) !usize {
    var user_buf: [24]u8 = undefined;
    var now_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
    var result = try postgres.queryParams(allocator, conn, "UPDATE zigcho.stable_score_sessions SET revoked_at=$2 WHERE user_id=$1 AND revoked_at IS NULL RETURNING 1", &.{ user, now_text });
    defer result.deinit();
    return result.rows();
}

pub fn revoke(allocator: std.mem.Allocator, pool: *postgres.Pool, user_id: i32, now: i64) !usize {
    if (user_id <= 0 or now <= 0) return 0;
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var lease = pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var lock = try postgres.queryParams(allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{user});
    lock.deinit();
    const revoked = try revokeWithConnection(allocator, lease.conn, user_id, now);
    try postgres.exec(lease.conn, "COMMIT");
    return revoked;
}
