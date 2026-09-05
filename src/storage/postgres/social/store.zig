const std = @import("std");
const domain = @import("../../../domain.zig");
const postgres = @import("../../../postgres.zig");
const storage_contracts = @import("../../contracts.zig");
const lazer = @import("../../../lazer.zig");
const common = @import("../common.zig");

const ReplaySource = storage_contracts.ReplaySource;
const DirectMessage = storage_contracts.DirectMessage;
const LazerChatWrite = storage_contracts.LazerChatWrite;
const ChatCursor = storage_contracts.ChatCursor;

pub fn friendIds(self: anytype, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = "SELECT relation.friend_id FROM zigcho.friends relation JOIN zigcho.users sender ON sender.id=relation.user_id JOIN zigcho.users target ON target.id=relation.friend_id WHERE relation.user_id=$1 AND NOT sender.restricted AND NOT target.restricted ORDER BY relation.friend_id LIMIT 1000";
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{id});
    defer result.deinit();
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(allocator);
    for (0..result.rows()) |row| try list.append(allocator, try result.int(i32, row, 0));
    if (user_id != 3 and std.mem.indexOfScalar(i32, list.items, 3) == null) try list.append(allocator, 3);
    return list.toOwnedSlice(allocator);
}

pub fn addFriend(self: anytype, user_id: i32, friend_id: i32) !domain.RelationshipAddResult {
    var user_buf: [24]u8 = undefined;
    var friend_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const friend = try std.fmt.bufPrint(&friend_buf, "{d}", .{friend_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql =
        "WITH eligible AS (SELECT sender.id user_id,target.id friend_id FROM zigcho.users sender JOIN zigcho.users target ON target.id=$2 " ++
        "WHERE sender.id=$1 AND sender.id!=target.id AND target.id!=3 AND NOT sender.restricted AND NOT target.restricted)," ++
        "inserted AS (INSERT INTO zigcho.friends(user_id,friend_id) SELECT user_id,friend_id FROM eligible ON CONFLICT DO NOTHING RETURNING 1) " ++
        "SELECT CASE WHEN EXISTS(SELECT 1 FROM inserted) THEN 1 WHEN EXISTS(SELECT 1 FROM eligible) THEN 2 ELSE 0 END";
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ user, friend });
    defer result.deinit();
    return switch (try result.int(u8, 0, 0)) {
        1 => .inserted,
        2 => .existing,
        else => .ineligible,
    };
}

pub fn removeFriend(self: anytype, user_id: i32, friend_id: i32) !bool {
    if (friend_id == 3) return false;
    var user_buf: [24]u8 = undefined;
    var friend_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const friend = try std.fmt.bufPrint(&friend_buf, "{d}", .{friend_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.friends WHERE user_id=$1 AND friend_id=$2 RETURNING 1", &.{ user, friend });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn friendsAreMutual(self: anytype, user_id: i32, friend_id: i32) !bool {
    var user_buf: [24]u8 = undefined;
    var friend_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const friend = try std.fmt.bufPrint(&friend_buf, "{d}", .{friend_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = "SELECT EXISTS(SELECT 1 FROM zigcho.friends relation JOIN zigcho.users sender ON sender.id=relation.user_id JOIN zigcho.users target ON target.id=relation.friend_id WHERE relation.user_id=$1 AND relation.friend_id=$2 AND sender.id!=target.id AND target.id!=3 AND NOT sender.restricted AND NOT target.restricted)::int";
    var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ friend, user });
    defer result.deinit();
    return try result.int(i32, 0, 0) != 0;
}

pub fn replayViewCountWithConnection(self: anytype, conn: *postgres.c.PGconn, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !i32 {
    if (!domain.validSiteMode(source, stats_mode)) return error.InvalidScoreSource;
    var buffers: [2][24]u8 = undefined;
    const user = try std.fmt.bufPrint(&buffers[0], "{d}", .{user_id});
    const mode = try std.fmt.bufPrint(&buffers[1], "{d}", .{stats_mode});
    var result = try postgres.queryParams(self.allocator, conn, "SELECT count(*) FROM zigcho.score_replay_views WHERE owner_id=$1 AND mode=$2 AND rank_namespace=$3 AND ($4='all' OR ($4='scorev2' AND source='stable') OR source=$4)", &.{ user, mode, domain.siteNamespace(source, stats_mode), @tagName(source) });
    defer result.deinit();
    return try result.int(i32, 0, 0);
}

pub fn replayViewCount(self: anytype, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !i32 {
    var lease = self.pool.acquire();
    defer lease.release();
    return replayViewCountWithConnection(self, lease.conn, user_id, source, stats_mode);
}

pub fn recordReplayView(self: anytype, viewer_id: i32, source: ReplaySource, score_id: i64) !bool {
    if (viewer_id <= 0 or score_id <= 0) return false;
    var buffers: [2][32]u8 = undefined;
    const viewer = try std.fmt.bufPrint(&buffers[0], "{d}", .{viewer_id});
    const score = try std.fmt.bufPrint(&buffers[1], "{d}", .{score_id});
    const stable_sql =
        "INSERT INTO zigcho.score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) " ++
        "SELECT 'stable',s.id,$1,s.user_id,CASE WHEN (s.mods&8192)!=0 THEN s.mode+8 WHEN (s.mods&128)!=0 THEN s.mode+4 ELSE s.mode END,s.rank_namespace FROM zigcho.scores s " ++
        "WHERE s.id=$2 AND s.user_id!=$1 AND s.passed AND s.rank_namespace IN('vanilla','relax','autopilot','scorev2') " ++
        "ON CONFLICT(source,score_id,viewer_id) DO UPDATE SET viewed_at=extract(epoch FROM clock_timestamp())::bigint RETURNING 1";
    const lazer_sql =
        "INSERT INTO zigcho.score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) " ++
        "SELECT 'lazer',s.id,$1,s.user_id,CASE s.rank_namespace WHEN 'vanilla' THEN s.ruleset_id WHEN 'relax' THEN s.ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE -1 END,s.rank_namespace FROM zigcho.lazer_scores s " ++
        "WHERE s.id=$2 AND s.user_id!=$1 AND s.passed AND s.rank_namespace IN('vanilla','relax','autopilot') " ++
        "ON CONFLICT(source,score_id,viewer_id) DO UPDATE SET viewed_at=extract(epoch FROM clock_timestamp())::bigint RETURNING 1";
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, if (source == .stable) stable_sql else lazer_sql, &.{ viewer, score });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn blockIds(self: anytype, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT blocked_id FROM zigcho.user_blocks WHERE user_id=$1 ORDER BY blocked_id LIMIT 1000", &.{id});
    defer result.deinit();
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(allocator);
    for (0..result.rows()) |row| try list.append(allocator, try result.int(i32, row, 0));
    return list.toOwnedSlice(allocator);
}

pub fn addBlock(self: anytype, user_id: i32, blocked_id: i32) !bool {
    if (user_id == blocked_id or blocked_id == 3) return false;
    var user_buf: [24]u8 = undefined;
    var blocked_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const blocked = try std.fmt.bufPrint(&blocked_buf, "{d}", .{blocked_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.user_blocks(user_id,blocked_id) VALUES($1,$2) ON CONFLICT DO NOTHING RETURNING 1", &.{ user, blocked });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn removeBlock(self: anytype, user_id: i32, blocked_id: i32) !bool {
    if (blocked_id == 3) return false;
    var user_buf: [24]u8 = undefined;
    var blocked_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const blocked = try std.fmt.bufPrint(&blocked_buf, "{d}", .{blocked_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.user_blocks WHERE user_id=$1 AND blocked_id=$2 RETURNING 1", &.{ user, blocked });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn directMessageAllowedWithConnection(self: anytype, conn: *postgres.c.PGconn, from_id: i32, to_id: i32) !bool {
    if (from_id <= 0 or to_id <= 0 or from_id == to_id) return false;
    var from_buf: [24]u8 = undefined;
    var to_buf: [24]u8 = undefined;
    const from = try std.fmt.bufPrint(&from_buf, "{d}", .{from_id});
    const to = try std.fmt.bufPrint(&to_buf, "{d}", .{to_id});
    const sql = "SELECT EXISTS(SELECT 1 FROM zigcho.users sender JOIN zigcho.users recipient ON recipient.id=$2 WHERE sender.id=$1 AND NOT sender.restricted AND NOT recipient.restricted AND NOT EXISTS(SELECT 1 FROM zigcho.user_blocks b WHERE (b.user_id=$1 AND b.blocked_id=$2) OR (b.user_id=$2 AND b.blocked_id=$1)))::int";
    var result = try postgres.queryParams(self.allocator, conn, sql, &.{ from, to });
    defer result.deinit();
    return try result.int(i32, 0, 0) != 0;
}

pub fn directMessageAllowed(self: anytype, from_id: i32, to_id: i32) !bool {
    var lease = self.pool.acquire();
    defer lease.release();
    return directMessageAllowedWithConnection(self, lease.conn, from_id, to_id);
}

pub fn storeDirectMessage(self: anytype, from_id: i32, to_id: i32, message: []const u8) !i64 {
    var from_buf: [24]u8 = undefined;
    var to_buf: [24]u8 = undefined;
    var target_buf: [64]u8 = undefined;
    const from = try std.fmt.bufPrint(&from_buf, "{d}", .{from_id});
    const to = try std.fmt.bufPrint(&to_buf, "{d}", .{to_id});
    const target = try lazer.directMessageTarget(&target_buf, from_id, to_id);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    if (!try directMessageAllowedWithConnection(self, lease.conn, from_id, to_id)) return error.DirectMessageBlocked;
    var mirror = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message) VALUES($1,$2,$3) RETURNING id", &.{ from, target, message });
    defer mirror.deinit();
    const chat_message_id = try mirror.int(i64, 0, 0);
    var chat_buf: [24]u8 = undefined;
    const chat = try std.fmt.bufPrint(&chat_buf, "{d}", .{chat_message_id});
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.direct_messages(from_id,to_id,message,chat_message_id) VALUES($1,$2,$3,$4) RETURNING id", &.{ from, to, message, chat });
    defer result.deinit();
    const direct_message_id = try result.int(i64, 0, 0);
    try postgres.exec(lease.conn, "COMMIT");
    return direct_message_id;
}

pub fn unreadDirectMessages(self: anytype, allocator: std.mem.Allocator, to_id: i32) ![]DirectMessage {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{to_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(allocator, lease.conn, "SELECT d.id,d.from_id,u.name,d.message FROM zigcho.direct_messages d JOIN zigcho.users u ON u.id=d.from_id WHERE d.to_id=$1 AND NOT d.read ORDER BY d.created_at,d.id LIMIT 1000", &.{id});
    defer result.deinit();
    var messages: std.ArrayList(DirectMessage) = .empty;
    errdefer {
        for (messages.items) |*message| message.deinit(allocator);
        messages.deinit(allocator);
    }
    for (0..result.rows()) |row| {
        const from_name = try allocator.dupe(u8, result.value(row, 2));
        errdefer allocator.free(from_name);
        const message = try allocator.dupe(u8, result.value(row, 3));
        errdefer allocator.free(message);
        try messages.append(allocator, .{ .id = try result.int(i64, row, 0), .from_id = try result.int(i32, row, 1), .from_name = from_name, .message = message });
    }
    return messages.toOwnedSlice(allocator);
}

pub fn markDirectMessagesRead(self: anytype, to_id: i32, from_id: i32) !void {
    var to_buf: [24]u8 = undefined;
    var from_buf: [24]u8 = undefined;
    const to = try std.fmt.bufPrint(&to_buf, "{d}", .{to_id});
    const from = try std.fmt.bufPrint(&from_buf, "{d}", .{from_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.direct_messages SET read=true WHERE to_id=$1 AND from_id=$2 AND NOT read", &.{ to, from });
    result.deinit();
}

pub fn markDirectMessageRead(self: anytype, to_id: i32, message_id: i64) !bool {
    var to_buf: [24]u8 = undefined;
    var message_buf: [32]u8 = undefined;
    const to = try std.fmt.bufPrint(&to_buf, "{d}", .{to_id});
    const id = try std.fmt.bufPrint(&message_buf, "{d}", .{message_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.direct_messages SET read=true WHERE id=$1 AND to_id=$2 AND NOT read RETURNING 1", &.{ id, to });
    defer result.deinit();
    return result.rows() != 0;
}

pub fn recordPublicMessage(self: anytype, sender_id: i32, target: []const u8, message: []const u8) !void {
    var id_buf: [24]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{sender_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message) VALUES($1,$2,$3)", &.{ id, target, message });
    result.deinit();
}

pub fn recordStaffAnnouncement(self: anytype, actor_id: i32, message: []const u8, reason: []const u8) !void {
    var actor_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var chat = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message) VALUES(3,'#announce',$1)", &.{message});
    chat.deinit();
    var audit = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,'infra.announcement','server',$2)", &.{ actor, reason });
    audit.deinit();
    try postgres.exec(lease.conn, "COMMIT");
}

pub fn recordLazerPublicMessage(self: anytype, allocator: std.mem.Allocator, sender_id: i32, target: []const u8, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
    const channel_id = lazer.channelId(target) orelse return error.UnknownChannel;
    var id_buf: [24]u8 = undefined;
    const sender = try std.fmt.bufPrint(&id_buf, "{d}", .{sender_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var access = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.privileges,c.write_privileges,c.locked FROM zigcho.users u JOIN zigcho.chat_channels c ON c.name=$2 WHERE u.id=$1", &.{ sender, target });
    defer access.deinit();
    if (access.rows() == 0) return error.UnknownChannel;
    const privileges = try access.int(u32, 0, 0);
    const required = try access.int(u32, 0, 1);
    if (try access.boolean(0, 2) or privileges & required == 0) return error.ChannelReadOnly;

    var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message,is_action,client_uuid) VALUES($1,$2,$3,$4,$5) ON CONFLICT(sender_id,client_uuid) WHERE client_uuid!='' DO NOTHING RETURNING 1", &.{ sender, target, message, if (is_action) "true" else "false", uuid });
    const inserted = insert.rows() != 0;
    insert.deinit();
    var row = try postgres.queryParams(allocator, lease.conn, "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE m.sender_id=$1 AND m.client_uuid=$2", &.{ sender, uuid });
    defer row.deinit();
    if (row.rows() != 1) return error.DatabaseQueryFailed;
    if (!std.mem.eql(u8, row.value(0, 1), target) or !std.mem.eql(u8, row.value(0, 2), message) or (try row.boolean(0, 3)) != is_action) return error.ChatUuidConflict;

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try lazer.writeChatMessage(&output.writer, .{
        .id = try row.int(i64, 0, 0),
        .channel_id = channel_id,
        .sender_id = sender_id,
        .sender_name = row.value(0, 6),
        .sender_country = row.value(0, 7),
        .sender_privileges = try row.int(u32, 0, 8),
        .content = message,
        .is_action = is_action,
        .uuid = uuid,
        .timestamp = row.value(0, 5),
    });
    return .{ .json = try output.toOwnedSlice(), .inserted = inserted };
}

pub fn recordLazerRoomMessage(self: anytype, allocator: std.mem.Allocator, sender_id: i32, room_id: i64, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
    const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    var sender_buffer: [24]u8 = undefined;
    var target_buffer: [64]u8 = undefined;
    const sender = try std.fmt.bufPrint(&sender_buffer, "{d}", .{sender_id});
    const target = try lazer.roomChannelName(&target_buffer, room_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message,is_action,client_uuid) VALUES($1,$2,$3,$4,$5) ON CONFLICT(sender_id,client_uuid) WHERE client_uuid!='' DO NOTHING RETURNING 1", &.{ sender, target, message, if (is_action) "true" else "false", uuid });
    const inserted = insert.rows() != 0;
    insert.deinit();
    var row = try postgres.queryParams(allocator, lease.conn, "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE m.sender_id=$1 AND m.client_uuid=$2", &.{ sender, uuid });
    defer row.deinit();
    if (row.rows() != 1) return error.DatabaseQueryFailed;
    if (!std.mem.eql(u8, row.value(0, 1), target) or !std.mem.eql(u8, row.value(0, 2), message) or (try row.boolean(0, 3)) != is_action) return error.ChatUuidConflict;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try lazer.writeChatMessage(&output.writer, .{
        .id = try row.int(i64, 0, 0),
        .channel_id = channel_id,
        .sender_id = sender_id,
        .sender_name = row.value(0, 6),
        .sender_country = row.value(0, 7),
        .sender_privileges = try row.int(u32, 0, 8),
        .content = message,
        .is_action = is_action,
        .uuid = uuid,
        .timestamp = row.value(0, 5),
    });
    return .{ .json = try output.toOwnedSlice(), .inserted = inserted };
}

pub fn recordLazerDirectMessage(self: anytype, allocator: std.mem.Allocator, sender_id: i32, target_id: i32, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
    const channel_id = lazer.privateChannelId(target_id) orelse return error.InvalidDirectMessage;
    var sender_buf: [24]u8 = undefined;
    var receiver_buf: [24]u8 = undefined;
    var target_buf: [64]u8 = undefined;
    const sender = try std.fmt.bufPrint(&sender_buf, "{d}", .{sender_id});
    const receiver = try std.fmt.bufPrint(&receiver_buf, "{d}", .{target_id});
    const target = try lazer.directMessageTarget(&target_buf, sender_id, target_id);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    if (!try directMessageAllowedWithConnection(self, lease.conn, sender_id, target_id)) return error.DirectMessageBlocked;
    var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message,is_action,client_uuid) VALUES($1,$2,$3,$4,$5) ON CONFLICT(sender_id,client_uuid) WHERE client_uuid!='' DO NOTHING RETURNING 1", &.{ sender, target, message, if (is_action) "true" else "false", uuid });
    const inserted = insert.rows() != 0;
    insert.deinit();
    var row = try postgres.queryParams(allocator, lease.conn, "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE m.sender_id=$1 AND m.client_uuid=$2", &.{ sender, uuid });
    defer row.deinit();
    if (row.rows() != 1) return error.DatabaseQueryFailed;
    if (!std.mem.eql(u8, row.value(0, 1), target) or !std.mem.eql(u8, row.value(0, 2), message) or (try row.boolean(0, 3)) != is_action) return error.ChatUuidConflict;
    var direct_message_id: ?i64 = null;
    if (inserted) {
        var chat_buf: [24]u8 = undefined;
        const chat = try std.fmt.bufPrint(&chat_buf, "{d}", .{try row.int(i64, 0, 0)});
        var direct = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.direct_messages(from_id,to_id,message,is_action,client_uuid,chat_message_id) VALUES($1,$2,$3,$4,$5,$6) RETURNING id", &.{ sender, receiver, message, if (is_action) "true" else "false", uuid, chat });
        direct_message_id = try direct.int(i64, 0, 0);
        direct.deinit();
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try lazer.writeChatMessage(&output.writer, .{
        .id = try row.int(i64, 0, 0),
        .channel_id = channel_id,
        .sender_id = sender_id,
        .sender_name = row.value(0, 6),
        .sender_country = row.value(0, 7),
        .sender_privileges = try row.int(u32, 0, 8),
        .content = message,
        .is_action = is_action,
        .uuid = uuid,
        .timestamp = row.value(0, 5),
    });
    try postgres.exec(lease.conn, "COMMIT");
    return .{ .json = try output.toOwnedSlice(), .inserted = inserted, .direct_message_id = direct_message_id };
}

pub fn lazerDirectMessagesJson(self: anytype, allocator: std.mem.Allocator, viewer_id: i32, other_id: i32, since: i64, limit: u16) ![]u8 {
    if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    const channel_id = lazer.privateChannelId(other_id) orelse return error.InvalidDirectMessage;
    var target_buf: [64]u8 = undefined;
    var since_buf: [24]u8 = undefined;
    var limit_buf: [8]u8 = undefined;
    const target = try lazer.directMessageTarget(&target_buf, viewer_id, other_id);
    const since_text = try std.fmt.bufPrint(&since_buf, "{d}", .{since});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = if (since == 0)
        "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT * FROM zigcho.chat_messages WHERE target=$1 ORDER BY id DESC LIMIT $2::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
    else
        "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE m.target=$1 AND m.id>$2::bigint AND NOT u.restricted ORDER BY m.id LIMIT $3::int";
    var result = if (since == 0)
        try postgres.queryParams(allocator, lease.conn, sql, &.{ target, limit_text })
    else
        try postgres.queryParams(allocator, lease.conn, sql, &.{ target, since_text, limit_text });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (0..result.rows()) |result_row| {
        if (result_row != 0) try output.writer.writeByte(',');
        try lazer.writeChatMessage(&output.writer, .{
            .id = try result.int(i64, result_row, 0),
            .channel_id = channel_id,
            .sender_id = try result.int(i32, result_row, 1),
            .sender_name = result.value(result_row, 2),
            .sender_country = result.value(result_row, 3),
            .sender_privileges = try result.int(u32, result_row, 8),
            .content = result.value(result_row, 4),
            .is_action = try result.boolean(result_row, 5),
            .uuid = result.value(result_row, 6),
            .timestamp = result.value(result_row, 7),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn directMessageThreadsJson(self: anytype, allocator: std.mem.Allocator, viewer_id: i32, limit: u8) ![]u8 {
    if (viewer_id <= 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    var viewer_buf: [24]u8 = undefined;
    var limit_buf: [8]u8 = undefined;
    const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql =
        "WITH participants AS (SELECT CASE WHEN from_id=$1 THEN to_id ELSE from_id END other_id,max(id) last_id FROM zigcho.direct_messages WHERE from_id=$1 OR to_id=$1 GROUP BY other_id) " ++
        "SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,d.message,d.is_action,to_char(to_timestamp(d.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),d.from_id,(SELECT count(*) FROM zigcho.direct_messages unread WHERE unread.to_id=$1 AND unread.from_id=u.id AND NOT unread.read) unread FROM participants p JOIN zigcho.direct_messages d ON d.id=p.last_id JOIN zigcho.users u ON u.id=p.other_id WHERE NOT u.restricted ORDER BY d.id DESC LIMIT $2::int";
    var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ viewer, limit_text });
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
        try output.writer.print(",\"privileges\":{d},\"last_message\":", .{try result.int(u32, row, 3)});
        try common.jsonString(&output.writer, result.value(row, 4));
        try output.writer.print(",\"is_action\":{},\"last_message_at\":", .{try result.boolean(row, 5)});
        try common.jsonString(&output.writer, result.value(row, 6));
        try output.writer.print(",\"last_sender_id\":{d},\"unread\":{d}}}", .{ try result.int(i32, row, 7), try result.int(i64, row, 8) });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerAllMessagesJson(self: anytype, allocator: std.mem.Allocator, viewer_id: i32, since: i64, limit: u16) ![]u8 {
    if (viewer_id <= 0 or since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    var low_pattern_buf: [64]u8 = undefined;
    var high_pattern_buf: [64]u8 = undefined;
    var viewer_buf: [24]u8 = undefined;
    var since_buf: [24]u8 = undefined;
    var limit_buf: [8]u8 = undefined;
    const low_pattern = try std.fmt.bufPrint(&low_pattern_buf, "@dm:{d}:%", .{viewer_id});
    const high_pattern = try std.fmt.bufPrint(&high_pattern_buf, "@dm:%:{d}", .{viewer_id});
    const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
    const since_text = try std.fmt.bufPrint(&since_buf, "{d}", .{since});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    const filter = "target IN('#osu','#announce','#lobby','#lazer') OR target LIKE $1 OR target LIKE $2";
    const unread_filter = "(m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>coalesce((SELECT r.last_read_id FROM zigcho.lazer_channel_reads r WHERE r.user_id=$3::int AND r.channel_id=CASE m.target WHEN '#osu' THEN 1 WHEN '#announce' THEN 2 WHEN '#lobby' THEN 3 WHEN '#lazer' THEN 4 END),0)) OR ((m.target LIKE $1 OR m.target LIKE $2) AND EXISTS(SELECT 1 FROM zigcho.direct_messages d WHERE d.chat_message_id=m.id AND d.to_id=$3::int AND NOT d.read))";
    const sql = if (since == 0)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT m.* FROM zigcho.chat_messages m WHERE " ++ unread_filter ++ " ORDER BY m.id DESC LIMIT $4::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
    else
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE (" ++ filter ++ ") AND m.id>$3::bigint AND NOT u.restricted ORDER BY m.id LIMIT $4::int";
    var result = if (since == 0)
        try postgres.queryParams(allocator, lease.conn, sql, &.{ low_pattern, high_pattern, viewer, limit_text })
    else
        try postgres.queryParams(allocator, lease.conn, sql, &.{ low_pattern, high_pattern, since_text, limit_text });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    for (0..result.rows()) |result_row| {
        const message_target = result.value(result_row, 1);
        const channel_id = lazer.channelId(message_target) orelse private: {
            const other_id = lazer.directMessageOther(message_target, viewer_id) orelse continue;
            break :private lazer.privateChannelId(other_id).?;
        };
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try lazer.writeChatMessage(&output.writer, .{
            .id = try result.int(i64, result_row, 0),
            .channel_id = channel_id,
            .sender_id = try result.int(i32, result_row, 2),
            .sender_name = result.value(result_row, 3),
            .sender_country = result.value(result_row, 4),
            .sender_privileges = try result.int(u32, result_row, 9),
            .content = result.value(result_row, 5),
            .is_action = try result.boolean(result_row, 6),
            .uuid = result.value(result_row, 7),
            .timestamp = result.value(result_row, 8),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerAllMessagesForRoomJson(self: anytype, allocator: std.mem.Allocator, viewer_id: i32, room_id: i64, since: i64, limit: u16) ![]u8 {
    const room_channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    if (viewer_id <= 0 or since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    var low_pattern_buffer: [64]u8 = undefined;
    var high_pattern_buffer: [64]u8 = undefined;
    var room_target_buffer: [64]u8 = undefined;
    var viewer_buffer: [24]u8 = undefined;
    var since_buffer: [24]u8 = undefined;
    var limit_buffer: [8]u8 = undefined;
    var room_channel_buffer: [24]u8 = undefined;
    const low_pattern = try std.fmt.bufPrint(&low_pattern_buffer, "@dm:{d}:%", .{viewer_id});
    const high_pattern = try std.fmt.bufPrint(&high_pattern_buffer, "@dm:%:{d}", .{viewer_id});
    const room_target = try lazer.roomChannelName(&room_target_buffer, room_id);
    const viewer = try std.fmt.bufPrint(&viewer_buffer, "{d}", .{viewer_id});
    const since_text = try std.fmt.bufPrint(&since_buffer, "{d}", .{since});
    const limit_text = try std.fmt.bufPrint(&limit_buffer, "{d}", .{limit});
    const room_channel = try std.fmt.bufPrint(&room_channel_buffer, "{d}", .{room_channel_id});
    var lease = self.pool.acquire();
    defer lease.release();
    const filter = "target IN('#osu','#announce','#lobby','#lazer') OR target LIKE $1 OR target LIKE $2 OR target=$5";
    const unread_filter = "(m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>coalesce((SELECT r.last_read_id FROM zigcho.lazer_channel_reads r WHERE r.user_id=$3::int AND r.channel_id=CASE m.target WHEN '#osu' THEN 1 WHEN '#announce' THEN 2 WHEN '#lobby' THEN 3 WHEN '#lazer' THEN 4 END),0)) OR ((m.target LIKE $1 OR m.target LIKE $2) AND EXISTS(SELECT 1 FROM zigcho.direct_messages d WHERE d.chat_message_id=m.id AND d.to_id=$3::int AND NOT d.read)) OR (m.target=$5 AND m.id>coalesce((SELECT r.last_read_id FROM zigcho.lazer_channel_reads r WHERE r.user_id=$3::int AND r.channel_id=$6::bigint),0))";
    const sql = if (since == 0)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT m.* FROM zigcho.chat_messages m WHERE " ++ unread_filter ++ " ORDER BY m.id DESC LIMIT $4::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
    else
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE (" ++ filter ++ ") AND m.id>$3::bigint AND NOT u.restricted ORDER BY m.id LIMIT $4::int";
    var result = if (since == 0)
        try postgres.queryParams(allocator, lease.conn, sql, &.{ low_pattern, high_pattern, viewer, limit_text, room_target, room_channel })
    else
        try postgres.queryParams(allocator, lease.conn, sql, &.{ low_pattern, high_pattern, since_text, limit_text, room_target });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var written: usize = 0;
    for (0..result.rows()) |row| {
        const message_target = result.value(row, 1);
        const channel_id = if (std.mem.eql(u8, message_target, room_target))
            room_channel_id
        else
            lazer.channelId(message_target) orelse private: {
                const other_id = lazer.directMessageOther(message_target, viewer_id) orelse continue;
                break :private lazer.privateChannelId(other_id).?;
            };
        if (written != 0) try output.writer.writeByte(',');
        written += 1;
        try lazer.writeChatMessage(&output.writer, .{
            .id = try result.int(i64, row, 0),
            .channel_id = channel_id,
            .sender_id = try result.int(i32, row, 2),
            .sender_name = result.value(row, 3),
            .sender_country = result.value(row, 4),
            .sender_privileges = try result.int(u32, row, 9),
            .content = result.value(row, 5),
            .is_action = try result.boolean(row, 6),
            .uuid = result.value(row, 7),
            .timestamp = result.value(row, 8),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerChatMessagesJson(self: anytype, allocator: std.mem.Allocator, channel_id: ?i64, since: i64, limit: u16) ![]u8 {
    if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    const target = if (channel_id) |id| lazer.channelName(id) orelse return error.UnknownChannel else null;
    var since_buf: [24]u8 = undefined;
    var limit_buf: [8]u8 = undefined;
    const since_text = try std.fmt.bufPrint(&since_buf, "{d}", .{since});
    const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = if (target != null and since == 0)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT * FROM zigcho.chat_messages WHERE target=$1 ORDER BY id DESC LIMIT $2::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
    else if (target != null)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE m.target=$1 AND m.id>$2::bigint AND NOT u.restricted ORDER BY m.id LIMIT $3::int"
    else if (since == 0)
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT * FROM zigcho.chat_messages WHERE target IN('#osu','#announce','#lobby','#lazer') ORDER BY id DESC LIMIT $1::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
    else
        "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>$1::bigint AND NOT u.restricted ORDER BY m.id LIMIT $2::int";
    var result = if (target) |name|
        if (since == 0)
            try postgres.queryParams(allocator, lease.conn, sql, &.{ name, limit_text })
        else
            try postgres.queryParams(allocator, lease.conn, sql, &.{ name, since_text, limit_text })
    else if (since == 0)
        try postgres.queryParams(allocator, lease.conn, sql, &.{limit_text})
    else
        try postgres.queryParams(allocator, lease.conn, sql, &.{ since_text, limit_text });
    defer result.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var first = true;
    for (0..result.rows()) |row| {
        const message_channel_id = lazer.channelId(result.value(row, 1)) orelse continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        try lazer.writeChatMessage(&output.writer, .{
            .id = try result.int(i64, row, 0),
            .channel_id = message_channel_id,
            .sender_id = try result.int(i32, row, 2),
            .sender_name = result.value(row, 3),
            .sender_country = result.value(row, 4),
            .sender_privileges = try result.int(u32, row, 9),
            .content = result.value(row, 5),
            .is_action = try result.boolean(row, 6),
            .uuid = result.value(row, 7),
            .timestamp = result.value(row, 8),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerRoomMessagesJson(self: anytype, allocator: std.mem.Allocator, room_id: i64, since: i64, limit: u16) ![]u8 {
    const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
    var target_buffer: [64]u8 = undefined;
    var since_buffer: [24]u8 = undefined;
    var limit_buffer: [8]u8 = undefined;
    const target = try lazer.roomChannelName(&target_buffer, room_id);
    const since_text = try std.fmt.bufPrint(&since_buffer, "{d}", .{since});
    const limit_text = try std.fmt.bufPrint(&limit_buffer, "{d}", .{limit});
    var lease = self.pool.acquire();
    defer lease.release();
    const sql = if (since == 0)
        "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT * FROM zigcho.chat_messages WHERE target=$1 ORDER BY id DESC LIMIT $2::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
    else
        "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE m.target=$1 AND m.id>$2::bigint AND NOT u.restricted ORDER BY m.id LIMIT $3::int";
    var result = if (since == 0)
        try postgres.queryParams(allocator, lease.conn, sql, &.{ target, limit_text })
    else
        try postgres.queryParams(allocator, lease.conn, sql, &.{ target, since_text, limit_text });
    defer result.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    for (0..result.rows()) |row| {
        if (row != 0) try output.writer.writeByte(',');
        try lazer.writeChatMessage(&output.writer, .{
            .id = try result.int(i64, row, 0),
            .channel_id = channel_id,
            .sender_id = try result.int(i32, row, 1),
            .sender_name = result.value(row, 2),
            .sender_country = result.value(row, 3),
            .sender_privileges = try result.int(u32, row, 8),
            .content = result.value(row, 4),
            .is_action = try result.boolean(row, 5),
            .uuid = result.value(row, 6),
            .timestamp = result.value(row, 7),
        });
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerRoomChannelCursor(self: anytype, user_id: i32, room_id: i64) !ChatCursor {
    if (user_id <= 0) return error.InvalidUser;
    const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    var user_buffer: [24]u8 = undefined;
    var channel_buffer: [24]u8 = undefined;
    var target_buffer: [64]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buffer, "{d}", .{user_id});
    const channel = try std.fmt.bufPrint(&channel_buffer, "{d}", .{channel_id});
    const target = try lazer.roomChannelName(&target_buffer, room_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT (SELECT max(id) FROM zigcho.chat_messages WHERE target=$1),(SELECT last_read_id FROM zigcho.lazer_channel_reads WHERE user_id=$2::int AND channel_id=$3::bigint)", &.{ target, user, channel });
    defer result.deinit();
    if (result.rows() != 1) return error.DatabaseQueryFailed;
    return .{
        .last_message_id = if (result.isNull(0, 0)) null else try result.int(i64, 0, 0),
        .last_read_id = if (result.isNull(0, 1)) null else try result.int(i64, 0, 1),
    };
}

pub fn markLazerRoomChannelRead(self: anytype, user_id: i32, room_id: i64, message_id: i64) !void {
    if (user_id <= 0 or message_id <= 0) return error.InvalidChatQuery;
    const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
    var user_buffer: [24]u8 = undefined;
    var channel_buffer: [24]u8 = undefined;
    var message_buffer: [24]u8 = undefined;
    var target_buffer: [64]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buffer, "{d}", .{user_id});
    const channel = try std.fmt.bufPrint(&channel_buffer, "{d}", .{channel_id});
    const message = try std.fmt.bufPrint(&message_buffer, "{d}", .{message_id});
    const target = try lazer.roomChannelName(&target_buffer, room_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_channel_reads(user_id,channel_id,last_read_id) SELECT $1::int,$2::bigint,$3::bigint WHERE EXISTS(SELECT 1 FROM zigcho.chat_messages WHERE id=$3::bigint AND target=$4) ON CONFLICT(user_id,channel_id) DO UPDATE SET last_read_id=greatest(zigcho.lazer_channel_reads.last_read_id,excluded.last_read_id),updated_at=extract(epoch FROM clock_timestamp())::bigint RETURNING 1", &.{ user, channel, message, target });
    defer result.deinit();
    if (result.rows() == 0) return error.ChatMessageNotFound;
}

pub fn lazerChannelListJson(self: anytype, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
    if (user_id <= 0) return error.InvalidUser;
    var user_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    var lease = self.pool.acquire();
    defer lease.release();

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('[');
    var channel_id: i64 = 1;
    while (channel_id <= 4) : (channel_id += 1) {
        if (channel_id != 1) try output.writer.writeByte(',');
        var channel_buf: [24]u8 = undefined;
        const channel = try std.fmt.bufPrint(&channel_buf, "{d}", .{channel_id});
        const target = lazer.channelName(channel_id).?;
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT (SELECT max(id) FROM zigcho.chat_messages WHERE target=$1),(SELECT last_read_id FROM zigcho.lazer_channel_reads WHERE user_id=$2::int AND channel_id=$3::smallint)", &.{ target, user, channel });
        defer result.deinit();
        const last_message_id: ?i64 = if (result.isNull(0, 0)) null else try result.int(i64, 0, 0);
        const last_read_id: ?i64 = if (result.isNull(0, 1)) null else try result.int(i64, 0, 1);
        try lazer.writeChatChannel(&output.writer, channel_id, last_message_id, last_read_id);
    }
    try output.writer.writeByte(']');
    return output.toOwnedSlice();
}

pub fn lazerChannelCursor(self: anytype, user_id: i32, channel_id: i64) !ChatCursor {
    const target = lazer.channelName(channel_id) orelse return error.UnknownChannel;
    if (user_id <= 0) return error.InvalidUser;
    var user_buf: [24]u8 = undefined;
    var channel_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const channel = try std.fmt.bufPrint(&channel_buf, "{d}", .{channel_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT (SELECT max(id) FROM zigcho.chat_messages WHERE target=$1),(SELECT last_read_id FROM zigcho.lazer_channel_reads WHERE user_id=$2::int AND channel_id=$3::smallint)", &.{ target, user, channel });
    defer result.deinit();
    if (result.rows() != 1) return error.DatabaseQueryFailed;
    return .{
        .last_message_id = if (result.isNull(0, 0)) null else try result.int(i64, 0, 0),
        .last_read_id = if (result.isNull(0, 1)) null else try result.int(i64, 0, 1),
    };
}

pub fn lazerDirectMessageCursor(self: anytype, viewer_id: i32, other_id: i32) !ChatCursor {
    if (viewer_id <= 0 or other_id <= 0 or viewer_id == other_id) return error.InvalidDirectMessage;
    var viewer_buf: [24]u8 = undefined;
    var other_buf: [24]u8 = undefined;
    var target_buf: [64]u8 = undefined;
    const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
    const other = try std.fmt.bufPrint(&other_buf, "{d}", .{other_id});
    const target = try lazer.directMessageTarget(&target_buf, viewer_id, other_id);
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT max(m.id),CASE WHEN (SELECT min(d.chat_message_id) FROM zigcho.direct_messages d WHERE d.to_id=$2::int AND d.from_id=$3::int AND NOT d.read AND d.chat_message_id IS NOT NULL) IS NULL THEN max(m.id) ELSE (SELECT max(previous.id) FROM zigcho.chat_messages previous WHERE previous.target=$1 AND previous.id<(SELECT min(d.chat_message_id) FROM zigcho.direct_messages d WHERE d.to_id=$2::int AND d.from_id=$3::int AND NOT d.read AND d.chat_message_id IS NOT NULL)) END FROM zigcho.chat_messages m WHERE m.target=$1", &.{ target, viewer, other });
    defer result.deinit();
    if (result.rows() != 1) return error.DatabaseQueryFailed;
    return .{
        .last_message_id = if (result.isNull(0, 0)) null else try result.int(i64, 0, 0),
        .last_read_id = if (result.isNull(0, 1)) null else try result.int(i64, 0, 1),
    };
}

pub fn markLazerChannelRead(self: anytype, user_id: i32, channel_id: i64, message_id: i64) !void {
    const target = lazer.channelName(channel_id) orelse return error.UnknownChannel;
    if (user_id <= 0 or message_id <= 0) return error.InvalidChatQuery;
    var user_buf: [24]u8 = undefined;
    var channel_buf: [24]u8 = undefined;
    var message_buf: [24]u8 = undefined;
    const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
    const channel = try std.fmt.bufPrint(&channel_buf, "{d}", .{channel_id});
    const message = try std.fmt.bufPrint(&message_buf, "{d}", .{message_id});
    var lease = self.pool.acquire();
    defer lease.release();
    var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_channel_reads(user_id,channel_id,last_read_id) SELECT $1::int,$2::smallint,$3::bigint WHERE EXISTS(SELECT 1 FROM zigcho.chat_messages WHERE id=$3::bigint AND target=$4) ON CONFLICT(user_id,channel_id) DO UPDATE SET last_read_id=greatest(zigcho.lazer_channel_reads.last_read_id,excluded.last_read_id),updated_at=extract(epoch FROM clock_timestamp())::bigint RETURNING 1", &.{ user, channel, message, target });
    defer result.deinit();
    if (result.rows() == 0) return error.ChatMessageNotFound;
}

pub fn markLazerDirectMessageRead(self: anytype, viewer_id: i32, other_id: i32, message_id: i64) !void {
    if (viewer_id <= 0 or other_id <= 0 or viewer_id == other_id or message_id <= 0) return error.InvalidChatQuery;
    var viewer_buf: [24]u8 = undefined;
    var other_buf: [24]u8 = undefined;
    var message_buf: [24]u8 = undefined;
    var target_buf: [64]u8 = undefined;
    const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
    const other = try std.fmt.bufPrint(&other_buf, "{d}", .{other_id});
    const message = try std.fmt.bufPrint(&message_buf, "{d}", .{message_id});
    const target = try lazer.directMessageTarget(&target_buf, viewer_id, other_id);
    var lease = self.pool.acquire();
    defer lease.release();
    try postgres.exec(lease.conn, "BEGIN");
    errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
    var found = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.chat_messages WHERE id=$1::bigint AND target=$2", &.{ message, target });
    defer found.deinit();
    if (found.rows() == 0) return error.ChatMessageNotFound;
    var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.direct_messages SET read=true WHERE to_id=$1::int AND from_id=$2::int AND NOT read AND (chat_message_id IS NULL OR chat_message_id<=$3::bigint)", &.{ viewer, other, message });
    update.deinit();
    try postgres.exec(lease.conn, "COMMIT");
}
