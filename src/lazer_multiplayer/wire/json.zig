const std = @import("std");
const max_playlist = @import("../../lazer_multiplayer.zig").max_playlist;
const max_room_participants = @import("../../lazer_multiplayer.zig").max_room_participants;
const timespan_ticks_per_second = @import("../../lazer_multiplayer.zig").timespan_ticks_per_second;
const matchmaking_stage = @import("../../lazer_multiplayer.zig").matchmaking_stage;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const RoomScoreRecord = @import("../../lazer_multiplayer.zig").RoomScoreRecord;
const RoomPersistence = @import("../../lazer_multiplayer.zig").RoomPersistence;
const scoreRanksBefore = @import("../../lazer_multiplayer.zig").scoreRanksBefore;
const scoreEligibleForHighScore = @import("../../lazer_multiplayer.zig").scoreEligibleForHighScore;
const MessagePackReader = @import("../../lazer_multiplayer.zig").MessagePackReader;
const PlaylistItem = @import("../../lazer_multiplayer.zig").PlaylistItem;
const RoomParticipant = @import("../../lazer_multiplayer.zig").RoomParticipant;
const Settings = @import("../../lazer_multiplayer.zig").Settings;
const Room = @import("../rooms/model.zig").Room;

pub fn writeApiUserJson(writer: *std.Io.Writer, id: i32, name: []const u8, country: [2]u8) !void {
    try writer.print("{{\"id\":{d},\"username\":", .{id});
    try std.json.Stringify.value(name, .{}, writer);
    try writer.print(",\"avatar_url\":\"https://a.kai.ovh/{d}\",\"country_code\":", .{id});
    try std.json.Stringify.value(country[0..], .{}, writer);
    try writer.writeAll(",\"is_active\":true,\"is_supporter\":true}");
}

pub fn beatmapStatusName(status: i8) []const u8 {
    return switch (status) {
        1 => "wip",
        2 => "pending",
        3 => "ranked",
        4 => "approved",
        5 => "qualified",
        6 => "loved",
        else => "graveyard",
    };
}

pub fn matchmakingStageName(stage: u8) []const u8 {
    return switch (stage) {
        matchmaking_stage.waiting_for_clients_join => "waiting for players",
        matchmaking_stage.round_warmup => "round warmup",
        matchmaking_stage.user_beatmap_select => "choosing a beatmap",
        matchmaking_stage.server_beatmap_finalised => "beatmap selected",
        matchmaking_stage.waiting_for_beatmap_download => "waiting for downloads",
        matchmaking_stage.gameplay_warmup => "gameplay warmup",
        matchmaking_stage.gameplay => "playing",
        matchmaking_stage.results => "results",
        else => "finished",
    };
}

pub fn rankedStageName(stage: u8) []const u8 {
    return switch (stage) {
        ranked_stage.wait_for_join => "waiting for players",
        ranked_stage.round_warmup => "round warmup",
        ranked_stage.card_discard => "discarding cards",
        ranked_stage.finish_card_discard => "locking discards",
        ranked_stage.card_play => "playing cards",
        ranked_stage.finish_card_play => "locking cards",
        ranked_stage.gameplay_warmup => "gameplay warmup",
        ranked_stage.gameplay => "playing",
        ranked_stage.results => "results",
        else => "finished",
    };
}

pub fn writeRoomModeJson(writer: *std.Io.Writer, room: *const Room) !void {
    try writer.writeAll(",\"zigcho\":{");
    if (room.ranked_play) |ranked| {
        try writer.writeAll("\"kind\":\"ranked_play\",\"phase\":");
        try std.json.Stringify.value(rankedStageName(ranked.stage), .{}, writer);
        try writer.print(",\"round\":{d},\"star_rating\":{d},\"active_user_id\":", .{ ranked.current_round, ranked.star_rating });
        if (ranked.active_user_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
        try writer.writeAll(",\"winner_id\":");
        if (ranked.winning_user_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
        try writer.writeAll(",\"players\":[");
        var written: usize = 0;
        for (ranked.users) |entry| if (entry) |user| {
            if (written != 0) try writer.writeByte(',');
            try writer.print("{{\"user_id\":{d},\"rating\":{d},\"rating_after\":{d},\"life\":{d},\"rounds_won\":{d},\"total_score\":{d}}}", .{ user.id, user.rating, user.rating_after, user.life, user.rounds_won, user.total_score });
            written += 1;
        };
        try writer.writeByte(']');
    } else if (room.matchmaking) |matchmaking| {
        try writer.writeAll("\"kind\":\"quick_play\",\"phase\":");
        try std.json.Stringify.value(matchmakingStageName(matchmaking.stage), .{}, writer);
        try writer.print(",\"round\":{d},\"gameplay_item_id\":{d},\"players\":[", .{ matchmaking.current_round, matchmaking.gameplay_item });
        var written: usize = 0;
        for (matchmaking.users) |entry| if (entry) |user| {
            if (written != 0) try writer.writeByte(',');
            try writer.print("{{\"user_id\":{d},\"points\":{d},\"placement\":", .{ user.id, user.points });
            if (user.placement) |placement| try writer.print("{d}", .{placement}) else try writer.writeAll("null");
            try writer.writeByte('}');
            written += 1;
        };
        try writer.writeByte(']');
    } else {
        try writer.writeAll("\"kind\":\"room\",\"phase\":");
        try std.json.Stringify.value(if (room.state == 0) "waiting" else "playing", .{}, writer);
        try writer.writeAll(",\"round\":0,\"players\":[]");
    }
    try writer.writeByte('}');
}

pub fn writeMessagePackJsonValue(writer: *std.Io.Writer, reader: *MessagePackReader, depth: u8) !void {
    if (depth >= 16 or reader.pos >= reader.data.len) return error.InvalidMultiplayerJsonValue;
    const tag = reader.data[reader.pos];
    if (tag == 0xc0) {
        reader.pos += 1;
        return writer.writeAll("null");
    }
    if (tag == 0xc2 or tag == 0xc3) return writer.writeAll(if (try reader.boolean()) "true" else "false");
    if (tag <= 0x7f or tag >= 0xe0 or (tag >= 0xcc and tag <= 0xd3)) return writer.print("{d}", .{try reader.integer()});
    if (tag == 0xca) {
        _ = try reader.byte();
        const value: f32 = @bitCast(try reader.readUnsigned(u32));
        if (!std.math.isFinite(value)) return error.InvalidMultiplayerJsonValue;
        return writer.print("{d}", .{value});
    }
    if (tag == 0xcb) {
        _ = try reader.byte();
        const value: f64 = @bitCast(try reader.readUnsigned(u64));
        if (!std.math.isFinite(value)) return error.InvalidMultiplayerJsonValue;
        return writer.print("{d}", .{value});
    }
    if ((tag >= 0xa0 and tag <= 0xbf) or tag == 0xd9 or tag == 0xda or tag == 0xdb) {
        const value = try reader.string();
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidMultiplayerJsonValue;
        return std.json.Stringify.value(value, .{}, writer);
    }
    if ((tag >= 0x90 and tag <= 0x9f) or tag == 0xdc or tag == 0xdd) {
        const len = try reader.arrayLen();
        try writer.writeByte('[');
        for (0..len) |index| {
            if (index != 0) try writer.writeByte(',');
            try writeMessagePackJsonValue(writer, reader, depth + 1);
        }
        return writer.writeByte(']');
    }
    if ((tag >= 0x80 and tag <= 0x8f) or tag == 0xde or tag == 0xdf) {
        const len = try reader.mapLen();
        try writer.writeByte('{');
        for (0..len) |index| {
            if (index != 0) try writer.writeByte(',');
            const key = try reader.string();
            if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidMultiplayerJsonValue;
            try std.json.Stringify.value(key, .{}, writer);
            try writer.writeByte(':');
            try writeMessagePackJsonValue(writer, reader, depth + 1);
        }
        return writer.writeByte('}');
    }
    return error.InvalidMultiplayerJsonValue;
}

pub fn writeMessagePackJson(writer: *std.Io.Writer, encoded: []const u8) !void {
    var reader: MessagePackReader = .{ .data = encoded };
    try writeMessagePackJsonValue(writer, &reader, 0);
    if (reader.pos != reader.data.len) return error.InvalidMultiplayerJsonValue;
}

pub fn writePlaylistItemJson(writer: *std.Io.Writer, item: PlaylistItem) !void {
    const mode: []const u8 = switch (item.ruleset_id) {
        0 => "osu",
        1 => "taiko",
        2 => "fruits",
        else => "mania",
    };
    const set_id = if (item.beatmapset_id > 0) item.beatmapset_id else item.beatmap_id;
    const artist = if (item.artist.len != 0) item.artist.slice() else "online beatmap";
    const title = if (item.title.len != 0) item.title.slice() else "unknown song";
    const version = if (item.version.len != 0) item.version.slice() else "online difficulty";
    const creator = if (item.creator.len != 0) item.creator.slice() else "unknown";
    const status = beatmapStatusName(item.status);
    try writer.print("{{\"id\":{d},\"owner_id\":{d},\"ruleset_id\":{d},\"expired\":{s},\"playlist_order\":{d},\"played_at\":null,\"allowed_mods\":", .{ item.id, item.owner_id, item.ruleset_id, if (item.expired) "true" else "false", item.order });
    try writeMessagePackJson(writer, item.allowed_mods.slice());
    try writer.writeAll(",\"required_mods\":");
    try writeMessagePackJson(writer, item.required_mods.slice());
    try writer.print(",\"beatmap_id\":{d},\"beatmap\":{{\"id\":{d},\"beatmapset_id\":{d},\"mode\":", .{ item.beatmap_id, item.beatmap_id, set_id });
    try std.json.Stringify.value(mode, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(status, .{}, writer);
    try writer.writeAll(",\"version\":");
    try std.json.Stringify.value(version, .{}, writer);
    try writer.writeAll(",\"difficulty_rating\":");
    try writer.print("{d},\"total_length\":{d},\"hit_length\":{d},\"checksum\":", .{ item.star_rating, item.total_length, item.hit_length });
    try std.json.Stringify.value(item.checksum.slice(), .{}, writer);
    try writer.print(",\"beatmapset\":{{\"id\":{d},\"status\":", .{set_id});
    try std.json.Stringify.value(status, .{}, writer);
    try writer.writeAll(",\"artist\":");
    try std.json.Stringify.value(artist, .{}, writer);
    try writer.writeAll(",\"artist_unicode\":");
    try std.json.Stringify.value(artist, .{}, writer);
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(title, .{}, writer);
    try writer.writeAll(",\"title_unicode\":");
    try std.json.Stringify.value(title, .{}, writer);
    try writer.writeAll(",\"creator\":");
    try std.json.Stringify.value(creator, .{}, writer);
    try writer.print(",\"covers\":{{\"cover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover.jpg\",\"cover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover@2x.jpg\",\"card\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card.jpg\",\"card@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card@2x.jpg\",\"list\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list.jpg\",\"list@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list@2x.jpg\",\"slimcover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover.jpg\",\"slimcover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover@2x.jpg\"}},\"preview_url\":\"https://b.kai.ovh/preview/{d}.mp3\"}}}},\"freestyle\":{s}}}", .{ set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, if (item.freestyle) "true" else "false" });
}

pub fn writeIsoTimestamp(writer: *std.Io.Writer, unix_seconds: i64) !void {
    if (unix_seconds < 0) return error.InvalidMultiplayerTimestamp;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    try writer.print("\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\"", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

pub fn autoStartSeconds(settings: Settings) i64 {
    var reader: MessagePackReader = .{ .data = settings.auto_start.slice() };
    const ticks = reader.integer() catch return 0;
    if (reader.pos != reader.data.len or ticks <= 0) return 0;
    return @divFloor(ticks, timespan_ticks_per_second);
}

pub fn roomHasEnded(room: *const Room, now_seconds: i64) bool {
    return room.ended or (room.ends_at > 0 and now_seconds >= room.ends_at);
}

pub fn writeCurrentUserScore(writer: *std.Io.Writer, room: *const Room, requester_id: i32) !void {
    if (requester_id <= 0 or room.userIndex(requester_id) == null) return writer.writeAll("null");
    try writer.writeAll("{\"playlist_item_attempts\":[");
    var written: usize = 0;
    for (room.playlist) |entry| if (entry) |item| {
        var attempts: usize = 0;
        var passed = false;
        for (room.scores.items) |score| if (score.user_id == requester_id and score.playlist_item_id == item.id) {
            attempts += 1;
            passed = passed or score.passed;
        };
        if (attempts == 0) continue;
        if (written != 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"attempts\":{d},\"passed\":{s}}}", .{ item.id, attempts, if (passed) "true" else "false" });
        written += 1;
    };
    try writer.writeAll("]}");
}

pub fn writeRoomJson(writer: *std.Io.Writer, room: *const Room, requester_id: i32, now_seconds: i64, persistence: RoomPersistence) !void {
    try writer.print("{{\"id\":{d},\"name\":", .{room.id});
    try std.json.Stringify.value(room.settings.name.slice(), .{}, writer);
    try writer.print(",\"description\":null,\"has_password\":{s},\"host\":", .{if (room.settings.password.len != 0) "true" else "false"});
    try writeApiUserJson(writer, room.host_id, room.host_name.slice(), room.host_country);
    try writer.writeAll(",\"category\":");
    try std.json.Stringify.value(if (room.settings.match_type == 0) "normal" else "realtime", .{}, writer);
    try writer.writeAll(",\"duration\":null,\"starts_at\":");
    if (room.starts_at > 0) try writeIsoTimestamp(writer, room.starts_at) else try writer.writeAll("null");
    try writer.writeAll(",\"ends_at\":");
    if (room.ends_at > 0) try writeIsoTimestamp(writer, room.ends_at) else try writer.writeAll("null");
    try writer.writeAll(",\"max_participants\":");
    if (room.settings.max_participants) |limit| try writer.print("{d}", .{limit}) else try writer.writeAll("null");
    try writer.print(",\"participant_count\":{d},\"recent_participants\":[", .{if (room.ended) room.participant_count else room.user_count});
    var users_written: usize = 0;
    if (room.ended) {
        for (room.participants[0..room.participant_count]) |entry| if (entry) |user| {
            if (users_written != 0) try writer.writeByte(',');
            try writeApiUserJson(writer, user.id, user.name.slice(), user.country);
            users_written += 1;
        };
    } else {
        for (room.users) |entry| if (entry) |user| {
            if (users_written != 0) try writer.writeByte(',');
            try writeApiUserJson(writer, user.id, user.name.slice(), user.country);
            users_written += 1;
        };
    }
    const match_type: []const u8 = switch (room.settings.match_type) {
        0 => "playlists",
        2 => "team_versus",
        3 => "matchmaking",
        4 => "ranked_play",
        else => "head_to_head",
    };
    const queue_mode: []const u8 = switch (room.settings.queue_mode) {
        1 => "all_players",
        2 => "all_players_round_robin",
        else => "host_only",
    };
    try writer.writeAll("],\"max_attempts\":");
    if (room.max_attempts) |limit| try writer.print("{d}", .{limit}) else try writer.writeAll("null");
    try writer.writeAll(",\"playlist\":[");
    var playlist_written: usize = 0;
    var active_playlist_items: usize = 0;
    var active_rulesets = [_]bool{false} ** 4;
    var all_rulesets = [_]bool{false} ** 4;
    for (room.playlist) |entry| if (entry) |item| {
        if (playlist_written != 0) try writer.writeByte(',');
        try writePlaylistItemJson(writer, item);
        playlist_written += 1;
        if (item.ruleset_id < all_rulesets.len) all_rulesets[item.ruleset_id] = true;
        if (!item.expired) {
            active_playlist_items += 1;
            if (item.ruleset_id < active_rulesets.len) active_rulesets[item.ruleset_id] = true;
        }
    };
    try writer.print("],\"playlist_item_stats\":{{\"count_active\":{d},\"count_total\":{d},\"ruleset_ids\":[", .{ active_playlist_items, room.playlist_count });
    const listed_rulesets = if (room.ended and room.settings.match_type == 0 and active_playlist_items == 0) all_rulesets else active_rulesets;
    var rulesets_written: usize = 0;
    for (listed_rulesets, 0..) |present, ruleset_id| {
        if (!present) continue;
        if (rulesets_written != 0) try writer.writeByte(',');
        try writer.print("{d}", .{ruleset_id});
        rulesets_written += 1;
    }
    try writer.writeAll("]},\"difficulty_range\":null,\"type\":");
    try std.json.Stringify.value(match_type, .{}, writer);
    try writer.writeAll(",\"queue_mode\":");
    try std.json.Stringify.value(queue_mode, .{}, writer);
    try writer.print(",\"auto_skip\":{s},\"auto_start_duration\":{d},\"current_user_score\":", .{ if (room.settings.auto_skip) "true" else "false", autoStartSeconds(room.settings) });
    try writeCurrentUserScore(writer, room, requester_id);
    try writer.writeAll(",\"current_playlist_item\":");
    const current = room.playlist[room.itemIndex(room.settings.playlist_item_id) orelse 0] orelse return error.MultiplayerPlaylistItemNotFound;
    try writePlaylistItemJson(writer, current);
    try writer.print(",\"channel_id\":{d},\"status\":\"{s}\",\"pinned\":false", .{ room.channel_id, if (roomHasEnded(room, now_seconds) or room.state == 0) "idle" else "playing" });
    if (persistence != .none) {
        try writer.writeAll(",\"zigcho_score_records\":[");
        var score_written: usize = 0;
        for (room.scores.items) |score| {
            if (score_written != 0) try writer.writeByte(',');
            try writer.print("{{\"score_id\":{d},\"user_id\":{d},\"playlist_item_id\":{d},\"total_score\":{d},\"accuracy\":{d},\"max_combo\":{d},\"passed\":{s}}}", .{ score.score_id, score.user_id, score.playlist_item_id, score.total_score, score.accuracy, score.max_combo, if (score.passed) "true" else "false" });
            score_written += 1;
        }
        try writer.writeAll("],\"zigcho_score_tokens\":[");
        for (room.score_tokens.items, 0..) |token, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"token_id\":{d},\"user_id\":{d},\"playlist_item_id\":{d},\"score_id\":", .{ token.token_id, token.user_id, token.playlist_item_id });
            if (token.score_id) |score_id| try writer.print("{d}", .{score_id}) else try writer.writeAll("null");
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    }
    if (persistence == .checkpoint) {
        try writer.writeAll(",\"zigcho_resumable\":true,\"zigcho_password\":");
        try std.json.Stringify.value(room.settings.password.slice(), .{}, writer);
        try writer.print(",\"zigcho_starts_at\":{d},\"zigcho_ends_at\":{d},\"zigcho_current_playlist_item_id\":{d},\"zigcho_active_users\":[", .{ room.starts_at, room.ends_at, room.settings.playlist_item_id });
        var active_written: usize = 0;
        for (room.users) |entry| if (entry) |user| {
            if (active_written != 0) try writer.writeByte(',');
            try writeApiUserJson(writer, user.id, user.name.slice(), user.country);
            active_written += 1;
        };
        try writer.writeAll("],\"zigcho_participants\":[");
        for (room.participants[0..room.participant_count], 0..) |entry, index| if (entry) |participant| {
            if (index != 0) try writer.writeByte(',');
            try writeApiUserJson(writer, participant.id, participant.name.slice(), participant.country);
        };
        try writer.writeByte(']');
    }
    try writeRoomModeJson(writer, room);
    try writer.writeByte('}');
}

pub fn writeRoomLeaderboardJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, room: *const Room, requester_id: i32) !void {
    const Aggregate = struct {
        user: RoomParticipant,
        attempts: i32 = 0,
        completed: i32 = 0,
        total_score: i64 = 0,
        accuracy_total: f64 = 0,
    };
    var aggregates: [max_room_participants]?Aggregate = [_]?Aggregate{null} ** max_room_participants;
    var aggregate_count: usize = 0;
    const playlist_room = room.settings.match_type == 0;
    var playlist_high_scores: ?[]?RoomScoreRecord = null;
    defer if (playlist_high_scores) |scores| allocator.free(scores);
    if (playlist_room) {
        playlist_high_scores = try allocator.alloc(?RoomScoreRecord, max_room_participants * max_playlist);
        @memset(playlist_high_scores.?, null);
    }
    for (room.scores.items) |score| {
        const participant_index = room.participantIndex(score.user_id) orelse continue;
        var aggregate_index: ?usize = null;
        for (aggregates[0..aggregate_count], 0..) |candidate, index| if (candidate.?.user.id == score.user_id) {
            aggregate_index = index;
            break;
        };
        if (aggregate_index == null) {
            if (aggregate_count == aggregates.len) continue;
            aggregate_index = aggregate_count;
            aggregates[aggregate_count] = .{ .user = room.participants[participant_index].? };
            aggregate_count += 1;
        }
        const aggregate = &aggregates[aggregate_index.?].?;
        aggregate.attempts += 1;
        if (playlist_room) {
            if (!scoreEligibleForHighScore(score, false)) continue;
            const item_index = room.itemIndex(score.playlist_item_id) orelse continue;
            const high_score = &playlist_high_scores.?[aggregate_index.? * max_playlist + item_index];
            if (high_score.* == null or scoreRanksBefore(score, high_score.*.?)) high_score.* = score;
        } else {
            aggregate.completed += @intFromBool(score.passed);
            aggregate.total_score += score.total_score;
            aggregate.accuracy_total += score.accuracy;
        }
    }
    if (playlist_room) {
        for (aggregates[0..aggregate_count], 0..) |*entry, aggregate_index| {
            const aggregate = &entry.*.?;
            for (playlist_high_scores.?[aggregate_index * max_playlist ..][0..max_playlist]) |high_score| if (high_score) |score| {
                aggregate.completed += 1;
                aggregate.total_score += score.total_score;
                aggregate.accuracy_total += score.accuracy;
            };
        }
        var ranked_count: usize = 0;
        for (aggregates[0..aggregate_count]) |entry| {
            if (entry.?.completed == 0) continue;
            aggregates[ranked_count] = entry;
            ranked_count += 1;
        }
        aggregate_count = ranked_count;
    }
    std.mem.sort(?Aggregate, aggregates[0..aggregate_count], {}, struct {
        fn lessThan(_: void, left: ?Aggregate, right: ?Aggregate) bool {
            if (left.?.total_score != right.?.total_score) return left.?.total_score > right.?.total_score;
            return left.?.user.id < right.?.user.id;
        }
    }.lessThan);
    try writer.writeAll("{\"leaderboard\":[");
    for (aggregates[0..aggregate_count], 0..) |entry, index| {
        const aggregate = entry.?;
        if (index != 0) try writer.writeByte(',');
        const accuracy_divisor = if (playlist_room) aggregate.completed else aggregate.attempts;
        try writer.print("{{\"attempts\":{d},\"completed\":{d},\"accuracy\":{d},\"pp\":null,\"room_id\":{d},\"total_score\":{d},\"user_id\":{d},\"user\":", .{ aggregate.attempts, aggregate.completed, aggregate.accuracy_total / @as(f64, @floatFromInt(accuracy_divisor)), room.id, aggregate.total_score, aggregate.user.id });
        try writeApiUserJson(writer, aggregate.user.id, aggregate.user.name.slice(), aggregate.user.country);
        try writer.print(",\"position\":{d}}}", .{index + 1});
    }
    try writer.writeAll("],\"user_score\":");
    var own_index: ?usize = null;
    for (aggregates[0..aggregate_count], 0..) |entry, index| if (entry.?.user.id == requester_id) {
        own_index = index;
        break;
    };
    if (own_index) |index| {
        const aggregate = aggregates[index].?;
        const accuracy_divisor = if (playlist_room) aggregate.completed else aggregate.attempts;
        try writer.print("{{\"attempts\":{d},\"completed\":{d},\"accuracy\":{d},\"pp\":null,\"room_id\":{d},\"total_score\":{d},\"user_id\":{d},\"user\":", .{ aggregate.attempts, aggregate.completed, aggregate.accuracy_total / @as(f64, @floatFromInt(accuracy_divisor)), room.id, aggregate.total_score, aggregate.user.id });
        try writeApiUserJson(writer, aggregate.user.id, aggregate.user.name.slice(), aggregate.user.country);
        try writer.print(",\"position\":{d}}}", .{index + 1});
    } else try writer.writeAll("null");
    try writer.writeByte('}');
}
