const d = @import("../deps.zig");
const std = d.std;
const storage = d.storage;
const sqlite_storage = d.sqlite_storage;
const pp = d.pp;
const config_mod = d.config_mod;
const r2 = d.r2;
const object_keys = d.object_keys;
const profile_avatar = d.profile_avatar;
const beatmap_sync = d.beatmap_sync;
const backup_transfer = @import("backup_transfer.zig");

pub fn configuredObjectStore(config: config_mod.Config) r2.Storage {
    return .{
        .endpoint = config.object_storage_endpoint,
        .bucket = config.object_storage_bucket,
        .access_key_id = config.object_storage_access_key_id,
        .secret_access_key = config.object_storage_secret_access_key,
        .region = config.object_storage_region,
    };
}

pub fn configuredLegacyAvatarStore(config: config_mod.Config) r2.Storage {
    return .{
        .endpoint = config.avatar_r2_endpoint,
        .bucket = config.avatar_r2_bucket,
        .access_key_id = config.avatar_r2_access_key_id,
        .secret_access_key = config.avatar_r2_secret_access_key,
    };
}

pub fn objectTransferCommand(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !bool {
    if (args.len == 0 or (!std.mem.eql(u8, args[0], "object-put") and !std.mem.eql(u8, args[0], "object-get"))) return false;
    if (args.len != 3) return error.InvalidObjectTransferArguments;
    var config = try config_mod.load(allocator, io);
    defer config.deinit();
    const target = configuredObjectStore(config);
    if (!target.enabled()) return error.ObjectStorageNotConfigured;
    const max_backup_bytes: usize = 2 * 1024 * 1024 * 1024;
    if (std.mem.eql(u8, args[0], "object-put")) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[2], allocator, .limited(max_backup_bytes));
        defer allocator.free(bytes);
        try backup_transfer.putVerified(allocator, io, target, args[1], bytes);
        std.log.info("event=object_backup_uploaded key={s} bytes={d} verified=true", .{ args[1], bytes.len });
    } else {
        const bytes = try backup_transfer.get(allocator, io, target, args[1], max_backup_bytes);
        defer allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = bytes, .flags = .{ .exclusive = true } });
        std.log.info("event=object_backup_downloaded key={s} bytes={d}", .{ args[1], bytes.len });
    }
    return true;
}

pub const AvatarObjectMigrationStats = struct { migrated: i64 = 0, failed: i64 = 0 };

pub fn migrateAvatarObjects(allocator: std.mem.Allocator, store: *storage.Store, source: r2.Storage, target: r2.Storage) !AvatarObjectMigrationStats {
    const user_ids = try store.customAvatarUserIds(allocator);
    defer allocator.free(user_ids);
    var stats: AvatarObjectMigrationStats = .{};
    for (user_ids) |user_id| {
        var avatar = (try store.customAvatarForUser(allocator, user_id)) orelse continue;
        defer avatar.deinit();
        var target_valid = false;
        if (target.getWithLimit(allocator, store.io, avatar.object_key, avatar.content_type, profile_avatar.max_bytes)) |data| {
            defer allocator.free(data);
            if (profile_avatar.validate(avatar.content_type, data)) |_| {
                target_valid = object_keys.matchesSha256(data, &avatar.etag);
            } else |_| {}
        } else |_| {}
        if (target_valid) {
            stats.migrated += 1;
            continue;
        }
        if (!source.enabled()) {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error=source_not_configured", .{user_id});
            continue;
        }
        const data = source.getWithLimit(allocator, store.io, avatar.object_key, avatar.content_type, profile_avatar.max_bytes) catch |err| {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error={t}", .{ user_id, err });
            continue;
        };
        defer allocator.free(data);
        _ = profile_avatar.validate(avatar.content_type, data) catch |err| {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error={t}", .{ user_id, err });
            continue;
        };
        if (!object_keys.matchesSha256(data, &avatar.etag)) {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error=etag_mismatch", .{user_id});
            continue;
        }
        target.put(allocator, store.io, avatar.object_key, avatar.content_type, data) catch |err| {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error={t}", .{ user_id, err });
            continue;
        };
        const verified = target.getWithLimit(allocator, store.io, avatar.object_key, avatar.content_type, profile_avatar.max_bytes) catch |err| {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error={t}", .{ user_id, err });
            continue;
        };
        defer allocator.free(verified);
        if (!object_keys.matchesSha256(verified, &avatar.etag)) {
            stats.failed += 1;
            std.log.warn("event=avatar_object_migration_failed user_id={d} error=verification_failed", .{user_id});
            continue;
        }
        stats.migrated += 1;
    }
    return stats;
}

pub fn mirrorWorkerCommand(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "mirror-worker")) return false;
    if (args.len != 1) return error.InvalidMirrorWorkerArguments;
    const database: [:0]const u8 = if (storage.is_postgres)
        std.mem.span(std.c.getenv("ZIGCHO_POSTGRES_URL") orelse return error.MissingPostgresUrl)
    else
        "zigcho.db";
    var store = try storage.Store.open(allocator, io, database);
    defer store.close();
    try store.migrate();
    var config = try config_mod.load(allocator, io);
    defer config.deinit();
    const object_store = configuredObjectStore(config);
    if (!object_store.enabled()) return error.ObjectStorageNotConfigured;
    store.bindObjectStorage(object_store);
    var sync = beatmap_sync.Sync.init(allocator, io, config.beatmap_cache_max_bytes);
    defer sync.deinit();
    sync.bindOsuApiKey(config.osu_api_key);
    std.log.info("event=beatmap_mirror_worker_started mode=continuous", .{});
    while (true) {
        const unknown_sizes = store.beatmapArchiveIdsMissingSize(allocator, 1) catch |err| {
            std.log.warn("event=beatmap_mirror_worker_inventory_list_failed error={t}", .{err});
            std.Io.sleep(io, .fromSeconds(30), .awake) catch return true;
            continue;
        };
        if (unknown_sizes.len != 0) {
            const set_id = unknown_sizes[0];
            allocator.free(unknown_sizes);
            const archive = store.beatmapArchive(allocator, set_id) catch |err| {
                std.log.warn("event=beatmap_mirror_worker_inventory_read_failed set_id={d} error={t}", .{ set_id, err });
                std.Io.sleep(io, .fromSeconds(30), .awake) catch return true;
                continue;
            } orelse {
                std.Io.sleep(io, .fromSeconds(30), .awake) catch return true;
                continue;
            };
            store.setBeatmapArchiveSize(set_id, archive.len) catch |err|
                std.log.warn("event=beatmap_mirror_worker_inventory_write_failed set_id={d} error={t}", .{ set_id, err });
            allocator.free(archive);
            std.log.info("event=beatmap_mirror_worker_inventoried set_id={d}", .{set_id});
            std.Io.sleep(io, .fromSeconds(1), .awake) catch return true;
            continue;
        }
        allocator.free(unknown_sizes);
        const ids = store.beatmapSetIdsMissingArchives(allocator, 1) catch |err| {
            std.log.warn("event=beatmap_mirror_worker_list_failed error={t}", .{err});
            std.Io.sleep(io, .fromSeconds(30), .awake) catch return true;
            continue;
        };
        if (ids.len == 0) {
            allocator.free(ids);
            std.log.info("event=beatmap_mirror_worker_idle", .{});
            std.Io.sleep(io, .fromSeconds(900), .awake) catch return true;
            continue;
        }
        const set_id = ids[0];
        allocator.free(ids);
        const mirrored = sync.prefetchMirrorArchive(&store, set_id) catch |err| {
            std.log.warn("event=beatmap_mirror_worker_failed set_id={d} error={t}", .{ set_id, err });
            std.Io.sleep(io, .fromSeconds(30), .awake) catch return true;
            continue;
        };
        allocator.free(mirrored.data);
        std.log.info("event=beatmap_mirror_worker_stored set_id={d}", .{set_id});
        std.Io.sleep(io, .fromSeconds(1), .awake) catch return true;
    }
}
