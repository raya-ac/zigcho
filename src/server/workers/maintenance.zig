const d = @import("../deps.zig");
const std = d.std;
const changelog = d.changelog;
const App = @import("../app.zig").App;

pub fn multiplayerMaintenance(app: *App, io: std.Io) std.Io.Cancelable!void {
    var next_room_expiry_check_ms: i64 = 0;
    while (true) {
        try std.Io.sleep(io, .fromMilliseconds(200), .awake);
        const now_ms = std.Io.Clock.awake.now(io).toMilliseconds();
        _ = app.lazer_multiplayer.advanceExpiredMatchCountdowns(now_ms) catch |err| {
            std.log.warn("event=lazer_multiplayer_countdown_maintenance_failed error={t}", .{err});
        };
        _ = app.lazer_multiplayer.advanceExpiredRankedPicks(now_ms) catch |err| {
            std.log.warn("event=lazer_multiplayer_maintenance_failed error={t}", .{err});
            continue;
        };
        if (now_ms >= next_room_expiry_check_ms) {
            const now_seconds = std.Io.Clock.real.now(io).toSeconds();
            const expired_matches = app.lazer_multiplayer.expirePendingMatches(now_seconds);
            if (expired_matches != 0) std.log.info("event=lazer_matchmaking_invitations_expired count={d}", .{expired_matches});
            const expired = app.lazer_multiplayer.archiveExpiredRooms(now_seconds);
            if (expired != 0) std.log.info("event=lazer_multiplayer_rooms_expired count={d}", .{expired});
            next_room_expiry_check_ms = now_ms + std.time.ms_per_s;
        }
    }
}

pub fn changelogRefreshWorker(app: *App, io: std.Io) std.Io.Cancelable!void {
    while (true) {
        app.changelog_feed.refresh() catch |err| {
            std.log.warn("event=changelog_refresh_failed error={t} fallback=last_good", .{err});
        };
        try std.Io.sleep(io, .fromSeconds(changelog.refresh_seconds), .awake);
    }
}
