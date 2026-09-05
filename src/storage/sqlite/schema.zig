const std = @import("std");
const lazer = @import("../../lazer.zig");
const database_sql = @import("database_sql");
const c = @import("../../storage.zig").c;
const Store = @import("../../storage.zig").Store;

pub fn migrate(self: *Store) !void {
    try self.exec(database_sql.sqlite_schema);
    var version: i32 = 0;
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA user_version", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) version = c.sqlite3_column_int(stmt, 0);
    _ = c.sqlite3_finalize(stmt);
    const needs_score_rebuild = version < 44;
    if (version < 2) try self.exec(database_sql.sqliteMigration(2));
    if (version < 3) try self.exec(database_sql.sqliteMigration(3));
    if (version < 4) try self.exec(database_sql.sqliteMigration(4));
    if (version < 5) try self.exec(database_sql.sqliteMigration(5));
    if (version < 6) try self.exec(database_sql.sqliteMigration(6));
    if (version < 7) try self.exec(database_sql.sqliteMigration(7));
    if (version < 8) try self.exec(database_sql.sqliteMigration(8));
    if (version < 9) try self.exec(database_sql.sqliteMigration(9));
    if (version < 10) {
        if (try self.hasAvatarColumn())
            try self.exec("PRAGMA user_version=10")
        else
            try self.exec(database_sql.sqliteMigration(10));
    }
    if (version < 11) try self.exec(database_sql.sqliteMigration(11));
    if (version < 12) try self.exec(database_sql.sqliteMigration(12));
    if (version < 13) try self.exec(database_sql.sqliteMigration(13));
    if (version < 14) {
        if (try self.hasBeatmapStatusFrozenColumn())
            try self.exec("PRAGMA user_version=14")
        else
            try self.exec(database_sql.sqliteMigration(14));
    }
    if (version < 15) try self.exec(database_sql.sqliteMigration(15));
    if (version < 16) try self.exec(database_sql.sqliteMigration(16));
    if (version < 17) {
        if (try self.hasBeatmapArchiveAccessColumn())
            try self.exec("PRAGMA user_version=17")
        else
            try self.exec(database_sql.sqliteMigration(17));
    }
    if (version < 18) try self.exec(database_sql.sqliteMigration(18));
    if (version < 19) try self.exec(database_sql.sqliteMigration(19));
    if (version < 20) try self.exec(database_sql.sqliteMigration(20));
    if (version < 21) {
        if (try self.hasLazerLeaderboardColumns())
            try self.exec("PRAGMA user_version=21")
        else
            try self.exec(database_sql.sqliteMigration(21));
    }
    if (version < 22) {
        if (try self.hasLazerPerformanceColumns())
            try self.exec("UPDATE lazer_scores SET best=1 WHERE id IN (SELECT id FROM (SELECT id,row_number() OVER (PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) place FROM lazer_scores WHERE passed=1) ranked WHERE place=1); PRAGMA user_version=22")
        else
            try self.exec(database_sql.sqliteMigration(22));
    }
    if (version < 23) {
        if (try self.hasSiteProfileSchema())
            try self.exec("PRAGMA user_version=23")
        else
            try self.exec(database_sql.sqliteMigration(23));
    }
    if (version < 24) {
        if (try self.hasExpandedSiteProfileSchema())
            try self.exec("PRAGMA user_version=24")
        else
            try self.exec(database_sql.sqliteMigration(24));
    }
    if (version < 25) {
        if (try self.hasAnticheatReviewSchema())
            try self.exec("PRAGMA user_version=25")
        else
            try self.exec(database_sql.sqliteMigration(25));
    }
    if (version < 26) {
        if (try self.hasAnticheatGameplaySchema())
            try self.exec("PRAGMA user_version=26")
        else
            try self.exec(database_sql.sqliteMigration(26));
    }
    if (version < 27) {
        if (try self.hasLazerChatSchema())
            try self.exec("PRAGMA user_version=27")
        else
            try self.exec(database_sql.sqliteMigration(27));
    }
    if (version < 28) {
        if (try self.hasLazerDirectMessageColumns())
            try self.exec("CREATE UNIQUE INDEX IF NOT EXISTS direct_messages_sender_uuid ON direct_messages(from_id,client_uuid) WHERE client_uuid!=''; UPDATE custom_mods SET ranked=1; CREATE TABLE IF NOT EXISTS user_achievements(user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,achievement_id INTEGER NOT NULL CHECK(achievement_id>0),score_source TEXT NOT NULL CHECK(score_source IN ('stable','lazer')),score_id INTEGER NOT NULL CHECK(score_id>0),achieved_at INTEGER NOT NULL DEFAULT (unixepoch()),PRIMARY KEY(user_id,achievement_id)); CREATE INDEX IF NOT EXISTS user_achievements_score ON user_achievements(score_source,score_id); PRAGMA user_version=28")
        else
            try self.exec(database_sql.sqliteMigration(28));
    }
    if (version < 29) {
        if (try self.hasScoreStarRatingColumns())
            try self.exec("UPDATE scores SET star_rating=coalesce(nullif(star_rating,0),(SELECT b.star_rating FROM beatmaps b WHERE b.md5=scores.map_md5),0); UPDATE lazer_scores SET star_rating=coalesce(nullif(star_rating,0),(SELECT b.star_rating FROM beatmaps b WHERE b.id=lazer_scores.beatmap_id),0); PRAGMA user_version=29")
        else
            try self.exec(database_sql.sqliteMigration(29));
    }
    if (version < 31) {
        if (try self.hasBeatmapArchiveSizeColumn())
            try self.exec("UPDATE beatmap_archives SET object_bytes=length(osz_file) WHERE object_bytes=0; PRAGMA user_version=31")
        else
            try self.exec("ALTER TABLE beatmap_archives ADD COLUMN object_bytes INTEGER NOT NULL DEFAULT 0 CHECK(object_bytes>=0); UPDATE beatmap_archives SET object_bytes=length(osz_file); PRAGMA user_version=31");
    }
    if (version < 32) try self.exec(database_sql.sqliteMigration(32));
    if (version < 33) {
        if (try self.hasAccountTeamSchema())
            try self.exec("PRAGMA user_version=33")
        else
            try self.exec(database_sql.sqliteMigration(33));
    }
    if (version < 34) try self.exec(database_sql.sqliteMigration(34));
    if (version < 35) {
        if (try self.hasUpstreamBeatmapSchema())
            try self.exec(
                "BEGIN IMMEDIATE;" ++
                    "UPDATE bss_counters SET next_id=max(next_id,1000000000);" ++
                    "CREATE UNIQUE INDEX IF NOT EXISTS beatmap_submissions_replacement ON beatmap_submissions(replacement_set_id) WHERE replacement_set_id IS NOT NULL;" ++
                    "CREATE INDEX IF NOT EXISTS upstream_users_name ON upstream_users(lower(username),fetched_at DESC,id);" ++
                    "CREATE INDEX IF NOT EXISTS beatmaps_creator_id ON beatmaps(creator_id,set_id);" ++
                    "PRAGMA user_version=35;" ++
                    "COMMIT",
            )
        else
            try self.exec(database_sql.sqliteMigration(35));
    }
    if (version < 36) try self.exec(database_sql.sqliteMigration(36));
    if (version < 37) try self.exec(database_sql.sqliteMigration(37));
    if (version < 38) {
        if (try self.hasDirectMessageChatLink())
            try self.exec("BEGIN IMMEDIATE; CREATE UNIQUE INDEX IF NOT EXISTS direct_messages_chat_message ON direct_messages(chat_message_id) WHERE chat_message_id IS NOT NULL; PRAGMA user_version=38; COMMIT")
        else
            try self.exec(database_sql.sqliteMigration(38));
    }
    if (version < 39) try self.exec(database_sql.sqliteMigration(39));
    if (version < 40) try self.exec(database_sql.sqliteMigration(40));
    if (version < 41) try self.exec(database_sql.sqliteMigration(41));
    if (version < 42) try self.exec(database_sql.sqliteMigration(42));
    if (version < 43) {
        if (try self.hasLazerTotalScoreWithoutModsColumn())
            try self.finishExistingLazerScoreSemanticsMigration(!try self.hasLazerScoreSemanticMarker())
        else
            try self.exec(database_sql.sqliteMigration(43));
    }
    if (version < 44) try self.exec(database_sql.sqliteMigration(44));
    if (version < 45) try self.exec(database_sql.sqliteMigration(45));
    if (version < 46) try self.exec(database_sql.sqliteMigration(46));
    try self.backfillLazerClassicScores();
    try self.exec("DELETE FROM user_stats_history WHERE day<((unixepoch()/86400)-89)*86400");
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

pub fn hasLazerPerformanceColumns(self: *Store) !bool {
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

pub fn hasScoreStarRatingColumns(self: *Store) !bool {
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

pub fn hasLazerChatSchema(self: *Store) !bool {
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

pub fn hasLazerDirectMessageColumns(self: *Store) !bool {
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

pub fn hasDirectMessageChatLink(self: *Store) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(direct_messages)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "chat_message_id")) return true;
    }
    return false;
}

pub fn hasSiteProfileSchema(self: *Store) !bool {
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

pub fn hasExpandedSiteProfileSchema(self: *Store) !bool {
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

pub fn hasAccountTeamSchema(self: *Store) !bool {
    var columns: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(users)", -1, &columns, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(columns);
    var username_changes = false;
    var username_changed_at = false;
    while (c.sqlite3_step(columns) == c.SQLITE_ROW) {
        const name = std.mem.span(c.sqlite3_column_text(columns, 1));
        if (std.mem.eql(u8, name, "username_changes")) username_changes = true;
        if (std.mem.eql(u8, name, "username_changed_at")) username_changed_at = true;
    }
    if (!username_changes or !username_changed_at) return false;
    var tables: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN('user_name_changes','user_banners','teams','team_members','team_applications','team_assets','lazer_presence','replay_objects','profile_score_pins','lazer_reports','beatmap_tag_votes')", -1, &tables, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(tables);
    return c.sqlite3_step(tables) == c.SQLITE_ROW and c.sqlite3_column_int(tables, 0) == 11;
}

pub fn hasUpstreamBeatmapSchema(self: *Store) !bool {
    var submission_columns: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(beatmap_submissions)", -1, &submission_columns, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(submission_columns);
    var have_replacement = false;
    while (c.sqlite3_step(submission_columns) == c.SQLITE_ROW) {
        if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(submission_columns, 1)), "replacement_set_id")) {
            have_replacement = true;
            break;
        }
    }
    if (!have_replacement) return false;

    var beatmap_columns: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(beatmaps)", -1, &beatmap_columns, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(beatmap_columns);
    var found: u8 = 0;
    while (c.sqlite3_step(beatmap_columns) == c.SQLITE_ROW) {
        const name = std.mem.span(c.sqlite3_column_text(beatmap_columns, 1));
        if (std.mem.eql(u8, name, "creator_id") or
            std.mem.eql(u8, name, "upstream_plays") or
            std.mem.eql(u8, name, "upstream_passes") or
            std.mem.eql(u8, name, "hit_length")) found += 1;
    }
    if (found != 4) return false;

    var tables: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN('upstream_users','upstream_user_profiles','beatmapset_metadata')", -1, &tables, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(tables);
    return c.sqlite3_step(tables) == c.SQLITE_ROW and c.sqlite3_column_int(tables, 0) == 3;
}

pub fn hasAnticheatReviewSchema(self: *Store) !bool {
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

pub fn hasAnticheatGameplaySchema(self: *Store) !bool {
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

pub fn hasAvatarColumn(self: *Store) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(users)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "avatar_key")) return true;
    }
    return false;
}

pub fn hasBeatmapStatusFrozenColumn(self: *Store) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(beatmaps)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "status_frozen")) return true;
    }
    return false;
}

pub fn hasBeatmapArchiveAccessColumn(self: *Store) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(beatmap_archives)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "last_accessed_at")) return true;
    }
    return false;
}

pub fn hasBeatmapArchiveSizeColumn(self: *Store) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(beatmap_archives)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "object_bytes")) return true;
    }
    return false;
}

pub fn hasLazerLeaderboardColumns(self: *Store) !bool {
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

pub fn hasLazerTotalScoreWithoutModsColumn(self: *Store) !bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "PRAGMA table_info(lazer_scores)", -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)), "total_score_without_mods")) return true;
    }
    return false;
}

pub fn hasLazerScoreSemanticMarker(self: *Store) !bool {
    // The column can survive a partial/manual migration. The legacy guard
    // pair is created only after the old value has been moved and cleared.
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN('lazer_scores_legacy_total_score_insert','lazer_scores_legacy_total_score_update')";
    if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseQueryFailed;
    return c.sqlite3_column_int(stmt, 0) == 2;
}

pub fn finishExistingLazerScoreSemanticsMigration(self: *Store, repair_legacy_rows: bool) !void {
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    if (repair_legacy_rows) try self.exec("UPDATE lazer_scores SET total_score_without_mods=coalesce(legacy_total_score,total_score),legacy_total_score=NULL");
    try self.exec(
        "CREATE TRIGGER IF NOT EXISTS lazer_scores_legacy_total_score_insert BEFORE INSERT ON lazer_scores WHEN NEW.legacy_total_score IS NOT NULL AND (typeof(NEW.legacy_total_score)!='integer' OR NEW.legacy_total_score<0 OR NEW.legacy_total_score>2147483647) BEGIN SELECT raise(ABORT,'legacy_total_score outside nullable int32 range'); END;" ++
            "CREATE TRIGGER IF NOT EXISTS lazer_scores_legacy_total_score_update BEFORE UPDATE OF legacy_total_score ON lazer_scores WHEN NEW.legacy_total_score IS NOT NULL AND (typeof(NEW.legacy_total_score)!='integer' OR NEW.legacy_total_score<0 OR NEW.legacy_total_score>2147483647) BEGIN SELECT raise(ABORT,'legacy_total_score outside nullable int32 range'); END;" ++
            "CREATE TRIGGER IF NOT EXISTS lazer_scores_total_score_without_mods_insert BEFORE INSERT ON lazer_scores WHEN NEW.total_score_without_mods IS NULL OR typeof(NEW.total_score_without_mods)!='integer' OR NEW.total_score_without_mods<0 OR NEW.total_score_without_mods>1000000000000 BEGIN SELECT raise(ABORT,'total_score_without_mods outside required range'); END;" ++
            "CREATE TRIGGER IF NOT EXISTS lazer_scores_total_score_without_mods_update BEFORE UPDATE OF total_score_without_mods ON lazer_scores WHEN NEW.total_score_without_mods IS NULL OR typeof(NEW.total_score_without_mods)!='integer' OR NEW.total_score_without_mods<0 OR NEW.total_score_without_mods>1000000000000 BEGIN SELECT raise(ABORT,'total_score_without_mods outside required range'); END;" ++
            "UPDATE lazer_scores SET total_score_without_mods=total_score_without_mods,legacy_total_score=legacy_total_score;" ++
            "PRAGMA user_version=43;" ++
            "COMMIT",
    );
}

pub fn backfillLazerClassicScores(self: *Store) !void {
    try self.exec("BEGIN IMMEDIATE");
    errdefer self.exec("ROLLBACK") catch {};
    var rows: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "SELECT id,ruleset_id,total_score,statistics_json,maximum_statistics_json FROM lazer_scores WHERE legacy_total_score IS NULL ORDER BY id", -1, &rows, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(rows);
    var update: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(self.db, "UPDATE lazer_scores SET legacy_total_score=?1 WHERE id=?2 AND legacy_total_score IS NULL", -1, &update, null) != c.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = c.sqlite3_finalize(update);
    while (c.sqlite3_step(rows) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(rows, 0);
        const ruleset_id = c.sqlite3_column_int64(rows, 1);
        const total_score = c.sqlite3_column_int64(rows, 2);
        const statistics_json = std.mem.span(c.sqlite3_column_text(rows, 3));
        const maximum_statistics_json = std.mem.span(c.sqlite3_column_text(rows, 4));
        const classic = lazer.classicTotalScoreFromJson(self.allocator, ruleset_id, total_score, statistics_json, maximum_statistics_json) catch lazer.stableLegacyTotalScore(total_score);
        _ = c.sqlite3_reset(update);
        _ = c.sqlite3_clear_bindings(update);
        _ = c.sqlite3_bind_int(update, 1, classic);
        _ = c.sqlite3_bind_int64(update, 2, id);
        if (c.sqlite3_step(update) != c.SQLITE_DONE) return error.DatabaseQueryFailed;
    }
    try self.exec("COMMIT");
}

pub fn rebuildScoreStats(self: *Store, own_transaction: bool) !void {
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
