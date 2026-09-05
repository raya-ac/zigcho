const std = @import("std");
const storage = @import("../../runtime_storage.zig");
const ranked_pick_seconds = @import("../../lazer_multiplayer.zig").ranked_pick_seconds;
const ranked_stage = @import("../../lazer_multiplayer.zig").ranked_stage;
const RankedPlayState = @import("../../lazer_multiplayer.zig").RankedPlayState;
const RankedResultContext = @import("../../lazer_multiplayer.zig").RankedResultContext;
const RankedStageCountdown = @import("../../lazer_multiplayer.zig").RankedStageCountdown;
const Room = @import("../rooms/model.zig").Room;
const Manager = @import("../../lazer_multiplayer.zig").Manager;
const eventMatchStateOwned = @import("../transport/events.zig").eventMatchStateOwned;

pub fn startRankedPickCountdownLocked(self: *Manager, ranked: *RankedPlayState, now_ms: i64) RankedStageCountdown {
    const countdown: RankedStageCountdown = .{
        .id = self.next_countdown_id,
        .deadline_ms = now_ms + ranked_pick_seconds * std.time.ms_per_s,
        .stage = ranked_stage.card_play,
    };
    self.next_countdown_id = if (self.next_countdown_id == std.math.maxInt(i32)) 1 else self.next_countdown_id + 1;
    ranked.pick_countdown = countdown;
    return countdown;
}

pub fn rankedResultContext(room: *const Room) !?RankedResultContext {
    const ranked = room.ranked_play orelse return null;
    if (ranked.stage != ranked_stage.ended or ranked.result_persisted) return null;
    const winner_id = ranked.winning_user_id orelse return null;
    var loser_id: ?i32 = null;
    for (ranked.users) |entry| if (entry) |user| if (user.id != winner_id) {
        if (loser_id != null) return error.InvalidRankedPlayResult;
        loser_id = user.id;
    };
    const loser = loser_id orelse return error.InvalidRankedPlayResult;
    const ruleset_id = ruleset: {
        for (room.playlist) |entry| if (entry) |item| break :ruleset item.ruleset_id;
        return error.InvalidRankedPlayResult;
    };
    return .{ .room_id = room.id, .ruleset_id = ruleset_id, .winner_id = winner_id, .loser_id = loser };
}

pub fn applyRankedResult(room: *Room, context: RankedResultContext, result: storage.Store.LazerRankedResult) !void {
    const ranked = if (room.ranked_play) |*state| state else return error.InvalidRankedPlayResult;
    if (ranked.result_persisted) return;
    if (room.id != context.room_id or ranked.stage != ranked_stage.ended or ranked.winning_user_id != context.winner_id) return error.RankedPlayResultConflict;
    for (&ranked.users) |*entry| if (entry.*) |*user| {
        if (user.id == context.winner_id) {
            user.rating = result.winner_rating_before;
            user.rating_after = result.winner_rating_after;
        } else if (user.id == context.loser_id) {
            user.rating = result.loser_rating_before;
            user.rating_after = result.loser_rating_after;
        }
    };
    ranked.result_persisted = true;
}

/// Persist a result for a detached room. The caller owns the room pointer
/// (normally through the archive gate), so no manager mutex is needed.
pub fn persistRankedResult(self: *Manager, room: *Room) !void {
    const store = self.store orelse return;
    const context = (try rankedResultContext(room)) orelse return;
    const result = try store.applyLazerRankedResult(context.room_id, context.ruleset_id, context.winner_id, context.loser_id);
    try applyRankedResult(room, context, result);
    std.log.info("event=lazer_ranked_rating_persisted room_id={d} ruleset_id={d} winner_id={d} loser_id={d} applied={s}", .{ context.room_id, context.ruleset_id, context.winner_id, context.loser_id, if (result.applied) "true" else "false" });
}

/// Capture only immutable ids under the manager mutex, settle the database
/// without blocking unrelated rooms, then re-lock briefly to publish the
/// authoritative ratings if this room is still live. If it was detached in
/// the meantime, the archive path applies the same idempotent DB result.
pub fn persistLiveRankedResult(self: *Manager, room_id: i64) !void {
    const store = self.store orelse return;
    self.mutex.lockUncancelable(self.io);
    const room = self.roomByIdLocked(room_id) orelse {
        self.mutex.unlock(self.io);
        return;
    };
    const context = rankedResultContext(room) catch |err| {
        self.mutex.unlock(self.io);
        return err;
    } orelse {
        self.mutex.unlock(self.io);
        return;
    };
    self.mutex.unlock(self.io);

    const result = try store.applyLazerRankedResult(context.room_id, context.ruleset_id, context.winner_id, context.loser_id);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const current = self.roomByIdLocked(room_id) orelse return;
    try applyRankedResult(current, context, result);
    std.log.info("event=lazer_ranked_rating_persisted room_id={d} ruleset_id={d} winner_id={d} loser_id={d} applied={s}", .{ context.room_id, context.ruleset_id, context.winner_id, context.loser_id, if (result.applied) "true" else "false" });
}

pub fn rankedStateEventForRoom(self: *Manager, room_id: i64) !?[]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const room = self.roomByIdLocked(room_id) orelse return null;
    return try eventMatchStateOwned(self.allocator, room);
}
