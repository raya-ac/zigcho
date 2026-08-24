const std = @import("std");
const domain = @import("domain.zig");
const storage = @import("runtime_storage.zig");

pub const FollowResult = union(enum) {
    not_found,
    ineligible,
    target: domain.User,
};

fn freeUser(allocator: std.mem.Allocator, user: domain.User) void {
    allocator.free(user.name);
    allocator.free(user.safe_name);
}

/// Applies the lazer follow mutation and reloads the target so the response
/// reflects the committed relationship instead of the pre-mutation profile.
pub fn follow(allocator: std.mem.Allocator, store: *storage.Store, user_id: i32, target_id: i32) !FollowResult {
    switch (try store.addFriend(user_id, target_id)) {
        .inserted, .existing => {},
        .ineligible => {
            const existing = (try store.userById(allocator, target_id)) orelse return .not_found;
            freeUser(allocator, existing);
            return .ineligible;
        },
    }
    return .{ .target = (try store.userById(allocator, target_id)) orelse return error.FollowTargetLost };
}

/// Returns Stable's raw replay frame bytes only for publicly visible owners.
/// A view is recorded only after the bytes have resolved successfully.
pub fn stableReplay(allocator: std.mem.Allocator, store: *storage.Store, viewer_id: i32, score_id: i64) !?[]u8 {
    const replay = (try store.stableReplay(allocator, score_id)) orelse return null;
    _ = store.recordReplayView(viewer_id, .stable, score_id) catch |err| {
        std.log.warn("event=replay_view_record_failed viewer_id={d} source=stable score_id={d} error={t}", .{ viewer_id, score_id, err });
    };
    return replay;
}
