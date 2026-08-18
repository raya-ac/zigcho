const std = @import("std");
const domain = @import("domain.zig");
const stable_score = @import("stable_score.zig");
const beatmap = @import("beatmap.zig");
const lazer = @import("lazer.zig");
const stable_mods = @import("stable_mods.zig");
const screenshot_contract = @import("screenshot.zig");
const media_contract = @import("media_contract.zig");
const site_replay = @import("site_replay.zig");
const user_json = @import("user_json.zig");
const achievements = @import("achievements.zig");
const r2 = @import("r2.zig");
const object_keys = @import("object_keys.zig");
pub const is_postgres = false;
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const ClientHardware = struct {
    osu_path_md5: []const u8,
    adapters_md5: []const u8,
    uninstall_md5: []const u8,
    disk_signature_md5: []const u8,
    client_version: []const u8,
    running_under_wine: bool,
    actionable: bool,
};

pub const HardwareEnforcement = struct {
    allocator: std.mem.Allocator,
    matched_user_ids: []i32,

    pub fn deinit(self: *HardwareEnforcement) void {
        self.allocator.free(self.matched_user_ids);
        self.* = undefined;
    }

    pub fn restricted(self: HardwareEnforcement) bool {
        return self.matched_user_ids.len != 0;
    }
};

pub const AnticheatSource = enum {
    stable_login,
    stable_lastfm,
    stable_score,

    pub fn text(self: AnticheatSource) []const u8 {
        return switch (self) {
            .stable_login => "stable_login",
            .stable_lastfm => "stable_lastfm",
            .stable_score => "stable_score",
        };
    }
};

pub const AnticheatReviewLabel = enum {
    clean,
    uncertain,
    cheat,
    dismissed,

    pub fn parse(value: []const u8) ?AnticheatReviewLabel {
        inline for (std.meta.fields(AnticheatReviewLabel)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn text(self: AnticheatReviewLabel) []const u8 {
        return @tagName(self);
    }
};

pub const AnticheatObservation = struct {
    source: AnticheatSource,
    module: []const u8,
    score_id: ?i64 = null,
    action: u32,
    sample_weight: u32 = 1,
    reason: u32,
    risk_score: u32,
    confidence_bps: u32,
    evidence: u64 = 0,
    decision_flags: u64 = 0,
    rule_revision: u32 = 0,
    objects_checked: u32 = 0,
    matched_clicks: u32 = 0,
    mean_abs_timing_error_milli: u32 = 0,
    timing_stddev_milli: u32 = 0,
    exact_timing_bps: u32 = 0,
    center_hits_bps: u32 = 0,
    mean_center_distance_milli: u32 = 0,
    snap_events: u32 = 0,
    replay_match_count: u32 = 0,
    key_press_count: u32 = 0,
    key_hold_count: u32 = 0,
    mean_hold_duration_milli: u32 = 0,
    hold_duration_stddev_milli: u32 = 0,
    alternation_bps: u32 = 0,
    target_distance_stddev_milli: u32 = 0,
    velocity_spike_count: u32 = 0,
    movement_velocity_stddev_milli: u32 = 0,
};

pub fn validateAnticheatObservation(user_id: i32, observation: AnticheatObservation) !void {
    if (user_id <= 0 or observation.module.len == 0 or observation.module.len > 64 or !std.unicode.utf8ValidateSlice(observation.module)) return error.InvalidAnticheatObservation;
    if (observation.score_id) |score_id| if (score_id <= 0) return error.InvalidAnticheatObservation;
    if ((observation.source == .stable_score) != (observation.score_id != null)) return error.InvalidAnticheatObservation;
    if (observation.action > 3 or observation.sample_weight == 0 or observation.sample_weight > 100_000 or observation.risk_score > 1000 or observation.confidence_bps > 10_000 or observation.replay_match_count > 100_000) return error.InvalidAnticheatObservation;
    if (observation.evidence > std.math.maxInt(i64) or observation.decision_flags > std.math.maxInt(i64)) return error.InvalidAnticheatObservation;
    if (observation.matched_clicks > observation.objects_checked or observation.snap_events > observation.objects_checked or observation.exact_timing_bps > 10_000 or observation.center_hits_bps > 10_000 or observation.key_hold_count > observation.key_press_count or observation.alternation_bps > 10_000) return error.InvalidAnticheatObservation;
}

pub const Store = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,
    io: std.Io,
    object_store: r2.Storage = .{ .endpoint = "", .bucket = "", .access_key_id = "", .secret_access_key = "" },
    mutex: std.Io.Mutex = .init,

    pub const CustomAvatar = struct {
        allocator: std.mem.Allocator,
        content_type: []u8,
        etag: [64]u8,
        object_key: []u8,
        updated_at: i64,

        pub fn deinit(self: *CustomAvatar) void {
            self.allocator.free(self.content_type);
            self.allocator.free(self.object_key);
            self.* = undefined;
        }
    };

    pub const LazerChatWrite = struct {
        json: []u8,
        inserted: bool,
    };

    const Credential = struct {
        allocator: std.mem.Allocator,
        user: ?domain.User,
        password_hash: []u8,
        password_salt: []u8,

        fn deinit(self: *Credential) void {
            if (self.user) |user| {
                self.allocator.free(user.name);
                self.allocator.free(user.safe_name);
            }
            self.allocator.free(self.password_hash);
            self.allocator.free(self.password_salt);
            self.* = undefined;
        }

        fn takeUser(self: *Credential) domain.User {
            const user = self.user.?;
            self.user = null;
            return user;
        }
    };

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !Store {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK) return error.DatabaseOpenFailed;
        return .{ .db = db.?, .allocator = allocator, .io = io };
    }
    pub fn bindObjectStorage(self: *Store, object_store: r2.Storage) void {
        self.object_store = object_store;
    }
    pub fn close(self: *Store) void {
        _ = c.sqlite3_close(self.db);
    }
    pub fn exec(self: *Store, sql: [:0]const u8) !void {
        var err: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, &err) != c.SQLITE_OK) {
            if (err != null) {
                std.log.err("sqlite exec failed: {s}", .{std.mem.span(err)});
                c.sqlite3_free(err);
            }
            return error.DatabaseQueryFailed;
        }
    }
    pub fn migrate(self: *Store) !void {
        try self.exec(@embedFile("schema.sql"));
        var version: i32 = 0;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA user_version", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) version = c.sqlite3_column_int(stmt, 0);
        _ = c.sqlite3_finalize(stmt);
        const needs_score_rebuild = version < 28;
        if (version < 2) try self.exec(@embedFile("migration_002.sql"));
        if (version < 3) try self.exec(@embedFile("migration_003.sql"));
        if (version < 4) try self.exec(@embedFile("migration_004.sql"));
        if (version < 5) try self.exec(@embedFile("migration_005.sql"));
        if (version < 6) try self.exec(@embedFile("migration_006.sql"));
        if (version < 7) try self.exec(@embedFile("migration_007.sql"));
        if (version < 8) try self.exec(@embedFile("migration_008.sql"));
        if (version < 9) try self.exec(@embedFile("migration_009.sql"));
        if (version < 10) {
            if (try self.hasAvatarColumn())
                try self.exec("PRAGMA user_version=10")
            else
                try self.exec(@embedFile("migration_010.sql"));
        }
        if (version < 11) try self.exec(@embedFile("migration_011.sql"));
        if (version < 12) try self.exec(@embedFile("migration_012.sql"));
        if (version < 13) try self.exec(@embedFile("migration_013.sql"));
        if (version < 14) {
            if (try self.hasBeatmapStatusFrozenColumn())
                try self.exec("PRAGMA user_version=14")
            else
                try self.exec(@embedFile("migration_014.sql"));
        }
        if (version < 15) try self.exec(@embedFile("migration_015.sql"));
        if (version < 16) try self.exec(@embedFile("migration_016.sql"));
        if (version < 17) {
            if (try self.hasBeatmapArchiveAccessColumn())
                try self.exec("PRAGMA user_version=17")
            else
                try self.exec(@embedFile("migration_017.sql"));
        }
        if (version < 18) try self.exec(@embedFile("migration_018.sql"));
        if (version < 19) try self.exec(@embedFile("migration_019.sql"));
        if (version < 20) try self.exec(@embedFile("migration_020.sql"));
        if (version < 21) {
            if (try self.hasLazerLeaderboardColumns())
                try self.exec("PRAGMA user_version=21")
            else
                try self.exec(@embedFile("migration_021.sql"));
        }
        if (version < 22) {
            if (try self.hasLazerPerformanceColumns())
                try self.exec("UPDATE lazer_scores SET best=1 WHERE id IN (SELECT id FROM (SELECT id,row_number() OVER (PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) place FROM lazer_scores WHERE passed=1) ranked WHERE place=1); PRAGMA user_version=22")
            else
                try self.exec(@embedFile("migration_022.sql"));
        }
        if (version < 23) {
            if (try self.hasSiteProfileSchema())
                try self.exec("PRAGMA user_version=23")
            else
                try self.exec(@embedFile("migration_023.sql"));
        }
        if (version < 24) {
            if (try self.hasExpandedSiteProfileSchema())
                try self.exec("PRAGMA user_version=24")
            else
                try self.exec(@embedFile("migration_024.sql"));
        }
        if (version < 25) {
            if (try self.hasAnticheatReviewSchema())
                try self.exec("PRAGMA user_version=25")
            else
                try self.exec(@embedFile("migration_025.sql"));
        }
        if (version < 26) {
            if (try self.hasAnticheatGameplaySchema())
                try self.exec("PRAGMA user_version=26")
            else
                try self.exec(@embedFile("migration_026.sql"));
        }
        if (version < 27) {
            if (try self.hasLazerChatSchema())
                try self.exec("PRAGMA user_version=27")
            else
                try self.exec(@embedFile("migration_027.sql"));
        }
        if (version < 28) {
            if (try self.hasLazerDirectMessageColumns())
                try self.exec("CREATE UNIQUE INDEX IF NOT EXISTS direct_messages_sender_uuid ON direct_messages(from_id,client_uuid) WHERE client_uuid!=''; UPDATE custom_mods SET ranked=1; CREATE TABLE IF NOT EXISTS user_achievements(user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,achievement_id INTEGER NOT NULL CHECK(achievement_id>0),score_source TEXT NOT NULL CHECK(score_source IN ('stable','lazer')),score_id INTEGER NOT NULL CHECK(score_id>0),achieved_at INTEGER NOT NULL DEFAULT (unixepoch()),PRIMARY KEY(user_id,achievement_id)); CREATE INDEX IF NOT EXISTS user_achievements_score ON user_achievements(score_source,score_id); PRAGMA user_version=28")
            else
                try self.exec(@embedFile("migration_028.sql"));
        }
        if (version < 29) {
            if (try self.hasScoreStarRatingColumns())
                try self.exec("UPDATE scores SET star_rating=coalesce(nullif(star_rating,0),(SELECT b.star_rating FROM beatmaps b WHERE b.md5=scores.map_md5),0); UPDATE lazer_scores SET star_rating=coalesce(nullif(star_rating,0),(SELECT b.star_rating FROM beatmaps b WHERE b.id=lazer_scores.beatmap_id),0); PRAGMA user_version=29")
            else
                try self.exec(@embedFile("migration_029.sql"));
        }
        try self.exec(
            "BEGIN IMMEDIATE;" ++
                "UPDATE lazer_scores SET best=0;" ++
                "WITH ordered AS (SELECT id,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) place FROM lazer_scores WHERE passed=1) " ++
                "UPDATE lazer_scores SET best=1 WHERE id IN(SELECT id FROM ordered WHERE place=1);" ++
                "COMMIT",
        );
        if (needs_score_rebuild) try self.rebuildScoreStats(true);
        try self.exec("INSERT OR IGNORE INTO chat_channels(name,topic,write_privileges) VALUES('#lazer','lazer chat',1)");
    }

    fn hasLazerPerformanceColumns(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(lazer_scores)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var have_pp = false;
        var have_best = false;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.eql(u8, name, "pp")) have_pp = true;
            if (std.mem.eql(u8, name, "best")) have_best = true;
        }
        return have_pp and have_best;
    }

    fn hasScoreStarRatingColumns(self: *Store) !bool {
        const tables = [_][]const u8{ "scores", "lazer_scores" };
        for (tables) |table| {
            var sql_buf: [64]u8 = undefined;
            const sql = try std.fmt.bufPrintZ(&sql_buf, "PRAGMA table_info({s})", .{table});
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stmt);
            var found = false;
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "star_rating")) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn hasLazerChatSchema(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(chat_messages)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var have_action = false;
        var have_uuid = false;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.eql(u8, name, "is_action")) have_action = true;
            if (std.mem.eql(u8, name, "client_uuid")) have_uuid = true;
        }
        if (!have_action or !have_uuid) return false;

        var table: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN('lazer_channel_reads','user_blocks')", -1, &table, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(table);
        return c.sqlite3_step(table) == c.SQLITE_ROW and c.sqlite3_column_int(table, 0) == 2;
    }

    fn hasLazerDirectMessageColumns(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(direct_messages)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var have_action = false;
        var have_uuid = false;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.eql(u8, name, "is_action")) have_action = true;
            if (std.mem.eql(u8, name, "client_uuid")) have_uuid = true;
        }
        return have_action and have_uuid;
    }

    fn hasSiteProfileSchema(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(users)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var have_bio = false;
        var have_preferred_mode = false;
        var have_profile_source = false;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.eql(u8, name, "bio")) have_bio = true;
            if (std.mem.eql(u8, name, "preferred_mode")) have_preferred_mode = true;
            if (std.mem.eql(u8, name, "profile_source")) have_profile_source = true;
        }
        if (!have_bio or !have_preferred_mode or !have_profile_source) return false;
        var table: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='user_avatars'", -1, &table, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(table);
        return c.sqlite3_step(table) == c.SQLITE_ROW;
    }

    fn hasExpandedSiteProfileSchema(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(users)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var found: u8 = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.eql(u8, name, "profile_title") or
                std.mem.eql(u8, name, "profile_pronouns") or
                std.mem.eql(u8, name, "profile_location") or
                std.mem.eql(u8, name, "profile_website") or
                std.mem.eql(u8, name, "profile_accent") or
                std.mem.eql(u8, name, "show_country") or
                std.mem.eql(u8, name, "show_profile_stats") or
                std.mem.eql(u8, name, "show_recent_scores")) found += 1;
        }
        return found == 8;
    }

    fn hasAnticheatReviewSchema(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(anticheat_observations)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var found: u8 = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.eql(u8, name, "source") or
                std.mem.eql(u8, name, "module") or
                std.mem.eql(u8, name, "sample_weight") or
                std.mem.eql(u8, name, "risk_score") or
                std.mem.eql(u8, name, "confidence_bps") or
                std.mem.eql(u8, name, "review_label") or
                std.mem.eql(u8, name, "reviewer_id") or
                std.mem.eql(u8, name, "review_note") or
                std.mem.eql(u8, name, "reviewed_at")) found += 1;
        }
        return found == 9;
    }

    fn hasAnticheatGameplaySchema(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(anticheat_observations)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var found: u8 = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.eql(u8, name, "replay_match_count") or
                std.mem.eql(u8, name, "key_press_count") or
                std.mem.eql(u8, name, "key_hold_count") or
                std.mem.eql(u8, name, "mean_hold_duration_milli") or
                std.mem.eql(u8, name, "hold_duration_stddev_milli") or
                std.mem.eql(u8, name, "alternation_bps") or
                std.mem.eql(u8, name, "target_distance_stddev_milli") or
                std.mem.eql(u8, name, "velocity_spike_count") or
                std.mem.eql(u8, name, "movement_velocity_stddev_milli")) found += 1;
        }
        if (found != 9) return false;
        var table: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='anticheat_replay_fingerprints'", -1, &table, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(table);
        return c.sqlite3_step(table) == c.SQLITE_ROW;
    }

    fn hasAvatarColumn(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(users)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "avatar_key")) return true;
        }
        return false;
    }

    fn hasBeatmapStatusFrozenColumn(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(beatmaps)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "status_frozen")) return true;
        }
        return false;
    }

    fn hasBeatmapArchiveAccessColumn(self: *Store) !bool {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(beatmap_archives)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "last_accessed_at")) return true;
        }
        return false;
    }

    fn hasLazerLeaderboardColumns(self: *Store) !bool {
        var found_rank = false;
        var found_maximum = false;
        var found_pauses = false;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(lazer_scores)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.eql(u8, name, "rank")) found_rank = true;
            if (std.mem.eql(u8, name, "maximum_statistics_json")) found_maximum = true;
            if (std.mem.eql(u8, name, "pauses_json")) found_pauses = true;
        }
        return found_rank and found_maximum and found_pauses;
    }

    fn rebuildScoreStats(self: *Store, own_transaction: bool) !void {
        if (own_transaction) try self.exec("BEGIN IMMEDIATE");
        errdefer if (own_transaction) self.exec("ROLLBACK") catch {};
        try self.exec(
            "UPDATE scores SET best=0;" ++
                "WITH ordered AS (" ++
                "SELECT id,row_number() OVER (PARTITION BY user_id,map_md5,mode,rank_namespace ORDER BY CASE WHEN rank_namespace IN('vanilla','scorev2') THEN CAST(score AS REAL) ELSE pp END DESC,id ASC) AS place " ++
                "FROM scores WHERE passed=1" ++
                ") UPDATE scores SET best=1 WHERE id IN (SELECT id FROM ordered WHERE place=1);",
        );
        try self.exec(
            "UPDATE lazer_scores SET best=0;" ++
                "WITH ordered AS (SELECT id,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) place FROM lazer_scores WHERE passed=1) " ++
                "UPDATE lazer_scores SET best=1 WHERE id IN(SELECT id FROM ordered WHERE place=1);",
        );
        const internal_mode = "CASE WHEN (s.mods & 8192)!=0 THEN s.mode+8 WHEN (s.mods & 128)!=0 THEN s.mode+4 ELSE s.mode END";
        const lazer_internal_mode = "CASE l.rank_namespace WHEN 'vanilla' THEN l.ruleset_id WHEN 'relax' THEN l.ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE -1 END";
        const lazer_hits = "coalesce(CAST(json_extract(l.statistics_json,'$.meh') AS INTEGER),0)+coalesce(CAST(json_extract(l.statistics_json,'$.ok') AS INTEGER),0)+coalesce(CAST(json_extract(l.statistics_json,'$.good') AS INTEGER),0)+coalesce(CAST(json_extract(l.statistics_json,'$.great') AS INTEGER),0)+coalesce(CAST(json_extract(l.statistics_json,'$.perfect') AS INTEGER),0)";
        const rebuild_sql = "UPDATE stats SET " ++
            "total_score=coalesce((SELECT sum(s.score) FROM scores s WHERE s.user_id=stats.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=stats.mode),0)+coalesce((SELECT sum(coalesce(l.legacy_total_score,l.total_score)) FROM lazer_scores l WHERE l.user_id=stats.user_id AND " ++ lazer_internal_mode ++ "=stats.mode),0)," ++
            "plays=coalesce((SELECT count(*) FROM scores s WHERE s.user_id=stats.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=stats.mode),0)+coalesce((SELECT count(*) FROM lazer_scores l WHERE l.user_id=stats.user_id AND " ++ lazer_internal_mode ++ "=stats.mode),0)," ++
            "play_time=coalesce((SELECT sum(s.time_elapsed/1000) FROM scores s WHERE s.user_id=stats.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=stats.mode),0)+coalesce((SELECT sum(max(b.total_length,0)) FROM lazer_scores l JOIN beatmaps b ON b.id=l.beatmap_id WHERE l.user_id=stats.user_id AND " ++ lazer_internal_mode ++ "=stats.mode),0)," ++
            "total_hits=coalesce((SELECT sum(s.n300+s.n100+s.n50+CASE WHEN s.mode IN (1,3) THEN s.ngeki+s.nkatu ELSE 0 END) FROM scores s WHERE s.user_id=stats.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=stats.mode),0)+coalesce((SELECT sum(" ++ lazer_hits ++ ") FROM lazer_scores l WHERE l.user_id=stats.user_id AND " ++ lazer_internal_mode ++ "=stats.mode),0)," ++
            "max_combo=max(coalesce((SELECT max(s.max_combo) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=stats.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=stats.mode AND s.passed=1 AND b.status>=3),0),coalesce((SELECT max(l.max_combo) FROM lazer_scores l JOIN beatmaps b ON b.id=l.beatmap_id WHERE l.user_id=stats.user_id AND " ++ lazer_internal_mode ++ "=stats.mode AND l.passed=1 AND b.status>=3),0))," ++
            "ranked_score=0," ++
            "pp=0,accuracy=0 WHERE user_id!=3 AND (EXISTS(SELECT 1 FROM scores s WHERE s.user_id=stats.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=stats.mode) OR EXISTS(SELECT 1 FROM lazer_scores l WHERE l.user_id=stats.user_id AND " ++ lazer_internal_mode ++ "=stats.mode))";
        try self.exec(rebuild_sql);

        const StatsKey = struct { user_id: i32, mode: u8 };
        var keys: std.ArrayList(StatsKey) = .empty;
        defer keys.deinit(self.allocator);
        var keys_stmt: ?*c.sqlite3_stmt = null;
        const keys_sql = "SELECT st.user_id,st.mode FROM stats st WHERE st.user_id!=3 AND (EXISTS(SELECT 1 FROM scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode) OR EXISTS(SELECT 1 FROM lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode)) ORDER BY st.user_id,st.mode";
        if (c.sqlite3_prepare_v2(self.db, keys_sql, -1, &keys_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        while (c.sqlite3_step(keys_stmt) == c.SQLITE_ROW) {
            try keys.append(self.allocator, .{ .user_id = c.sqlite3_column_int(keys_stmt, 0), .mode = @intCast(c.sqlite3_column_int(keys_stmt, 1)) });
        }
        _ = c.sqlite3_finalize(keys_stmt);

        for (keys.items) |key| {
            const namespace: []const u8 = switch (key.mode) {
                0...3 => "vanilla",
                4...6 => "relax",
                8 => "autopilot",
                else => continue,
            };
            const vanilla_mode: u8 = key.mode % 4;
            try self.rebuildCombinedPerformanceLocked(key.user_id, vanilla_mode, key.mode, namespace);
        }
        if (own_transaction) try self.exec("COMMIT");
    }

    pub fn register(self: *Store, name: []const u8, email: []const u8, password_md5: []const u8) !i32 {
        const safe = try domain.safeName(self.allocator, name);
        defer self.allocator.free(safe);
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{
            .allocator = self.allocator,
            .params = .owasp_2id,
        }, &hash_buffer, self.io);
        var random_byte: [1]u8 = undefined;
        try std.Io.randomSecure(self.io, &random_byte);
        const avatar_key: u8 = 1 + (random_byte[0] & 1);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "INSERT INTO users(name,safe_name,email,password_hash,password_salt,avatar_key) VALUES(?1,?2,?3,?4,?5,?6)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, safe.ptr, @intCast(safe.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, email.ptr, @intCast(email.len), null);
        _ = c.sqlite3_bind_blob(stmt, 4, hash.ptr, @intCast(hash.len), null);
        _ = c.sqlite3_bind_blob(stmt, 5, "argon2id".ptr, 8, null);
        _ = c.sqlite3_bind_int(stmt, 6, avatar_key);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.UserExists;
        const id: i32 = @intCast(c.sqlite3_last_insert_rowid(self.db));
        const stat_modes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 8 };
        for (stat_modes) |mode| {
            var buf: [128]u8 = undefined;
            const q = std.fmt.bufPrintZ(&buf, "INSERT INTO stats(user_id,mode) VALUES({d},{d})", .{ id, mode }) catch return error.DatabaseQueryFailed;
            try self.exec(q);
        }
        return id;
    }

    pub fn recordClientHardware(self: *Store, user_id: i32, hardware: ClientHardware) !HardwareEnforcement {
        var matched: std.ArrayList(i32) = .empty;
        errdefer matched.deinit(self.allocator);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

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
            if (try self.restrictUserLocked(user_id)) try self.insertRestrictionAuditLocked(user_id, matched.items[0], "multiaccount_hwid_exact");
            for (matched.items) |matched_user_id| {
                if (try self.restrictUserLocked(matched_user_id)) try self.insertRestrictionAuditLocked(matched_user_id, user_id, "multiaccount_hwid_exact");
            }
        }

        const owned_matches = try matched.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_matches);
        try self.exec("COMMIT");
        return .{ .allocator = self.allocator, .matched_user_ids = owned_matches };
    }

    pub fn restrictForClientFlag(self: *Store, user_id: i32, flags: u32) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const changed = try self.restrictUserLocked(user_id);
        if (changed) {
            var detail_buf: [64]u8 = undefined;
            const detail = try std.fmt.bufPrint(&detail_buf, "stable_lastfm_hq flags:{d}", .{flags});
            try self.insertAuditLocked(3, "account.restrict", user_id, detail);
        }
        try self.exec("COMMIT");
        return changed;
    }

    fn restrictUserLocked(self: *Store, user_id: i32) !bool {
        if (user_id == 3) return false;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET restricted=1 WHERE id=?1 AND id!=3 AND restricted=0", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) != 0;
    }

    fn insertRestrictionAuditLocked(self: *Store, target_user_id: i32, matched_user_id: i32, reason: []const u8) !void {
        var detail_buf: [128]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "{s} matched_user:{d}", .{ reason, matched_user_id });
        try self.insertAuditLocked(3, "account.restrict", target_user_id, detail);
    }

    fn insertAuditLocked(self: *Store, actor_id: i32, action: []const u8, target_user_id: i32, detail: []const u8) !void {
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

    pub fn recordAnticheatObservation(self: *Store, user_id: i32, observation: AnticheatObservation) !i64 {
        try validateAnticheatObservation(user_id, observation);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO anticheat_observations(user_id,score_id,source,module,action,sample_weight,reason,risk_score,confidence_bps,evidence,decision_flags,rule_revision,objects_checked,matched_clicks,mean_abs_timing_error_milli,timing_stddev_milli,exact_timing_bps,center_hits_bps,mean_center_distance_milli,snap_events,replay_match_count,key_press_count,key_hold_count,mean_hold_duration_milli,hold_duration_stddev_milli,alternation_bps,target_distance_stddev_milli,velocity_spike_count,movement_velocity_stddev_milli) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29)";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (observation.score_id) |score_id|
            _ = c.sqlite3_bind_int64(stmt, 2, score_id)
        else
            _ = c.sqlite3_bind_null(stmt, 2);
        const source = observation.source.text();
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
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const observation_id = c.sqlite3_last_insert_rowid(self.db);
        var detail_buf: [512]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "observation_id={d} module={s} source={s} score_id={d} mode=observe action={d} sample_weight={d} reason={d} risk={d} confidence_bps={d} evidence={d} replay_match_count={d} rule_revision={d}", .{
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
        if (c.sqlite3_prepare_v2(self.db, "SELECT count(DISTINCT user_id) FROM anticheat_replay_fingerprints WHERE replay_sha256=?1 AND user_id!=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
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

    pub const RegistrationConflicts = struct { username: bool, email: bool };

    pub fn registrationConflicts(self: *Store, name: []const u8, email: []const u8) !RegistrationConflicts {
        const safe = try domain.safeName(self.allocator, name);
        defer self.allocator.free(safe);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT EXISTS(SELECT 1 FROM users WHERE safe_name=?1), EXISTS(SELECT 1 FROM users WHERE email=?2)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, safe.ptr, @intCast(safe.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, email.ptr, @intCast(email.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return .{ .username = c.sqlite3_column_int(stmt, 0) != 0, .email = c.sqlite3_column_int(stmt, 1) != 0 };
    }

    pub fn avatarForUser(self: *Store, user_id: i32) !?u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT avatar_key FROM users WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const key = c.sqlite3_column_int(stmt, 0);
        if (key < 1 or key > 2) return error.InvalidAvatarKey;
        return @intCast(key);
    }

    pub fn customAvatarForUser(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT content_type,etag,object_key,updated_at FROM user_avatars WHERE user_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const content_type = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        errdefer allocator.free(content_type);
        const etag_value = std.mem.span(c.sqlite3_column_text(stmt, 1));
        if (etag_value.len != 64) return error.InvalidAvatarEtag;
        var etag: [64]u8 = undefined;
        @memcpy(&etag, etag_value);
        const object_key = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        return .{ .allocator = allocator, .content_type = content_type, .etag = etag, .object_key = object_key, .updated_at = c.sqlite3_column_int64(stmt, 3) };
    }

    pub fn setCustomAvatar(self: *Store, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO user_avatars(user_id,object_key,content_type,etag) VALUES(?1,?2,?3,?4) ON CONFLICT(user_id) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,updated_at=max(unixepoch(),user_avatars.updated_at+1)";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, object_key.ptr, @intCast(object_key.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, content_type.ptr, @intCast(content_type.len), null);
        _ = c.sqlite3_bind_text(stmt, 4, &etag, etag.len, null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn deleteCustomAvatar(self: *Store, user_id: i32) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM user_avatars WHERE user_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) != 0;
    }

    pub fn updateSiteProfile(self: *Store, user_id: i32, settings: domain.SiteProfileSettings) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET bio=?1,profile_title=?2,profile_pronouns=?3,profile_location=?4,profile_website=?5,profile_accent=?6,preferred_mode=?7,profile_source=?8,avatar_key=?9,show_country=?10,show_profile_stats=?11,show_recent_scores=?12 WHERE id=?13 AND id!=3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, settings.bio.ptr, @intCast(settings.bio.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, settings.title.ptr, @intCast(settings.title.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, settings.pronouns.ptr, @intCast(settings.pronouns.len), null);
        _ = c.sqlite3_bind_text(stmt, 4, settings.location.ptr, @intCast(settings.location.len), null);
        _ = c.sqlite3_bind_text(stmt, 5, settings.website.ptr, @intCast(settings.website.len), null);
        const accent = @tagName(settings.accent);
        _ = c.sqlite3_bind_text(stmt, 6, accent.ptr, @intCast(accent.len), null);
        _ = c.sqlite3_bind_int(stmt, 7, settings.preferred_mode);
        const source = @tagName(settings.profile_source);
        _ = c.sqlite3_bind_text(stmt, 8, source.ptr, @intCast(source.len), null);
        _ = c.sqlite3_bind_int(stmt, 9, settings.avatar_key);
        _ = c.sqlite3_bind_int(stmt, 10, @intFromBool(settings.show_country));
        _ = c.sqlite3_bind_int(stmt, 11, @intFromBool(settings.show_profile_stats));
        _ = c.sqlite3_bind_int(stmt, 12, @intFromBool(settings.show_recent_scores));
        _ = c.sqlite3_bind_int(stmt, 13, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.UserNotFound;
    }

    pub fn siteAccountJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT u.id,u.name,u.email,u.country,u.privileges,u.bio,u.preferred_mode,u.profile_source,u.avatar_key,EXISTS(SELECT 1 FROM user_avatars a WHERE a.user_id=u.id),coalesce((SELECT updated_at FROM user_avatars a WHERE a.user_id=u.id),0),u.created_at,coalesce(u.last_login,0),u.profile_title,u.profile_pronouns,u.profile_location,u.profile_website,u.profile_accent,u.show_country,u.show_profile_stats,u.show_recent_scores FROM users u WHERE u.id=?1 AND u.id!=3";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(stmt, 0)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        try output.writer.writeAll(",\"email\":");
        if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL) try output.writer.writeAll("null") else try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        try output.writer.print(",\"privileges\":{d},\"bio\":", .{c.sqlite3_column_int64(stmt, 4)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 5)));
        try output.writer.writeAll(",\"profile_source\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 7)));
        try output.writer.print(",\"preferred_mode\":{d},\"avatar_key\":{d},\"has_custom_avatar\":{},\"avatar_version\":{d},\"created_at\":{d},\"last_login\":{d},\"profile_title\":", .{ c.sqlite3_column_int(stmt, 6), c.sqlite3_column_int(stmt, 8), c.sqlite3_column_int(stmt, 9) != 0, c.sqlite3_column_int64(stmt, 10), c.sqlite3_column_int64(stmt, 11), c.sqlite3_column_int64(stmt, 12) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 13)));
        try output.writer.writeAll(",\"profile_pronouns\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 14)));
        try output.writer.writeAll(",\"profile_location\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 15)));
        try output.writer.writeAll(",\"profile_website\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 16)));
        try output.writer.writeAll(",\"profile_accent\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 17)));
        try output.writer.print(",\"show_country\":{},\"show_profile_stats\":{},\"show_recent_scores\":{}}}", .{ c.sqlite3_column_int(stmt, 18) != 0, c.sqlite3_column_int(stmt, 19) != 0, c.sqlite3_column_int(stmt, 20) != 0 });
        var list = output.toArrayList();
        return @as(?[]u8, try list.toOwnedSlice(allocator));
    }

    pub fn authenticate(self: *Store, allocator: std.mem.Allocator, name: []const u8, password_md5: []const u8) !?domain.User {
        const safe = try domain.safeName(allocator, name);
        defer allocator.free(safe);
        var credential = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk (try self.credentialForSafeName(allocator, safe)) orelse return null;
        };
        defer credential.deinit();
        var upgrade_password = false;
        if (credential.password_hash.len > 0 and credential.password_hash[0] == '$') {
            std.crypto.pwhash.argon2.strVerify(credential.password_hash, password_md5, .{ .allocator = allocator }, self.io) catch return null;
        } else {
            var actual: [32]u8 = undefined;
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(credential.password_salt);
            h.update(password_md5);
            h.final(&actual);
            if (credential.password_hash.len != 32 or !std.crypto.timing_safe.eql([32]u8, actual, credential.password_hash[0..32].*)) return null;
            upgrade_password = true;
        }
        const user_id = credential.user.?.id;
        if (upgrade_password) try self.upgradePassword(user_id, password_md5, credential.password_hash);
        return credential.takeUser();
    }

    fn credentialForSafeName(self: *Store, allocator: std.mem.Allocator, safe: []const u8) !?Credential {
        const sql = "SELECT id,name,safe_name,country,privileges,silence_end,restricted,password_hash,password_salt FROM users WHERE safe_name=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, safe.ptr, @intCast(safe.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const uname = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer allocator.free(uname);
        const usafe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        errdefer allocator.free(usafe);
        const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
        if (cc.len != 2) return error.InvalidCountry;
        const expected: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 7));
        const expected_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 7));
        const expected_copy = try allocator.dupe(u8, expected[0..expected_len]);
        errdefer allocator.free(expected_copy);
        const salt: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 8));
        const salt_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 8));
        const salt_copy = try allocator.dupe(u8, salt[0..salt_len]);
        return .{
            .allocator = allocator,
            .user = .{ .id = c.sqlite3_column_int(stmt, 0), .name = uname, .safe_name = usafe, .country = .{ cc[0], cc[1] }, .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)), .silence_end = c.sqlite3_column_int64(stmt, 5), .restricted = c.sqlite3_column_int(stmt, 6) != 0 },
            .password_hash = expected_copy,
            .password_salt = salt_copy,
        };
    }

    pub fn userById(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?domain.User {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT id,name,safe_name,country,privileges,silence_end,restricted FROM users WHERE id=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer allocator.free(name);
        const safe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
        return .{
            .id = c.sqlite3_column_int(stmt, 0),
            .name = name,
            .safe_name = safe,
            .country = .{ cc[0], cc[1] },
            .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)),
            .silence_end = c.sqlite3_column_int64(stmt, 5),
            .restricted = c.sqlite3_column_int(stmt, 6) != 0,
        };
    }

    pub fn userByName(self: *Store, allocator: std.mem.Allocator, name: []const u8) !?domain.User {
        const safe = try domain.safeName(allocator, name);
        defer allocator.free(safe);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT id,name,safe_name,country,privileges,silence_end,restricted FROM users WHERE safe_name=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, safe.ptr, @intCast(safe.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const user_name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer allocator.free(user_name);
        const safe_name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
        if (cc.len != 2) return error.InvalidCountry;
        return .{
            .id = c.sqlite3_column_int(stmt, 0),
            .name = user_name,
            .safe_name = safe_name,
            .country = .{ cc[0], cc[1] },
            .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)),
            .silence_end = c.sqlite3_column_int64(stmt, 5),
            .restricted = c.sqlite3_column_int(stmt, 6) != 0,
        };
    }

    pub fn friendIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT friend_id FROM friends WHERE user_id=?1 ORDER BY friend_id LIMIT 1000", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        var list: std.ArrayList(i32) = .empty;
        errdefer list.deinit(allocator);
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try list.append(allocator, c.sqlite3_column_int(stmt, 0)),
            c.SQLITE_DONE => break,
            else => return error.DatabaseQueryFailed,
        };
        if (user_id != 3 and std.mem.indexOfScalar(i32, list.items, 3) == null) try list.append(allocator, 3);
        return try list.toOwnedSlice(allocator);
    }

    pub fn addFriend(self: *Store, user_id: i32, friend_id: i32) !bool {
        if (user_id == friend_id or friend_id == 3) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO friends(user_id,friend_id) VALUES(?1,?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, friend_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) != 0;
    }

    pub fn removeFriend(self: *Store, user_id: i32, friend_id: i32) !bool {
        if (friend_id == 3) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM friends WHERE user_id=?1 AND friend_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, friend_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) != 0;
    }

    pub fn friendsAreMutual(self: *Store, user_id: i32, friend_id: i32) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT EXISTS(SELECT 1 FROM friends WHERE user_id=?1 AND friend_id=?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, friend_id);
        _ = c.sqlite3_bind_int(stmt, 2, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return c.sqlite3_column_int(stmt, 0) != 0;
    }

    pub fn blockIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT blocked_id FROM user_blocks WHERE user_id=?1 ORDER BY blocked_id LIMIT 1000", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        var list: std.ArrayList(i32) = .empty;
        errdefer list.deinit(allocator);
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try list.append(allocator, c.sqlite3_column_int(stmt, 0)),
            c.SQLITE_DONE => break,
            else => return error.DatabaseQueryFailed,
        };
        return list.toOwnedSlice(allocator);
    }

    pub fn addBlock(self: *Store, user_id: i32, blocked_id: i32) !bool {
        if (user_id == blocked_id or blocked_id == 3) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO user_blocks(user_id,blocked_id) VALUES(?1,?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, blocked_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) != 0;
    }

    pub fn removeBlock(self: *Store, user_id: i32, blocked_id: i32) !bool {
        if (blocked_id == 3) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM user_blocks WHERE user_id=?1 AND blocked_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, blocked_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) != 0;
    }

    pub fn favouriteSetIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT set_id FROM favourites WHERE user_id=?1 ORDER BY created_at,set_id LIMIT 10000", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        var list: std.ArrayList(i32) = .empty;
        errdefer list.deinit(allocator);
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try list.append(allocator, c.sqlite3_column_int(stmt, 0)),
            c.SQLITE_DONE => break,
            else => return error.DatabaseQueryFailed,
        };
        return list.toOwnedSlice(allocator);
    }

    pub fn addFavourite(self: *Store, user_id: i32, set_id: i32) !bool {
        if (set_id <= 0) return error.InvalidBeatmapSet;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO favourites(user_id,set_id) VALUES(?1,?2)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) != 0;
    }

    pub fn removeFavourite(self: *Store, user_id: i32, set_id: i32) !bool {
        if (set_id <= 0) return error.InvalidBeatmapSet;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM favourites WHERE user_id=?1 AND set_id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) != 0;
    }

    pub const StableBeatmapInfo = struct {
        id: i32,
        set_id: i32,
        md5: [32]u8,
        status: i32,
        grades: [4][]const u8,
    };

    pub fn stableGrade(mode: u8, mods: i32, accuracy: f64, n300: i32, n100: i32, n50: i32, nmiss: i32) []const u8 {
        const hidden = mods & ((1 << 3) | (1 << 10)) != 0;
        const base: []const u8 = switch (mode) {
            0 => standard: {
                const total = n300 + n100 + n50 + nmiss;
                if (total <= 0) break :standard "N";
                const ratio_300 = @as(f64, @floatFromInt(n300)) / @as(f64, @floatFromInt(total));
                const ratio_50 = @as(f64, @floatFromInt(n50)) / @as(f64, @floatFromInt(total));
                if (n100 == 0 and n50 == 0 and nmiss == 0) break :standard "X";
                if (ratio_300 > 0.9 and ratio_50 <= 0.01 and nmiss == 0) break :standard "S";
                if ((ratio_300 > 0.8 and nmiss == 0) or ratio_300 > 0.9) break :standard "A";
                if ((ratio_300 > 0.7 and nmiss == 0) or ratio_300 > 0.8) break :standard "B";
                if (ratio_300 > 0.6) break :standard "C";
                break :standard "D";
            },
            1 => taiko: {
                const total = n300 + n100 + nmiss;
                if (total <= 0) break :taiko "N";
                const ratio_300 = @as(f64, @floatFromInt(n300)) / @as(f64, @floatFromInt(total));
                if (n100 == 0 and nmiss == 0) break :taiko "X";
                if (ratio_300 > 0.9 and nmiss == 0) break :taiko "S";
                if ((ratio_300 > 0.8 and nmiss == 0) or ratio_300 > 0.9) break :taiko "A";
                if ((ratio_300 > 0.7 and nmiss == 0) or ratio_300 > 0.8) break :taiko "B";
                if (ratio_300 > 0.6) break :taiko "C";
                break :taiko "D";
            },
            2 => if (accuracy >= 1.0) "X" else if (accuracy > 0.98) "S" else if (accuracy > 0.94) "A" else if (accuracy > 0.90) "B" else if (accuracy > 0.85) "C" else "D",
            3 => if (accuracy >= 1.0) "X" else if (accuracy > 0.95) "S" else if (accuracy > 0.9) "A" else if (accuracy > 0.8) "B" else if (accuracy > 0.7) "C" else "D",
            else => "N",
        };
        if (!hidden) return base;
        if (std.mem.eql(u8, base, "X")) return "XH";
        if (std.mem.eql(u8, base, "S")) return "SH";
        return base;
    }

    fn stableBeatmapInfoLocked(self: *Store, user_id: i32, field: []const u8, by_id: bool) !?StableBeatmapInfo {
        const sql = if (by_id)
            "SELECT id,set_id,md5,status FROM beatmaps WHERE id=CAST(?1 AS INTEGER)"
        else
            "SELECT id,set_id,md5,status FROM beatmaps WHERE artist || ' - ' || title || ' (' || creator || ') [' || version || '].osu'=?1";
        var map_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_stmt);
        _ = c.sqlite3_bind_text(map_stmt, 1, field.ptr, @intCast(field.len), null);
        if (c.sqlite3_step(map_stmt) != c.SQLITE_ROW) return null;
        const md5_text = std.mem.span(c.sqlite3_column_text(map_stmt, 2));
        if (md5_text.len != 32) return error.InvalidBeatmapChecksum;
        var info: StableBeatmapInfo = .{
            .id = c.sqlite3_column_int(map_stmt, 0),
            .set_id = c.sqlite3_column_int(map_stmt, 1),
            .md5 = undefined,
            .status = switch (stableStatus(c.sqlite3_column_int(map_stmt, 3))) {
                0 => 0,
                2 => 1,
                3 => 2,
                4 => 3,
                5 => 4,
                else => 0,
            },
            .grades = .{ "N", "N", "N", "N" },
        };
        @memcpy(&info.md5, md5_text);
        var score_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT mode,mods,accuracy,n300,n100,n50,nmiss FROM scores WHERE user_id=?1 AND map_md5=?2 AND rank_namespace='vanilla' AND passed=1 AND best=1 AND mode BETWEEN 0 AND 3", -1, &score_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(score_stmt);
        _ = c.sqlite3_bind_int(score_stmt, 1, user_id);
        _ = c.sqlite3_bind_text(score_stmt, 2, info.md5[0..].ptr, info.md5.len, null);
        while (c.sqlite3_step(score_stmt) == c.SQLITE_ROW) {
            const mode: u8 = @intCast(c.sqlite3_column_int(score_stmt, 0));
            info.grades[mode] = stableGrade(mode, c.sqlite3_column_int(score_stmt, 1), c.sqlite3_column_double(score_stmt, 2), c.sqlite3_column_int(score_stmt, 3), c.sqlite3_column_int(score_stmt, 4), c.sqlite3_column_int(score_stmt, 5), c.sqlite3_column_int(score_stmt, 6));
        }
        return info;
    }

    pub fn stableBeatmapInfoByFilename(self: *Store, user_id: i32, filename: []const u8) !?StableBeatmapInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stableBeatmapInfoLocked(user_id, filename, false);
    }

    pub fn stableBeatmapInfoById(self: *Store, user_id: i32, map_id: i32) !?StableBeatmapInfo {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stableBeatmapInfoLocked(user_id, id, true);
    }

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

    pub const DirectMessage = struct {
        id: i64,
        from_id: i32,
        from_name: []u8,
        message: []u8,

        pub fn deinit(self: *DirectMessage, allocator: std.mem.Allocator) void {
            allocator.free(self.from_name);
            allocator.free(self.message);
            self.* = undefined;
        }
    };

    pub fn storeDirectMessage(self: *Store, from_id: i32, to_id: i32, message: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var target_buffer: [64]u8 = undefined;
        const target = try lazer.directMessageTarget(&target_buffer, from_id, to_id);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO direct_messages(from_id,to_id,message) VALUES(?1,?2,?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(stmt, 1, from_id);
        _ = c.sqlite3_bind_int(stmt, 2, to_id);
        _ = c.sqlite3_bind_text(stmt, 3, message.ptr, @intCast(message.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(stmt);
        stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO chat_messages(sender_id,target,message) VALUES(?1,?2,?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, from_id);
        _ = c.sqlite3_bind_text(stmt, 2, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, message.ptr, @intCast(message.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        try self.exec("COMMIT");
    }

    pub fn unreadDirectMessages(self: *Store, allocator: std.mem.Allocator, to_id: i32) ![]DirectMessage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT d.id,d.from_id,u.name,d.message FROM direct_messages d JOIN users u ON u.id=d.from_id WHERE d.to_id=?1 AND d.read=0 ORDER BY d.created_at,d.id LIMIT 1000", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, to_id);
        var messages: std.ArrayList(DirectMessage) = .empty;
        errdefer {
            for (messages.items) |*message| message.deinit(allocator);
            messages.deinit(allocator);
        }
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const from_name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
            errdefer allocator.free(from_name);
            const message = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)));
            errdefer allocator.free(message);
            try messages.append(allocator, .{ .id = c.sqlite3_column_int64(stmt, 0), .from_id = c.sqlite3_column_int(stmt, 1), .from_name = from_name, .message = message });
        }
        return messages.toOwnedSlice(allocator);
    }

    pub fn markDirectMessagesRead(self: *Store, to_id: i32, from_id: i32) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE direct_messages SET read=1 WHERE to_id=?1 AND from_id=?2 AND read=0", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, to_id);
        _ = c.sqlite3_bind_int(stmt, 2, from_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn recordPublicMessage(self: *Store, sender_id: i32, target: []const u8, message: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO chat_messages(sender_id,target,message) VALUES(?1,?2,?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, sender_id);
        _ = c.sqlite3_bind_text(stmt, 2, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, message.ptr, @intCast(message.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn recordLazerPublicMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, target: []const u8, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
        const channel_id = lazer.channelId(target) orelse return error.UnknownChannel;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var access: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT u.privileges,c.write_privileges,c.locked FROM users u JOIN chat_channels c ON c.name=?2 WHERE u.id=?1", -1, &access, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(access);
        _ = c.sqlite3_bind_int(access, 1, sender_id);
        _ = c.sqlite3_bind_text(access, 2, target.ptr, @intCast(target.len), null);
        if (c.sqlite3_step(access) != c.SQLITE_ROW) return error.UnknownChannel;
        const privileges: u32 = @intCast(c.sqlite3_column_int64(access, 0));
        const required: u32 = @intCast(c.sqlite3_column_int64(access, 1));
        if (c.sqlite3_column_int(access, 2) != 0 or privileges & required == 0) return error.ChannelReadOnly;

        var insert: ?*c.sqlite3_stmt = null;
        const insert_sql = "INSERT OR IGNORE INTO chat_messages(sender_id,target,message,is_action,client_uuid) VALUES(?1,?2,?3,?4,?5)";
        if (c.sqlite3_prepare_v2(self.db, insert_sql, -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(insert);
        _ = c.sqlite3_bind_int(insert, 1, sender_id);
        _ = c.sqlite3_bind_text(insert, 2, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(insert, 3, message.ptr, @intCast(message.len), null);
        _ = c.sqlite3_bind_int(insert, 4, @intFromBool(is_action));
        _ = c.sqlite3_bind_text(insert, 5, uuid.ptr, @intCast(uuid.len), null);
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const inserted = c.sqlite3_changes(self.db) != 0;

        var row: ?*c.sqlite3_stmt = null;
        const row_sql = "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.sender_id=?1 AND m.client_uuid=?2";
        if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(row);
        _ = c.sqlite3_bind_int(row, 1, sender_id);
        _ = c.sqlite3_bind_text(row, 2, uuid.ptr, @intCast(uuid.len), null);
        if (c.sqlite3_step(row) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        if (!std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 1)), target) or
            !std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 2)), message) or
            (c.sqlite3_column_int(row, 3) != 0) != is_action) return error.ChatUuidConflict;

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try lazer.writeChatMessage(&output.writer, .{
            .id = c.sqlite3_column_int64(row, 0),
            .channel_id = channel_id,
            .sender_id = sender_id,
            .sender_name = std.mem.span(c.sqlite3_column_text(row, 6)),
            .sender_country = std.mem.span(c.sqlite3_column_text(row, 7)),
            .sender_privileges = @intCast(c.sqlite3_column_int64(row, 8)),
            .content = message,
            .is_action = is_action,
            .uuid = uuid,
            .timestamp = std.mem.span(c.sqlite3_column_text(row, 5)),
        });
        return .{ .json = try output.toOwnedSlice(), .inserted = inserted };
    }

    pub fn recordLazerDirectMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, target_id: i32, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
        const channel_id = lazer.privateChannelId(target_id) orelse return error.InvalidDirectMessage;
        var target_buffer: [64]u8 = undefined;
        const target = try lazer.directMessageTarget(&target_buffer, sender_id, target_id);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        var insert: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO chat_messages(sender_id,target,message,is_action,client_uuid) VALUES(?1,?2,?3,?4,?5)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(insert, 1, sender_id);
        _ = c.sqlite3_bind_text(insert, 2, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(insert, 3, message.ptr, @intCast(message.len), null);
        _ = c.sqlite3_bind_int(insert, 4, @intFromBool(is_action));
        _ = c.sqlite3_bind_text(insert, 5, uuid.ptr, @intCast(uuid.len), null);
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const inserted = c.sqlite3_changes(self.db) != 0;
        _ = c.sqlite3_finalize(insert);

        var row: ?*c.sqlite3_stmt = null;
        const row_sql = "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.sender_id=?1 AND m.client_uuid=?2";
        if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(row);
        _ = c.sqlite3_bind_int(row, 1, sender_id);
        _ = c.sqlite3_bind_text(row, 2, uuid.ptr, @intCast(uuid.len), null);
        if (c.sqlite3_step(row) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        if (!std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 1)), target) or
            !std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(row, 2)), message) or
            (c.sqlite3_column_int(row, 3) != 0) != is_action) return error.ChatUuidConflict;

        if (inserted) {
            var direct: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "INSERT INTO direct_messages(from_id,to_id,message,is_action,client_uuid) VALUES(?1,?2,?3,?4,?5)", -1, &direct, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(direct);
            _ = c.sqlite3_bind_int(direct, 1, sender_id);
            _ = c.sqlite3_bind_int(direct, 2, target_id);
            _ = c.sqlite3_bind_text(direct, 3, message.ptr, @intCast(message.len), null);
            _ = c.sqlite3_bind_int(direct, 4, @intFromBool(is_action));
            _ = c.sqlite3_bind_text(direct, 5, uuid.ptr, @intCast(uuid.len), null);
            if (c.sqlite3_step(direct) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try lazer.writeChatMessage(&output.writer, .{
            .id = c.sqlite3_column_int64(row, 0),
            .channel_id = channel_id,
            .sender_id = sender_id,
            .sender_name = std.mem.span(c.sqlite3_column_text(row, 6)),
            .sender_country = std.mem.span(c.sqlite3_column_text(row, 7)),
            .sender_privileges = @intCast(c.sqlite3_column_int64(row, 8)),
            .content = message,
            .is_action = is_action,
            .uuid = uuid,
            .timestamp = std.mem.span(c.sqlite3_column_text(row, 5)),
        });
        try self.exec("COMMIT");
        return .{ .json = try output.toOwnedSlice(), .inserted = inserted };
    }

    pub fn lazerDirectMessagesJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, other_id: i32, since: i64, limit: u16) ![]u8 {
        if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
        const channel_id = lazer.privateChannelId(other_id) orelse return error.InvalidDirectMessage;
        var target_buffer: [64]u8 = undefined;
        const target = try lazer.directMessageTarget(&target_buffer, viewer_id, other_id);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = if (since == 0)
            "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT * FROM chat_messages WHERE target=?1 ORDER BY id DESC LIMIT ?2) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
        else
            "SELECT m.id,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.target=?1 AND m.id>?2 AND u.restricted=0 ORDER BY m.id LIMIT ?3";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_int64(stmt, 2, if (since == 0) limit else since);
        if (since != 0) _ = c.sqlite3_bind_int(stmt, 3, limit);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try lazer.writeChatMessage(&output.writer, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .channel_id = channel_id,
                .sender_id = c.sqlite3_column_int(stmt, 1),
                .sender_name = std.mem.span(c.sqlite3_column_text(stmt, 2)),
                .sender_country = std.mem.span(c.sqlite3_column_text(stmt, 3)),
                .sender_privileges = @intCast(c.sqlite3_column_int64(stmt, 8)),
                .content = std.mem.span(c.sqlite3_column_text(stmt, 4)),
                .is_action = c.sqlite3_column_int(stmt, 5) != 0,
                .uuid = std.mem.span(c.sqlite3_column_text(stmt, 6)),
                .timestamp = std.mem.span(c.sqlite3_column_text(stmt, 7)),
            });
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerAllMessagesJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, since: i64, limit: u16) ![]u8 {
        if (viewer_id <= 0 or since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
        var low_pattern_buffer: [64]u8 = undefined;
        var high_pattern_buffer: [64]u8 = undefined;
        const low_pattern = try std.fmt.bufPrint(&low_pattern_buffer, "@dm:{d}:%", .{viewer_id});
        const high_pattern = try std.fmt.bufPrint(&high_pattern_buffer, "@dm:%:{d}", .{viewer_id});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const filter = "target IN('#osu','#announce','#lobby','#lazer') OR target LIKE ?1 OR target LIKE ?2";
        const sql = if (since == 0)
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT * FROM chat_messages WHERE " ++ filter ++ " ORDER BY id DESC LIMIT ?3) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
        else
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE (" ++ filter ++ ") AND m.id>?3 AND u.restricted=0 ORDER BY m.id LIMIT ?4";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, low_pattern.ptr, @intCast(low_pattern.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, high_pattern.ptr, @intCast(high_pattern.len), null);
        _ = c.sqlite3_bind_int64(stmt, 3, if (since == 0) limit else since);
        if (since != 0) _ = c.sqlite3_bind_int(stmt, 4, limit);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const message_target = std.mem.span(c.sqlite3_column_text(stmt, 1));
            const message_channel_id = lazer.channelId(message_target) orelse private: {
                const other_id = lazer.directMessageOther(message_target, viewer_id) orelse continue;
                break :private lazer.privateChannelId(other_id).?;
            };
            if (!first) try output.writer.writeByte(',');
            first = false;
            try lazer.writeChatMessage(&output.writer, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .channel_id = message_channel_id,
                .sender_id = c.sqlite3_column_int(stmt, 2),
                .sender_name = std.mem.span(c.sqlite3_column_text(stmt, 3)),
                .sender_country = std.mem.span(c.sqlite3_column_text(stmt, 4)),
                .sender_privileges = @intCast(c.sqlite3_column_int64(stmt, 9)),
                .content = std.mem.span(c.sqlite3_column_text(stmt, 5)),
                .is_action = c.sqlite3_column_int(stmt, 6) != 0,
                .uuid = std.mem.span(c.sqlite3_column_text(stmt, 7)),
                .timestamp = std.mem.span(c.sqlite3_column_text(stmt, 8)),
            });
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerChatMessagesJson(self: *Store, allocator: std.mem.Allocator, channel_id: ?i64, since: i64, limit: u16) ![]u8 {
        if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
        const target = if (channel_id) |id| lazer.channelName(id) orelse return error.UnknownChannel else null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const sql = if (target != null and since == 0)
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT * FROM chat_messages WHERE target=?1 ORDER BY id DESC LIMIT ?2) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
        else if (target != null)
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.target=?1 AND m.id>?2 AND u.restricted=0 ORDER BY m.id LIMIT ?3"
        else if (since == 0)
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM (SELECT * FROM chat_messages WHERE target IN('#osu','#announce','#lobby','#lazer') ORDER BY id DESC LIMIT ?1) m JOIN users u ON u.id=m.sender_id WHERE u.restricted=0 ORDER BY m.id"
        else
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,strftime('%Y-%m-%dT%H:%M:%SZ',m.created_at,'unixepoch'),u.privileges FROM chat_messages m JOIN users u ON u.id=m.sender_id WHERE m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>?1 AND u.restricted=0 ORDER BY m.id LIMIT ?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (target) |name| {
            _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
            if (since == 0) {
                _ = c.sqlite3_bind_int(stmt, 2, limit);
            } else {
                _ = c.sqlite3_bind_int64(stmt, 2, since);
                _ = c.sqlite3_bind_int(stmt, 3, limit);
            }
        } else if (since == 0) {
            _ = c.sqlite3_bind_int(stmt, 1, limit);
        } else {
            _ = c.sqlite3_bind_int64(stmt, 1, since);
            _ = c.sqlite3_bind_int(stmt, 2, limit);
        }

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const message_channel_id = lazer.channelId(std.mem.span(c.sqlite3_column_text(stmt, 1))) orelse continue;
            if (!first) try output.writer.writeByte(',');
            first = false;
            try lazer.writeChatMessage(&output.writer, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .channel_id = message_channel_id,
                .sender_id = c.sqlite3_column_int(stmt, 2),
                .sender_name = std.mem.span(c.sqlite3_column_text(stmt, 3)),
                .sender_country = std.mem.span(c.sqlite3_column_text(stmt, 4)),
                .sender_privileges = @intCast(c.sqlite3_column_int64(stmt, 9)),
                .content = std.mem.span(c.sqlite3_column_text(stmt, 5)),
                .is_action = c.sqlite3_column_int(stmt, 6) != 0,
                .uuid = std.mem.span(c.sqlite3_column_text(stmt, 7)),
                .timestamp = std.mem.span(c.sqlite3_column_text(stmt, 8)),
            });
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerChannelListJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
        if (user_id <= 0) return error.InvalidUser;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT (SELECT max(id) FROM chat_messages WHERE target=?1),(SELECT last_read_id FROM lazer_channel_reads WHERE user_id=?2 AND channel_id=?3)";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var channel_id: i64 = 1;
        while (channel_id <= 4) : (channel_id += 1) {
            if (channel_id != 1) try output.writer.writeByte(',');
            const target = lazer.channelName(channel_id).?;
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
            _ = c.sqlite3_bind_int(stmt, 2, user_id);
            _ = c.sqlite3_bind_int64(stmt, 3, channel_id);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
            const last_message_id: ?i64 = if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 0);
            const last_read_id: ?i64 = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 1);
            try lazer.writeChatChannel(&output.writer, channel_id, last_message_id, last_read_id);
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn markLazerChannelRead(self: *Store, user_id: i32, channel_id: i64, message_id: i64) !void {
        const target = lazer.channelName(channel_id) orelse return error.UnknownChannel;
        if (user_id <= 0 or message_id <= 0) return error.InvalidChatQuery;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO lazer_channel_reads(user_id,channel_id,last_read_id) SELECT ?1,?2,?3 WHERE EXISTS(SELECT 1 FROM chat_messages WHERE id=?3 AND target=?4) ON CONFLICT(user_id,channel_id) DO UPDATE SET last_read_id=max(last_read_id,excluded.last_read_id),updated_at=unixepoch()";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int64(stmt, 2, channel_id);
        _ = c.sqlite3_bind_int64(stmt, 3, message_id);
        _ = c.sqlite3_bind_text(stmt, 4, target.ptr, @intCast(target.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (c.sqlite3_changes(self.db) == 0) return error.ChatMessageNotFound;
    }

    pub fn beatmapRankContext(self: *Store, map_md5: []const u8) !?domain.BeatmapRankContext {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active=1),(SELECT count(*) FROM beatmap_nominations n WHERE n.set_id=b.set_id AND n.active=1) FROM beatmaps b WHERE b.md5=?1";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .map_id = c.sqlite3_column_int(stmt, 0),
            .set_id = c.sqlite3_column_int(stmt, 1),
            .status = @intCast(c.sqlite3_column_int(stmt, 2)),
            .requests = @intCast(c.sqlite3_column_int(stmt, 3)),
            .nominations = @intCast(c.sqlite3_column_int(stmt, 4)),
        };
    }

    pub fn requestBeatmapRank(self: *Store, requester_id: i32, map_md5: []const u8) !domain.BeatmapRankContext {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var map_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT id,set_id,status FROM beatmaps WHERE md5=?1", -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_stmt);
        _ = c.sqlite3_bind_text(map_stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
        if (c.sqlite3_step(map_stmt) != c.SQLITE_ROW) return error.BeatmapNotFound;
        const map_id = c.sqlite3_column_int(map_stmt, 0);
        const set_id = c.sqlite3_column_int(map_stmt, 1);
        const status: i8 = @intCast(c.sqlite3_column_int(map_stmt, 2));
        if (status != @intFromEnum(domain.RankedStatus.pending)) return error.BeatmapNotPending;

        var insert: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO beatmap_rank_requests(set_id,map_id,requester_id) VALUES(?1,?2,?3)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(insert);
        _ = c.sqlite3_bind_int(insert, 1, set_id);
        _ = c.sqlite3_bind_int(insert, 2, map_id);
        _ = c.sqlite3_bind_int(insert, 3, requester_id);
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (c.sqlite3_changes(self.db) == 0) return error.BeatmapAlreadyRequested;
        try self.insertBeatmapRankEventLocked(set_id, requester_id, "request", status, status, "player request");
        try self.exec("COMMIT");
        return .{ .map_id = map_id, .set_id = set_id, .status = status, .requests = try self.activeRankCountLocked("beatmap_rank_requests", set_id), .nominations = try self.activeRankCountLocked("beatmap_nominations", set_id) };
    }

    pub fn nominateBeatmapSet(self: *Store, actor_id: i32, map_md5: []const u8, reason: []const u8) !domain.BeatmapRankContext {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const context = try self.rankContextLocked(map_md5);
        if (context.status != @intFromEnum(domain.RankedStatus.pending)) return error.BeatmapNotPending;
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO beatmap_nominations(set_id,nominator_id,active) VALUES(?1,?2,1) ON CONFLICT(set_id,nominator_id) DO UPDATE SET active=1,updated_at=unixepoch() WHERE beatmap_nominations.active=0";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, context.set_id);
        _ = c.sqlite3_bind_int(stmt, 2, actor_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (c.sqlite3_changes(self.db) == 0) return error.BeatmapAlreadyNominated;
        try self.insertBeatmapRankEventLocked(context.set_id, actor_id, "nominate", context.status, context.status, reason);
        try self.exec("COMMIT");
        var result = context;
        result.nominations = try self.activeRankCountLocked("beatmap_nominations", context.set_id);
        return result;
    }

    pub fn applyBeatmapRankAction(self: *Store, actor_id: i32, map_md5: []const u8, action: domain.BeatmapRankAction, reason: []const u8) !domain.BeatmapRankContext {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var context = try self.rankContextLocked(map_md5);
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
                var previous: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "SELECT from_status FROM beatmap_rank_events WHERE set_id=?1 AND from_status!=to_status ORDER BY id DESC LIMIT 1", -1, &previous, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
                defer _ = c.sqlite3_finalize(previous);
                _ = c.sqlite3_bind_int(previous, 1, context.set_id);
                if (c.sqlite3_step(previous) != c.SQLITE_ROW) return error.NothingToRollback;
                target = @intCast(c.sqlite3_column_int(previous, 0));
            },
        }
        var update: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmaps SET status=?1,status_frozen=1,last_update=unixepoch() WHERE set_id=?2", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(update);
        _ = c.sqlite3_bind_int(update, 1, target);
        _ = c.sqlite3_bind_int(update, 2, context.set_id);
        if (c.sqlite3_step(update) != c.SQLITE_DONE or c.sqlite3_changes(self.db) == 0) return error.BeatmapNotFound;
        if (action != .qualify) try self.clearBeatmapNominationsLocked(context.set_id);
        if (action == .rank or action == .approve or action == .love) try self.resolveBeatmapRequestsLocked(context.set_id);
        try self.rebuildScoreStats(false);
        try self.insertBeatmapRankEventLocked(context.set_id, actor_id, action_name, current, target, reason);
        try self.exec("COMMIT");
        context.status = target;
        context.requests = try self.activeRankCountLocked("beatmap_rank_requests", context.set_id);
        context.nominations = try self.activeRankCountLocked("beatmap_nominations", context.set_id);
        return context;
    }

    pub fn beatmapRankQueue(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT r.set_id,count(*),min(r.created_at),min(b.artist),min(b.title),(SELECT count(*) FROM beatmap_nominations n WHERE n.set_id=r.set_id AND n.active=1) FROM beatmap_rank_requests r JOIN beatmaps b ON b.set_id=r.set_id WHERE r.active=1 GROUP BY r.set_id ORDER BY min(r.created_at),r.set_id LIMIT 50";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (output.items.len != 0) try output.append(allocator, '\n');
            const line = try std.fmt.allocPrint(allocator, "set {d} | {d} request(s) | {d}/2 noms | {s} - {s}", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int(stmt, 1), c.sqlite3_column_int(stmt, 5), std.mem.span(c.sqlite3_column_text(stmt, 3)), std.mem.span(c.sqlite3_column_text(stmt, 4)) });
            defer allocator.free(line);
            try output.appendSlice(allocator, line);
        }
        return output.toOwnedSlice(allocator);
    }

    fn rankContextLocked(self: *Store, map_md5: []const u8) !domain.BeatmapRankContext {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active=1),(SELECT count(*) FROM beatmap_nominations n WHERE n.set_id=b.set_id AND n.active=1) FROM beatmaps b WHERE b.md5=?1";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.BeatmapNotFound;
        return .{ .map_id = c.sqlite3_column_int(stmt, 0), .set_id = c.sqlite3_column_int(stmt, 1), .status = @intCast(c.sqlite3_column_int(stmt, 2)), .requests = @intCast(c.sqlite3_column_int(stmt, 3)), .nominations = @intCast(c.sqlite3_column_int(stmt, 4)) };
    }

    fn activeRankCountLocked(self: *Store, comptime table: []const u8, set_id: i32) !u32 {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT count(*) FROM " ++ table ++ " WHERE set_id=?1 AND active=1";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return @intCast(c.sqlite3_column_int(stmt, 0));
    }

    fn clearBeatmapNominationsLocked(self: *Store, set_id: i32) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_nominations SET active=0,updated_at=unixepoch() WHERE set_id=?1 AND active=1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    fn resolveBeatmapRequestsLocked(self: *Store, set_id: i32) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_rank_requests SET active=0,resolved_at=unixepoch() WHERE set_id=?1 AND active=1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    fn insertBeatmapRankEventLocked(self: *Store, set_id: i32, actor_id: i32, action: []const u8, from_status: i8, to_status: i8, reason: []const u8) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO beatmap_rank_events(set_id,actor_id,action,from_status,to_status,reason) VALUES(?1,?2,?3,?4,?5,?6)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        _ = c.sqlite3_bind_int(stmt, 2, actor_id);
        _ = c.sqlite3_bind_text(stmt, 3, action.ptr, @intCast(action.len), null);
        _ = c.sqlite3_bind_int(stmt, 4, from_status);
        _ = c.sqlite3_bind_int(stmt, 5, to_status);
        _ = c.sqlite3_bind_text(stmt, 6, reason.ptr, @intCast(reason.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        var target_buf: [32]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "beatmapset:{d}", .{set_id});
        var audit: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,?2,?3,?4)", -1, &audit, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(audit);
        _ = c.sqlite3_bind_int(audit, 1, actor_id);
        var audit_action_buf: [64]u8 = undefined;
        const audit_action = try std.fmt.bufPrint(&audit_action_buf, "beatmap.{s}", .{action});
        _ = c.sqlite3_bind_text(audit, 2, audit_action.ptr, @intCast(audit_action.len), null);
        _ = c.sqlite3_bind_text(audit, 3, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(audit, 4, reason.ptr, @intCast(reason.len), null);
        if (c.sqlite3_step(audit) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn channelCanWrite(self: *Store, name: []const u8, privileges: u32) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT CASE WHEN locked!=0 THEN (?2 & 8192)=8192 ELSE (?2 & write_privileges)=write_privileges END FROM chat_channels WHERE name=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), null);
        _ = c.sqlite3_bind_int64(stmt, 2, privileges);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return true;
        return c.sqlite3_column_int(stmt, 0) != 0;
    }

    pub fn setChannelLocked(self: *Store, actor_id: i32, name: []const u8, locked: bool, reason: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE chat_channels SET locked=?1,updated_by=?2,updated_at=unixepoch() WHERE name=?3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, @intFromBool(locked));
        _ = c.sqlite3_bind_int(stmt, 2, actor_id);
        _ = c.sqlite3_bind_text(stmt, 3, name.ptr, @intCast(name.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) == 0) return error.InvalidChannel;
        var audit_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,?2,?3,?4)", -1, &audit_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(audit_stmt);
        _ = c.sqlite3_bind_int(audit_stmt, 1, actor_id);
        const action = if (locked) "channel.lock" else "channel.unlock";
        _ = c.sqlite3_bind_text(audit_stmt, 2, action.ptr, @intCast(action.len), null);
        _ = c.sqlite3_bind_text(audit_stmt, 3, name.ptr, @intCast(name.len), null);
        _ = c.sqlite3_bind_text(audit_stmt, 4, reason.ptr, @intCast(reason.len), null);
        if (c.sqlite3_step(audit_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        try self.exec("COMMIT");
    }

    pub fn setSilence(self: *Store, actor_id: i32, target_id: i32, silence_end: i64, action: []const u8, reason: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET silence_end=?1 WHERE id=?2 AND id!=3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, silence_end);
        _ = c.sqlite3_bind_int(stmt, 2, target_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) == 0) return error.InvalidModerationTarget;
        try self.insertAuditLocked(actor_id, action, target_id, reason);
        try self.exec("COMMIT");
    }

    pub fn setRestricted(self: *Store, actor_id: i32, target_id: i32, restricted: bool, reason: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET restricted=?1 WHERE id=?2 AND id!=3", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, @intFromBool(restricted));
        _ = c.sqlite3_bind_int(stmt, 2, target_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE or c.sqlite3_changes(self.db) == 0) return error.InvalidModerationTarget;
        try self.insertAuditLocked(actor_id, if (restricted) "account.restrict" else "account.unrestrict", target_id, reason);
        try self.exec("COMMIT");
    }

    pub fn changePrivileges(self: *Store, actor_id: i32, target_id: i32, bits: u32, add: bool) !u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = if (add)
            "UPDATE users SET privileges=privileges | ?1 WHERE id=?2 AND id!=3 RETURNING privileges"
        else
            "UPDATE users SET privileges=privileges & ~?1 WHERE id=?2 AND id!=3 RETURNING privileges";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, bits);
        _ = c.sqlite3_bind_int(stmt, 2, target_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.InvalidModerationTarget;
        const privileges: u32 = @intCast(c.sqlite3_column_int64(stmt, 0));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        var detail_buf: [64]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "{s} bits:{d}", .{ if (add) "add" else "remove", bits });
        try self.insertAuditLocked(actor_id, "account.privileges", target_id, detail);
        try self.exec("COMMIT");
        return privileges;
    }

    pub fn addModerationNote(self: *Store, actor_id: i32, target_id: i32, note: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.insertAuditLocked(actor_id, "account.note", target_id, note);
    }

    pub fn recordModerationAction(self: *Store, actor_id: i32, target_id: i32, action: []const u8, detail: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.insertAuditLocked(actor_id, action, target_id, detail);
    }

    pub fn recordAudit(self: *Store, actor_id: i32, action: []const u8, target: []const u8, detail: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,?2,?3,?4)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, actor_id);
        _ = c.sqlite3_bind_text(stmt, 2, action.ptr, @intCast(action.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(stmt, 4, detail.ptr, @intCast(detail.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn moderationNotes(self: *Store, allocator: std.mem.Allocator, target_id: i32, limit: u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var target_buf: [24]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_id});
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT created_at,action,coalesce(actor_id,0),coalesce(detail,'') FROM audit_log WHERE target=?1 ORDER BY id DESC LIMIT ?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_int(stmt, 2, limit);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (output.items.len != 0) try output.append(allocator, '\n');
            const line = try std.fmt.allocPrint(allocator, "{d} | {s} | by {d} | {s}", .{
                c.sqlite3_column_int64(stmt, 0),
                std.mem.span(c.sqlite3_column_text(stmt, 1)),
                c.sqlite3_column_int(stmt, 2),
                std.mem.span(c.sqlite3_column_text(stmt, 3)),
            });
            defer allocator.free(line);
            try output.appendSlice(allocator, line);
        }
        return output.toOwnedSlice(allocator);
    }

    pub fn createModerationAppeal(self: *Store, user_id: i32, kind: []const u8, message: []const u8) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO moderation_appeals(user_id,kind,message) VALUES(?1,?2,?3) RETURNING id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, kind.ptr, @intCast(kind.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, message.ptr, @intCast(message.len), null);
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => c.sqlite3_column_int64(stmt, 0),
            c.SQLITE_CONSTRAINT => error.AppealAlreadyOpen,
            else => error.DatabaseQueryFailed,
        };
    }

    pub fn resolveModerationAppeal(self: *Store, actor_id: i32, appeal_id: i64, status: []const u8, resolution: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const target_id = block: {
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE moderation_appeals SET status=?1,reviewer_id=?2,resolution=?3,resolved_at=unixepoch() WHERE id=?4 AND status='open' RETURNING user_id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), null);
            _ = c.sqlite3_bind_int(stmt, 2, actor_id);
            _ = c.sqlite3_bind_text(stmt, 3, resolution.ptr, @intCast(resolution.len), null);
            _ = c.sqlite3_bind_int64(stmt, 4, appeal_id);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.AppealNotOpen;
            break :block c.sqlite3_column_int(stmt, 0);
        };
        try self.insertAuditLocked(actor_id, if (std.mem.eql(u8, status, "accepted")) "appeal.accept" else "appeal.deny", target_id, resolution);
        try self.exec("COMMIT");
    }

    pub fn beatmapMd5ForSet(self: *Store, set_id: i32) !?[32]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT md5 FROM beatmaps WHERE set_id=?1 ORDER BY id LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const value = std.mem.span(c.sqlite3_column_text(stmt, 0));
        if (value.len != 32) return error.InvalidBeatmapHash;
        var out: [32]u8 = undefined;
        @memcpy(&out, value);
        return out;
    }

    pub fn staffAnticheatJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var pending_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM anticheat_observations WHERE review_label='pending'", -1, &pending_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(pending_stmt);
        if (c.sqlite3_step(pending_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        const pending = c.sqlite3_column_int64(pending_stmt, 0);

        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT o.id,o.user_id,u.name,coalesce(o.score_id,0),o.source,o.module,o.action,o.sample_weight,o.reason,o.risk_score,o.confidence_bps,o.evidence,o.decision_flags,o.rule_revision,o.objects_checked,o.matched_clicks,o.mean_abs_timing_error_milli,o.timing_stddev_milli,o.exact_timing_bps,o.center_hits_bps,o.mean_center_distance_milli,o.snap_events,o.replay_match_count,o.key_press_count,o.key_hold_count,o.mean_hold_duration_milli,o.hold_duration_stddev_milli,o.alternation_bps,o.target_distance_stddev_milli,o.velocity_spike_count,o.movement_velocity_stddev_milli,o.review_label,coalesce(reviewer.name,''),o.review_note,coalesce(o.reviewed_at,0),o.created_at FROM anticheat_observations o JOIN users u ON u.id=o.user_id LEFT JOIN users reviewer ON reviewer.id=o.reviewer_id ORDER BY (o.review_label='pending') DESC,o.created_at DESC,o.id DESC LIMIT 250";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"pending\":{d},\"observations\":[", .{pending});
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
            try output.writer.writeAll(",\"reviewer\":");
            try std.json.Stringify.value(std.mem.span(c.sqlite3_column_text(stmt, 32)), .{}, &output.writer);
            try output.writer.writeAll(",\"review_note\":");
            try std.json.Stringify.value(std.mem.span(c.sqlite3_column_text(stmt, 33)), .{}, &output.writer);
            try output.writer.print(",\"reviewed_at\":{d},\"created_at\":{d}}}", .{ c.sqlite3_column_int64(stmt, 34), c.sqlite3_column_int64(stmt, 35) });
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

    pub fn staffOverviewJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT (SELECT count(*) FROM moderation_appeals WHERE status='open'),(SELECT count(DISTINCT set_id) FROM beatmap_rank_requests WHERE active=1),(SELECT count(*) FROM users WHERE restricted=1),(SELECT count(*) FROM users WHERE silence_end>unixepoch()),(SELECT count(*) FROM audit_log WHERE created_at>=unixepoch()-86400),(SELECT count(*) FROM client_hardware),(SELECT count(*) FROM anticheat_observations WHERE review_label='pending')";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return std.fmt.allocPrint(allocator, "{{\"open_appeals\":{d},\"ranking_sets\":{d},\"restricted_users\":{d},\"silenced_users\":{d},\"audit_24h\":{d},\"hardware_records\":{d},\"anticheat_pending\":{d}}}", .{ c.sqlite3_column_int64(stmt, 0), c.sqlite3_column_int64(stmt, 1), c.sqlite3_column_int64(stmt, 2), c.sqlite3_column_int64(stmt, 3), c.sqlite3_column_int64(stmt, 4), c.sqlite3_column_int64(stmt, 5), c.sqlite3_column_int64(stmt, 6) });
    }

    pub fn staffRankingJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var queue: ?*c.sqlite3_stmt = null;
        const queue_sql = "SELECT r.set_id,min(b.status),count(*),(SELECT count(*) FROM beatmap_nominations n WHERE n.set_id=r.set_id AND n.active=1),min(b.artist),min(b.title),min(b.creator),min(b.md5),min(r.created_at) FROM beatmap_rank_requests r JOIN beatmaps b ON b.set_id=r.set_id WHERE r.active=1 GROUP BY r.set_id ORDER BY min(r.created_at),r.set_id LIMIT 100";
        if (c.sqlite3_prepare_v2(self.db, queue_sql, -1, &queue, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(queue);
        var history: ?*c.sqlite3_stmt = null;
        const history_sql = "SELECT e.id,e.set_id,e.action,e.from_status,e.to_status,e.reason,e.created_at,u.name FROM beatmap_rank_events e JOIN users u ON u.id=e.actor_id ORDER BY e.id DESC LIMIT 100";
        if (c.sqlite3_prepare_v2(self.db, history_sql, -1, &history, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(history);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"queue\":[");
        var first = true;
        while (c.sqlite3_step(queue) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"set_id\":{d},\"status\":{d},\"requests\":{d},\"nominations\":{d},\"artist\":", .{ c.sqlite3_column_int(queue, 0), c.sqlite3_column_int(queue, 1), c.sqlite3_column_int(queue, 2), c.sqlite3_column_int(queue, 3) });
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(queue, 4)));
            try output.writer.writeAll(",\"title\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(queue, 5)));
            try output.writer.writeAll(",\"creator\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(queue, 6)));
            try output.writer.writeAll(",\"map_md5\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(queue, 7)));
            try output.writer.print(",\"created_at\":{d}}}", .{c.sqlite3_column_int64(queue, 8)});
        }
        try output.writer.writeAll("],\"history\":[");
        first = true;
        while (c.sqlite3_step(history) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"id\":{d},\"set_id\":{d},\"action\":", .{ c.sqlite3_column_int64(history, 0), c.sqlite3_column_int(history, 1) });
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(history, 2)));
            try output.writer.print(",\"from_status\":{d},\"to_status\":{d},\"reason\":", .{ c.sqlite3_column_int(history, 3), c.sqlite3_column_int(history, 4) });
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(history, 5)));
            try output.writer.print(",\"created_at\":{d},\"actor\":", .{c.sqlite3_column_int64(history, 6)});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(history, 7)));
            try output.writer.writeByte('}');
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn staffAppealsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT a.id,a.user_id,u.name,u.country,a.kind,a.message,a.status,coalesce(r.name,''),coalesce(a.resolution,''),a.created_at,coalesce(a.resolved_at,0) FROM moderation_appeals a JOIN users u ON u.id=a.user_id LEFT JOIN users r ON r.id=a.reviewer_id ORDER BY CASE a.status WHEN 'open' THEN 0 ELSE 1 END,a.created_at,a.id LIMIT 200";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"appeals\":[");
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ c.sqlite3_column_int64(stmt, 0), c.sqlite3_column_int(stmt, 1) });
            for (2..9) |column| {
                try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, @intCast(column))));
                const names = [_][]const u8{ "country", "kind", "message", "status", "reviewer", "resolution" };
                if (column < 8) try output.writer.print(",\"{s}\":", .{names[column - 2]});
            }
            try output.writer.print(",\"created_at\":{d},\"resolved_at\":{d}}}", .{ c.sqlite3_column_int64(stmt, 9), c.sqlite3_column_int64(stmt, 10) });
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn staffUserJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var user: ?*c.sqlite3_stmt = null;
        const user_sql = "SELECT id,name,country,privileges,silence_end,restricted,created_at,coalesce(last_login,0),(SELECT count(DISTINCT h2.user_id) FROM client_hardware h1 JOIN client_hardware h2 ON h2.user_id!=h1.user_id AND h2.adapters_md5=h1.adapters_md5 AND h2.uninstall_md5=h1.uninstall_md5 AND h2.disk_signature_md5=h1.disk_signature_md5 WHERE h1.user_id=u.id) FROM users u WHERE id=?1 AND id!=3";
        if (c.sqlite3_prepare_v2(self.db, user_sql, -1, &user, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(user);
        _ = c.sqlite3_bind_int(user, 1, user_id);
        if (c.sqlite3_step(user) != c.SQLITE_ROW) return null;
        var hardware: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT substr(adapters_md5,-8),substr(uninstall_md5,-8),substr(disk_signature_md5,-8),client_version,running_under_wine,first_seen,last_seen,occurrences FROM client_hardware WHERE user_id=?1 ORDER BY last_seen DESC LIMIT 50", -1, &hardware, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(hardware);
        _ = c.sqlite3_bind_int(hardware, 1, user_id);
        var audit: ?*c.sqlite3_stmt = null;
        var target_buf: [24]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
        if (c.sqlite3_prepare_v2(self.db, "SELECT a.id,coalesce(actor.name,'system'),a.action,coalesce(a.detail,''),a.created_at FROM audit_log a LEFT JOIN users actor ON actor.id=a.actor_id WHERE a.target=?1 ORDER BY a.id DESC LIMIT 100", -1, &audit, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(audit);
        _ = c.sqlite3_bind_text(audit, 1, target.ptr, @intCast(target.len), null);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"user\":{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(user, 0)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 1)));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 2)));
        try output.writer.print(",\"privileges\":{d},\"silence_end\":{d},\"restricted\":{},\"created_at\":{d},\"last_login\":{d},\"exact_hardware_matches\":{d}}},\"hardware\":[", .{ c.sqlite3_column_int64(user, 3), c.sqlite3_column_int64(user, 4), c.sqlite3_column_int(user, 5) != 0, c.sqlite3_column_int64(user, 6), c.sqlite3_column_int64(user, 7), c.sqlite3_column_int64(user, 8) });
        var first = true;
        while (c.sqlite3_step(hardware) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.writeAll("{\"adapter\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(hardware, 0)));
            try output.writer.writeAll(",\"uninstall\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(hardware, 1)));
            try output.writer.writeAll(",\"disk\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(hardware, 2)));
            try output.writer.writeAll(",\"client\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(hardware, 3)));
            try output.writer.print(",\"wine\":{},\"first_seen\":{d},\"last_seen\":{d},\"occurrences\":{d}}}", .{ c.sqlite3_column_int(hardware, 4) != 0, c.sqlite3_column_int64(hardware, 5), c.sqlite3_column_int64(hardware, 6), c.sqlite3_column_int(hardware, 7) });
        }
        try output.writer.writeAll("],\"audit\":[");
        first = true;
        while (c.sqlite3_step(audit) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"id\":{d},\"actor\":", .{c.sqlite3_column_int64(audit, 0)});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(audit, 1)));
            try output.writer.writeAll(",\"action\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(audit, 2)));
            try output.writer.writeAll(",\"detail\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(audit, 3)));
            try output.writer.print(",\"created_at\":{d}}}", .{c.sqlite3_column_int64(audit, 4)});
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn staffAuditJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT a.id,coalesce(u.name,'system'),a.action,coalesce(a.target,''),coalesce(a.detail,''),a.created_at FROM audit_log a LEFT JOIN users u ON u.id=a.actor_id ORDER BY a.id DESC LIMIT 250", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"events\":[");
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"id\":{d},\"actor\":", .{c.sqlite3_column_int64(stmt, 0)});
            for (1..5) |column| {
                try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, @intCast(column))));
                const names = [_][]const u8{ "action", "target", "detail" };
                if (column < 4) try output.writer.print(",\"{s}\":", .{names[column - 1]});
            }
            try output.writer.print(",\"created_at\":{d}}}", .{c.sqlite3_column_int64(stmt, 5)});
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn staffChannelsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT name,topic,write_privileges,locked,updated_at FROM chat_channels ORDER BY name", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"channels\":[");
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.writeAll("{\"name\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 0)));
            try output.writer.writeAll(",\"topic\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 1)));
            try output.writer.print(",\"write_privileges\":{d},\"locked\":{},\"updated_at\":{d}}}", .{ c.sqlite3_column_int64(stmt, 2), c.sqlite3_column_int(stmt, 3) != 0, c.sqlite3_column_int64(stmt, 4) });
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn updateCountry(self: *Store, user_id: i32, value: [2]u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE users SET country=?1,last_login=unixepoch() WHERE id=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, value[0..].ptr, 2, null);
        _ = c.sqlite3_bind_int(stmt, 2, user_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub const ServerCounts = struct {
        users: i64,
        plays: i64,
        passed: i64,
        maps: i64,
    };

    pub const BeatmapCacheStats = struct {
        entries: i64,
        bytes: i64,
        hydration_failures: i64,
    };

    pub const BeatmapCachePrune = struct {
        entries: i64,
        bytes: i64,
    };

    pub const BeatmapMediaCacheStats = struct {
        entries: i64,
        bytes: i64,
    };

    pub const ObjectMigrationStats = struct {
        archives: i64 = 0,
        media: i64 = 0,
        failed: i64 = 0,
    };

    pub const ObjectPurgeStats = struct {
        archives: i64 = 0,
        archive_bytes: i64 = 0,
        media: i64 = 0,
        media_bytes: i64 = 0,
    };

    pub fn serverCounts(self: *Store) !ServerCounts {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT " ++
            "(SELECT count(*) FROM users WHERE id!=3)," ++
            "(SELECT count(*) FROM scores)+(SELECT count(*) FROM lazer_scores)," ++
            "(SELECT count(*) FROM scores WHERE passed=1)+(SELECT count(*) FROM lazer_scores WHERE passed=1)," ++
            "(SELECT count(*) FROM beatmaps)";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return .{
            .users = c.sqlite3_column_int64(stmt, 0),
            .plays = c.sqlite3_column_int64(stmt, 1),
            .passed = c.sqlite3_column_int64(stmt, 2),
            .maps = c.sqlite3_column_int64(stmt, 3),
        };
    }

    pub fn customAvatarUserIds(self: *Store, allocator: std.mem.Allocator) ![]i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT user_id FROM user_avatars ORDER BY user_id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var ids: std.ArrayList(i32) = .empty;
        errdefer ids.deinit(allocator);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) try ids.append(allocator, c.sqlite3_column_int(stmt, 0));
        return ids.toOwnedSlice(allocator);
    }

    pub fn siteRankings(self: *Store, allocator: std.mem.Allocator, source: domain.SiteScoreSource, mode: u8, offset: u16) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const stable_sql =
            "WITH source_scores AS (" ++
            "SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,b.id beatmap_id " ++
            "FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.mode=?1 AND s.rank_namespace=?2)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
            "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0 ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET ?3";
        const lazer_sql =
            "WITH source_scores AS (" ++
            "SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,s.beatmap_id " ++
            "FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=?1 AND s.rank_namespace=?2)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
            "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0 ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET ?3";
        const sql: [*:0]const u8 = switch (source) {
            .all => "SELECT row_number() OVER(ORDER BY s.pp DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,s.pp,s.accuracy,s.plays,s.ranked_score,s.total_score,s.max_combo FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?1 AND u.id!=3 AND u.restricted=0 AND s.plays>0 ORDER BY s.pp DESC,u.id ASC LIMIT 100 OFFSET ?2",
            .stable, .scorev2 => stable_sql,
            .lazer => lazer_sql,
        };
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (source == .all) {
            _ = c.sqlite3_bind_int(stmt, 1, mode);
            _ = c.sqlite3_bind_int(stmt, 2, offset);
        } else {
            const namespace = domain.siteNamespace(source, mode);
            _ = c.sqlite3_bind_int(stmt, 1, domain.siteScoreMode(mode));
            _ = c.sqlite3_bind_text(stmt, 2, namespace.ptr, @intCast(namespace.len), null);
            _ = c.sqlite3_bind_int(stmt, 3, offset);
        }
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"source\":\"{s}\",\"mode\":{d},\"offset\":{d},\"players\":[", .{ @tagName(source), mode, offset });
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"rank\":{d},\"id\":{d},\"name\":", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int(stmt, 1) });
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 2)));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
            try output.writer.print(",\"privileges\":{d},\"pp\":{d},\"accuracy\":{d},\"plays\":{d},\"ranked_score\":{d},\"total_score\":{d},\"max_combo\":{d}}}", .{ c.sqlite3_column_int64(stmt, 4), c.sqlite3_column_int(stmt, 5), c.sqlite3_column_double(stmt, 6), c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int64(stmt, 8), c.sqlite3_column_int64(stmt, 9), c.sqlite3_column_int(stmt, 10) });
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn lazerRankingsJson(self: *Store, allocator: std.mem.Allocator, ruleset_id: u8, kind: lazer.RankingKind, country_filter: ?[]const u8, page: u16) ![]u8 {
        if (page == 0) return error.InvalidPage;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const offset: u32 = (@as(u32, page) - 1) * 50;
        var stmt: ?*c.sqlite3_stmt = null;
        const country_sql =
            "WITH visible AS (SELECT CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,s.plays,s.ranked_score,s.pp FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?1 AND s.plays>0 AND u.id!=3 AND u.restricted=0) " ++
            "SELECT country,count(*),sum(plays),sum(ranked_score),sum(pp) FROM visible WHERE country!='XX' GROUP BY country ORDER BY sum(pp) DESC,country ASC LIMIT 50 OFFSET ?2";
        const performance_sql =
            "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo," ++
            "row_number() OVER(ORDER BY s.pp DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END ORDER BY s.pp DESC,u.id ASC) country_rank " ++
            "FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?1 AND s.plays>0 AND u.id!=3 AND u.restricted=0) " ++
            "SELECT * FROM visible WHERE (?2='' OR country=?2) ORDER BY pp DESC,id ASC LIMIT 50 OFFSET ?3";
        const score_sql =
            "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo," ++
            "row_number() OVER(ORDER BY s.total_score DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END ORDER BY s.total_score DESC,u.id ASC) country_rank " ++
            "FROM stats s JOIN users u ON u.id=s.user_id WHERE s.mode=?1 AND s.plays>0 AND u.id!=3 AND u.restricted=0) " ++
            "SELECT * FROM visible WHERE (?2='' OR country=?2) ORDER BY total_score DESC,id ASC LIMIT 50 OFFSET ?3";
        const sql: [*:0]const u8 = switch (kind) {
            .country => country_sql,
            .performance => performance_sql,
            .score => score_sql,
        };
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, ruleset_id);
        if (kind == .country) {
            _ = c.sqlite3_bind_int64(stmt, 2, offset);
        } else {
            const filter = country_filter orelse "";
            _ = c.sqlite3_bind_text(stmt, 2, filter.ptr, @intCast(filter.len), null);
            _ = c.sqlite3_bind_int64(stmt, 3, offset);
        }

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"ranking\":[");
        var row: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) : (row += 1) {
            if (row != 0) try output.writer.writeByte(',');
            if (kind == .country) {
                try output.writer.writeAll("{\"code\":");
                try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 0)));
                try output.writer.print(",\"active_users\":{d},\"play_count\":{d},\"ranked_score\":{d},\"performance\":{d}}}", .{ c.sqlite3_column_int(stmt, 1), c.sqlite3_column_int64(stmt, 2), c.sqlite3_column_int64(stmt, 3), c.sqlite3_column_int64(stmt, 4) });
                continue;
            }
            const country_text = std.mem.span(c.sqlite3_column_text(stmt, 2));
            const cc: [2]u8 = if (country_text.len == 2) .{ country_text[0], country_text[1] } else .{ 'X', 'X' };
            const user: domain.User = .{ .id = c.sqlite3_column_int(stmt, 0), .name = std.mem.span(c.sqlite3_column_text(stmt, 1)), .safe_name = "", .country = cc, .privileges = @intCast(c.sqlite3_column_int64(stmt, 3)) };
            const stats: domain.Stats = .{ .mode = @enumFromInt(ruleset_id), .ranked_score = c.sqlite3_column_int64(stmt, 4), .total_score = c.sqlite3_column_int64(stmt, 5), .pp = c.sqlite3_column_int(stmt, 6), .plays = c.sqlite3_column_int(stmt, 7), .play_time = c.sqlite3_column_int(stmt, 8), .total_hits = c.sqlite3_column_int64(stmt, 9), .accuracy = c.sqlite3_column_double(stmt, 10), .max_combo = c.sqlite3_column_int(stmt, 11) };
            try user_json.writeRankingStatistics(&output.writer, user, stats, c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 13));
        }
        try output.writer.writeAll("],\"cursor\":null}");
        return output.toOwnedSlice();
    }

    fn prepareSiteScores(self: *Store, sql: [:0]const u8, user_id: i32, score_mode: u8, namespace: []const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, score_mode);
        _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
        return stmt.?;
    }

    fn writeSiteScores(writer: *std.Io.Writer, scores: *c.sqlite3_stmt, include_weight: bool) !void {
        try writer.writeByte('[');
        var first = true;
        var position: usize = 0;
        while (c.sqlite3_step(scores) == c.SQLITE_ROW) {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{{\"id\":{d},\"score\":{d},\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"mode\":{d},\"namespace\":", .{ c.sqlite3_column_int64(scores, 0), c.sqlite3_column_int64(scores, 1), c.sqlite3_column_double(scores, 2), c.sqlite3_column_double(scores, 3), c.sqlite3_column_int(scores, 4), c.sqlite3_column_int(scores, 5), c.sqlite3_column_int(scores, 6) });
            try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 7)));
            try writer.print(",\"passed\":{},\"submitted_at\":{d},\"set_id\":{d},\"map_id\":{d},\"artist\":", .{ c.sqlite3_column_int(scores, 8) != 0, c.sqlite3_column_int64(scores, 9), c.sqlite3_column_int(scores, 10), c.sqlite3_column_int(scores, 11) });
            try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 12)));
            try writer.writeAll(",\"title\":");
            try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 13)));
            try writer.writeAll(",\"version\":");
            try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 14)));
            try writer.print(",\"status\":{d},\"client\":", .{c.sqlite3_column_int(scores, 15)});
            try jsonString(writer, std.mem.span(c.sqlite3_column_text(scores, 16)));
            try writer.writeAll(",\"mods_json\":");
            if (c.sqlite3_column_type(scores, 17) == c.SQLITE_NULL) {
                try writer.writeAll("null");
            } else {
                try writer.writeAll(std.mem.span(c.sqlite3_column_text(scores, 17)));
            }
            if (include_weight) {
                const percentage = 100.0 * std.math.pow(f64, 0.95, @floatFromInt(position));
                const weighted_pp = c.sqlite3_column_double(scores, 2) * percentage / 100.0;
                try writer.print(",\"weight\":{{\"percentage\":{d:.2},\"pp\":{d:.2}}}", .{ percentage, weighted_pp });
            }
            try writer.print(",\"has_replay\":{},\"star_rating\":{d}}}", .{ c.sqlite3_column_int(scores, 18) != 0, c.sqlite3_column_double(scores, 19) });
            position += 1;
        }
        try writer.writeByte(']');
    }

    pub fn siteProfile(self: *Store, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const score_mode = domain.siteScoreMode(stats_mode);
        const namespace = domain.siteNamespace(source, stats_mode);
        var user: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT id,name,CASE WHEN show_country=1 THEN country ELSE 'XX' END,privileges,created_at,bio,preferred_mode,profile_source,coalesce((SELECT updated_at FROM user_avatars a WHERE a.user_id=users.id),avatar_key),profile_title,profile_pronouns,profile_location,profile_website,profile_accent,show_profile_stats,show_recent_scores FROM users WHERE id=?1 AND id!=3 AND restricted=0", -1, &user, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(user);
        _ = c.sqlite3_bind_int(user, 1, user_id);
        if (c.sqlite3_step(user) != c.SQLITE_ROW) return null;
        var stats: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT s.mode,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,(SELECT count(*)+1 FROM stats r JOIN users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND ru.id!=3 AND ru.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM stats s WHERE s.user_id=?1 ORDER BY s.mode", -1, &stats, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stats);
        _ = c.sqlite3_bind_int(stats, 1, user_id);
        const stable_stats_sql =
            "WITH source_scores AS (SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.time_elapsed/1000 play_time,b.status,b.id beatmap_id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.mode=?2 AND s.rank_namespace=?3)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
            "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
            "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=?1";
        const lazer_stats_sql =
            "WITH source_scores AS (SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,max(b.total_length,0) play_time,b.status,s.beatmap_id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=?2 AND s.rank_namespace=?3)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
            "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
            "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=?1";
        const combined_stats_sql = "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.accuracy,s.max_combo,(SELECT count(*)+1 FROM stats r JOIN users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND ru.id!=3 AND ru.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM stats s WHERE s.user_id=?1 AND s.mode=?2 AND s.plays>0";
        const selected_stats_sql: [*:0]const u8 = switch (source) {
            .all => combined_stats_sql,
            .stable, .scorev2 => stable_stats_sql,
            .lazer => lazer_stats_sql,
        };
        var selected_stats: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, selected_stats_sql, -1, &selected_stats, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(selected_stats);
        _ = c.sqlite3_bind_int(selected_stats, 1, user_id);
        _ = c.sqlite3_bind_int(selected_stats, 2, score_mode);
        if (source != .all) _ = c.sqlite3_bind_text(selected_stats, 3, namespace.ptr, @intCast(namespace.len), null);
        const stable_columns = "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'stable',NULL,length(s.replay)>0,coalesce(nullif(s.star_rating,0),b.star_rating) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 ";
        const lazer_columns = "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,length(s.replay)>0,coalesce(nullif(s.star_rating,0),b.star_rating) FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id ";
        const pinned_sql: [:0]const u8 = switch (source) {
            .all, .stable, .scorev2 => stable_columns ++ "JOIN score_pins p ON p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
            .lazer => stable_columns ++ "WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND 0",
        };
        const top_sql: [:0]const u8 = switch (source) {
            .all => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,beatmap_key) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL,length(s.replay)>0,coalesce(nullif(s.star_rating,0),b.star_rating),b.id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4) UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,length(s.replay)>0,coalesce(nullif(s.star_rating,0),b.star_rating),b.id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4))," ++
                "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) map_place FROM candidates) " ++
                "SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_key ASC,id ASC LIMIT 100",
            .stable, .scorev2 => "WITH candidates AS (" ++ stable_columns ++ "WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
            .lazer => "WITH candidates AS (" ++ lazer_columns ++ "WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
        };
        const recent_sql: [:0]const u8 = switch (source) {
            .all => "WITH recent_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL,length(s.replay)>0,coalesce(nullif(s.star_rating,0),b.star_rating) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json,length(s.replay)>0,coalesce(nullif(s.star_rating,0),b.star_rating) FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3) " ++
                "SELECT * FROM recent_scores ORDER BY submitted_at DESC,client ASC,id DESC LIMIT 20",
            .lazer => lazer_columns ++ "WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 ORDER BY s.id DESC LIMIT 20",
            .stable, .scorev2 => stable_columns ++ "WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 ORDER BY s.id DESC LIMIT 20",
        };
        const pinned = try self.prepareSiteScores(pinned_sql, user_id, score_mode, namespace);
        defer _ = c.sqlite3_finalize(pinned);
        const top = try self.prepareSiteScores(top_sql, user_id, score_mode, namespace);
        defer _ = c.sqlite3_finalize(top);
        const recent = try self.prepareSiteScores(recent_sql, user_id, score_mode, namespace);
        defer _ = c.sqlite3_finalize(recent);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"id\":{d},\"name\":", .{c.sqlite3_column_int(user, 0)});
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 1)));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 2)));
        try output.writer.print(",\"privileges\":{d},\"created_at\":{d},\"bio\":", .{ c.sqlite3_column_int64(user, 3), c.sqlite3_column_int64(user, 4) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 5)));
        try output.writer.writeAll(",\"profile_source\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 7)));
        try output.writer.print(",\"preferred_mode\":{d},\"avatar_version\":{d},\"profile_title\":", .{ c.sqlite3_column_int(user, 6), c.sqlite3_column_int64(user, 8) });
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 9)));
        try output.writer.writeAll(",\"profile_pronouns\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 10)));
        try output.writer.writeAll(",\"profile_location\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 11)));
        try output.writer.writeAll(",\"profile_website\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 12)));
        try output.writer.writeAll(",\"profile_accent\":");
        try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(user, 13)));
        const show_profile_stats = c.sqlite3_column_int(user, 14) != 0;
        const show_recent_scores = c.sqlite3_column_int(user, 15) != 0;
        try output.writer.print(",\"stats_public\":{},\"recent_scores_public\":{},\"selected_source\":\"{s}\",\"stats_source\":\"{s}\",\"selected_mode\":{d},\"selected_stats\":", .{ show_profile_stats, show_recent_scores, @tagName(source), if (source == .all) "combined" else @tagName(source), stats_mode });
        if (show_profile_stats and c.sqlite3_step(selected_stats) == c.SQLITE_ROW) {
            try output.writer.print("{{\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d}}}", .{ c.sqlite3_column_int64(selected_stats, 0), c.sqlite3_column_int64(selected_stats, 1), c.sqlite3_column_int(selected_stats, 2), c.sqlite3_column_int(selected_stats, 3), c.sqlite3_column_int(selected_stats, 4), c.sqlite3_column_double(selected_stats, 5), c.sqlite3_column_int(selected_stats, 6), c.sqlite3_column_int(selected_stats, 7) });
        } else {
            try output.writer.writeAll("null");
        }
        try output.writer.writeAll(",\"stats\":[");
        var first = true;
        while (show_profile_stats and c.sqlite3_step(stats) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"mode\":{d},\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"total_hits\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d}}}", .{ c.sqlite3_column_int(stats, 0), c.sqlite3_column_int64(stats, 1), c.sqlite3_column_int64(stats, 2), c.sqlite3_column_int(stats, 3), c.sqlite3_column_int(stats, 4), c.sqlite3_column_int(stats, 5), c.sqlite3_column_int64(stats, 6), c.sqlite3_column_double(stats, 7), c.sqlite3_column_int(stats, 8), c.sqlite3_column_int(stats, 9) });
        }
        try output.writer.writeAll("],\"pinned_scores\":");
        try writeSiteScores(&output.writer, pinned, false);
        try output.writer.writeAll(",\"top_scores\":");
        try writeSiteScores(&output.writer, top, true);
        try output.writer.writeAll(",\"recent_scores\":");
        if (show_recent_scores) try writeSiteScores(&output.writer, recent, false) else try output.writer.writeAll("[]");
        try output.writer.writeAll(",\"achievements\":");
        try self.writeUserAchievementsLocked(&output.writer, user_id, true);
        try output.writer.writeByte('}');
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn siteBeatmapLeaderboard(self: *Store, allocator: std.mem.Allocator, map_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const score_mode = domain.siteScoreMode(stats_mode);
        const namespace = domain.siteNamespace(source, stats_mode);
        var map: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT mode FROM beatmaps WHERE id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map);
        _ = c.sqlite3_bind_int(map, 1, map_id);
        if (c.sqlite3_step(map) != c.SQLITE_ROW or c.sqlite3_column_int(map, 0) != score_mode) return null;
        const sql =
            "WITH candidates(id,user_id,name,country,privileges,total_score,pp,accuracy,max_combo,mods,mode,rank_namespace,submitted_at,client,mods_json,has_replay) AS (" ++
            "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.submitted_at,'stable',NULL,length(s.replay)>0 FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 JOIN users u ON u.id=s.user_id WHERE b.id=?1 AND s.mode=?2 AND s.rank_namespace=?4 AND s.passed=1 AND u.restricted=0 AND u.id!=3 AND (?3='all' OR ?3='stable' OR ?3='scorev2') UNION ALL " ++
            "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END,u.privileges,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.submitted_at,'lazer',s.mods_json,length(s.replay)>0 FROM lazer_scores s JOIN users u ON u.id=s.user_id WHERE s.beatmap_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?4 AND s.passed=1 AND u.restricted=0 AND u.id!=3 AND (?3='all' OR ?3='lazer'))," ++
            "per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN ?5=1 THEN pp ELSE total_score END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) user_place FROM candidates)," ++
            "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN ?5=1 THEN pp ELSE total_score END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) position FROM per_user WHERE user_place=1) " ++
            "SELECT position,id,user_id,name,country,privileges,total_score,pp,accuracy,max_combo,mods,rank_namespace,submitted_at,client,mods_json,has_replay FROM board ORDER BY position LIMIT 100";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, map_id);
        _ = c.sqlite3_bind_int(stmt, 2, score_mode);
        const source_name = @tagName(source);
        _ = c.sqlite3_bind_text(stmt, 3, source_name.ptr, @intCast(source_name.len), null);
        _ = c.sqlite3_bind_text(stmt, 4, namespace.ptr, @intCast(namespace.len), null);
        _ = c.sqlite3_bind_int(stmt, 5, @intFromBool(std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot")));
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"map_id\":{d},\"source\":\"{s}\",\"mode\":{d},\"namespace\":", .{ map_id, source_name, stats_mode });
        try jsonString(&output.writer, namespace);
        try output.writer.writeAll(",\"scores\":[");
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{{\"rank\":{d},\"id\":{d},\"user_id\":{d},\"name\":", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int64(stmt, 1), c.sqlite3_column_int(stmt, 2) });
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 4)));
            try output.writer.print(",\"privileges\":{d},\"score\":{d},\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"namespace\":", .{ c.sqlite3_column_int64(stmt, 5), c.sqlite3_column_int64(stmt, 6), c.sqlite3_column_double(stmt, 7), c.sqlite3_column_double(stmt, 8), c.sqlite3_column_int(stmt, 9), c.sqlite3_column_int(stmt, 10) });
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 11)));
            try output.writer.print(",\"submitted_at\":{d},\"client\":", .{c.sqlite3_column_int64(stmt, 12)});
            try jsonString(&output.writer, std.mem.span(c.sqlite3_column_text(stmt, 13)));
            try output.writer.writeAll(",\"mods_json\":");
            if (c.sqlite3_column_type(stmt, 14) == c.SQLITE_NULL) try output.writer.writeAll("null") else try output.writer.writeAll(std.mem.span(c.sqlite3_column_text(stmt, 14)));
            try output.writer.print(",\"has_replay\":{}}}", .{c.sqlite3_column_int(stmt, 15) != 0});
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return @as(?[]u8, try list.toOwnedSlice(allocator));
    }

    pub fn siteReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT s.id,u.name,s.map_md5,s.mode,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.score,s.max_combo,s.perfect,s.mods,s.submitted_at,s.replay FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1 AND s.passed=1 AND u.id!=3 AND u.restricted=0 AND s.replay IS NOT NULL AND length(s.replay)>0";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const replay_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 15));
        const replay_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 15));
        return @as(?[]u8, try site_replay.build(allocator, .{
            .score_id = c.sqlite3_column_int64(stmt, 0),
            .username = std.mem.span(c.sqlite3_column_text(stmt, 1)),
            .map_md5 = std.mem.span(c.sqlite3_column_text(stmt, 2)),
            .mode = @intCast(c.sqlite3_column_int(stmt, 3)),
            .n300 = c.sqlite3_column_int(stmt, 4),
            .n100 = c.sqlite3_column_int(stmt, 5),
            .n50 = c.sqlite3_column_int(stmt, 6),
            .ngeki = c.sqlite3_column_int(stmt, 7),
            .nkatu = c.sqlite3_column_int(stmt, 8),
            .nmiss = c.sqlite3_column_int(stmt, 9),
            .score = c.sqlite3_column_int64(stmt, 10),
            .max_combo = c.sqlite3_column_int(stmt, 11),
            .perfect = c.sqlite3_column_int(stmt, 12) != 0,
            .mods = c.sqlite3_column_int(stmt, 13),
            .submitted_at = c.sqlite3_column_int64(stmt, 14),
        }, replay_ptr[0..replay_len]));
    }

    pub fn lazerReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT s.replay FROM lazer_scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1 AND u.id!=3 AND u.restricted=0 AND s.replay IS NOT NULL AND length(s.replay)>0";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const replay_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        const replay_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return @as(?[]u8, try allocator.dupe(u8, replay_ptr[0..replay_len]));
    }

    fn upgradePassword(self: *Store, user_id: i32, password_md5: []const u8, previous_hash: []const u8) !void {
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "UPDATE users SET password_hash=?1,password_salt='argon2id' WHERE id=?2 AND password_hash=?3";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, hash.ptr, @intCast(hash.len), null);
        _ = c.sqlite3_bind_int(stmt, 2, user_id);
        _ = c.sqlite3_bind_blob(stmt, 3, previous_hash.ptr, @intCast(previous_hash.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn issueToken(self: *Store, user_id: i32, scopes: []const u8, lifetime_seconds: i64) ![64]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var raw: [32]u8 = undefined;
        try std.Io.randomSecure(self.io, &raw);
        var token: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{x}", .{raw}) catch unreachable;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&token, &digest, .{});
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const sql = "INSERT INTO oauth_tokens(token_hash,user_id,scopes,expires_at) VALUES(?1,?2,?3,?4)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
        _ = c.sqlite3_bind_int(stmt, 2, user_id);
        _ = c.sqlite3_bind_text(stmt, 3, scopes.ptr, @intCast(scopes.len), null);
        _ = c.sqlite3_bind_int64(stmt, 4, now + lifetime_seconds);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return token;
    }

    pub fn authenticateToken(self: *Store, allocator: std.mem.Allocator, token: []const u8, required_scope: []const u8) !?domain.User {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (token.len != 64) return null;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,t.scopes FROM oauth_tokens t JOIN users u ON u.id=t.user_id WHERE t.token_hash=?1 AND t.revoked_at IS NULL AND t.expires_at>?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
        _ = c.sqlite3_bind_int64(stmt, 2, std.Io.Clock.real.now(self.io).toSeconds());
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const scopes = std.mem.span(c.sqlite3_column_text(stmt, 7));
        var allowed = required_scope.len == 0;
        var it = std.mem.splitScalar(u8, scopes, ' ');
        while (it.next()) |scope| {
            if (std.mem.eql(u8, scope, required_scope) or std.mem.eql(u8, scope, "*")) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return null;
        const user_id = c.sqlite3_column_int(stmt, 0);
        const name = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        errdefer allocator.free(name);
        const safe = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)));
        errdefer allocator.free(safe);
        const cc = std.mem.span(c.sqlite3_column_text(stmt, 3));
        const user: domain.User = .{ .id = user_id, .name = name, .safe_name = safe, .country = .{ cc[0], cc[1] }, .privileges = @intCast(c.sqlite3_column_int64(stmt, 4)), .silence_end = c.sqlite3_column_int64(stmt, 5), .restricted = c.sqlite3_column_int(stmt, 6) != 0 };
        _ = c.sqlite3_finalize(stmt);
        stmt = null;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        var touch: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE oauth_tokens SET last_used_at=?1 WHERE token_hash=?2 AND (last_used_at IS NULL OR last_used_at<?3)", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(touch);
        _ = c.sqlite3_bind_int64(touch, 1, now);
        _ = c.sqlite3_bind_blob(touch, 2, &digest, digest.len, null);
        _ = c.sqlite3_bind_int64(touch, 3, now - 30);
        if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return user;
    }

    pub fn recentOauthUserIds(self: *Store, allocator: std.mem.Allocator, cutoff: i64) ![]i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "SELECT DISTINCT t.user_id FROM oauth_tokens t JOIN users u ON u.id=t.user_id WHERE t.last_used_at>=?1 AND t.revoked_at IS NULL AND t.expires_at>unixepoch() AND u.restricted=0 ORDER BY t.user_id";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, cutoff);
        var ids: std.ArrayList(i32) = .empty;
        errdefer ids.deinit(allocator);
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try ids.append(allocator, c.sqlite3_column_int(stmt, 0)),
            c.SQLITE_DONE => break,
            else => return error.DatabaseQueryFailed,
        };
        return ids.toOwnedSlice(allocator);
    }

    pub fn statsForUser(self: *Store, user_id: i32, mode: u8) !?domain.Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,(SELECT count(1)+1 FROM stats r JOIN users u ON u.id=r.user_id WHERE r.mode=s.mode AND u.restricted=0 AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))),(SELECT count(1)+1 FROM stats r JOIN users u ON u.id=r.user_id WHERE r.mode=s.mode AND u.restricted=0 AND u.country=me.country AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM stats s JOIN users me ON me.id=s.user_id WHERE s.user_id=?1 AND s.mode=?2";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, mode);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        var stats: domain.Stats = .{
            .mode = @enumFromInt(mode % 4),
            .ranked_score = c.sqlite3_column_int64(stmt, 0),
            .total_score = c.sqlite3_column_int64(stmt, 1),
            .pp = c.sqlite3_column_int(stmt, 2),
            .plays = c.sqlite3_column_int(stmt, 3),
            .play_time = c.sqlite3_column_int(stmt, 4),
            .total_hits = c.sqlite3_column_int64(stmt, 5),
            .accuracy = c.sqlite3_column_double(stmt, 6),
            .max_combo = c.sqlite3_column_int(stmt, 7),
            .global_rank = c.sqlite3_column_int(stmt, 8),
            .country_rank = c.sqlite3_column_int(stmt, 9),
        };
        var stable: ?*c.sqlite3_stmt = null;
        const stable_sql = "SELECT s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)";
        if (c.sqlite3_prepare_v2(self.db, stable_sql, -1, &stable, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stable);
        _ = c.sqlite3_bind_int(stable, 1, user_id);
        _ = c.sqlite3_bind_int(stable, 2, mode);
        while (c.sqlite3_step(stable) == c.SQLITE_ROW) stats.addGrade(stableGrade(mode, c.sqlite3_column_int(stable, 0), c.sqlite3_column_double(stable, 1), c.sqlite3_column_int(stable, 2), c.sqlite3_column_int(stable, 3), c.sqlite3_column_int(stable, 4), c.sqlite3_column_int(stable, 5)));
        var modern: ?*c.sqlite3_stmt = null;
        const modern_sql = "SELECT s.rank FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)";
        if (c.sqlite3_prepare_v2(self.db, modern_sql, -1, &modern, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(modern);
        _ = c.sqlite3_bind_int(modern, 1, user_id);
        _ = c.sqlite3_bind_int(modern, 2, mode);
        while (c.sqlite3_step(modern) == c.SQLITE_ROW) stats.addGrade(std.mem.span(c.sqlite3_column_text(modern, 0)));
        return stats;
    }

    pub fn sourceStatsForUser(self: *Store, user_id: i32, mode: u8, source: domain.SiteScoreSource) !?domain.Stats {
        if (source != .stable and source != .lazer) return error.InvalidScoreSource;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stable_sql =
            "WITH source_scores AS (SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.time_elapsed/1000 play_time,b.status,b.id beatmap_id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.mode=?2 AND s.rank_namespace='vanilla')," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
            "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
            "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=?1";
        const lazer_sql =
            "WITH source_scores AS (SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,max(b.total_length,0) play_time,b.status,s.beatmap_id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=?2 AND s.rank_namespace='vanilla')," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed=1 AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*pow(0.95,performance_index))+416.6667*(1-pow(0.9994,count(*)))) pp,sum(accuracy*pow(0.95,performance_index))/(20*(1-pow(0.95,count(*)))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed=1 AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
            "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND u.restricted=0)," ++
            "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, if (source == .stable) stable_sql else lazer_sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, mode);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .mode = @enumFromInt(mode % 4),
            .ranked_score = c.sqlite3_column_int64(stmt, 0),
            .total_score = c.sqlite3_column_int64(stmt, 1),
            .pp = c.sqlite3_column_int(stmt, 2),
            .plays = c.sqlite3_column_int(stmt, 3),
            .play_time = c.sqlite3_column_int(stmt, 4),
            .accuracy = c.sqlite3_column_double(stmt, 5),
            .max_combo = c.sqlite3_column_int(stmt, 6),
            .global_rank = c.sqlite3_column_int(stmt, 7),
        };
    }

    pub fn revokeToken(self: *Store, token: []const u8) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (token.len != 64) return false;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const sql = "UPDATE oauth_tokens SET revoked_at=unixepoch() WHERE token_hash=?1 AND revoked_at IS NULL";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_blob(stmt, 1, &digest, digest.len, null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    pub fn lazerUserScoreCounts(self: *Store, user_id: i32, ruleset_id: u8, source: domain.SiteScoreSource) !domain.UserScoreCounts {
        if (source == .scorev2) return error.InvalidScoreSource;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql =
            "SELECT " ++
            "(SELECT count(*) FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE ?3!='stable' AND s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4))+(SELECT count(*) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE ?3!='lazer' AND s.user_id=?1 AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4))," ++
            "(SELECT count(*) FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE ?3!='stable' AND s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM lazer_scores o JOIN users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed=1 AND o.best=1 AND ou.restricted=0 AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id))))+(SELECT count(*) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE ?3!='lazer' AND s.user_id=?1 AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM scores o JOIN users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed=1 AND o.best=1 AND ou.restricted=0 AND (o.score>s.score OR (o.score=s.score AND o.id<s.id))))," ++
            "(SELECT count(*) FROM lazer_scores WHERE ?3!='stable' AND user_id=?1 AND ruleset_id=?2)+(SELECT count(*) FROM scores WHERE ?3!='lazer' AND user_id=?1 AND mode=?2)," ++
            "(SELECT count(*) FROM score_pins p JOIN scores s ON s.id=p.score_id WHERE ?3!='lazer' AND p.user_id=?1 AND s.mode=?2)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
        const source_name = @tagName(source);
        _ = c.sqlite3_bind_text(stmt, 3, source_name.ptr, @intCast(source_name.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return .{
            .best = c.sqlite3_column_int(stmt, 0),
            .firsts = c.sqlite3_column_int(stmt, 1),
            .recent = c.sqlite3_column_int(stmt, 2),
            .pinned = c.sqlite3_column_int(stmt, 3),
        };
    }

    pub fn lazerUserScoresJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8, kind: lazer.UserScoreKind, source: domain.SiteScoreSource, offset: u16, limit: u8) ![]u8 {
        if (limit == 0 or limit > 100) return error.InvalidScoreLimit;
        if (source == .scorev2) return error.InvalidScoreSource;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const filters = switch (kind) {
            .best => .{
                "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)",
                "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4)",
                "pp DESC,submitted_epoch DESC,id DESC",
            },
            .firsts => .{
                "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM lazer_scores o JOIN users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed=1 AND o.best=1 AND ou.restricted=0 AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id)))",
                "AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM scores o JOIN users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed=1 AND o.best=1 AND ou.restricted=0 AND (o.score>s.score OR (o.score=s.score AND o.id<s.id)))",
                "submitted_epoch DESC,id DESC",
            },
            .recent => .{ "", "", "submitted_epoch DESC,id DESC" },
            .pinned => .{
                "AND 0",
                "AND EXISTS(SELECT 1 FROM score_pins p WHERE p.user_id=s.user_id AND p.score_id=s.id)",
                "submitted_epoch DESC,id DESC",
            },
        };
        const sql = try std.fmt.allocPrint(allocator,
            \\SELECT * FROM (
            \\SELECT 'lazer' source,s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,coalesce(s.legacy_total_score,s.total_score) total_without,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json,s.statistics_json,s.maximum_statistics_json,s.pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,length(s.replay)>0 has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,0 perfect
            \\FROM lazer_scores s JOIN users u ON u.id=s.user_id JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 {s} {s}
            \\UNION ALL
            \\SELECT 'stable' source,4000000000000000000+s.id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,s.pp,s.accuracy,s.max_combo,s.passed,'' rank,'[]' mods_json,'{{}}' statistics_json,'{{}}' maximum_statistics_json,'[]' pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,length(s.replay)>0 has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect
            \\FROM scores s JOIN users u ON u.id=s.user_id JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 {s} {s}
            \\) ORDER BY {s} LIMIT ?3 OFFSET ?4
        , .{ filters[0], if (source == .stable) "AND 0" else "", filters[1], if (source == .lazer) "AND 0" else "", filters[2] });
        defer allocator.free(sql);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
        _ = c.sqlite3_bind_int(stmt, 3, limit);
        _ = c.sqlite3_bind_int(stmt, 4, offset);

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var written: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            const stable = std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)), "stable");
            const status = c.sqlite3_column_int(stmt, 20);
            const namespace_name = std.mem.span(c.sqlite3_column_text(stmt, 29));
            var mods: std.Io.Writer.Allocating = .init(allocator);
            defer mods.deinit();
            var statistics: std.Io.Writer.Allocating = .init(allocator);
            defer statistics.deinit();
            if (stable) {
                try stable_mods.writeLazerJson(&mods.writer, c.sqlite3_column_int(stmt, 31), true);
                try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, c.sqlite3_column_int(stmt, 32), c.sqlite3_column_int(stmt, 33), c.sqlite3_column_int(stmt, 34), c.sqlite3_column_int(stmt, 35), c.sqlite3_column_int(stmt, 36), c.sqlite3_column_int(stmt, 37));
            }
            try lazer.writeLeaderboardScore(&output.writer, .{
                .id = c.sqlite3_column_int64(stmt, 1),
                .user_id = c.sqlite3_column_int(stmt, 2),
                .username = std.mem.span(c.sqlite3_column_text(stmt, 3)),
                .country = std.mem.span(c.sqlite3_column_text(stmt, 4)),
                .beatmap_id = c.sqlite3_column_int(stmt, 5),
                .ruleset_id = c.sqlite3_column_int(stmt, 6),
                .total_score = c.sqlite3_column_int64(stmt, 7),
                .total_score_without_mods = c.sqlite3_column_int64(stmt, 8),
                .pp = c.sqlite3_column_double(stmt, 9),
                .accuracy = c.sqlite3_column_double(stmt, 10),
                .max_combo = c.sqlite3_column_int(stmt, 11),
                .passed = c.sqlite3_column_int(stmt, 12) != 0,
                .rank = if (stable) stableGrade(ruleset_id, c.sqlite3_column_int(stmt, 31), c.sqlite3_column_double(stmt, 10), c.sqlite3_column_int(stmt, 32), c.sqlite3_column_int(stmt, 33), c.sqlite3_column_int(stmt, 34), c.sqlite3_column_int(stmt, 37)) else std.mem.span(c.sqlite3_column_text(stmt, 13)),
                .mods_json = if (stable) mods.written() else std.mem.span(c.sqlite3_column_text(stmt, 14)),
                .statistics_json = if (stable) statistics.written() else std.mem.span(c.sqlite3_column_text(stmt, 15)),
                .maximum_statistics_json = std.mem.span(c.sqlite3_column_text(stmt, 16)),
                .pauses_json = std.mem.span(c.sqlite3_column_text(stmt, 17)),
                .ended_at = std.mem.span(c.sqlite3_column_text(stmt, 18)),
                .ranked = (status == 3 or status == 4) and std.mem.eql(u8, namespace_name, "vanilla"),
                .has_replay = c.sqlite3_column_int(stmt, 30) != 0,
                .beatmap = .{
                    .id = c.sqlite3_column_int(stmt, 5),
                    .set_id = c.sqlite3_column_int(stmt, 21),
                    .status = lazerStatus(status),
                    .checksum = std.mem.span(c.sqlite3_column_text(stmt, 22)),
                    .ruleset_id = c.sqlite3_column_int(stmt, 23),
                    .star_rating = c.sqlite3_column_double(stmt, 24),
                    .version = std.mem.span(c.sqlite3_column_text(stmt, 25)),
                    .artist = std.mem.span(c.sqlite3_column_text(stmt, 26)),
                    .title = std.mem.span(c.sqlite3_column_text(stmt, 27)),
                    .creator = std.mem.span(c.sqlite3_column_text(stmt, 28)),
                },
            });
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    fn stableClassicLeaderboardJsonLocked(self: *Store, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, limit: u8) ![]u8 {
        const sql =
            "WITH ordered AS (" ++
            "SELECT s.*,b.status,b.set_id,b.id beatmap_id,b.star_rating,b.version,b.artist,b.title,b.creator,row_number() OVER(PARTITION BY s.user_id ORDER BY s.score DESC,s.id ASC) AS user_place " ++
            "FROM scores s JOIN users u ON u.id=s.user_id JOIN beatmaps b ON b.md5=s.map_md5 " ++
            "WHERE b.id=?1 AND s.mode=?2 AND s.rank_namespace='vanilla' AND s.passed=1 AND s.best=1 AND u.restricted=0)," ++
            "board AS (SELECT *,row_number() OVER(ORDER BY score DESC,id ASC) AS position,count(*) OVER() AS score_count FROM ordered WHERE user_place=1) " ++
            "SELECT position,score_count,id,user_id,(SELECT name FROM users WHERE id=board.user_id),(SELECT country FROM users WHERE id=board.user_id),beatmap_id,mode,score,pp,accuracy,max_combo,n300,n100,n50,ngeki,nkatu,nmiss,perfect,mods,strftime('%Y-%m-%dT%H:%M:%SZ',submitted_at,'unixepoch'),status,set_id,map_md5,star_rating,version,artist,title,creator " ++
            "FROM board WHERE position<=?3 OR user_id=?4 ORDER BY position";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, beatmap_id);
        _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
        _ = c.sqlite3_bind_int(stmt, 3, limit);
        _ = c.sqlite3_bind_int(stmt, 4, requester_id);

        var scores: std.Io.Writer.Allocating = .init(allocator);
        defer scores.deinit();
        var user_score: ?[]u8 = null;
        defer if (user_score) |json| allocator.free(json);
        var score_count: i64 = 0;
        var written: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const position = c.sqlite3_column_int64(stmt, 0);
            score_count = c.sqlite3_column_int64(stmt, 1);
            var mods: std.Io.Writer.Allocating = .init(allocator);
            defer mods.deinit();
            try stable_mods.writeLazerJson(&mods.writer, c.sqlite3_column_int(stmt, 19), true);
            var statistics: std.Io.Writer.Allocating = .init(allocator);
            defer statistics.deinit();
            try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 13), c.sqlite3_column_int(stmt, 14), c.sqlite3_column_int(stmt, 15), c.sqlite3_column_int(stmt, 16), c.sqlite3_column_int(stmt, 17));
            const score: lazer.LeaderboardScore = .{
                .id = c.sqlite3_column_int64(stmt, 2),
                .user_id = c.sqlite3_column_int(stmt, 3),
                .username = std.mem.span(c.sqlite3_column_text(stmt, 4)),
                .country = std.mem.span(c.sqlite3_column_text(stmt, 5)),
                .beatmap_id = c.sqlite3_column_int(stmt, 6),
                .ruleset_id = c.sqlite3_column_int(stmt, 7),
                .total_score = c.sqlite3_column_int64(stmt, 8),
                .total_score_without_mods = c.sqlite3_column_int64(stmt, 8),
                .pp = c.sqlite3_column_double(stmt, 9),
                .accuracy = c.sqlite3_column_double(stmt, 10),
                .max_combo = c.sqlite3_column_int(stmt, 11),
                .passed = true,
                .rank = stableGrade(ruleset_id, c.sqlite3_column_int(stmt, 19), c.sqlite3_column_double(stmt, 10), c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 13), c.sqlite3_column_int(stmt, 14), c.sqlite3_column_int(stmt, 17)),
                .mods_json = mods.written(),
                .statistics_json = statistics.written(),
                .maximum_statistics_json = "{}",
                .pauses_json = "[]",
                .ended_at = std.mem.span(c.sqlite3_column_text(stmt, 20)),
                .ranked = c.sqlite3_column_int(stmt, 21) == 3 or c.sqlite3_column_int(stmt, 21) == 4,
                .has_replay = false,
                .beatmap = .{
                    .id = c.sqlite3_column_int(stmt, 6),
                    .set_id = c.sqlite3_column_int(stmt, 22),
                    .status = lazerStatus(c.sqlite3_column_int(stmt, 21)),
                    .checksum = std.mem.span(c.sqlite3_column_text(stmt, 23)),
                    .ruleset_id = ruleset_id,
                    .star_rating = c.sqlite3_column_double(stmt, 24),
                    .version = std.mem.span(c.sqlite3_column_text(stmt, 25)),
                    .artist = std.mem.span(c.sqlite3_column_text(stmt, 26)),
                    .title = std.mem.span(c.sqlite3_column_text(stmt, 27)),
                    .creator = std.mem.span(c.sqlite3_column_text(stmt, 28)),
                },
            };
            if (position <= limit) {
                if (written != 0) try scores.writer.writeByte(',');
                try lazer.writeLeaderboardScore(&scores.writer, score);
                written += 1;
            }
            if (score.user_id == requester_id) {
                var own: std.Io.Writer.Allocating = .init(allocator);
                errdefer own.deinit();
                try own.writer.print("{{\"position\":{d},\"score\":", .{position});
                try lazer.writeLeaderboardScore(&own.writer, score);
                try own.writer.writeByte('}');
                user_score = try own.toOwnedSlice();
            }
        }
        const score_rows_json = try scores.toOwnedSlice();
        defer allocator.free(score_rows_json);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"score_count\":{d},\"scores\":[", .{score_count});
        try output.writer.writeAll(score_rows_json);
        try output.writer.writeAll("],\"user_score\":");
        if (user_score) |json| try output.writer.writeAll(json) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    pub fn lazerLeaderboardJson(self: *Store, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, exact_mods_json: []const u8, filter_mods: bool, classic: bool, requested_stable_mods: ?i32, limit: u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql =
            "WITH candidates AS (" ++
            "SELECT 'lazer' source,s.id source_id,s.id public_id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,coalesce(s.legacy_total_score,s.total_score) total_without,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json,s.statistics_json,s.maximum_statistics_json,s.pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch') ended_at,b.status,length(s.replay)>0 has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,0 perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,1 source_order " ++
            "FROM lazer_scores s JOIN users u ON u.id=s.user_id JOIN beatmaps b ON b.id=s.beatmap_id " ++
            "WHERE s.beatmap_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND u.restricted=0 AND ?6=0 " ++
            "AND (?5=0 OR (" ++
            "NOT EXISTS(SELECT upper(json_extract(stored.value,'$.acronym')) FROM json_each(s.mods_json) stored WHERE ?3!='custom' OR upper(json_extract(stored.value,'$.acronym')) NOT IN('RX','AP') EXCEPT SELECT upper(value) FROM json_each(?4) WHERE ?3!='custom' OR upper(value) NOT IN('RX','AP')) " ++
            "AND NOT EXISTS(SELECT upper(value) FROM json_each(?4) WHERE ?3!='custom' OR upper(value) NOT IN('RX','AP') EXCEPT SELECT upper(json_extract(stored.value,'$.acronym')) FROM json_each(s.mods_json) stored WHERE ?3!='custom' OR upper(json_extract(stored.value,'$.acronym')) NOT IN('RX','AP')))) " ++
            "UNION ALL " ++
            "SELECT 'stable' source,s.id source_id,4000000000000000000+s.id public_id,s.user_id,u.name,CASE WHEN u.show_country=1 THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,s.pp,s.accuracy,s.max_combo,s.passed,'' rank,'[]' mods_json,'{}' statistics_json,'{}' maximum_statistics_json,'[]' pauses_json,strftime('%Y-%m-%dT%H:%M:%SZ',s.submitted_at,'unixepoch') ended_at,b.status,length(s.replay)>0 has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,0 source_order " ++
            "FROM scores s JOIN users u ON u.id=s.user_id JOIN beatmaps b ON b.md5=s.map_md5 " ++
            "WHERE b.id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND u.restricted=0 AND ?3!='custom' AND ?7=1 AND (?5=0 OR s.mods=?8))," ++
            "ordered AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN rank_namespace IN('relax','autopilot') THEN pp ELSE total_score END DESC,source_order,source_id) user_place FROM candidates)," ++
            "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN rank_namespace IN('relax','autopilot') THEN pp ELSE total_score END DESC,source_order,source_id) position,count(*) OVER() score_count FROM ordered WHERE user_place=1) " ++
            "SELECT position,score_count,source,public_id,user_id,name,country,beatmap_id,ruleset_id,total_score,total_without,pp,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,ended_at,status,has_replay,stable_mods,n300,n100,n50,ngeki,nkatu,nmiss,perfect,set_id,md5,map_mode,star_rating,version,artist,title,creator,rank_namespace " ++
            "FROM board WHERE position<=?9 OR user_id=?10 ORDER BY position";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, beatmap_id);
        _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
        const namespace_name = @tagName(namespace);
        _ = c.sqlite3_bind_text(stmt, 3, namespace_name.ptr, @intCast(namespace_name.len), null);
        _ = c.sqlite3_bind_text(stmt, 4, exact_mods_json.ptr, @intCast(exact_mods_json.len), null);
        _ = c.sqlite3_bind_int(stmt, 5, @intFromBool(filter_mods));
        _ = c.sqlite3_bind_int(stmt, 6, @intFromBool(classic));
        _ = c.sqlite3_bind_int(stmt, 7, @intFromBool(requested_stable_mods != null));
        _ = c.sqlite3_bind_int(stmt, 8, requested_stable_mods orelse 0);
        _ = c.sqlite3_bind_int(stmt, 9, limit);
        _ = c.sqlite3_bind_int(stmt, 10, requester_id);

        var scores: std.Io.Writer.Allocating = .init(allocator);
        defer scores.deinit();
        var user_score: ?[]u8 = null;
        defer if (user_score) |json| allocator.free(json);
        var score_count: i64 = 0;
        var written: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const position = c.sqlite3_column_int64(stmt, 0);
            score_count = c.sqlite3_column_int64(stmt, 1);
            const stable = std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)), "stable");
            var mods: std.Io.Writer.Allocating = .init(allocator);
            defer mods.deinit();
            var statistics: std.Io.Writer.Allocating = .init(allocator);
            defer statistics.deinit();
            if (stable) {
                try stable_mods.writeLazerJson(&mods.writer, c.sqlite3_column_int(stmt, 23), true);
                try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, c.sqlite3_column_int(stmt, 24), c.sqlite3_column_int(stmt, 25), c.sqlite3_column_int(stmt, 26), c.sqlite3_column_int(stmt, 27), c.sqlite3_column_int(stmt, 28), c.sqlite3_column_int(stmt, 29));
            }
            const score: lazer.LeaderboardScore = .{
                .id = c.sqlite3_column_int64(stmt, 3),
                .user_id = c.sqlite3_column_int(stmt, 4),
                .username = std.mem.span(c.sqlite3_column_text(stmt, 5)),
                .country = std.mem.span(c.sqlite3_column_text(stmt, 6)),
                .beatmap_id = c.sqlite3_column_int(stmt, 7),
                .ruleset_id = c.sqlite3_column_int(stmt, 8),
                .total_score = c.sqlite3_column_int64(stmt, 9),
                .total_score_without_mods = c.sqlite3_column_int64(stmt, 10),
                .pp = c.sqlite3_column_double(stmt, 11),
                .accuracy = c.sqlite3_column_double(stmt, 12),
                .max_combo = c.sqlite3_column_int(stmt, 13),
                .passed = c.sqlite3_column_int(stmt, 14) != 0,
                .rank = if (stable) stableGrade(ruleset_id, c.sqlite3_column_int(stmt, 23), c.sqlite3_column_double(stmt, 12), c.sqlite3_column_int(stmt, 24), c.sqlite3_column_int(stmt, 25), c.sqlite3_column_int(stmt, 26), c.sqlite3_column_int(stmt, 29)) else std.mem.span(c.sqlite3_column_text(stmt, 15)),
                .mods_json = if (stable) mods.written() else std.mem.span(c.sqlite3_column_text(stmt, 16)),
                .statistics_json = if (stable) statistics.written() else std.mem.span(c.sqlite3_column_text(stmt, 17)),
                .maximum_statistics_json = std.mem.span(c.sqlite3_column_text(stmt, 18)),
                .pauses_json = std.mem.span(c.sqlite3_column_text(stmt, 19)),
                .ended_at = std.mem.span(c.sqlite3_column_text(stmt, 20)),
                .ranked = (c.sqlite3_column_int(stmt, 21) == 3 or c.sqlite3_column_int(stmt, 21) == 4) and namespace == .vanilla,
                .has_replay = c.sqlite3_column_int(stmt, 22) != 0,
                .beatmap = .{
                    .id = c.sqlite3_column_int(stmt, 7),
                    .set_id = c.sqlite3_column_int(stmt, 31),
                    .status = lazerStatus(c.sqlite3_column_int(stmt, 21)),
                    .checksum = std.mem.span(c.sqlite3_column_text(stmt, 32)),
                    .ruleset_id = c.sqlite3_column_int(stmt, 33),
                    .star_rating = c.sqlite3_column_double(stmt, 34),
                    .version = std.mem.span(c.sqlite3_column_text(stmt, 35)),
                    .artist = std.mem.span(c.sqlite3_column_text(stmt, 36)),
                    .title = std.mem.span(c.sqlite3_column_text(stmt, 37)),
                    .creator = std.mem.span(c.sqlite3_column_text(stmt, 38)),
                },
            };
            if (position <= limit) {
                if (written != 0) try scores.writer.writeByte(',');
                try lazer.writeLeaderboardScore(&scores.writer, score);
                written += 1;
            }
            if (score.user_id == requester_id) {
                var own: std.Io.Writer.Allocating = .init(allocator);
                errdefer own.deinit();
                try own.writer.print("{{\"position\":{d},\"score\":", .{position});
                try lazer.writeLeaderboardScore(&own.writer, score);
                try own.writer.writeByte('}');
                user_score = try own.toOwnedSlice();
            }
        }

        const score_rows_json = try scores.toOwnedSlice();
        defer allocator.free(score_rows_json);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"score_count\":{d},\"scores\":[", .{score_count});
        try output.writer.writeAll(score_rows_json);
        try output.writer.writeAll("],\"user_score\":");
        if (user_score) |json| try output.writer.writeAll(json) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
    }

    fn awardAchievementsLocked(self: *Store, user_id: i32, source: []const u8, score_id: i64, input: achievements.Input) !void {
        const candidates = achievements.candidates(input);
        if (candidates.len == 0) return;
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT OR IGNORE INTO user_achievements(user_id,achievement_id,score_source,score_id) SELECT ?1,?2,?3,?4 WHERE EXISTS(SELECT 1 FROM users WHERE id=?1 AND restricted=0)";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        for (candidates.slice()) |achievement_id| {
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);
            _ = c.sqlite3_bind_int(stmt, 1, user_id);
            _ = c.sqlite3_bind_int(stmt, 2, achievement_id);
            _ = c.sqlite3_bind_text(stmt, 3, source.ptr, @intCast(source.len), null);
            _ = c.sqlite3_bind_int64(stmt, 4, score_id);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }
    }

    fn writeUserAchievementsLocked(self: *Store, writer: *std.Io.Writer, user_id: i32, include_metadata: bool) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT achievement_id,achieved_at FROM user_achievements WHERE user_id=?1 ORDER BY achieved_at,achievement_id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        try writer.writeByte('[');
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id: u8 = @intCast(c.sqlite3_column_int(stmt, 0));
            if (achievements.byId(id) == null) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try achievements.writeJson(writer, id, c.sqlite3_column_int64(stmt, 1), include_metadata);
        }
        try writer.writeByte(']');
    }

    pub fn lazerUserAchievementsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try self.writeUserAchievementsLocked(&output.writer, user_id, true);
        return output.toOwnedSlice();
    }

    pub fn newAchievementsForScore(self: *Store, source: []const u8, score_id: i64) !achievements.Unlocks {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT achievement_id FROM user_achievements WHERE score_source=?1 AND score_id=?2 ORDER BY achievement_id", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, source.ptr, @intCast(source.len), null);
        _ = c.sqlite3_bind_int64(stmt, 2, score_id);
        var result: achievements.Unlocks = .{};
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) result.append(@intCast(c.sqlite3_column_int(stmt, 0)));
        return result;
    }

    pub fn insertLazerScore(self: *Store, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const score_id = try self.insertLazerScoreLocked(user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
        try self.exec("COMMIT");
        return score_id;
    }

    fn insertLazerScoreLocked(self: *Store, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        const namespace = @tagName(input.namespace);
        const rank = input.rank orelse if (input.passed) "D" else "F";
        var previous_best_id: i64 = 0;
        var previous_pp: f64 = 0;
        var previous_score: i64 = 0;
        var previous: ?*c.sqlite3_stmt = null;
        const previous_sql = "SELECT id,pp,total_score FROM lazer_scores WHERE user_id=?1 AND beatmap_id=?2 AND ruleset_id=?3 AND rank_namespace=?4 AND best=1 LIMIT 1";
        if (c.sqlite3_prepare_v2(self.db, previous_sql, -1, &previous, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(previous, 1, user_id);
        _ = c.sqlite3_bind_int64(previous, 2, input.beatmap_id);
        _ = c.sqlite3_bind_int64(previous, 3, input.ruleset_id);
        _ = c.sqlite3_bind_text(previous, 4, namespace.ptr, @intCast(namespace.len), null);
        if (c.sqlite3_step(previous) == c.SQLITE_ROW) {
            previous_best_id = c.sqlite3_column_int64(previous, 0);
            previous_pp = c.sqlite3_column_double(previous, 1);
            previous_score = c.sqlite3_column_int64(previous, 2);
        }
        _ = c.sqlite3_finalize(previous);
        const is_best = input.passed and (previous_best_id == 0 or pp_value > previous_pp or (pp_value == previous_pp and input.total_score > previous_score));
        const sql = "INSERT INTO lazer_scores(user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,client_version,pp,best,replay,star_rating) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int64(stmt, 2, input.beatmap_id);
        _ = c.sqlite3_bind_int64(stmt, 3, input.ruleset_id);
        _ = c.sqlite3_bind_int64(stmt, 4, input.total_score);
        if (input.legacy_total_score) |n| _ = c.sqlite3_bind_int64(stmt, 5, n) else _ = c.sqlite3_bind_null(stmt, 5);
        _ = c.sqlite3_bind_double(stmt, 6, input.accuracy);
        _ = c.sqlite3_bind_int64(stmt, 7, input.max_combo);
        _ = c.sqlite3_bind_int(stmt, 8, @intFromBool(input.passed));
        _ = c.sqlite3_bind_text(stmt, 9, rank.ptr, @intCast(rank.len), null);
        _ = c.sqlite3_bind_text(stmt, 10, mods_json.ptr, @intCast(mods_json.len), null);
        _ = c.sqlite3_bind_text(stmt, 11, statistics_json.ptr, @intCast(statistics_json.len), null);
        _ = c.sqlite3_bind_text(stmt, 12, maximum_statistics_json.ptr, @intCast(maximum_statistics_json.len), null);
        _ = c.sqlite3_bind_text(stmt, 13, pauses_json.ptr, @intCast(pauses_json.len), null);
        _ = c.sqlite3_bind_text(stmt, 14, namespace.ptr, @intCast(namespace.len), null);
        if (input.client_version) |version| {
            _ = c.sqlite3_bind_text(stmt, 15, version.ptr, @intCast(version.len), null);
        } else _ = c.sqlite3_bind_null(stmt, 15);
        _ = c.sqlite3_bind_double(stmt, 16, pp_value);
        _ = c.sqlite3_bind_int(stmt, 17, @intFromBool(is_best));
        if (replay_data.len == 0)
            _ = c.sqlite3_bind_null(stmt, 18)
        else
            _ = c.sqlite3_bind_blob(stmt, 18, replay_data.ptr, @intCast(replay_data.len), null);
        _ = c.sqlite3_bind_double(stmt, 19, input.achievement_stars);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const score_id = c.sqlite3_last_insert_rowid(self.db);
        if (is_best and previous_best_id != 0) {
            var unset: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE lazer_scores SET best=0 WHERE id=?1", -1, &unset, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(unset);
            _ = c.sqlite3_bind_int64(unset, 1, previous_best_id);
            if (c.sqlite3_step(unset) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }
        try self.updateLazerStatsLocked(user_id, input);
        var map: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT status FROM beatmaps WHERE id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map);
        _ = c.sqlite3_bind_int64(map, 1, input.beatmap_id);
        const ranked = c.sqlite3_step(map) == c.SQLITE_ROW and (c.sqlite3_column_int(map, 0) == 3 or c.sqlite3_column_int(map, 0) == 4);
        try self.awardAchievementsLocked(user_id, "lazer", score_id, .{
            .eligible = input.passed and input.namespace == .vanilla and ranked,
            .mode = @intCast(input.ruleset_id),
            .mods = input.achievement_mods,
            .perfect = input.achievement_perfect,
            .max_combo = @intCast(input.max_combo),
            .stars = input.achievement_stars,
            .accuracy = input.accuracy,
            .pp = pp_value,
        });
        return score_id;
    }

    fn updateLazerStatsLocked(self: *Store, user_id: i32, input: lazer.ScoreInput) !void {
        const stats_mode = lazer.statsMode(input) orelse return;
        var map: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT md5,status,max(total_length,0) FROM beatmaps WHERE id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map);
        _ = c.sqlite3_bind_int64(map, 1, input.beatmap_id);
        if (c.sqlite3_step(map) != c.SQLITE_ROW) return;
        const map_status = c.sqlite3_column_int(map, 1);
        const play_time = c.sqlite3_column_int64(map, 2);
        const namespace = @tagName(input.namespace);
        const legacy_score = input.legacy_total_score orelse input.total_score;
        const hits = lazer.totalHits(input);

        var update: ?*c.sqlite3_stmt = null;
        const update_sql = "UPDATE stats SET total_score=total_score+?1,ranked_score=ranked_score+?2,plays=plays+1,play_time=play_time+?3,total_hits=total_hits+?4,max_combo=CASE WHEN ?5=1 THEN max(max_combo,?6) ELSE max_combo END WHERE user_id=?7 AND mode=?8";
        if (c.sqlite3_prepare_v2(self.db, update_sql, -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(update);
        _ = c.sqlite3_bind_int64(update, 1, legacy_score);
        _ = c.sqlite3_bind_int64(update, 2, 0);
        _ = c.sqlite3_bind_int64(update, 3, play_time);
        _ = c.sqlite3_bind_int64(update, 4, hits);
        _ = c.sqlite3_bind_int(update, 5, @intFromBool(input.passed and map_status >= 3));
        _ = c.sqlite3_bind_int64(update, 6, input.max_combo);
        _ = c.sqlite3_bind_int(update, 7, user_id);
        _ = c.sqlite3_bind_int(update, 8, stats_mode);
        if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;

        var map_update: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmaps SET plays=plays+1,passes=passes+?1 WHERE id=?2", -1, &map_update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_update);
        _ = c.sqlite3_bind_int(map_update, 1, @intFromBool(input.passed));
        _ = c.sqlite3_bind_int64(map_update, 2, input.beatmap_id);
        if (c.sqlite3_step(map_update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (input.passed and (map_status == 3 or map_status == 4)) try self.rebuildCombinedPerformanceLocked(user_id, @intCast(input.ruleset_id), stats_mode, namespace);
    }

    fn rebuildCombinedPerformanceLocked(self: *Store, user_id: i32, ruleset_id: u8, stats_mode: u8, namespace: []const u8) !void {
        const sql =
            "WITH candidates AS (" ++
            "SELECT b.id beatmap_id,s.pp,s.accuracy,s.score legacy_score,0 source,s.id score_id FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4) " ++
            "UNION ALL SELECT s.beatmap_id,s.pp,s.accuracy,coalesce(s.legacy_total_score,s.total_score),1,s.id FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=?1 AND s.ruleset_id=?2 AND s.rank_namespace=?3 AND s.passed=1 AND b.status IN(3,4))," ++
            "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id ORDER BY pp DESC,source ASC,score_id ASC) map_place FROM candidates) " ++
            "SELECT pp,accuracy,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_id ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_int(stmt, 2, ruleset_id);
        _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
        var total_pp: f64 = 0;
        var weighted_accuracy: f64 = 0;
        var weight: f64 = 1;
        var score_count: u32 = 0;
        var ranked_score: i64 = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            total_pp += c.sqlite3_column_double(stmt, 0) * weight;
            weighted_accuracy += c.sqlite3_column_double(stmt, 1) * weight;
            ranked_score += c.sqlite3_column_int64(stmt, 2);
            weight *= 0.95;
            score_count += 1;
        }
        const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
        const accuracy = if (score_count == 0) 0 else weighted_accuracy / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count))));
        var update: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "UPDATE stats SET pp=?1,accuracy=?2,ranked_score=?3 WHERE user_id=?4 AND mode=?5", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(update);
        _ = c.sqlite3_bind_int64(update, 1, @intFromFloat(@round(total_pp + bonus_pp)));
        _ = c.sqlite3_bind_double(update, 2, accuracy);
        _ = c.sqlite3_bind_int64(update, 3, ranked_score);
        _ = c.sqlite3_bind_int(update, 4, user_id);
        _ = c.sqlite3_bind_int(update, 5, stats_mode);
        if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn createLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
        var random_bytes: [8]u8 = undefined;
        try std.Io.randomSecure(self.io, &random_bytes);
        const token_id: i64 = @intCast((std.mem.readInt(u64, &random_bytes, .little) & std.math.maxInt(i64)) | 1);
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        {
            var map: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT md5 FROM beatmaps WHERE id=?1", -1, &map, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(map);
            _ = c.sqlite3_bind_int(map, 1, beatmap_id);
            if (c.sqlite3_step(map) != c.SQLITE_ROW) return error.BeatmapNotFound;
            if (!std.ascii.eqlIgnoreCase(std.mem.span(c.sqlite3_column_text(map, 0)), beatmap_hash)) return error.BeatmapHashMismatch;
        }

        var prune: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM lazer_score_tokens WHERE expires_at<?1 OR (consumed_at IS NOT NULL AND consumed_at<?2)", -1, &prune, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int64(prune, 1, now - 86_400);
        _ = c.sqlite3_bind_int64(prune, 2, now - 86_400);
        if (c.sqlite3_step(prune) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        _ = c.sqlite3_finalize(prune);

        {
            var insert: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "INSERT INTO lazer_score_tokens(id,user_id,beatmap_id,beatmap_hash,ruleset_id,version_hash,expires_at) VALUES(?1,?2,?3,?4,?5,?6,?7)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(insert);
            _ = c.sqlite3_bind_int64(insert, 1, token_id);
            _ = c.sqlite3_bind_int(insert, 2, user_id);
            _ = c.sqlite3_bind_int(insert, 3, beatmap_id);
            _ = c.sqlite3_bind_text(insert, 4, beatmap_hash.ptr, @intCast(beatmap_hash.len), null);
            _ = c.sqlite3_bind_int64(insert, 5, ruleset_id);
            _ = c.sqlite3_bind_text(insert, 6, version_hash.ptr, @intCast(version_hash.len), null);
            _ = c.sqlite3_bind_int64(insert, 7, now + lazer.score_token_lifetime_seconds);
            if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }
        try self.exec("COMMIT");
        return token_id;
    }

    pub fn submitLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        {
            var token: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT user_id,beatmap_id,ruleset_id,expires_at,consumed_at FROM lazer_score_tokens WHERE id=?1", -1, &token, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(token);
            _ = c.sqlite3_bind_int64(token, 1, token_id);
            if (c.sqlite3_step(token) != c.SQLITE_ROW) return error.InvalidLazerScoreToken;
            if (c.sqlite3_column_int(token, 0) != user_id) return error.ForeignLazerScoreToken;
            if (c.sqlite3_column_int(token, 1) != beatmap_id or c.sqlite3_column_int64(token, 2) != input.ruleset_id) return error.LazerScoreTokenMismatch;
            if (c.sqlite3_column_int64(token, 3) <= now) return error.LazerScoreTokenExpired;
            if (c.sqlite3_column_type(token, 4) != c.SQLITE_NULL) return error.LazerScoreTokenUsed;
        }

        const score_id = try self.insertLazerScoreLocked(user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
        {
            var consume: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE lazer_score_tokens SET consumed_at=?1,score_id=?2 WHERE id=?3 AND consumed_at IS NULL", -1, &consume, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(consume);
            _ = c.sqlite3_bind_int64(consume, 1, now);
            _ = c.sqlite3_bind_int64(consume, 2, score_id);
            _ = c.sqlite3_bind_int64(consume, 3, token_id);
            if (c.sqlite3_step(consume) != c.SQLITE_DONE or c.sqlite3_changes(self.db) != 1) return error.LazerScoreTokenUsed;
        }
        try self.exec("COMMIT");
        return score_id;
    }

    pub const BeatmapForScore = struct { id: i32, set_id: i32, status: i8, plays: i32, passes: i32 };

    pub const BeatmapRating = union(enum) {
        no_exist,
        not_ranked,
        can_rate,
        already_voted: f64,
    };

    pub fn rateBeatmap(self: *Store, user_id: i32, map_md5: []const u8, rating: ?u8) !BeatmapRating {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var map_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT status FROM beatmaps WHERE md5=?1", -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_stmt);
        _ = c.sqlite3_bind_text(map_stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
        if (c.sqlite3_step(map_stmt) != c.SQLITE_ROW) return .no_exist;
        if (c.sqlite3_column_int(map_stmt, 0) < 3) return .not_ranked;

        if (rating) |value| {
            if (value < 1 or value > 10) return error.InvalidRating;
            var insert_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "INSERT INTO ratings(user_id,map_md5,rating) VALUES(?1,?2,?3) ON CONFLICT(user_id,map_md5) DO NOTHING", -1, &insert_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(insert_stmt);
            _ = c.sqlite3_bind_int(insert_stmt, 1, user_id);
            _ = c.sqlite3_bind_text(insert_stmt, 2, map_md5.ptr, @intCast(map_md5.len), null);
            _ = c.sqlite3_bind_int(insert_stmt, 3, value);
            if (c.sqlite3_step(insert_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        } else {
            var existing_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM ratings WHERE user_id=?1 AND map_md5=?2", -1, &existing_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(existing_stmt);
            _ = c.sqlite3_bind_int(existing_stmt, 1, user_id);
            _ = c.sqlite3_bind_text(existing_stmt, 2, map_md5.ptr, @intCast(map_md5.len), null);
            if (c.sqlite3_step(existing_stmt) != c.SQLITE_ROW) return .can_rate;
        }

        var average_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT avg(rating) FROM ratings WHERE map_md5=?1", -1, &average_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(average_stmt);
        _ = c.sqlite3_bind_text(average_stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
        if (c.sqlite3_step(average_stmt) != c.SQLITE_ROW or c.sqlite3_column_type(average_stmt, 0) == c.SQLITE_NULL) return error.DatabaseQueryFailed;
        return .{ .already_voted = c.sqlite3_column_double(average_stmt, 0) };
    }

    pub fn recordLastFmFlag(self: *Store, user_id: i32, flags: u32) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var target_buf: [24]u8 = undefined;
        var detail_buf: [32]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
        const detail = try std.fmt.bufPrint(&detail_buf, "flags:{d}", .{flags});
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT INTO audit_log(actor_id,action,target,detail) VALUES(?1,'stable.lastfm_flag',?2,?3)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, target.ptr, @intCast(target.len), null);
        _ = c.sqlite3_bind_text(stmt, 3, detail.ptr, @intCast(detail.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn upsertBeatmap(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,status=CASE WHEN beatmaps.status_frozen=1 THEN beatmaps.status ELSE excluded.status END,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, metadata.id);
        _ = c.sqlite3_bind_int(stmt, 2, metadata.set_id);
        _ = c.sqlite3_bind_text(stmt, 3, md5.ptr, @intCast(md5.len), null);
        _ = c.sqlite3_bind_text(stmt, 4, metadata.artist.ptr, @intCast(metadata.artist.len), null);
        _ = c.sqlite3_bind_text(stmt, 5, metadata.title.ptr, @intCast(metadata.title.len), null);
        _ = c.sqlite3_bind_text(stmt, 6, metadata.version.ptr, @intCast(metadata.version.len), null);
        _ = c.sqlite3_bind_text(stmt, 7, metadata.creator.ptr, @intCast(metadata.creator.len), null);
        _ = c.sqlite3_bind_int(stmt, 8, status);
        _ = c.sqlite3_bind_int(stmt, 9, metadata.total_length);
        _ = c.sqlite3_bind_int64(stmt, 10, max_combo);
        _ = c.sqlite3_bind_int(stmt, 11, metadata.mode);
        _ = c.sqlite3_bind_double(stmt, 12, metadata.bpm);
        _ = c.sqlite3_bind_double(stmt, 13, metadata.cs);
        _ = c.sqlite3_bind_double(stmt, 14, metadata.ar);
        _ = c.sqlite3_bind_double(stmt, 15, metadata.od);
        _ = c.sqlite3_bind_double(stmt, 16, metadata.hp);
        _ = c.sqlite3_bind_double(stmt, 17, stars);
        _ = c.sqlite3_bind_text(stmt, 18, metadata.source.ptr, @intCast(metadata.source.len), null);
        _ = c.sqlite3_bind_text(stmt, 19, metadata.tags.ptr, @intCast(metadata.tags.len), null);
        _ = c.sqlite3_bind_blob(stmt, 20, osu_file.ptr, @intCast(osu_file.len), null);
        _ = c.sqlite3_bind_int64(stmt, 21, metadata.count_circles);
        _ = c.sqlite3_bind_int64(stmt, 22, metadata.count_sliders);
        _ = c.sqlite3_bind_int64(stmt, 23, metadata.count_spinners);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn upsertBeatmapMeta(self: *Store, map: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "INSERT INTO beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,unixepoch(),?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,NULL,?20,?21,?22) ON CONFLICT(id) DO NOTHING";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, map.id);
        _ = c.sqlite3_bind_int(stmt, 2, map.set_id);
        _ = c.sqlite3_bind_text(stmt, 3, md5.ptr, @intCast(md5.len), null);
        _ = c.sqlite3_bind_text(stmt, 4, map.artist.ptr, @intCast(map.artist.len), null);
        _ = c.sqlite3_bind_text(stmt, 5, map.title.ptr, @intCast(map.title.len), null);
        _ = c.sqlite3_bind_text(stmt, 6, map.version.ptr, @intCast(map.version.len), null);
        _ = c.sqlite3_bind_text(stmt, 7, map.creator.ptr, @intCast(map.creator.len), null);
        _ = c.sqlite3_bind_int(stmt, 8, status);
        _ = c.sqlite3_bind_int(stmt, 9, map.total_length);
        _ = c.sqlite3_bind_int64(stmt, 10, max_combo);
        _ = c.sqlite3_bind_int(stmt, 11, map.mode);
        _ = c.sqlite3_bind_double(stmt, 12, map.bpm);
        _ = c.sqlite3_bind_double(stmt, 13, map.cs);
        _ = c.sqlite3_bind_double(stmt, 14, map.ar);
        _ = c.sqlite3_bind_double(stmt, 15, map.od);
        _ = c.sqlite3_bind_double(stmt, 16, map.hp);
        _ = c.sqlite3_bind_double(stmt, 17, stars);
        _ = c.sqlite3_bind_text(stmt, 18, map.source.ptr, @intCast(map.source.len), null);
        _ = c.sqlite3_bind_text(stmt, 19, map.tags.ptr, @intCast(map.tags.len), null);
        _ = c.sqlite3_bind_int64(stmt, 20, map.count_circles);
        _ = c.sqlite3_bind_int64(stmt, 21, map.count_sliders);
        _ = c.sqlite3_bind_int64(stmt, 22, map.count_spinners);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn beatmapFile(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT osu_file FROM beatmaps WHERE md5=?1 AND osu_file IS NOT NULL";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return try allocator.dupe(u8, ptr[0..len]);
    }

    pub fn beatmapHasFile(self: *Store, md5: []const u8) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE md5=?1 AND osu_file IS NOT NULL", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn beatmapFileById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT osu_file FROM beatmaps WHERE id=?1 AND osu_file IS NOT NULL";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, map_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return try allocator.dupe(u8, ptr[0..len]);
    }

    pub const BeatmapSelection = struct {
        md5: [32]u8,
        set_id: i32,
        status: i8,
        mode: u8,
    };

    pub const MatchmakingBeatmap = struct {
        id: i32,
        md5: [32]u8,
        mode: u8,
        stars: f64,
    };

    pub fn matchmakingBeatmaps(self: *Store, allocator: std.mem.Allocator, mode: u8, limit: u8) ![]MatchmakingBeatmap {
        if (mode > 3 or limit == 0 or limit > 32) return error.InvalidMatchmakingPool;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT id,md5,mode,star_rating FROM beatmaps WHERE status IN(3,4) AND mode=?1 AND osu_file IS NOT NULL ORDER BY star_rating,id LIMIT ?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, mode);
        _ = c.sqlite3_bind_int(stmt, 2, limit);
        var maps: std.ArrayList(MatchmakingBeatmap) = .empty;
        errdefer maps.deinit(allocator);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const md5 = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (md5.len != 32) return error.InvalidBeatmap;
            var map: MatchmakingBeatmap = .{
                .id = c.sqlite3_column_int(stmt, 0),
                .md5 = undefined,
                .mode = @intCast(c.sqlite3_column_int(stmt, 2)),
                .stars = c.sqlite3_column_double(stmt, 3),
            };
            @memcpy(&map.md5, md5);
            try maps.append(allocator, map);
        }
        return maps.toOwnedSlice(allocator);
    }

    pub fn beatmapSelectionById(self: *Store, map_id: i32) !?BeatmapSelection {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT md5,set_id,status,mode FROM beatmaps WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, map_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const md5 = std.mem.span(c.sqlite3_column_text(stmt, 0));
        if (md5.len != 32) return error.InvalidBeatmap;
        var selection: BeatmapSelection = .{
            .md5 = undefined,
            .set_id = c.sqlite3_column_int(stmt, 1),
            .status = @intCast(c.sqlite3_column_int(stmt, 2)),
            .mode = @intCast(c.sqlite3_column_int(stmt, 3)),
        };
        @memcpy(&selection.md5, md5);
        return selection;
    }

    pub fn setScorePinned(self: *Store, user_id: i32, map_md5: []const u8, mode: u8, mods: i32, namespace: []const u8, pinned: bool) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};

        const score_id = block: {
            var score: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT id FROM scores WHERE user_id=?1 AND map_md5=?2 AND mode=?3 AND rank_namespace=?4 AND mods=?5 AND passed=1 ORDER BY best DESC,pp DESC,score DESC,id DESC LIMIT 1", -1, &score, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(score);
            _ = c.sqlite3_bind_int(score, 1, user_id);
            _ = c.sqlite3_bind_text(score, 2, map_md5.ptr, @intCast(map_md5.len), null);
            _ = c.sqlite3_bind_int(score, 3, mode);
            _ = c.sqlite3_bind_text(score, 4, namespace.ptr, @intCast(namespace.len), null);
            _ = c.sqlite3_bind_int(score, 5, mods);
            if (c.sqlite3_step(score) != c.SQLITE_ROW) return error.NoPassedScore;
            break :block c.sqlite3_column_int64(score, 0);
        };

        if (pinned) {
            var old: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "DELETE FROM score_pins WHERE user_id=?1 AND score_id<>?2 AND score_id IN (SELECT id FROM scores WHERE user_id=?1 AND map_md5=?3 AND mode=?4 AND mods=?5 AND rank_namespace=?6)", -1, &old, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int(old, 1, user_id);
            _ = c.sqlite3_bind_int64(old, 2, score_id);
            _ = c.sqlite3_bind_text(old, 3, map_md5.ptr, @intCast(map_md5.len), null);
            _ = c.sqlite3_bind_int(old, 4, mode);
            _ = c.sqlite3_bind_int(old, 5, mods);
            _ = c.sqlite3_bind_text(old, 6, namespace.ptr, @intCast(namespace.len), null);
            if (c.sqlite3_step(old) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
            _ = c.sqlite3_finalize(old);

            var existing: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM score_pins WHERE user_id=?1 AND score_id=?2", -1, &existing, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int(existing, 1, user_id);
            _ = c.sqlite3_bind_int64(existing, 2, score_id);
            const already_pinned = c.sqlite3_step(existing) == c.SQLITE_ROW;
            _ = c.sqlite3_finalize(existing);
            if (!already_pinned) {
                var count: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM score_pins p JOIN scores s ON s.id=p.score_id WHERE p.user_id=?1 AND s.mode=?2 AND s.rank_namespace=?3", -1, &count, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
                _ = c.sqlite3_bind_int(count, 1, user_id);
                _ = c.sqlite3_bind_int(count, 2, mode);
                _ = c.sqlite3_bind_text(count, 3, namespace.ptr, @intCast(namespace.len), null);
                if (c.sqlite3_step(count) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
                const pin_count = c.sqlite3_column_int(count, 0);
                _ = c.sqlite3_finalize(count);
                if (pin_count >= 3) return error.TooManyPinnedScores;
                var insert: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "INSERT INTO score_pins(user_id,score_id) VALUES(?1,?2)", -1, &insert, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
                _ = c.sqlite3_bind_int(insert, 1, user_id);
                _ = c.sqlite3_bind_int64(insert, 2, score_id);
                if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
                _ = c.sqlite3_finalize(insert);
            } else {
                var touch: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "UPDATE score_pins SET pinned_at=unixepoch() WHERE user_id=?1 AND score_id=?2", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
                _ = c.sqlite3_bind_int(touch, 1, user_id);
                _ = c.sqlite3_bind_int64(touch, 2, score_id);
                if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
                _ = c.sqlite3_finalize(touch);
            }
        } else {
            var remove: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "DELETE FROM score_pins WHERE user_id=?1 AND score_id IN (SELECT id FROM scores WHERE user_id=?1 AND map_md5=?2 AND mode=?3 AND mods=?4 AND rank_namespace=?5)", -1, &remove, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int(remove, 1, user_id);
            _ = c.sqlite3_bind_text(remove, 2, map_md5.ptr, @intCast(map_md5.len), null);
            _ = c.sqlite3_bind_int(remove, 3, mode);
            _ = c.sqlite3_bind_int(remove, 4, mods);
            _ = c.sqlite3_bind_text(remove, 5, namespace.ptr, @intCast(namespace.len), null);
            if (c.sqlite3_step(remove) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
            _ = c.sqlite3_finalize(remove);
        }
        try self.exec("COMMIT");
        return score_id;
    }

    pub fn upsertBeatmapArchive(self: *Store, set_id: i32, sha256: []const u8, osz_file: []const u8) !void {
        if (!try self.beatmapSetExists(set_id)) return error.UnknownBeatmapSet;
        if (self.object_store.enabled() and object_keys.validSha256(sha256)) {
            const object_key = try object_keys.archive(self.allocator, set_id, sha256);
            defer self.allocator.free(object_key);
            self.object_store.put(self.allocator, self.io, object_key, "application/octet-stream", osz_file) catch |err|
                std.log.warn("event=beatmap_archive_object_write_failed set_id={d} error={t}", .{ set_id, err });
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var exists_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE set_id=?1 LIMIT 1", -1, &exists_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(exists_stmt, 1, set_id);
        const exists = c.sqlite3_step(exists_stmt) == c.SQLITE_ROW;
        _ = c.sqlite3_finalize(exists_stmt);
        if (!exists) return error.UnknownBeatmapSet;
        const sql = "INSERT INTO beatmap_archives(set_id,sha256,osz_file,last_accessed_at) VALUES(?1,?2,?3,unixepoch()) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,imported_at=unixepoch(),last_accessed_at=unixepoch()";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        _ = c.sqlite3_bind_text(stmt, 2, sha256.ptr, @intCast(sha256.len), null);
        _ = c.sqlite3_bind_blob(stmt, 3, osz_file.ptr, @intCast(osz_file.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn beatmapSetExists(self: *Store, set_id: i32) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE set_id=?1 LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn beatmapSetIdForMap(self: *Store, beatmap_id: i32) !?i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT set_id FROM beatmaps WHERE id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, beatmap_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return c.sqlite3_column_int(stmt, 0);
    }

    pub fn putBeatmapMedia(self: *Store, set_id: i32, kind: media_contract.Kind, content_type: media_contract.ContentType, data: []const u8) !void {
        if (!media_contract.compatible(kind, content_type) or media_contract.detect(kind, data) != content_type) return error.InvalidBeatmapMedia;
        if (!try self.beatmapSetExists(set_id)) return error.UnknownBeatmapSet;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        var encoded_digest: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&encoded_digest, "{x}", .{digest}) catch unreachable;

        if (self.object_store.enabled()) {
            const object_key = try object_keys.media(self.allocator, set_id, kind, content_type, &encoded_digest);
            defer self.allocator.free(object_key);
            self.object_store.put(self.allocator, self.io, object_key, content_type.value(), data) catch |err|
                std.log.warn("event=beatmap_media_object_write_failed set_id={d} kind={s} error={t}", .{ set_id, kind.dbName(), err });
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var exists: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT 1 FROM beatmaps WHERE set_id=?1 LIMIT 1", -1, &exists, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(exists, 1, set_id);
        const known_set = c.sqlite3_step(exists) == c.SQLITE_ROW;
        _ = c.sqlite3_finalize(exists);
        if (!known_set) return error.UnknownBeatmapSet;

        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO beatmap_media(set_id,kind,content_type,sha256,data,last_accessed_at) VALUES(?1,?2,?3,?4,?5,unixepoch()) ON CONFLICT(set_id,kind) DO UPDATE SET content_type=excluded.content_type,sha256=excluded.sha256,data=excluded.data,fetched_at=unixepoch(),last_accessed_at=unixepoch()";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, set_id);
        _ = c.sqlite3_bind_text(stmt, 2, kind.dbName().ptr, @intCast(kind.dbName().len), null);
        _ = c.sqlite3_bind_text(stmt, 3, content_type.value().ptr, @intCast(content_type.value().len), null);
        _ = c.sqlite3_bind_text(stmt, 4, &encoded_digest, encoded_digest.len, null);
        _ = c.sqlite3_bind_blob(stmt, 5, data.ptr, @intCast(data.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn beatmapMedia(self: *Store, allocator: std.mem.Allocator, set_id: i32, kind: media_contract.Kind) !?media_contract.Asset {
        const stored = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT content_type,sha256,data FROM beatmap_media WHERE set_id=?1 AND kind=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_int(stmt, 1, set_id);
            _ = c.sqlite3_bind_text(stmt, 2, kind.dbName().ptr, @intCast(kind.dbName().len), null);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            const content_type = media_contract.ContentType.parse(std.mem.span(c.sqlite3_column_text(stmt, 0))) orelse return error.InvalidStoredBeatmapMedia;
            const sha256 = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
            errdefer allocator.free(sha256);
            const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 2));
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
            const data = try allocator.dupe(u8, ptr[0..len]);
            errdefer allocator.free(data);
            if (!media_contract.compatible(kind, content_type) or !object_keys.validSha256(sha256)) return error.InvalidStoredBeatmapMedia;
            var touch: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_media SET last_accessed_at=unixepoch() WHERE set_id=?1 AND kind=?2", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(touch);
            _ = c.sqlite3_bind_int(touch, 1, set_id);
            _ = c.sqlite3_bind_text(touch, 2, kind.dbName().ptr, @intCast(kind.dbName().len), null);
            if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
            break :blk .{ .data = data, .content_type = content_type, .sha256 = sha256 };
        };
        defer allocator.free(stored.sha256);
        if (self.object_store.enabled()) {
            const object_key = try object_keys.media(allocator, set_id, kind, stored.content_type, stored.sha256);
            defer allocator.free(object_key);
            if (self.object_store.getWithLimit(allocator, self.io, object_key, stored.content_type.value(), stored.data.len)) |data| {
                if (object_keys.matchesSha256(data, stored.sha256) and media_contract.detect(kind, data) == stored.content_type) {
                    allocator.free(stored.data);
                    return .{ .data = data, .content_type = stored.content_type };
                }
                allocator.free(data);
                std.log.warn("event=beatmap_media_object_invalid set_id={d} kind={s}", .{ set_id, kind.dbName() });
            } else |err| std.log.warn("event=beatmap_media_object_read_failed set_id={d} kind={s} error={t}", .{ set_id, kind.dbName(), err });
        }
        if (media_contract.detect(kind, stored.data) != stored.content_type or !object_keys.matchesSha256(stored.data, stored.sha256)) {
            allocator.free(stored.data);
            return error.InvalidStoredBeatmapMedia;
        }
        return .{ .data = stored.data, .content_type = stored.content_type };
    }

    pub fn beatmapMediaCacheStats(self: *Store) !BeatmapMediaCacheStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.mediaCacheSizeLocked();
    }

    pub fn pruneBeatmapMedia(self: *Store, max_bytes: u64) !BeatmapCachePrune {
        if (self.object_store.enabled()) return .{ .entries = 0, .bytes = 0 };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const before = try self.mediaCacheSizeLocked();
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "DELETE FROM beatmap_media WHERE (set_id,kind) IN (SELECT set_id,kind FROM (SELECT set_id,kind,sum(length(data)) OVER (ORDER BY last_accessed_at DESC,fetched_at DESC,set_id DESC,kind DESC) AS running_bytes FROM beatmap_media) WHERE running_bytes>?1)";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(@min(max_bytes, @as(u64, std.math.maxInt(i64)))));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const after = try self.mediaCacheSizeLocked();
        return .{ .entries = before.entries - after.entries, .bytes = before.bytes - after.bytes };
    }

    fn mediaCacheSizeLocked(self: *Store) !BeatmapMediaCacheStats {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),coalesce(sum(length(data)),0) FROM beatmap_media", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return .{ .entries = c.sqlite3_column_int64(stmt, 0), .bytes = c.sqlite3_column_int64(stmt, 1) };
    }

    pub fn beatmapArchive(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
        const stored = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT sha256,osz_file FROM beatmap_archives WHERE set_id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_int(stmt, 1, set_id);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
            const sha256 = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
            errdefer allocator.free(sha256);
            const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 1));
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
            const data = try allocator.dupe(u8, ptr[0..len]);
            errdefer allocator.free(data);
            var touch: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "UPDATE beatmap_archives SET last_accessed_at=unixepoch() WHERE set_id=?1", -1, &touch, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(touch);
            _ = c.sqlite3_bind_int(touch, 1, set_id);
            if (c.sqlite3_step(touch) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
            break :blk .{ .data = data, .sha256 = sha256 };
        };
        defer allocator.free(stored.sha256);
        if (self.object_store.enabled() and object_keys.validSha256(stored.sha256)) {
            const object_key = try object_keys.archive(allocator, set_id, stored.sha256);
            defer allocator.free(object_key);
            if (self.object_store.getWithLimit(allocator, self.io, object_key, "application/octet-stream", stored.data.len)) |data| {
                if (object_keys.matchesSha256(data, stored.sha256)) {
                    allocator.free(stored.data);
                    return data;
                }
                allocator.free(data);
                std.log.warn("event=beatmap_archive_object_invalid set_id={d}", .{set_id});
            } else |err| std.log.warn("event=beatmap_archive_object_read_failed set_id={d} error={t}", .{ set_id, err });
        }
        return stored.data;
    }

    pub fn hydrationRetryAllowed(self: *Store, md5: []const u8, now: i64) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT next_retry_at<=?2 FROM beatmap_hydration_failures WHERE md5=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        _ = c.sqlite3_bind_int64(stmt, 2, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return true;
        return c.sqlite3_column_int(stmt, 0) != 0;
    }

    pub fn recordHydrationFailure(self: *Store, md5: []const u8, set_id: i32, reason: []const u8, now: i64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "INSERT INTO beatmap_hydration_failures(md5,set_id,attempts,next_retry_at,last_error,updated_at) VALUES(?1,?2,1,?4+30,?3,?4) ON CONFLICT(md5) DO UPDATE SET set_id=excluded.set_id,attempts=min(32,beatmap_hydration_failures.attempts+1),next_retry_at=excluded.updated_at+min(21600,30*(1 << min(beatmap_hydration_failures.attempts,10))),last_error=excluded.last_error,updated_at=excluded.updated_at";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        _ = c.sqlite3_bind_int(stmt, 2, set_id);
        _ = c.sqlite3_bind_text(stmt, 3, reason.ptr, @intCast(reason.len), null);
        _ = c.sqlite3_bind_int64(stmt, 4, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        var trim: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM beatmap_hydration_failures WHERE md5 IN (SELECT md5 FROM beatmap_hydration_failures ORDER BY updated_at DESC,md5 DESC LIMIT -1 OFFSET 10000)", -1, &trim, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(trim);
        if (c.sqlite3_step(trim) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn clearHydrationFailure(self: *Store, md5: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "DELETE FROM beatmap_hydration_failures WHERE md5=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }

    pub fn beatmapCacheStats(self: *Store) !BeatmapCacheStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),coalesce(sum(length(osz_file)),0),(SELECT count(*) FROM beatmap_hydration_failures) FROM beatmap_archives", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return .{ .entries = c.sqlite3_column_int64(stmt, 0), .bytes = c.sqlite3_column_int64(stmt, 1), .hydration_failures = c.sqlite3_column_int64(stmt, 2) };
    }

    pub fn pruneBeatmapArchives(self: *Store, max_bytes: u64) !BeatmapCachePrune {
        if (self.object_store.enabled()) return .{ .entries = 0, .bytes = 0 };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const before = try self.cacheSizeLocked();
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "DELETE FROM beatmap_archives WHERE set_id IN (SELECT set_id FROM (SELECT set_id,sum(length(osz_file)) OVER (ORDER BY last_accessed_at DESC,imported_at DESC,set_id DESC) AS running_bytes FROM beatmap_archives) WHERE running_bytes>?1)";
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(@min(max_bytes, @as(u64, std.math.maxInt(i64)))));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        const after = try self.cacheSizeLocked();
        return .{ .entries = before.entries - after.entries, .bytes = before.bytes - after.bytes };
    }

    fn cacheSizeLocked(self: *Store) !BeatmapCachePrune {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),coalesce(sum(length(osz_file)),0) FROM beatmap_archives", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        return .{ .entries = c.sqlite3_column_int64(stmt, 0), .bytes = c.sqlite3_column_int64(stmt, 1) };
    }

    fn putVerifiedObject(self: *Store, object_key: []const u8, content_type: []const u8, bytes: []const u8, sha256: []const u8) !void {
        try self.object_store.put(self.allocator, self.io, object_key, content_type, bytes);
        const downloaded = try self.object_store.getWithLimit(self.allocator, self.io, object_key, content_type, bytes.len);
        defer self.allocator.free(downloaded);
        if (downloaded.len != bytes.len or !object_keys.matchesSha256(downloaded, sha256)) return error.ObjectVerificationFailed;
    }

    pub fn migrateBeatmapObjects(self: *Store) !ObjectMigrationStats {
        if (!self.object_store.enabled()) return error.ObjectStorageNotConfigured;
        var stats: ObjectMigrationStats = .{};
        var offset: i64 = 0;
        while (true) : (offset += 1) {
            const item = blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                var stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "SELECT set_id,sha256,osz_file FROM beatmap_archives ORDER BY set_id LIMIT 1 OFFSET ?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_int64(stmt, 1, offset);
                if (c.sqlite3_step(stmt) != c.SQLITE_ROW) break :blk null;
                const sha256 = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
                errdefer self.allocator.free(sha256);
                const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 2));
                const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
                const data = try self.allocator.dupe(u8, ptr[0..len]);
                break :blk .{ .set_id = c.sqlite3_column_int(stmt, 0), .sha256 = sha256, .data = data };
            } orelse break;
            defer self.allocator.free(item.sha256);
            defer self.allocator.free(item.data);
            const object_key = object_keys.archive(self.allocator, item.set_id, item.sha256) catch |err| {
                stats.failed += 1;
                std.log.warn("event=beatmap_archive_object_migration_failed set_id={d} error={t}", .{ item.set_id, err });
                continue;
            };
            defer self.allocator.free(object_key);
            self.putVerifiedObject(object_key, "application/octet-stream", item.data, item.sha256) catch |err| {
                stats.failed += 1;
                std.log.warn("event=beatmap_archive_object_migration_failed set_id={d} error={t}", .{ item.set_id, err });
                continue;
            };
            stats.archives += 1;
        }

        offset = 0;
        while (true) : (offset += 1) {
            const item = blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                var stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, "SELECT set_id,kind,content_type,sha256,data FROM beatmap_media ORDER BY set_id,kind LIMIT 1 OFFSET ?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
                defer _ = c.sqlite3_finalize(stmt);
                _ = c.sqlite3_bind_int64(stmt, 1, offset);
                if (c.sqlite3_step(stmt) != c.SQLITE_ROW) break :blk null;
                const kind = media_contract.Kind.parseDb(std.mem.span(c.sqlite3_column_text(stmt, 1))) orelse return error.InvalidStoredBeatmapMedia;
                const content_type = media_contract.ContentType.parse(std.mem.span(c.sqlite3_column_text(stmt, 2))) orelse return error.InvalidStoredBeatmapMedia;
                const sha256 = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)));
                errdefer self.allocator.free(sha256);
                const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 4));
                const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
                const data = try self.allocator.dupe(u8, ptr[0..len]);
                break :blk .{ .set_id = c.sqlite3_column_int(stmt, 0), .kind = kind, .content_type = content_type, .sha256 = sha256, .data = data };
            } orelse break;
            defer self.allocator.free(item.sha256);
            defer self.allocator.free(item.data);
            const object_key = object_keys.media(self.allocator, item.set_id, item.kind, item.content_type, item.sha256) catch |err| {
                stats.failed += 1;
                std.log.warn("event=beatmap_media_object_migration_failed set_id={d} kind={s} error={t}", .{ item.set_id, item.kind.dbName(), err });
                continue;
            };
            defer self.allocator.free(object_key);
            self.putVerifiedObject(object_key, item.content_type.value(), item.data, item.sha256) catch |err| {
                stats.failed += 1;
                std.log.warn("event=beatmap_media_object_migration_failed set_id={d} kind={s} error={t}", .{ item.set_id, item.kind.dbName(), err });
                continue;
            };
            stats.media += 1;
        }
        return stats;
    }

    pub fn purgeBeatmapObjectBackups(self: *Store) !ObjectPurgeStats {
        _ = self;
        return error.ObjectPurgeRequiresPostgres;
    }

    pub fn beatmapForScore(self: *Store, md5: []const u8) !?BeatmapForScore {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT id,set_id,status,plays,passes FROM beatmaps WHERE md5=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{ .id = c.sqlite3_column_int(stmt, 0), .set_id = c.sqlite3_column_int(stmt, 1), .status = @intCast(c.sqlite3_column_int(stmt, 2)), .plays = c.sqlite3_column_int(stmt, 3), .passes = c.sqlite3_column_int(stmt, 4) };
    }

    pub const BeatmapInfo = struct { id: i32, set_id: i32, max_combo: i32, artist: []const u8, title: []const u8, version: []const u8, star_rating: f64 };

    pub fn scoreLeaderboardPlacement(self: *Store, score_id: i64) !?domain.ScorePlacement {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT s.best,(SELECT count(*) FROM scores o WHERE o.map_md5=pb.map_md5 AND o.mode=pb.mode AND o.rank_namespace=pb.rank_namespace AND o.passed=1 AND o.best=1 AND ((pb.rank_namespace IN('vanilla','scorev2') AND (o.score>pb.score OR (o.score=pb.score AND o.id<pb.id))) OR (pb.rank_namespace IN('relax','autopilot') AND (o.pp>pb.pp OR (o.pp=pb.pp AND o.id<pb.id))))) FROM scores s JOIN beatmaps b ON b.md5=s.map_md5 JOIN scores pb ON pb.user_id=s.user_id AND pb.map_md5=s.map_md5 AND pb.mode=s.mode AND pb.rank_namespace=s.rank_namespace AND pb.passed=1 AND pb.best=1 WHERE s.id=?1 AND s.passed=1 AND b.status>=3";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{ .submitted_is_best = c.sqlite3_column_int(stmt, 0) != 0, .rank = c.sqlite3_column_int(stmt, 1) };
    }

    pub fn lazerScoreLeaderboardPlacement(self: *Store, score_id: i64) !?domain.ScorePlacement {
        const Context = struct { user_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, mods_json: []u8 };
        const context: Context = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, "SELECT s.user_id,s.beatmap_id,s.ruleset_id,s.rank_namespace,s.mods_json,s.passed,b.status FROM lazer_scores s JOIN beatmaps b ON b.id=s.beatmap_id WHERE s.id=?1", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_int64(stmt, 1, score_id);
            if (c.sqlite3_step(stmt) != c.SQLITE_ROW or c.sqlite3_column_int(stmt, 5) == 0 or c.sqlite3_column_int(stmt, 6) < 3) return null;
            const namespace_name = std.mem.span(c.sqlite3_column_text(stmt, 3));
            const score_namespace = std.meta.stringToEnum(lazer.Namespace, namespace_name) orelse return error.DatabaseQueryFailed;
            break :blk .{
                .user_id = c.sqlite3_column_int(stmt, 0),
                .beatmap_id = c.sqlite3_column_int(stmt, 1),
                .ruleset_id = @intCast(c.sqlite3_column_int(stmt, 2)),
                .namespace = score_namespace,
                .mods_json = try self.allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4))),
            };
        };
        defer self.allocator.free(context.mods_json);
        const filter = try lazer.scoreModFilter(self.allocator, context.mods_json);
        defer filter.deinit(self.allocator);
        const board_json = try self.lazerLeaderboardJson(self.allocator, context.user_id, context.beatmap_id, context.ruleset_id, context.namespace, filter.exact_json, true, false, filter.stable_bits, 100);
        defer self.allocator.free(board_json);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, board_json, .{});
        defer parsed.deinit();
        const own = parsed.value.object.get("user_score") orelse return null;
        const own_object = switch (own) {
            .object => |value| value,
            else => return null,
        };
        const position = own_object.get("position") orelse return null;
        const position_value = switch (position) {
            .integer => |value| value,
            else => return null,
        };
        const score = own_object.get("score") orelse return null;
        const score_object = switch (score) {
            .object => |value| value,
            else => return null,
        };
        const listed_id = switch (score_object.get("id") orelse return null) {
            .integer => |value| value,
            else => return null,
        };
        return .{
            .submitted_is_best = listed_id == score_id,
            .rank = std.math.cast(i32, @max(position_value - 1, 0)) orelse return error.DatabaseQueryFailed,
        };
    }

    pub fn beatmapInfo(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?BeatmapInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT id,set_id,max_combo,artist,title,version,star_rating FROM beatmaps WHERE md5=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, md5.ptr, @intCast(md5.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{
            .id = c.sqlite3_column_int(stmt, 0),
            .set_id = c.sqlite3_column_int(stmt, 1),
            .max_combo = c.sqlite3_column_int(stmt, 2),
            .artist = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
            .title = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4))),
            .version = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5))),
            .star_rating = c.sqlite3_column_double(stmt, 6),
        };
    }

    pub fn beatmapInfoById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?BeatmapInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT id,set_id,max_combo,artist,title,version,star_rating FROM beatmaps WHERE id=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, map_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const artist = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        errdefer allocator.free(artist);
        const title = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4)));
        errdefer allocator.free(title);
        const version = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 5)));
        return .{ .id = c.sqlite3_column_int(stmt, 0), .set_id = c.sqlite3_column_int(stmt, 1), .max_combo = c.sqlite3_column_int(stmt, 2), .artist = artist, .title = title, .version = version, .star_rating = c.sqlite3_column_double(stmt, 6) };
    }

    pub fn insertStableScore(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const namespace = score.rankNamespace();
        var previous_best_id: i64 = 0;
        var previous_best_score: i64 = 0;
        var previous_best_pp: f64 = 0;
        const best_sql = "SELECT id,score,pp FROM scores WHERE user_id=?1 AND map_md5=?2 AND mode=?3 AND rank_namespace=?4 AND best=1 LIMIT 1";
        var best_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, best_sql, -1, &best_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        _ = c.sqlite3_bind_int(best_stmt, 1, user_id);
        _ = c.sqlite3_bind_text(best_stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        _ = c.sqlite3_bind_int(best_stmt, 3, score.mode);
        _ = c.sqlite3_bind_text(best_stmt, 4, namespace.ptr, @intCast(namespace.len), null);
        if (c.sqlite3_step(best_stmt) == c.SQLITE_ROW) {
            previous_best_id = c.sqlite3_column_int64(best_stmt, 0);
            previous_best_score = c.sqlite3_column_int64(best_stmt, 1);
            previous_best_pp = c.sqlite3_column_double(best_stmt, 2);
        }
        _ = c.sqlite3_finalize(best_stmt);
        const uses_pp_metric = stable_mods.usesPpMetric(namespace);
        const updates_player_stats = stable_mods.updatesPlayerStats(namespace);
        const is_best = score.passed and if (uses_pp_metric) pp_value > previous_best_pp else score.total_score > previous_best_score;
        const stats_mode = stable_score.statsMode(score.mode, score.mods) orelse return error.UnsupportedModMode;
        const sql = "INSERT INTO scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed,star_rating) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        _ = c.sqlite3_bind_int(stmt, 3, score.mode);
        _ = c.sqlite3_bind_int(stmt, 4, score.mods);
        _ = c.sqlite3_bind_int64(stmt, 5, score.total_score);
        _ = c.sqlite3_bind_double(stmt, 6, pp_value);
        _ = c.sqlite3_bind_double(stmt, 7, score.accuracy());
        _ = c.sqlite3_bind_int(stmt, 8, score.max_combo);
        _ = c.sqlite3_bind_int(stmt, 9, score.n300);
        _ = c.sqlite3_bind_int(stmt, 10, score.n100);
        _ = c.sqlite3_bind_int(stmt, 11, score.n50);
        _ = c.sqlite3_bind_int(stmt, 12, score.nmiss);
        _ = c.sqlite3_bind_int(stmt, 13, score.ngeki);
        _ = c.sqlite3_bind_int(stmt, 14, score.nkatu);
        _ = c.sqlite3_bind_int(stmt, 15, @intFromBool(score.perfect));
        _ = c.sqlite3_bind_int(stmt, 16, @intFromBool(score.passed));
        _ = c.sqlite3_bind_blob(stmt, 17, replay_data.ptr, @intCast(replay_data.len), null);
        _ = c.sqlite3_bind_text(stmt, 18, score.online_checksum.ptr, @intCast(score.online_checksum.len), null);
        _ = c.sqlite3_bind_text(stmt, 19, namespace.ptr, @intCast(namespace.len), null);
        _ = c.sqlite3_bind_int(stmt, 20, @intFromBool(is_best));
        _ = c.sqlite3_bind_int64(stmt, 21, time_elapsed_ms);
        _ = c.sqlite3_bind_double(stmt, 22, score.achievement_stars);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return if (c.sqlite3_extended_errcode(self.db) == c.SQLITE_CONSTRAINT_UNIQUE) error.DuplicateScore else error.DatabaseQueryFailed;
        const id = c.sqlite3_last_insert_rowid(self.db);
        if (is_best and previous_best_id != 0) {
            const unset = "UPDATE scores SET best=0 WHERE id=?1";
            var unset_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, unset, -1, &unset_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int64(unset_stmt, 1, previous_best_id);
            if (c.sqlite3_step(unset_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
            _ = c.sqlite3_finalize(unset_stmt);
        }
        const status_sql = "SELECT status FROM beatmaps WHERE md5=?1";
        var status_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, status_sql, -1, &status_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(status_stmt);
        _ = c.sqlite3_bind_text(status_stmt, 1, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        if (c.sqlite3_step(status_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        const map_status = c.sqlite3_column_int(status_stmt, 0);
        const has_leaderboard = map_status >= 3;
        const awards_ranked_pp = map_status == 3 or map_status == 4;
        try self.awardAchievementsLocked(user_id, "stable", id, .{
            .eligible = score.passed and std.mem.eql(u8, namespace, "vanilla") and awards_ranked_pp,
            .mode = score.mode,
            .mods = @intCast(score.mods),
            .perfect = score.perfect,
            .max_combo = @intCast(score.max_combo),
            .stars = score.achievement_stars,
            .accuracy = score.accuracy(),
            .pp = pp_value,
        });
        if (updates_player_stats) {
            const total_hits: i64 = @as(i64, score.n300) + score.n100 + score.n50 + if (score.mode == 1 or score.mode == 3) @as(i64, score.ngeki) + score.nkatu else 0;
            const update_stats = "UPDATE stats SET total_score=total_score+?1,ranked_score=ranked_score+?2,plays=plays+1,play_time=play_time+?3,total_hits=total_hits+?4,max_combo=CASE WHEN ?5=1 THEN max(max_combo,?6) ELSE max_combo END WHERE user_id=?7 AND mode=?8";
            var stats_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, update_stats, -1, &stats_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            defer _ = c.sqlite3_finalize(stats_stmt);
            _ = c.sqlite3_bind_int64(stats_stmt, 1, score.total_score);
            _ = c.sqlite3_bind_int64(stats_stmt, 2, 0);
            _ = c.sqlite3_bind_int64(stats_stmt, 3, time_elapsed_ms / 1000);
            _ = c.sqlite3_bind_int64(stats_stmt, 4, total_hits);
            _ = c.sqlite3_bind_int(stats_stmt, 5, @intFromBool(score.passed and has_leaderboard));
            _ = c.sqlite3_bind_int(stats_stmt, 6, score.max_combo);
            _ = c.sqlite3_bind_int(stats_stmt, 7, user_id);
            _ = c.sqlite3_bind_int(stats_stmt, 8, stats_mode);
            if (c.sqlite3_step(stats_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        }
        const update_map = "UPDATE beatmaps SET plays=plays+1,passes=passes+?1 WHERE md5=?2";
        var map_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, update_map, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_stmt);
        _ = c.sqlite3_bind_int(map_stmt, 1, @intFromBool(score.passed));
        _ = c.sqlite3_bind_text(map_stmt, 2, score.map_md5.ptr, @intCast(score.map_md5.len), null);
        if (c.sqlite3_step(map_stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        if (updates_player_stats and score.passed and awards_ranked_pp) {
            try self.rebuildCombinedPerformanceLocked(user_id, score.mode, stats_mode, namespace);
        }
        try self.exec("COMMIT");
        return id;
    }

    pub fn replay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT replay FROM scores WHERE id=?1 AND replay IS NOT NULL";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return @as(?[]u8, try allocator.dupe(u8, ptr[0..len]));
    }

    pub fn putScreenshot(self: *Store, user_id: i32, token: []const u8, extension: []const u8, image: []const u8) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var quota: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT count(*),coalesce(sum(length(image)),0) FROM screenshots WHERE uploader_id=?1", -1, &quota, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(quota);
        _ = c.sqlite3_bind_int(quota, 1, user_id);
        if (c.sqlite3_step(quota) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        const file_count: usize = @intCast(c.sqlite3_column_int64(quota, 0));
        const byte_count: usize = @intCast(c.sqlite3_column_int64(quota, 1));
        if (!screenshot_contract.quotaAllows(file_count, byte_count, image.len)) return error.ScreenshotQuotaExceeded;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO screenshots(token,extension,uploader_id,image) VALUES(?1,?2,?3,?4)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, token.ptr, @intCast(token.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, extension.ptr, @intCast(extension.len), null);
        _ = c.sqlite3_bind_int(stmt, 3, user_id);
        _ = c.sqlite3_bind_blob(stmt, 4, image.ptr, @intCast(image.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
        return c.sqlite3_changes(self.db) == 1;
    }

    pub fn screenshot(self: *Store, allocator: std.mem.Allocator, token: []const u8, extension: []const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, "SELECT image FROM screenshots WHERE token=?1 AND extension=?2", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, token.ptr, @intCast(token.len), null);
        _ = c.sqlite3_bind_text(stmt, 2, extension.ptr, @intCast(extension.len), null);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return @as(?[]u8, try allocator.dupe(u8, ptr[0..len]));
    }

    pub const PpSnapshot = struct { score: f64, player: i64 };

    pub fn ppSnapshot(self: *Store, score_id: i64) !?PpSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = "SELECT s.pp,t.pp FROM scores s JOIN stats t ON t.user_id=s.user_id AND t.mode=s.mode WHERE s.id=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, score_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return .{ .score = c.sqlite3_column_double(stmt, 0), .player = c.sqlite3_column_int64(stmt, 1) };
    }

    fn writeDirectText(writer: *std.Io.Writer, value: []const u8) !void {
        for (value) |char| try writer.writeByte(switch (char) {
            '|' => 'I',
            '\r', '\n' => ' ',
            else => char,
        });
    }

    pub fn directStatus(db_status: i32) i32 {
        return switch (db_status) {
            2 => 2,
            3, 4 => 0,
            5 => 3,
            6 => 8,
            else => 2,
        };
    }

    pub fn stableStatus(db_status: i32) i32 {
        return switch (db_status) {
            1 => -1,
            2 => 0,
            3 => 2,
            4 => 3,
            5 => 4,
            6 => 5,
            else => 1,
        };
    }

    fn appendDirectSet(self: *Store, writer: *std.Io.Writer, set_id: i32) !bool {
        const set_sql = "SELECT artist,title,creator,status,coalesce(datetime(last_update,'unixepoch'),'1970-01-01 00:00:00') FROM beatmaps WHERE set_id=?1 ORDER BY star_rating LIMIT 1";
        var set_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(set_stmt);
        _ = c.sqlite3_bind_int(set_stmt, 1, set_id);
        if (c.sqlite3_step(set_stmt) != c.SQLITE_ROW) return false;
        try writer.print("{d}.osz|", .{set_id});
        try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 0)));
        try writer.writeByte('|');
        try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
        try writer.writeByte('|');
        try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
        try writer.print("|{d}|10.0|{s}|{d}|0|0|0|0|0|", .{ directStatus(c.sqlite3_column_int(set_stmt, 3)), std.mem.span(c.sqlite3_column_text(set_stmt, 4)), set_id });

        const maps_sql = "SELECT star_rating,version,cs,od,ar,hp,mode FROM beatmaps WHERE set_id=?1 ORDER BY star_rating,id";
        var maps_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, maps_sql, -1, &maps_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(maps_stmt);
        _ = c.sqlite3_bind_int(maps_stmt, 1, set_id);
        var first = true;
        while (c.sqlite3_step(maps_stmt) == c.SQLITE_ROW) {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("[{d:.2}⭐] ", .{c.sqlite3_column_double(maps_stmt, 0)});
            try writeDirectText(writer, std.mem.span(c.sqlite3_column_text(maps_stmt, 1)));
            try writer.print(" {{cs: {d} / od: {d} / ar: {d} / hp: {d}}}@{d}", .{ c.sqlite3_column_double(maps_stmt, 2), c.sqlite3_column_double(maps_stmt, 3), c.sqlite3_column_double(maps_stmt, 4), c.sqlite3_column_double(maps_stmt, 5), c.sqlite3_column_int(maps_stmt, 6) });
        }
        return true;
    }

    pub fn stableSearch(self: *Store, allocator: std.mem.Allocator, query: []const u8, mode: i8, direct_status: u8, page: u16) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const sql = "SELECT set_id FROM beatmaps WHERE EXISTS(SELECT 1 FROM beatmap_archives a WHERE a.set_id=beatmaps.set_id) AND (?1=-1 OR mode=?1) AND (?2='' OR instr(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower(?2))>0) AND ((?3=4 AND status IN(3,4,5,6)) OR (?3 IN(0,7) AND status IN(3,4)) OR (?3 IN(2,5) AND status=2) OR (?3=3 AND status=5) OR (?3=8 AND status=6)) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 100 OFFSET ?4";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int(stmt, 1, mode);
        _ = c.sqlite3_bind_text(stmt, 2, query.ptr, @intCast(query.len), null);
        _ = c.sqlite3_bind_int(stmt, 3, direct_status);
        _ = c.sqlite3_bind_int64(stmt, 4, @as(i64, page) * 100);
        var ids: [100]i32 = undefined;
        var count: usize = 0;
        while (count < ids.len and c.sqlite3_step(stmt) == c.SQLITE_ROW) : (count += 1) ids[count] = c.sqlite3_column_int(stmt, 0);
        try output.writer.print("{d}", .{if (count == 100) @as(usize, 101) else count});
        for (ids[0..count]) |set_id| {
            try output.writer.writeByte('\n');
            _ = try self.appendDirectSet(&output.writer, set_id);
        }
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn stableSearchSet(self: *Store, allocator: std.mem.Allocator, set_id: ?i32, map_id: ?i32, md5: ?[]const u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const find_sql = "SELECT set_id FROM beatmaps WHERE (?1 IS NOT NULL AND set_id=?1) OR (?2 IS NOT NULL AND id=?2) OR (?3 IS NOT NULL AND md5=?3) LIMIT 1";
        var find_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, find_sql, -1, &find_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(find_stmt);
        if (set_id) |value| _ = c.sqlite3_bind_int(find_stmt, 1, value) else _ = c.sqlite3_bind_null(find_stmt, 1);
        if (map_id) |value| _ = c.sqlite3_bind_int(find_stmt, 2, value) else _ = c.sqlite3_bind_null(find_stmt, 2);
        if (md5) |value| _ = c.sqlite3_bind_text(find_stmt, 3, value.ptr, @intCast(value.len), null) else _ = c.sqlite3_bind_null(find_stmt, 3);
        if (c.sqlite3_step(find_stmt) != c.SQLITE_ROW) return allocator.dupe(u8, "");
        const found_set_id = c.sqlite3_column_int(find_stmt, 0);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        _ = try self.appendDirectSet(&output.writer, found_set_id);
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
        try std.json.Stringify.value(value, .{}, writer);
    }

    pub fn lazerStatus(db_status: i32) []const u8 {
        return switch (db_status) {
            3 => "ranked",
            4 => "approved",
            5 => "qualified",
            6 => "loved",
            else => "pending",
        };
    }

    fn appendLazerMap(writer: *std.Io.Writer, stmt: *c.sqlite3_stmt) !void {
        try writer.print("{{\"id\":{d},\"beatmapset_id\":{d},\"status\":", .{ c.sqlite3_column_int(stmt, 0), c.sqlite3_column_int(stmt, 1) });
        try jsonString(writer, lazerStatus(c.sqlite3_column_int(stmt, 2)));
        try writer.writeAll(",\"checksum\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 3)));
        try writer.print(",\"user_id\":1,\"playcount\":{d},\"passcount\":{d},\"mode_int\":{d},\"difficulty_rating\":{d},\"drain\":{d},\"cs\":{d},\"ar\":{d},\"accuracy\":{d},\"total_length\":{d},\"hit_length\":{d},\"convert\":false,\"count_circles\":{d},\"count_sliders\":{d},\"count_spinners\":{d},\"version\":", .{ c.sqlite3_column_int(stmt, 4), c.sqlite3_column_int(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_double(stmt, 7), c.sqlite3_column_double(stmt, 8), c.sqlite3_column_double(stmt, 9), c.sqlite3_column_double(stmt, 10), c.sqlite3_column_double(stmt, 11), c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 12), c.sqlite3_column_int(stmt, 17), c.sqlite3_column_int(stmt, 18), c.sqlite3_column_int(stmt, 19) });
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 13)));
        try writer.print(",\"max_combo\":{d},\"last_updated\":", .{c.sqlite3_column_int(stmt, 14)});
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(stmt, 15)));
        try writer.print(",\"bpm\":{d},\"owners\":[]}}", .{c.sqlite3_column_double(stmt, 16)});
    }

    fn appendLazerSet(self: *Store, writer: *std.Io.Writer, set_id: i32) !bool {
        const set_sql = "SELECT set_id,artist,title,creator,status,bpm,source,tags,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',last_update,'unixepoch'),'1970-01-01T00:00:00Z'),coalesce((SELECT 0 FROM beatmap_archives a WHERE a.set_id=beatmaps.set_id),1),sum(plays) FROM beatmaps WHERE set_id=?1 GROUP BY set_id";
        var set_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, set_sql, -1, &set_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(set_stmt);
        _ = c.sqlite3_bind_int(set_stmt, 1, set_id);
        if (c.sqlite3_step(set_stmt) != c.SQLITE_ROW) return false;
        try writer.print("{{\"id\":{d},\"status\":", .{set_id});
        try jsonString(writer, lazerStatus(c.sqlite3_column_int(set_stmt, 4)));
        try writer.writeAll(",\"title\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
        try writer.writeAll(",\"title_unicode\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 2)));
        try writer.writeAll(",\"artist\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
        try writer.writeAll(",\"artist_unicode\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 1)));
        try writer.writeAll(",\"creator\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 3)));
        try writer.print(",\"user_id\":1,\"covers\":{{\"cover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover.jpg\",\"cover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover@2x.jpg\",\"card\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card.jpg\",\"card@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card@2x.jpg\",\"list\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list.jpg\",\"list@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list@2x.jpg\",\"slimcover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover.jpg\",\"slimcover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover@2x.jpg\"}},\"preview_url\":\"https://b.kai.ovh/preview/{d}.mp3\",\"play_count\":{d},\"favourite_count\":0,\"bpm\":{d},\"nsfw\":false,\"spotlight\":false,\"video\":false,\"storyboard\":false,\"submitted_date\":", .{ set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, c.sqlite3_column_int(set_stmt, 10), c.sqlite3_column_double(set_stmt, 5) });
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 8)));
        try writer.writeAll(",\"last_updated\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 8)));
        try writer.print(",\"ranked_date\":null,\"ratings\":[],\"availability\":{{\"download_disabled\":{s},\"more_information\":\"\"}},\"genre\":{{\"id\":0,\"name\":\"Unspecified\"}},\"language\":{{\"id\":0,\"name\":\"Unspecified\"}},\"source\":", .{if (c.sqlite3_column_int(set_stmt, 9) != 0) "true" else "false"});
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 6)));
        try writer.writeAll(",\"tags\":");
        try jsonString(writer, std.mem.span(c.sqlite3_column_text(set_stmt, 7)));
        try writer.writeAll(",\"beatmaps\":[");
        const maps_sql = "SELECT id,set_id,status,md5,plays,passes,mode,star_rating,hp,cs,ar,od,total_length,version,max_combo,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',last_update,'unixepoch'),'1970-01-01T00:00:00Z'),bpm,count_circles,count_sliders,count_spinners FROM beatmaps WHERE set_id=?1 ORDER BY star_rating,id";
        var maps_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, maps_sql, -1, &maps_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(maps_stmt);
        _ = c.sqlite3_bind_int(maps_stmt, 1, set_id);
        var first = true;
        while (c.sqlite3_step(maps_stmt) == c.SQLITE_ROW) {
            if (!first) try writer.writeByte(',');
            first = false;
            try appendLazerMap(writer, maps_stmt.?);
        }
        try writer.writeAll("]}");
        return true;
    }

    pub fn lazerBeatmapSet(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        if (!try self.appendLazerSet(&output.writer, set_id)) {
            output.deinit();
            return null;
        }
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn lazerBeatmapLookup(self: *Store, allocator: std.mem.Allocator, beatmap_id: ?i32, checksum: ?[]const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const sql = if (checksum != null)
            "SELECT id,set_id,status,md5,plays,passes,mode,star_rating,hp,cs,ar,od,total_length,version,max_combo,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',last_update,'unixepoch'),'1970-01-01T00:00:00Z'),bpm,count_circles,count_sliders,count_spinners FROM beatmaps WHERE md5=?1"
        else
            "SELECT id,set_id,status,md5,plays,passes,mode,star_rating,hp,cs,ar,od,total_length,version,max_combo,coalesce(strftime('%Y-%m-%dT%H:%M:%SZ',last_update,'unixepoch'),'1970-01-01T00:00:00Z'),bpm,count_circles,count_sliders,count_spinners FROM beatmaps WHERE id=?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (checksum) |hash| {
            _ = c.sqlite3_bind_text(stmt, 1, hash.ptr, @intCast(hash.len), null);
        } else {
            _ = c.sqlite3_bind_int(stmt, 1, beatmap_id orelse return null);
        }
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        var map_output: std.Io.Writer.Allocating = .init(allocator);
        defer map_output.deinit();
        try appendLazerMap(&map_output.writer, stmt.?);
        const map_json = map_output.written();
        if (map_json.len == 0 or map_json[map_json.len - 1] != '}') return error.InvalidStoredBeatmap;

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll(map_json[0 .. map_json.len - 1]);
        try output.writer.print(",\"beatmapset\":{{\"id\":{d},\"status\":", .{c.sqlite3_column_int(stmt, 1)});
        try jsonString(&output.writer, lazerStatus(c.sqlite3_column_int(stmt, 2)));
        try output.writer.writeAll("}}");
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn lazerBeatmapSearch(self: *Store, allocator: std.mem.Allocator, query: []const u8, mode: i8, offset: u16) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const ids_sql = "SELECT set_id FROM beatmaps WHERE (?1=-1 OR mode=?1) AND (?2='' OR instr(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower(?2))>0) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 50 OFFSET ?3";
        var ids_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, ids_sql, -1, &ids_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(ids_stmt);
        _ = c.sqlite3_bind_int(ids_stmt, 1, mode);
        _ = c.sqlite3_bind_text(ids_stmt, 2, query.ptr, @intCast(query.len), null);
        _ = c.sqlite3_bind_int64(ids_stmt, 3, offset);
        var ids: [50]i32 = undefined;
        var count: usize = 0;
        while (count < ids.len and c.sqlite3_step(ids_stmt) == c.SQLITE_ROW) : (count += 1) ids[count] = c.sqlite3_column_int(ids_stmt, 0);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"beatmapsets\":[");
        for (ids[0..count], 0..) |set_id, index| {
            if (index != 0) try output.writer.writeByte(',');
            _ = try self.appendLazerSet(&output.writer, set_id);
        }
        try output.writer.print("],\"total\":{d},\"cursor\":null}}", .{count});
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn lazerBeatmapSets(self: *Store, allocator: std.mem.Allocator, set_ids: []const i32) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"beatmapsets\":[");
        var count: usize = 0;
        for (set_ids) |set_id| {
            var set_output: std.Io.Writer.Allocating = .init(allocator);
            defer set_output.deinit();
            if (!try self.appendLazerSet(&set_output.writer, set_id)) continue;
            if (count != 0) try output.writer.writeByte(',');
            try output.writer.writeAll(set_output.written());
            count += 1;
        }
        try output.writer.print("],\"total\":{d},\"cursor\":null}}", .{count});
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn stableLeaderboard(self: *Store, allocator: std.mem.Allocator, viewer: domain.User, map_md5: []const u8, mode: u8, board_type: u8, requested_mods: i32) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const w = &output.writer;
        const map_sql = "SELECT id,set_id,status,artist,title,version FROM beatmaps WHERE md5=?1";
        var map_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, map_sql, -1, &map_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(map_stmt);
        _ = c.sqlite3_bind_text(map_stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
        if (c.sqlite3_step(map_stmt) != c.SQLITE_ROW) {
            try w.writeAll("-1|false");
            var missing = output.toArrayList();
            return missing.toOwnedSlice(allocator);
        }
        const map_id = c.sqlite3_column_int(map_stmt, 0);
        const set_id = c.sqlite3_column_int(map_stmt, 1);
        const status = c.sqlite3_column_int(map_stmt, 2);
        const client_status = stableStatus(status);
        const artist = std.mem.span(c.sqlite3_column_text(map_stmt, 3));
        const title = std.mem.span(c.sqlite3_column_text(map_stmt, 4));
        const version = std.mem.span(c.sqlite3_column_text(map_stmt, 5));
        if (status < 3) {
            try w.print("{d}|false", .{client_status});
            var unavailable = output.toArrayList();
            return unavailable.toOwnedSlice(allocator);
        }
        const namespace = stable_mods.namespace(requested_mods);
        const uses_pp = std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot");
        const filter = " FROM scores s JOIN users u ON u.id=s.user_id WHERE s.map_md5=?1 AND s.mode=?2 AND s.passed=1 AND s.best=1 AND s.rank_namespace=?3 AND (?4!=2 OR s.mods=?5) AND (?4!=3 OR s.user_id=?6 OR EXISTS(SELECT 1 FROM friends f WHERE f.user_id=?6 AND f.friend_id=s.user_id)) AND (?4!=4 OR u.country=?7)";
        const count_sql = "SELECT min(count(*),50)" ++ filter;
        var count_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, count_sql, -1, &count_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(count_stmt);
        bindBoard(count_stmt.?, map_md5, mode, namespace, board_type, requested_mods, &viewer);
        if (c.sqlite3_step(count_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
        const row_count = c.sqlite3_column_int(count_stmt, 0);
        try w.print("{d}|false|{d}|{d}|{d}|0|\n0\n{s} - {s} [{s}]\n0\n", .{ client_status, map_id, set_id, row_count, artist, title, version });

        const personal_id_sql = if (uses_pp) "SELECT s.id,s.pp" ++ filter ++ " AND s.user_id=?6 ORDER BY s.pp DESC,s.id ASC LIMIT 1" else "SELECT s.id,s.score" ++ filter ++ " AND s.user_id=?6 ORDER BY s.score DESC,s.id ASC LIMIT 1";
        var personal_id_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, personal_id_sql, -1, &personal_id_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        bindBoard(personal_id_stmt.?, map_md5, mode, namespace, board_type, requested_mods, &viewer);
        var personal_id: i64 = 0;
        var personal_score: i64 = 0;
        if (c.sqlite3_step(personal_id_stmt) == c.SQLITE_ROW) {
            personal_id = c.sqlite3_column_int64(personal_id_stmt, 0);
            personal_score = if (uses_pp) @bitCast(c.sqlite3_column_double(personal_id_stmt, 1)) else c.sqlite3_column_int64(personal_id_stmt, 1);
        }
        _ = c.sqlite3_finalize(personal_id_stmt);
        if (personal_id != 0) {
            const rank_sql = if (uses_pp) "SELECT count(*)+1" ++ filter ++ " AND (s.pp>?8 OR (s.pp=?8 AND s.id<?9))" else "SELECT count(*)+1" ++ filter ++ " AND (s.score>?8 OR (s.score=?8 AND s.id<?9))";
            var rank_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, rank_sql, -1, &rank_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            bindBoard(rank_stmt.?, map_md5, mode, namespace, board_type, requested_mods, &viewer);
            _ = c.sqlite3_bind_double(rank_stmt, 8, @bitCast(personal_score));
            _ = c.sqlite3_bind_int64(rank_stmt, 9, personal_id);
            if (c.sqlite3_step(rank_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
            const personal_rank = c.sqlite3_column_int(rank_stmt, 0);
            _ = c.sqlite3_finalize(rank_stmt);
            const row_sql = if (uses_pp)
                "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,length(s.replay)>0 FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1"
            else
                "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,length(s.replay)>0 FROM scores s JOIN users u ON u.id=s.user_id WHERE s.id=?1";
            var row_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, row_sql, -1, &row_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
            _ = c.sqlite3_bind_int64(row_stmt, 1, personal_id);
            if (c.sqlite3_step(row_stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
            try writeBoardRow(w, row_stmt.?, personal_rank, uses_pp);
            _ = c.sqlite3_finalize(row_stmt);
        }
        try w.writeByte('\n');
        const rows_sql = if (uses_pp)
            "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,length(s.replay)>0" ++ filter ++ " ORDER BY s.pp DESC,s.id ASC LIMIT 50"
        else
            "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,length(s.replay)>0" ++ filter ++ " ORDER BY s.score DESC,s.id ASC LIMIT 50";
        var rows_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, rows_sql, -1, &rows_stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
        defer _ = c.sqlite3_finalize(rows_stmt);
        bindBoard(rows_stmt.?, map_md5, mode, namespace, board_type, requested_mods, &viewer);
        var rank: i32 = 1;
        while (c.sqlite3_step(rows_stmt) == c.SQLITE_ROW) {
            if (rank > 1) try w.writeByte('\n');
            try writeBoardRow(w, rows_stmt.?, rank, uses_pp);
            rank += 1;
        }
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

fn bindBoard(stmt: *c.sqlite3_stmt, map_md5: []const u8, mode: u8, namespace: []const u8, board_type: u8, mods: i32, viewer: *const domain.User) void {
    _ = c.sqlite3_bind_text(stmt, 1, map_md5.ptr, @intCast(map_md5.len), null);
    _ = c.sqlite3_bind_int(stmt, 2, mode);
    _ = c.sqlite3_bind_text(stmt, 3, namespace.ptr, @intCast(namespace.len), null);
    _ = c.sqlite3_bind_int(stmt, 4, board_type);
    _ = c.sqlite3_bind_int(stmt, 5, mods);
    _ = c.sqlite3_bind_int(stmt, 6, viewer.id);
    _ = c.sqlite3_bind_text(stmt, 7, viewer.country[0..].ptr, 2, null);
}

fn writeBoardRow(w: *std.Io.Writer, stmt: *c.sqlite3_stmt, rank: i32, is_pp: bool) !void {
    const score_val: i64 = if (is_pp) @intFromFloat(c.sqlite3_column_double(stmt, 2)) else c.sqlite3_column_int64(stmt, 2);
    try w.print("{d}|{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}", .{ c.sqlite3_column_int64(stmt, 0), std.mem.span(c.sqlite3_column_text(stmt, 1)), score_val, c.sqlite3_column_int(stmt, 3), c.sqlite3_column_int(stmt, 4), c.sqlite3_column_int(stmt, 5), c.sqlite3_column_int(stmt, 6), c.sqlite3_column_int(stmt, 7), c.sqlite3_column_int(stmt, 8), c.sqlite3_column_int(stmt, 9), c.sqlite3_column_int(stmt, 10), c.sqlite3_column_int(stmt, 11), c.sqlite3_column_int(stmt, 12), rank, c.sqlite3_column_int64(stmt, 13), c.sqlite3_column_int(stmt, 14) });
}
