const d = @import("deps.zig");
const std = d.std;
const builtin = d.builtin;
const storage = d.storage;
const sqlite_storage = d.sqlite_storage;
const sessions_mod = d.sessions_mod;
const bancho = d.bancho;
const lazer_bot = d.lazer_bot;
const lazer_multiplayer = d.lazer_multiplayer;
const lazer_spectator = d.lazer_spectator;
const rate_limit = d.rate_limit;
const beatmap_sync = d.beatmap_sync;
const beatmap_media = d.beatmap_media;
const webhook = d.webhook;
const anticheat_abi = d.anticheat_abi;
const anticheat_plugin = d.anticheat_plugin;
const config_mod = d.config_mod;
const avatar_cache = d.avatar_cache;
const changelog = d.changelog;
const http_boundary = d.http_boundary;

const App = @import("app.zig").App;
const lifecycle = @import("lifecycle.zig");
const objects = @import("cli/objects.zig");
const recalc = @import("cli/recalc.zig");
const workers = @import("workers/maintenance.zig");
const irc_transport = @import("irc/transport.zig");
const connection = @import("http/connection.zig");

pub fn run(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len > 1 and try objects.objectTransferCommand(allocator, init.io, args[1..])) return;
    if (args.len > 1 and try objects.mirrorWorkerCommand(allocator, init.io, args[1..])) return;
    if (args.len > 1 and std.mem.eql(u8, args[1], "check")) {
        if (args.len > 2) return error.UnexpectedCheckArgument;
        const database: [:0]const u8 = if (storage.is_postgres)
            std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
        else
            "zigcho.db";
        var store = try storage.Store.open(allocator, init.io, database);
        defer store.close();
        try store.migrate();
        const kai = (try store.userById(allocator, 3)) orelse return error.SystemBotMissing;
        defer {
            allocator.free(kai.name);
            allocator.free(kai.safe_name);
        }
        if (!std.mem.eql(u8, kai.safe_name, "kai")) return error.InvalidSystemBot;
        const counts = try store.serverCounts();
        std.log.info("event=preflight_ok storage={s} accounts={d} plays={d} passed={d} beatmaps={d}", .{
            if (storage.is_postgres) "postgres" else "sqlite",
            counts.users,
            counts.plays,
            counts.passed,
            counts.maps,
        });
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "object-migrate")) {
        if (storage.is_postgres and args.len > 2) return error.PostgresUrlMustUseEnvironment;
        const database: [:0]const u8 = if (storage.is_postgres)
            std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
        else if (args.len > 2)
            try allocator.dupeZ(u8, args[2])
        else
            "zigcho.db";
        defer if (!storage.is_postgres and args.len > 2) allocator.free(database);
        var store = try storage.Store.open(allocator, init.io, database);
        defer store.close();
        try store.migrate();
        var config = try config_mod.load(allocator, init.io);
        defer config.deinit();
        const object_store = objects.configuredObjectStore(config);
        if (!object_store.enabled()) return error.ObjectStorageNotConfigured;
        store.bindObjectStorage(object_store);
        const maps = try store.migrateBeatmapObjects();
        const avatars = try objects.migrateAvatarObjects(allocator, &store, objects.configuredLegacyAvatarStore(config), object_store);
        std.log.info("event=object_migration_complete archives={d} media={d} replays={d} replay_bytes={d} avatars={d} failed={d}", .{ maps.archives, maps.media, maps.replays, maps.replay_bytes, avatars.migrated, maps.failed + avatars.failed });
        if (maps.failed + avatars.failed != 0) return error.ObjectMigrationIncomplete;
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "object-purge")) {
        if (!storage.is_postgres) return error.ObjectPurgeRequiresPostgres;
        if (args.len > 2) return error.PostgresUrlMustUseEnvironment;
        const database = std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl);
        var store = try storage.Store.open(allocator, init.io, database);
        defer store.close();
        try store.migrate();
        var config = try config_mod.load(allocator, init.io);
        defer config.deinit();
        const object_store = objects.configuredObjectStore(config);
        if (!object_store.enabled()) return error.ObjectStorageNotConfigured;
        store.bindObjectStorage(object_store);
        const avatars = try objects.migrateAvatarObjects(allocator, &store, objects.configuredLegacyAvatarStore(config), object_store);
        if (avatars.failed != 0) return error.ObjectMigrationIncomplete;
        const purged = try store.purgeBeatmapObjectBackups();
        std.log.info("event=object_purge_complete archives={d} archive_bytes={d} media={d} media_bytes={d} avatars={d}", .{ purged.archives, purged.archive_bytes, purged.media, purged.media_bytes, avatars.migrated });
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "recalc")) {
        if (storage.is_postgres) {
            if (args.len > 2) return error.PostgresUrlMustUseEnvironment;
            const conninfo = std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl);
            var store = try storage.Store.open(allocator, init.io, conninfo);
            defer store.close();
            try store.migrate();
            const count = try store.recalculatePerformance(allocator);
            std.log.info("event=postgres_pp_recalc_complete scores={d}", .{count});
        } else {
            const db_path: [:0]const u8 = if (args.len > 2) try allocator.dupeZ(u8, args[2]) else "zigcho.db";
            defer if (args.len > 2) allocator.free(db_path);
            var store = try sqlite_storage.Store.open(allocator, init.io, db_path);
            defer store.close();
            try store.migrate();
            try recalc.recalcAllScores(allocator, &store);
        }
        return;
    }
    const bind = if (args.len > 1) args[1] else "127.0.0.1";
    const port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 8080;
    if (storage.is_postgres and args.len > 3) return error.PostgresUrlMustUseEnvironment;
    const default_database: [:0]const u8 = if (storage.is_postgres)
        std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
    else
        "zigcho.db";
    const db_path: [:0]const u8 = if (args.len > 3) try allocator.dupeZ(u8, args[3]) else default_database;
    defer if (args.len > 3) allocator.free(db_path);
    var store = try storage.Store.open(allocator, init.io, db_path);
    defer store.close();
    try store.migrate();
    var config = try config_mod.load(allocator, init.io);
    defer config.deinit();
    const object_store = objects.configuredObjectStore(config);
    store.bindObjectStorage(object_store);
    const anticheat: ?anticheat_plugin.Host = if (config.anticheat_module_path.len == 0)
        null
    else
        try anticheat_plugin.Host.open(config.anticheat_module_path);
    var app: App = .{
        .allocator = allocator,
        .store = store,
        .sessions = sessions_mod.Sessions.init(allocator, init.io),
        .lazer_bot = lazer_bot.Manager.init(allocator, init.io),
        .lazer_multiplayer = lazer_multiplayer.Manager.init(allocator, init.io),
        .lazer_spectator = lazer_spectator.Manager.init(allocator, init.io),
        .limiter = rate_limit.Limiter.init(allocator, init.io),
        .map_sync = beatmap_sync.Sync.init(allocator, init.io, config.beatmap_cache_max_bytes),
        .media_sync = beatmap_media.Sync.init(allocator, init.io, config.beatmap_media_cache_max_bytes),
        .score_webhook = webhook.Webhook.init(allocator, init.io, config.score_webhook),
        .anticheat = anticheat,
        .anticheat_allow_sample_modulus = config.anticheat_allow_sample_modulus,
        .avatar_store = if (object_store.enabled()) object_store else objects.configuredLegacyAvatarStore(config),
        .avatar_cache = avatar_cache.Cache.init(allocator, init.io),
        .geo_client = .{ .allocator = allocator, .io = init.io },
        .changelog_feed = changelog.Feed.init(allocator, init.io),
        .started_at = std.Io.Clock.real.now(init.io).toSeconds(),
        .http_gate = .init(config.http_max_connections),
        .http_header_timeout_seconds = config.http_header_timeout_seconds,
        .http_request_timeout_seconds = config.http_request_timeout_seconds,
        .http_long_request_timeout_seconds = config.http_long_request_timeout_seconds,
    };
    app.map_sync.bindOsuApiKey(config.osu_api_key);
    var kai = (try app.store.userById(allocator, 3)) orelse return error.SystemBotMissing;
    try app.lazer_multiplayer.bindStore(&app.store);
    app.lazer_multiplayer.bindBeatmapSync(&app.map_sync);
    app.lazer_multiplayer.setEnabled(try app.store.serverControlEnabled(.lazer_multiplayer));
    app.lazer_multiplayer.refreshMatchmakingMaps() catch |err| std.log.warn("event=lazer_matchmaking_pool_startup_failed error={t}", .{err});
    app.lazer_spectator.bindStore(&app.store);
    app.lazer_spectator.setEnabled(try app.store.serverControlEnabled(.spectator));
    kai.country = .{ 'I', 'S' };
    const kai_session = try app.sessions.createBot(kai);
    kai_session.longitude = -21.9426; // reykjavik
    kai_session.latitude = 64.1466;
    if (app.anticheat) |*loaded| std.log.info("event=anticheat_module_loaded module={s} abi={d} rule_revision={d} mode=observe", .{ loaded.name(), anticheat_abi.version, loaded.ruleRevision() });
    defer if (app.anticheat) |*loaded| loaded.close();
    defer app.score_webhook.deinit();
    defer app.avatar_cache.deinit();
    defer app.changelog_feed.deinit();
    defer app.map_sync.deinit();
    defer app.geo_client.deinit();
    defer app.limiter.deinit();
    defer app.lazer_spectator.deinit();
    defer app.lazer_multiplayer.deinit();
    defer app.lazer_bot.deinit();
    defer app.sessions.deinit();
    const address = try std.Io.net.IpAddress.parse(bind, port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    lifecycle.shutdown_requested.store(false, .release);
    lifecycle.restart_requested.store(false, .release);
    lifecycle.shutdown_listener_fd.store(@intCast(listener.socket.handle), .release);
    defer lifecycle.shutdown_listener_fd.store(-1, .release);
    if (comptime builtin.os.tag != .windows and std.posix.Sigaction != void) {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = lifecycle.requestShutdown },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var old_term: std.posix.Sigaction = undefined;
        var old_int: std.posix.Sigaction = undefined;
        std.posix.sigaction(.TERM, &action, &old_term);
        std.posix.sigaction(.INT, &action, &old_int);
        defer std.posix.sigaction(.TERM, &old_term, null);
        defer std.posix.sigaction(.INT, &old_int, null);
    }
    var connections: std.Io.Group = .init;
    defer connections.cancel(init.io);
    // Run before the connection group is cancelled so the pinned lazer client
    // receives ServerShuttingDown and active room archives are durable.
    defer app.lazer_multiplayer.shutdown();
    try connections.concurrent(init.io, workers.multiplayerMaintenance, .{ &app, init.io });
    try connections.concurrent(init.io, workers.changelogRefreshWorker, .{ &app, init.io });
    if (config.irc_port != 0) try connections.concurrent(init.io, irc_transport.serveIrcListener, .{ &app, config.irc_bind, config.irc_port, init.io });
    std.log.info("event=server_started bind={s} port={d} storage={s}", .{ bind, port, if (storage.is_postgres) "postgres" else "sqlite" });
    while (true) {
        if (lifecycle.shutdown_requested.load(.acquire)) break;
        const stream = listener.accept(init.io) catch |err| {
            if (lifecycle.shutdown_requested.load(.acquire)) break;
            std.log.err("accept: {t}", .{err});
            continue;
        };
        if (!app.http_gate.tryAcquire()) {
            var rejected = stream;
            rejected.close(init.io);
            continue;
        }
        connections.concurrent(init.io, connection.serveConnection, .{ &app, stream, init.io }) catch |err| {
            std.log.err("spawn connection: {t}", .{err});
            app.http_gate.release();
            var rejected = stream;
            rejected.close(init.io);
        };
    }
    if (lifecycle.restart_requested.load(.acquire)) return error.ServerRestartRequested;
}
