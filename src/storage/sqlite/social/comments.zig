const std = @import("std");
const domain = @import("../../../domain.zig");
const lazer = @import("../../../lazer.zig");
const user_json = @import("../../../user_json.zig");
const visible_follower_count_sql = @import("../../../storage.zig").visible_follower_count_sql;
const LazerCommentable = @import("../../contracts.zig").LazerCommentable;
const LazerCommentTarget = @import("../../contracts.zig").LazerCommentTarget;
const LazerCommentSort = @import("../../contracts.zig").LazerCommentSort;
const c = @import("../../../storage.zig").c;
const Store = @import("../../../storage.zig").Store;
const jsonString = @import("../beatmaps/lazer_listing.zig").jsonString;

pub fn addBeatmapComment(self: *Store, user_id: i32, target_type: []const u8, target_id: i64, time: f64, comment: []const u8, colour: ?[]const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO beatmap_comments(target_id,target_type,user_id,time,comment,colour) VALUES(?1,?2,?3,?4,?5,?6)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, target_id);
    _ = c.sqlite3_bind_text(stmt, 2, target_type.ptr, @intCast(target_type.len), null);
    _ = c.sqlite3_bind_int(stmt, 3, user_id);
    _ = c.sqlite3_bind_double(stmt, 4, time);
    _ = c.sqlite3_bind_text(stmt, 5, comment.ptr, @intCast(comment.len), null);
    if (colour) |value| _ = c.sqlite3_bind_text(stmt, 6, value.ptr, @intCast(value.len), null) else _ = c.sqlite3_bind_null(stmt, 6);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
}

pub fn beatmapComments(self: *Store, allocator: std.mem.Allocator, score_id: i64, set_id: i32, map_id: i32) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT c.time,c.target_type,u.privileges,c.colour,c.comment FROM beatmap_comments c JOIN users u ON u.id=c.user_id WHERE (c.target_type='replay' AND c.target_id=?1) OR (c.target_type='song' AND c.target_id=?2) OR (c.target_type='map' AND c.target_id=?3) ORDER BY c.id LIMIT 1000";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, score_id);
    _ = c.sqlite3_bind_int(stmt, 2, set_id);
    _ = c.sqlite3_bind_int(stmt, 3, map_id);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte('\n');
        first = false;
        const privileges: u32 = @intCast(c.sqlite3_column_int64(stmt, 2));
        const format = if (privileges & (1 << 11) != 0) "bat" else if (privileges & (1 << 4) != 0) "supporter" else "";
        const colour = if (c.sqlite3_column_type(stmt, 3) == c.SQLITE_NULL) "" else std.mem.span(c.sqlite3_column_text(stmt, 3));
        try output.writer.print("{d}\t{s}\t{s}", .{ c.sqlite3_column_double(stmt, 0), std.mem.span(c.sqlite3_column_text(stmt, 1)), format });
        if (colour.len != 0) try output.writer.print("|{s}", .{colour});
        try output.writer.print("\t{s}", .{std.mem.span(c.sqlite3_column_text(stmt, 4))});
    }
    return output.toOwnedSlice();
}

pub fn addLazerComment(self: *Store, user_id: i32, target: LazerCommentTarget, parent_id: ?i64, message: []const u8) !i64 {
    if (message.len == 0 or message.len > 1000 or !std.unicode.utf8ValidateSlice(message)) return error.InvalidComment;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (parent_id) |parent| {
        var check: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM lazer_comments WHERE id=?1 AND commentable_type=?2 AND commentable_id=?3 AND deleted_at IS NULL", -1, &check, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(check);
        _ = c.sqlite3_bind_int64(check, 1, parent);
        _ = c.sqlite3_bind_text(check, 2, target.commentable.text().ptr, @intCast(target.commentable.text().len), null);
        _ = c.sqlite3_bind_int64(check, 3, target.id);
        if (c.sqlite3_step(check) != c.SQLITE_ROW) return error.CommentParentNotFound;
    }
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT INTO lazer_comments(commentable_type,commentable_id,user_id,parent_id,message) VALUES(?1,?2,?3,?4,?5)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, target.commentable.text().ptr, @intCast(target.commentable.text().len), null);
    _ = c.sqlite3_bind_int64(stmt, 2, target.id);
    _ = c.sqlite3_bind_int(stmt, 3, user_id);
    if (parent_id) |parent| _ = c.sqlite3_bind_int64(stmt, 4, parent) else _ = c.sqlite3_bind_null(stmt, 4);
    _ = c.sqlite3_bind_text(stmt, 5, message.ptr, @intCast(message.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_last_insert_rowid(self.db);
}

pub fn lazerCommentTarget(self: *Store, comment_id: i64) !?LazerCommentTarget {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT commentable_type,commentable_id FROM lazer_comments WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, comment_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return .{ .commentable = LazerCommentable.parse(std.mem.span(c.sqlite3_column_text(stmt, 0))) orelse return error.InvalidStoredComment, .id = c.sqlite3_column_int64(stmt, 1) };
}

pub fn deleteLazerComment(self: *Store, user_id: i32, comment_id: i64, staff: bool) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = if (staff)
        "UPDATE lazer_comments SET message='',deleted_at=unixepoch(),updated_at=unixepoch() WHERE id=?1 AND deleted_at IS NULL"
    else
        "UPDATE lazer_comments SET message='',deleted_at=unixepoch(),updated_at=unixepoch() WHERE id=?1 AND user_id=?2 AND deleted_at IS NULL";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, comment_id);
    if (!staff) _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn setLazerCommentVote(self: *Store, user_id: i32, comment_id: i64, voted: bool) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = if (voted)
        "INSERT OR IGNORE INTO lazer_comment_votes(comment_id,user_id) SELECT ?1,?2 WHERE EXISTS(SELECT 1 FROM lazer_comments WHERE id=?1 AND deleted_at IS NULL)"
    else
        "DELETE FROM lazer_comment_votes WHERE comment_id=?1 AND user_id=?2";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, comment_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn reportLazerComment(self: *Store, user_id: i32, comment_id: i64, reason: []const u8, comments: []const u8) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO lazer_comment_reports(comment_id,reporter_id,reason,comments) SELECT ?1,?2,?3,?4 WHERE EXISTS(SELECT 1 FROM lazer_comments WHERE id=?1)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, comment_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_text(stmt, 3, reason.ptr, @intCast(reason.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, comments.ptr, @intCast(comments.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn addLazerReport(self: *Store, reporter_id: i32, reportable_type: []const u8, reportable_id: i64, reason: []const u8, comments: []const u8) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO lazer_reports(reporter_id,reportable_type,reportable_id,reason,comments) VALUES(?1,?2,?3,?4,?5)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, reporter_id);
    _ = c.sqlite3_bind_text(stmt, 2, reportable_type.ptr, @intCast(reportable_type.len), null);
    _ = c.sqlite3_bind_int64(stmt, 3, reportable_id);
    _ = c.sqlite3_bind_text(stmt, 4, reason.ptr, @intCast(reason.len), null);
    _ = c.sqlite3_bind_text(stmt, 5, comments.ptr, @intCast(comments.len), null);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn lazerMessageExists(self: *Store, message_id: i64) !bool {
    if (message_id <= 0) return false;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT EXISTS(SELECT 1 FROM chat_messages WHERE id=?1) OR EXISTS(SELECT 1 FROM direct_messages WHERE id=?1)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, message_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return c.sqlite3_column_int(stmt, 0) != 0;
}

pub fn staffLazerReportsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var stmt: ?*c.sqlite3_stmt = null;
    const sql =
        "SELECT r.id,r.reporter_id,reporter.name,reporter.country,r.reportable_type,r.reportable_id," ++
        "CASE r.reportable_type WHEN 'user' THEN coalesce((SELECT name FROM users WHERE id=r.reportable_id),'missing user') " ++
        "WHEN 'message' THEN substr(coalesce((SELECT message FROM chat_messages WHERE id=r.reportable_id),(SELECT message FROM direct_messages WHERE id=r.reportable_id),'missing message'),1,180) " ++
        "ELSE substr(coalesce((SELECT message FROM lazer_comments WHERE id=r.reportable_id),'missing comment'),1,180) END," ++
        "r.reason,r.comments,r.status,r.created_at,coalesce(r.resolved_at,0),coalesce(resolver.name,'') " ++
        "FROM lazer_reports r JOIN users reporter ON reporter.id=r.reporter_id LEFT JOIN users resolver ON resolver.id=r.resolver_id " ++
        "ORDER BY CASE r.status WHEN 'open' THEN 0 ELSE 1 END,r.created_at DESC,r.id DESC LIMIT 300";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"reports\":[");
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{d},\"reporter_id\":{d},\"reporter\":", .{ c.sqlite3_column_int64(stmt, 0), c.sqlite3_column_int(stmt, 1) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        try output.writer.writeAll(",\"reportable_type\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 4)));
        try output.writer.print(",\"reportable_id\":{d},\"target\":", .{c.sqlite3_column_int64(stmt, 5)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 6)));
        try output.writer.writeAll(",\"reason\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 7)));
        try output.writer.writeAll(",\"comments\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 8)));
        try output.writer.writeAll(",\"status\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 9)));
        try output.writer.print(",\"created_at\":{d},\"resolved_at\":{d},\"resolver\":", .{ c.sqlite3_column_int64(stmt, 10), c.sqlite3_column_int64(stmt, 11) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 12)));
        try output.writer.writeByte('}');
    }
    try output.writer.writeAll("]}");
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn resolveLazerReport(self: *Store, actor_id: i32, report_id: i64, decision: []const u8) !bool {
    if (!std.mem.eql(u8, decision, "resolved") and !std.mem.eql(u8, decision, "dismissed")) return error.InvalidReportDecision;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    const reporter_id = block: {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE lazer_reports SET status=?1,resolved_at=unixepoch(),resolver_id=?2 WHERE id=?3 AND status='open' RETURNING reporter_id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, decision.ptr, @intCast(decision.len), null);
        _ = c.sqlite3_bind_int(stmt, 2, actor_id);
        _ = c.sqlite3_bind_int64(stmt, 3, report_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            try self.exec("ROLLBACK");
            return false;
        }
        break :block c.sqlite3_column_int(stmt, 0);
    };
    var detail_buf: [128]u8 = undefined;
    const detail = try std.fmt.bufPrint(&detail_buf, "report_id={d} decision={s}", .{ report_id, decision });
    try self.insertAuditLocked(actor_id, "lazer.report_review", reporter_id, detail);
    try self.exec("COMMIT");
    return true;
}

pub fn setLazerBeatmapTag(self: *Store, user_id: i32, beatmap_id: i32, tag_id: i64, selected: bool) !bool {
    if (!lazer.validBeatmapTagId(tag_id) or beatmap_id <= 0 or user_id <= 0) return error.InvalidBeatmapTag;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var exists: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE id=?1", -1, &exists, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(exists);
    _ = c.sqlite3_bind_int(exists, 1, beatmap_id);
    if (c.sqlite3_step(exists) != c.SQLITE_ROW) return error.BeatmapNotFound;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = if (selected)
        "INSERT OR IGNORE INTO beatmap_tag_votes(beatmap_id,user_id,tag_id) VALUES(?1,?2,?3)"
    else
        "DELETE FROM beatmap_tag_votes WHERE beatmap_id=?1 AND user_id=?2 AND tag_id=?3";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int(stmt, 1, beatmap_id);
    _ = c.sqlite3_bind_int(stmt, 2, user_id);
    _ = c.sqlite3_bind_int64(stmt, 3, tag_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    return c.sqlite3_changes(self.db) != 0;
}

pub fn lazerBeatmapTagStateJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, beatmap_id: i32) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var exists: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE id=?1", -1, &exists, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(exists);
    _ = c.sqlite3_bind_int(exists, 1, beatmap_id);
    if (c.sqlite3_step(exists) != c.SQLITE_ROW) return null;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"top_tag_ids\":[");
    var top: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT tag_id,count(*) FROM beatmap_tag_votes WHERE beatmap_id=?1 GROUP BY tag_id ORDER BY count(*) DESC,tag_id LIMIT 20", -1, &top, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(top);
    _ = c.sqlite3_bind_int(top, 1, beatmap_id);
    var first = true;
    while (c.sqlite3_step(top) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"tag_id\":{d},\"count\":{d}}}", .{ c.sqlite3_column_int64(top, 0), c.sqlite3_column_int(top, 1) });
    }
    try output.writer.writeAll("],\"current_user_tag_ids\":[");
    var own: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT tag_id FROM beatmap_tag_votes WHERE beatmap_id=?1 AND user_id=?2 ORDER BY tag_id", -1, &own, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(own);
    _ = c.sqlite3_bind_int(own, 1, beatmap_id);
    _ = c.sqlite3_bind_int(own, 2, user_id);
    first = true;
    while (c.sqlite3_step(own) == c.SQLITE_ROW) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{d}", .{c.sqlite3_column_int64(own, 0)});
    }
    try output.writer.writeAll("]}");
    return @as(?[]u8, try output.toOwnedSlice());
}

pub fn lazerCommentsJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, target: LazerCommentTarget, sort: LazerCommentSort, page: u16, parent_id: i64, only_id: i64) ![]u8 {
    if (page == 0 or page > 1000 or parent_id < 0 or only_id < 0) return error.InvalidCommentQuery;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const base_sql = "SELECT c.id,c.parent_id,c.user_id,c.message,strftime('%Y-%m-%dT%H:%M:%SZ',c.created_at,'unixepoch'),strftime('%Y-%m-%dT%H:%M:%SZ',c.updated_at,'unixepoch'),CASE WHEN c.deleted_at IS NULL THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%SZ',c.deleted_at,'unixepoch') END,(SELECT count(*) FROM lazer_comments r WHERE r.parent_id=c.id),(SELECT count(*) FROM lazer_comment_votes v WHERE v.comment_id=c.id),EXISTS(SELECT 1 FROM lazer_comment_votes v WHERE v.comment_id=c.id AND v.user_id=?5) FROM lazer_comments c JOIN users u ON u.id=c.user_id WHERE c.commentable_type=?1 AND c.commentable_id=?2 AND u.restricted=0 AND ((?4>0 AND c.id=?4) OR (?4=0 AND ((?3>0 AND c.parent_id=?3) OR (?3=0 AND c.parent_id IS NULL))))";
    const sql = switch (sort) {
        .new => base_sql ++ " ORDER BY c.created_at DESC,c.id DESC LIMIT 51 OFFSET ?6",
        .old => base_sql ++ " ORDER BY c.created_at ASC,c.id ASC LIMIT 51 OFFSET ?6",
        .top => base_sql ++ " ORDER BY (SELECT count(*) FROM lazer_comment_votes v WHERE v.comment_id=c.id) DESC,c.created_at DESC,c.id DESC LIMIT 51 OFFSET ?6",
    };
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, target.commentable.text().ptr, @intCast(target.commentable.text().len), null);
    _ = c.sqlite3_bind_int64(stmt, 2, target.id);
    _ = c.sqlite3_bind_int64(stmt, 3, parent_id);
    _ = c.sqlite3_bind_int64(stmt, 4, only_id);
    _ = c.sqlite3_bind_int(stmt, 5, viewer_id);
    _ = c.sqlite3_bind_int64(stmt, 6, (@as(i64, page) - 1) * 50);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var user_ids: std.ArrayList(i32) = .empty;
    defer user_ids.deinit(allocator);
    var voted_ids: std.ArrayList(i64) = .empty;
    defer voted_ids.deinit(allocator);
    try output.writer.writeAll("{\"commentable_meta\":[{\"id\":");
    try output.writer.print("{d},\"owner_id\":null,\"owner_title\":null,\"title\":", .{target.id});
    var title_buf: [96]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "{s} #{d}", .{ target.commentable.text(), target.id });
    try jsonString(&output.writer, title);
    try output.writer.writeAll(",\"type\":");
    try jsonString(&output.writer, target.commentable.text());
    try output.writer.writeAll(",\"url\":");
    var url_buf: [128]u8 = undefined;
    const url = if (target.commentable == .beatmapset) try std.fmt.bufPrint(&url_buf, "https://kai.ovh/beatmapsets/{d}", .{target.id}) else try std.fmt.bufPrint(&url_buf, "https://kai.ovh/", .{});
    try jsonString(&output.writer, url);
    try output.writer.writeAll(",\"current_user_attributes\":{\"can_new_comment_reason\":null}}],\"comments\":[");
    var written: usize = 0;
    var has_more = false;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (written == 50) {
            has_more = true;
            break;
        }
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        const comment_id = c.sqlite3_column_int64(stmt, 0);
        const user_id = c.sqlite3_column_int(stmt, 2);
        if (std.mem.indexOfScalar(i32, user_ids.items, user_id) == null) try user_ids.append(allocator, user_id);
        const voted = c.sqlite3_column_int(stmt, 9) != 0;
        if (voted) try voted_ids.append(allocator, comment_id);
        try output.writer.print("{{\"id\":{d},\"parent_id\":", .{comment_id});
        if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) try output.writer.writeAll("null") else try output.writer.print("{d}", .{c.sqlite3_column_int64(stmt, 1)});
        try output.writer.print(",\"user_id\":{d},\"message\":", .{user_id});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        try output.writer.writeAll(",\"message_html\":null,\"replies_count\":");
        try output.writer.print("{d},\"votes_count\":{d},\"commentable_type\":", .{ c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int(stmt, 8) });
        try jsonString(&output.writer, target.commentable.text());
        try output.writer.print(",\"commentable_id\":{d},\"legacy_name\":null,\"created_at\":", .{target.id});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 4)));
        try output.writer.writeAll(",\"updated_at\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 5)));
        try output.writer.writeAll(",\"deleted_at\":");
        if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL) try output.writer.writeAll("null") else try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 6)));
        try output.writer.writeAll(",\"edited_at\":null,\"edited_by_id\":null,\"pinned\":false}");
    }
    var count_stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),sum(CASE WHEN parent_id IS NULL THEN 1 ELSE 0 END) FROM lazer_comments WHERE commentable_type=?1 AND commentable_id=?2", -1, &count_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(count_stmt);
    _ = c.sqlite3_bind_text(count_stmt, 1, target.commentable.text().ptr, @intCast(target.commentable.text().len), null);
    _ = c.sqlite3_bind_int64(count_stmt, 2, target.id);
    if (c.sqlite3_step(count_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    const total = c.sqlite3_column_int(count_stmt, 0);
    const top_level = c.sqlite3_column_int(count_stmt, 1);
    try output.writer.print("],\"has_more\":{},\"has_more_id\":null,\"user_follow\":false,\"included_comments\":[],\"pinned_comments\":[],\"user_votes\":[", .{has_more});
    for (voted_ids.items, 0..) |id, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{d}", .{id});
    }
    try output.writer.writeAll("],\"users\":[");
    for (user_ids.items, 0..) |id, index| {
        var user_stmt: ?*c.sqlite3_stmt = null;
        const user_sql = "SELECT u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,u.restricted," ++ visible_follower_count_sql ++ " FROM users u WHERE u.id=?1";
        if (c.sqlite3_prepare_v2(self.db, user_sql, -1, &user_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(user_stmt);
        _ = c.sqlite3_bind_int(user_stmt, 1, id);
        if (c.sqlite3_step(user_stmt) != c.SQLITE_ROW) continue;
        if (index != 0) try output.writer.writeByte(',');
        const country = std.mem.span(c.sqlite3_column_text(user_stmt, 2));
        const user: domain.User = .{ .id = id, .name = std.mem.span(c.sqlite3_column_text(user_stmt, 1)), .safe_name = "", .country = .{ country[0], country[1] }, .privileges = @intCast(c.sqlite3_column_int64(user_stmt, 3)), .restricted = c.sqlite3_column_int(user_stmt, 4) != 0, .follower_count = c.sqlite3_column_int(user_stmt, 5) };
        try user_json.writeCompact(&output.writer, user, true);
    }
    try output.writer.print("],\"total\":{d},\"top_level_count\":{d}}}", .{ total, top_level });
    return output.toOwnedSlice();
}
