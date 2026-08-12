const std = @import("std");
const postgres = @import("postgres.zig");

const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const required_sqlite_version = 17;

const Kind = enum { text, integer, real, boolean, blob };
const Column = struct { name: []const u8, kind: Kind };
const Table = struct {
    name: []const u8,
    columns: []const Column,
    identity: bool = false,
};

const users = [_]Column{
    .{ .name = "id", .kind = .integer },         .{ .name = "name", .kind = .text },          .{ .name = "safe_name", .kind = .text },
    .{ .name = "password_hash", .kind = .blob }, .{ .name = "password_salt", .kind = .blob }, .{ .name = "email", .kind = .text },
    .{ .name = "country", .kind = .text },       .{ .name = "privileges", .kind = .integer }, .{ .name = "silence_end", .kind = .integer },
    .{ .name = "restricted", .kind = .boolean }, .{ .name = "created_at", .kind = .integer }, .{ .name = "last_login", .kind = .integer },
    .{ .name = "avatar_key", .kind = .integer },
};
const stats = [_]Column{
    .{ .name = "user_id", .kind = .integer },     .{ .name = "mode", .kind = .integer },  .{ .name = "ranked_score", .kind = .integer },
    .{ .name = "total_score", .kind = .integer }, .{ .name = "pp", .kind = .integer },    .{ .name = "plays", .kind = .integer },
    .{ .name = "play_time", .kind = .integer },   .{ .name = "accuracy", .kind = .real }, .{ .name = "max_combo", .kind = .integer },
    .{ .name = "total_hits", .kind = .integer },
};
const beatmaps = [_]Column{
    .{ .name = "id", .kind = .integer },            .{ .name = "set_id", .kind = .integer },        .{ .name = "md5", .kind = .text },
    .{ .name = "artist", .kind = .text },           .{ .name = "title", .kind = .text },            .{ .name = "version", .kind = .text },
    .{ .name = "creator", .kind = .text },          .{ .name = "status", .kind = .integer },        .{ .name = "status_frozen", .kind = .boolean },
    .{ .name = "last_update", .kind = .integer },   .{ .name = "total_length", .kind = .integer },  .{ .name = "max_combo", .kind = .integer },
    .{ .name = "plays", .kind = .integer },         .{ .name = "passes", .kind = .integer },        .{ .name = "mode", .kind = .integer },
    .{ .name = "bpm", .kind = .real },              .{ .name = "cs", .kind = .real },               .{ .name = "ar", .kind = .real },
    .{ .name = "od", .kind = .real },               .{ .name = "hp", .kind = .real },               .{ .name = "star_rating", .kind = .real },
    .{ .name = "source", .kind = .text },           .{ .name = "tags", .kind = .text },             .{ .name = "osu_file", .kind = .blob },
    .{ .name = "count_circles", .kind = .integer }, .{ .name = "count_sliders", .kind = .integer }, .{ .name = "count_spinners", .kind = .integer },
};
const scores = [_]Column{
    .{ .name = "id", .kind = .integer },           .{ .name = "user_id", .kind = .integer },      .{ .name = "map_md5", .kind = .text },
    .{ .name = "mode", .kind = .integer },         .{ .name = "mods", .kind = .integer },         .{ .name = "score", .kind = .integer },
    .{ .name = "pp", .kind = .real },              .{ .name = "accuracy", .kind = .real },        .{ .name = "max_combo", .kind = .integer },
    .{ .name = "n300", .kind = .integer },         .{ .name = "n100", .kind = .integer },         .{ .name = "n50", .kind = .integer },
    .{ .name = "nmiss", .kind = .integer },        .{ .name = "ngeki", .kind = .integer },        .{ .name = "nkatu", .kind = .integer },
    .{ .name = "perfect", .kind = .boolean },      .{ .name = "passed", .kind = .boolean },       .{ .name = "replay", .kind = .blob },
    .{ .name = "submitted_at", .kind = .integer }, .{ .name = "checksum", .kind = .text },        .{ .name = "rank_namespace", .kind = .text },
    .{ .name = "best", .kind = .boolean },         .{ .name = "time_elapsed", .kind = .integer },
};
const score_pins = [_]Column{
    .{ .name = "user_id", .kind = .integer }, .{ .name = "score_id", .kind = .integer }, .{ .name = "pinned_at", .kind = .integer },
};
const friends = [_]Column{ .{ .name = "user_id", .kind = .integer }, .{ .name = "friend_id", .kind = .integer } };
const favourites = [_]Column{ .{ .name = "user_id", .kind = .integer }, .{ .name = "set_id", .kind = .integer }, .{ .name = "created_at", .kind = .integer } };
const ratings = [_]Column{ .{ .name = "user_id", .kind = .integer }, .{ .name = "map_md5", .kind = .text }, .{ .name = "rating", .kind = .integer }, .{ .name = "created_at", .kind = .integer } };
const audit_log = [_]Column{
    .{ .name = "id", .kind = .integer },  .{ .name = "actor_id", .kind = .integer }, .{ .name = "action", .kind = .text },
    .{ .name = "target", .kind = .text }, .{ .name = "detail", .kind = .text },      .{ .name = "created_at", .kind = .integer },
};
const chat_messages = [_]Column{
    .{ .name = "id", .kind = .integer },   .{ .name = "sender_id", .kind = .integer },  .{ .name = "target", .kind = .text },
    .{ .name = "message", .kind = .text }, .{ .name = "created_at", .kind = .integer },
};
const chat_channels = [_]Column{
    .{ .name = "name", .kind = .text },      .{ .name = "topic", .kind = .text },         .{ .name = "write_privileges", .kind = .integer },
    .{ .name = "locked", .kind = .boolean }, .{ .name = "updated_by", .kind = .integer }, .{ .name = "updated_at", .kind = .integer },
};
const beatmap_rank_requests = [_]Column{
    .{ .name = "id", .kind = .integer },           .{ .name = "set_id", .kind = .integer }, .{ .name = "map_id", .kind = .integer },
    .{ .name = "requester_id", .kind = .integer }, .{ .name = "active", .kind = .boolean }, .{ .name = "created_at", .kind = .integer },
    .{ .name = "resolved_at", .kind = .integer },
};
const beatmap_nominations = [_]Column{
    .{ .name = "set_id", .kind = .integer },     .{ .name = "nominator_id", .kind = .integer }, .{ .name = "active", .kind = .boolean },
    .{ .name = "created_at", .kind = .integer }, .{ .name = "updated_at", .kind = .integer },
};
const beatmap_rank_events = [_]Column{
    .{ .name = "id", .kind = .integer },  .{ .name = "set_id", .kind = .integer },      .{ .name = "actor_id", .kind = .integer },
    .{ .name = "action", .kind = .text }, .{ .name = "from_status", .kind = .integer }, .{ .name = "to_status", .kind = .integer },
    .{ .name = "reason", .kind = .text }, .{ .name = "created_at", .kind = .integer },
};
const lazer_scores = [_]Column{
    .{ .name = "id", .kind = .integer },          .{ .name = "user_id", .kind = .integer },      .{ .name = "beatmap_id", .kind = .integer },
    .{ .name = "ruleset_id", .kind = .integer },  .{ .name = "total_score", .kind = .integer },  .{ .name = "legacy_total_score", .kind = .integer },
    .{ .name = "accuracy", .kind = .real },       .{ .name = "max_combo", .kind = .integer },    .{ .name = "passed", .kind = .boolean },
    .{ .name = "mods_json", .kind = .text },      .{ .name = "statistics_json", .kind = .text }, .{ .name = "rank_namespace", .kind = .text },
    .{ .name = "client_version", .kind = .text }, .{ .name = "replay", .kind = .blob },          .{ .name = "submitted_at", .kind = .integer },
};
const custom_mods = [_]Column{
    .{ .name = "acronym", .kind = .text },   .{ .name = "name", .kind = .text },             .{ .name = "description", .kind = .text },
    .{ .name = "ranked", .kind = .boolean }, .{ .name = "score_multiplier", .kind = .real }, .{ .name = "settings_schema", .kind = .text },
};
const oauth_tokens = [_]Column{
    .{ .name = "token_hash", .kind = .blob },    .{ .name = "user_id", .kind = .integer },      .{ .name = "scopes", .kind = .text },
    .{ .name = "client_id", .kind = .integer },  .{ .name = "created_at", .kind = .integer },   .{ .name = "expires_at", .kind = .integer },
    .{ .name = "revoked_at", .kind = .integer }, .{ .name = "last_used_at", .kind = .integer },
};
const beatmap_archives = [_]Column{
    .{ .name = "set_id", .kind = .integer },      .{ .name = "sha256", .kind = .text },              .{ .name = "osz_file", .kind = .blob },
    .{ .name = "imported_at", .kind = .integer }, .{ .name = "last_accessed_at", .kind = .integer },
};
const beatmap_hydration_failures = [_]Column{
    .{ .name = "md5", .kind = .text },              .{ .name = "set_id", .kind = .integer },  .{ .name = "attempts", .kind = .integer },
    .{ .name = "next_retry_at", .kind = .integer }, .{ .name = "last_error", .kind = .text }, .{ .name = "updated_at", .kind = .integer },
};
const client_hardware = [_]Column{
    .{ .name = "user_id", .kind = .integer },            .{ .name = "osu_path_md5", .kind = .text },       .{ .name = "adapters_md5", .kind = .text },
    .{ .name = "uninstall_md5", .kind = .text },         .{ .name = "disk_signature_md5", .kind = .text }, .{ .name = "client_version", .kind = .text },
    .{ .name = "running_under_wine", .kind = .boolean }, .{ .name = "first_seen", .kind = .integer },      .{ .name = "last_seen", .kind = .integer },
    .{ .name = "occurrences", .kind = .integer },
};
const moderation_appeals = [_]Column{
    .{ .name = "id", .kind = .integer },      .{ .name = "user_id", .kind = .integer },    .{ .name = "kind", .kind = .text },
    .{ .name = "message", .kind = .text },    .{ .name = "status", .kind = .text },        .{ .name = "reviewer_id", .kind = .integer },
    .{ .name = "resolution", .kind = .text }, .{ .name = "created_at", .kind = .integer }, .{ .name = "resolved_at", .kind = .integer },
};

const tables = [_]Table{
    .{ .name = "users", .columns = &users, .identity = true },
    .{ .name = "stats", .columns = &stats },
    .{ .name = "beatmaps", .columns = &beatmaps },
    .{ .name = "scores", .columns = &scores, .identity = true },
    .{ .name = "score_pins", .columns = &score_pins },
    .{ .name = "friends", .columns = &friends },
    .{ .name = "favourites", .columns = &favourites },
    .{ .name = "ratings", .columns = &ratings },
    .{ .name = "audit_log", .columns = &audit_log, .identity = true },
    .{ .name = "chat_messages", .columns = &chat_messages, .identity = true },
    .{ .name = "chat_channels", .columns = &chat_channels },
    .{ .name = "beatmap_rank_requests", .columns = &beatmap_rank_requests, .identity = true },
    .{ .name = "beatmap_nominations", .columns = &beatmap_nominations },
    .{ .name = "beatmap_rank_events", .columns = &beatmap_rank_events, .identity = true },
    .{ .name = "lazer_scores", .columns = &lazer_scores, .identity = true },
    .{ .name = "custom_mods", .columns = &custom_mods },
    .{ .name = "oauth_tokens", .columns = &oauth_tokens },
    .{ .name = "beatmap_archives", .columns = &beatmap_archives },
    .{ .name = "beatmap_hydration_failures", .columns = &beatmap_hydration_failures },
    .{ .name = "client_hardware", .columns = &client_hardware },
    .{ .name = "moderation_appeals", .columns = &moderation_appeals, .identity = true },
};

fn sqliteError(db: *sqlite.sqlite3) void {
    std.log.err("sqlite migration source failed: {s}", .{std.mem.span(sqlite.sqlite3_errmsg(db))});
}

fn sqliteQueryInt(db: *sqlite.sqlite3, sql: [:0]const u8) !i64 {
    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != sqlite.SQLITE_OK) {
        sqliteError(db);
        return error.DatabaseQueryFailed;
    }
    defer _ = sqlite.sqlite3_finalize(stmt);
    if (sqlite.sqlite3_step(stmt) != sqlite.SQLITE_ROW) return error.DatabaseQueryFailed;
    return sqlite.sqlite3_column_int64(stmt, 0);
}

fn checkSource(db: *sqlite.sqlite3) !void {
    if (try sqliteQueryInt(db, "PRAGMA user_version") != required_sqlite_version) return error.UnsupportedSqliteSchema;

    var integrity: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &integrity, null) != sqlite.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = sqlite.sqlite3_finalize(integrity);
    if (sqlite.sqlite3_step(integrity) != sqlite.SQLITE_ROW or !std.mem.eql(u8, std.mem.span(sqlite.sqlite3_column_text(integrity, 0)), "ok")) return error.SqliteIntegrityFailed;

    var foreign_keys: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, "PRAGMA foreign_key_check", -1, &foreign_keys, null) != sqlite.SQLITE_OK) return error.DatabaseQueryFailed;
    defer _ = sqlite.sqlite3_finalize(foreign_keys);
    if (sqlite.sqlite3_step(foreign_keys) == sqlite.SQLITE_ROW) return error.SqliteForeignKeyFailed;
}

fn appendQuotedColumns(allocator: std.mem.Allocator, list: *std.ArrayList(u8), columns: []const Column) !void {
    for (columns, 0..) |column, index| {
        if (index != 0) try list.append(allocator, ',');
        try list.append(allocator, '"');
        try list.appendSlice(allocator, column.name);
        try list.append(allocator, '"');
    }
}

fn sourceSql(allocator: std.mem.Allocator, table: Table) ![:0]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, "SELECT ");
    try appendQuotedColumns(allocator, &list, table.columns);
    try list.appendSlice(allocator, " FROM \"");
    try list.appendSlice(allocator, table.name);
    try list.appendSlice(allocator, "\" ORDER BY rowid");
    return allocator.dupeZ(u8, list.items);
}

fn insertSql(allocator: std.mem.Allocator, table: Table) ![:0]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, "INSERT INTO zigcho.\"");
    try list.appendSlice(allocator, table.name);
    try list.appendSlice(allocator, "\" (");
    try appendQuotedColumns(allocator, &list, table.columns);
    try list.appendSlice(allocator, ") VALUES (");
    for (table.columns, 0..) |_, index| {
        if (index != 0) try list.append(allocator, ',');
        const placeholder = try std.fmt.allocPrint(allocator, "${d}", .{index + 1});
        defer allocator.free(placeholder);
        try list.appendSlice(allocator, placeholder);
    }
    try list.appendSlice(allocator, ")");
    return allocator.dupeZ(u8, list.items);
}

fn hexBlob(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '\\';
    out[1] = 'x';
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[2 + index * 2] = alphabet[byte >> 4];
        out[3 + index * 2] = alphabet[byte & 0x0f];
    }
    return out;
}

fn ownedSqliteValue(allocator: std.mem.Allocator, stmt: *sqlite.sqlite3_stmt, column: usize, kind: Kind) !?[]u8 {
    if (sqlite.sqlite3_column_type(stmt, @intCast(column)) == sqlite.SQLITE_NULL) return null;
    return switch (kind) {
        .text => try allocator.dupe(u8, std.mem.span(sqlite.sqlite3_column_text(stmt, @intCast(column)))),
        .integer => try std.fmt.allocPrint(allocator, "{d}", .{sqlite.sqlite3_column_int64(stmt, @intCast(column))}),
        .real => try std.fmt.allocPrint(allocator, "{d}", .{sqlite.sqlite3_column_double(stmt, @intCast(column))}),
        .boolean => try allocator.dupe(u8, if (sqlite.sqlite3_column_int(stmt, @intCast(column)) == 0) "false" else "true"),
        .blob => blob: {
            const len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, @intCast(column)));
            if (len == 0) break :blob try allocator.dupe(u8, "\\x");
            const ptr: [*]const u8 = @ptrCast(sqlite.sqlite3_column_blob(stmt, @intCast(column)));
            break :blob try hexBlob(allocator, ptr[0..len]);
        },
    };
}

fn copyTable(allocator: std.mem.Allocator, source: *sqlite.sqlite3, target: *postgres.c.PGconn, table: Table) !u64 {
    const select_sql = try sourceSql(allocator, table);
    defer allocator.free(select_sql);
    const insert_sql = try insertSql(allocator, table);
    defer allocator.free(insert_sql);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(source, select_sql.ptr, -1, &stmt, null) != sqlite.SQLITE_OK) {
        sqliteError(source);
        return error.DatabaseQueryFailed;
    }
    defer _ = sqlite.sqlite3_finalize(stmt);

    const params = try allocator.alloc(?[]const u8, table.columns.len);
    defer allocator.free(params);
    const owned = try allocator.alloc(?[]u8, table.columns.len);
    defer allocator.free(owned);

    var count: u64 = 0;
    while (true) {
        const step = sqlite.sqlite3_step(stmt);
        if (step == sqlite.SQLITE_DONE) break;
        if (step != sqlite.SQLITE_ROW) {
            sqliteError(source);
            return error.DatabaseQueryFailed;
        }
        @memset(owned, null);
        defer for (owned) |value| if (value) |bytes| allocator.free(bytes);
        for (table.columns, 0..) |column, index| {
            const value = try ownedSqliteValue(allocator, stmt.?, index, column.kind);
            owned[index] = value;
            params[index] = if (value) |bytes| bytes else null;
        }
        var result = try postgres.queryParams(allocator, target, insert_sql, params);
        result.deinit();
        count += 1;
    }
    return count;
}

fn pgInt(target: *postgres.c.PGconn, allocator: std.mem.Allocator, sql: []const u8) !i64 {
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    var result = try postgres.query(target, sql_z);
    defer result.deinit();
    if (result.rows() != 1 or result.columns() != 1 or result.isNull(0, 0)) return error.DatabaseQueryFailed;
    return std.fmt.parseInt(i64, result.value(0, 0), 10);
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ![:0]u8 {
    const bytes = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(bytes);
    return allocator.dupeZ(u8, bytes);
}

fn tableCountSql(allocator: std.mem.Allocator, prefix: []const u8, table: Table) ![:0]u8 {
    return allocPrintZ(allocator, "SELECT count(*) FROM {s}\"{s}\"", .{ prefix, table.name });
}

fn verifyCounts(allocator: std.mem.Allocator, source: *sqlite.sqlite3, target: *postgres.c.PGconn) !void {
    for (tables) |table| {
        const source_sql = try tableCountSql(allocator, "", table);
        defer allocator.free(source_sql);
        const target_sql = try tableCountSql(allocator, "zigcho.", table);
        defer allocator.free(target_sql);
        const source_count = try sqliteQueryInt(source, source_sql);
        const target_count = try pgInt(target, allocator, target_sql);
        if (source_count != target_count) return error.PostgresParityFailed;
    }

    const source_blob_bytes = try sqliteQueryInt(source, "SELECT " ++
        "coalesce((SELECT sum(length(password_hash)+length(password_salt)) FROM users),0)+" ++
        "coalesce((SELECT sum(length(osu_file)) FROM beatmaps),0)+" ++
        "coalesce((SELECT sum(length(replay)) FROM scores),0)+" ++
        "coalesce((SELECT sum(length(replay)) FROM lazer_scores),0)+" ++
        "coalesce((SELECT sum(length(token_hash)) FROM oauth_tokens),0)+" ++
        "coalesce((SELECT sum(length(osz_file)) FROM beatmap_archives),0)");
    const target_blob_bytes = try pgInt(target, allocator, "SELECT " ++
        "coalesce((SELECT sum(octet_length(password_hash)+octet_length(password_salt)) FROM zigcho.users),0)+" ++
        "coalesce((SELECT sum(octet_length(osu_file)) FROM zigcho.beatmaps),0)+" ++
        "coalesce((SELECT sum(octet_length(replay)) FROM zigcho.scores),0)+" ++
        "coalesce((SELECT sum(octet_length(replay)) FROM zigcho.lazer_scores),0)+" ++
        "coalesce((SELECT sum(octet_length(token_hash)) FROM zigcho.oauth_tokens),0)+" ++
        "coalesce((SELECT sum(octet_length(osz_file)) FROM zigcho.beatmap_archives),0)");
    if (source_blob_bytes != target_blob_bytes) return error.PostgresParityFailed;
}

fn resetIdentities(allocator: std.mem.Allocator, target: *postgres.c.PGconn) !void {
    for (tables) |table| {
        if (!table.identity) continue;
        const sql = try allocPrintZ(allocator, "SELECT setval(pg_get_serial_sequence('zigcho.\"{s}\"','id'),coalesce((SELECT max(id) FROM zigcho.\"{s}\"),1),(SELECT count(*)!=0 FROM zigcho.\"{s}\"))", .{ table.name, table.name, table.name });
        defer allocator.free(sql);
        var result = try postgres.query(target, sql);
        result.deinit();
    }
}

fn targetIsFresh(target: *postgres.c.PGconn) !bool {
    var result = try postgres.query(target, "SELECT to_regnamespace('zigcho') IS NULL");
    defer result.deinit();
    return result.rows() == 1 and std.mem.eql(u8, result.value(0, 0), "t");
}

fn migrate(allocator: std.mem.Allocator, sqlite_path: [:0]const u8, conninfo: [:0]const u8) !void {
    var source_ptr: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open_v2(sqlite_path.ptr, &source_ptr, sqlite.SQLITE_OPEN_READONLY | sqlite.SQLITE_OPEN_NOMUTEX, null) != sqlite.SQLITE_OK) return error.DatabaseOpenFailed;
    const source = source_ptr.?;
    defer _ = sqlite.sqlite3_close(source);
    try checkSource(source);

    const target = try postgres.connect(conninfo);
    defer postgres.c.PQfinish(target);
    if (!try targetIsFresh(target)) return error.PostgresTargetNotEmpty;

    try postgres.exec(target, "BEGIN ISOLATION LEVEL SERIALIZABLE");
    errdefer postgres.exec(target, "ROLLBACK") catch {};
    try postgres.exec(target, @embedFile("postgres_schema.sql"));
    for (tables) |table| {
        const copied = try copyTable(allocator, source, target, table);
        std.debug.print("  {s}: {d}\n", .{ table.name, copied });
    }
    try resetIdentities(allocator, target);
    try verifyCounts(allocator, source, target);
    try postgres.exec(target, "ANALYZE");
    try postgres.exec(target, "COMMIT");
    std.debug.print("postgres migration verified: schema v{d}, all table counts and blob bytes match\n", .{required_sqlite_version});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len != 2) {
        std.debug.print("usage: ZIGCHO_POSTGRES_URL='...' zigcho-migrate-postgres <sqlite-db>\n", .{});
        return error.InvalidArguments;
    }
    const conninfo_value = init.environ_map.get("ZIGCHO_POSTGRES_URL") orelse {
        std.debug.print("ZIGCHO_POSTGRES_URL is required; keep credentials out of process arguments\n", .{});
        return error.MissingPostgresUrl;
    };
    const sqlite_path = try allocator.dupeZ(u8, args[1]);
    defer allocator.free(sqlite_path);
    const conninfo = try allocator.dupeZ(u8, conninfo_value);
    defer allocator.free(conninfo);
    try migrate(allocator, sqlite_path, conninfo);
}

test "postgres table inventory stays at the current sqlite schema" {
    try std.testing.expectEqual(@as(usize, 21), tables.len);
    try std.testing.expectEqualStrings("users", tables[0].name);
    try std.testing.expectEqualStrings("moderation_appeals", tables[tables.len - 1].name);
}
