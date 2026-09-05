const std = @import("std");
const postgres = @import("../../../postgres.zig");
const contracts = @import("../../contracts.zig");

const sql =
    "WITH requested AS MATERIALIZED (SELECT * FROM unnest($1::integer[],$2::smallint[]) WITH ORDINALITY AS q(user_id,mode,ord))," ++
    "population AS MATERIALIZED (SELECT s.user_id,s.mode,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode IN(SELECT DISTINCT mode FROM requested) AND s.plays>0 AND u.id!=3 AND NOT u.restricted)," ++
    "ranked AS (SELECT user_id,mode,row_number() OVER(PARTITION BY mode ORDER BY pp DESC,user_id ASC) global_rank FROM population) " ++
    "SELECT s.user_id,s.ranked_score,s.total_score,s.pp,s.plays,s.accuracy,CASE WHEN s.plays>0 THEN coalesce(r.global_rank,(SELECT count(*)+1 FROM population p WHERE p.mode=s.mode AND (p.pp>s.pp OR (p.pp=s.pp AND p.user_id<s.user_id)))) ELSE 0 END " ++
    "FROM requested q LEFT JOIN zigcho.stats s ON s.user_id=q.user_id AND s.mode=q.mode LEFT JOIN ranked r ON r.user_id=s.user_id AND r.mode=s.mode ORDER BY q.ord";

/// Preserve request order, duplicates and missing-stat defaults. Chunking bounds
/// each query's parameters without imposing a new online-player limit.
pub fn read(self: anytype, allocator: std.mem.Allocator, requests: []const contracts.BanchoStatsRequest) ![]contracts.BanchoStats {
    const result = try allocator.alloc(contracts.BanchoStats, requests.len);
    errdefer allocator.free(result);
    @memset(result, .{});
    var offset: usize = 0;
    while (offset < requests.len) {
        const chunk = requests[offset..@min(offset + 1024, requests.len)];
        var ids = std.Io.Writer.Allocating.init(allocator);
        defer ids.deinit();
        var modes = std.Io.Writer.Allocating.init(allocator);
        defer modes.deinit();
        try ids.writer.writeByte('{');
        try modes.writer.writeByte('{');
        for (chunk, 0..) |request, index| {
            if (index != 0) {
                try ids.writer.writeByte(',');
                try modes.writer.writeByte(',');
            }
            try ids.writer.print("{d}", .{request.user_id});
            try modes.writer.print("{d}", .{request.mode});
        }
        try ids.writer.writeByte('}');
        try modes.writer.writeByte('}');
        var lease = self.pool.acquire();
        defer lease.release();
        var rows = try postgres.queryParams(allocator, lease.conn, sql, &.{ ids.written(), modes.written() });
        defer rows.deinit();
        if (rows.rows() != chunk.len) return error.InvalidBanchoStatsBatch;
        for (chunk, 0..) |_, index| {
            if (rows.isNull(index, 0)) continue;
            result[offset + index] = .{
                .ranked_score = try rows.int(i64, index, 1),
                .total_score = try rows.int(i64, index, 2),
                .pp = try rows.int(i32, index, 3),
                .plays = try rows.int(i32, index, 4),
                .accuracy = try rows.float(f64, index, 5),
                .global_rank = try rows.int(i32, index, 6),
            };
        }
        offset += chunk.len;
    }
    return result;
}
