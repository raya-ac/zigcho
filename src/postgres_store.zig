const std = @import("std");
const domain = @import("domain.zig");
const postgres = @import("postgres.zig");
const sqlite_storage = @import("storage.zig");
const stable_score = @import("stable_score.zig");
const beatmap = @import("beatmap.zig");
const lazer = @import("lazer.zig");
const performance_calculator = @import("exact_pp.zig");
const stable_mods = @import("stable_mods.zig");
const screenshot_contract = @import("screenshot.zig");
const media_contract = @import("media_contract.zig");
const site_replay = @import("site_replay.zig");
const user_json = @import("user_json.zig");
const achievements = @import("achievements.zig");
const bss = @import("bss.zig");
const r2 = @import("r2.zig");
const object_keys = @import("object_keys.zig");
const upstream_user = @import("upstream_user.zig");
const database_sql = @import("database_sql");

pub const ClientHardware = sqlite_storage.ClientHardware;
pub const HardwareEnforcement = sqlite_storage.HardwareEnforcement;
pub const AnticheatSource = sqlite_storage.AnticheatSource;
pub const AnticheatReviewLabel = sqlite_storage.AnticheatReviewLabel;
pub const AnticheatObservation = sqlite_storage.AnticheatObservation;
pub const is_postgres = true;
pub const LazerCommentable = sqlite_storage.LazerCommentable;
pub const LazerCommentTarget = sqlite_storage.LazerCommentTarget;
pub const LazerCommentSort = sqlite_storage.LazerCommentSort;
pub const ReplaySource = sqlite_storage.ReplaySource;
pub const UpstreamUserCache = sqlite_storage.UpstreamUserCache;
pub const BeatmapSetCreator = sqlite_storage.BeatmapSetCreator;
const archive_object_limit: usize = 128 * 1024 * 1024;
const max_replay_object_bytes: usize = 32 * 1024 * 1024;

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: postgres.Pool,
    object_store: r2.Storage = .{ .endpoint = "", .bucket = "", .access_key_id = "", .secret_access_key = "" },
    external_only: bool = false,

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

    pub const RegistrationConflicts = struct { username: bool, email: bool };
    pub const ServerCounts = struct { users: i64, plays: i64, passed: i64, maps: i64 };
    pub const BeatmapCacheStats = struct { entries: i64, bytes: i64, hydration_failures: i64 };
    pub const BeatmapCachePrune = struct { entries: i64, bytes: i64 };
    pub const BeatmapMediaCacheStats = struct { entries: i64, bytes: i64 };
    pub const BeatmapArchiveDownload = sqlite_storage.Store.BeatmapArchiveDownload;
    pub const ObjectMigrationStats = sqlite_storage.Store.ObjectMigrationStats;
    pub const ObjectPurgeStats = sqlite_storage.Store.ObjectPurgeStats;
    pub const BeatmapForScore = sqlite_storage.Store.BeatmapForScore;
    pub const BeatmapInfo = sqlite_storage.Store.BeatmapInfo;
    pub const StableBeatmapInfo = sqlite_storage.Store.StableBeatmapInfo;
    pub const DirectMessage = sqlite_storage.Store.DirectMessage;
    pub const BeatmapSelection = sqlite_storage.Store.BeatmapSelection;
    pub const MatchmakingBeatmap = sqlite_storage.Store.MatchmakingBeatmap;
    pub const MultiplayerRoomArchive = sqlite_storage.Store.MultiplayerRoomArchive;
    pub const BeatmapRating = sqlite_storage.Store.BeatmapRating;
    pub const PpSnapshot = sqlite_storage.Store.PpSnapshot;
    pub const CustomAvatar = sqlite_storage.Store.CustomAvatar;
    pub const LazerChatWrite = sqlite_storage.Store.LazerChatWrite;
    pub const ChatCursor = sqlite_storage.Store.ChatCursor;
    pub const directStatus = sqlite_storage.Store.directStatus;
    pub const stableStatus = sqlite_storage.Store.stableStatus;
    pub const lazerStatus = sqlite_storage.Store.lazerStatus;

    fn param(buffers: anytype, cursor: *usize, value: anytype) ![]u8 {
        if (cursor.* == buffers.len) return error.ParameterBufferExhausted;
        const index = cursor.*;
        cursor.* += 1;
        return std.fmt.bufPrint(&buffers[index], "{d}", .{value});
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, conninfo: []const u8) !Store {
        return .{ .allocator = allocator, .io = io, .pool = try postgres.Pool.init(allocator, io, conninfo, postgres.Pool.default_size) };
    }

    pub fn bindObjectStorage(self: *Store, object_store: r2.Storage) void {
        self.object_store = object_store;
    }

    pub fn close(self: *Store) void {
        self.pool.deinit();
    }

    fn refreshExternalOnly(self: *Store, conn: *postgres.c.PGconn) !void {
        var result = try postgres.query(conn, "SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND is_nullable='YES' AND ((table_name='beatmap_archives' AND column_name='osz_file') OR (table_name='beatmap_media' AND column_name='data'))");
        defer result.deinit();
        self.external_only = try result.int(i32, 0, 0) == 2;
    }

    pub fn migrate(self: *Store) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        var exists = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.schema_migrations') IS NOT NULL)::int");
        const bootstrapped = try exists.int(i32, 0, 0) == 0;
        exists.deinit();
        if (bootstrapped) {
            try postgres.exec(lease.conn, "BEGIN;" ++ database_sql.postgres_schema ++ "COMMIT;");
            try self.refreshExternalOnly(lease.conn);
            return;
        }
        var result = try postgres.query(lease.conn, "SELECT max(version) FROM zigcho.schema_migrations");
        if (result.rows() == 0 or result.isNull(0, 0)) {
            result.deinit();
            return error.UnsupportedSchemaVersion;
        }
        const version = try result.int(i32, 0, 0);
        result.deinit();
        if (version == 12) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "CREATE TABLE zigcho.chat_messages(id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,sender_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,target text NOT NULL,message text NOT NULL,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "CREATE INDEX chat_messages_target_time ON zigcho.chat_messages(target,created_at DESC);" ++
                    "CREATE INDEX chat_messages_sender_time ON zigcho.chat_messages(sender_id,created_at DESC);" ++
                    "CREATE TABLE zigcho.chat_channels(name text PRIMARY KEY,topic text NOT NULL,write_privileges bigint NOT NULL DEFAULT 1,locked boolean NOT NULL DEFAULT false,updated_by integer,updated_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "INSERT INTO zigcho.chat_channels(name,topic,write_privileges) VALUES('#osu','general chat',1),('#announce','updates',8192),('#lobby','multiplayer lobby',1),('#lazer','lazer chat',1);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(13);" ++
                    "COMMIT",
            );
        } else if (version != 13 and version != 14 and version != 15 and version != 16 and version != 17 and version != 18 and version != 19 and version != 20 and version != 21 and version != 22 and version != 23 and version != 24 and version != 25 and version != 26 and version != 27 and version != 28 and version != 29 and version != 30 and version != 31 and version != 32 and version != 33 and version != 34 and version != 35 and version != 36) return error.UnsupportedSchemaVersion;
        if (version <= 13) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.beatmaps ADD COLUMN status_frozen boolean NOT NULL DEFAULT false;" ++
                    "CREATE TABLE zigcho.beatmap_rank_requests(id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,set_id integer NOT NULL,map_id integer NOT NULL REFERENCES zigcho.beatmaps(id) ON DELETE CASCADE,requester_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,active boolean NOT NULL DEFAULT true,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),resolved_at bigint);" ++
                    "CREATE UNIQUE INDEX beatmap_rank_requests_active_user ON zigcho.beatmap_rank_requests(set_id,requester_id) WHERE active;" ++
                    "CREATE INDEX beatmap_rank_requests_queue ON zigcho.beatmap_rank_requests(active,created_at,set_id);" ++
                    "CREATE TABLE zigcho.beatmap_nominations(set_id integer NOT NULL,nominator_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,active boolean NOT NULL DEFAULT true,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),updated_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),PRIMARY KEY(set_id,nominator_id));" ++
                    "CREATE INDEX beatmap_nominations_active ON zigcho.beatmap_nominations(set_id,active);" ++
                    "CREATE TABLE zigcho.beatmap_rank_events(id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,set_id integer NOT NULL,actor_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE RESTRICT,action text NOT NULL,from_status smallint NOT NULL,to_status smallint NOT NULL,reason text NOT NULL,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "CREATE INDEX beatmap_rank_events_set_time ON zigcho.beatmap_rank_events(set_id,created_at DESC,id DESC);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(14);" ++
                    "COMMIT",
            );
        }
        if (version <= 14) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "CREATE TABLE zigcho.moderation_appeals(id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,kind text NOT NULL CHECK(kind IN ('restriction','hwid')),message text NOT NULL,status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','accepted','denied')),reviewer_id integer REFERENCES zigcho.users(id) ON DELETE SET NULL,resolution text,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),resolved_at bigint);" ++
                    "CREATE UNIQUE INDEX moderation_appeals_one_open ON zigcho.moderation_appeals(user_id,kind) WHERE status='open';" ++
                    "CREATE INDEX moderation_appeals_queue ON zigcho.moderation_appeals(status,created_at,id);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(15);" ++
                    "COMMIT",
            );
        }
        if (version <= 15) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "CREATE TABLE zigcho.score_pins(user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,score_id bigint NOT NULL UNIQUE REFERENCES zigcho.scores(id) ON DELETE CASCADE,pinned_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),PRIMARY KEY(user_id,score_id));" ++
                    "CREATE INDEX score_pins_user_time ON zigcho.score_pins(user_id,pinned_at DESC,score_id DESC);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(16);" ++
                    "COMMIT",
            );
        }
        if (version <= 16) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.beatmap_archives ADD COLUMN last_accessed_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint);" ++
                    "UPDATE zigcho.beatmap_archives SET last_accessed_at=imported_at;" ++
                    "CREATE INDEX beatmap_archives_lru ON zigcho.beatmap_archives(last_accessed_at,imported_at,set_id);" ++
                    "CREATE TABLE zigcho.beatmap_hydration_failures(md5 char(32) PRIMARY KEY,set_id integer NOT NULL,attempts smallint NOT NULL DEFAULT 1 CHECK(attempts BETWEEN 1 AND 32),next_retry_at bigint NOT NULL,last_error text NOT NULL,updated_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "CREATE INDEX beatmap_hydration_retry ON zigcho.beatmap_hydration_failures(next_retry_at,updated_at);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(17);" ++
                    "COMMIT",
            );
        }
        if (version <= 17) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "CREATE TABLE zigcho.screenshots(token char(8) PRIMARY KEY,extension text NOT NULL CHECK(extension IN ('jpeg','png')),uploader_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,image bytea NOT NULL CHECK(octet_length(image)<=4194304),created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "CREATE INDEX screenshots_uploader_time ON zigcho.screenshots(uploader_id,created_at DESC);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(18);" ++
                    "COMMIT",
            );
        }
        if (version <= 18) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "CREATE TABLE zigcho.beatmap_media(set_id integer NOT NULL,kind text NOT NULL CHECK(kind IN ('cover','cover_2x','card','card_2x','list','list_2x','slimcover','slimcover_2x','thumb','thumb_large','preview')),content_type text NOT NULL CHECK(content_type IN ('image/jpeg','audio/ogg','audio/mpeg')),sha256 char(64) NOT NULL,data bytea NOT NULL CHECK(octet_length(data) BETWEEN 1 AND 4194304),fetched_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),last_accessed_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),PRIMARY KEY(set_id,kind));" ++
                    "CREATE INDEX beatmap_media_lru ON zigcho.beatmap_media(last_accessed_at,fetched_at,set_id,kind);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(19);" ++
                    "COMMIT",
            );
        }
        if (version <= 19) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "CREATE TABLE zigcho.beatmap_comments(id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,target_id bigint NOT NULL,target_type text NOT NULL CHECK(target_type IN ('song','map','replay')),user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,time double precision NOT NULL,comment text NOT NULL CHECK(length(comment) BETWEEN 1 AND 80),colour char(6),created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "CREATE INDEX beatmap_comments_target ON zigcho.beatmap_comments(target_type,target_id,id);" ++
                    "CREATE TABLE zigcho.direct_messages(id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,from_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,to_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,message text NOT NULL CHECK(length(message) BETWEEN 1 AND 2000),read boolean NOT NULL DEFAULT false,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "CREATE INDEX direct_messages_unread ON zigcho.direct_messages(to_id,read,created_at,id);" ++
                    "CREATE INDEX direct_messages_conversation ON zigcho.direct_messages(to_id,from_id,read,id);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(20);" ++
                    "COMMIT",
            );
        }
        if (version <= 20) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.lazer_scores ADD COLUMN rank text NOT NULL DEFAULT 'F';" ++
                    "ALTER TABLE zigcho.lazer_scores ADD COLUMN maximum_statistics_json jsonb NOT NULL DEFAULT '{}'::jsonb;" ++
                    "ALTER TABLE zigcho.lazer_scores ADD COLUMN pauses_json jsonb NOT NULL DEFAULT '[]'::jsonb;" ++
                    "CREATE TABLE zigcho.lazer_score_tokens(id bigint PRIMARY KEY,user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,beatmap_id integer NOT NULL REFERENCES zigcho.beatmaps(id) ON DELETE CASCADE,beatmap_hash char(32) NOT NULL,ruleset_id smallint NOT NULL CHECK(ruleset_id BETWEEN 0 AND 3),version_hash char(32) NOT NULL,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),expires_at bigint NOT NULL,consumed_at bigint,score_id bigint REFERENCES zigcho.lazer_scores(id) ON DELETE SET NULL);" ++
                    "CREATE INDEX lazer_score_tokens_user_expiry ON zigcho.lazer_score_tokens(user_id,expires_at DESC);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(21);" ++
                    "COMMIT",
            );
        }
        if (version <= 21) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.lazer_scores ADD COLUMN pp double precision NOT NULL DEFAULT 0;" ++
                    "ALTER TABLE zigcho.lazer_scores ADD COLUMN best boolean NOT NULL DEFAULT false;" ++
                    "WITH ranked AS (SELECT id,row_number() OVER (PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) place FROM zigcho.lazer_scores WHERE passed) UPDATE zigcho.lazer_scores scores SET best=true FROM ranked WHERE scores.id=ranked.id AND ranked.place=1;" ++
                    "CREATE INDEX lazer_scores_user_best ON zigcho.lazer_scores(user_id,ruleset_id,rank_namespace,beatmap_id,best);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(22);" ++
                    "COMMIT",
            );
        }
        if (version <= 22) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.users ADD COLUMN bio text NOT NULL DEFAULT '' CHECK(length(bio)<=500);" ++
                    "ALTER TABLE zigcho.users ADD COLUMN preferred_mode smallint NOT NULL DEFAULT 0 CHECK(preferred_mode BETWEEN 0 AND 3);" ++
                    "ALTER TABLE zigcho.users ADD COLUMN profile_source text NOT NULL DEFAULT 'all' CHECK(profile_source IN('all','lazer','scorev2'));" ++
                    "CREATE TABLE zigcho.user_avatars(user_id integer PRIMARY KEY REFERENCES zigcho.users(id) ON DELETE CASCADE,object_key text NOT NULL UNIQUE CHECK(length(object_key) BETWEEN 1 AND 200),content_type text NOT NULL CHECK(content_type IN('image/png','image/jpeg','image/gif')),etag char(64) NOT NULL,updated_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(23);" ++
                    "COMMIT",
            );
        }
        if (version <= 23) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.users ADD COLUMN profile_title text NOT NULL DEFAULT '' CHECK(length(profile_title)<=40);" ++
                    "ALTER TABLE zigcho.users ADD COLUMN profile_pronouns text NOT NULL DEFAULT '' CHECK(length(profile_pronouns)<=32);" ++
                    "ALTER TABLE zigcho.users ADD COLUMN profile_location text NOT NULL DEFAULT '' CHECK(length(profile_location)<=60);" ++
                    "ALTER TABLE zigcho.users ADD COLUMN profile_website text NOT NULL DEFAULT '' CHECK(length(profile_website)<=200);" ++
                    "ALTER TABLE zigcho.users ADD COLUMN profile_accent text NOT NULL DEFAULT 'pink' CHECK(profile_accent IN('pink','violet','blue','mint','gold','red'));" ++
                    "ALTER TABLE zigcho.users ADD COLUMN show_country boolean NOT NULL DEFAULT true;" ++
                    "ALTER TABLE zigcho.users ADD COLUMN show_profile_stats boolean NOT NULL DEFAULT true;" ++
                    "ALTER TABLE zigcho.users ADD COLUMN show_recent_scores boolean NOT NULL DEFAULT true;" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(24);" ++
                    "COMMIT",
            );
        }
        if (version <= 24) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "CREATE TABLE zigcho.anticheat_observations(id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,score_id bigint REFERENCES zigcho.scores(id) ON DELETE SET NULL,source text NOT NULL CHECK(source IN('stable_login','stable_lastfm','stable_score')),module text NOT NULL CHECK(length(module) BETWEEN 1 AND 64),action smallint NOT NULL CHECK(action BETWEEN 0 AND 3),sample_weight integer NOT NULL DEFAULT 1 CHECK(sample_weight BETWEEN 1 AND 100000),reason integer NOT NULL,risk_score smallint NOT NULL CHECK(risk_score BETWEEN 0 AND 1000),confidence_bps integer NOT NULL CHECK(confidence_bps BETWEEN 0 AND 10000),evidence bigint NOT NULL DEFAULT 0 CHECK(evidence>=0),decision_flags bigint NOT NULL DEFAULT 0 CHECK(decision_flags>=0),rule_revision integer NOT NULL DEFAULT 0,objects_checked integer NOT NULL DEFAULT 0 CHECK(objects_checked>=0),matched_clicks integer NOT NULL DEFAULT 0 CHECK(matched_clicks BETWEEN 0 AND objects_checked),mean_abs_timing_error_milli integer NOT NULL DEFAULT 0 CHECK(mean_abs_timing_error_milli>=0),timing_stddev_milli integer NOT NULL DEFAULT 0 CHECK(timing_stddev_milli>=0),exact_timing_bps integer NOT NULL DEFAULT 0 CHECK(exact_timing_bps BETWEEN 0 AND 10000),center_hits_bps integer NOT NULL DEFAULT 0 CHECK(center_hits_bps BETWEEN 0 AND 10000),mean_center_distance_milli integer NOT NULL DEFAULT 0 CHECK(mean_center_distance_milli>=0),snap_events integer NOT NULL DEFAULT 0 CHECK(snap_events BETWEEN 0 AND objects_checked),review_label text NOT NULL DEFAULT 'pending' CHECK(review_label IN('pending','clean','uncertain','cheat','dismissed')),reviewer_id integer REFERENCES zigcho.users(id) ON DELETE SET NULL,review_note text NOT NULL DEFAULT '' CHECK(length(review_note)<=1000),reviewed_at bigint,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),CHECK((review_label='pending' AND reviewer_id IS NULL AND reviewed_at IS NULL AND review_note='') OR (review_label!='pending' AND reviewer_id IS NOT NULL AND reviewed_at IS NOT NULL AND length(review_note) BETWEEN 3 AND 1000)));" ++
                    "CREATE UNIQUE INDEX anticheat_observations_score ON zigcho.anticheat_observations(score_id) WHERE score_id IS NOT NULL;" ++
                    "CREATE INDEX anticheat_observations_queue ON zigcho.anticheat_observations(review_label,created_at,id);" ++
                    "CREATE INDEX anticheat_observations_user ON zigcho.anticheat_observations(user_id,created_at DESC,id DESC);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(25);" ++
                    "COMMIT",
            );
        }
        if (version <= 25) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.anticheat_observations ADD COLUMN replay_match_count integer NOT NULL DEFAULT 0 CHECK(replay_match_count BETWEEN 0 AND 100000),ADD COLUMN key_press_count integer NOT NULL DEFAULT 0 CHECK(key_press_count>=0),ADD COLUMN key_hold_count integer NOT NULL DEFAULT 0 CHECK(key_hold_count BETWEEN 0 AND key_press_count),ADD COLUMN mean_hold_duration_milli integer NOT NULL DEFAULT 0 CHECK(mean_hold_duration_milli>=0),ADD COLUMN hold_duration_stddev_milli integer NOT NULL DEFAULT 0 CHECK(hold_duration_stddev_milli>=0),ADD COLUMN alternation_bps integer NOT NULL DEFAULT 0 CHECK(alternation_bps BETWEEN 0 AND 10000),ADD COLUMN target_distance_stddev_milli integer NOT NULL DEFAULT 0 CHECK(target_distance_stddev_milli>=0),ADD COLUMN velocity_spike_count integer NOT NULL DEFAULT 0 CHECK(velocity_spike_count>=0),ADD COLUMN movement_velocity_stddev_milli integer NOT NULL DEFAULT 0 CHECK(movement_velocity_stddev_milli>=0);" ++
                    "CREATE TABLE zigcho.anticheat_replay_fingerprints(score_id bigint PRIMARY KEY REFERENCES zigcho.scores(id) ON DELETE CASCADE,user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,replay_sha256 bytea NOT NULL CHECK(octet_length(replay_sha256)=32),created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint));" ++
                    "CREATE INDEX anticheat_replay_fingerprints_hash ON zigcho.anticheat_replay_fingerprints(replay_sha256,user_id);" ++
                    "CREATE INDEX anticheat_replay_fingerprints_user ON zigcho.anticheat_replay_fingerprints(user_id,created_at DESC,score_id DESC);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(26);" ++
                    "COMMIT",
            );
        }
        if (version <= 26) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.chat_messages ADD COLUMN is_action boolean NOT NULL DEFAULT false;" ++
                    "ALTER TABLE zigcho.chat_messages ADD COLUMN client_uuid text NOT NULL DEFAULT '' CHECK(length(client_uuid) IN(0,36));" ++
                    "CREATE UNIQUE INDEX chat_messages_sender_uuid ON zigcho.chat_messages(sender_id,client_uuid) WHERE client_uuid!='';" ++
                    "CREATE TABLE zigcho.lazer_channel_reads(user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,channel_id smallint NOT NULL CHECK(channel_id BETWEEN 1 AND 4),last_read_id bigint NOT NULL DEFAULT 0,updated_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),PRIMARY KEY(user_id,channel_id));" ++
                    "CREATE TABLE zigcho.user_blocks(user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,blocked_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),PRIMARY KEY(user_id,blocked_id),CHECK(user_id!=blocked_id));" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(27);" ++
                    "COMMIT",
            );
        }
        if (version <= 27) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.direct_messages ADD COLUMN is_action boolean NOT NULL DEFAULT false,ADD COLUMN client_uuid text NOT NULL DEFAULT '';" ++
                    "CREATE UNIQUE INDEX direct_messages_sender_uuid ON zigcho.direct_messages(from_id,client_uuid) WHERE client_uuid!='';" ++
                    "UPDATE zigcho.custom_mods SET ranked=true;" ++
                    "CREATE TABLE zigcho.user_achievements(user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,achievement_id smallint NOT NULL CHECK(achievement_id>0),score_source text NOT NULL CHECK(score_source IN ('stable','lazer')),score_id bigint NOT NULL CHECK(score_id>0),achieved_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),PRIMARY KEY(user_id,achievement_id));" ++
                    "CREATE INDEX user_achievements_score ON zigcho.user_achievements(score_source,score_id);" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(28);" ++
                    "COMMIT",
            );
            try self.rebuildRankedStats(lease.conn);
        }
        if (version <= 28) {
            try postgres.exec(
                lease.conn,
                "BEGIN;" ++
                    "ALTER TABLE zigcho.scores ADD COLUMN star_rating double precision NOT NULL DEFAULT 0;" ++
                    "ALTER TABLE zigcho.lazer_scores ADD COLUMN star_rating double precision NOT NULL DEFAULT 0;" ++
                    "UPDATE zigcho.scores s SET star_rating=coalesce(b.star_rating,0) FROM zigcho.beatmaps b WHERE b.md5=s.map_md5;" ++
                    "UPDATE zigcho.lazer_scores s SET star_rating=coalesce(b.star_rating,0) FROM zigcho.beatmaps b WHERE b.id=s.beatmap_id;" ++
                    "INSERT INTO zigcho.schema_migrations(version) VALUES(29);" ++
                    "COMMIT",
            );
        }
        if (version <= 30) try postgres.exec(lease.conn, database_sql.postgresMigration(31));
        if (version <= 31) try postgres.exec(lease.conn, database_sql.postgresMigration(32));
        if (version <= 32) try postgres.exec(lease.conn, database_sql.postgresMigration(33));
        if (version <= 33) try postgres.exec(lease.conn, database_sql.postgresMigration(34));
        if (version <= 34) try postgres.exec(lease.conn, database_sql.postgresMigration(35));
        if (version <= 35) try postgres.exec(lease.conn, database_sql.postgresMigration(36));
        try self.refreshExternalOnly(lease.conn);
        try postgres.exec(
            lease.conn,
            "BEGIN;" ++
                "UPDATE zigcho.lazer_scores SET best=false;" ++
                "WITH ordered AS (SELECT id,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) place FROM zigcho.lazer_scores WHERE passed) " ++
                "UPDATE zigcho.lazer_scores scores SET best=true FROM ordered WHERE scores.id=ordered.id AND ordered.place=1;" ++
                "COMMIT",
        );
        try postgres.exec(lease.conn, "INSERT INTO zigcho.chat_channels(name,topic,write_privileges) VALUES('#osu','general chat',1),('#announce','updates',8192),('#lobby','multiplayer lobby',1),('#lazer','lazer chat',1) ON CONFLICT(name) DO NOTHING");
    }

    fn userFromResult(allocator: std.mem.Allocator, result: postgres.Result, row: usize) !domain.User {
        const name = try allocator.dupe(u8, result.value(row, 1));
        errdefer allocator.free(name);
        const safe_name = try allocator.dupe(u8, result.value(row, 2));
        errdefer allocator.free(safe_name);
        const country = result.value(row, 3);
        if (country.len != 2) return error.InvalidCountry;
        const team: ?domain.TeamSummary = if (result.isNull(row, 8)) null else try domain.TeamSummary.init(try result.int(i32, row, 8), result.value(row, 9), result.value(row, 10), try result.int(i64, row, 11));
        return .{
            .id = try result.int(i32, row, 0),
            .name = name,
            .safe_name = safe_name,
            .country = .{ country[0], country[1] },
            .privileges = try result.int(u32, row, 4),
            .silence_end = try result.int(i64, row, 5),
            .restricted = try result.boolean(row, 6),
            .banner_version = try result.int(i64, row, 7),
            .team = team,
        };
    }

    pub fn register(self: *Store, name: []const u8, email: []const u8, password_md5: []const u8) !i32 {
        const safe = try domain.safeName(self.allocator, name);
        defer self.allocator.free(safe);
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
        const hash_bytea = try postgres.encodeBytea(self.allocator, hash);
        defer self.allocator.free(hash_bytea);
        const salt_bytea = try postgres.encodeBytea(self.allocator, "argon2id");
        defer self.allocator.free(salt_bytea);
        var random_byte: [1]u8 = undefined;
        try std.Io.randomSecure(self.io, &random_byte);
        var avatar_buf: [2]u8 = undefined;
        const avatar = try std.fmt.bufPrint(&avatar_buf, "{d}", .{1 + (random_byte[0] & 1)});

        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.users(name,safe_name,email,password_hash,password_salt,avatar_key) VALUES($1,$2,$3,$4,$5,$6) RETURNING id", &.{ name, safe, email, hash_bytea, salt_bytea, avatar }) catch |err| switch (err) {
            error.UniqueViolation => return error.UserExists,
            else => return err,
        };
        defer result.deinit();
        const id = try result.int(i32, 0, 0);
        var id_buf: [24]u8 = undefined;
        const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
        var stats_result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.stats(user_id,mode) SELECT $1,mode FROM unnest(ARRAY[0,1,2,3,4,5,6,8]) AS mode", &.{id_text});
        stats_result.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return id;
    }

    fn restrictUser(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, user_id: i32) !bool {
        if (user_id == 3) return false;
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var result = try postgres.queryParams(allocator, conn, "UPDATE zigcho.users SET restricted=true WHERE id=$1 AND id!=3 AND NOT restricted RETURNING 1", &.{id});
        defer result.deinit();
        return result.rows() != 0;
    }

    fn insertAudit(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, actor_id: i32, action: []const u8, target_user_id: i32, detail: []const u8) !void {
        var actor_buf: [24]u8 = undefined;
        var target_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_user_id});
        var result = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, action, target, detail });
        result.deinit();
    }

    pub fn recordAnticheatObservation(self: *Store, user_id: i32, observation: AnticheatObservation) !i64 {
        try sqlite_storage.validateAnticheatObservation(user_id, observation);
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        var params: [29]?[]const u8 = undefined;
        params[0] = try param(&buffers, &cursor, user_id);
        params[1] = if (observation.score_id) |score_id| try param(&buffers, &cursor, score_id) else null;
        params[2] = observation.source.text();
        params[3] = observation.module;
        params[4] = try param(&buffers, &cursor, observation.action);
        params[5] = try param(&buffers, &cursor, observation.sample_weight);
        params[6] = try param(&buffers, &cursor, observation.reason);
        params[7] = try param(&buffers, &cursor, observation.risk_score);
        params[8] = try param(&buffers, &cursor, observation.confidence_bps);
        params[9] = try param(&buffers, &cursor, observation.evidence);
        params[10] = try param(&buffers, &cursor, observation.decision_flags);
        params[11] = try param(&buffers, &cursor, observation.rule_revision);
        params[12] = try param(&buffers, &cursor, observation.objects_checked);
        params[13] = try param(&buffers, &cursor, observation.matched_clicks);
        params[14] = try param(&buffers, &cursor, observation.mean_abs_timing_error_milli);
        params[15] = try param(&buffers, &cursor, observation.timing_stddev_milli);
        params[16] = try param(&buffers, &cursor, observation.exact_timing_bps);
        params[17] = try param(&buffers, &cursor, observation.center_hits_bps);
        params[18] = try param(&buffers, &cursor, observation.mean_center_distance_milli);
        params[19] = try param(&buffers, &cursor, observation.snap_events);
        params[20] = try param(&buffers, &cursor, observation.replay_match_count);
        params[21] = try param(&buffers, &cursor, observation.key_press_count);
        params[22] = try param(&buffers, &cursor, observation.key_hold_count);
        params[23] = try param(&buffers, &cursor, observation.mean_hold_duration_milli);
        params[24] = try param(&buffers, &cursor, observation.hold_duration_stddev_milli);
        params[25] = try param(&buffers, &cursor, observation.alternation_bps);
        params[26] = try param(&buffers, &cursor, observation.target_distance_stddev_milli);
        params[27] = try param(&buffers, &cursor, observation.velocity_spike_count);
        params[28] = try param(&buffers, &cursor, observation.movement_velocity_stddev_milli);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.anticheat_observations(user_id,score_id,source,module,action,sample_weight,reason,risk_score,confidence_bps,evidence,decision_flags,rule_revision,objects_checked,matched_clicks,mean_abs_timing_error_milli,timing_stddev_milli,exact_timing_bps,center_hits_bps,mean_center_distance_milli,snap_events,replay_match_count,key_press_count,key_hold_count,mean_hold_duration_milli,hold_duration_stddev_milli,alternation_bps,target_distance_stddev_milli,velocity_spike_count,movement_velocity_stddev_milli) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29) RETURNING id", &params);
        defer result.deinit();
        const observation_id = try result.int(i64, 0, 0);
        var detail_buf: [512]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "observation_id={d} module={s} source={s} score_id={d} mode=observe action={d} sample_weight={d} reason={d} risk={d} confidence_bps={d} evidence={d} replay_match_count={d} rule_revision={d}", .{
            observation_id,
            observation.module,
            observation.source.text(),
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
        try insertAudit(self.allocator, lease.conn, 3, "anticheat.observe", user_id, detail);
        try postgres.exec(lease.conn, "COMMIT");
        return observation_id;
    }

    pub fn crossAccountReplayMatches(self: *Store, user_id: i32, digest: *const [32]u8) !u32 {
        if (user_id <= 0) return error.InvalidUser;
        const encoded = try postgres.encodeBytea(self.allocator, digest);
        defer self.allocator.free(encoded);
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT least(count(DISTINCT user_id),100000) FROM zigcho.anticheat_replay_fingerprints WHERE replay_sha256=$1 AND user_id!=$2", &.{ encoded, user });
        defer result.deinit();
        return @intCast(try result.int(i64, 0, 0));
    }

    pub fn recordReplayFingerprint(self: *Store, user_id: i32, score_id: i64, digest: *const [32]u8) !void {
        if (user_id <= 0 or score_id <= 0) return error.InvalidReplayFingerprint;
        const encoded = try postgres.encodeBytea(self.allocator, digest);
        defer self.allocator.free(encoded);
        var user_buf: [24]u8 = undefined;
        var score_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.anticheat_replay_fingerprints(score_id,user_id,replay_sha256) SELECT id,user_id,$1 FROM zigcho.scores WHERE id=$2 AND user_id=$3 ON CONFLICT(score_id) DO NOTHING", &.{ encoded, score, user });
        result.deinit();
    }

    pub fn recordClientHardware(self: *Store, user_id: i32, hardware: ClientHardware) !HardwareEnforcement {
        var matched: std.ArrayList(i32) = .empty;
        errdefer matched.deinit(self.allocator);
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const wine = if (hardware.running_under_wine) "true" else "false";

        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        try postgres.exec(lease.conn, "LOCK TABLE zigcho.client_hardware IN SHARE ROW EXCLUSIVE MODE");

        if (hardware.actionable) {
            var matches = try postgres.queryParams(self.allocator, lease.conn, "SELECT DISTINCT user_id FROM zigcho.client_hardware WHERE user_id!=$1 AND user_id!=3 AND adapters_md5=$2 AND uninstall_md5=$3 AND disk_signature_md5=$4 ORDER BY user_id", &.{ id, hardware.adapters_md5, hardware.uninstall_md5, hardware.disk_signature_md5 });
            defer matches.deinit();
            for (0..matches.rows()) |row| try matched.append(self.allocator, try matches.int(i32, row, 0));
        }

        var upsert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.client_hardware(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5,client_version,running_under_wine) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5) DO UPDATE SET client_version=excluded.client_version,running_under_wine=excluded.running_under_wine,last_seen=extract(epoch FROM clock_timestamp())::bigint,occurrences=zigcho.client_hardware.occurrences+1", &.{ id, hardware.osu_path_md5, hardware.adapters_md5, hardware.uninstall_md5, hardware.disk_signature_md5, hardware.client_version, wine });
        upsert.deinit();

        if (matched.items.len != 0) {
            if (try restrictUser(self.allocator, lease.conn, user_id)) {
                var detail_buf: [128]u8 = undefined;
                const detail = try std.fmt.bufPrint(&detail_buf, "multiaccount_hwid_exact matched_user:{d}", .{matched.items[0]});
                try insertAudit(self.allocator, lease.conn, 3, "account.restrict", user_id, detail);
            }
            for (matched.items) |matched_user_id| {
                if (try restrictUser(self.allocator, lease.conn, matched_user_id)) {
                    var detail_buf: [128]u8 = undefined;
                    const detail = try std.fmt.bufPrint(&detail_buf, "multiaccount_hwid_exact matched_user:{d}", .{user_id});
                    try insertAudit(self.allocator, lease.conn, 3, "account.restrict", matched_user_id, detail);
                }
            }
        }

        const owned_matches = try matched.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_matches);
        try postgres.exec(lease.conn, "COMMIT");
        return .{ .allocator = self.allocator, .matched_user_ids = owned_matches };
    }

    pub fn restrictForClientFlag(self: *Store, user_id: i32, flags: u32) !bool {
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        const changed = try restrictUser(self.allocator, lease.conn, user_id);
        if (changed) {
            var detail_buf: [64]u8 = undefined;
            const detail = try std.fmt.bufPrint(&detail_buf, "stable_lastfm_hq flags:{d}", .{flags});
            try insertAudit(self.allocator, lease.conn, 3, "account.restrict", user_id, detail);
        }
        try postgres.exec(lease.conn, "COMMIT");
        return changed;
    }

    pub fn recordLastFmFlag(self: *Store, user_id: i32, flags: u32) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        var detail_buf: [32]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "flags:{d}", .{flags});
        try insertAudit(self.allocator, lease.conn, user_id, "stable.lastfm_flag", user_id, detail);
    }

    pub fn rateBeatmap(self: *Store, user_id: i32, map_md5: []const u8, rating: ?u8) !BeatmapRating {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT status FROM zigcho.beatmaps WHERE md5=$1", &.{map_md5});
        defer map.deinit();
        if (map.rows() == 0) return .no_exist;
        if (try map.int(i32, 0, 0) < 3) return .not_ranked;
        if (rating) |value| {
            if (value < 1 or value > 10) return error.InvalidRating;
            var rating_buf: [4]u8 = undefined;
            const rating_text = try std.fmt.bufPrint(&rating_buf, "{d}", .{value});
            var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.ratings(user_id,map_md5,rating) VALUES($1,$2,$3) ON CONFLICT(user_id,map_md5) DO NOTHING", &.{ user, map_md5, rating_text });
            insert.deinit();
        } else {
            var existing = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.ratings WHERE user_id=$1 AND map_md5=$2", &.{ user, map_md5 });
            defer existing.deinit();
            if (existing.rows() == 0) return .can_rate;
        }
        var average = try postgres.queryParams(self.allocator, lease.conn, "SELECT avg(rating) FROM zigcho.ratings WHERE map_md5=$1", &.{map_md5});
        defer average.deinit();
        if (average.rows() == 0 or average.isNull(0, 0)) return error.DatabaseQueryFailed;
        return .{ .already_voted = try average.float(f64, 0, 0) };
    }

    fn upsertBeatmapInner(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: ?[]const u8, update_existing: bool) !void {
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const map_id = try param(&buffers, &cursor, metadata.id);
        const set_id = try param(&buffers, &cursor, metadata.set_id);
        const status_text = try param(&buffers, &cursor, status);
        const total_length = try param(&buffers, &cursor, metadata.total_length);
        const combo = try param(&buffers, &cursor, max_combo);
        const mode = try param(&buffers, &cursor, metadata.mode);
        const bpm = try param(&buffers, &cursor, metadata.bpm);
        const cs = try param(&buffers, &cursor, metadata.cs);
        const ar = try param(&buffers, &cursor, metadata.ar);
        const od = try param(&buffers, &cursor, metadata.od);
        const hp = try param(&buffers, &cursor, metadata.hp);
        const star_rating = try param(&buffers, &cursor, stars);
        const circles = try param(&buffers, &cursor, metadata.count_circles);
        const sliders = try param(&buffers, &cursor, metadata.count_sliders);
        const spinners = try param(&buffers, &cursor, metadata.count_spinners);
        var encoded_file: ?[]u8 = null;
        if (osu_file) |bytes| encoded_file = try postgres.encodeBytea(self.allocator, bytes);
        defer if (encoded_file) |bytes| self.allocator.free(bytes);
        const file_param: ?[]const u8 = if (encoded_file) |bytes| bytes else null;
        const sql = if (update_existing)
            "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES($1,$2,$3,$4,$5,$6,$7,$8,extract(epoch FROM clock_timestamp())::bigint,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,status=CASE WHEN zigcho.beatmaps.status_frozen THEN zigcho.beatmaps.status ELSE excluded.status END,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners"
        else
            "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES($1,$2,$3,$4,$5,$6,$7,$8,extract(epoch FROM clock_timestamp())::bigint,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) ON CONFLICT(id) DO NOTHING";
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ map_id, set_id, md5, metadata.artist, metadata.title, metadata.version, metadata.creator, status_text, total_length, combo, mode, bpm, cs, ar, od, hp, star_rating, metadata.source, metadata.tags, file_param, circles, sliders, spinners });
        result.deinit();
    }

    pub fn upsertBeatmap(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32, osu_file: []const u8) !void {
        return self.upsertBeatmapInner(metadata, md5, status, stars, max_combo, osu_file, true);
    }

    pub fn upsertBeatmapMeta(self: *Store, metadata: beatmap.Metadata, md5: []const u8, status: i8, stars: f64, max_combo: u32) !void {
        return self.upsertBeatmapInner(metadata, md5, status, stars, max_combo, null, false);
    }

    pub fn beatmapFile(self: *Store, allocator: std.mem.Allocator, md5: []const u8) !?[]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT osu_file FROM zigcho.beatmaps WHERE md5=$1 AND osu_file IS NOT NULL", &.{md5});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try postgres.decodeBytea(allocator, result.value(0, 0));
    }

    pub fn beatmapHasFile(self: *Store, md5: []const u8) !bool {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE md5=$1 AND osu_file IS NOT NULL", &.{md5});
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn beatmapFileById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT osu_file FROM zigcho.beatmaps WHERE id=$1 AND osu_file IS NOT NULL", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try postgres.decodeBytea(allocator, result.value(0, 0));
    }

    pub fn beatmapSelectionById(self: *Store, map_id: i32) !?BeatmapSelection {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT md5,set_id,status,mode FROM zigcho.beatmaps WHERE id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const md5 = result.value(0, 0);
        if (md5.len != 32) return error.InvalidBeatmap;
        var selection: BeatmapSelection = .{
            .md5 = undefined,
            .set_id = try result.int(i32, 0, 1),
            .status = try result.int(i8, 0, 2),
            .mode = try result.int(u8, 0, 3),
        };
        @memcpy(&selection.md5, md5);
        return selection;
    }

    fn multiplayerRoomArchiveFromResult(allocator: std.mem.Allocator, result: postgres.Result, row: usize) !MultiplayerRoomArchive {
        const category = try allocator.dupe(u8, result.value(row, 2));
        errdefer allocator.free(category);
        const room_json = try allocator.dupe(u8, result.value(row, 3));
        errdefer allocator.free(room_json);
        const leaderboard_json = try allocator.dupe(u8, result.value(row, 4));
        errdefer allocator.free(leaderboard_json);
        const participant_ids_json = try allocator.dupe(u8, result.value(row, 5));
        return .{
            .allocator = allocator,
            .room_id = try result.int(i64, row, 0),
            .owner_id = try result.int(i32, row, 1),
            .category = category,
            .room_json = room_json,
            .leaderboard_json = leaderboard_json,
            .participant_ids_json = participant_ids_json,
            .ended_at = try result.int(i64, row, 6),
        };
    }

    pub fn nextLazerMultiplayerRoomId(self: *Store) !i64 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT coalesce(max(room_id),0)+1 FROM zigcho.lazer_multiplayer_room_history");
        defer result.deinit();
        if (result.rows() != 1) return error.DatabaseQueryFailed;
        return result.int(i64, 0, 0);
    }

    pub fn saveLazerMultiplayerRoomArchive(self: *Store, room_id: i64, owner_id: i32, category: []const u8, room_json: []const u8, leaderboard_json: []const u8, participant_ids_json: []const u8) !void {
        if (room_id <= 0 or owner_id <= 0 or room_json.len == 0 or room_json.len > 512 * 1024 or leaderboard_json.len == 0 or leaderboard_json.len > 512 * 1024 or participant_ids_json.len == 0 or participant_ids_json.len > 4096) return error.InvalidMultiplayerArchive;
        if (!std.mem.eql(u8, category, "normal") and !std.mem.eql(u8, category, "realtime") and !std.mem.eql(u8, category, "spotlight") and !std.mem.eql(u8, category, "featured_artist")) return error.InvalidMultiplayerArchive;
        var room_buf: [24]u8 = undefined;
        var owner_buf: [16]u8 = undefined;
        const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
        const owner_id_text = try std.fmt.bufPrint(&owner_buf, "{d}", .{owner_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_multiplayer_room_history(room_id,owner_id,category,room_json,leaderboard_json,participant_ids_json,ended_at) VALUES($1,$2,$3,$4::jsonb,$5::jsonb,$6::jsonb,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(room_id) DO UPDATE SET owner_id=excluded.owner_id,category=excluded.category,room_json=excluded.room_json,leaderboard_json=excluded.leaderboard_json,participant_ids_json=excluded.participant_ids_json,ended_at=excluded.ended_at", &.{ room_id_text, owner_id_text, category, room_json, leaderboard_json, participant_ids_json });
        result.deinit();
    }

    pub fn lazerMultiplayerRoomArchive(self: *Store, allocator: std.mem.Allocator, room_id: i64) !?MultiplayerRoomArchive {
        if (room_id <= 0) return null;
        var room_buf: [24]u8 = undefined;
        const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT room_id,owner_id,category,room_json::text,leaderboard_json::text,participant_ids_json::text,ended_at FROM zigcho.lazer_multiplayer_room_history WHERE room_id=$1", &.{room_id_text});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try multiplayerRoomArchiveFromResult(allocator, result, 0);
    }

    pub fn lazerMultiplayerRoomArchives(self: *Store, allocator: std.mem.Allocator, limit: u8) ![]MultiplayerRoomArchive {
        if (limit == 0) return allocator.alloc(MultiplayerRoomArchive, 0);
        var limit_buf: [4]u8 = undefined;
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT room_id,owner_id,category,room_json::text,leaderboard_json::text,participant_ids_json::text,ended_at FROM zigcho.lazer_multiplayer_room_history ORDER BY ended_at DESC,room_id DESC LIMIT $1", &.{limit_text});
        defer result.deinit();
        const archives = try allocator.alloc(MultiplayerRoomArchive, result.rows());
        var initialized: usize = 0;
        errdefer {
            for (archives[0..initialized]) |*archive| archive.deinit();
            allocator.free(archives);
        }
        for (archives, 0..) |*archive, row| {
            archive.* = try multiplayerRoomArchiveFromResult(allocator, result, row);
            initialized += 1;
        }
        return archives;
    }

    pub fn matchmakingBeatmaps(self: *Store, allocator: std.mem.Allocator, mode: u8, limit: u8) ![]MatchmakingBeatmap {
        if (mode > 3 or limit == 0 or limit > 32) return error.InvalidMatchmakingPool;
        var mode_buf: [4]u8 = undefined;
        var limit_buf: [4]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,md5,mode,star_rating FROM zigcho.beatmaps WHERE status IN(3,4) AND mode=$1 AND osu_file IS NOT NULL ORDER BY star_rating,id LIMIT $2", &.{ mode_text, limit_text });
        defer result.deinit();
        const maps = try allocator.alloc(MatchmakingBeatmap, result.rows());
        errdefer allocator.free(maps);
        for (maps, 0..) |*map, row| {
            const md5 = result.value(row, 1);
            if (md5.len != 32) return error.InvalidBeatmap;
            map.* = .{
                .id = try result.int(i32, row, 0),
                .md5 = undefined,
                .mode = try result.int(u8, row, 2),
                .stars = try result.float(f64, row, 3),
            };
            @memcpy(&map.md5, md5);
        }
        return maps;
    }

    pub fn setScorePinned(self: *Store, user_id: i32, map_md5: []const u8, mode: u8, mods_value: i32, namespace: []const u8, pinned: bool) !i64 {
        var user_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        var mods_buf: [16]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const mods = try std.fmt.bufPrint(&mods_buf, "{d}", .{mods_value});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var locked_user = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE id=$1 FOR UPDATE", &.{user});
        defer locked_user.deinit();
        if (locked_user.rows() == 0) return error.UserNotFound;
        var score = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND mode=$3 AND rank_namespace=$4 AND mods=$5 AND passed ORDER BY best DESC,pp DESC,score DESC,id DESC LIMIT 1", &.{ user, map_md5, mode_text, namespace, mods });
        defer score.deinit();
        if (score.rows() == 0) return error.NoPassedScore;
        const score_id = try score.int(i64, 0, 0);
        var score_buf: [24]u8 = undefined;
        const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        if (pinned) {
            var old = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.score_pins p USING zigcho.scores s WHERE p.user_id=$1 AND p.score_id=s.id AND s.user_id=$1 AND s.map_md5=$2 AND s.mode=$3 AND s.rank_namespace=$4 AND s.mods=$5 AND p.score_id<>$6", &.{ user, map_md5, mode_text, namespace, mods, score_text });
            old.deinit();
            var old_profile = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.profile_score_pins p USING zigcho.scores s WHERE p.user_id=$1 AND p.source='stable' AND p.score_id=s.id AND s.user_id=$1 AND s.map_md5=$2 AND s.mode=$3 AND s.rank_namespace=$4 AND s.mods=$5 AND p.score_id<>$6", &.{ user, map_md5, mode_text, namespace, mods, score_text });
            old_profile.deinit();
            var pins = try postgres.queryParams(self.allocator, lease.conn, "SELECT score_id FROM zigcho.profile_score_pins WHERE user_id=$1 AND mode=$2 AND rank_namespace=$3 FOR UPDATE", &.{ user, mode_text, namespace });
            defer pins.deinit();
            var already_pinned = false;
            for (0..pins.rows()) |row| if (try pins.int(i64, row, 0) == score_id) {
                already_pinned = true;
                break;
            };
            if (!already_pinned and pins.rows() >= 3) return error.TooManyPinnedScores;
            var update = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.score_pins(user_id,score_id) VALUES($1,$2) ON CONFLICT(user_id,score_id) DO UPDATE SET pinned_at=extract(epoch FROM clock_timestamp())::bigint", &.{ user, score_text });
            update.deinit();
        } else {
            var update = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.score_pins p USING zigcho.scores s WHERE p.user_id=$1 AND p.score_id=s.id AND s.user_id=$1 AND s.map_md5=$2 AND s.mode=$3 AND s.rank_namespace=$4 AND s.mods=$5", &.{ user, map_md5, mode_text, namespace, mods });
            update.deinit();
        }
        if (pinned) {
            var profile = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.profile_score_pins(user_id,source,score_id,mode,rank_namespace) VALUES($1,'stable',$2,$3,$4) ON CONFLICT(user_id,source,score_id) DO UPDATE SET pinned_at=extract(epoch FROM clock_timestamp())::bigint", &.{ user, score_text, mode_text, namespace });
            profile.deinit();
        } else {
            var profile = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.profile_score_pins p USING zigcho.scores s WHERE p.user_id=$1 AND p.source='stable' AND p.score_id=s.id AND s.user_id=$1 AND s.map_md5=$2 AND s.mode=$3 AND s.rank_namespace=$4 AND s.mods=$5", &.{ user, map_md5, mode_text, namespace, mods });
            profile.deinit();
        }
        try postgres.exec(lease.conn, "COMMIT");
        return score_id;
    }

    pub fn setScorePinnedById(self: *Store, user_id: i32, source: ReplaySource, score_id: i64, pinned: bool) !void {
        var buffers: [2][32]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const score_id_text = try param(&buffers, &cursor, score_id);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var score = try postgres.queryParams(self.allocator, lease.conn, switch (source) {
            .stable => "SELECT mode,rank_namespace FROM zigcho.scores WHERE id=$1 AND user_id=$2 AND passed FOR UPDATE",
            .lazer => "SELECT ruleset_id,rank_namespace FROM zigcho.lazer_scores WHERE id=$1 AND user_id=$2 AND passed FOR UPDATE",
        }, &.{ score_id_text, user });
        defer score.deinit();
        if (score.rows() != 1) return error.NoPassedScore;
        if (pinned) {
            var pins = try postgres.queryParams(self.allocator, lease.conn, "SELECT score_id FROM zigcho.profile_score_pins WHERE user_id=$1 AND mode=$2 AND rank_namespace=$3 AND NOT(source=$4 AND score_id=$5) FOR UPDATE", &.{ user, score.value(0, 0), score.value(0, 1), source.text(), score_id_text });
            defer pins.deinit();
            if (pins.rows() >= 3) return error.TooManyPinnedScores;
            var update = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.profile_score_pins(user_id,source,score_id,mode,rank_namespace) VALUES($1,$2,$3,$4,$5) ON CONFLICT(user_id,source,score_id) DO UPDATE SET pinned_at=extract(epoch FROM clock_timestamp())::bigint", &.{ user, source.text(), score_id_text, score.value(0, 0), score.value(0, 1) });
            update.deinit();
            if (source == .stable) {
                var legacy = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.score_pins(user_id,score_id) VALUES($1,$2) ON CONFLICT(user_id,score_id) DO UPDATE SET pinned_at=extract(epoch FROM clock_timestamp())::bigint", &.{ user, score_id_text });
                legacy.deinit();
            }
        } else {
            var update = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.profile_score_pins WHERE user_id=$1 AND source=$2 AND score_id=$3", &.{ user, source.text(), score_id_text });
            update.deinit();
            if (source == .stable) {
                var legacy = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.score_pins WHERE user_id=$1 AND score_id=$2", &.{ user, score_id_text });
                legacy.deinit();
            }
        }
        try postgres.exec(lease.conn, "COMMIT");
    }

    fn allocateBssIds(self: *Store, conn: *postgres.c.PGconn, kind: []const u8, count: u16) !i32 {
        if (count == 0 or (!std.mem.eql(u8, kind, "set") and !std.mem.eql(u8, kind, "beatmap"))) return error.InvalidBssReservation;
        var counter = try postgres.queryParams(self.allocator, conn, "SELECT next_id FROM zigcho.bss_counters WHERE kind=$1 FOR UPDATE", &.{kind});
        defer counter.deinit();
        if (counter.rows() != 1) return error.DatabaseQueryFailed;
        var start: i64 = @max(@as(i64, bss.private_id_floor), try counter.int(i64, 0, 0));
        var high = try postgres.query(conn, if (std.mem.eql(u8, kind, "set"))
            "SELECT greatest(coalesce((SELECT max(set_id) FROM zigcho.beatmaps),0),coalesce((SELECT max(set_id) FROM zigcho.beatmap_submissions),0))"
        else
            "SELECT greatest(coalesce((SELECT max(id) FROM zigcho.beatmaps),0),coalesce((SELECT max(beatmap_id) FROM zigcho.beatmap_submission_maps),0))");
        defer high.deinit();
        start = @max(start, try high.int(i64, 0, 0) + 1);
        const next = std.math.add(i64, start, count) catch return error.BssIdentifierExhausted;
        if (start > std.math.maxInt(i32) or next > @as(i64, std.math.maxInt(i32)) + 1) return error.BssIdentifierExhausted;
        var next_buf: [24]u8 = undefined;
        const next_text = try std.fmt.bufPrint(&next_buf, "{d}", .{next});
        var update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.bss_counters SET next_id=$2 WHERE kind=$1 RETURNING 1", &.{ kind, next_text });
        defer update.deinit();
        if (update.rows() != 1) return error.DatabaseQueryFailed;
        return @intCast(start);
    }

    pub fn reserveBssSubmission(self: *Store, allocator: std.mem.Allocator, user_id: i32, input: bss.ReserveInput) !bss.Reservation {
        const total = input.keep_ids.len + input.create_count;
        if (user_id <= 0 or total == 0 or total > bss.max_beatmaps) return error.InvalidBssReservation;
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        const ids = try allocator.alloc(i32, total);
        errdefer allocator.free(ids);
        var set_id: i32 = undefined;
        var revision: u32 = 1;
        var reissued_legacy_set: ?i32 = null;
        var reused_legacy_replacement = false;
        if (input.set_id) |existing_set| {
            var set_buf: [24]u8 = undefined;
            const set = try std.fmt.bufPrint(&set_buf, "{d}", .{existing_set});
            var submission = try postgres.queryParams(self.allocator, lease.conn, "SELECT owner_id,revision,state,(SELECT count(*) FROM zigcho.beatmaps WHERE set_id=$1),replacement_set_id FROM zigcho.beatmap_submissions WHERE set_id=$1 FOR UPDATE", &.{set});
            defer submission.deinit();
            if (submission.rows() == 0) return error.BssSubmissionNotFound;
            if (try submission.int(i32, 0, 0) != user_id) return error.BssNotOwner;
            const old_revision = try submission.int(i64, 0, 1);
            if (old_revision <= 0 or old_revision >= std.math.maxInt(u32)) return error.BssIdentifierExhausted;
            const reissue = existing_set < bss.private_id_floor and
                std.mem.eql(u8, submission.value(0, 2), "failed") and
                (try submission.int(i64, 0, 3)) == 0;
            for (input.keep_ids, 0..) |id, index| {
                var id_buf: [24]u8 = undefined;
                const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
                var owned = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND beatmap_id=$2", &.{ set, id_text });
                defer owned.deinit();
                if (owned.rows() == 0) return error.BssBeatmapNotOwned;
                if (!reissue) ids[index] = id;
            }
            if (reissue) {
                if (!submission.isNull(0, 4)) {
                    const replacement = try submission.int(i32, 0, 4);
                    var replacement_buf: [24]u8 = undefined;
                    const replacement_text = try std.fmt.bufPrint(&replacement_buf, "{d}", .{replacement});
                    var replacement_result = try postgres.queryParams(self.allocator, lease.conn, "SELECT owner_id,revision,(SELECT count(*) FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND active) FROM zigcho.beatmap_submissions WHERE set_id=$1 FOR UPDATE", &.{replacement_text});
                    defer replacement_result.deinit();
                    if (replacement_result.rows() != 1 or (try replacement_result.int(i32, 0, 0)) != user_id or (try replacement_result.int(usize, 0, 2)) != total) return error.InvalidBssReservation;
                    const replacement_revision = try replacement_result.int(i64, 0, 1);
                    if (replacement_revision <= 0 or replacement_revision >= std.math.maxInt(u32)) return error.BssIdentifierExhausted;
                    revision = @intCast(replacement_revision + 1);
                    set_id = replacement;
                    var replacement_maps = try postgres.queryParams(self.allocator, lease.conn, "SELECT beatmap_id FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND active ORDER BY position,beatmap_id", &.{replacement_text});
                    defer replacement_maps.deinit();
                    if (replacement_maps.rows() != ids.len) return error.InvalidBssReservation;
                    for (ids, 0..) |*id, row| id.* = try replacement_maps.int(i32, row, 0);
                    reused_legacy_replacement = true;
                } else {
                    reissued_legacy_set = existing_set;
                    set_id = try self.allocateBssIds(lease.conn, "set", 1);
                    revision = 1;
                }
            } else {
                revision = @intCast(old_revision + 1);
                set_id = existing_set;
                var deactivate = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submission_maps SET active=false WHERE set_id=$1", &.{set});
                deactivate.deinit();
                for (input.keep_ids, 0..) |id, position| {
                    var id_buf: [24]u8 = undefined;
                    var position_buf: [24]u8 = undefined;
                    const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
                    const position_text = try std.fmt.bufPrint(&position_buf, "{d}", .{position});
                    var keep = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submission_maps SET active=true,position=$3 WHERE set_id=$1 AND beatmap_id=$2 RETURNING 1", &.{ set, id_text, position_text });
                    defer keep.deinit();
                    if (keep.rows() != 1) return error.DatabaseQueryFailed;
                }
            }
        } else {
            set_id = try self.allocateBssIds(lease.conn, "set", 1);
        }
        if (input.set_id == null or reissued_legacy_set != null) {
            var set_buf: [24]u8 = undefined;
            const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
            var create = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_submissions(set_id,owner_id,target,notify_replies) VALUES($1,$2,$3,$4::boolean)", &.{ set, user, input.target.database(), if (input.notify_replies) "true" else "false" });
            create.deinit();
        }
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const allocate_count: u16 = if (reissued_legacy_set != null) @intCast(total) else if (reused_legacy_replacement) 0 else input.create_count;
        if (allocate_count > 0) {
            const first = try self.allocateBssIds(lease.conn, "beatmap", allocate_count);
            for (0..allocate_count) |offset| {
                const id: i32 = first + @as(i32, @intCast(offset));
                const position = if (reissued_legacy_set != null) offset else input.keep_ids.len + offset;
                ids[position] = id;
                var id_buf: [24]u8 = undefined;
                var position_buf: [24]u8 = undefined;
                const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
                const position_text = try std.fmt.bufPrint(&position_buf, "{d}", .{position});
                var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_submission_maps(set_id,beatmap_id,position) VALUES($1,$2,$3)", &.{ set, id_text, position_text });
                insert.deinit();
            }
        }
        if (reissued_legacy_set) |legacy_set| {
            var legacy_buf: [24]u8 = undefined;
            const legacy = try std.fmt.bufPrint(&legacy_buf, "{d}", .{legacy_set});
            var alias = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submissions SET replacement_set_id=$3,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND owner_id=$2 AND state='failed' AND replacement_set_id IS NULL RETURNING 1", &.{ legacy, user, set });
            defer alias.deinit();
            if (alias.rows() != 1) return error.DatabaseQueryFailed;
        }
        if (input.set_id != null) {
            var revision_buf: [24]u8 = undefined;
            const revision_text = try std.fmt.bufPrint(&revision_buf, "{d}", .{revision});
            var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submissions SET target=$2,notify_replies=$3::boolean,state='reserved',revision=$4,last_error='',updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND owner_id=$5 RETURNING 1", &.{ set, input.target.database(), if (input.notify_replies) "true" else "false", revision_text, user });
            defer update.deinit();
            if (update.rows() != 1) return error.DatabaseQueryFailed;
        }
        try postgres.exec(lease.conn, "COMMIT");
        return .{ .allocator = allocator, .set_id = set_id, .beatmap_ids = ids, .revision = revision };
    }

    pub fn bssReservedMapIds(self: *Store, allocator: std.mem.Allocator, user_id: i32, set_id: i32) ![]i32 {
        var user_buf: [24]u8 = undefined;
        var set_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT m.beatmap_id FROM zigcho.beatmap_submissions s JOIN zigcho.beatmap_submission_maps m ON m.set_id=s.set_id WHERE s.set_id=$1 AND s.owner_id=$2 AND m.active ORDER BY m.position,m.beatmap_id", &.{ set, user });
        defer result.deinit();
        if (result.rows() == 0) {
            var owner = try postgres.queryParams(self.allocator, lease.conn, "SELECT owner_id FROM zigcho.beatmap_submissions WHERE set_id=$1", &.{set});
            defer owner.deinit();
            if (owner.rows() == 0) return error.BssSubmissionNotFound;
            if (try owner.int(i32, 0, 0) != user_id) return error.BssNotOwner;
            return error.InvalidBssReservation;
        }
        if (result.rows() > bss.max_beatmaps) return error.InvalidBssReservation;
        const ids = try allocator.alloc(i32, result.rows());
        for (ids, 0..) |*id, row| id.* = try result.int(i32, row, 0);
        return ids;
    }

    pub fn failBssSubmission(self: *Store, user_id: i32, set_id: i32, reason: []const u8) !void {
        const trimmed = std.mem.trim(u8, reason, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 500) return error.InvalidBssFailure;
        var user_buf: [24]u8 = undefined;
        var set_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submissions SET state='failed',last_error=$3,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND owner_id=$2 RETURNING 1", &.{ set, user, trimmed });
        defer result.deinit();
        if (result.rows() != 1) return error.BssNotOwner;
    }

    pub fn publishBssSubmission(self: *Store, user_id: i32, set_id: i32, package: *const bss.Package, archive: []const u8, sha256: []const u8) !void {
        if (archive.len == 0 or archive.len > bss.max_upload_bytes or package.maps.len == 0 or package.maps.len > bss.max_beatmaps or !object_keys.validSha256(sha256)) return error.InvalidBssArchive;
        var object_written = false;
        if (self.object_store.enabled()) {
            const object_key = try object_keys.archive(self.allocator, set_id, sha256);
            defer self.allocator.free(object_key);
            try self.object_store.put(self.allocator, self.io, object_key, "application/octet-stream", archive);
            object_written = true;
        }
        if (self.external_only and !object_written) return error.BssObjectStorageRequired;

        var user_buf: [24]u8 = undefined;
        var set_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var submission = try postgres.queryParams(self.allocator, lease.conn, "SELECT submission.owner_id,submission.target,owner.name FROM zigcho.beatmap_submissions submission JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE submission.set_id=$1 FOR UPDATE OF submission", &.{set});
        defer submission.deinit();
        if (submission.rows() == 0) return error.BssSubmissionNotFound;
        if (try submission.int(i32, 0, 0) != user_id) return error.BssNotOwner;
        const target = bss.Target.parse(submission.value(0, 1)) orelse return error.DatabaseQueryFailed;
        const owner_name = submission.value(0, 2);
        var count = try postgres.queryParams(self.allocator, lease.conn, "SELECT count(*) FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND active", &.{set});
        defer count.deinit();
        if (try count.int(usize, 0, 0) != package.maps.len) return error.BssRevisionMismatch;

        const upsert_sql = "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,last_update,total_length,max_combo,mode,bpm,cs,ar,od,hp,star_rating,source,tags,osu_file,count_circles,count_sliders,count_spinners) VALUES($1,$2,$3,$4,$5,$6,$7,$8,extract(epoch FROM clock_timestamp())::bigint,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23) ON CONFLICT(id) DO UPDATE SET set_id=excluded.set_id,md5=excluded.md5,artist=excluded.artist,title=excluded.title,version=excluded.version,creator=excluded.creator,creator_id=NULL,status=excluded.status,last_update=excluded.last_update,total_length=excluded.total_length,max_combo=excluded.max_combo,mode=excluded.mode,bpm=excluded.bpm,cs=excluded.cs,ar=excluded.ar,od=excluded.od,hp=excluded.hp,star_rating=excluded.star_rating,source=excluded.source,tags=excluded.tags,osu_file=excluded.osu_file,count_circles=excluded.count_circles,count_sliders=excluded.count_sliders,count_spinners=excluded.count_spinners";
        for (package.maps) |map| {
            if (map.metadata.set_id != set_id) return error.BssRevisionMismatch;
            var map_id_buf: [24]u8 = undefined;
            const map_id = try std.fmt.bufPrint(&map_id_buf, "{d}", .{map.metadata.id});
            var active = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND beatmap_id=$2 AND active", &.{ set, map_id });
            defer active.deinit();
            if (active.rows() != 1) return error.BssRevisionMismatch;
            const encoded = try postgres.encodeBytea(self.allocator, map.contents);
            defer self.allocator.free(encoded);
            var status_buf: [8]u8 = undefined;
            var length_buf: [24]u8 = undefined;
            var combo_buf: [24]u8 = undefined;
            var mode_buf: [8]u8 = undefined;
            var bpm_buf: [48]u8 = undefined;
            var cs_buf: [48]u8 = undefined;
            var ar_buf: [48]u8 = undefined;
            var od_buf: [48]u8 = undefined;
            var hp_buf: [48]u8 = undefined;
            var stars_buf: [48]u8 = undefined;
            var circles_buf: [24]u8 = undefined;
            var sliders_buf: [24]u8 = undefined;
            var spinners_buf: [24]u8 = undefined;
            const status = try std.fmt.bufPrint(&status_buf, "{d}", .{target.status()});
            const total_length = try std.fmt.bufPrint(&length_buf, "{d}", .{map.metadata.total_length});
            const max_combo = try std.fmt.bufPrint(&combo_buf, "{d}", .{map.max_combo});
            const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{map.metadata.mode});
            const bpm = try std.fmt.bufPrint(&bpm_buf, "{d}", .{map.metadata.bpm});
            const cs = try std.fmt.bufPrint(&cs_buf, "{d}", .{map.metadata.cs});
            const ar = try std.fmt.bufPrint(&ar_buf, "{d}", .{map.metadata.ar});
            const od = try std.fmt.bufPrint(&od_buf, "{d}", .{map.metadata.od});
            const hp = try std.fmt.bufPrint(&hp_buf, "{d}", .{map.metadata.hp});
            const stars = try std.fmt.bufPrint(&stars_buf, "{d}", .{map.stars});
            const circles = try std.fmt.bufPrint(&circles_buf, "{d}", .{map.metadata.count_circles});
            const sliders = try std.fmt.bufPrint(&sliders_buf, "{d}", .{map.metadata.count_sliders});
            const spinners = try std.fmt.bufPrint(&spinners_buf, "{d}", .{map.metadata.count_spinners});
            var upsert = try postgres.queryParams(self.allocator, lease.conn, upsert_sql, &.{ map_id, set, &map.md5, map.metadata.artist, map.metadata.title, map.metadata.version, owner_name, status, total_length, max_combo, mode, bpm, cs, ar, od, hp, stars, map.metadata.source, map.metadata.tags, encoded, circles, sliders, spinners });
            upsert.deinit();
        }
        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{d}", .{archive.len});
        if (self.external_only and object_written) {
            var stored = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES($1,$2,NULL,$3,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=NULL,object_bytes=excluded.object_bytes,imported_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, size });
            stored.deinit();
        } else {
            const encoded_archive = try postgres.encodeBytea(self.allocator, archive);
            defer self.allocator.free(encoded_archive);
            var stored = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES($1,$2,$3,$4,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,object_bytes=excluded.object_bytes,imported_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, encoded_archive, size });
            stored.deinit();
        }
        if (target == .pending) {
            var first_map_buf: [24]u8 = undefined;
            const first_map = try std.fmt.bufPrint(&first_map_buf, "{d}", .{package.maps[0].metadata.id});
            var request = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_rank_requests(set_id,map_id,requester_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING 1", &.{ set, first_map, user });
            const inserted = request.rows() == 1;
            request.deinit();
            if (inserted) try insertBeatmapRankEvent(self.allocator, lease.conn, set_id, user_id, "request", target.status(), target.status(), "lazer BSS pending submission");
        } else {
            var close_requests = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_rank_requests SET active=false,resolved_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND active", &.{set});
            close_requests.deinit();
            var close_nominations = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_nominations SET active=false,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND active", &.{set});
            close_nominations.deinit();
        }
        var complete = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_submissions SET state='published',last_error='',updated_at=extract(epoch FROM clock_timestamp())::bigint,uploaded_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND owner_id=$2 RETURNING 1", &.{ set, user });
        defer complete.deinit();
        if (complete.rows() != 1) return error.BssRevisionMismatch;
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn upsertBeatmapArchive(self: *Store, set_id: i32, sha256: []const u8, osz_file: []const u8) !void {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        if (!try self.beatmapSetExists(set_id)) return error.UnknownBeatmapSet;
        const object_written = upload: {
            if (!self.object_store.enabled() or !object_keys.validSha256(sha256)) break :upload false;
            const object_key = try object_keys.archive(self.allocator, set_id, sha256);
            defer self.allocator.free(object_key);
            self.object_store.put(self.allocator, self.io, object_key, "application/octet-stream", osz_file) catch |err| {
                std.log.warn("event=beatmap_archive_object_write_failed set_id={d} error={t}", .{ set_id, err });
                break :upload false;
            };
            break :upload true;
        };
        var lease = self.pool.acquire();
        defer lease.release();
        var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE set_id=$1 LIMIT 1", &.{set});
        defer exists.deinit();
        if (exists.rows() == 0) return error.UnknownBeatmapSet;
        if (self.external_only and object_written) {
            var size_buf: [32]u8 = undefined;
            const size = try std.fmt.bufPrint(&size_buf, "{d}", .{osz_file.len});
            var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES($1,$2,NULL,$3,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=NULL,object_bytes=excluded.object_bytes,imported_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, size });
            result.deinit();
        } else {
            const encoded = try postgres.encodeBytea(self.allocator, osz_file);
            defer self.allocator.free(encoded);
            var size_buf: [32]u8 = undefined;
            const size = try std.fmt.bufPrint(&size_buf, "{d}", .{osz_file.len});
            var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_archives(set_id,sha256,osz_file,object_bytes,last_accessed_at) VALUES($1,$2,$3,$4,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id) DO UPDATE SET sha256=excluded.sha256,osz_file=excluded.osz_file,object_bytes=excluded.object_bytes,imported_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, sha256, encoded, size });
            result.deinit();
        }
    }

    pub fn beatmapSetExists(self: *Store, set_id: i32) !bool {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE set_id=$1 LIMIT 1", &.{set});
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn beatmapSetIdsMissingArchives(self: *Store, allocator: std.mem.Allocator, limit: u16) ![]i32 {
        if (limit == 0) return allocator.alloc(i32, 0);
        var limit_buf: [12]u8 = undefined;
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.set_id FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmap_archives a ON a.set_id=b.set_id WHERE b.set_id>0 AND a.set_id IS NULL GROUP BY b.set_id ORDER BY max(b.last_update) DESC,b.set_id DESC LIMIT $1", &.{limit_text});
        defer result.deinit();
        const ids = try allocator.alloc(i32, result.rows());
        errdefer allocator.free(ids);
        for (ids, 0..) |*id, row| id.* = try result.int(i32, row, 0);
        return ids;
    }

    pub fn beatmapArchiveIdsMissingSize(self: *Store, allocator: std.mem.Allocator, limit: u16) ![]i32 {
        if (limit == 0) return allocator.alloc(i32, 0);
        var limit_buf: [12]u8 = undefined;
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmap_archives WHERE object_bytes=0 ORDER BY set_id LIMIT $1", &.{limit_text});
        defer result.deinit();
        const ids = try allocator.alloc(i32, result.rows());
        errdefer allocator.free(ids);
        for (ids, 0..) |*id, row| id.* = try result.int(i32, row, 0);
        return ids;
    }

    pub fn setBeatmapArchiveSize(self: *Store, set_id: i32, bytes: usize) !void {
        var set_buf: [24]u8 = undefined;
        var bytes_buf: [32]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const size = try std.fmt.bufPrint(&bytes_buf, "{d}", .{bytes});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_archives SET object_bytes=$2 WHERE set_id=$1", &.{ set, size });
        result.deinit();
    }

    pub fn beatmapMirrorPendingCount(self: *Store) !i64 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT count(*) FROM (SELECT b.set_id FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmap_archives a ON a.set_id=b.set_id WHERE b.set_id>0 AND a.set_id IS NULL GROUP BY b.set_id) pending");
        defer result.deinit();
        return try result.int(i64, 0, 0);
    }

    pub fn beatmapSetCreator(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?BeatmapSetCreator {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT coalesce(max(owner.name),b.creator),min(b.mode),coalesce(max(owner.id),max(b.creator_id)),max(owner.id) IS NOT NULL FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.set_id=$1 GROUP BY b.creator ORDER BY count(*) DESC,b.creator LIMIT 1", &.{set});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const name = try allocator.dupe(u8, result.value(0, 0));
        return .{
            .allocator = allocator,
            .name = name,
            .mode = try result.int(u8, 0, 1),
            .user_id = if (result.isNull(0, 2)) null else try result.int(i32, 0, 2),
            .is_local = try result.boolean(0, 3),
        };
    }

    pub fn upstreamUserCacheByName(self: *Store, name: []const u8, mode: u8, now: i64, max_age: i64) !?UpstreamUserCache {
        if (mode > 3 or now < 0 or max_age < 0) return error.InvalidUpstreamUser;
        var mode_buf: [4]u8 = undefined;
        var now_buf: [32]u8 = undefined;
        var age_buf: [32]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
        const age_text = try std.fmt.bufPrint(&age_buf, "{d}", .{max_age});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.id,coalesce(p.fetched_at>=$3::bigint-$4::bigint,false) FROM zigcho.upstream_users u LEFT JOIN zigcho.upstream_user_profiles p ON p.user_id=u.id AND p.mode=$2 WHERE lower(u.username)=lower($1) ORDER BY u.fetched_at DESC,u.id LIMIT 1", &.{ name, mode_text, now_text, age_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .id = try result.int(i32, 0, 0), .fresh = try result.boolean(0, 1) };
    }

    pub fn upstreamUserCacheById(self: *Store, user_id: i32, mode: u8, now: i64, max_age: i64) !?UpstreamUserCache {
        if (user_id <= 0 or mode > 3 or now < 0 or max_age < 0) return error.InvalidUpstreamUser;
        var id_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        var now_buf: [32]u8 = undefined;
        var age_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
        const age_text = try std.fmt.bufPrint(&age_buf, "{d}", .{max_age});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.id,coalesce(p.fetched_at>=$3::bigint-$4::bigint,false) FROM zigcho.upstream_users u LEFT JOIN zigcho.upstream_user_profiles p ON p.user_id=u.id AND p.mode=$2 WHERE u.id=$1", &.{ id, mode_text, now_text, age_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .id = try result.int(i32, 0, 0), .fresh = try result.boolean(0, 1) };
    }

    pub fn upsertUpstreamUserProfile(self: *Store, profile: upstream_user.Profile, profile_json: []const u8, fetched_at: i64) !void {
        try upstream_user.validate(profile);
        if (fetched_at < 0 or profile_json.len == 0 or profile_json.len > 128 * 1024 or !std.unicode.utf8ValidateSlice(profile_json)) return error.InvalidUpstreamUser;
        var id_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        var fetched_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{profile.id});
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{profile.mode});
        const fetched = try std.fmt.bufPrint(&fetched_buf, "{d}", .{fetched_at});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var user_result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.upstream_users(id,username,country,join_date,fetched_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(id) DO UPDATE SET username=excluded.username,country=excluded.country,join_date=excluded.join_date,fetched_at=excluded.fetched_at", &.{ id, profile.username, profile.country[0..], profile.join_date, fetched });
        user_result.deinit();
        var profile_result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.upstream_user_profiles(user_id,mode,profile_json,fetched_at) VALUES($1,$2,$3::jsonb,$4) ON CONFLICT(user_id,mode) DO UPDATE SET profile_json=excluded.profile_json,fetched_at=excluded.fetched_at", &.{ id, mode_text, profile_json, fetched });
        profile_result.deinit();
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn linkBeatmapSetCreator(self: *Store, set_id: i32, user_id: i32) !void {
        if (set_id <= 0 or user_id <= 0) return error.InvalidUpstreamUser;
        var set_buf: [24]u8 = undefined;
        var id_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET creator_id=$2 WHERE set_id=$1 AND EXISTS(SELECT 1 FROM zigcho.upstream_users WHERE id=$2)", &.{ set, id });
        result.deinit();
    }

    pub fn upstreamUserProfileJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, mode: u8) !?[]u8 {
        if (user_id <= 0 or mode > 3) return null;
        var id_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT profile_json::text FROM zigcho.upstream_user_profiles WHERE user_id=$1 ORDER BY mode=$2::int DESC,mode=0 DESC,mode LIMIT 1", &.{ id, mode_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return @as(?[]u8, try allocator.dupe(u8, result.value(0, 0)));
    }

    pub fn upsertBeatmapSetMetadata(self: *Store, metadata: upstream_user.SetMetadata, fetched_at: i64) !void {
        if (metadata.set_id <= 0 or metadata.favourites < 0 or metadata.genre_id < 0 or metadata.language_id < 0 or fetched_at < 0 or metadata.submitted_date.len != 20 or metadata.last_updated.len != 20 or (metadata.ranked_date != null and metadata.ranked_date.?.len != 20)) return error.InvalidBeatmapSetMetadata;
        var set_buf: [24]u8 = undefined;
        var favourites_buf: [24]u8 = undefined;
        var genre_buf: [8]u8 = undefined;
        var language_buf: [8]u8 = undefined;
        var fetched_buf: [32]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{metadata.set_id});
        const favourites = try std.fmt.bufPrint(&favourites_buf, "{d}", .{metadata.favourites});
        const genre = try std.fmt.bufPrint(&genre_buf, "{d}", .{metadata.genre_id});
        const language = try std.fmt.bufPrint(&language_buf, "{d}", .{metadata.language_id});
        const fetched = try std.fmt.bufPrint(&fetched_buf, "{d}", .{fetched_at});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmapset_metadata(set_id,favourites,submitted_date,last_updated,ranked_date,has_video,genre_id,language_id,fetched_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(set_id) DO UPDATE SET favourites=excluded.favourites,submitted_date=excluded.submitted_date,last_updated=excluded.last_updated,ranked_date=excluded.ranked_date,has_video=excluded.has_video,genre_id=excluded.genre_id,language_id=excluded.language_id,fetched_at=excluded.fetched_at", &.{ set, favourites, metadata.submitted_date, metadata.last_updated, metadata.ranked_date, if (metadata.has_video) "true" else "false", genre, language, fetched });
        result.deinit();
    }

    pub fn updateBeatmapUpstreamStats(self: *Store, beatmap_id: i32, plays: i32, passes: i32, hit_length: i32) !void {
        if (beatmap_id <= 0 or plays < 0 or passes < 0 or passes > plays or hit_length < 0) return error.InvalidBeatmapSetMetadata;
        var map_buf: [24]u8 = undefined;
        var plays_buf: [24]u8 = undefined;
        var passes_buf: [24]u8 = undefined;
        var hit_buf: [24]u8 = undefined;
        const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
        const play_count = try std.fmt.bufPrint(&plays_buf, "{d}", .{plays});
        const pass_count = try std.fmt.bufPrint(&passes_buf, "{d}", .{passes});
        const hit = try std.fmt.bufPrint(&hit_buf, "{d}", .{hit_length});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET upstream_plays=$2,upstream_passes=$3,hit_length=$4 WHERE id=$1", &.{ map, play_count, pass_count, hit });
        result.deinit();
    }

    pub fn beatmapSetIdForMap(self: *Store, beatmap_id: i32) !?i32 {
        var map_buf: [24]u8 = undefined;
        const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE id=$1", &.{map});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try result.int(i32, 0, 0);
    }

    pub fn beatmapSetIdForChecksum(self: *Store, checksum: []const u8) !?i32 {
        if (!lazer.validHash(checksum)) return null;
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE md5=$1", &.{checksum});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try result.int(i32, 0, 0);
    }

    pub fn putBeatmapMedia(self: *Store, set_id: i32, kind: media_contract.Kind, content_type: media_contract.ContentType, data: []const u8) !void {
        if (!media_contract.compatible(kind, content_type) or media_contract.detect(kind, data) != content_type) return error.InvalidBeatmapMedia;
        if (!try self.beatmapSetExists(set_id)) return error.UnknownBeatmapSet;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        var encoded_digest: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&encoded_digest, "{x}", .{digest}) catch unreachable;
        const object_written = upload: {
            if (!self.object_store.enabled()) break :upload false;
            const object_key = try object_keys.media(self.allocator, set_id, kind, content_type, &encoded_digest);
            defer self.allocator.free(object_key);
            self.object_store.put(self.allocator, self.io, object_key, content_type.value(), data) catch |err| {
                std.log.warn("event=beatmap_media_object_write_failed set_id={d} kind={s} error={t}", .{ set_id, kind.dbName(), err });
                break :upload false;
            };
            break :upload true;
        };
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE set_id=$1 LIMIT 1", &.{set});
        defer exists.deinit();
        if (exists.rows() == 0) return error.UnknownBeatmapSet;
        if (self.external_only and object_written) {
            var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_media(set_id,kind,content_type,sha256,data,last_accessed_at) VALUES($1,$2,$3,$4,NULL,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id,kind) DO UPDATE SET content_type=excluded.content_type,sha256=excluded.sha256,data=NULL,fetched_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, kind.dbName(), content_type.value(), &encoded_digest });
            result.deinit();
        } else {
            const encoded_data = try postgres.encodeBytea(self.allocator, data);
            defer self.allocator.free(encoded_data);
            var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_media(set_id,kind,content_type,sha256,data,last_accessed_at) VALUES($1,$2,$3,$4,$5,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(set_id,kind) DO UPDATE SET content_type=excluded.content_type,sha256=excluded.sha256,data=excluded.data,fetched_at=extract(epoch FROM clock_timestamp())::bigint,last_accessed_at=extract(epoch FROM clock_timestamp())::bigint", &.{ set, kind.dbName(), content_type.value(), &encoded_digest, encoded_data });
            result.deinit();
        }
    }

    pub fn beatmapMedia(self: *Store, allocator: std.mem.Allocator, set_id: i32, kind: media_contract.Kind) !?media_contract.Asset {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const stored = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_media SET last_accessed_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND kind=$2 RETURNING content_type,sha256,data", &.{ set, kind.dbName() });
            defer result.deinit();
            if (result.rows() == 0) return null;
            const content_type = media_contract.ContentType.parse(result.value(0, 0)) orelse return error.InvalidStoredBeatmapMedia;
            const sha256 = try allocator.dupe(u8, result.value(0, 1));
            errdefer allocator.free(sha256);
            const data: ?[]u8 = if (result.isNull(0, 2)) null else try postgres.decodeBytea(allocator, result.value(0, 2));
            errdefer if (data) |owned| allocator.free(owned);
            if (!media_contract.compatible(kind, content_type) or !object_keys.validSha256(sha256)) return error.InvalidStoredBeatmapMedia;
            break :blk .{ .data = data, .content_type = content_type, .sha256 = sha256 };
        };
        defer allocator.free(stored.sha256);
        if (self.object_store.enabled()) {
            const object_key = try object_keys.media(allocator, set_id, kind, stored.content_type, stored.sha256);
            defer allocator.free(object_key);
            const limit = if (stored.data) |fallback| fallback.len else kind.maxBytes();
            if (self.object_store.getWithLimit(allocator, self.io, object_key, stored.content_type.value(), limit)) |data| {
                if (object_keys.matchesSha256(data, stored.sha256) and media_contract.detect(kind, data) == stored.content_type) {
                    if (stored.data) |fallback| allocator.free(fallback);
                    return .{ .data = data, .content_type = stored.content_type };
                }
                allocator.free(data);
                std.log.warn("event=beatmap_media_object_invalid set_id={d} kind={s}", .{ set_id, kind.dbName() });
            } else |err| std.log.warn("event=beatmap_media_object_read_failed set_id={d} kind={s} error={t}", .{ set_id, kind.dbName(), err });
        }
        const fallback = stored.data orelse return null;
        if (media_contract.detect(kind, fallback) != stored.content_type or !object_keys.matchesSha256(fallback, stored.sha256)) {
            allocator.free(fallback);
            return error.InvalidStoredBeatmapMedia;
        }
        return .{ .data = fallback, .content_type = stored.content_type };
    }

    pub fn beatmapMediaCacheStats(self: *Store) !BeatmapMediaCacheStats {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT count(*),coalesce(sum(octet_length(data)),0) FROM zigcho.beatmap_media");
        defer result.deinit();
        return .{ .entries = try result.int(i64, 0, 0), .bytes = try result.int(i64, 0, 1) };
    }

    pub fn pruneBeatmapMedia(self: *Store, max_bytes: u64) !BeatmapCachePrune {
        if (self.object_store.enabled()) return .{ .entries = 0, .bytes = 0 };
        var max_buf: [32]u8 = undefined;
        const max_text = try std.fmt.bufPrint(&max_buf, "{d}", .{@min(max_bytes, @as(u64, std.math.maxInt(i64)))});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "WITH ranked AS (SELECT set_id,kind,octet_length(data) AS bytes,sum(octet_length(data)) OVER(ORDER BY last_accessed_at DESC,fetched_at DESC,set_id DESC,kind DESC) AS running_bytes FROM zigcho.beatmap_media),deleted AS (DELETE FROM zigcho.beatmap_media m USING ranked r WHERE m.set_id=r.set_id AND m.kind=r.kind AND r.running_bytes>$1::bigint RETURNING octet_length(m.data) AS bytes) SELECT count(*),coalesce(sum(bytes),0) FROM deleted", &.{max_text});
        defer result.deinit();
        return .{ .entries = try result.int(i64, 0, 0), .bytes = try result.int(i64, 0, 1) };
    }

    pub fn beatmapArchive(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?[]u8 {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const stored = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_archives SET last_accessed_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 RETURNING sha256,osz_file", &.{set});
            defer result.deinit();
            if (result.rows() == 0) return null;
            const sha256 = try allocator.dupe(u8, result.value(0, 0));
            errdefer allocator.free(sha256);
            const data: ?[]u8 = if (result.isNull(0, 1)) null else try postgres.decodeBytea(allocator, result.value(0, 1));
            errdefer if (data) |owned| allocator.free(owned);
            break :blk .{ .data = data, .sha256 = sha256 };
        };
        defer allocator.free(stored.sha256);
        if (self.object_store.enabled() and object_keys.validSha256(stored.sha256)) {
            const object_key = try object_keys.archive(allocator, set_id, stored.sha256);
            defer allocator.free(object_key);
            const limit = if (stored.data) |fallback| fallback.len else archive_object_limit;
            if (self.object_store.getWithLimit(allocator, self.io, object_key, "application/octet-stream", limit)) |data| {
                if (object_keys.matchesSha256(data, stored.sha256)) {
                    if (stored.data) |fallback| allocator.free(fallback);
                    return data;
                }
                allocator.free(data);
                std.log.warn("event=beatmap_archive_object_invalid set_id={d}", .{set_id});
            } else |err| std.log.warn("event=beatmap_archive_object_read_failed set_id={d} error={t}", .{ set_id, err });
        }
        const fallback = stored.data orelse return null;
        if (!object_keys.matchesSha256(fallback, stored.sha256)) {
            allocator.free(fallback);
            return error.InvalidStoredBeatmapArchive;
        }
        return fallback;
    }

    pub fn beatmapArchiveDownload(self: *Store, allocator: std.mem.Allocator, set_id: i32) !?BeatmapArchiveDownload {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const stored = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_archives SET last_accessed_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 RETURNING sha256,osz_file,object_bytes", &.{set});
            defer result.deinit();
            if (result.rows() == 0) return null;
            const sha256 = try allocator.dupe(u8, result.value(0, 0));
            errdefer allocator.free(sha256);
            const data: ?[]u8 = if (result.isNull(0, 1)) null else try postgres.decodeBytea(allocator, result.value(0, 1));
            errdefer if (data) |value| allocator.free(value);
            const bytes_i64 = try result.int(i64, 0, 2);
            if (bytes_i64 <= 0 or bytes_i64 > archive_object_limit) return error.InvalidStoredBeatmapArchive;
            break :blk .{ .sha256 = sha256, .data = data, .bytes = @as(usize, @intCast(bytes_i64)) };
        };
        defer allocator.free(stored.sha256);
        if (stored.data) |data| {
            if (data.len != stored.bytes or !object_keys.matchesSha256(data, stored.sha256)) {
                allocator.free(data);
                return error.InvalidStoredBeatmapArchive;
            }
        }
        errdefer if (stored.data) |data| allocator.free(data);
        const object_key = if (self.object_store.enabled() and object_keys.validSha256(stored.sha256))
            try object_keys.archive(allocator, set_id, stored.sha256)
        else
            null;
        if (object_key == null and stored.data == null) return null;
        return .{ .allocator = allocator, .object_key = object_key, .data = stored.data, .bytes = stored.bytes };
    }

    pub fn streamBeatmapArchive(self: *Store, download: BeatmapArchiveDownload, writer: *std.Io.Writer) !void {
        if (download.object_key) |object_key| {
            return self.object_store.streamGet(self.allocator, self.io, object_key, "application/octet-stream", writer);
        }
        try writer.writeAll(download.data orelse return error.BeatmapArchiveUnavailable);
    }

    pub fn beatmapArchiveRedirectUrl(self: *Store, allocator: std.mem.Allocator, download: BeatmapArchiveDownload) !?[]u8 {
        const object_key = download.object_key orelse return null;
        return try self.object_store.presignedGetUrl(allocator, self.io, object_key, 15 * 60);
    }

    pub fn hydrationRetryAllowed(self: *Store, md5: []const u8, now: i64) !bool {
        var now_buf: [32]u8 = undefined;
        const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT next_retry_at<=$2 FROM zigcho.beatmap_hydration_failures WHERE md5=$1", &.{ md5, now_text });
        defer result.deinit();
        if (result.rows() == 0) return true;
        return try result.boolean(0, 0);
    }

    pub fn recordHydrationFailure(self: *Store, md5: []const u8, set_id: i32, reason: []const u8, now: i64) !void {
        var set_buf: [24]u8 = undefined;
        var now_buf: [32]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const now_text = try std.fmt.bufPrint(&now_buf, "{d}", .{now});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_hydration_failures(md5,set_id,attempts,next_retry_at,last_error,updated_at) VALUES($1,$2,1,$4::bigint+30,$3,$4) ON CONFLICT(md5) DO UPDATE SET set_id=excluded.set_id,attempts=least(32,zigcho.beatmap_hydration_failures.attempts+1),next_retry_at=excluded.updated_at+least(21600,(30*power(2,least(zigcho.beatmap_hydration_failures.attempts,10)))::bigint),last_error=excluded.last_error,updated_at=excluded.updated_at", &.{ md5, set, reason, now_text });
        result.deinit();
        var trim = try postgres.query(lease.conn, "DELETE FROM zigcho.beatmap_hydration_failures WHERE md5 IN(SELECT md5 FROM zigcho.beatmap_hydration_failures ORDER BY updated_at DESC,md5 DESC OFFSET 10000)");
        trim.deinit();
    }

    pub fn clearHydrationFailure(self: *Store, md5: []const u8) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.beatmap_hydration_failures WHERE md5=$1", &.{md5});
        result.deinit();
    }

    pub fn beatmapCacheStats(self: *Store) !BeatmapCacheStats {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT count(*),coalesce(sum(object_bytes),0),(SELECT count(*) FROM zigcho.beatmap_hydration_failures) FROM zigcho.beatmap_archives");
        defer result.deinit();
        return .{ .entries = try result.int(i64, 0, 0), .bytes = try result.int(i64, 0, 1), .hydration_failures = try result.int(i64, 0, 2) };
    }

    pub fn pruneBeatmapArchives(self: *Store, max_bytes: u64) !BeatmapCachePrune {
        if (self.object_store.enabled()) return .{ .entries = 0, .bytes = 0 };
        var max_buf: [32]u8 = undefined;
        const max_text = try std.fmt.bufPrint(&max_buf, "{d}", .{@min(max_bytes, @as(u64, std.math.maxInt(i64)))});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "WITH ranked AS (SELECT set_id,octet_length(osz_file) AS bytes,sum(octet_length(osz_file)) OVER(ORDER BY last_accessed_at DESC,imported_at DESC,set_id DESC) AS running_bytes FROM zigcho.beatmap_archives),deleted AS (DELETE FROM zigcho.beatmap_archives WHERE set_id IN(SELECT set_id FROM ranked WHERE running_bytes>$1::bigint) RETURNING octet_length(osz_file) AS bytes) SELECT count(*),coalesce(sum(bytes),0) FROM deleted", &.{max_text});
        defer result.deinit();
        return .{ .entries = try result.int(i64, 0, 0), .bytes = try result.int(i64, 0, 1) };
    }

    fn putVerifiedObject(self: *Store, object_key: []const u8, content_type: []const u8, bytes: []const u8, sha256: []const u8) !void {
        try self.object_store.put(self.allocator, self.io, object_key, content_type, bytes);
        const downloaded = try self.object_store.getWithLimit(self.allocator, self.io, object_key, content_type, bytes.len);
        defer self.allocator.free(downloaded);
        if (downloaded.len != bytes.len or !object_keys.matchesSha256(downloaded, sha256)) return error.ObjectVerificationFailed;
    }

    pub fn storeReplayObject(self: *Store, source: ReplaySource, score_id: i64, data: []const u8) !bool {
        if (!self.object_store.enabled()) return false;
        if (score_id <= 0 or data.len == 0 or data.len > max_replay_object_bytes) return error.InvalidReplayObject;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const etag = std.fmt.bytesToHex(digest, .lower);
        const object_key = try object_keys.replay(self.allocator, source.text(), &etag);
        defer self.allocator.free(object_key);
        try self.putVerifiedObject(object_key, "application/octet-stream", data, &etag);
        var id_buf: [32]u8 = undefined;
        var bytes_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
        const bytes = try std.fmt.bufPrint(&bytes_buf, "{d}", .{data.len});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.replay_objects(source,score_id,object_key,etag,object_bytes) VALUES($1,$2,$3,$4,$5) ON CONFLICT(source,score_id) DO UPDATE SET object_key=excluded.object_key,etag=excluded.etag,object_bytes=excluded.object_bytes,stored_at=greatest(extract(epoch FROM clock_timestamp())::bigint,zigcho.replay_objects.stored_at+1)", &.{ source.text(), id, object_key, &etag, bytes });
        result.deinit();
        return true;
    }

    pub fn migrateBeatmapObjects(self: *Store) !ObjectMigrationStats {
        if (!self.object_store.enabled()) return error.ObjectStorageNotConfigured;
        var stats: ObjectMigrationStats = .{};
        var offset: i64 = 0;
        while (true) : (offset += 1) {
            var offset_buf: [32]u8 = undefined;
            const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
            const item = blk: {
                var lease = self.pool.acquire();
                defer lease.release();
                var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id,sha256,osz_file FROM zigcho.beatmap_archives ORDER BY set_id LIMIT 1 OFFSET $1::bigint", &.{offset_text});
                defer result.deinit();
                if (result.rows() == 0) break :blk null;
                const sha256 = try self.allocator.dupe(u8, result.value(0, 1));
                errdefer self.allocator.free(sha256);
                const data = try postgres.decodeBytea(self.allocator, result.value(0, 2));
                break :blk .{ .set_id = try result.int(i32, 0, 0), .sha256 = sha256, .data = data };
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
            var offset_buf: [32]u8 = undefined;
            const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
            const item = blk: {
                var lease = self.pool.acquire();
                defer lease.release();
                var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id,kind,content_type,sha256,data FROM zigcho.beatmap_media ORDER BY set_id,kind LIMIT 1 OFFSET $1::bigint", &.{offset_text});
                defer result.deinit();
                if (result.rows() == 0) break :blk null;
                const kind = media_contract.Kind.parseDb(result.value(0, 1)) orelse return error.InvalidStoredBeatmapMedia;
                const content_type = media_contract.ContentType.parse(result.value(0, 2)) orelse return error.InvalidStoredBeatmapMedia;
                const sha256 = try self.allocator.dupe(u8, result.value(0, 3));
                errdefer self.allocator.free(sha256);
                const data = try postgres.decodeBytea(self.allocator, result.value(0, 4));
                break :blk .{ .set_id = try result.int(i32, 0, 0), .kind = kind, .content_type = content_type, .sha256 = sha256, .data = data };
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

        offset = 0;
        while (true) : (offset += 1) {
            var offset_buf: [32]u8 = undefined;
            const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
            const item = blk: {
                var lease = self.pool.acquire();
                defer lease.release();
                var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT source,score_id,replay FROM (SELECT 'stable'::text source,id score_id,replay FROM zigcho.scores WHERE replay IS NOT NULL AND octet_length(replay)>0 UNION ALL SELECT 'lazer'::text source,id score_id,replay FROM zigcho.lazer_scores WHERE replay IS NOT NULL AND octet_length(replay)>0) rows ORDER BY source,score_id LIMIT 1 OFFSET $1::bigint", &.{offset_text});
                defer result.deinit();
                if (result.rows() == 0) break :blk null;
                const source: ReplaySource = if (std.mem.eql(u8, result.value(0, 0), "stable")) .stable else .lazer;
                break :blk .{ .source = source, .score_id = try result.int(i64, 0, 1), .data = try postgres.decodeBytea(self.allocator, result.value(0, 2)) };
            } orelse break;
            defer self.allocator.free(item.data);
            if (self.storeReplayObject(item.source, item.score_id, item.data)) |stored| {
                if (stored) {
                    stats.replays += 1;
                    stats.replay_bytes += @intCast(item.data.len);
                }
            } else |err| {
                stats.failed += 1;
                std.log.warn("event=replay_object_migration_failed source={s} score_id={d} error={t}", .{ item.source.text(), item.score_id, err });
            }
        }
        return stats;
    }

    pub fn purgeBeatmapObjectBackups(self: *Store) !ObjectPurgeStats {
        if (!self.object_store.enabled()) return error.ObjectStorageNotConfigured;
        const version = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.query(lease.conn, "SELECT max(version) FROM zigcho.schema_migrations");
            defer result.deinit();
            break :blk try result.int(i32, 0, 0);
        };
        if (version >= 30) return .{};
        if (version != 29) return error.UnsupportedSchemaVersion;
        const verification = try self.migrateBeatmapObjects();
        if (verification.failed != 0) return error.ObjectMigrationIncomplete;
        var lease = self.pool.acquire();
        defer lease.release();
        var before = try postgres.query(lease.conn, "SELECT count(osz_file),coalesce(sum(octet_length(osz_file)),0),(SELECT count(data) FROM zigcho.beatmap_media),(SELECT coalesce(sum(octet_length(data)),0) FROM zigcho.beatmap_media) FROM zigcho.beatmap_archives");
        defer before.deinit();
        const stats: ObjectPurgeStats = .{
            .archives = try before.int(i64, 0, 0),
            .archive_bytes = try before.int(i64, 0, 1),
            .media = try before.int(i64, 0, 2),
            .media_bytes = try before.int(i64, 0, 3),
        };
        try postgres.exec(lease.conn, database_sql.postgresMigration(30));
        self.external_only = true;
        return stats;
    }

    fn writeDirectText(writer: *std.Io.Writer, value: []const u8) !void {
        for (value) |char| try writer.writeByte(switch (char) {
            '|' => 'I',
            '\r', '\n' => ' ',
            else => char,
        });
    }

    fn appendDirectSet(self: *Store, conn: *postgres.c.PGconn, writer: *std.Io.Writer, set_id: i32) !bool {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var set_result = try postgres.queryParams(self.allocator, conn, "SELECT artist,title,creator,status,coalesce(to_char(to_timestamp(last_update) AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS'),'1970-01-01 00:00:00') FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY star_rating LIMIT 1", &.{set});
        defer set_result.deinit();
        if (set_result.rows() == 0) return false;
        try writer.print("{d}.osz|", .{set_id});
        try writeDirectText(writer, set_result.value(0, 0));
        try writer.writeByte('|');
        try writeDirectText(writer, set_result.value(0, 1));
        try writer.writeByte('|');
        try writeDirectText(writer, set_result.value(0, 2));
        try writer.print("|{d}|10.0|{s}|{d}|0|0|0|0|0|", .{ directStatus(try set_result.int(i32, 0, 3)), set_result.value(0, 4), set_id });

        var maps = try postgres.queryParams(self.allocator, conn, "SELECT star_rating,version,cs,od,ar,hp,mode FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY star_rating,id", &.{set});
        defer maps.deinit();
        for (0..maps.rows()) |row| {
            if (row != 0) try writer.writeByte(',');
            try writer.print("[{d:.2}⭐] ", .{try maps.float(f64, row, 0)});
            try writeDirectText(writer, maps.value(row, 1));
            try writer.print(" {{cs: {d} / od: {d} / ar: {d} / hp: {d}}}@{d}", .{ try maps.float(f64, row, 2), try maps.float(f64, row, 3), try maps.float(f64, row, 4), try maps.float(f64, row, 5), try maps.int(i32, row, 6) });
        }
        return true;
    }

    pub fn stableSearch(self: *Store, allocator: std.mem.Allocator, search_query: []const u8, mode: i8, direct_status: u8, page: u16) ![]u8 {
        var mode_buf: [4]u8 = undefined;
        var status_buf: [4]u8 = undefined;
        var offset_buf: [24]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const status_text = try std.fmt.bufPrint(&status_buf, "{d}", .{direct_status});
        const offset = try std.fmt.bufPrint(&offset_buf, "{d}", .{@as(u32, page) * 100});
        var lease = self.pool.acquire();
        defer lease.release();
        var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE EXISTS(SELECT 1 FROM zigcho.beatmap_archives a WHERE a.set_id=zigcho.beatmaps.set_id) AND ($1::int=-1 OR mode=$1::int) AND ($2='' OR strpos(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower($2))>0) AND (($3::int=4 AND status IN(3,4,5,6)) OR ($3::int IN(0,7) AND status IN(3,4)) OR ($3::int IN(2,5) AND status=2) OR ($3::int=3 AND status=5) OR ($3::int=8 AND status=6)) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 100 OFFSET $4", &.{ mode_text, search_query, status_text, offset });
        defer ids.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{d}", .{if (ids.rows() == 100) @as(usize, 101) else ids.rows()});
        for (0..ids.rows()) |row| {
            try output.writer.writeByte('\n');
            _ = try self.appendDirectSet(lease.conn, &output.writer, try ids.int(i32, row, 0));
        }
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn stableSearchSet(self: *Store, allocator: std.mem.Allocator, set_id: ?i32, map_id: ?i32, md5: ?[]const u8) ![]u8 {
        var set_buf: [24]u8 = undefined;
        var map_buf: [24]u8 = undefined;
        const set: ?[]const u8 = if (set_id) |value| try std.fmt.bufPrint(&set_buf, "{d}", .{value}) else null;
        const map: ?[]const u8 = if (map_id) |value| try std.fmt.bufPrint(&map_buf, "{d}", .{value}) else null;
        var lease = self.pool.acquire();
        defer lease.release();
        var found = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE ($1::int IS NOT NULL AND set_id=$1::int) OR ($2::int IS NOT NULL AND id=$2::int) OR ($3::text IS NOT NULL AND md5=$3::text) LIMIT 1", &.{ set, map, md5 });
        defer found.deinit();
        if (found.rows() == 0) return allocator.dupe(u8, "");
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        _ = try self.appendDirectSet(lease.conn, &output.writer, try found.int(i32, 0, 0));
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    fn writeBoardRow(writer: *std.Io.Writer, result: postgres.Result, row: usize, rank: i32, uses_pp: bool) !void {
        const score_value: i64 = if (uses_pp) @intFromFloat(try result.float(f64, row, 2)) else try result.int(i64, row, 2);
        try writer.print("{d}|{s}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}", .{
            try result.int(i64, row, 0),
            result.value(row, 1),
            score_value,
            try result.int(i32, row, 3),
            try result.int(i32, row, 4),
            try result.int(i32, row, 5),
            try result.int(i32, row, 6),
            try result.int(i32, row, 7),
            try result.int(i32, row, 8),
            try result.int(i32, row, 9),
            @intFromBool(try result.boolean(row, 10)),
            try result.int(i32, row, 11),
            try result.int(i32, row, 12),
            rank,
            try result.int(i64, row, 13),
            @intFromBool(try result.boolean(row, 14)),
        });
    }

    pub fn stableLeaderboard(self: *Store, allocator: std.mem.Allocator, viewer: domain.User, map_md5: []const u8, mode: u8, board_type: u8, requested_mods: i32) ![]u8 {
        var mode_buf: [4]u8 = undefined;
        var board_buf: [4]u8 = undefined;
        var mods_buf: [16]u8 = undefined;
        var viewer_buf: [24]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const board = try std.fmt.bufPrint(&board_buf, "{d}", .{board_type});
        const mods = try std.fmt.bufPrint(&mods_buf, "{d}", .{requested_mods});
        const viewer_id = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer.id});
        const namespace = stable_mods.namespace(requested_mods);
        const uses_pp = std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot");
        const filter = " FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.map_md5=$1 AND s.mode=$2 AND s.passed AND s.best AND s.rank_namespace=$3 AND ($4::int!=2 OR s.mods=$5) AND ($4::int!=3 OR s.user_id=$6 OR EXISTS(SELECT 1 FROM zigcho.friends f WHERE f.user_id=$6 AND f.friend_id=s.user_id)) AND ($4::int!=4 OR u.country=$7)";
        const params = &.{ map_md5, mode_text, namespace, board, mods, viewer_id, viewer.country[0..] };
        var lease = self.pool.acquire();
        defer lease.release();
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,status,artist,title,version FROM zigcho.beatmaps WHERE md5=$1", &.{map_md5});
        defer map.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        const writer = &output.writer;
        if (map.rows() == 0) {
            try writer.writeAll("-1|false");
            var missing = output.toArrayList();
            return missing.toOwnedSlice(allocator);
        }
        const map_id = try map.int(i32, 0, 0);
        const set_id = try map.int(i32, 0, 1);
        const status = try map.int(i32, 0, 2);
        const client_status = stableStatus(status);
        if (status < 3) {
            try writer.print("{d}|false", .{client_status});
            var unavailable = output.toArrayList();
            return unavailable.toOwnedSlice(allocator);
        }

        var count = try postgres.queryParams(self.allocator, lease.conn, "SELECT least(count(*),50)" ++ filter, params);
        defer count.deinit();
        const row_count = try count.int(i32, 0, 0);
        try writer.print("{d}|false|{d}|{d}|{d}|0|\n0\n{s} - {s} [{s}]\n0\n", .{ client_status, map_id, set_id, row_count, map.value(0, 3), map.value(0, 4), map.value(0, 5) });

        var personal = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
            "SELECT s.id,s.pp" ++ filter ++ " AND s.user_id=$6 ORDER BY s.pp DESC,s.id ASC LIMIT 1"
        else
            "SELECT s.id,s.score" ++ filter ++ " AND s.user_id=$6 ORDER BY s.score DESC,s.id ASC LIMIT 1", params);
        defer personal.deinit();
        if (personal.rows() != 0) {
            const personal_id = try personal.int(i64, 0, 0);
            var metric_buf: [64]u8 = undefined;
            var score_id_buf: [24]u8 = undefined;
            const metric = if (uses_pp)
                try std.fmt.bufPrint(&metric_buf, "{d}", .{try personal.float(f64, 0, 1)})
            else
                try std.fmt.bufPrint(&metric_buf, "{d}", .{try personal.int(i64, 0, 1)});
            const personal_id_text = try std.fmt.bufPrint(&score_id_buf, "{d}", .{personal_id});
            const rank_params = &.{ map_md5, mode_text, namespace, board, mods, viewer_id, viewer.country[0..], metric, personal_id_text };
            var personal_rank = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
                "SELECT count(*)+1" ++ filter ++ " AND (s.pp>$8 OR (s.pp=$8 AND s.id<$9))"
            else
                "SELECT count(*)+1" ++ filter ++ " AND (s.score>$8 OR (s.score=$8 AND s.id<$9))", rank_params);
            defer personal_rank.deinit();
            var personal_row = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
                "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,coalesce(octet_length(s.replay),0)>0 FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1"
            else
                "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,coalesce(octet_length(s.replay),0)>0 FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1", &.{personal_id_text});
            defer personal_row.deinit();
            if (personal_row.rows() == 0) return error.DatabaseQueryFailed;
            try writeBoardRow(writer, personal_row, 0, try personal_rank.int(i32, 0, 0), uses_pp);
        }
        try writer.writeByte('\n');
        var rows = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
            "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,coalesce(octet_length(s.replay),0)>0" ++ filter ++ " ORDER BY s.pp DESC,s.id ASC LIMIT 50"
        else
            "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,coalesce(octet_length(s.replay),0)>0" ++ filter ++ " ORDER BY s.score DESC,s.id ASC LIMIT 50", params);
        defer rows.deinit();
        for (0..rows.rows()) |row| {
            if (row != 0) try writer.writeByte('\n');
            try writeBoardRow(writer, rows, row, @intCast(row + 1), uses_pp);
        }
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    fn jsonString(writer: *std.Io.Writer, value: []const u8) !void {
        try std.json.Stringify.value(value, .{}, writer);
    }

    fn appendLazerTagFields(self: *Store, conn: *postgres.c.PGconn, writer: *std.Io.Writer, beatmap_id: i32, requester_id: ?i32) !void {
        var map_buf: [24]u8 = undefined;
        const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
        var top = try postgres.queryParams(self.allocator, conn, "SELECT tag_id,count(*) FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 GROUP BY tag_id ORDER BY count(*) DESC,tag_id LIMIT 20", &.{map});
        defer top.deinit();
        try writer.writeAll(",\"top_tag_ids\":[");
        for (0..top.rows()) |top_row| {
            if (top_row != 0) try writer.writeByte(',');
            try writer.print("{{\"tag_id\":{d},\"count\":{d}}}", .{ try top.int(i64, top_row, 0), try top.int(i64, top_row, 1) });
        }
        try writer.writeAll("],\"current_user_tag_ids\":[");
        if (requester_id) |user_id| {
            var user_buf: [24]u8 = undefined;
            const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
            var own = try postgres.queryParams(self.allocator, conn, "SELECT tag_id FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 AND user_id=$2 ORDER BY tag_id", &.{ map, user });
            defer own.deinit();
            for (0..own.rows()) |own_row| {
                if (own_row != 0) try writer.writeByte(',');
                try writer.print("{d}", .{try own.int(i64, own_row, 0)});
            }
        }
        try writer.writeByte(']');
    }

    fn appendLazerMap(self: *Store, conn: *postgres.c.PGconn, writer: *std.Io.Writer, result: postgres.Result, row: usize, requester_id: ?i32) !void {
        const creator_id = try result.int(i32, row, 20);
        try writer.print("{{\"id\":{d},\"beatmapset_id\":{d},\"status\":", .{ try result.int(i32, row, 0), try result.int(i32, row, 1) });
        try jsonString(writer, lazerStatus(try result.int(i32, row, 2)));
        try writer.writeAll(",\"checksum\":");
        try jsonString(writer, result.value(row, 3));
        try writer.print(",\"user_id\":{d},\"playcount\":{d},\"passcount\":{d},\"mode_int\":{d},\"difficulty_rating\":{d},\"drain\":{d},\"cs\":{d},\"ar\":{d},\"accuracy\":{d},\"total_length\":{d},\"hit_length\":{d},\"convert\":false,\"count_circles\":{d},\"count_sliders\":{d},\"count_spinners\":{d},\"version\":", .{ creator_id, try result.int(i64, row, 4), try result.int(i64, row, 5), try result.int(i32, row, 6), try result.float(f64, row, 7), try result.float(f64, row, 8), try result.float(f64, row, 9), try result.float(f64, row, 10), try result.float(f64, row, 11), try result.int(i32, row, 12), try result.int(i32, row, 22), try result.int(i32, row, 17), try result.int(i32, row, 18), try result.int(i32, row, 19) });
        try jsonString(writer, result.value(row, 13));
        try writer.print(",\"max_combo\":{d},\"last_updated\":", .{try result.int(i32, row, 14)});
        try jsonString(writer, result.value(row, 15));
        try writer.print(",\"bpm\":{d},\"owners\":[", .{try result.float(f64, row, 16)});
        if (creator_id > 0) {
            try writer.print("{{\"id\":{d},\"username\":", .{creator_id});
            try jsonString(writer, result.value(row, 21));
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
        try self.appendLazerTagFields(conn, writer, try result.int(i32, row, 0), requester_id);
        try writer.writeByte('}');
    }

    fn appendLazerSet(self: *Store, conn: *postgres.c.PGconn, writer: *std.Io.Writer, set_id: i32, requester_id: ?i32) !bool {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var set_result = try postgres.queryParams(self.allocator, conn, "SELECT b.set_id,min(b.artist),min(b.title),coalesce(max(owner.name),min(b.creator)),min(b.status),max(b.bpm),min(b.source),min(b.tags),coalesce(max(m.submitted_date),coalesce(to_char(to_timestamp(max(b.last_update)) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),sum(b.plays+b.upstream_plays),coalesce(max(m.favourites),0),coalesce(max(m.last_updated),coalesce(to_char(to_timestamp(max(b.last_update)) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),max(m.ranked_date),coalesce(bool_or(m.has_video),false),coalesce(max(m.genre_id),0),coalesce(max(m.language_id),0),coalesce(max(owner.id),max(b.creator_id),0) FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.set_id=$1 GROUP BY b.set_id", &.{set});
        defer set_result.deinit();
        if (set_result.rows() == 0) return false;
        try writer.print("{{\"id\":{d},\"status\":", .{set_id});
        try jsonString(writer, lazerStatus(try set_result.int(i32, 0, 4)));
        try writer.writeAll(",\"title\":");
        try jsonString(writer, set_result.value(0, 2));
        try writer.writeAll(",\"title_unicode\":");
        try jsonString(writer, set_result.value(0, 2));
        try writer.writeAll(",\"artist\":");
        try jsonString(writer, set_result.value(0, 1));
        try writer.writeAll(",\"artist_unicode\":");
        try jsonString(writer, set_result.value(0, 1));
        try writer.writeAll(",\"creator\":");
        try jsonString(writer, set_result.value(0, 3));
        const creator_id = try set_result.int(i32, 0, 16);
        try writer.print(",\"user_id\":{d},\"covers\":{{\"cover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover.jpg\",\"cover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/cover@2x.jpg\",\"card\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card.jpg\",\"card@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/card@2x.jpg\",\"list\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list.jpg\",\"list@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/list@2x.jpg\",\"slimcover\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover.jpg\",\"slimcover@2x\":\"https://assets.kai.ovh/beatmaps/{d}/covers/slimcover@2x.jpg\"}},\"preview_url\":\"https://b.kai.ovh/preview/{d}.mp3\",\"play_count\":{d},\"favourite_count\":{d},\"bpm\":{d},\"nsfw\":false,\"spotlight\":false,\"video\":{s},\"storyboard\":false,\"submitted_date\":", .{ creator_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, set_id, try set_result.int(i64, 0, 9), try set_result.int(i32, 0, 10), try set_result.float(f64, 0, 5), if (try set_result.boolean(0, 13)) "true" else "false" });
        try jsonString(writer, set_result.value(0, 8));
        try writer.writeAll(",\"last_updated\":");
        try jsonString(writer, set_result.value(0, 11));
        try writer.writeAll(",\"ranked_date\":");
        if (set_result.isNull(0, 12)) try writer.writeAll("null") else try jsonString(writer, set_result.value(0, 12));
        const genre_id = try set_result.int(i16, 0, 14);
        const language_id = try set_result.int(i16, 0, 15);
        try writer.print(",\"ratings\":[],\"availability\":{{\"download_disabled\":false,\"more_information\":\"\"}},\"genre\":{{\"id\":{d},\"name\":", .{genre_id});
        try jsonString(writer, upstream_user.genreName(genre_id));
        try writer.print("}},\"language\":{{\"id\":{d},\"name\":", .{language_id});
        try jsonString(writer, upstream_user.languageName(language_id));
        try writer.writeAll("},\"source\":");
        try jsonString(writer, set_result.value(0, 6));
        try writer.writeAll(",\"tags\":");
        try jsonString(writer, set_result.value(0, 7));
        try writer.writeAll(",\"related_tags\":");
        try writer.writeAll(lazer.beatmap_tags_array_json);
        try writer.writeAll(",\"user\":");
        var local_profile = try postgres.queryParams(self.allocator, conn, "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) FROM zigcho.beatmap_submissions submission JOIN zigcho.users u ON u.id=submission.owner_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE submission.set_id=$1 AND submission.state='published'", &.{set});
        defer local_profile.deinit();
        if (local_profile.rows() != 0) {
            const local_user = try userFromResult(self.allocator, local_profile, 0);
            defer self.allocator.free(local_user.name);
            defer self.allocator.free(local_user.safe_name);
            try user_json.writeCompact(writer, local_user);
        } else if (creator_id > 0) {
            var creator_buf: [24]u8 = undefined;
            const creator = try std.fmt.bufPrint(&creator_buf, "{d}", .{creator_id});
            var profile = try postgres.queryParams(self.allocator, conn, "SELECT profile_json::text FROM zigcho.upstream_user_profiles WHERE user_id=$1 ORDER BY mode=0 DESC,mode LIMIT 1", &.{creator});
            defer profile.deinit();
            if (profile.rows() != 0) try writer.writeAll(profile.value(0, 0)) else try writer.writeAll("null");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"beatmaps\":[");
        var maps = try postgres.queryParams(self.allocator, conn, "SELECT b.id,b.set_id,b.status,b.md5,b.plays+b.upstream_plays,b.passes+b.upstream_passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.set_id=$1 ORDER BY b.star_rating,b.id", &.{set});
        defer maps.deinit();
        for (0..maps.rows()) |row| {
            if (row != 0) try writer.writeByte(',');
            try self.appendLazerMap(conn, writer, maps, row, requester_id);
        }
        try writer.writeAll("]}");
        return true;
    }

    pub fn lazerBeatmapSet(self: *Store, allocator: std.mem.Allocator, set_id: i32, requester_id: ?i32) !?[]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        if (!try self.appendLazerSet(lease.conn, &output.writer, set_id, requester_id)) {
            output.deinit();
            return null;
        }
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn lazerBeatmapLookup(self: *Store, allocator: std.mem.Allocator, beatmap_id: ?i32, checksum: ?[]const u8, requester_id: ?i32) !?[]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var id_buf: [24]u8 = undefined;
        const value = checksum orelse try std.fmt.bufPrint(&id_buf, "{d}", .{beatmap_id orelse return null});
        const sql = if (checksum != null)
            "SELECT b.id,b.set_id,b.status,b.md5,b.plays+b.upstream_plays,b.passes+b.upstream_passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.md5=$1"
        else
            "SELECT b.id,b.set_id,b.status,b.md5,b.plays+b.upstream_plays,b.passes+b.upstream_passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.id=$1";
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{value});
        defer result.deinit();
        if (result.rows() == 0) return null;

        var map_output: std.Io.Writer.Allocating = .init(allocator);
        defer map_output.deinit();
        try self.appendLazerMap(lease.conn, &map_output.writer, result, 0, requester_id);
        const map_json = map_output.written();
        if (map_json.len == 0 or map_json[map_json.len - 1] != '}') return error.InvalidStoredBeatmap;

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll(map_json[0 .. map_json.len - 1]);
        try output.writer.writeAll(",\"beatmapset\":");
        if (!try self.appendLazerSet(lease.conn, &output.writer, try result.int(i32, 0, 1), requester_id)) return error.InvalidStoredBeatmap;
        try output.writer.writeByte('}');
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn lazerBeatmapSearch(self: *Store, allocator: std.mem.Allocator, search_query: []const u8, mode: i8, offset: u16, requester_id: ?i32) ![]u8 {
        var mode_buf: [4]u8 = undefined;
        var offset_buf: [24]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        var lease = self.pool.acquire();
        defer lease.release();
        var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT set_id FROM zigcho.beatmaps WHERE ($1::int=-1 OR mode=$1::int) AND ($2='' OR strpos(lower(artist||' '||title||' '||creator||' '||source||' '||tags),lower($2))>0) GROUP BY set_id ORDER BY max(last_update) DESC,set_id DESC LIMIT 50 OFFSET $3", &.{ mode_text, search_query, offset_text });
        defer ids.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"beatmapsets\":[");
        for (0..ids.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            _ = try self.appendLazerSet(lease.conn, &output.writer, try ids.int(i32, row, 0), requester_id);
        }
        const has_more = ids.rows() == 50;
        try output.writer.print("],\"total\":{d},\"cursor\":", .{@as(usize, offset) + ids.rows() + @intFromBool(has_more)});
        if (has_more) try output.writer.print("{{\"offset\":{d}}}", .{@as(usize, offset) + ids.rows()}) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn lazerBeatmapSets(self: *Store, allocator: std.mem.Allocator, set_ids: []const i32, offset: u16, requester_id: ?i32) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"beatmapsets\":[");
        var count: usize = 0;
        for (set_ids) |set_id| {
            var set_output: std.Io.Writer.Allocating = .init(allocator);
            defer set_output.deinit();
            if (!try self.appendLazerSet(lease.conn, &set_output.writer, set_id, requester_id)) continue;
            if (count != 0) try output.writer.writeByte(',');
            try output.writer.writeAll(set_output.written());
            count += 1;
        }
        const has_more = set_ids.len == 50 and count == set_ids.len;
        try output.writer.print("],\"total\":{d},\"cursor\":", .{@as(usize, offset) + count + @intFromBool(has_more)});
        if (has_more) try output.writer.print("{{\"offset\":{d}}}", .{@as(usize, offset) + count}) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn lazerUserBeatmapSetsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, kind: []const u8, offset: usize, limit: usize, requester_id: ?i32) ![]u8 {
        var user_buf: [24]u8 = undefined;
        var offset_buf: [24]u8 = undefined;
        var limit_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=$1 AND submission.state='published' GROUP BY submission.set_id,submission.updated_at HAVING $2='all' OR ($2='ranked' AND min(b.status) IN(3,4)) OR ($2='loved' AND min(b.status)=6) OR ($2='pending' AND min(b.status)=2) OR ($2='graveyard' AND min(b.status)=1) OR ($2='nominated' AND min(b.status)=5) ORDER BY submission.updated_at DESC,submission.set_id DESC LIMIT $3 OFFSET $4", &.{ user, kind, limit_text, offset_text });
        defer ids.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var written: usize = 0;
        for (0..ids.rows()) |row| {
            var set_output: std.Io.Writer.Allocating = .init(allocator);
            defer set_output.deinit();
            if (!try self.appendLazerSet(lease.conn, &set_output.writer, try ids.int(i32, row, 0), requester_id)) continue;
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try output.writer.writeAll(set_output.written());
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerMostPlayedJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, offset: u16, limit: u8) ![]u8 {
        var user_buf: [24]u8 = undefined;
        var offset_buf: [24]u8 = undefined;
        var limit_buf: [8]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        var rows = try postgres.queryParams(self.allocator, lease.conn, "WITH plays AS (SELECT b.id beatmap_id,count(*) plays FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 GROUP BY b.id UNION ALL SELECT beatmap_id,count(*) FROM zigcho.lazer_scores WHERE user_id=$1 GROUP BY beatmap_id), totals AS (SELECT beatmap_id,sum(plays) plays FROM plays GROUP BY beatmap_id) SELECT beatmap_id,plays FROM totals ORDER BY plays DESC,beatmap_id LIMIT $2 OFFSET $3", &.{ user, limit_text, offset_text });
        defer rows.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var written: usize = 0;
        for (0..rows.rows()) |row| {
            const beatmap_id = try rows.int(i32, row, 0);
            var map_buf: [24]u8 = undefined;
            const map_id = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
            var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,b.md5,b.plays+b.upstream_plays,b.passes+b.upstream_passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.id=$1", &.{map_id});
            defer map.deinit();
            if (map.rows() == 0) continue;
            var set: std.Io.Writer.Allocating = .init(allocator);
            defer set.deinit();
            if (!try self.appendLazerSet(lease.conn, &set.writer, try map.int(i32, 0, 1), user_id)) continue;
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try output.writer.print("{{\"beatmap_id\":{d},\"count\":{d},\"beatmap\":", .{ beatmap_id, try rows.int(i64, row, 1) });
            try self.appendLazerMap(lease.conn, &output.writer, map, 0, user_id);
            try output.writer.writeAll(",\"beatmapset\":");
            try output.writer.writeAll(set.written());
            try output.writer.writeByte('}');
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn registrationConflicts(self: *Store, name: []const u8, email: []const u8) !RegistrationConflicts {
        const safe = try domain.safeName(self.allocator, name);
        defer self.allocator.free(safe);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT EXISTS(SELECT 1 FROM zigcho.users WHERE safe_name=$1),EXISTS(SELECT 1 FROM zigcho.users WHERE email=$2)", &.{ safe, email });
        defer result.deinit();
        return .{ .username = try result.boolean(0, 0), .email = try result.boolean(0, 1) };
    }

    pub fn avatarForUser(self: *Store, user_id: i32) !?u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT avatar_key FROM zigcho.users WHERE id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const key = try result.int(u8, 0, 0);
        if (key < 1 or key > 2) return error.InvalidAvatarKey;
        return key;
    }

    pub fn customAvatarForUser(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT content_type,etag,object_key,updated_at FROM zigcho.user_avatars WHERE user_id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const content_type = try allocator.dupe(u8, result.value(0, 0));
        errdefer allocator.free(content_type);
        const etag_value = result.value(0, 1);
        if (etag_value.len != 64) return error.InvalidAvatarEtag;
        var etag: [64]u8 = undefined;
        @memcpy(&etag, etag_value);
        const object_key = try allocator.dupe(u8, result.value(0, 2));
        return .{ .allocator = allocator, .content_type = content_type, .etag = etag, .object_key = object_key, .updated_at = try result.int(i64, 0, 3) };
    }

    pub fn setCustomAvatar(self: *Store, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8) !void {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.user_avatars(user_id,object_key,content_type,etag) VALUES($1,$2,$3,$4) ON CONFLICT(user_id) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,zigcho.user_avatars.updated_at+1)", &.{ id, object_key, content_type, &etag });
        result.deinit();
    }

    pub fn deleteCustomAvatar(self: *Store, user_id: i32) !bool {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.user_avatars WHERE user_id=$1 RETURNING user_id", &.{id});
        defer result.deinit();
        return result.rows() != 0;
    }

    fn customImageFromResult(allocator: std.mem.Allocator, result: postgres.Result) !CustomAvatar {
        const content_type = try allocator.dupe(u8, result.value(0, 0));
        errdefer allocator.free(content_type);
        const etag_value = result.value(0, 1);
        if (etag_value.len != 64) return error.InvalidAvatarEtag;
        var etag: [64]u8 = undefined;
        @memcpy(&etag, etag_value);
        const object_key = try allocator.dupe(u8, result.value(0, 2));
        return .{
            .allocator = allocator,
            .content_type = content_type,
            .etag = etag,
            .object_key = object_key,
            .updated_at = try result.int(i64, 0, 3),
            .width = try result.int(u32, 0, 4),
            .height = try result.int(u32, 0, 5),
        };
    }

    pub fn customBannerForUser(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?CustomAvatar {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT content_type,etag,object_key,updated_at,width,height FROM zigcho.user_banners WHERE user_id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try customImageFromResult(allocator, result);
    }

    pub fn setCustomBanner(self: *Store, user_id: i32, object_key: []const u8, content_type: []const u8, etag: [64]u8, width: u32, height: u32) !void {
        var buffers: [3][64]u8 = undefined;
        var cursor: usize = 0;
        const id = try param(&buffers, &cursor, user_id);
        const width_text = try param(&buffers, &cursor, width);
        const height_text = try param(&buffers, &cursor, height);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.user_banners(user_id,object_key,content_type,etag,width,height) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(user_id) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,width=excluded.width,height=excluded.height,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,zigcho.user_banners.updated_at+1)", &.{ id, object_key, content_type, &etag, width_text, height_text });
        result.deinit();
    }

    pub fn deleteCustomBanner(self: *Store, user_id: i32) !bool {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.user_banners WHERE user_id=$1 RETURNING user_id", &.{id});
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn teamAsset(self: *Store, allocator: std.mem.Allocator, team_id: i32, kind: []const u8) !?CustomAvatar {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{team_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT content_type,etag,object_key,updated_at,width,height FROM zigcho.team_assets WHERE team_id=$1 AND kind=$2", &.{ id, kind });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try customImageFromResult(allocator, result);
    }

    pub fn setTeamAsset(self: *Store, team_id: i32, kind: []const u8, object_key: []const u8, content_type: []const u8, etag: [64]u8, width: u32, height: u32) !void {
        var buffers: [3][64]u8 = undefined;
        var cursor: usize = 0;
        const id = try param(&buffers, &cursor, team_id);
        const width_text = try param(&buffers, &cursor, width);
        const height_text = try param(&buffers, &cursor, height);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.team_assets(team_id,kind,object_key,content_type,etag,width,height) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(team_id,kind) DO UPDATE SET object_key=excluded.object_key,content_type=excluded.content_type,etag=excluded.etag,width=excluded.width,height=excluded.height,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,zigcho.team_assets.updated_at+1)", &.{ id, kind, object_key, content_type, &etag, width_text, height_text });
        result.deinit();
    }

    pub fn deleteTeamAsset(self: *Store, team_id: i32, kind: []const u8) !bool {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{team_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_assets WHERE team_id=$1 AND kind=$2 RETURNING team_id", &.{ id, kind });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn customAvatarUserIds(self: *Store, allocator: std.mem.Allocator) ![]i32 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT user_id FROM zigcho.user_avatars ORDER BY user_id");
        defer result.deinit();
        var ids: std.ArrayList(i32) = .empty;
        errdefer ids.deinit(allocator);
        try ids.ensureTotalCapacity(allocator, result.rows());
        for (0..result.rows()) |row| ids.appendAssumeCapacity(try result.int(i32, row, 0));
        return ids.toOwnedSlice(allocator);
    }

    pub fn updateSiteProfile(self: *Store, user_id: i32, settings: domain.SiteProfileSettings) !void {
        var id_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        var avatar_buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{settings.preferred_mode});
        const avatar = try std.fmt.bufPrint(&avatar_buf, "{d}", .{settings.avatar_key});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET bio=$1,profile_title=$2,profile_pronouns=$3,profile_location=$4,profile_website=$5,profile_accent=$6,preferred_mode=$7,profile_source=$8,avatar_key=$9,show_country=$10,show_profile_stats=$11,show_recent_scores=$12 WHERE id=$13 AND id!=3 RETURNING id", &.{ settings.bio, settings.title, settings.pronouns, settings.location, settings.website, @tagName(settings.accent), mode, @tagName(settings.profile_source), avatar, if (settings.show_country) "true" else "false", if (settings.show_profile_stats) "true" else "false", if (settings.show_recent_scores) "true" else "false", id });
        defer result.deinit();
        if (result.rows() != 1) return error.UserNotFound;
    }

    pub fn siteAccountJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,u.email,u.country,u.privileges,u.bio,u.preferred_mode,u.profile_source,u.avatar_key,EXISTS(SELECT 1 FROM zigcho.user_avatars a WHERE a.user_id=u.id),coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),0),u.created_at,coalesce(u.last_login,0),u.profile_title,u.profile_pronouns,u.profile_location,u.profile_website,u.profile_accent,u.show_country,u.show_profile_stats,u.show_recent_scores,u.username_changes,EXISTS(SELECT 1 FROM zigcho.user_banners b WHERE b.user_id=u.id),coalesce((SELECT updated_at FROM zigcho.user_banners b WHERE b.user_id=u.id),0),tm.team_id,t.name,t.short_name,(t.leader_id=u.id) FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1 AND u.id!=3", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"id\":{d},\"name\":", .{try result.int(i32, 0, 0)});
        try jsonString(&output.writer, result.value(0, 1));
        try output.writer.writeAll(",\"email\":");
        if (result.isNull(0, 2)) try output.writer.writeAll("null") else try jsonString(&output.writer, result.value(0, 2));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, result.value(0, 3));
        try output.writer.print(",\"privileges\":{d},\"bio\":", .{try result.int(u32, 0, 4)});
        try jsonString(&output.writer, result.value(0, 5));
        try output.writer.writeAll(",\"profile_source\":");
        try jsonString(&output.writer, result.value(0, 7));
        try output.writer.print(",\"preferred_mode\":{d},\"avatar_key\":{d},\"has_custom_avatar\":{},\"avatar_version\":{d},\"created_at\":{d},\"last_login\":{d},\"profile_title\":", .{ try result.int(u8, 0, 6), try result.int(u8, 0, 8), try result.boolean(0, 9), try result.int(i64, 0, 10), try result.int(i64, 0, 11), try result.int(i64, 0, 12) });
        try jsonString(&output.writer, result.value(0, 13));
        try output.writer.writeAll(",\"profile_pronouns\":");
        try jsonString(&output.writer, result.value(0, 14));
        try output.writer.writeAll(",\"profile_location\":");
        try jsonString(&output.writer, result.value(0, 15));
        try output.writer.writeAll(",\"profile_website\":");
        try jsonString(&output.writer, result.value(0, 16));
        try output.writer.writeAll(",\"profile_accent\":");
        try jsonString(&output.writer, result.value(0, 17));
        const changes = try result.int(i32, 0, 21);
        const privileges = try result.int(u32, 0, 4);
        try output.writer.print(",\"show_country\":{},\"show_profile_stats\":{},\"show_recent_scores\":{},\"username_changes\":{d},\"username_change_free\":{},\"username_change_allowed\":{},\"has_custom_banner\":{},\"banner_version\":{d},\"team\":", .{ try result.boolean(0, 18), try result.boolean(0, 19), try result.boolean(0, 20), changes, changes == 0, changes == 0 or (privileges & (1 << 5)) != 0, try result.boolean(0, 22), try result.int(i64, 0, 23) });
        if (result.isNull(0, 24)) {
            try output.writer.writeAll("null");
        } else {
            try output.writer.print("{{\"id\":{d},\"name\":", .{try result.int(i32, 0, 24)});
            try jsonString(&output.writer, result.value(0, 25));
            try output.writer.writeAll(",\"short_name\":");
            try jsonString(&output.writer, result.value(0, 26));
            try output.writer.print(",\"leader\":{}}}", .{try result.boolean(0, 27)});
        }
        try output.writer.writeByte('}');
        var list = output.toArrayList();
        return @as(?[]u8, try list.toOwnedSlice(allocator));
    }

    pub fn updateAccountEmail(self: *Store, user_id: i32, email: []const u8) !void {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET email=$1 WHERE id=$2 AND id!=3 RETURNING id", &.{ email, id }) catch |err| switch (err) {
            error.UniqueViolation => return error.EmailExists,
            else => return err,
        };
        defer result.deinit();
        if (result.rows() != 1) return error.UserNotFound;
        try insertAudit(self.allocator, lease.conn, user_id, "account.email", user_id, "email changed");
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn updateAccountPassword(self: *Store, user_id: i32, password_md5: []const u8) !void {
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
        const hash_bytea = try postgres.encodeBytea(self.allocator, hash);
        defer self.allocator.free(hash_bytea);
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET password_hash=$1,password_salt=convert_to('argon2id','UTF8') WHERE id=$2 AND id!=3 RETURNING id", &.{ hash_bytea, id });
        defer result.deinit();
        if (result.rows() != 1) return error.UserNotFound;
        try insertAudit(self.allocator, lease.conn, user_id, "account.password", user_id, "password changed");
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn updateAccountUsername(self: *Store, user_id: i32, new_name: []const u8) !void {
        const safe = try domain.safeName(self.allocator, new_name);
        defer self.allocator.free(safe);
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var current = try postgres.queryParams(self.allocator, lease.conn, "SELECT name,username_changes,privileges FROM zigcho.users WHERE id=$1 AND id!=3 FOR UPDATE", &.{id});
        defer current.deinit();
        if (current.rows() != 1) return error.UserNotFound;
        if (try current.int(i32, 0, 1) != 0 and (try current.int(u32, 0, 2)) & (1 << 5) == 0) return error.PremiumRequired;
        var update = postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET name=$1,safe_name=$2,username_changes=username_changes+1,username_changed_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$3 RETURNING id", &.{ new_name, safe, id }) catch |err| switch (err) {
            error.UniqueViolation => return error.UsernameExists,
            else => return err,
        };
        defer update.deinit();
        var history = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.user_name_changes(user_id,old_name,new_name) VALUES($1,$2,$3)", &.{ id, current.value(0, 0), new_name });
        history.deinit();
        try insertAudit(self.allocator, lease.conn, user_id, "account.username", user_id, "username changed");
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn revokeAllTokensForUser(self: *Store, user_id: i32) !usize {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL RETURNING 1", &.{id});
        defer result.deinit();
        return result.rows();
    }

    pub fn teamsJson(self: *Store, allocator: std.mem.Allocator, requester_id: ?i32) ![]u8 {
        var requester_buf: [24]u8 = undefined;
        const requester = if (requester_id) |id| try std.fmt.bufPrint(&requester_buf, "{d}", .{id}) else null;
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT t.id,t.name,t.short_name,t.description,t.is_open,t.default_ruleset_id,t.leader_id,t.created_at,t.updated_at,(SELECT count(*) FROM zigcho.team_members m WHERE m.team_id=t.id),coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0),EXISTS(SELECT 1 FROM zigcho.team_members m WHERE m.team_id=t.id AND m.user_id=$1),EXISTS(SELECT 1 FROM zigcho.team_applications a WHERE a.team_id=t.id AND a.user_id=$1) FROM zigcho.teams t ORDER BY (SELECT count(*) FROM zigcho.team_members m WHERE m.team_id=t.id) DESC,lower(t.name),t.id", &.{requester});
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            const team_id = try result.int(i32, row, 0);
            const flag_version = try result.int(i64, row, 10);
            try output.writer.print("{{\"id\":{d},\"name\":", .{team_id});
            try jsonString(&output.writer, result.value(row, 1));
            try output.writer.writeAll(",\"short_name\":");
            try jsonString(&output.writer, result.value(row, 2));
            try output.writer.writeAll(",\"description\":");
            try jsonString(&output.writer, result.value(row, 3));
            try output.writer.print(",\"is_open\":{},\"default_ruleset_id\":{d},\"leader_id\":{d},\"created_at\":{d},\"updated_at\":{d},\"member_count\":{d},\"flag_url\":", .{ try result.boolean(row, 4), try result.int(u8, row, 5), try result.int(i32, row, 6), try result.int(i64, row, 7), try result.int(i64, row, 8), try result.int(i32, row, 9) });
            if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ team_id, flag_version }) else try output.writer.writeAll("null");
            try output.writer.print(",\"member\":{},\"applied\":{}}}", .{ try result.boolean(row, 11), try result.boolean(row, 12) });
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn teamJson(self: *Store, allocator: std.mem.Allocator, team_id: i32, requester_id: ?i32, staff: bool) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        var requester_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{team_id});
        const requester = if (requester_id) |value| try std.fmt.bufPrint(&requester_buf, "{d}", .{value}) else null;
        var lease = self.pool.acquire();
        defer lease.release();
        var team = try postgres.queryParams(allocator, lease.conn, "SELECT t.id,t.name,t.short_name,t.url,t.description,t.is_open,t.default_ruleset_id,t.leader_id,t.created_at,t.updated_at,coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0),coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='header'),0),EXISTS(SELECT 1 FROM zigcho.team_members m WHERE m.team_id=t.id AND m.user_id=$2),EXISTS(SELECT 1 FROM zigcho.team_applications a WHERE a.team_id=t.id AND a.user_id=$2) FROM zigcho.teams t WHERE t.id=$1", &.{ id, requester });
        defer team.deinit();
        if (team.rows() == 0) return null;
        const leader_id = try team.int(i32, 0, 7);
        const can_manage = staff or (requester_id != null and requester_id.? == leader_id);
        var members = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,m.joined_at FROM zigcho.team_members m JOIN zigcho.users u ON u.id=m.user_id WHERE m.team_id=$1 ORDER BY CASE WHEN u.id=(SELECT leader_id FROM zigcho.teams WHERE id=$1) THEN 0 ELSE 1 END,m.joined_at,u.id", &.{id});
        defer members.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"id\":{d},\"name\":", .{team_id});
        try jsonString(&output.writer, team.value(0, 1));
        try output.writer.writeAll(",\"short_name\":");
        try jsonString(&output.writer, team.value(0, 2));
        try output.writer.writeAll(",\"url\":");
        try jsonString(&output.writer, team.value(0, 3));
        try output.writer.writeAll(",\"description\":");
        try jsonString(&output.writer, team.value(0, 4));
        const flag_version = try team.int(i64, 0, 10);
        const header_version = try team.int(i64, 0, 11);
        try output.writer.print(",\"is_open\":{},\"default_ruleset_id\":{d},\"leader_id\":{d},\"created_at\":{d},\"updated_at\":{d},\"flag_url\":", .{ try team.boolean(0, 5), try team.int(u8, 0, 6), leader_id, try team.int(i64, 0, 8), try team.int(i64, 0, 9) });
        if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ team_id, flag_version }) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"header_url\":");
        if (header_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/header?v={d}\"", .{ team_id, header_version }) else try output.writer.writeAll("null");
        try output.writer.print(",\"member\":{},\"applied\":{},\"can_manage\":{},\"members\":[", .{ try team.boolean(0, 12), try team.boolean(0, 13), can_manage });
        for (0..members.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            const member_id = try members.int(i32, row, 0);
            try output.writer.print("{{\"id\":{d},\"name\":", .{member_id});
            try jsonString(&output.writer, members.value(row, 1));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, members.value(row, 2));
            try output.writer.print(",\"privileges\":{d},\"joined_at\":{d},\"leader\":{}}}", .{ try members.int(u32, row, 3), try members.int(i64, row, 4), member_id == leader_id });
        }
        try output.writer.writeAll("],\"applications\":[");
        if (can_manage) {
            var applications = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,u.country,a.created_at FROM zigcho.team_applications a JOIN zigcho.users u ON u.id=a.user_id WHERE a.team_id=$1 ORDER BY a.created_at,u.id", &.{id});
            defer applications.deinit();
            for (0..applications.rows()) |row| {
                if (row != 0) try output.writer.writeByte(',');
                try output.writer.print("{{\"id\":{d},\"name\":", .{try applications.int(i32, row, 0)});
                try jsonString(&output.writer, applications.value(row, 1));
                try output.writer.writeAll(",\"country\":");
                try jsonString(&output.writer, applications.value(row, 2));
                try output.writer.print(",\"created_at\":{d}}}", .{try applications.int(i64, row, 3)});
            }
        }
        try output.writer.writeAll("]}");
        return @as(?[]u8, try output.toOwnedSlice());
    }

    pub fn createTeam(self: *Store, user_id: i32, settings: domain.TeamSettings) !i32 {
        var buffers: [4][24]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const is_open = if (settings.is_open) "true" else "false";
        const ruleset = try param(&buffers, &cursor, settings.default_ruleset_id);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var insert = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.teams(name,short_name,url,description,is_open,default_ruleset_id,leader_id) SELECT $1,$2,$3,$4,$5,$6,$7 WHERE NOT EXISTS(SELECT 1 FROM zigcho.team_members WHERE user_id=$7) RETURNING id", &.{ settings.name, settings.short_name, settings.url, settings.description, is_open, ruleset, user }) catch |err| switch (err) {
            error.UniqueViolation => return error.TeamExists,
            else => return err,
        };
        defer insert.deinit();
        if (insert.rows() != 1) return error.AlreadyInTeam;
        const team_id = try insert.int(i32, 0, 0);
        const team = try param(&buffers, &cursor, team_id);
        var member = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.team_members(user_id,team_id) VALUES($1,$2)", &.{ user, team });
        member.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_applications WHERE user_id=$1", &.{user});
        clear.deinit();
        try insertAudit(self.allocator, lease.conn, user_id, "team.create", user_id, "team created");
        try postgres.exec(lease.conn, "COMMIT");
        return team_id;
    }

    pub fn updateTeam(self: *Store, actor_id: i32, team_id: i32, settings: domain.TeamSettings, staff: bool) !void {
        var buffers: [4][24]u8 = undefined;
        var cursor: usize = 0;
        const actor = try param(&buffers, &cursor, actor_id);
        const team = try param(&buffers, &cursor, team_id);
        const ruleset = try param(&buffers, &cursor, settings.default_ruleset_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.teams SET name=$1,short_name=$2,url=$3,description=$4,is_open=$5,default_ruleset_id=$6,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,updated_at+1) WHERE id=$7 AND (leader_id=$8 OR $9::boolean) RETURNING id", &.{ settings.name, settings.short_name, settings.url, settings.description, if (settings.is_open) "true" else "false", ruleset, team, actor, if (staff) "true" else "false" }) catch |err| switch (err) {
            error.UniqueViolation => return error.TeamExists,
            else => return err,
        };
        defer result.deinit();
        if (result.rows() != 1) return error.TeamPermissionDenied;
    }

    pub fn joinOrApplyTeam(self: *Store, user_id: i32, team_id: i32) !domain.TeamJoinResult {
        var buffers: [2][24]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const team = try param(&buffers, &cursor, team_id);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var found = try postgres.queryParams(self.allocator, lease.conn, "SELECT is_open FROM zigcho.teams WHERE id=$1 FOR UPDATE", &.{team});
        defer found.deinit();
        if (found.rows() != 1) return error.TeamNotFound;
        const team_open = try found.boolean(0, 0);
        var result = postgres.queryParams(self.allocator, lease.conn, if (team_open) "INSERT INTO zigcho.team_members(user_id,team_id) VALUES($1,$2)" else "INSERT INTO zigcho.team_applications(user_id,team_id) VALUES($1,$2)", &.{ user, team }) catch |err| switch (err) {
            error.UniqueViolation => return if (team_open) error.AlreadyInTeam else error.AlreadyApplied,
            else => return err,
        };
        result.deinit();
        if (team_open) {
            var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_applications WHERE user_id=$1", &.{user});
            clear.deinit();
        }
        try postgres.exec(lease.conn, "COMMIT");
        return if (team_open) .joined else .applied;
    }

    pub fn leaveTeam(self: *Store, user_id: i32, team_id: i32) !void {
        var buffers: [2][24]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const team = try param(&buffers, &cursor, team_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_members WHERE user_id=$1 AND team_id=$2 AND user_id!=(SELECT leader_id FROM zigcho.teams WHERE id=$2) RETURNING user_id", &.{ user, team });
        defer result.deinit();
        if (result.rows() != 1) return error.TeamLeaderCannotLeave;
    }

    pub fn teamMemberAction(self: *Store, actor_id: i32, team_id: i32, target_id: i32, action: []const u8, staff: bool) !void {
        var buffers: [3][24]u8 = undefined;
        var cursor: usize = 0;
        const actor = try param(&buffers, &cursor, actor_id);
        const team = try param(&buffers, &cursor, team_id);
        const target = try param(&buffers, &cursor, target_id);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var auth = try postgres.queryParams(self.allocator, lease.conn, "SELECT leader_id FROM zigcho.teams WHERE id=$1 AND (leader_id=$2 OR $3::boolean) FOR UPDATE", &.{ team, actor, if (staff) "true" else "false" });
        defer auth.deinit();
        if (auth.rows() != 1) return error.TeamPermissionDenied;
        const leader_id = try auth.int(i32, 0, 0);
        if (std.mem.eql(u8, action, "approve")) {
            var result = postgres.queryParams(self.allocator, lease.conn, "WITH moved AS (DELETE FROM zigcho.team_applications WHERE user_id=$1 AND team_id=$2 RETURNING user_id,team_id) INSERT INTO zigcho.team_members(user_id,team_id) SELECT user_id,team_id FROM moved RETURNING user_id", &.{ target, team }) catch |err| switch (err) {
                error.UniqueViolation => return error.AlreadyInTeam,
                else => return err,
            };
            defer result.deinit();
            if (result.rows() != 1) return error.TeamApplicationNotFound;
        } else if (std.mem.eql(u8, action, "reject")) {
            var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_applications WHERE user_id=$1 AND team_id=$2 RETURNING user_id", &.{ target, team });
            defer result.deinit();
            if (result.rows() != 1) return error.TeamApplicationNotFound;
        } else if (std.mem.eql(u8, action, "remove")) {
            if (target_id == leader_id) return error.TeamLeaderCannotLeave;
            var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.team_members WHERE user_id=$1 AND team_id=$2 RETURNING user_id", &.{ target, team });
            defer result.deinit();
            if (result.rows() != 1) return error.TeamMemberNotFound;
        } else if (std.mem.eql(u8, action, "transfer")) {
            if (!staff and actor_id != leader_id) return error.TeamPermissionDenied;
            var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.teams SET leader_id=$1,updated_at=greatest(extract(epoch FROM clock_timestamp())::bigint,updated_at+1) WHERE id=$2 AND EXISTS(SELECT 1 FROM zigcho.team_members WHERE team_id=$2 AND user_id=$1) RETURNING id", &.{ target, team });
            defer result.deinit();
            if (result.rows() != 1) return error.TeamMemberNotFound;
        } else return error.InvalidTeamAction;
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn disbandTeam(self: *Store, actor_id: i32, team_id: i32, staff: bool) !void {
        var buffers: [2][24]u8 = undefined;
        var cursor: usize = 0;
        const actor = try param(&buffers, &cursor, actor_id);
        const team = try param(&buffers, &cursor, team_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.teams WHERE id=$1 AND (leader_id=$2 OR $3::boolean) RETURNING id", &.{ team, actor, if (staff) "true" else "false" });
        defer result.deinit();
        if (result.rows() != 1) return error.TeamPermissionDenied;
    }

    pub fn teamCanManage(self: *Store, actor_id: i32, team_id: i32, staff: bool) !bool {
        var buffers: [2][24]u8 = undefined;
        var cursor: usize = 0;
        const actor = try param(&buffers, &cursor, actor_id);
        const team = try param(&buffers, &cursor, team_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.teams WHERE id=$1 AND (leader_id=$2 OR $3::boolean)", &.{ team, actor, if (staff) "true" else "false" });
        defer result.deinit();
        return result.rows() != 0;
    }

    fn credentialForSafeName(self: *Store, allocator: std.mem.Allocator, safe: []const u8) !?Credential {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.password_hash,u.password_salt FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.safe_name=$1", &.{safe});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const user = try userFromResult(allocator, result, 0);
        errdefer {
            allocator.free(user.name);
            allocator.free(user.safe_name);
        }
        const password_hash = try postgres.decodeBytea(allocator, result.value(0, 12));
        errdefer allocator.free(password_hash);
        const password_salt = try postgres.decodeBytea(allocator, result.value(0, 13));
        return .{ .allocator = allocator, .user = user, .password_hash = password_hash, .password_salt = password_salt };
    }

    pub fn authenticate(self: *Store, allocator: std.mem.Allocator, name: []const u8, password_md5: []const u8) !?domain.User {
        const safe = try domain.safeName(allocator, name);
        defer allocator.free(safe);
        var credential = (try self.credentialForSafeName(allocator, safe)) orelse return null;
        defer credential.deinit();
        var upgrade = false;
        if (credential.password_hash.len > 0 and credential.password_hash[0] == '$') {
            std.crypto.pwhash.argon2.strVerify(credential.password_hash, password_md5, .{ .allocator = allocator }, self.io) catch return null;
        } else {
            var actual: [32]u8 = undefined;
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(credential.password_salt);
            hash.update(password_md5);
            hash.final(&actual);
            if (credential.password_hash.len != 32 or !std.crypto.timing_safe.eql([32]u8, actual, credential.password_hash[0..32].*)) return null;
            upgrade = true;
        }
        const user_id = credential.user.?.id;
        if (upgrade) try self.upgradePassword(user_id, password_md5, credential.password_hash);
        return credential.takeUser();
    }

    fn upgradePassword(self: *Store, user_id: i32, password_md5: []const u8, previous_hash: []const u8) !void {
        var hash_buffer: [256]u8 = undefined;
        const hash = try std.crypto.pwhash.argon2.strHash(password_md5, .{ .allocator = self.allocator, .params = .owasp_2id }, &hash_buffer, self.io);
        const hash_bytea = try postgres.encodeBytea(self.allocator, hash);
        defer self.allocator.free(hash_bytea);
        const salt_bytea = try postgres.encodeBytea(self.allocator, "argon2id");
        defer self.allocator.free(salt_bytea);
        const previous_bytea = try postgres.encodeBytea(self.allocator, previous_hash);
        defer self.allocator.free(previous_bytea);
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET password_hash=$1,password_salt=$2 WHERE id=$3 AND password_hash=$4", &.{ hash_bytea, salt_bytea, id, previous_bytea });
        result.deinit();
    }

    pub fn userById(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?domain.User {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try userFromResult(allocator, result, 0);
    }

    pub fn userByName(self: *Store, allocator: std.mem.Allocator, name: []const u8) !?domain.User {
        const safe = try domain.safeName(allocator, name);
        defer allocator.free(safe);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.safe_name=$1", &.{safe});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try userFromResult(allocator, result, 0);
    }

    pub fn friendIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT friend_id FROM zigcho.friends WHERE user_id=$1 ORDER BY friend_id LIMIT 1000", &.{id});
        defer result.deinit();
        var list: std.ArrayList(i32) = .empty;
        errdefer list.deinit(allocator);
        for (0..result.rows()) |row| try list.append(allocator, try result.int(i32, row, 0));
        if (user_id != 3 and std.mem.indexOfScalar(i32, list.items, 3) == null) try list.append(allocator, 3);
        return list.toOwnedSlice(allocator);
    }

    pub fn addFriend(self: *Store, user_id: i32, friend_id: i32) !bool {
        if (user_id == friend_id or friend_id == 3) return false;
        var user_buf: [24]u8 = undefined;
        var friend_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const friend = try std.fmt.bufPrint(&friend_buf, "{d}", .{friend_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.friends(user_id,friend_id) VALUES($1,$2) ON CONFLICT DO NOTHING RETURNING 1", &.{ user, friend });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn removeFriend(self: *Store, user_id: i32, friend_id: i32) !bool {
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

    pub fn friendsAreMutual(self: *Store, user_id: i32, friend_id: i32) !bool {
        var user_buf: [24]u8 = undefined;
        var friend_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const friend = try std.fmt.bufPrint(&friend_buf, "{d}", .{friend_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT EXISTS(SELECT 1 FROM zigcho.friends WHERE user_id=$1 AND friend_id=$2)::int", &.{ friend, user });
        defer result.deinit();
        return try result.int(i32, 0, 0) != 0;
    }

    pub fn blockIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
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

    pub fn addBlock(self: *Store, user_id: i32, blocked_id: i32) !bool {
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

    pub fn removeBlock(self: *Store, user_id: i32, blocked_id: i32) !bool {
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

    pub fn favouriteSetIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT set_id FROM zigcho.favourites WHERE user_id=$1 ORDER BY created_at,set_id LIMIT 10000", &.{id});
        defer result.deinit();
        var list: std.ArrayList(i32) = .empty;
        errdefer list.deinit(allocator);
        for (0..result.rows()) |row| try list.append(allocator, try result.int(i32, row, 0));
        return list.toOwnedSlice(allocator);
    }

    pub fn addFavourite(self: *Store, user_id: i32, set_id: i32) !bool {
        if (set_id <= 0) return error.InvalidBeatmapSet;
        var user_buf: [24]u8 = undefined;
        var set_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.favourites(user_id,set_id) VALUES($1,$2) ON CONFLICT DO NOTHING RETURNING 1", &.{ user, set });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn removeFavourite(self: *Store, user_id: i32, set_id: i32) !bool {
        if (set_id <= 0) return error.InvalidBeatmapSet;
        var user_buf: [24]u8 = undefined;
        var set_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.favourites WHERE user_id=$1 AND set_id=$2 RETURNING 1", &.{ user, set });
        defer result.deinit();
        return result.rows() != 0;
    }

    fn stableBeatmapInfo(self: *Store, user_id: i32, field: []const u8, by_id: bool) !?StableBeatmapInfo {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        const sql = if (by_id)
            "SELECT id,set_id,md5,status FROM zigcho.beatmaps WHERE id=CAST($1 AS integer)"
        else
            "SELECT id,set_id,md5,status FROM zigcho.beatmaps WHERE artist || ' - ' || title || ' (' || creator || ') [' || version || '].osu'=$1";
        var map = try postgres.queryParams(self.allocator, lease.conn, sql, &.{field});
        defer map.deinit();
        if (map.rows() == 0) return null;
        const md5_text = map.value(0, 2);
        if (md5_text.len != 32) return error.InvalidBeatmapChecksum;
        const db_status = try map.int(i32, 0, 3);
        var info: StableBeatmapInfo = .{
            .id = try map.int(i32, 0, 0),
            .set_id = try map.int(i32, 0, 1),
            .md5 = undefined,
            .status = switch (stableStatus(db_status)) {
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
        var scores = try postgres.queryParams(self.allocator, lease.conn, "SELECT mode,mods,accuracy,n300,n100,n50,nmiss FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND rank_namespace='vanilla' AND passed AND best AND mode BETWEEN 0 AND 3", &.{ user, md5_text });
        defer scores.deinit();
        for (0..scores.rows()) |row| {
            const mode = try scores.int(u8, row, 0);
            info.grades[mode] = sqlite_storage.Store.stableGrade(mode, try scores.int(i32, row, 1), try scores.float(f64, row, 2), try scores.int(i32, row, 3), try scores.int(i32, row, 4), try scores.int(i32, row, 5), try scores.int(i32, row, 6));
        }
        return info;
    }

    pub fn stableBeatmapInfoByFilename(self: *Store, user_id: i32, filename: []const u8) !?StableBeatmapInfo {
        return self.stableBeatmapInfo(user_id, filename, false);
    }

    pub fn stableBeatmapInfoById(self: *Store, user_id: i32, map_id: i32) !?StableBeatmapInfo {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
        return self.stableBeatmapInfo(user_id, id, true);
    }

    pub fn addBeatmapComment(self: *Store, user_id: i32, target_type: []const u8, target_id: i64, time: f64, comment: []const u8, colour: ?[]const u8) !void {
        var user_buf: [24]u8 = undefined;
        var target_buf: [32]u8 = undefined;
        var time_buf: [64]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
        const time_text = try std.fmt.bufPrint(&time_buf, "{d}", .{time});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = if (colour) |value|
            try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_comments(target_id,target_type,user_id,time,comment,colour) VALUES($1,$2,$3,$4,$5,$6)", &.{ target, target_type, user, time_text, comment, value })
        else
            try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_comments(target_id,target_type,user_id,time,comment) VALUES($1,$2,$3,$4,$5)", &.{ target, target_type, user, time_text, comment });
        result.deinit();
    }

    pub fn beatmapComments(self: *Store, allocator: std.mem.Allocator, score_id: i64, set_id: i32, map_id: i32) ![]u8 {
        var score_buf: [32]u8 = undefined;
        var set_buf: [24]u8 = undefined;
        var map_buf: [24]u8 = undefined;
        const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const map_id_text = try std.fmt.bufPrint(&map_buf, "{d}", .{map_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT c.time,c.target_type,u.privileges,c.colour,c.comment FROM zigcho.beatmap_comments c JOIN zigcho.users u ON u.id=c.user_id WHERE (c.target_type='replay' AND c.target_id=$1) OR (c.target_type='song' AND c.target_id=$2) OR (c.target_type='map' AND c.target_id=$3) ORDER BY c.id LIMIT 1000", &.{ score, set, map_id_text });
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte('\n');
            const privileges = try result.int(u32, row, 2);
            const format = if (privileges & (1 << 11) != 0) "bat" else if (privileges & (1 << 4) != 0) "supporter" else "";
            try output.writer.print("{d}\t{s}\t{s}", .{ try result.float(f64, row, 0), result.value(row, 1), format });
            if (!result.isNull(row, 3)) try output.writer.print("|{s}", .{result.value(row, 3)});
            try output.writer.print("\t{s}", .{result.value(row, 4)});
        }
        return output.toOwnedSlice();
    }

    pub fn addLazerComment(self: *Store, user_id: i32, target: LazerCommentTarget, parent_id: ?i64, message: []const u8) !i64 {
        if (message.len == 0 or message.len > 1000 or !std.unicode.utf8ValidateSlice(message)) return error.InvalidComment;
        var user_buf: [24]u8 = undefined;
        var target_buf: [32]u8 = undefined;
        var parent_buf: [32]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const target_id = try std.fmt.bufPrint(&target_buf, "{d}", .{target.id});
        const parent = if (parent_id) |value| try std.fmt.bufPrint(&parent_buf, "{d}", .{value}) else null;
        var lease = self.pool.acquire();
        defer lease.release();
        if (parent) |parent_text| {
            var check = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.lazer_comments WHERE id=$1 AND commentable_type=$2 AND commentable_id=$3 AND deleted_at IS NULL", &.{ parent_text, target.commentable.text(), target_id });
            defer check.deinit();
            if (check.rows() == 0) return error.CommentParentNotFound;
        }
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_comments(commentable_type,commentable_id,user_id,parent_id,message) VALUES($1,$2,$3,$4,$5) RETURNING id", &.{ target.commentable.text(), target_id, user, parent, message });
        defer result.deinit();
        return try result.int(i64, 0, 0);
    }

    pub fn lazerCommentTarget(self: *Store, comment_id: i64) !?LazerCommentTarget {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{comment_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT commentable_type,commentable_id FROM zigcho.lazer_comments WHERE id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .commentable = LazerCommentable.parse(result.value(0, 0)) orelse return error.InvalidStoredComment, .id = try result.int(i64, 0, 1) };
    }

    pub fn deleteLazerComment(self: *Store, user_id: i32, comment_id: i64, staff: bool) !bool {
        var user_buf: [24]u8 = undefined;
        var id_buf: [32]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{comment_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, if (staff)
            "UPDATE zigcho.lazer_comments SET message='',deleted_at=extract(epoch FROM clock_timestamp())::bigint,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$1 AND deleted_at IS NULL RETURNING 1"
        else
            "UPDATE zigcho.lazer_comments SET message='',deleted_at=extract(epoch FROM clock_timestamp())::bigint,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL RETURNING 1", if (staff) &.{id} else &.{ id, user });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn setLazerCommentVote(self: *Store, user_id: i32, comment_id: i64, voted: bool) !bool {
        var user_buf: [24]u8 = undefined;
        var id_buf: [32]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{comment_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, if (voted)
            "INSERT INTO zigcho.lazer_comment_votes(comment_id,user_id) SELECT $1,$2 WHERE EXISTS(SELECT 1 FROM zigcho.lazer_comments WHERE id=$1 AND deleted_at IS NULL) ON CONFLICT DO NOTHING RETURNING 1"
        else
            "DELETE FROM zigcho.lazer_comment_votes WHERE comment_id=$1 AND user_id=$2 RETURNING 1", &.{ id, user });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn reportLazerComment(self: *Store, user_id: i32, comment_id: i64, reason: []const u8, comments: []const u8) !bool {
        var user_buf: [24]u8 = undefined;
        var id_buf: [32]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{comment_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_comment_reports(comment_id,reporter_id,reason,comments) SELECT $1,$2,$3,$4 WHERE EXISTS(SELECT 1 FROM zigcho.lazer_comments WHERE id=$1) ON CONFLICT DO NOTHING RETURNING 1", &.{ id, user, reason, comments });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn addLazerReport(self: *Store, reporter_id: i32, reportable_type: []const u8, reportable_id: i64, reason: []const u8, comments: []const u8) !bool {
        var reporter_buf: [24]u8 = undefined;
        var target_buf: [24]u8 = undefined;
        const reporter = try std.fmt.bufPrint(&reporter_buf, "{d}", .{reporter_id});
        const target = try std.fmt.bufPrint(&target_buf, "{d}", .{reportable_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_reports(reporter_id,reportable_type,reportable_id,reason,comments) VALUES($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING RETURNING id", &.{ reporter, reportable_type, target, reason, comments });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn lazerMessageExists(self: *Store, message_id: i64) !bool {
        if (message_id <= 0) return false;
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{message_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT EXISTS(SELECT 1 FROM zigcho.chat_messages WHERE id=$1) OR EXISTS(SELECT 1 FROM zigcho.direct_messages WHERE id=$1)", &.{id});
        defer result.deinit();
        return try result.boolean(0, 0);
    }

    pub fn staffLazerReportsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT r.id,r.reporter_id,reporter.name,reporter.country,r.reportable_type,r.reportable_id," ++
            "CASE r.reportable_type WHEN 'user' THEN coalesce((SELECT name FROM zigcho.users WHERE id=r.reportable_id::integer),'missing user') " ++
            "WHEN 'message' THEN left(coalesce((SELECT message FROM zigcho.chat_messages WHERE id=r.reportable_id),(SELECT message FROM zigcho.direct_messages WHERE id=r.reportable_id),'missing message'),180) " ++
            "ELSE left(coalesce((SELECT message FROM zigcho.lazer_comments WHERE id=r.reportable_id),'missing comment'),180) END," ++
            "r.reason,r.comments,r.status,r.created_at,coalesce(r.resolved_at,0),coalesce(resolver.name,'') " ++
            "FROM zigcho.lazer_reports r JOIN zigcho.users reporter ON reporter.id=r.reporter_id LEFT JOIN zigcho.users resolver ON resolver.id=r.resolver_id " ++
            "ORDER BY CASE r.status WHEN 'open' THEN 0 ELSE 1 END,r.created_at DESC,r.id DESC LIMIT 300");
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"reports\":[");
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"reporter_id\":{d},\"reporter\":", .{ try result.int(i64, row, 0), try result.int(i32, row, 1) });
            try jsonString(&output.writer, result.value(row, 2));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, result.value(row, 3));
            try output.writer.writeAll(",\"reportable_type\":");
            try jsonString(&output.writer, result.value(row, 4));
            try output.writer.print(",\"reportable_id\":{d},\"target\":", .{try result.int(i64, row, 5)});
            try jsonString(&output.writer, result.value(row, 6));
            try output.writer.writeAll(",\"reason\":");
            try jsonString(&output.writer, result.value(row, 7));
            try output.writer.writeAll(",\"comments\":");
            try jsonString(&output.writer, result.value(row, 8));
            try output.writer.writeAll(",\"status\":");
            try jsonString(&output.writer, result.value(row, 9));
            try output.writer.print(",\"created_at\":{d},\"resolved_at\":{d},\"resolver\":", .{ try result.int(i64, row, 10), try result.int(i64, row, 11) });
            try jsonString(&output.writer, result.value(row, 12));
            try output.writer.writeByte('}');
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn resolveLazerReport(self: *Store, actor_id: i32, report_id: i64, decision: []const u8) !bool {
        if (!std.mem.eql(u8, decision, "resolved") and !std.mem.eql(u8, decision, "dismissed")) return error.InvalidReportDecision;
        var actor_buf: [24]u8 = undefined;
        var id_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{report_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.lazer_reports SET status=$1,resolved_at=extract(epoch FROM clock_timestamp())::bigint,resolver_id=$2 WHERE id=$3 AND status='open' RETURNING reporter_id", &.{ decision, actor, id });
        defer result.deinit();
        if (result.rows() == 0) {
            try postgres.exec(lease.conn, "ROLLBACK");
            return false;
        }
        var detail_buf: [128]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "report_id={d} decision={s}", .{ report_id, decision });
        try insertAudit(self.allocator, lease.conn, actor_id, "lazer.report_review", try result.int(i32, 0, 0), detail);
        try postgres.exec(lease.conn, "COMMIT");
        return true;
    }

    pub fn setLazerBeatmapTag(self: *Store, user_id: i32, beatmap_id: i32, tag_id: i64, selected: bool) !bool {
        if (!lazer.validBeatmapTagId(tag_id) or beatmap_id <= 0 or user_id <= 0) return error.InvalidBeatmapTag;
        var user_buf: [24]u8 = undefined;
        var map_buf: [24]u8 = undefined;
        var tag_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
        const tag = try std.fmt.bufPrint(&tag_buf, "{d}", .{tag_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE id=$1", &.{map});
        defer exists.deinit();
        if (exists.rows() == 0) return error.BeatmapNotFound;
        var result = try postgres.queryParams(self.allocator, lease.conn, if (selected)
            "INSERT INTO zigcho.beatmap_tag_votes(beatmap_id,user_id,tag_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING 1"
        else
            "DELETE FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 AND user_id=$2 AND tag_id=$3 RETURNING 1", &.{ map, user, tag });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn lazerBeatmapTagStateJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, beatmap_id: i32) !?[]u8 {
        var user_buf: [24]u8 = undefined;
        var map_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const map = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var exists = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmaps WHERE id=$1", &.{map});
        defer exists.deinit();
        if (exists.rows() == 0) return null;
        var top = try postgres.queryParams(self.allocator, lease.conn, "SELECT tag_id,count(*) FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 GROUP BY tag_id ORDER BY count(*) DESC,tag_id LIMIT 20", &.{map});
        defer top.deinit();
        var own = try postgres.queryParams(self.allocator, lease.conn, "SELECT tag_id FROM zigcho.beatmap_tag_votes WHERE beatmap_id=$1 AND user_id=$2 ORDER BY tag_id", &.{ map, user });
        defer own.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"top_tag_ids\":[");
        for (0..top.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"tag_id\":{d},\"count\":{d}}}", .{ try top.int(i64, row, 0), try top.int(i64, row, 1) });
        }
        try output.writer.writeAll("],\"current_user_tag_ids\":[");
        for (0..own.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{d}", .{try own.int(i64, row, 0)});
        }
        try output.writer.writeAll("]}");
        return @as(?[]u8, try output.toOwnedSlice());
    }

    pub fn lazerCommentsJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, target: LazerCommentTarget, sort: LazerCommentSort, page: u16, parent_id: i64, only_id: i64) ![]u8 {
        if (page == 0 or page > 1000 or parent_id < 0 or only_id < 0) return error.InvalidCommentQuery;
        var target_buf: [32]u8 = undefined;
        var parent_buf: [32]u8 = undefined;
        var only_buf: [32]u8 = undefined;
        var viewer_buf: [24]u8 = undefined;
        var offset_buf: [32]u8 = undefined;
        const target_id = try std.fmt.bufPrint(&target_buf, "{d}", .{target.id});
        const parent = try std.fmt.bufPrint(&parent_buf, "{d}", .{parent_id});
        const only = try std.fmt.bufPrint(&only_buf, "{d}", .{only_id});
        const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
        const offset = try std.fmt.bufPrint(&offset_buf, "{d}", .{(@as(i64, page) - 1) * 50});
        const base_sql = "SELECT c.id,c.parent_id,c.user_id,c.message,to_char(to_timestamp(c.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),to_char(to_timestamp(c.updated_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),CASE WHEN c.deleted_at IS NULL THEN NULL ELSE to_char(to_timestamp(c.deleted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') END,(SELECT count(*) FROM zigcho.lazer_comments r WHERE r.parent_id=c.id),(SELECT count(*) FROM zigcho.lazer_comment_votes v WHERE v.comment_id=c.id),EXISTS(SELECT 1 FROM zigcho.lazer_comment_votes v WHERE v.comment_id=c.id AND v.user_id=$5) FROM zigcho.lazer_comments c JOIN zigcho.users u ON u.id=c.user_id WHERE c.commentable_type=$1 AND c.commentable_id=$2 AND NOT u.restricted AND (($4::bigint>0 AND c.id=$4::bigint) OR ($4::bigint=0 AND (($3::bigint>0 AND c.parent_id=$3::bigint) OR ($3::bigint=0 AND c.parent_id IS NULL))))";
        const sql = switch (sort) {
            .new => base_sql ++ " ORDER BY c.created_at DESC,c.id DESC LIMIT 51 OFFSET $6::int",
            .old => base_sql ++ " ORDER BY c.created_at ASC,c.id ASC LIMIT 51 OFFSET $6::int",
            .top => base_sql ++ " ORDER BY (SELECT count(*) FROM zigcho.lazer_comment_votes v WHERE v.comment_id=c.id) DESC,c.created_at DESC,c.id DESC LIMIT 51 OFFSET $6::int",
        };
        var lease = self.pool.acquire();
        defer lease.release();
        var rows = try postgres.queryParams(allocator, lease.conn, sql, &.{ target.commentable.text(), target_id, parent, only, viewer, offset });
        defer rows.deinit();
        var count = try postgres.queryParams(allocator, lease.conn, "SELECT count(*),count(*) FILTER(WHERE parent_id IS NULL) FROM zigcho.lazer_comments WHERE commentable_type=$1 AND commentable_id=$2", &.{ target.commentable.text(), target_id });
        defer count.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"commentable_meta\":[{{\"id\":{d},\"owner_id\":null,\"owner_title\":null,\"title\":", .{target.id});
        var title_buf: [96]u8 = undefined;
        const title = try std.fmt.bufPrint(&title_buf, "{s} #{d}", .{ target.commentable.text(), target.id });
        try jsonString(&output.writer, title);
        try output.writer.writeAll(",\"type\":");
        try jsonString(&output.writer, target.commentable.text());
        try output.writer.writeAll(",\"url\":");
        var url_buf: [128]u8 = undefined;
        const url = if (target.commentable == .beatmapset) try std.fmt.bufPrint(&url_buf, "https://kai.ovh/beatmapsets/{d}", .{target.id}) else try std.fmt.bufPrint(&url_buf, "https://kai.ovh/", .{});
        try jsonString(&output.writer, url);
        try output.writer.writeAll(",\"current_user_attributes\":{\"can_new_comment_reason\":null}}],\"comments\":[");
        const visible_rows = @min(rows.rows(), 50);
        var user_ids: std.ArrayList(i32) = .empty;
        defer user_ids.deinit(allocator);
        var voted_ids: std.ArrayList(i64) = .empty;
        defer voted_ids.deinit(allocator);
        for (0..visible_rows) |row| {
            if (row != 0) try output.writer.writeByte(',');
            const comment_id = try rows.int(i64, row, 0);
            const user_id = try rows.int(i32, row, 2);
            if (std.mem.indexOfScalar(i32, user_ids.items, user_id) == null) try user_ids.append(allocator, user_id);
            if (try rows.boolean(row, 9)) try voted_ids.append(allocator, comment_id);
            try output.writer.print("{{\"id\":{d},\"parent_id\":", .{comment_id});
            if (rows.isNull(row, 1)) try output.writer.writeAll("null") else try output.writer.print("{d}", .{try rows.int(i64, row, 1)});
            try output.writer.print(",\"user_id\":{d},\"message\":", .{user_id});
            try jsonString(&output.writer, rows.value(row, 3));
            try output.writer.print(",\"message_html\":null,\"replies_count\":{d},\"votes_count\":{d},\"commentable_type\":", .{ try rows.int(i32, row, 7), try rows.int(i32, row, 8) });
            try jsonString(&output.writer, target.commentable.text());
            try output.writer.print(",\"commentable_id\":{d},\"legacy_name\":null,\"created_at\":", .{target.id});
            try jsonString(&output.writer, rows.value(row, 4));
            try output.writer.writeAll(",\"updated_at\":");
            try jsonString(&output.writer, rows.value(row, 5));
            try output.writer.writeAll(",\"deleted_at\":");
            if (rows.isNull(row, 6)) try output.writer.writeAll("null") else try jsonString(&output.writer, rows.value(row, 6));
            try output.writer.writeAll(",\"edited_at\":null,\"edited_by_id\":null,\"pinned\":false}");
        }
        try output.writer.print("],\"has_more\":{},\"has_more_id\":null,\"user_follow\":false,\"included_comments\":[],\"pinned_comments\":[],\"user_votes\":[", .{rows.rows() > 50});
        for (voted_ids.items, 0..) |id, index| {
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.print("{d}", .{id});
        }
        try output.writer.writeAll("],\"users\":[");
        for (user_ids.items, 0..) |id, index| {
            var id_buf: [24]u8 = undefined;
            const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
            var user_row = try postgres.queryParams(allocator, lease.conn, "SELECT id,name,CASE WHEN show_country THEN country ELSE 'XX' END,privileges,restricted FROM zigcho.users WHERE id=$1", &.{id_text});
            defer user_row.deinit();
            if (user_row.rows() == 0) continue;
            if (index != 0) try output.writer.writeByte(',');
            const country = user_row.value(0, 2);
            const user_value: domain.User = .{ .id = id, .name = user_row.value(0, 1), .safe_name = "", .country = .{ country[0], country[1] }, .privileges = try user_row.int(u32, 0, 3), .restricted = try user_row.boolean(0, 4) };
            try user_json.writeCompact(&output.writer, user_value);
        }
        try output.writer.print("],\"total\":{d},\"top_level_count\":{d}}}", .{ try count.int(i32, 0, 0), try count.int(i32, 0, 1) });
        return output.toOwnedSlice();
    }

    fn directMessageAllowedWithConnection(self: *Store, conn: *postgres.c.PGconn, from_id: i32, to_id: i32) !bool {
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

    pub fn directMessageAllowed(self: *Store, from_id: i32, to_id: i32) !bool {
        var lease = self.pool.acquire();
        defer lease.release();
        return self.directMessageAllowedWithConnection(lease.conn, from_id, to_id);
    }

    pub fn storeDirectMessage(self: *Store, from_id: i32, to_id: i32, message: []const u8) !void {
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
        if (!try self.directMessageAllowedWithConnection(lease.conn, from_id, to_id)) return error.DirectMessageBlocked;
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.direct_messages(from_id,to_id,message) VALUES($1,$2,$3)", &.{ from, to, message });
        result.deinit();
        var mirror = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message) VALUES($1,$2,$3)", &.{ from, target, message });
        mirror.deinit();
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn unreadDirectMessages(self: *Store, allocator: std.mem.Allocator, to_id: i32) ![]DirectMessage {
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

    pub fn markDirectMessagesRead(self: *Store, to_id: i32, from_id: i32) !void {
        var to_buf: [24]u8 = undefined;
        var from_buf: [24]u8 = undefined;
        const to = try std.fmt.bufPrint(&to_buf, "{d}", .{to_id});
        const from = try std.fmt.bufPrint(&from_buf, "{d}", .{from_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.direct_messages SET read=true WHERE to_id=$1 AND from_id=$2 AND NOT read", &.{ to, from });
        result.deinit();
    }

    pub fn recordPublicMessage(self: *Store, sender_id: i32, target: []const u8, message: []const u8) !void {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{sender_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message) VALUES($1,$2,$3)", &.{ id, target, message });
        result.deinit();
    }

    pub fn recordLazerPublicMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, target: []const u8, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
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

    pub fn recordLazerDirectMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, target_id: i32, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
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
        if (!try self.directMessageAllowedWithConnection(lease.conn, sender_id, target_id)) return error.DirectMessageBlocked;
        var insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message,is_action,client_uuid) VALUES($1,$2,$3,$4,$5) ON CONFLICT(sender_id,client_uuid) WHERE client_uuid!='' DO NOTHING RETURNING 1", &.{ sender, target, message, if (is_action) "true" else "false", uuid });
        const inserted = insert.rows() != 0;
        insert.deinit();
        var row = try postgres.queryParams(allocator, lease.conn, "SELECT m.id,m.target,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE m.sender_id=$1 AND m.client_uuid=$2", &.{ sender, uuid });
        defer row.deinit();
        if (row.rows() != 1) return error.DatabaseQueryFailed;
        if (!std.mem.eql(u8, row.value(0, 1), target) or !std.mem.eql(u8, row.value(0, 2), message) or (try row.boolean(0, 3)) != is_action) return error.ChatUuidConflict;
        if (inserted) {
            var direct = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.direct_messages(from_id,to_id,message,is_action,client_uuid) VALUES($1,$2,$3,$4,$5)", &.{ sender, receiver, message, if (is_action) "true" else "false", uuid });
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
        return .{ .json = try output.toOwnedSlice(), .inserted = inserted };
    }

    pub fn lazerDirectMessagesJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, other_id: i32, since: i64, limit: u16) ![]u8 {
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

    pub fn directMessageThreadsJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, limit: u8) ![]u8 {
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
            try jsonString(&output.writer, result.value(row, 1));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, result.value(row, 2));
            try output.writer.print(",\"privileges\":{d},\"last_message\":", .{try result.int(u32, row, 3)});
            try jsonString(&output.writer, result.value(row, 4));
            try output.writer.print(",\"is_action\":{},\"last_message_at\":", .{try result.boolean(row, 5)});
            try jsonString(&output.writer, result.value(row, 6));
            try output.writer.print(",\"last_sender_id\":{d},\"unread\":{d}}}", .{ try result.int(i32, row, 7), try result.int(i64, row, 8) });
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerAllMessagesJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, since: i64, limit: u16) ![]u8 {
        if (viewer_id <= 0 or since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
        var low_pattern_buf: [64]u8 = undefined;
        var high_pattern_buf: [64]u8 = undefined;
        var since_buf: [24]u8 = undefined;
        var limit_buf: [8]u8 = undefined;
        const low_pattern = try std.fmt.bufPrint(&low_pattern_buf, "@dm:{d}:%", .{viewer_id});
        const high_pattern = try std.fmt.bufPrint(&high_pattern_buf, "@dm:%:{d}", .{viewer_id});
        const since_text = try std.fmt.bufPrint(&since_buf, "{d}", .{since});
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        const filter = "target IN('#osu','#announce','#lobby','#lazer') OR target LIKE $1 OR target LIKE $2";
        const sql = if (since == 0)
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT * FROM zigcho.chat_messages WHERE " ++ filter ++ " ORDER BY id DESC LIMIT $3::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
        else
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE (" ++ filter ++ ") AND m.id>$3::bigint AND NOT u.restricted ORDER BY m.id LIMIT $4::int";
        var result = if (since == 0)
            try postgres.queryParams(allocator, lease.conn, sql, &.{ low_pattern, high_pattern, limit_text })
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

    pub fn lazerChatMessagesJson(self: *Store, allocator: std.mem.Allocator, channel_id: ?i64, since: i64, limit: u16) ![]u8 {
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

    pub fn lazerChannelListJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
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

    pub fn lazerChannelCursor(self: *Store, user_id: i32, channel_id: i64) !ChatCursor {
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

    pub fn lazerDirectMessageCursor(self: *Store, viewer_id: i32, other_id: i32) !ChatCursor {
        if (viewer_id <= 0 or other_id <= 0 or viewer_id == other_id) return error.InvalidDirectMessage;
        var viewer_buf: [24]u8 = undefined;
        var other_buf: [24]u8 = undefined;
        var target_buf: [64]u8 = undefined;
        const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
        const other = try std.fmt.bufPrint(&other_buf, "{d}", .{other_id});
        const target = try lazer.directMessageTarget(&target_buf, viewer_id, other_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT max(m.id),CASE WHEN NOT EXISTS(SELECT 1 FROM zigcho.direct_messages d WHERE d.to_id=$2::int AND d.from_id=$3::int AND NOT d.read) THEN max(m.id) ELSE NULL END FROM zigcho.chat_messages m WHERE m.target=$1", &.{ target, viewer, other });
        defer result.deinit();
        if (result.rows() != 1) return error.DatabaseQueryFailed;
        return .{
            .last_message_id = if (result.isNull(0, 0)) null else try result.int(i64, 0, 0),
            .last_read_id = if (result.isNull(0, 1)) null else try result.int(i64, 0, 1),
        };
    }

    pub fn markLazerChannelRead(self: *Store, user_id: i32, channel_id: i64, message_id: i64) !void {
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

    pub fn beatmapRankContext(self: *Store, map_md5: []const u8) !?domain.BeatmapRankContext {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM zigcho.beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=b.set_id AND n.active) FROM zigcho.beatmaps b WHERE b.md5=$1", &.{map_md5});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try rankContextFromResult(result);
    }

    pub fn requestBeatmapRank(self: *Store, requester_id: i32, map_md5: []const u8) !domain.BeatmapRankContext {
        var actor_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{requester_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM zigcho.beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=b.set_id AND n.active) FROM zigcho.beatmaps b WHERE b.md5=$1 FOR UPDATE", &.{map_md5});
        defer map.deinit();
        if (map.rows() == 0) return error.BeatmapNotFound;
        var context = try rankContextFromResult(map);
        if (context.status != @intFromEnum(domain.RankedStatus.pending)) return error.BeatmapNotPending;
        var set_buf: [24]u8 = undefined;
        var map_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{context.set_id});
        const map_id = try std.fmt.bufPrint(&map_buf, "{d}", .{context.map_id});
        var inserted = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_rank_requests(set_id,map_id,requester_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING 1", &.{ set, map_id, actor });
        defer inserted.deinit();
        if (inserted.rows() == 0) return error.BeatmapAlreadyRequested;
        try insertBeatmapRankEvent(self.allocator, lease.conn, context.set_id, requester_id, "request", context.status, context.status, "player request");
        context.requests += 1;
        try postgres.exec(lease.conn, "COMMIT");
        return context;
    }

    pub fn nominateBeatmapSet(self: *Store, actor_id: i32, map_md5: []const u8, reason: []const u8) !domain.BeatmapRankContext {
        var actor_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM zigcho.beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=b.set_id AND n.active) FROM zigcho.beatmaps b WHERE b.md5=$1 FOR UPDATE", &.{map_md5});
        defer map.deinit();
        if (map.rows() == 0) return error.BeatmapNotFound;
        var context = try rankContextFromResult(map);
        if (context.status != @intFromEnum(domain.RankedStatus.pending)) return error.BeatmapNotPending;
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{context.set_id});
        var inserted = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.beatmap_nominations(set_id,nominator_id,active) VALUES($1,$2,true) ON CONFLICT(set_id,nominator_id) DO UPDATE SET active=true,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE NOT zigcho.beatmap_nominations.active RETURNING 1", &.{ set, actor });
        defer inserted.deinit();
        if (inserted.rows() == 0) return error.BeatmapAlreadyNominated;
        try insertBeatmapRankEvent(self.allocator, lease.conn, context.set_id, actor_id, "nominate", context.status, context.status, reason);
        context.nominations += 1;
        try postgres.exec(lease.conn, "COMMIT");
        return context;
    }

    pub fn applyBeatmapRankAction(self: *Store, actor_id: i32, map_md5: []const u8, action: domain.BeatmapRankAction, reason: []const u8) !domain.BeatmapRankContext {
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,(SELECT count(*) FROM zigcho.beatmap_rank_requests r WHERE r.set_id=b.set_id AND r.active),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=b.set_id AND n.active) FROM zigcho.beatmaps b WHERE b.md5=$1 FOR UPDATE", &.{map_md5});
        defer map.deinit();
        if (map.rows() == 0) return error.BeatmapNotFound;
        var context = try rankContextFromResult(map);
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{context.set_id});
        var locked = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,status FROM zigcho.beatmaps WHERE set_id=$1 FOR UPDATE", &.{set});
        defer locked.deinit();
        if (locked.rows() == 0) return error.BeatmapNotFound;
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
                var previous = try postgres.queryParams(self.allocator, lease.conn, "SELECT from_status FROM zigcho.beatmap_rank_events WHERE set_id=$1 AND from_status!=to_status ORDER BY id DESC LIMIT 1", &.{set});
                defer previous.deinit();
                if (previous.rows() == 0) return error.NothingToRollback;
                target = try previous.int(i8, 0, 0);
            },
        }
        var status_buf: [8]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buf, "{d}", .{target});
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET status=$1,status_frozen=true,last_update=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$2 RETURNING 1", &.{ status, set });
        defer update.deinit();
        if (update.rows() == 0) return error.BeatmapNotFound;
        if (action != .qualify) {
            var cleared = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_nominations SET active=false,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND active", &.{set});
            cleared.deinit();
            context.nominations = 0;
        }
        if (action == .rank or action == .approve or action == .love) {
            var resolved = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmap_rank_requests SET active=false,resolved_at=extract(epoch FROM clock_timestamp())::bigint WHERE set_id=$1 AND active", &.{set});
            resolved.deinit();
            context.requests = 0;
        }
        try self.rebuildRankedStats(lease.conn);
        try insertBeatmapRankEvent(self.allocator, lease.conn, context.set_id, actor_id, action_name, current, target, reason);
        context.status = target;
        try postgres.exec(lease.conn, "COMMIT");
        return context;
    }

    pub fn beatmapRankQueue(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT r.set_id,count(*),min(r.created_at),min(b.artist),min(b.title),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=r.set_id AND n.active) FROM zigcho.beatmap_rank_requests r JOIN zigcho.beatmaps b ON b.set_id=r.set_id WHERE r.active GROUP BY r.set_id ORDER BY min(r.created_at),r.set_id LIMIT 50");
        defer result.deinit();
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        for (0..result.rows()) |row| {
            if (output.items.len != 0) try output.append(allocator, '\n');
            const line = try std.fmt.allocPrint(allocator, "set {d} | {d} request(s) | {d}/2 noms | {s} - {s}", .{ try result.int(i32, row, 0), try result.int(i32, row, 1), try result.int(i32, row, 5), result.value(row, 3), result.value(row, 4) });
            defer allocator.free(line);
            try output.appendSlice(allocator, line);
        }
        return output.toOwnedSlice(allocator);
    }

    fn rankContextFromResult(result: postgres.Result) !domain.BeatmapRankContext {
        return .{ .map_id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .status = try result.int(i8, 0, 2), .requests = try result.int(u32, 0, 3), .nominations = try result.int(u32, 0, 4) };
    }

    fn insertBeatmapRankEvent(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, set_id: i32, actor_id: i32, action: []const u8, from_status: i8, to_status: i8, reason: []const u8) !void {
        var set_buf: [24]u8 = undefined;
        var actor_buf: [24]u8 = undefined;
        var from_buf: [8]u8 = undefined;
        var to_buf: [8]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        const from = try std.fmt.bufPrint(&from_buf, "{d}", .{from_status});
        const to = try std.fmt.bufPrint(&to_buf, "{d}", .{to_status});
        var event = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.beatmap_rank_events(set_id,actor_id,action,from_status,to_status,reason) VALUES($1,$2,$3,$4,$5,$6)", &.{ set, actor, action, from, to, reason });
        event.deinit();
        var target_buf: [40]u8 = undefined;
        var audit_action_buf: [64]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "beatmapset:{d}", .{set_id});
        const audit_action = try std.fmt.bufPrint(&audit_action_buf, "beatmap.{s}", .{action});
        var audit = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, audit_action, target, reason });
        audit.deinit();
    }

    fn rebuildRankedStats(self: *Store, conn: *postgres.c.PGconn) !void {
        var best = try postgres.query(
            conn,
            "UPDATE zigcho.lazer_scores SET best=false;" ++
                "WITH ordered AS (SELECT id,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace ORDER BY pp DESC,total_score DESC,id ASC) place FROM zigcho.lazer_scores WHERE passed) " ++
                "UPDATE zigcho.lazer_scores scores SET best=true FROM ordered WHERE scores.id=ordered.id AND ordered.place=1",
        );
        best.deinit();
        const internal_mode = "CASE WHEN (s.mods&8192)!=0 THEN s.mode+8 WHEN (s.mods&128)!=0 THEN s.mode+4 ELSE s.mode END";
        const lazer_internal_mode = "CASE l.rank_namespace WHEN 'vanilla' THEN l.ruleset_id WHEN 'relax' THEN l.ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE -1 END";
        const lazer_hits = "coalesce((l.statistics_json->>'meh')::bigint,0)+coalesce((l.statistics_json->>'ok')::bigint,0)+coalesce((l.statistics_json->>'good')::bigint,0)+coalesce((l.statistics_json->>'great')::bigint,0)+coalesce((l.statistics_json->>'perfect')::bigint,0)";
        var reset = try postgres.query(conn, "UPDATE zigcho.stats st SET " ++
            "total_score=coalesce((SELECT sum(s.score) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum(coalesce(l.legacy_total_score,l.total_score)) FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
            "plays=coalesce((SELECT count(*) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT count(*) FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
            "play_time=coalesce((SELECT sum(s.time_elapsed/1000) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum(greatest(b.total_length,0)) FROM zigcho.lazer_scores l JOIN zigcho.beatmaps b ON b.id=l.beatmap_id WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
            "total_hits=coalesce((SELECT sum(s.n300+s.n100+s.n50+CASE WHEN s.mode IN(1,3) THEN s.ngeki+s.nkatu ELSE 0 END) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum(" ++ lazer_hits ++ ") FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
            "ranked_score=0," ++
            "max_combo=greatest(coalesce((SELECT max(s.max_combo) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode AND s.passed AND b.status>=3),0),coalesce((SELECT max(l.max_combo) FROM zigcho.lazer_scores l JOIN zigcho.beatmaps b ON b.id=l.beatmap_id WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode AND l.passed AND b.status>=3),0))," ++
            "pp=0,accuracy=0 WHERE st.user_id!=3 AND (EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode))");
        reset.deinit();
        var keys = try postgres.query(conn, "SELECT st.user_id,st.mode FROM zigcho.stats st WHERE st.user_id!=3 AND (EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode)) ORDER BY st.user_id,st.mode");
        defer keys.deinit();
        for (0..keys.rows()) |row| {
            const user_id = try keys.int(i32, row, 0);
            const stats_mode = try keys.int(u8, row, 1);
            const namespace: []const u8 = switch (stats_mode) {
                0...3 => "vanilla",
                4...6 => "relax",
                8 => "autopilot",
                else => continue,
            };
            try self.rebuildCombinedPerformanceWithConnection(conn, user_id, stats_mode % 4, stats_mode, namespace);
        }
    }

    pub fn recalculatePerformance(self: *Store, allocator: std.mem.Allocator) !u64 {
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var scores = try postgres.query(lease.conn, "SELECT s.id,s.mode,s.mods,s.max_combo,s.n300,s.n100,s.n50,s.nmiss,s.ngeki,s.nkatu,s.score,b.osu_file FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE b.osu_file IS NOT NULL ORDER BY s.id");
        defer scores.deinit();
        var count: u64 = 0;
        for (0..scores.rows()) |row| {
            const map_file = try postgres.decodeBytea(allocator, scores.value(row, 11));
            defer allocator.free(map_file);
            const result = performance_calculator.calculate(map_file, .{
                .mode = try scores.int(u8, row, 1),
                .lazer = 0,
                .mods = try scores.int(u32, row, 2),
                .max_combo = try scores.int(u32, row, 3),
                .n_geki = try scores.int(u32, row, 8),
                .n_katu = try scores.int(u32, row, 9),
                .n300 = try scores.int(u32, row, 4),
                .n100 = try scores.int(u32, row, 5),
                .n50 = try scores.int(u32, row, 6),
                .misses = try scores.int(u32, row, 7),
                .legacy_total_score = try scores.int(u32, row, 10),
            }) catch continue;
            var id_buf: [24]u8 = undefined;
            var pp_buf: [64]u8 = undefined;
            var star_buf: [64]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "{d}", .{try scores.int(i64, row, 0)});
            const performance = try std.fmt.bufPrint(&pp_buf, "{d}", .{result.pp});
            const stars = try std.fmt.bufPrint(&star_buf, "{d}", .{result.stars});
            var update = try postgres.queryParams(allocator, lease.conn, "UPDATE zigcho.scores SET pp=$1,star_rating=$2 WHERE id=$3", &.{ performance, stars, id });
            update.deinit();
            count += 1;
        }
        var lazer_scores = try postgres.query(lease.conn, "SELECT s.id,s.beatmap_id,s.ruleset_id,s.total_score,s.legacy_total_score,s.accuracy,s.max_combo,s.passed,s.mods_json::text,s.statistics_json::text,s.rank_namespace,b.osu_file FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE b.osu_file IS NOT NULL ORDER BY s.id");
        defer lazer_scores.deinit();
        for (0..lazer_scores.rows()) |row| {
            const namespace = std.meta.stringToEnum(lazer.Namespace, lazer_scores.value(row, 10)) orelse continue;
            if (namespace == .custom) continue;
            var parsed_mods = std.json.parseFromSlice(std.json.Value, allocator, lazer_scores.value(row, 8), .{}) catch continue;
            defer parsed_mods.deinit();
            const mods = switch (parsed_mods.value) {
                .array => |value| value,
                else => continue,
            };
            var parsed_statistics = std.json.parseFromSlice(std.json.Value, allocator, lazer_scores.value(row, 9), .{}) catch continue;
            defer parsed_statistics.deinit();
            const statistics = switch (parsed_statistics.value) {
                .object => |value| value,
                else => continue,
            };
            const input: lazer.ScoreInput = .{
                .beatmap_id = try lazer_scores.int(i64, row, 1),
                .ruleset_id = try lazer_scores.int(i64, row, 2),
                .total_score = try lazer_scores.int(i64, row, 3),
                .legacy_total_score = if (lazer_scores.isNull(row, 4)) null else try lazer_scores.int(i64, row, 4),
                .accuracy = try lazer_scores.float(f64, row, 5),
                .max_combo = try lazer_scores.int(i64, row, 6),
                .passed = try lazer_scores.boolean(row, 7),
                .mods = mods,
                .statistics = statistics,
                .namespace = namespace,
            };
            const state = (lazer.performanceState(input) catch continue) orelse continue;
            const map_file = try postgres.decodeBytea(allocator, lazer_scores.value(row, 11));
            defer allocator.free(map_file);
            const performance_input: performance_calculator.Input = .{
                .mode = @intCast(input.ruleset_id),
                .lazer = 1,
                .mods = state.mods,
                .max_combo = state.max_combo,
                .large_tick_hits = state.large_tick_hits,
                .small_tick_hits = state.small_tick_hits,
                .slider_end_hits = state.slider_end_hits,
                .n_geki = state.n_geki,
                .n_katu = state.n_katu,
                .n300 = state.n300,
                .n100 = state.n100,
                .n50 = state.n50,
                .misses = state.misses,
                .legacy_total_score = state.legacy_total_score,
            };
            const result = if (namespace == .vanilla)
                performance_calculator.calculateLazer(map_file, lazer_scores.value(row, 8), performance_input) catch continue
            else
                performance_calculator.calculate(map_file, performance_input) catch continue;
            var id_buf: [24]u8 = undefined;
            var pp_buf: [64]u8 = undefined;
            var star_buf: [64]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "{d}", .{try lazer_scores.int(i64, row, 0)});
            const performance = try std.fmt.bufPrint(&pp_buf, "{d}", .{result.pp});
            const stars = try std.fmt.bufPrint(&star_buf, "{d}", .{result.stars});
            var update = try postgres.queryParams(allocator, lease.conn, "UPDATE zigcho.lazer_scores SET pp=$1,star_rating=$2 WHERE id=$3", &.{ performance, stars, id });
            update.deinit();
            count += 1;
        }
        var best = try postgres.query(
            lease.conn,
            "UPDATE zigcho.scores SET best=false;" ++
                "WITH ordered AS (SELECT id,row_number() OVER(PARTITION BY user_id,map_md5,mode,rank_namespace ORDER BY CASE WHEN rank_namespace IN('vanilla','scorev2') THEN score::double precision ELSE pp END DESC,id ASC) AS place FROM zigcho.scores WHERE passed) " ++
                "UPDATE zigcho.scores SET best=true WHERE id IN(SELECT id FROM ordered WHERE place=1)",
        );
        best.deinit();
        try self.rebuildRankedStats(lease.conn);
        var detail_buf: [192]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "recalculated {d} stable and lazer scores with {s}", .{ count, performance_calculator.engine_version });
        var audit = try postgres.queryParams(allocator, lease.conn, "INSERT INTO zigcho.audit_log(action,target,detail) VALUES('operations.pp_recalc','scores',$1)", &.{detail});
        audit.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return count;
    }

    pub fn channelCanWrite(self: *Store, name: []const u8, privileges: u32) !bool {
        var priv_buf: [24]u8 = undefined;
        const priv_text = try std.fmt.bufPrint(&priv_buf, "{d}", .{privileges});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT CASE WHEN locked THEN ($2::bigint & 8192)=8192 ELSE ($2::bigint & write_privileges)=write_privileges END FROM zigcho.chat_channels WHERE name=$1", &.{ name, priv_text });
        defer result.deinit();
        if (result.rows() == 0) return true;
        return result.boolean(0, 0);
    }

    pub fn setChannelLocked(self: *Store, actor_id: i32, name: []const u8, locked: bool, reason: []const u8) !void {
        var actor_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.chat_channels SET locked=$1,updated_by=$2,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE name=$3 RETURNING 1", &.{ if (locked) "true" else "false", actor, name });
        defer update.deinit();
        if (update.rows() == 0) return error.InvalidChannel;
        var audit = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, if (locked) "channel.lock" else "channel.unlock", name, reason });
        audit.deinit();
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn setSilence(self: *Store, actor_id: i32, target_id: i32, silence_end: i64, action: []const u8, reason: []const u8) !void {
        var target_buf: [24]u8 = undefined;
        var end_buf: [24]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
        const end = try std.fmt.bufPrint(&end_buf, "{d}", .{silence_end});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET silence_end=$1 WHERE id=$2 AND id!=3 RETURNING 1", &.{ end, target });
        defer update.deinit();
        if (update.rows() == 0) return error.InvalidModerationTarget;
        try insertAudit(self.allocator, lease.conn, actor_id, action, target_id, reason);
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn setRestricted(self: *Store, actor_id: i32, target_id: i32, restricted: bool, reason: []const u8) !void {
        var target_buf: [24]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET restricted=$1 WHERE id=$2 AND id!=3 RETURNING 1", &.{ if (restricted) "true" else "false", target });
        defer update.deinit();
        if (update.rows() == 0) return error.InvalidModerationTarget;
        try insertAudit(self.allocator, lease.conn, actor_id, if (restricted) "account.restrict" else "account.unrestrict", target_id, reason);
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn changePrivileges(self: *Store, actor_id: i32, target_id: i32, bits: u32, add: bool) !u32 {
        var target_buf: [24]u8 = undefined;
        var bits_buf: [24]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
        const bit_text = try std.fmt.bufPrint(&bits_buf, "{d}", .{bits});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        const sql = if (add)
            "UPDATE zigcho.users SET privileges=privileges | $1::bigint WHERE id=$2 AND id!=3 RETURNING privileges"
        else
            "UPDATE zigcho.users SET privileges=privileges & ~$1::bigint WHERE id=$2 AND id!=3 RETURNING privileges";
        var update = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ bit_text, target });
        defer update.deinit();
        if (update.rows() == 0) return error.InvalidModerationTarget;
        const privileges = try update.int(u32, 0, 0);
        var detail_buf: [64]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "{s} bits:{d}", .{ if (add) "add" else "remove", bits });
        try insertAudit(self.allocator, lease.conn, actor_id, "account.privileges", target_id, detail);
        try postgres.exec(lease.conn, "COMMIT");
        return privileges;
    }

    pub fn addModerationNote(self: *Store, actor_id: i32, target_id: i32, note: []const u8) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        try insertAudit(self.allocator, lease.conn, actor_id, "account.note", target_id, note);
    }

    pub fn recordModerationAction(self: *Store, actor_id: i32, target_id: i32, action: []const u8, detail: []const u8) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        try insertAudit(self.allocator, lease.conn, actor_id, action, target_id, detail);
    }

    pub fn recordAudit(self: *Store, actor_id: i32, action: []const u8, target: []const u8, detail: []const u8) !void {
        var actor_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, action, target, detail });
        result.deinit();
    }

    pub fn moderationNotes(self: *Store, allocator: std.mem.Allocator, target_id: i32, limit: u8) ![]u8 {
        var target_buf: [24]u8 = undefined;
        var limit_buf: [4]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_id});
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT created_at,action,coalesce(actor_id,0),coalesce(detail,'') FROM zigcho.audit_log WHERE target=$1 ORDER BY id DESC LIMIT $2", &.{ target, limit_text });
        defer result.deinit();
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        for (0..result.rows()) |row| {
            if (output.items.len != 0) try output.append(allocator, '\n');
            const line = try std.fmt.allocPrint(allocator, "{d} | {s} | by {d} | {s}", .{
                try result.int(i64, row, 0),
                result.value(row, 1),
                try result.int(i32, row, 2),
                result.value(row, 3),
            });
            defer allocator.free(line);
            try output.appendSlice(allocator, line);
        }
        return output.toOwnedSlice(allocator);
    }

    pub fn createModerationAppeal(self: *Store, user_id: i32, kind: []const u8, message: []const u8) !i64 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.moderation_appeals(user_id,kind,message) VALUES($1,$2,$3) RETURNING id", &.{ id, kind, message }) catch |err| switch (err) {
            error.UniqueViolation => return error.AppealAlreadyOpen,
            else => return err,
        };
        defer result.deinit();
        return result.int(i64, 0, 0);
    }

    pub fn resolveModerationAppeal(self: *Store, actor_id: i32, appeal_id: i64, status: []const u8, resolution: []const u8) !void {
        var actor_buf: [24]u8 = undefined;
        var appeal_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        const appeal = try std.fmt.bufPrint(&appeal_buf, "{d}", .{appeal_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.moderation_appeals SET status=$1,reviewer_id=$2,resolution=$3,resolved_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$4 AND status='open' RETURNING user_id", &.{ status, actor, resolution, appeal });
        defer update.deinit();
        if (update.rows() == 0) return error.AppealNotOpen;
        const target_id = try update.int(i32, 0, 0);
        try insertAudit(self.allocator, lease.conn, actor_id, if (std.mem.eql(u8, status, "accepted")) "appeal.accept" else "appeal.deny", target_id, resolution);
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn beatmapMd5ForSet(self: *Store, set_id: i32) !?[32]u8 {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{set_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT md5 FROM zigcho.beatmaps WHERE set_id=$1 ORDER BY id LIMIT 1", &.{set});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const value = result.value(0, 0);
        if (value.len != 32) return error.InvalidBeatmapHash;
        var out: [32]u8 = undefined;
        @memcpy(&out, value);
        return out;
    }

    pub fn staffAnticheatJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT o.id,o.user_id,u.name,coalesce(o.score_id,0),o.source,o.module,o.action,o.sample_weight,o.reason,o.risk_score,o.confidence_bps,o.evidence,o.decision_flags,o.rule_revision,o.objects_checked,o.matched_clicks,o.mean_abs_timing_error_milli,o.timing_stddev_milli,o.exact_timing_bps,o.center_hits_bps,o.mean_center_distance_milli,o.snap_events,o.replay_match_count,o.key_press_count,o.key_hold_count,o.mean_hold_duration_milli,o.hold_duration_stddev_milli,o.alternation_bps,o.target_distance_stddev_milli,o.velocity_spike_count,o.movement_velocity_stddev_milli,o.review_label,coalesce(reviewer.name,''),o.review_note,coalesce(o.reviewed_at,0),o.created_at FROM zigcho.anticheat_observations o JOIN zigcho.users u ON u.id=o.user_id LEFT JOIN zigcho.users reviewer ON reviewer.id=o.reviewer_id ORDER BY (o.review_label='pending') DESC,o.created_at DESC,o.id DESC LIMIT 250");
        defer result.deinit();
        var pending_result = try postgres.query(lease.conn, "SELECT count(*) FROM zigcho.anticheat_observations WHERE review_label='pending'");
        defer pending_result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"pending\":{d},\"observations\":[", .{try pending_result.int(i64, 0, 0)});
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ try result.int(i64, row, 0), try result.int(i32, row, 1) });
            try jsonString(&output.writer, result.value(row, 2));
            try output.writer.print(",\"score_id\":{d},\"source\":", .{try result.int(i64, row, 3)});
            try jsonString(&output.writer, result.value(row, 4));
            try output.writer.writeAll(",\"module\":");
            try jsonString(&output.writer, result.value(row, 5));
            try output.writer.print(",\"action\":{d},\"sample_weight\":{d},\"reason\":{d},\"risk\":{d},\"confidence_bps\":{d},\"evidence\":{d},\"decision_flags\":{d},\"rule_revision\":{d},\"objects\":{d},\"clicks\":{d},\"mean_timing_milli\":{d},\"timing_stddev_milli\":{d},\"exact_timing_bps\":{d},\"center_hits_bps\":{d},\"mean_center_distance_milli\":{d},\"snaps\":{d},\"replay_match_count\":{d},\"key_press_count\":{d},\"key_hold_count\":{d},\"mean_hold_duration_milli\":{d},\"hold_duration_stddev_milli\":{d},\"alternation_bps\":{d},\"target_distance_stddev_milli\":{d},\"velocity_spike_count\":{d},\"movement_velocity_stddev_milli\":{d},\"review_label\":", .{
                try result.int(i32, row, 6),  try result.int(i32, row, 7),  try result.int(i32, row, 8),  try result.int(i32, row, 9),
                try result.int(i64, row, 10), try result.int(i64, row, 11), try result.int(i32, row, 12), try result.int(i32, row, 13),
                try result.int(i32, row, 14), try result.int(i32, row, 15), try result.int(i32, row, 16), try result.int(i32, row, 17),
                try result.int(i32, row, 18), try result.int(i32, row, 19), try result.int(i32, row, 20), try result.int(i32, row, 21),
                try result.int(i32, row, 22), try result.int(i32, row, 23), try result.int(i32, row, 24), try result.int(i32, row, 25),
                try result.int(i32, row, 26), try result.int(i32, row, 27), try result.int(i32, row, 28), try result.int(i32, row, 29),
                try result.int(i32, row, 30),
            });
            try jsonString(&output.writer, result.value(row, 31));
            try output.writer.writeAll(",\"reviewer\":");
            try jsonString(&output.writer, result.value(row, 32));
            try output.writer.writeAll(",\"review_note\":");
            try jsonString(&output.writer, result.value(row, 33));
            try output.writer.print(",\"reviewed_at\":{d},\"created_at\":{d}}}", .{ try result.int(i64, row, 34), try result.int(i64, row, 35) });
        }
        try output.writer.writeAll("]}");
        return output.toOwnedSlice();
    }

    pub fn reviewAnticheatObservation(self: *Store, actor_id: i32, observation_id: i64, label: AnticheatReviewLabel, note: []const u8) !void {
        const trimmed = std.mem.trim(u8, note, " \t\r\n");
        if (actor_id <= 0 or observation_id <= 0 or trimmed.len < 3 or trimmed.len > 1000 or !std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidAnticheatReview;
        var actor_buf: [24]u8 = undefined;
        var id_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{observation_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.anticheat_observations SET review_label=$1,reviewer_id=$2,review_note=$3,reviewed_at=extract(epoch FROM clock_timestamp())::bigint WHERE id=$4 RETURNING user_id", &.{ label.text(), actor, trimmed, id });
        defer result.deinit();
        if (result.rows() == 0) return error.AnticheatObservationNotFound;
        const user_id = try result.int(i32, 0, 0);
        var detail_buf: [1120]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "observation_id={d} label={s} note={s}", .{ observation_id, label.text(), trimmed });
        try insertAudit(self.allocator, lease.conn, actor_id, "anticheat.review", user_id, detail);
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn staffOverviewJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT (SELECT count(*) FROM zigcho.moderation_appeals WHERE status='open'),(SELECT count(DISTINCT set_id) FROM zigcho.beatmap_rank_requests WHERE active),(SELECT count(*) FROM zigcho.users WHERE restricted),(SELECT count(*) FROM zigcho.users WHERE silence_end>extract(epoch FROM clock_timestamp())::bigint),(SELECT count(*) FROM zigcho.audit_log WHERE created_at>=extract(epoch FROM clock_timestamp())::bigint-86400),(SELECT count(*) FROM zigcho.client_hardware),(SELECT count(*) FROM zigcho.anticheat_observations WHERE review_label='pending'),(SELECT count(*) FROM zigcho.lazer_reports WHERE status='open')");
        defer result.deinit();
        return std.fmt.allocPrint(allocator, "{{\"open_appeals\":{d},\"ranking_sets\":{d},\"restricted_users\":{d},\"silenced_users\":{d},\"audit_24h\":{d},\"hardware_records\":{d},\"anticheat_pending\":{d},\"open_reports\":{d}}}", .{ try result.int(i64, 0, 0), try result.int(i64, 0, 1), try result.int(i64, 0, 2), try result.int(i64, 0, 3), try result.int(i64, 0, 4), try result.int(i64, 0, 5), try result.int(i64, 0, 6), try result.int(i64, 0, 7) });
    }

    pub fn staffUserSearchJson(self: *Store, allocator: std.mem.Allocator, query: []const u8) ![]u8 {
        const safe = try domain.safeName(allocator, query);
        defer allocator.free(safe);
        var id_buf: [24]u8 = undefined;
        const numeric_id = std.fmt.parseInt(i32, query, 10) catch 0;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{numeric_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,u.country,u.privileges,u.restricted,u.silence_end,coalesce(u.last_login,0),coalesce(t.short_name,'') FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1 OR position(lower($2) in lower(u.name))>0 OR position($3 in u.safe_name)>0 ORDER BY CASE WHEN u.id=$1 THEN 0 WHEN u.safe_name=$3 THEN 1 WHEN lower(u.name)=lower($2) THEN 2 WHEN position($3 in u.safe_name)=1 THEN 3 ELSE 4 END,u.restricted,u.id LIMIT 20", &.{ id, query, safe });
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"name\":", .{try result.int(i32, row, 0)});
            try jsonString(&output.writer, result.value(row, 1));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, result.value(row, 2));
            try output.writer.print(",\"privileges\":{d},\"restricted\":{},\"silence_end\":{d},\"last_login\":{d},\"team\":", .{ try result.int(u32, row, 3), try result.boolean(row, 4), try result.int(i64, row, 5), try result.int(i64, row, 6) });
            try jsonString(&output.writer, result.value(row, 7));
            try output.writer.writeByte('}');
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerUserSearchIds(self: *Store, allocator: std.mem.Allocator, query: []const u8, limit: u8) ![]i32 {
        const safe = try domain.safeName(allocator, query);
        defer allocator.free(safe);
        var limit_buf: [8]u8 = undefined;
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        var rows = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE NOT restricted AND id!=3 AND (position(lower($1) in lower(name))>0 OR position($2 in safe_name)>0) ORDER BY CASE WHEN safe_name=$2 THEN 0 WHEN lower(name)=lower($1) THEN 1 WHEN position($2 in safe_name)=1 THEN 2 ELSE 3 END,id LIMIT $3", &.{ query, safe, limit_text });
        defer rows.deinit();
        const ids = try allocator.alloc(i32, rows.rows());
        errdefer allocator.free(ids);
        for (ids, 0..) |*id, row| id.* = try rows.int(i32, row, 0);
        return ids;
    }

    pub fn staffRankingJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var queue = try postgres.query(lease.conn, "SELECT r.set_id,min(b.status),count(*),(SELECT count(*) FROM zigcho.beatmap_nominations n WHERE n.set_id=r.set_id AND n.active),min(b.artist),min(b.title),min(b.creator),min(b.md5),min(r.created_at) FROM zigcho.beatmap_rank_requests r JOIN zigcho.beatmaps b ON b.set_id=r.set_id WHERE r.active GROUP BY r.set_id ORDER BY min(r.created_at),r.set_id LIMIT 100");
        defer queue.deinit();
        var history = try postgres.query(lease.conn, "SELECT e.id,e.set_id,e.action,e.from_status,e.to_status,e.reason,e.created_at,u.name FROM zigcho.beatmap_rank_events e JOIN zigcho.users u ON u.id=e.actor_id ORDER BY e.id DESC LIMIT 100");
        defer history.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"queue\":[");
        for (0..queue.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"set_id\":{d},\"status\":{d},\"requests\":{d},\"nominations\":{d},\"artist\":", .{ try queue.int(i32, row, 0), try queue.int(i8, row, 1), try queue.int(i32, row, 2), try queue.int(i32, row, 3) });
            try jsonString(&output.writer, queue.value(row, 4));
            try output.writer.writeAll(",\"title\":");
            try jsonString(&output.writer, queue.value(row, 5));
            try output.writer.writeAll(",\"creator\":");
            try jsonString(&output.writer, queue.value(row, 6));
            try output.writer.writeAll(",\"map_md5\":");
            try jsonString(&output.writer, queue.value(row, 7));
            try output.writer.print(",\"created_at\":{d}}}", .{try queue.int(i64, row, 8)});
        }
        try output.writer.writeAll("],\"history\":[");
        for (0..history.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"set_id\":{d},\"action\":", .{ try history.int(i64, row, 0), try history.int(i32, row, 1) });
            try jsonString(&output.writer, history.value(row, 2));
            try output.writer.print(",\"from_status\":{d},\"to_status\":{d},\"reason\":", .{ try history.int(i8, row, 3), try history.int(i8, row, 4) });
            try jsonString(&output.writer, history.value(row, 5));
            try output.writer.print(",\"created_at\":{d},\"actor\":", .{try history.int(i64, row, 6)});
            try jsonString(&output.writer, history.value(row, 7));
            try output.writer.writeByte('}');
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn staffAppealsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT a.id,a.user_id,u.name,u.country,a.kind,a.message,a.status,coalesce(r.name,''),coalesce(a.resolution,''),a.created_at,coalesce(a.resolved_at,0) FROM zigcho.moderation_appeals a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN zigcho.users r ON r.id=a.reviewer_id ORDER BY CASE a.status WHEN 'open' THEN 0 ELSE 1 END,a.created_at,a.id LIMIT 200");
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"appeals\":[");
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"user_id\":{d},\"user\":", .{ try result.int(i64, row, 0), try result.int(i32, row, 1) });
            for (2..9) |column| {
                try jsonString(&output.writer, result.value(row, column));
                const names = [_][]const u8{ "country", "kind", "message", "status", "reviewer", "resolution" };
                if (column < 8) try output.writer.print(",\"{s}\":", .{names[column - 2]});
            }
            try output.writer.print(",\"created_at\":{d},\"resolved_at\":{d}}}", .{ try result.int(i64, row, 9), try result.int(i64, row, 10) });
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn staffUserJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var target_buf: [24]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var user = try postgres.queryParams(allocator, lease.conn, "SELECT id,name,country,privileges,silence_end,restricted,created_at,coalesce(last_login,0),(SELECT count(DISTINCT h2.user_id) FROM zigcho.client_hardware h1 JOIN zigcho.client_hardware h2 ON h2.user_id!=h1.user_id AND h2.adapters_md5=h1.adapters_md5 AND h2.uninstall_md5=h1.uninstall_md5 AND h2.disk_signature_md5=h1.disk_signature_md5 WHERE h1.user_id=u.id) FROM zigcho.users u WHERE id=$1 AND id!=3", &.{id});
        defer user.deinit();
        if (user.rows() == 0) return null;
        var hardware = try postgres.queryParams(allocator, lease.conn, "SELECT right(adapters_md5,8),right(uninstall_md5,8),right(disk_signature_md5,8),client_version,running_under_wine,first_seen,last_seen,occurrences FROM zigcho.client_hardware WHERE user_id=$1 ORDER BY last_seen DESC LIMIT 50", &.{id});
        defer hardware.deinit();
        var audit = try postgres.queryParams(allocator, lease.conn, "SELECT a.id,coalesce(actor.name,'system'),a.action,coalesce(a.detail,''),a.created_at FROM zigcho.audit_log a LEFT JOIN zigcho.users actor ON actor.id=a.actor_id WHERE a.target=$1 ORDER BY a.id DESC LIMIT 100", &.{target});
        defer audit.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"user\":{{\"id\":{d},\"name\":", .{try user.int(i32, 0, 0)});
        try jsonString(&output.writer, user.value(0, 1));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, user.value(0, 2));
        try output.writer.print(",\"privileges\":{d},\"silence_end\":{d},\"restricted\":{},\"created_at\":{d},\"last_login\":{d},\"exact_hardware_matches\":{d}}},\"hardware\":[", .{ try user.int(u32, 0, 3), try user.int(i64, 0, 4), try user.boolean(0, 5), try user.int(i64, 0, 6), try user.int(i64, 0, 7), try user.int(i64, 0, 8) });
        for (0..hardware.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"adapter\":");
            try jsonString(&output.writer, hardware.value(row, 0));
            try output.writer.writeAll(",\"uninstall\":");
            try jsonString(&output.writer, hardware.value(row, 1));
            try output.writer.writeAll(",\"disk\":");
            try jsonString(&output.writer, hardware.value(row, 2));
            try output.writer.writeAll(",\"client\":");
            try jsonString(&output.writer, hardware.value(row, 3));
            try output.writer.print(",\"wine\":{},\"first_seen\":{d},\"last_seen\":{d},\"occurrences\":{d}}}", .{ try hardware.boolean(row, 4), try hardware.int(i64, row, 5), try hardware.int(i64, row, 6), try hardware.int(i32, row, 7) });
        }
        try output.writer.writeAll("],\"audit\":[");
        for (0..audit.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"actor\":", .{try audit.int(i64, row, 0)});
            try jsonString(&output.writer, audit.value(row, 1));
            try output.writer.writeAll(",\"action\":");
            try jsonString(&output.writer, audit.value(row, 2));
            try output.writer.writeAll(",\"detail\":");
            try jsonString(&output.writer, audit.value(row, 3));
            try output.writer.print(",\"created_at\":{d}}}", .{try audit.int(i64, row, 4)});
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn staffAuditJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT a.id,coalesce(u.name,'system'),a.action,coalesce(a.target,''),coalesce(a.detail,''),a.created_at FROM zigcho.audit_log a LEFT JOIN zigcho.users u ON u.id=a.actor_id ORDER BY a.id DESC LIMIT 250");
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"events\":[");
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"actor\":", .{try result.int(i64, row, 0)});
            for (1..5) |column| {
                try jsonString(&output.writer, result.value(row, column));
                const names = [_][]const u8{ "action", "target", "detail" };
                if (column < 4) try output.writer.print(",\"{s}\":", .{names[column - 1]});
            }
            try output.writer.print(",\"created_at\":{d}}}", .{try result.int(i64, row, 5)});
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn staffChannelsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT name,topic,write_privileges,locked,updated_at FROM zigcho.chat_channels ORDER BY name");
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"channels\":[");
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"name\":");
            try jsonString(&output.writer, result.value(row, 0));
            try output.writer.writeAll(",\"topic\":");
            try jsonString(&output.writer, result.value(row, 1));
            try output.writer.print(",\"write_privileges\":{d},\"locked\":{},\"updated_at\":{d}}}", .{ try result.int(u32, row, 2), try result.boolean(row, 3), try result.int(i64, row, 4) });
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn updateCountry(self: *Store, user_id: i32, value: [2]u8) !void {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET country=$1,last_login=extract(epoch FROM clock_timestamp())::bigint WHERE id=$2", &.{ value[0..], id });
        result.deinit();
    }

    pub fn serverCounts(self: *Store) !ServerCounts {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT (SELECT count(*) FROM zigcho.users WHERE id!=3),(SELECT count(*) FROM zigcho.scores)+(SELECT count(*) FROM zigcho.lazer_scores),(SELECT count(*) FROM zigcho.scores WHERE passed)+(SELECT count(*) FROM zigcho.lazer_scores WHERE passed),(SELECT count(*) FROM zigcho.beatmaps)");
        defer result.deinit();
        return .{ .users = try result.int(i64, 0, 0), .plays = try result.int(i64, 0, 1), .passed = try result.int(i64, 0, 2), .maps = try result.int(i64, 0, 3) };
    }

    pub fn siteRankings(self: *Store, allocator: std.mem.Allocator, source: domain.SiteScoreSource, mode: u8, offset: u16) ![]u8 {
        var mode_buf: [4]u8 = undefined;
        var offset_buf: [8]u8 = undefined;
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        var lease = self.pool.acquire();
        defer lease.release();
        const stable_sql =
            "WITH source_scores AS (" ++
            "SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,b.id beatmap_id " ++
            "FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.mode=$1 AND s.rank_namespace=$2)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
            "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET $3";
        const lazer_sql =
            "WITH source_scores AS (" ++
            "SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,s.beatmap_id " ++
            "FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$1 AND s.rank_namespace=$2)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
            "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET $3";
        var result = switch (source) {
            .all => try postgres.queryParams(allocator, lease.conn, "SELECT row_number() OVER(ORDER BY s.pp DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.pp,s.accuracy,s.plays,s.ranked_score,s.total_score,s.max_combo FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND u.id!=3 AND NOT u.restricted AND s.plays>0 ORDER BY s.pp DESC,u.id ASC LIMIT 100 OFFSET $2", &.{ mode_text, offset_text }),
            .stable, .lazer, .scorev2 => blk: {
                var score_mode_buf: [4]u8 = undefined;
                const score_mode_text = try std.fmt.bufPrint(&score_mode_buf, "{d}", .{domain.siteScoreMode(mode)});
                break :blk try postgres.queryParams(allocator, lease.conn, if (source == .lazer) lazer_sql else stable_sql, &.{ score_mode_text, domain.siteNamespace(source, mode), offset_text });
            },
        };
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"source\":\"{s}\",\"mode\":{d},\"offset\":{d},\"players\":[", .{ @tagName(source), mode, offset });
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"rank\":{d},\"id\":{d},\"name\":", .{ try result.int(i32, row, 0), try result.int(i32, row, 1) });
            try jsonString(&output.writer, result.value(row, 2));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, result.value(row, 3));
            try output.writer.print(",\"privileges\":{d},\"pp\":{d},\"accuracy\":{d},\"plays\":{d},\"ranked_score\":{d},\"total_score\":{d},\"max_combo\":{d}}}", .{ try result.int(u32, row, 4), try result.int(i32, row, 5), try result.float(f64, row, 6), try result.int(i32, row, 7), try result.int(i64, row, 8), try result.int(i64, row, 9), try result.int(i32, row, 10) });
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    pub fn lazerRankingsJson(self: *Store, allocator: std.mem.Allocator, ruleset_id: u8, kind: lazer.RankingKind, country_filter: ?[]const u8, page: u16) ![]u8 {
        if (page == 0) return error.InvalidPage;
        var mode_buf: [4]u8 = undefined;
        var offset_buf: [16]u8 = undefined;
        const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{ruleset_id});
        const offset = try std.fmt.bufPrint(&offset_buf, "{d}", .{(@as(u32, page) - 1) * 50});
        var lease = self.pool.acquire();
        defer lease.release();
        const country_sql =
            "WITH visible AS (SELECT CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.plays,s.ranked_score,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted) " ++
            "SELECT country,count(*),sum(plays),sum(ranked_score),sum(pp) FROM visible WHERE country!='XX' GROUP BY country ORDER BY sum(pp) DESC,country ASC LIMIT 50 OFFSET $2";
        const performance_sql =
            "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo," ++
            "row_number() OVER(ORDER BY s.pp DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country THEN u.country ELSE 'XX' END ORDER BY s.pp DESC,u.id ASC) country_rank " ++
            "FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted) " ++
            "SELECT * FROM visible WHERE ($2='' OR country=$2) ORDER BY pp DESC,id ASC LIMIT 50 OFFSET $3";
        const score_sql =
            "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo," ++
            "row_number() OVER(ORDER BY s.total_score DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country THEN u.country ELSE 'XX' END ORDER BY s.total_score DESC,u.id ASC) country_rank " ++
            "FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted) " ++
            "SELECT * FROM visible WHERE ($2='' OR country=$2) ORDER BY total_score DESC,id ASC LIMIT 50 OFFSET $3";
        var result = switch (kind) {
            .country => try postgres.queryParams(allocator, lease.conn, country_sql, &.{ mode, offset }),
            .performance => try postgres.queryParams(allocator, lease.conn, performance_sql, &.{ mode, country_filter orelse "", offset }),
            .score => try postgres.queryParams(allocator, lease.conn, score_sql, &.{ mode, country_filter orelse "", offset }),
        };
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"ranking\":[");
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            if (kind == .country) {
                try output.writer.writeAll("{\"code\":");
                try jsonString(&output.writer, result.value(row, 0));
                try output.writer.print(",\"active_users\":{d},\"play_count\":{d},\"ranked_score\":{d},\"performance\":{d}}}", .{ try result.int(i32, row, 1), try result.int(i64, row, 2), try result.int(i64, row, 3), try result.int(i64, row, 4) });
                continue;
            }
            const country_text = result.value(row, 2);
            const cc: [2]u8 = if (country_text.len == 2) .{ country_text[0], country_text[1] } else .{ 'X', 'X' };
            const user: domain.User = .{ .id = try result.int(i32, row, 0), .name = result.value(row, 1), .safe_name = "", .country = cc, .privileges = try result.int(u32, row, 3) };
            const stats: domain.Stats = .{ .mode = @enumFromInt(ruleset_id), .ranked_score = try result.int(i64, row, 4), .total_score = try result.int(i64, row, 5), .pp = try result.int(i32, row, 6), .plays = try result.int(i32, row, 7), .play_time = try result.int(i32, row, 8), .total_hits = try result.int(i64, row, 9), .accuracy = try result.float(f64, row, 10), .max_combo = try result.int(i32, row, 11) };
            try user_json.writeRankingStatistics(&output.writer, user, stats, try result.int(i32, row, 12), try result.int(i32, row, 13));
        }
        try output.writer.writeAll("],\"cursor\":null}");
        return output.toOwnedSlice();
    }

    fn writeSiteScores(writer: *std.Io.Writer, scores: *postgres.Result, include_weight: bool) !void {
        try writer.writeByte('[');
        for (0..scores.rows()) |row| {
            if (row != 0) try writer.writeByte(',');
            try writer.print("{{\"id\":{d},\"score\":{d},\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"mode\":{d},\"namespace\":", .{ try scores.int(i64, row, 0), try scores.int(i64, row, 1), try scores.float(f64, row, 2), try scores.float(f64, row, 3), try scores.int(i32, row, 4), try scores.int(i32, row, 5), try scores.int(u8, row, 6) });
            try jsonString(writer, scores.value(row, 7));
            try writer.print(",\"passed\":{},\"submitted_at\":{d},\"set_id\":{d},\"map_id\":{d},\"artist\":", .{ try scores.boolean(row, 8), try scores.int(i64, row, 9), try scores.int(i32, row, 10), try scores.int(i32, row, 11) });
            try jsonString(writer, scores.value(row, 12));
            try writer.writeAll(",\"title\":");
            try jsonString(writer, scores.value(row, 13));
            try writer.writeAll(",\"version\":");
            try jsonString(writer, scores.value(row, 14));
            try writer.print(",\"status\":{d},\"client\":", .{try scores.int(i8, row, 15)});
            try jsonString(writer, scores.value(row, 16));
            try writer.writeAll(",\"mods_json\":");
            if (scores.isNull(row, 17)) {
                try writer.writeAll("null");
            } else {
                try writer.writeAll(scores.value(row, 17));
            }
            if (include_weight) {
                const percentage = 100.0 * std.math.pow(f64, 0.95, @floatFromInt(row));
                const weighted_pp = try scores.float(f64, row, 2) * percentage / 100.0;
                try writer.print(",\"weight\":{{\"percentage\":{d:.2},\"pp\":{d:.2}}}", .{ percentage, weighted_pp });
            }
            try writer.print(",\"has_replay\":{},\"star_rating\":{d}}}", .{ try scores.boolean(row, 18), try scores.float(f64, row, 19) });
        }
        try writer.writeByte(']');
    }

    pub fn siteProfile(self: *Store, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        var score_mode_buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const score_mode = domain.siteScoreMode(stats_mode);
        const score_mode_text = try std.fmt.bufPrint(&score_mode_buf, "{d}", .{score_mode});
        const namespace = domain.siteNamespace(source, stats_mode);
        var lease = self.pool.acquire();
        defer lease.release();
        var user = try postgres.queryParams(allocator, lease.conn, "SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,u.created_at,u.bio,u.preferred_mode,u.profile_source,coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.profile_title,u.profile_pronouns,u.profile_location,u.profile_website,u.profile_accent,u.show_profile_stats,u.show_recent_scores,coalesce((SELECT updated_at FROM zigcho.user_banners b WHERE b.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0) FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1 AND u.id!=3 AND NOT u.restricted", &.{id});
        defer user.deinit();
        if (user.rows() == 0) return null;
        var stats = try postgres.queryParams(allocator, lease.conn, "SELECT s.mode,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,(SELECT count(*)+1 FROM zigcho.stats r JOIN zigcho.users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND ru.id!=3 AND NOT ru.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM zigcho.stats s WHERE s.user_id=$1 ORDER BY s.mode", &.{id});
        defer stats.deinit();
        const stable_stats_sql =
            "WITH source_scores AS (SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.time_elapsed/1000 play_time,b.status,b.id beatmap_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.mode=$2 AND s.rank_namespace=$3)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
            "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
            "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=$1";
        const lazer_stats_sql =
            "WITH source_scores AS (SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,greatest(b.total_length,0) play_time,b.status,s.beatmap_id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$2 AND s.rank_namespace=$3)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
            "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
            "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=$1";
        var selected_stats = switch (source) {
            .all => try postgres.queryParams(allocator, lease.conn, "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.accuracy,s.max_combo,(SELECT count(*)+1 FROM zigcho.stats r JOIN zigcho.users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND ru.id!=3 AND NOT ru.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM zigcho.stats s WHERE s.user_id=$1 AND s.mode=$2 AND s.plays>0", &.{ id, score_mode_text }),
            .stable, .scorev2 => try postgres.queryParams(allocator, lease.conn, stable_stats_sql, &.{ id, score_mode_text, namespace }),
            .lazer => try postgres.queryParams(allocator, lease.conn, lazer_stats_sql, &.{ id, score_mode_text, namespace }),
        };
        defer selected_stats.deinit();
        const stable_columns = "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 ";
        const lazer_columns = "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id ";
        const pinned_sql: [:0]const u8 = switch (source) {
            .all => "WITH pinned_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,pinned_at) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating),p.pinned_at FROM zigcho.profile_score_pins p JOIN zigcho.scores s ON p.source='stable' AND s.id=p.score_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE p.user_id=$1 AND p.mode=$2 AND p.rank_namespace=$3 AND s.passed UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating),p.pinned_at FROM zigcho.profile_score_pins p JOIN zigcho.lazer_scores s ON p.source='lazer' AND s.id=p.score_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE p.user_id=$1 AND p.mode=$2 AND p.rank_namespace=$3 AND s.passed) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating FROM pinned_scores ORDER BY pinned_at DESC,client,id DESC LIMIT 3",
            .stable, .scorev2 => stable_columns ++ "JOIN zigcho.profile_score_pins p ON p.source='stable' AND p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
            .lazer => lazer_columns ++ "JOIN zigcho.profile_score_pins p ON p.source='lazer' AND p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
        };
        const top_sql: [:0]const u8 = switch (source) {
            .all => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,beatmap_key) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating),b.id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4) UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating),b.id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4))," ++
                "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) map_place FROM candidates) " ++
                "SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_key ASC,id ASC LIMIT 100",
            .stable, .scorev2 => "WITH candidates AS (" ++ stable_columns ++ "WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
            .lazer => "WITH candidates AS (" ++ lazer_columns ++ "WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
        };
        const recent_sql: [:0]const u8 = switch (source) {
            .all => "WITH recent_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3) " ++
                "SELECT * FROM recent_scores ORDER BY submitted_at DESC,client ASC,id DESC LIMIT 20",
            .lazer => lazer_columns ++ "WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 ORDER BY s.id DESC LIMIT 20",
            .stable, .scorev2 => stable_columns ++ "WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 ORDER BY s.id DESC LIMIT 20",
        };
        const first_sql: [:0]const u8 = switch (source) {
            .all => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,beatmap_key,user_id) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating),b.id,s.user_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating),b.id,s.user_id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted)," ++
                "per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=$1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,first_count FROM firsts ORDER BY submitted_at DESC,client,id DESC LIMIT 20",
            .stable, .scorev2 => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,beatmap_key,user_id) AS (SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating),b.id,s.user_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted),per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=$1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,first_count FROM firsts ORDER BY submitted_at DESC,id DESC LIMIT 20",
            .lazer => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,beatmap_key,user_id) AS (SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND coalesce(octet_length(s.replay),0)>0,coalesce(nullif(s.star_rating,0),b.star_rating),b.id,s.user_id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted),per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=$1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,first_count FROM firsts ORDER BY submitted_at DESC,id DESC LIMIT 20",
        };
        var pinned = try postgres.queryParams(allocator, lease.conn, pinned_sql, &.{ id, score_mode_text, namespace });
        defer pinned.deinit();
        var top = try postgres.queryParams(allocator, lease.conn, top_sql, &.{ id, score_mode_text, namespace });
        defer top.deinit();
        var recent = try postgres.queryParams(allocator, lease.conn, recent_sql, &.{ id, score_mode_text, namespace });
        defer recent.deinit();
        var firsts = try postgres.queryParams(allocator, lease.conn, first_sql, &.{ id, score_mode_text, namespace });
        defer firsts.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"id\":{d},\"name\":", .{try user.int(i32, 0, 0)});
        try jsonString(&output.writer, user.value(0, 1));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, user.value(0, 2));
        try output.writer.print(",\"privileges\":{d},\"created_at\":{d},\"bio\":", .{ try user.int(u32, 0, 3), try user.int(i64, 0, 4) });
        try jsonString(&output.writer, user.value(0, 5));
        try output.writer.writeAll(",\"profile_source\":");
        try jsonString(&output.writer, user.value(0, 7));
        try output.writer.print(",\"preferred_mode\":{d},\"avatar_version\":{d},\"profile_title\":", .{ try user.int(u8, 0, 6), try user.int(i64, 0, 8) });
        try jsonString(&output.writer, user.value(0, 9));
        try output.writer.writeAll(",\"profile_pronouns\":");
        try jsonString(&output.writer, user.value(0, 10));
        try output.writer.writeAll(",\"profile_location\":");
        try jsonString(&output.writer, user.value(0, 11));
        try output.writer.writeAll(",\"profile_website\":");
        try jsonString(&output.writer, user.value(0, 12));
        try output.writer.writeAll(",\"profile_accent\":");
        try jsonString(&output.writer, user.value(0, 13));
        const banner_version = try user.int(i64, 0, 16);
        try output.writer.writeAll(",\"banner_url\":");
        if (banner_version > 0) try output.writer.print("\"https://assets.kai.ovh/banners/{d}/cover.jpg?v={d}\"", .{ user_id, banner_version }) else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"team\":");
        if (user.isNull(0, 17)) {
            try output.writer.writeAll("null");
        } else {
            const team_id = try user.int(i32, 0, 17);
            try output.writer.print("{{\"id\":{d},\"name\":", .{team_id});
            try jsonString(&output.writer, user.value(0, 18));
            try output.writer.writeAll(",\"short_name\":");
            try jsonString(&output.writer, user.value(0, 19));
            const flag_version = try user.int(i64, 0, 20);
            try output.writer.writeAll(",\"flag_url\":");
            if (flag_version > 0) try output.writer.print("\"https://assets.kai.ovh/teams/{d}/flag?v={d}\"", .{ team_id, flag_version }) else try output.writer.writeAll("null");
            try output.writer.writeByte('}');
        }
        const show_profile_stats = try user.boolean(0, 14);
        const show_recent_scores = try user.boolean(0, 15);
        try output.writer.print(",\"stats_public\":{},\"recent_scores_public\":{},\"selected_source\":\"{s}\",\"stats_source\":\"{s}\",\"selected_mode\":{d},\"selected_stats\":", .{ show_profile_stats, show_recent_scores, @tagName(source), if (source == .all) "combined" else @tagName(source), stats_mode });
        if (!show_profile_stats or selected_stats.rows() == 0) {
            try output.writer.writeAll("null");
        } else {
            const total_score = @max(@as(i64, 0), try selected_stats.int(i64, 0, 1));
            const level_current = @min(@as(i64, 100), @divFloor(total_score, 1_000_000) + 1);
            const level_progress = @divFloor(@mod(total_score, 1_000_000) * 100, 1_000_000);
            const global_rank = try selected_stats.int(i32, 0, 7);
            try output.writer.print("{{\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d},\"level_current\":{d},\"level_progress\":{d},\"rank_history\":[", .{ try selected_stats.int(i64, 0, 0), total_score, try selected_stats.int(i32, 0, 2), try selected_stats.int(i32, 0, 3), try selected_stats.int(i32, 0, 4), try selected_stats.float(f64, 0, 5), try selected_stats.int(i32, 0, 6), global_rank, level_current, level_progress });
            for (0..90) |index| {
                if (index != 0) try output.writer.writeByte(',');
                try output.writer.print("{d}", .{if (global_rank > 0 and index >= 88) global_rank else 0});
            }
            try output.writer.writeAll("]}");
        }
        try output.writer.writeAll(",\"stats\":[");
        for (0..if (show_profile_stats) stats.rows() else 0) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"mode\":{d},\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"total_hits\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d}}}", .{ try stats.int(u8, row, 0), try stats.int(i64, row, 1), try stats.int(i64, row, 2), try stats.int(i32, row, 3), try stats.int(i32, row, 4), try stats.int(i32, row, 5), try stats.int(i64, row, 6), try stats.float(f64, row, 7), try stats.int(i32, row, 8), try stats.int(i32, row, 9) });
        }
        try output.writer.writeAll("],\"pinned_scores\":");
        try writeSiteScores(&output.writer, &pinned, false);
        try output.writer.writeAll(",\"top_scores\":");
        try writeSiteScores(&output.writer, &top, true);
        try output.writer.writeAll(",\"recent_scores\":");
        if (show_recent_scores) try writeSiteScores(&output.writer, &recent, false) else try output.writer.writeAll("[]");
        const first_count: i64 = if (firsts.rows() == 0) 0 else try firsts.int(i64, 0, 20);
        try output.writer.print(",\"first_place_count\":{d},\"first_place_scores\":", .{first_count});
        try writeSiteScores(&output.writer, &firsts, false);
        try output.writer.writeAll(",\"beatmapsets\":[");
        var mapped_sets = try postgres.queryParams(allocator, lease.conn, "SELECT set_id FROM zigcho.beatmap_submissions WHERE owner_id=$1 AND state='published' ORDER BY updated_at DESC,set_id DESC LIMIT 50", &.{id});
        defer mapped_sets.deinit();
        var mapped_written: usize = 0;
        for (0..mapped_sets.rows()) |row| {
            var mapped_set: std.Io.Writer.Allocating = .init(allocator);
            defer mapped_set.deinit();
            if (!try self.appendLazerSet(lease.conn, &mapped_set.writer, try mapped_sets.int(i32, row, 0), user_id)) continue;
            if (mapped_written != 0) try output.writer.writeByte(',');
            mapped_written += 1;
            try output.writer.writeAll(mapped_set.written());
        }
        try output.writer.writeByte(']');
        try output.writer.writeAll(",\"achievements\":");
        try self.writeUserAchievementsWithConnection(allocator, lease.conn, &output.writer, user_id, true);
        try output.writer.writeByte('}');
        var list = output.toArrayList();
        return try list.toOwnedSlice(allocator);
    }

    pub fn siteBeatmapLeaderboard(self: *Store, allocator: std.mem.Allocator, map_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
        var map_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        const map_text = try std.fmt.bufPrint(&map_buf, "{d}", .{map_id});
        const score_mode = domain.siteScoreMode(stats_mode);
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{score_mode});
        const namespace = domain.siteNamespace(source, stats_mode);
        const source_name = @tagName(source);
        const uses_pp = std.mem.eql(u8, namespace, "relax") or std.mem.eql(u8, namespace, "autopilot");
        var lease = self.pool.acquire();
        defer lease.release();
        var map = try postgres.queryParams(allocator, lease.conn, "SELECT mode FROM zigcho.beatmaps WHERE id=$1", &.{map_text});
        defer map.deinit();
        if (map.rows() == 0 or try map.int(u8, 0, 0) != score_mode) return null;
        const sql =
            "WITH candidates(id,user_id,name,country,privileges,total_score,pp,accuracy,max_combo,mods,mode,rank_namespace,submitted_at,client,mods_json,has_replay) AS (" ++
            "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.submitted_at,'stable',NULL::text,coalesce(octet_length(s.replay),0)>0 FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE b.id=$1 AND b.status>=3 AND s.mode=$2 AND s.rank_namespace=$4 AND s.passed AND NOT u.restricted AND u.id!=3 AND ($3='all' OR $3='stable' OR $3='scorev2') AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') UNION ALL " ++
            "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.submitted_at,'lazer',s.mods_json::text,coalesce(octet_length(s.replay),0)>0 FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.beatmap_id=$1 AND b.status>=3 AND s.ruleset_id=$2 AND s.rank_namespace=$4 AND s.passed AND NOT u.restricted AND u.id!=3 AND ($3='all' OR $3='lazer') AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto'))," ++
            "per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN $5::boolean THEN pp ELSE total_score::double precision END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) user_place FROM candidates)," ++
            "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN $5::boolean THEN pp ELSE total_score::double precision END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) position FROM per_user WHERE user_place=1) " ++
            "SELECT position,id,user_id,name,country,privileges,total_score,pp,accuracy,max_combo,mods,rank_namespace,submitted_at,client,mods_json,has_replay FROM board ORDER BY position LIMIT 100";
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ map_text, mode_text, source_name, namespace, if (uses_pp) "true" else "false" });
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"map_id\":{d},\"source\":\"{s}\",\"mode\":{d},\"namespace\":", .{ map_id, source_name, stats_mode });
        try jsonString(&output.writer, namespace);
        try output.writer.writeAll(",\"scores\":[");
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"rank\":{d},\"id\":{d},\"user_id\":{d},\"name\":", .{ try result.int(i32, row, 0), try result.int(i64, row, 1), try result.int(i32, row, 2) });
            try jsonString(&output.writer, result.value(row, 3));
            try output.writer.writeAll(",\"country\":");
            try jsonString(&output.writer, result.value(row, 4));
            try output.writer.print(",\"privileges\":{d},\"score\":{d},\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"namespace\":", .{ try result.int(u32, row, 5), try result.int(i64, row, 6), try result.float(f64, row, 7), try result.float(f64, row, 8), try result.int(i32, row, 9), try result.int(i32, row, 10) });
            try jsonString(&output.writer, result.value(row, 11));
            try output.writer.print(",\"submitted_at\":{d},\"client\":", .{try result.int(i64, row, 12)});
            try jsonString(&output.writer, result.value(row, 13));
            try output.writer.writeAll(",\"mods_json\":");
            if (result.isNull(row, 14)) try output.writer.writeAll("null") else try output.writer.writeAll(result.value(row, 14));
            try output.writer.print(",\"has_replay\":{}}}", .{try result.boolean(row, 15)});
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return @as(?[]u8, try list.toOwnedSlice(allocator));
    }

    fn replayData(self: *Store, allocator: std.mem.Allocator, source: ReplaySource, score_id: i64, public_only: bool) !?[]u8 {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
        const stored = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            const sql = switch (source) {
                .stable => if (public_only)
                    "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.replay_objects r ON r.source='stable' AND r.score_id=s.id WHERE s.id=$1 AND s.passed AND u.id!=3 AND NOT u.restricted AND (coalesce(octet_length(s.replay),0)>0 OR r.object_key IS NOT NULL)"
                else
                    "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM zigcho.scores s LEFT JOIN zigcho.replay_objects r ON r.source='stable' AND r.score_id=s.id WHERE s.id=$1 AND s.passed AND (coalesce(octet_length(s.replay),0)>0 OR r.object_key IS NOT NULL)",
                .lazer => "SELECT s.replay,r.object_key,r.etag,r.object_bytes FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.replay_objects r ON r.source='lazer' AND r.score_id=s.id WHERE s.id=$1 AND s.passed AND u.id!=3 AND NOT u.restricted AND (coalesce(octet_length(s.replay),0)>0 OR r.object_key IS NOT NULL)",
            };
            var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{id});
            defer result.deinit();
            if (result.rows() == 0) break :blk null;
            const fallback = if (result.isNull(0, 0)) null else try postgres.decodeBytea(allocator, result.value(0, 0));
            errdefer if (fallback) |data| allocator.free(data);
            const object_key = if (result.isNull(0, 1)) null else try allocator.dupe(u8, result.value(0, 1));
            errdefer if (object_key) |key| allocator.free(key);
            var etag: [64]u8 = undefined;
            if (object_key != null) {
                const value = result.value(0, 2);
                if (value.len != etag.len) return error.InvalidReplayObject;
                @memcpy(&etag, value);
            }
            break :blk .{ .fallback = fallback, .object_key = object_key, .etag = etag, .object_bytes = if (result.isNull(0, 3)) 0 else try result.int(usize, 0, 3) };
        } orelse return null;
        defer if (stored.object_key) |key| allocator.free(key);
        if (stored.object_key) |key| if (self.object_store.enabled() and stored.object_bytes > 0 and stored.object_bytes <= max_replay_object_bytes) {
            if (self.object_store.getWithLimit(allocator, self.io, key, "application/octet-stream", stored.object_bytes)) |data| {
                if (data.len == stored.object_bytes and object_keys.matchesSha256(data, &stored.etag)) {
                    if (stored.fallback) |fallback| allocator.free(fallback);
                    return data;
                }
                allocator.free(data);
                std.log.warn("event=replay_object_invalid source={s} score_id={d}", .{ source.text(), score_id });
            } else |err| std.log.warn("event=replay_object_read_failed source={s} score_id={d} error={t}", .{ source.text(), score_id, err });
        };
        return stored.fallback;
    }

    pub fn siteReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
        const metadata: site_replay.Header = (blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(allocator, lease.conn, "SELECT s.id,u.name,s.map_md5,s.mode,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.score,s.max_combo,s.perfect,s.mods,s.submitted_at FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1 AND s.passed AND u.id!=3 AND NOT u.restricted AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects r WHERE r.source='stable' AND r.score_id=s.id))", &.{id});
            defer result.deinit();
            if (result.rows() == 0) break :blk null;
            const username = try allocator.dupe(u8, result.value(0, 1));
            errdefer allocator.free(username);
            const map_md5 = try allocator.dupe(u8, result.value(0, 2));
            errdefer allocator.free(map_md5);
            break :blk site_replay.Header{
                .score_id = try result.int(i64, 0, 0),
                .username = username,
                .map_md5 = map_md5,
                .mode = try result.int(u8, 0, 3),
                .n300 = try result.int(i32, 0, 4),
                .n100 = try result.int(i32, 0, 5),
                .n50 = try result.int(i32, 0, 6),
                .ngeki = try result.int(i32, 0, 7),
                .nkatu = try result.int(i32, 0, 8),
                .nmiss = try result.int(i32, 0, 9),
                .score = try result.int(i64, 0, 10),
                .max_combo = try result.int(i32, 0, 11),
                .perfect = try result.boolean(0, 12),
                .mods = try result.int(i32, 0, 13),
                .submitted_at = try result.int(i64, 0, 14),
            };
        }) orelse return null;
        defer allocator.free(metadata.username);
        defer allocator.free(metadata.map_md5);
        const frames = (try self.replayData(allocator, .stable, score_id, true)) orelse return null;
        defer allocator.free(frames);
        return @as(?[]u8, try site_replay.build(allocator, metadata, frames));
    }

    pub fn lazerReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        return self.replayData(allocator, .lazer, score_id, true);
    }

    pub fn lazerUserScoreCounts(self: *Store, user_id: i32, ruleset_id: u8, source: domain.SiteScoreSource) !domain.UserScoreCounts {
        if (source == .scorev2) return error.InvalidScoreSource;
        var user_buf: [24]u8 = undefined;
        var ruleset_buf: [4]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const ruleset = try std.fmt.bufPrint(&ruleset_buf, "{d}", .{ruleset_id});
        const source_name = @tagName(source);
        var lease = self.pool.acquire();
        defer lease.release();
        const sql =
            "SELECT " ++
            "(SELECT count(*) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE $3!='stable' AND s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4))+(SELECT count(*) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE $3!='lazer' AND s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4))," ++
            "(SELECT count(*) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE $3!='stable' AND s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.lazer_scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id))))+(SELECT count(*) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE $3!='lazer' AND s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.score>s.score OR (o.score=s.score AND o.id<s.id))))," ++
            "(SELECT count(*) FROM zigcho.lazer_scores WHERE $3!='stable' AND user_id=$1 AND ruleset_id=$2)+(SELECT count(*) FROM zigcho.scores WHERE $3!='lazer' AND user_id=$1 AND mode=$2)," ++
            "(SELECT count(*) FROM zigcho.profile_score_pins p WHERE p.user_id=$1 AND p.mode=$2 AND ($3='all' OR p.source=$3))";
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ user, ruleset, source_name });
        defer result.deinit();
        return .{
            .best = try result.int(i32, 0, 0),
            .firsts = try result.int(i32, 0, 1),
            .recent = try result.int(i32, 0, 2),
            .pinned = try result.int(i32, 0, 3),
        };
    }

    pub fn lazerRecentActivityJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, offset: u16, limit: u8) ![]u8 {
        if (limit == 0 or limit > 100) return error.InvalidScoreLimit;
        var user_buf: [24]u8 = undefined;
        var limit_buf: [8]u8 = undefined;
        var offset_buf: [16]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        const sql =
            "WITH all_scores AS (" ++
            "SELECT s.id,'lazer'::text source,s.user_id,s.ruleset_id mode,s.pp,s.rank,0 mods,s.accuracy,0 n300,0 n100,0 n50,0 nmiss,s.submitted_at,b.id map_id,b.set_id,b.artist,b.title,b.version FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.passed AND NOT u.restricted " ++
            "UNION ALL SELECT s.id,'stable',s.user_id,s.mode,s.pp,''::text,s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss,s.submitted_at,b.id,b.set_id,b.artist,b.title,b.version FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE s.passed AND NOT u.restricted)," ++
            "best AS (SELECT user_id,map_id,mode,max(pp) pp FROM all_scores GROUP BY user_id,map_id,mode) " ++
            "SELECT a.id,a.source,a.mode,a.rank,a.mods,a.accuracy,a.n300,a.n100,a.n50,a.nmiss,to_char(to_timestamp(a.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),a.map_id,a.set_id,a.artist,a.title,a.version,u.name,1+(SELECT count(*) FROM best b WHERE b.map_id=a.map_id AND b.mode=a.mode AND b.pp>a.pp) placement FROM all_scores a JOIN zigcho.users u ON u.id=a.user_id WHERE a.user_id=$1 ORDER BY a.submitted_at DESC,a.source ASC,a.id DESC LIMIT $2 OFFSET $3";
        var lease = self.pool.acquire();
        defer lease.release();
        var rows = try postgres.queryParams(allocator, lease.conn, sql, &.{ user, limit_text, offset_text });
        defer rows.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        for (0..rows.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            const stable = std.mem.eql(u8, rows.value(row, 1), "stable");
            const mode = try rows.int(u8, row, 2);
            const rank = if (stable) sqlite_storage.Store.stableGrade(mode, try rows.int(i32, row, 4), try rows.float(f64, row, 5), try rows.int(i32, row, 6), try rows.int(i32, row, 7), try rows.int(i32, row, 8), try rows.int(i32, row, 9)) else rows.value(row, 3);
            try output.writer.print("{{\"id\":{d},\"createdAt\":", .{@as(i64, @intCast(row + 1 + offset))});
            try jsonString(&output.writer, rows.value(row, 10));
            try output.writer.writeAll(",\"type\":\"rank\",\"scoreRank\":");
            try jsonString(&output.writer, rank);
            try output.writer.print(",\"rank\":{d},\"mode\":", .{try rows.int(i32, row, 17)});
            try jsonString(&output.writer, switch (mode) {
                0 => "osu",
                1 => "taiko",
                2 => "fruits",
                3 => "mania",
                else => "osu",
            });
            var title_buf: [768]u8 = undefined;
            const map_title = try std.fmt.bufPrint(&title_buf, "{s} - {s} [{s}]", .{ rows.value(row, 13), rows.value(row, 14), rows.value(row, 15) });
            try output.writer.writeAll(",\"beatmap\":{\"title\":");
            try jsonString(&output.writer, map_title);
            try output.writer.print(",\"url\":\"/b/{d}\"}},\"beatmapset\":{{\"title\":", .{try rows.int(i32, row, 11)});
            var set_title_buf: [512]u8 = undefined;
            const set_title = try std.fmt.bufPrint(&set_title_buf, "{s} - {s}", .{ rows.value(row, 13), rows.value(row, 14) });
            try jsonString(&output.writer, set_title);
            try output.writer.print(",\"url\":\"/beatmapsets/{d}\"}},\"user\":{{\"username\":", .{try rows.int(i32, row, 12)});
            try jsonString(&output.writer, rows.value(row, 16));
            try output.writer.print(",\"url\":\"/users/{d}\",\"previousUsername\":null}}}}", .{user_id});
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerUserScoresJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8, kind: lazer.UserScoreKind, source: domain.SiteScoreSource, offset: u16, limit: u8) ![]u8 {
        if (limit == 0 or limit > 100) return error.InvalidScoreLimit;
        if (source == .scorev2) return error.InvalidScoreSource;
        var buffers: [4][24]u8 = undefined;
        const user = try std.fmt.bufPrint(&buffers[0], "{d}", .{user_id});
        const ruleset = try std.fmt.bufPrint(&buffers[1], "{d}", .{ruleset_id});
        const limit_text = try std.fmt.bufPrint(&buffers[2], "{d}", .{limit});
        const offset_text = try std.fmt.bufPrint(&buffers[3], "{d}", .{offset});
        const filters = switch (kind) {
            .best => .{
                "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)",
                "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)",
                "pp DESC,submitted_epoch DESC,id DESC",
            },
            .firsts => .{
                "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.lazer_scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id)))",
                "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.score>s.score OR (o.score=s.score AND o.id<s.id)))",
                "submitted_epoch DESC,id DESC",
            },
            .recent => .{ "", "", "submitted_epoch DESC,id DESC" },
            .pinned => .{
                "AND EXISTS(SELECT 1 FROM zigcho.profile_score_pins p WHERE p.user_id=s.user_id AND p.source='lazer' AND p.score_id=s.id)",
                "AND EXISTS(SELECT 1 FROM zigcho.profile_score_pins p WHERE p.user_id=s.user_id AND p.source='stable' AND p.score_id=s.id)",
                "submitted_epoch DESC,id DESC",
            },
        };
        const sql = try std.fmt.allocPrintSentinel(allocator,
            \\SELECT * FROM (
            \\SELECT 'lazer'::text source,s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,coalesce(s.legacy_total_score,s.total_score) total_without,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,s.passed AND coalesce(octet_length(s.replay),0)>0 has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,false perfect
            \\FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 {s} {s}
            \\UNION ALL
            \\SELECT 'stable'::text source,4000000000000000000+s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,s.pp,s.accuracy,s.max_combo,s.passed,''::text rank,'[]'::text mods_json,'{{}}'::text statistics_json,'{{}}'::text maximum_statistics_json,'[]'::text pauses_json,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,s.passed AND coalesce(octet_length(s.replay),0)>0 has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect
            \\FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 {s} {s}
            \\) combined ORDER BY {s} LIMIT $3 OFFSET $4
        , .{ filters[0], if (source == .stable) "AND false" else "", filters[1], if (source == .lazer) "AND false" else "", filters[2] }, 0);
        defer allocator.free(sql);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ user, ruleset, limit_text, offset_text });
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            const stable = std.mem.eql(u8, result.value(row, 0), "stable");
            const status = try result.int(i32, row, 20);
            var mods: std.Io.Writer.Allocating = .init(allocator);
            defer mods.deinit();
            var statistics: std.Io.Writer.Allocating = .init(allocator);
            defer statistics.deinit();
            if (stable) {
                try stable_mods.writeLazerJson(&mods.writer, try result.int(i32, row, 31), true);
                try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, try result.int(i32, row, 32), try result.int(i32, row, 33), try result.int(i32, row, 34), try result.int(i32, row, 35), try result.int(i32, row, 36), try result.int(i32, row, 37));
            }
            try lazer.writeLeaderboardScore(&output.writer, .{
                .id = try result.int(i64, row, 1),
                .legacy_score_id = if (stable) lazer.decodeStableScoreId(try result.int(i64, row, 1)) else null,
                .legacy_total_score = if (stable) try result.int(i64, row, 7) else null,
                .user_id = try result.int(i32, row, 2),
                .username = result.value(row, 3),
                .country = result.value(row, 4),
                .beatmap_id = try result.int(i32, row, 5),
                .ruleset_id = try result.int(i32, row, 6),
                .total_score = try result.int(i64, row, 7),
                .total_score_without_mods = try result.int(i64, row, 8),
                .pp = try result.float(f64, row, 9),
                .accuracy = try result.float(f64, row, 10),
                .max_combo = try result.int(i32, row, 11),
                .passed = try result.boolean(row, 12),
                .rank = if (stable) sqlite_storage.Store.stableGrade(ruleset_id, try result.int(i32, row, 31), try result.float(f64, row, 10), try result.int(i32, row, 32), try result.int(i32, row, 33), try result.int(i32, row, 34), try result.int(i32, row, 37)) else result.value(row, 13),
                .mods_json = if (stable) mods.written() else result.value(row, 14),
                .statistics_json = if (stable) statistics.written() else result.value(row, 15),
                .maximum_statistics_json = result.value(row, 16),
                .pauses_json = result.value(row, 17),
                .ended_at = result.value(row, 18),
                .ranked = status == 3 or status == 4,
                .has_replay = try result.boolean(row, 30),
                .beatmap = .{
                    .id = try result.int(i32, row, 5),
                    .set_id = try result.int(i32, row, 21),
                    .status = lazerStatus(status),
                    .checksum = result.value(row, 22),
                    .ruleset_id = try result.int(i32, row, 23),
                    .star_rating = try result.float(f64, row, 24),
                    .version = result.value(row, 25),
                    .artist = result.value(row, 26),
                    .title = result.value(row, 27),
                    .creator = result.value(row, 28),
                },
            });
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    fn stableClassicLeaderboardJson(self: *Store, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, limit: u8) ![]u8 {
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const requester = try param(&buffers, &cursor, requester_id);
        const beatmap_text = try param(&buffers, &cursor, beatmap_id);
        const ruleset = try param(&buffers, &cursor, ruleset_id);
        const limit_text = try param(&buffers, &cursor, limit);
        var lease = self.pool.acquire();
        defer lease.release();
        const sql =
            "WITH ordered AS (" ++
            "SELECT s.*,b.status,b.set_id,b.id beatmap_id,b.star_rating AS beatmap_star_rating,b.version,b.artist,b.title,b.creator,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version,row_number() OVER(PARTITION BY s.user_id ORDER BY s.score DESC,s.id ASC) AS user_place " ++
            "FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 " ++
            "WHERE b.id=$1 AND b.status>=3 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND NOT u.restricted)," ++
            "board AS (SELECT *,row_number() OVER(ORDER BY score DESC,id ASC) AS position,count(*) OVER() AS score_count FROM ordered WHERE user_place=1) " ++
            "SELECT position,score_count,id,user_id,(SELECT name FROM zigcho.users WHERE id=board.user_id),(SELECT country FROM zigcho.users WHERE id=board.user_id),beatmap_id,mode,score,pp,accuracy,max_combo,n300,n100,n50,ngeki,nkatu,nmiss,perfect,mods,to_char(to_timestamp(submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),status,set_id,map_md5,beatmap_star_rating,version,artist,title,creator,team_id,team_name,team_short_name,team_flag_version " ++
            "FROM board WHERE position<=$3 OR user_id=$4 ORDER BY position";
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ beatmap_text, ruleset, limit_text, requester });
        defer result.deinit();

        var scores: std.Io.Writer.Allocating = .init(allocator);
        defer scores.deinit();
        var user_score: ?[]u8 = null;
        defer if (user_score) |json| allocator.free(json);
        var score_count: i64 = 0;
        var written: usize = 0;
        for (0..result.rows()) |row| {
            const position = try result.int(i64, row, 0);
            score_count = try result.int(i64, row, 1);
            var mods: std.Io.Writer.Allocating = .init(allocator);
            defer mods.deinit();
            const mod_bits = try result.int(i32, row, 19);
            try stable_mods.writeLazerJson(&mods.writer, mod_bits, true);
            var statistics: std.Io.Writer.Allocating = .init(allocator);
            defer statistics.deinit();
            const n300 = try result.int(i32, row, 12);
            const n100 = try result.int(i32, row, 13);
            const n50 = try result.int(i32, row, 14);
            const ngeki = try result.int(i32, row, 15);
            const nkatu = try result.int(i32, row, 16);
            const nmiss = try result.int(i32, row, 17);
            try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, n300, n100, n50, ngeki, nkatu, nmiss);
            const status = try result.int(i32, row, 21);
            const score: lazer.LeaderboardScore = .{
                .id = try result.int(i64, row, 2),
                .legacy_score_id = try result.int(i64, row, 2),
                .legacy_total_score = try result.int(i64, row, 8),
                .user_id = try result.int(i32, row, 3),
                .username = result.value(row, 4),
                .country = result.value(row, 5),
                .beatmap_id = try result.int(i32, row, 6),
                .ruleset_id = try result.int(i32, row, 7),
                .total_score = try result.int(i64, row, 8),
                .total_score_without_mods = try result.int(i64, row, 8),
                .pp = try result.float(f64, row, 9),
                .accuracy = try result.float(f64, row, 10),
                .max_combo = try result.int(i32, row, 11),
                .passed = true,
                .rank = sqlite_storage.Store.stableGrade(ruleset_id, mod_bits, try result.float(f64, row, 10), n300, n100, n50, nmiss),
                .mods_json = mods.written(),
                .statistics_json = statistics.written(),
                .maximum_statistics_json = "{}",
                .pauses_json = "[]",
                .ended_at = result.value(row, 20),
                .ranked = status == 3 or status == 4,
                .has_replay = false,
                .team = if (result.isNull(row, 29)) null else try domain.TeamSummary.init(try result.int(i32, row, 29), result.value(row, 30), result.value(row, 31), try result.int(i64, row, 32)),
                .beatmap = .{
                    .id = try result.int(i32, row, 6),
                    .set_id = try result.int(i32, row, 22),
                    .status = lazerStatus(status),
                    .checksum = result.value(row, 23),
                    .ruleset_id = ruleset_id,
                    .star_rating = try result.float(f64, row, 24),
                    .version = result.value(row, 25),
                    .artist = result.value(row, 26),
                    .title = result.value(row, 27),
                    .creator = result.value(row, 28),
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

    pub fn lazerLeaderboardJson(self: *Store, allocator: std.mem.Allocator, requester_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, exact_mods_json: []const u8, filter_mods: bool, classic: bool, requested_stable_mods: ?i32, scope: lazer.LeaderboardScope, limit: u8) ![]u8 {
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const requester = try param(&buffers, &cursor, requester_id);
        const beatmap_text = try param(&buffers, &cursor, beatmap_id);
        const ruleset = try param(&buffers, &cursor, ruleset_id);
        const limit_text = try param(&buffers, &cursor, limit);
        const filter = if (filter_mods) "true" else "false";
        const classic_only = if (classic) "true" else "false";
        const stable_supported = if (requested_stable_mods != null) "true" else "false";
        const stable_bits = try param(&buffers, &cursor, requested_stable_mods orelse 0);
        const namespace_name = @tagName(namespace);
        var lease = self.pool.acquire();
        defer lease.release();
        const sql =
            "WITH candidates AS (" ++
            "SELECT 'lazer'::text source,s.id source_id,s.id public_id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,coalesce(s.legacy_total_score,s.total_score) total_without,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') ended_at,b.status,s.passed AND coalesce(octet_length(s.replay),0)>0 has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,false perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,1 source_order,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version " ++
            "FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id " ++
            "WHERE s.beatmap_id=$1 AND b.status>=3 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND NOT u.restricted AND NOT $6::boolean AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') " ++
            "AND ($11='global' OR ($11='country' AND u.country=(SELECT country FROM zigcho.users WHERE id=$10)) OR ($11='friend' AND (s.user_id=$10 OR EXISTS(SELECT 1 FROM zigcho.friends f WHERE f.user_id=$10 AND f.friend_id=s.user_id))) OR ($11='team' AND tm.team_id IS NOT NULL AND tm.team_id=(SELECT team_id FROM zigcho.team_members WHERE user_id=$10))) " ++
            "AND (NOT $5::boolean OR (" ++
            "NOT EXISTS(SELECT upper(stored.value->>'acronym') FROM jsonb_array_elements(s.mods_json) stored WHERE $3!='custom' OR upper(stored.value->>'acronym') NOT IN('RX','AP') EXCEPT SELECT upper(value) FROM jsonb_array_elements_text($4::jsonb) WHERE $3!='custom' OR upper(value) NOT IN('RX','AP')) " ++
            "AND NOT EXISTS(SELECT upper(value) FROM jsonb_array_elements_text($4::jsonb) WHERE $3!='custom' OR upper(value) NOT IN('RX','AP') EXCEPT SELECT upper(stored.value->>'acronym') FROM jsonb_array_elements(s.mods_json) stored WHERE $3!='custom' OR upper(stored.value->>'acronym') NOT IN('RX','AP')))) " ++
            "UNION ALL " ++
            "SELECT 'stable'::text source,s.id source_id,4000000000000000000+s.id public_id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,s.pp,s.accuracy,s.max_combo,s.passed,''::text rank,'[]'::text mods_json,'{}'::text statistics_json,'{}'::text maximum_statistics_json,'[]'::text pauses_json,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') ended_at,b.status,s.passed AND coalesce(octet_length(s.replay),0)>0 has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,0 source_order,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version " ++
            "FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 " ++
            "WHERE b.id=$1 AND b.status>=3 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND NOT u.restricted AND $3!='custom' AND $7::boolean AND (NOT $5::boolean OR (s.mods & $12::integer)=$8) AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') " ++
            "AND ($11='global' OR ($11='country' AND u.country=(SELECT country FROM zigcho.users WHERE id=$10)) OR ($11='friend' AND (s.user_id=$10 OR EXISTS(SELECT 1 FROM zigcho.friends f WHERE f.user_id=$10 AND f.friend_id=s.user_id))) OR ($11='team' AND tm.team_id IS NOT NULL AND tm.team_id=(SELECT team_id FROM zigcho.team_members WHERE user_id=$10))))," ++
            "ordered AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN rank_namespace IN('vanilla','relax','autopilot') THEN pp ELSE total_score::double precision END DESC,source_order,source_id) user_place FROM candidates)," ++
            "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN rank_namespace IN('relax','autopilot') THEN pp ELSE total_score::double precision END DESC,source_order,source_id) position,count(*) OVER() score_count FROM ordered WHERE user_place=1) " ++
            "SELECT position,score_count,source,public_id,user_id,name,country,beatmap_id,ruleset_id,total_score,total_without,pp,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,ended_at,status,has_replay,stable_mods,n300,n100,n50,ngeki,nkatu,nmiss,perfect,set_id,md5,map_mode,star_rating,version,artist,title,creator,rank_namespace,team_id,team_name,team_short_name,team_flag_version " ++
            "FROM board WHERE position<=$9 OR user_id=$10 ORDER BY position";
        const gameplay_mask = try param(&buffers, &cursor, stable_mods.leaderboard_gameplay_mask);
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ beatmap_text, ruleset, namespace_name, exact_mods_json, filter, classic_only, stable_supported, stable_bits, limit_text, requester, @tagName(scope), gameplay_mask });
        defer result.deinit();

        var scores: std.Io.Writer.Allocating = .init(allocator);
        defer scores.deinit();
        var user_score: ?[]u8 = null;
        defer if (user_score) |json| allocator.free(json);
        var score_count: i64 = 0;
        var written: usize = 0;
        for (0..result.rows()) |row| {
            const position = try result.int(i64, row, 0);
            score_count = try result.int(i64, row, 1);
            const stable = std.mem.eql(u8, result.value(row, 2), "stable");
            var mods: std.Io.Writer.Allocating = .init(allocator);
            defer mods.deinit();
            var statistics: std.Io.Writer.Allocating = .init(allocator);
            defer statistics.deinit();
            if (stable) {
                try stable_mods.writeLazerJson(&mods.writer, try result.int(i32, row, 23), true);
                try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, try result.int(i32, row, 24), try result.int(i32, row, 25), try result.int(i32, row, 26), try result.int(i32, row, 27), try result.int(i32, row, 28), try result.int(i32, row, 29));
            }
            const score: lazer.LeaderboardScore = .{
                .id = try result.int(i64, row, 3),
                .legacy_score_id = if (stable) lazer.decodeStableScoreId(try result.int(i64, row, 3)) else null,
                .legacy_total_score = if (stable) try result.int(i64, row, 9) else null,
                .user_id = try result.int(i32, row, 4),
                .username = result.value(row, 5),
                .country = result.value(row, 6),
                .beatmap_id = try result.int(i32, row, 7),
                .ruleset_id = try result.int(i32, row, 8),
                .total_score = try result.int(i64, row, 9),
                .total_score_without_mods = try result.int(i64, row, 10),
                .pp = try result.float(f64, row, 11),
                .accuracy = try result.float(f64, row, 12),
                .max_combo = try result.int(i32, row, 13),
                .passed = try result.boolean(row, 14),
                .rank = if (stable) sqlite_storage.Store.stableGrade(ruleset_id, try result.int(i32, row, 23), try result.float(f64, row, 12), try result.int(i32, row, 24), try result.int(i32, row, 25), try result.int(i32, row, 26), try result.int(i32, row, 29)) else result.value(row, 15),
                .mods_json = if (stable) mods.written() else result.value(row, 16),
                .statistics_json = if (stable) statistics.written() else result.value(row, 17),
                .maximum_statistics_json = result.value(row, 18),
                .pauses_json = result.value(row, 19),
                .ended_at = result.value(row, 20),
                .ranked = (try result.int(i32, row, 21)) == 3 or (try result.int(i32, row, 21)) == 4,
                .has_replay = try result.boolean(row, 22),
                .team = if (result.isNull(row, 40)) null else try domain.TeamSummary.init(try result.int(i32, row, 40), result.value(row, 41), result.value(row, 42), try result.int(i64, row, 43)),
                .beatmap = .{
                    .id = try result.int(i32, row, 7),
                    .set_id = try result.int(i32, row, 31),
                    .status = lazerStatus(try result.int(i32, row, 21)),
                    .checksum = result.value(row, 32),
                    .ruleset_id = try result.int(i32, row, 33),
                    .star_rating = try result.float(f64, row, 34),
                    .version = result.value(row, 35),
                    .artist = result.value(row, 36),
                    .title = result.value(row, 37),
                    .creator = result.value(row, 38),
                },
            };
            if (position <= limit) {
                if (written != 0) try scores.writer.writeByte(',');
                try lazer.writeLeaderboardScore(&scores.writer, score);
                written += 1;
            }
            if (score.user_id == requester_id and (!stable or user_score == null)) {
                if (user_score) |json| allocator.free(json);
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

    pub fn lazerScoreJson(self: *Store, allocator: std.mem.Allocator, score_id: i64, beatmap_id: i32) !?[]u8 {
        var score_buf: [32]u8 = undefined;
        var map_buf: [24]u8 = undefined;
        const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        const map_text = try std.fmt.bufPrint(&map_buf, "{d}", .{beatmap_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,s.beatmap_id,s.ruleset_id,s.total_score,coalesce(s.legacy_total_score,s.total_score),s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),b.status,(s.passed AND (octet_length(s.replay)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id))),b.set_id,b.md5,b.mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.id=$1 AND s.beatmap_id=$2 AND NOT u.restricted", &.{ score_text, map_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        const status = try result.int(i32, 0, 18);
        const score: lazer.LeaderboardScore = .{
            .id = try result.int(i64, 0, 0),
            .user_id = try result.int(i32, 0, 1),
            .username = result.value(0, 2),
            .country = result.value(0, 3),
            .beatmap_id = try result.int(i32, 0, 4),
            .ruleset_id = try result.int(i32, 0, 5),
            .total_score = try result.int(i64, 0, 6),
            .total_score_without_mods = try result.int(i64, 0, 7),
            .pp = try result.float(f64, 0, 8),
            .accuracy = try result.float(f64, 0, 9),
            .max_combo = try result.int(i32, 0, 10),
            .passed = try result.boolean(0, 11),
            .rank = result.value(0, 12),
            .mods_json = result.value(0, 13),
            .statistics_json = result.value(0, 14),
            .maximum_statistics_json = result.value(0, 15),
            .pauses_json = result.value(0, 16),
            .ended_at = result.value(0, 17),
            .ranked = status == 3 or status == 4,
            .has_replay = try result.boolean(0, 19),
            .beatmap = .{
                .id = try result.int(i32, 0, 4),
                .set_id = try result.int(i32, 0, 20),
                .status = lazerStatus(status),
                .checksum = result.value(0, 21),
                .ruleset_id = try result.int(i32, 0, 22),
                .star_rating = try result.float(f64, 0, 23),
                .version = result.value(0, 24),
                .artist = result.value(0, 25),
                .title = result.value(0, 26),
                .creator = result.value(0, 27),
            },
        };
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try lazer.writeLeaderboardScore(&output.writer, score);
        return @as(?[]u8, try output.toOwnedSlice());
    }

    fn awardAchievementsWithConnection(self: *Store, conn: *postgres.c.PGconn, user_id: i32, source: []const u8, score_id: i64, input: achievements.Input) !void {
        var user_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        var score_buf: [32]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{input.mode});
        const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        var enriched = input;
        if (input.eligible) {
            var stats = try postgres.queryParams(self.allocator, conn, "SELECT s.plays,s.total_hits,CASE WHEN s.pp>0 THEN (SELECT count(*)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND u.id!=3 AND NOT u.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM zigcho.stats s WHERE s.user_id=$1 AND s.mode=$2", &.{ user, mode });
            defer stats.deinit();
            if (stats.rows() != 0) {
                enriched.plays = try stats.int(i64, 0, 0);
                enriched.total_hits = try stats.int(i64, 0, 1);
                enriched.global_rank = try stats.int(i64, 0, 2);
            }
        }
        const candidates = achievements.candidates(enriched);
        if (candidates.len == 0) return;
        for (candidates.slice()) |achievement_id| {
            var achievement_buf: [8]u8 = undefined;
            const achievement = try std.fmt.bufPrint(&achievement_buf, "{d}", .{achievement_id});
            var inserted = try postgres.queryParams(self.allocator, conn, "INSERT INTO zigcho.user_achievements(user_id,achievement_id,score_source,score_id) SELECT $1,$2,$3,$4 WHERE EXISTS(SELECT 1 FROM zigcho.users WHERE id=$1 AND NOT restricted) ON CONFLICT DO NOTHING", &.{ user, achievement, source, score });
            inserted.deinit();
        }
    }

    fn writeUserAchievementsWithConnection(_: *Store, allocator: std.mem.Allocator, conn: *postgres.c.PGconn, writer: *std.Io.Writer, user_id: i32, include_metadata: bool) !void {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var result = try postgres.queryParams(allocator, conn, "SELECT ua.achievement_id,to_char(to_timestamp(ua.achieved_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),(SELECT count(*) FROM zigcho.user_achievements all_ua JOIN zigcho.users all_users ON all_users.id=all_ua.user_id WHERE all_ua.achievement_id=ua.achievement_id AND NOT all_users.restricted),(SELECT count(*) FROM zigcho.users WHERE NOT restricted) FROM zigcho.user_achievements ua WHERE ua.user_id=$1 ORDER BY ua.achieved_at DESC,ua.achievement_id DESC", &.{user});
        defer result.deinit();
        try writer.writeByte('[');
        var first = true;
        for (0..result.rows()) |row| {
            const id = try result.int(u16, row, 0);
            if (achievements.byId(id) == null) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try achievements.writeJson(writer, id, result.value(row, 1), try result.int(i64, row, 2), try result.int(i64, row, 3), include_metadata);
        }
        try writer.writeByte(']');
    }

    pub fn lazerUserAchievementsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try self.writeUserAchievementsWithConnection(allocator, lease.conn, &output.writer, user_id, true);
        return output.toOwnedSlice();
    }

    pub fn newAchievementsForScore(self: *Store, source: []const u8, score_id: i64) !achievements.Unlocks {
        var score_buf: [32]u8 = undefined;
        const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var rows = try postgres.queryParams(self.allocator, lease.conn, "SELECT achievement_id FROM zigcho.user_achievements WHERE score_source=$1 AND score_id=$2 ORDER BY achievement_id", &.{ source, score });
        defer rows.deinit();
        var result: achievements.Unlocks = .{};
        for (0..rows.rows()) |row| result.append(try rows.int(u16, row, 0));
        return result;
    }

    pub fn insertLazerScore(self: *Store, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        const score_id = try self.insertLazerScoreWithConnection(lease.conn, user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
        try postgres.exec(lease.conn, "COMMIT");
        return score_id;
    }

    fn insertLazerScoreWithConnection(self: *Store, conn: *postgres.c.PGconn, user_id: i32, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const beatmap_id = try param(&buffers, &cursor, input.beatmap_id);
        const ruleset_id = try param(&buffers, &cursor, input.ruleset_id);
        const total_score = try param(&buffers, &cursor, input.total_score);
        const legacy_total_score: ?[]const u8 = if (input.legacy_total_score) |value| try param(&buffers, &cursor, value) else null;
        const accuracy = try param(&buffers, &cursor, input.accuracy);
        const max_combo = try param(&buffers, &cursor, input.max_combo);
        const pp_text = try param(&buffers, &cursor, pp_value);
        const star_rating = try param(&buffers, &cursor, input.achievement_stars);
        const replay_encoded: ?[]u8 = if (replay_data.len == 0) null else try postgres.encodeBytea(self.allocator, replay_data);
        defer if (replay_encoded) |encoded| self.allocator.free(encoded);
        const passed = if (input.passed) "true" else "false";
        const rank = input.rank orelse if (input.passed) "D" else "F";
        const namespace = @tagName(input.namespace);
        const medal_categories = try lazer.medalModCategories(self.allocator, mods_json);
        const best_sql = "SELECT id,pp,total_score FROM zigcho.lazer_scores WHERE user_id=$1 AND beatmap_id=$2 AND ruleset_id=$3 AND rank_namespace=$4 AND best FOR UPDATE";
        var previous = try postgres.queryParams(self.allocator, conn, best_sql, &.{ user, beatmap_id, ruleset_id, namespace });
        defer previous.deinit();
        const previous_best_id: i64 = if (previous.rows() == 0) 0 else try previous.int(i64, 0, 0);
        const previous_pp: f64 = if (previous.rows() == 0) 0 else try previous.float(f64, 0, 1);
        const previous_score: i64 = if (previous.rows() == 0) 0 else try previous.int(i64, 0, 2);
        const is_best = input.passed and (previous_best_id == 0 or pp_value > previous_pp or (pp_value == previous_pp and input.total_score > previous_score));
        var result = try postgres.queryParams(self.allocator, conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,client_version,pp,best,replay,star_rating) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11::jsonb,$12::jsonb,$13::jsonb,$14,$15,$16,$17,$18,$19) RETURNING id", &.{ user, beatmap_id, ruleset_id, total_score, legacy_total_score, accuracy, max_combo, passed, rank, mods_json, statistics_json, maximum_statistics_json, pauses_json, namespace, input.client_version, pp_text, if (is_best) "true" else "false", replay_encoded, star_rating });
        defer result.deinit();
        const score_id = try result.int(i64, 0, 0);
        if (is_best and previous_best_id != 0) {
            var previous_buffer: [32]u8 = undefined;
            const previous_id = try std.fmt.bufPrint(&previous_buffer, "{d}", .{previous_best_id});
            var unset = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.lazer_scores SET best=false WHERE id=$1", &.{previous_id});
            unset.deinit();
        }
        try self.updateLazerStatsWithConnection(conn, user_id, input);
        var ranked_map = try postgres.queryParams(self.allocator, conn, "SELECT status IN(3,4) FROM zigcho.beatmaps WHERE id=$1", &.{beatmap_id});
        defer ranked_map.deinit();
        const ranked = ranked_map.rows() != 0 and try ranked_map.boolean(0, 0);
        try self.awardAchievementsWithConnection(conn, user_id, "lazer", score_id, .{
            .eligible = input.passed and input.namespace == .vanilla and ranked,
            .mod_intro_eligible = input.passed and ranked,
            .conversion_mod = medal_categories.conversion,
            .fun_mod = medal_categories.fun,
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

    fn updateLazerStatsWithConnection(self: *Store, conn: *postgres.c.PGconn, user_id: i32, input: lazer.ScoreInput) !void {
        const stats_mode = lazer.statsMode(input) orelse return;
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const beatmap_id = try param(&buffers, &cursor, input.beatmap_id);
        const stats_mode_text = try param(&buffers, &cursor, stats_mode);
        const legacy_score = try param(&buffers, &cursor, input.legacy_total_score orelse input.total_score);
        const max_combo = try param(&buffers, &cursor, input.max_combo);
        const hits = try param(&buffers, &cursor, lazer.totalHits(input));
        const namespace = @tagName(input.namespace);

        var map = try postgres.queryParams(self.allocator, conn, "SELECT md5,status,greatest(total_length,0) FROM zigcho.beatmaps WHERE id=$1 FOR UPDATE", &.{beatmap_id});
        defer map.deinit();
        if (map.rows() == 0) return;
        const map_status = try map.int(i32, 0, 1);
        const play_time = try param(&buffers, &cursor, try map.int(i32, 0, 2));
        var update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.stats SET total_score=total_score+$1,plays=plays+1,play_time=play_time+$2,total_hits=total_hits+$3,max_combo=CASE WHEN $4::boolean THEN greatest(max_combo,$5) ELSE max_combo END WHERE user_id=$6 AND mode=$7", &.{ legacy_score, play_time, hits, if (input.passed and map_status >= 3) "true" else "false", max_combo, user, stats_mode_text });
        update.deinit();
        var map_update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.beatmaps SET plays=plays+1,passes=passes+$1 WHERE id=$2", &.{ if (input.passed) "1" else "0", beatmap_id });
        map_update.deinit();
        if (input.passed and (map_status == 3 or map_status == 4)) try self.rebuildCombinedPerformanceWithConnection(conn, user_id, @intCast(input.ruleset_id), stats_mode, namespace);
    }

    fn rebuildCombinedPerformanceWithConnection(self: *Store, conn: *postgres.c.PGconn, user_id: i32, ruleset_id: u8, stats_mode: u8, namespace: []const u8) !void {
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const ruleset = try param(&buffers, &cursor, ruleset_id);
        const mode = try param(&buffers, &cursor, stats_mode);
        var result = try postgres.queryParams(self.allocator, conn, "WITH candidates AS (" ++
            "SELECT b.id beatmap_id,s.pp,s.accuracy,s.score legacy_score,0 source,s.id score_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4) " ++
            "UNION ALL SELECT s.beatmap_id,s.pp,s.accuracy,coalesce(s.legacy_total_score,s.total_score),1,s.id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4))," ++
            "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id ORDER BY pp DESC,source ASC,score_id ASC) map_place FROM candidates) " ++
            "SELECT pp,accuracy,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_id ASC", &.{ user, ruleset, namespace });
        defer result.deinit();
        var total_pp: f64 = 0;
        var weighted_accuracy: f64 = 0;
        var weight: f64 = 1;
        var ranked_score: i64 = 0;
        for (0..result.rows()) |row| {
            total_pp += try result.float(f64, row, 0) * weight;
            weighted_accuracy += try result.float(f64, row, 1) * weight;
            ranked_score += try result.int(i64, row, 2);
            weight *= 0.95;
        }
        const score_count: u32 = @intCast(result.rows());
        const bonus_pp = 416.6667 * (1.0 - std.math.pow(f64, 0.9994, @floatFromInt(score_count)));
        const accuracy = if (score_count == 0) 0 else weighted_accuracy / (20.0 * (1.0 - std.math.pow(f64, 0.95, @floatFromInt(score_count))));
        const total = try param(&buffers, &cursor, @as(i64, @intFromFloat(@round(total_pp + bonus_pp))));
        const accuracy_text = try param(&buffers, &cursor, accuracy);
        const ranked = try param(&buffers, &cursor, ranked_score);
        var update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.stats SET pp=$1,accuracy=$2,ranked_score=$3 WHERE user_id=$4 AND mode=$5", &.{ total, accuracy_text, ranked, user, mode });
        update.deinit();
    }

    pub fn createLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
        var random_bytes: [8]u8 = undefined;
        try std.Io.randomSecure(self.io, &random_bytes);
        const token_id: i64 = @intCast((std.mem.readInt(u64, &random_bytes, .little) & std.math.maxInt(i64)) | 1);
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const token = try param(&buffers, &cursor, token_id);
        const user = try param(&buffers, &cursor, user_id);
        const map_id = try param(&buffers, &cursor, beatmap_id);
        const ruleset = try param(&buffers, &cursor, ruleset_id);
        const expiry = try param(&buffers, &cursor, now + lazer.score_token_lifetime_seconds);
        const prune_before = try param(&buffers, &cursor, now - 86_400);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT md5 FROM zigcho.beatmaps WHERE id=$1", &.{map_id});
        defer map.deinit();
        if (map.rows() == 0) return error.BeatmapNotFound;
        if (!std.ascii.eqlIgnoreCase(map.value(0, 0), beatmap_hash)) return error.BeatmapHashMismatch;
        var prune = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_score_tokens WHERE expires_at<$1 OR (consumed_at IS NOT NULL AND consumed_at<$1)", &.{prune_before});
        prune.deinit();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_score_tokens(id,user_id,beatmap_id,beatmap_hash,ruleset_id,version_hash,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7)", &.{ token, user, map_id, beatmap_hash, ruleset, version_hash, expiry });
        result.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return token_id;
    }

    pub fn submitLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const token_text = try param(&buffers, &cursor, token_id);
        const user_text = try param(&buffers, &cursor, user_id);
        const map_text = try param(&buffers, &cursor, beatmap_id);
        const ruleset_text = try param(&buffers, &cursor, input.ruleset_id);
        const now_text = try param(&buffers, &cursor, now);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var token = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id,beatmap_id,ruleset_id,expires_at,consumed_at FROM zigcho.lazer_score_tokens WHERE id=$1 FOR UPDATE", &.{token_text});
        defer token.deinit();
        if (token.rows() == 0) return error.InvalidLazerScoreToken;
        if (try token.int(i32, 0, 0) != user_id) return error.ForeignLazerScoreToken;
        if (try token.int(i32, 0, 1) != beatmap_id or try token.int(i64, 0, 2) != input.ruleset_id) return error.LazerScoreTokenMismatch;
        if (try token.int(i64, 0, 3) <= now) return error.LazerScoreTokenExpired;
        if (!token.isNull(0, 4)) return error.LazerScoreTokenUsed;
        const score_id = try self.insertLazerScoreWithConnection(lease.conn, user_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data);
        var score_buffer: [32]u8 = undefined;
        const score_text = try std.fmt.bufPrint(&score_buffer, "{d}", .{score_id});
        var consume = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.lazer_score_tokens SET consumed_at=$1,score_id=$2 WHERE id=$3 AND user_id=$4 AND beatmap_id=$5 AND ruleset_id=$6 AND consumed_at IS NULL RETURNING 1", &.{ now_text, score_text, token_text, user_text, map_text, ruleset_text });
        defer consume.deinit();
        if (consume.rows() != 1) return error.LazerScoreTokenUsed;
        try postgres.exec(lease.conn, "COMMIT");
        return score_id;
    }

    pub fn statsForUser(self: *Store, user_id: i32, mode: u8) !?domain.Stats {
        var id_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,(SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND NOT u.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))),(SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND NOT u.restricted AND u.country=me.country AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM zigcho.stats s JOIN zigcho.users me ON me.id=s.user_id WHERE s.user_id=$1 AND s.mode=$2", &.{ id, mode_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        var stats: domain.Stats = .{ .mode = @enumFromInt(mode % 4), .ranked_score = try result.int(i64, 0, 0), .total_score = try result.int(i64, 0, 1), .pp = try result.int(i32, 0, 2), .plays = try result.int(i32, 0, 3), .play_time = try result.int(i32, 0, 4), .total_hits = try result.int(i64, 0, 5), .accuracy = try result.float(f64, 0, 6), .max_combo = try result.int(i32, 0, 7), .global_rank = try result.int(i32, 0, 8), .country_rank = try result.int(i32, 0, 9) };
        var stable = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{ id, mode_text });
        defer stable.deinit();
        for (0..stable.rows()) |row| stats.addGrade(sqlite_storage.Store.stableGrade(mode, try stable.int(i32, row, 0), try stable.float(f64, row, 1), try stable.int(i32, row, 2), try stable.int(i32, row, 3), try stable.int(i32, row, 4), try stable.int(i32, row, 5)));
        var modern = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.rank FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{ id, mode_text });
        defer modern.deinit();
        for (0..modern.rows()) |row| stats.addGrade(modern.value(row, 0));
        return stats;
    }

    pub fn sourceStatsForUser(self: *Store, user_id: i32, mode: u8, source: domain.SiteScoreSource) !?domain.Stats {
        if (source != .stable and source != .lazer) return error.InvalidScoreSource;
        var id_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const stable_sql =
            "WITH source_scores AS (SELECT s.user_id,s.id score_id,s.score total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.time_elapsed/1000 play_time,b.status,b.id beatmap_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.mode=$2 AND s.rank_namespace='vanilla')," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
            "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
            "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=$1";
        const lazer_sql =
            "WITH source_scores AS (SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,greatest(b.total_length,0) play_time,b.status,s.beatmap_id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$2 AND s.rank_namespace='vanilla')," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce(sum(play_time),0) play_time,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id)," ++
            "players AS (SELECT a.user_id,a.ranked_score,a.total_score,coalesce(p.pp,0) pp,a.plays,a.play_time,coalesce(p.accuracy,0) accuracy,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
            "ordered AS (SELECT *,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) SELECT ranked_score,total_score,pp,plays,play_time,accuracy,max_combo,global_rank FROM ordered WHERE user_id=$1";
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, if (source == .stable) stable_sql else lazer_sql, &.{ id, mode_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{
            .mode = @enumFromInt(mode % 4),
            .ranked_score = try result.int(i64, 0, 0),
            .total_score = try result.int(i64, 0, 1),
            .pp = try result.int(i32, 0, 2),
            .plays = try result.int(i32, 0, 3),
            .play_time = try result.int(i32, 0, 4),
            .accuracy = try result.float(f64, 0, 5),
            .max_combo = try result.int(i32, 0, 6),
            .global_rank = try result.int(i32, 0, 7),
        };
    }

    pub fn beatmapForScore(self: *Store, md5: []const u8) !?BeatmapForScore {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,status,plays,passes FROM zigcho.beatmaps WHERE md5=$1", &.{md5});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .status = try result.int(i8, 0, 2), .plays = try result.int(i32, 0, 3), .passes = try result.int(i32, 0, 4) };
    }

    pub fn scoreLeaderboardPlacement(self: *Store, score_id: i64) !?domain.ScorePlacement {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.best,(SELECT count(*) FROM zigcho.scores o WHERE o.map_md5=pb.map_md5 AND o.mode=pb.mode AND o.rank_namespace=pb.rank_namespace AND o.passed AND o.best AND ((pb.rank_namespace IN('vanilla','scorev2') AND (o.score>pb.score OR (o.score=pb.score AND o.id<pb.id))) OR (pb.rank_namespace IN('relax','autopilot') AND (o.pp>pb.pp OR (o.pp=pb.pp AND o.id<pb.id))))) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.scores pb ON pb.user_id=s.user_id AND pb.map_md5=s.map_md5 AND pb.mode=s.mode AND pb.rank_namespace=s.rank_namespace AND pb.passed AND pb.best WHERE s.id=$1 AND s.passed AND b.status>=3", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .submitted_is_best = try result.boolean(0, 0), .rank = try result.int(i32, 0, 1) };
    }

    pub fn lazerScoreLeaderboardPlacement(self: *Store, score_id: i64) !?domain.ScorePlacement {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
        const Context = struct { user_id: i32, beatmap_id: i32, ruleset_id: u8, namespace: lazer.Namespace, mods_json: []u8 };
        const context: Context = blk: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.user_id,s.beatmap_id,s.ruleset_id,s.rank_namespace,s.mods_json::text,s.passed,b.status FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.id=$1", &.{id});
            defer result.deinit();
            if (result.rows() == 0 or !try result.boolean(0, 5) or try result.int(i32, 0, 6) < 3) return null;
            const score_namespace = std.meta.stringToEnum(lazer.Namespace, result.value(0, 3)) orelse return error.DatabaseQueryFailed;
            break :blk .{
                .user_id = try result.int(i32, 0, 0),
                .beatmap_id = try result.int(i32, 0, 1),
                .ruleset_id = try result.int(u8, 0, 2),
                .namespace = score_namespace,
                .mods_json = try self.allocator.dupe(u8, result.value(0, 4)),
            };
        };
        defer self.allocator.free(context.mods_json);
        const filter = try lazer.scoreModFilter(self.allocator, context.mods_json);
        defer filter.deinit(self.allocator);
        const board_json = try self.lazerLeaderboardJson(self.allocator, context.user_id, context.beatmap_id, context.ruleset_id, context.namespace, filter.exact_json, true, false, filter.stable_bits, .global, 100);
        defer self.allocator.free(board_json);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, board_json, .{});
        defer parsed.deinit();
        const own = parsed.value.object.get("user_score") orelse return null;
        const own_object = switch (own) {
            .object => |value| value,
            else => return null,
        };
        const position_value = switch (own_object.get("position") orelse return null) {
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
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,max_combo,artist,title,version,creator,status,star_rating FROM zigcho.beatmaps WHERE md5=$1", &.{md5});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const artist = try allocator.dupe(u8, result.value(0, 3));
        errdefer allocator.free(artist);
        const title = try allocator.dupe(u8, result.value(0, 4));
        errdefer allocator.free(title);
        const version = try allocator.dupe(u8, result.value(0, 5));
        errdefer allocator.free(version);
        const creator = try allocator.dupe(u8, result.value(0, 6));
        return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .max_combo = try result.int(i32, 0, 2), .artist = artist, .title = title, .version = version, .creator = creator, .status = try result.int(i8, 0, 7), .star_rating = try result.float(f64, 0, 8) };
    }

    pub fn beatmapInfoById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?BeatmapInfo {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,max_combo,artist,title,version,creator,status,star_rating FROM zigcho.beatmaps WHERE id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const artist = try allocator.dupe(u8, result.value(0, 3));
        errdefer allocator.free(artist);
        const title = try allocator.dupe(u8, result.value(0, 4));
        errdefer allocator.free(title);
        const version = try allocator.dupe(u8, result.value(0, 5));
        errdefer allocator.free(version);
        const creator = try allocator.dupe(u8, result.value(0, 6));
        return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .max_combo = try result.int(i32, 0, 2), .artist = artist, .title = title, .version = version, .creator = creator, .status = try result.int(i8, 0, 7), .star_rating = try result.float(f64, 0, 8) };
    }

    pub fn insertStableScore(self: *Store, user_id: i32, score: stable_score.Submission, pp_value: f64, replay_data: []const u8, time_elapsed_ms: u32) !i64 {
        const stats_mode = stable_score.statsMode(score.mode, score.mods) orelse return error.UnsupportedModMode;
        const namespace = score.rankNamespace();
        const uses_pp = stable_mods.usesPpMetric(namespace);
        const updates_player_stats = stable_mods.updatesPlayerStats(namespace);
        const replay_encoded = try postgres.encodeBytea(self.allocator, replay_data);
        defer self.allocator.free(replay_encoded);

        var user_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        var stats_mode_buf: [4]u8 = undefined;
        var mods_buf: [16]u8 = undefined;
        var score_buf: [32]u8 = undefined;
        var pp_buf: [64]u8 = undefined;
        var accuracy_buf: [64]u8 = undefined;
        var combo_buf: [16]u8 = undefined;
        var n300_buf: [16]u8 = undefined;
        var n100_buf: [16]u8 = undefined;
        var n50_buf: [16]u8 = undefined;
        var nmiss_buf: [16]u8 = undefined;
        var ngeki_buf: [16]u8 = undefined;
        var nkatu_buf: [16]u8 = undefined;
        var elapsed_buf: [24]u8 = undefined;
        var star_buf: [64]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const mode = try std.fmt.bufPrint(&mode_buf, "{d}", .{score.mode});
        const stats_mode_text = try std.fmt.bufPrint(&stats_mode_buf, "{d}", .{stats_mode});
        const mods = try std.fmt.bufPrint(&mods_buf, "{d}", .{score.mods});
        const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score.total_score});
        const pp = try std.fmt.bufPrint(&pp_buf, "{d}", .{pp_value});
        const accuracy = try std.fmt.bufPrint(&accuracy_buf, "{d}", .{score.accuracy()});
        const combo = try std.fmt.bufPrint(&combo_buf, "{d}", .{score.max_combo});
        const n300 = try std.fmt.bufPrint(&n300_buf, "{d}", .{score.n300});
        const n100 = try std.fmt.bufPrint(&n100_buf, "{d}", .{score.n100});
        const n50 = try std.fmt.bufPrint(&n50_buf, "{d}", .{score.n50});
        const nmiss = try std.fmt.bufPrint(&nmiss_buf, "{d}", .{score.nmiss});
        const ngeki = try std.fmt.bufPrint(&ngeki_buf, "{d}", .{score.ngeki});
        const nkatu = try std.fmt.bufPrint(&nkatu_buf, "{d}", .{score.nkatu});
        const elapsed = try std.fmt.bufPrint(&elapsed_buf, "{d}", .{time_elapsed_ms});
        const star_rating = try std.fmt.bufPrint(&star_buf, "{d}", .{score.achievement_stars});

        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        if (updates_player_stats) {
            var stats_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.stats WHERE user_id=$1 AND mode=$2 FOR UPDATE", &.{ user, stats_mode_text });
            defer stats_lock.deinit();
            if (stats_lock.rows() == 0) return error.DatabaseQueryFailed;
        }

        var previous_best_id: i64 = 0;
        var previous_best_score: i64 = 0;
        var previous_best_pp: f64 = 0;
        var previous = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,score,pp FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND mode=$3 AND rank_namespace=$4 AND best LIMIT 1", &.{ user, score.map_md5, mode, namespace });
        defer previous.deinit();
        if (previous.rows() != 0) {
            previous_best_id = try previous.int(i64, 0, 0);
            previous_best_score = try previous.int(i64, 0, 1);
            previous_best_pp = try previous.float(f64, 0, 2);
        }
        const is_best = score.passed and if (uses_pp) pp_value > previous_best_pp else score.total_score > previous_best_score;
        const perfect = if (score.perfect) "true" else "false";
        const passed = if (score.passed) "true" else "false";
        const best = if (is_best) "true" else "false";
        var inserted = postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,checksum,rank_namespace,best,time_elapsed,star_rating) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22) RETURNING id", &.{ user, score.map_md5, mode, mods, score_text, pp, accuracy, combo, n300, n100, n50, nmiss, ngeki, nkatu, perfect, passed, replay_encoded, score.online_checksum, namespace, best, elapsed, star_rating }) catch |err| switch (err) {
            error.UniqueViolation => return error.DuplicateScore,
            else => return err,
        };
        defer inserted.deinit();
        const score_id = try inserted.int(i64, 0, 0);

        if (is_best and previous_best_id != 0) {
            var previous_buf: [24]u8 = undefined;
            const previous_id = try std.fmt.bufPrint(&previous_buf, "{d}", .{previous_best_id});
            var unset = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.scores SET best=false WHERE id=$1", &.{previous_id});
            unset.deinit();
        }
        var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT status FROM zigcho.beatmaps WHERE md5=$1 FOR UPDATE", &.{score.map_md5});
        defer map.deinit();
        if (map.rows() == 0) return error.DatabaseQueryFailed;
        const map_status = try map.int(i32, 0, 0);
        const leaderboard = map_status >= 3;
        const ranked = map_status == 3 or map_status == 4;
        if (updates_player_stats) {
            const total_hits: i64 = @as(i64, score.n300) + score.n100 + score.n50 + if (score.mode == 1 or score.mode == 3) @as(i64, score.ngeki) + score.nkatu else 0;
            var ranked_buf: [32]u8 = undefined;
            var seconds_buf: [24]u8 = undefined;
            var hits_buf: [32]u8 = undefined;
            const ranked_text = try std.fmt.bufPrint(&ranked_buf, "{d}", .{@as(i64, 0)});
            const seconds = try std.fmt.bufPrint(&seconds_buf, "{d}", .{time_elapsed_ms / 1000});
            const hits = try std.fmt.bufPrint(&hits_buf, "{d}", .{total_hits});
            var update_stats = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.stats SET total_score=total_score+$1,ranked_score=ranked_score+$2,plays=plays+1,play_time=play_time+$3,total_hits=total_hits+$4,max_combo=CASE WHEN $5::boolean THEN greatest(max_combo,$6) ELSE max_combo END WHERE user_id=$7 AND mode=$8", &.{ score_text, ranked_text, seconds, hits, if (score.passed and leaderboard) "true" else "false", combo, user, stats_mode_text });
            update_stats.deinit();
        }
        var update_map = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.beatmaps SET plays=plays+1,passes=passes+$1 WHERE md5=$2", &.{ if (score.passed) "1" else "0", score.map_md5 });
        update_map.deinit();

        if (updates_player_stats and score.passed and ranked) {
            try self.rebuildCombinedPerformanceWithConnection(lease.conn, user_id, score.mode, stats_mode, namespace);
        }
        try self.awardAchievementsWithConnection(lease.conn, user_id, "stable", score_id, .{
            .eligible = score.passed and std.mem.eql(u8, namespace, "vanilla") and ranked,
            .mode = score.mode,
            .mods = @intCast(score.mods),
            .perfect = score.perfect,
            .max_combo = @intCast(score.max_combo),
            .stars = score.achievement_stars,
            .accuracy = score.accuracy(),
            .pp = pp_value,
        });
        try postgres.exec(lease.conn, "COMMIT");
        return score_id;
    }

    pub fn replay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        return self.replayData(allocator, .stable, score_id, false);
    }

    pub fn putScreenshot(self: *Store, user_id: i32, token: []const u8, extension: []const u8, image: []const u8) !bool {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const encoded = try postgres.encodeBytea(self.allocator, image);
        defer self.allocator.free(encoded);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var locked_user = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE id=$1 FOR UPDATE", &.{user});
        defer locked_user.deinit();
        if (locked_user.rows() == 0) return error.UserNotFound;
        var quota = try postgres.queryParams(self.allocator, lease.conn, "SELECT count(*),coalesce(sum(octet_length(image)),0) FROM zigcho.screenshots WHERE uploader_id=$1", &.{user});
        defer quota.deinit();
        const file_count = try quota.int(usize, 0, 0);
        const byte_count = try quota.int(usize, 0, 1);
        if (!screenshot_contract.quotaAllows(file_count, byte_count, image.len)) return error.ScreenshotQuotaExceeded;
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.screenshots(token,extension,uploader_id,image) VALUES($1,$2,$3,$4) ON CONFLICT(token) DO NOTHING RETURNING 1", &.{ token, extension, user, encoded });
        defer result.deinit();
        const inserted = result.rows() == 1;
        try postgres.exec(lease.conn, "COMMIT");
        return inserted;
    }

    pub fn screenshot(self: *Store, allocator: std.mem.Allocator, token: []const u8, extension: []const u8) !?[]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT image FROM zigcho.screenshots WHERE token=$1 AND extension=$2", &.{ token, extension });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try postgres.decodeBytea(allocator, result.value(0, 0));
    }

    pub fn ppSnapshot(self: *Store, score_id: i64) !?PpSnapshot {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{score_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.pp,t.pp FROM zigcho.scores s JOIN zigcho.stats t ON t.user_id=s.user_id AND t.mode=CASE WHEN (s.mods&8192)!=0 THEN s.mode+8 WHEN (s.mods&128)!=0 THEN s.mode+4 ELSE s.mode END WHERE s.id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{ .score = try result.float(f64, 0, 0), .player = try result.int(i64, 0, 1) };
    }

    pub fn issueToken(self: *Store, user_id: i32, scopes: []const u8, lifetime_seconds: i64) ![64]u8 {
        var raw: [32]u8 = undefined;
        try std.Io.randomSecure(self.io, &raw);
        var token: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{x}", .{raw}) catch unreachable;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var id_buf: [24]u8 = undefined;
        var expiry_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        const expiry = try std.fmt.bufPrint(&expiry_buf, "{d}", .{now_seconds + lifetime_seconds});
        var used_buf: [32]u8 = undefined;
        const used = try std.fmt.bufPrint(&used_buf, "{d}", .{now_seconds});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = if (std.mem.indexOf(u8, scopes, "scores:write") != null)
            try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,expires_at,last_used_at) VALUES($1,$2,$3,$4,$5)", &.{ digest_bytea, id, scopes, expiry, used })
        else
            try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,expires_at) VALUES($1,$2,$3,$4)", &.{ digest_bytea, id, scopes, expiry });
        result.deinit();
        return token;
    }

    pub fn authenticateToken(self: *Store, allocator: std.mem.Allocator, token: []const u8, required_scope: []const u8) !?domain.User {
        if (token.len != 64) return null;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var now_buf: [32]u8 = undefined;
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        const now = try std.fmt.bufPrint(&now_buf, "{d}", .{now_seconds});
        var lease = self.pool.acquire();
        defer lease.release();
        const user = result: {
            var query_result = try postgres.queryParams(self.allocator, lease.conn, "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,team.name,team.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=team.id AND ta.kind='flag'),0),t.scopes FROM zigcho.oauth_tokens t JOIN zigcho.users u ON u.id=t.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams team ON team.id=tm.team_id WHERE t.token_hash=$1 AND t.revoked_at IS NULL AND t.expires_at>$2", &.{ digest_bytea, now });
            defer query_result.deinit();
            if (query_result.rows() == 0) return null;
            var allowed = required_scope.len == 0;
            var scopes = std.mem.splitScalar(u8, query_result.value(0, 12), ' ');
            while (scopes.next()) |scope| if (std.mem.eql(u8, scope, required_scope) or std.mem.eql(u8, scope, "*")) {
                allowed = true;
                break;
            };
            if (!allowed) return null;
            break :result try userFromResult(allocator, query_result, 0);
        };
        errdefer {
            allocator.free(user.name);
            allocator.free(user.safe_name);
        }
        var stale_buf: [32]u8 = undefined;
        const stale = try std.fmt.bufPrint(&stale_buf, "{d}", .{now_seconds - 30});
        var touch = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET last_used_at=$1 WHERE token_hash=$2 AND (last_used_at IS NULL OR last_used_at<$3)", &.{ now, digest_bytea, stale });
        touch.deinit();
        return user;
    }

    pub fn consumeGameRefreshToken(self: *Store, allocator: std.mem.Allocator, token: []const u8) !?domain.User {
        if (token.len != 64) return null;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        const user_id: i32 = consume: {
            var lease = self.pool.acquire();
            defer lease.release();
            var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND scopes='game:refresh' AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint RETURNING user_id", &.{digest_bytea});
            defer result.deinit();
            if (result.rows() == 0) return null;
            break :consume try result.int(i32, 0, 0);
        };
        return self.userById(allocator, user_id);
    }

    pub fn recentOauthUserIds(self: *Store, allocator: std.mem.Allocator, cutoff: i64) ![]i32 {
        var cutoff_buf: [32]u8 = undefined;
        const cutoff_value = try std.fmt.bufPrint(&cutoff_buf, "{d}", .{cutoff});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT DISTINCT t.user_id FROM zigcho.oauth_tokens t JOIN zigcho.users u ON u.id=t.user_id WHERE t.last_used_at>=$1 AND t.revoked_at IS NULL AND t.expires_at>extract(epoch FROM clock_timestamp())::bigint AND t.scopes ~ '(^| )identify( |$)' AND t.scopes ~ '(^| )scores:write( |$)' AND u.restricted=false ORDER BY t.user_id", &.{cutoff_value});
        defer result.deinit();
        var ids: std.ArrayList(i32) = .empty;
        errdefer ids.deinit(allocator);
        try ids.ensureTotalCapacity(allocator, result.rows());
        for (0..result.rows()) |row| ids.appendAssumeCapacity(try result.int(i32, row, 0));
        return ids.toOwnedSlice(allocator);
    }

    pub fn lazerUserOnline(self: *Store, user_id: i32, cutoff: i64) !bool {
        var id_buf: [24]u8 = undefined;
        var cutoff_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const cutoff_value = try std.fmt.bufPrint(&cutoff_buf, "{d}", .{cutoff});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.oauth_tokens WHERE user_id=$1 AND last_used_at>=$2 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)' LIMIT 1", &.{ id, cutoff_value });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn revokeToken(self: *Store, token: []const u8) !bool {
        if (token.len != 64) return false;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND revoked_at IS NULL RETURNING 1", &.{digest_bytea});
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn revokeGameTokensForUser(self: *Store, user_id: i32) !usize {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)') RETURNING 1", &.{id});
        defer result.deinit();
        return result.rows();
    }
};

test "postgres runtime migrates through durable lazer multiplayer schema thirty six" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_MIGRATE_URL") orelse return error.SkipZigTest;
    {
        var old_store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
        defer old_store.close();
        try old_store.migrate();
        var previous = old_store.pool.acquire();
        defer previous.release();
        try postgres.exec(previous.conn, "DROP TABLE zigcho.lazer_multiplayer_room_history; DROP TABLE zigcho.beatmapset_metadata; DROP TABLE zigcho.upstream_user_profiles; ALTER TABLE zigcho.beatmaps DROP COLUMN creator_id,DROP COLUMN upstream_plays,DROP COLUMN upstream_passes,DROP COLUMN hit_length; DROP TABLE zigcho.upstream_users; DROP TABLE zigcho.beatmap_submission_maps; DROP TABLE zigcho.beatmap_submissions; DROP TABLE zigcho.bss_counters; DROP TABLE zigcho.profile_score_pins; DROP TABLE zigcho.beatmap_tag_votes; DROP TABLE zigcho.lazer_reports; DROP TABLE zigcho.replay_objects; DROP TABLE zigcho.lazer_presence; DROP TABLE zigcho.team_assets; DROP TABLE zigcho.team_applications; DROP TABLE zigcho.team_members; DROP TABLE zigcho.teams; DROP TABLE zigcho.user_banners; DROP TABLE zigcho.user_name_changes; ALTER TABLE zigcho.users DROP COLUMN username_changes,DROP COLUMN username_changed_at; DROP TABLE zigcho.lazer_comment_reports; DROP TABLE zigcho.lazer_comment_votes; DROP TABLE zigcho.lazer_comments");
        try postgres.exec(previous.conn, "ALTER TABLE zigcho.scores DROP COLUMN star_rating; ALTER TABLE zigcho.lazer_scores DROP COLUMN star_rating; ALTER TABLE zigcho.beatmap_archives DROP COLUMN object_bytes; DROP TABLE zigcho.user_achievements; DROP INDEX zigcho.direct_messages_sender_uuid; ALTER TABLE zigcho.direct_messages DROP COLUMN is_action,DROP COLUMN client_uuid; DROP TABLE zigcho.user_blocks; DROP TABLE zigcho.lazer_channel_reads; DROP INDEX zigcho.chat_messages_sender_uuid; ALTER TABLE zigcho.chat_messages DROP COLUMN is_action,DROP COLUMN client_uuid; DROP TABLE zigcho.anticheat_replay_fingerprints; DROP TABLE zigcho.anticheat_observations; DROP TABLE zigcho.user_avatars; ALTER TABLE zigcho.users DROP COLUMN bio,DROP COLUMN preferred_mode,DROP COLUMN profile_source,DROP COLUMN profile_title,DROP COLUMN profile_pronouns,DROP COLUMN profile_location,DROP COLUMN profile_website,DROP COLUMN profile_accent,DROP COLUMN show_country,DROP COLUMN show_profile_stats,DROP COLUMN show_recent_scores; DROP INDEX zigcho.lazer_scores_user_best; DROP TABLE zigcho.lazer_score_tokens; ALTER TABLE zigcho.lazer_scores DROP COLUMN rank,DROP COLUMN maximum_statistics_json,DROP COLUMN pauses_json,DROP COLUMN pp,DROP COLUMN best; TRUNCATE zigcho.schema_migrations; INSERT INTO zigcho.schema_migrations(version) VALUES(20)");
        try postgres.exec(previous.conn, "ALTER TABLE zigcho.beatmap_archives ALTER COLUMN osz_file SET NOT NULL; ALTER TABLE zigcho.beatmap_media ALTER COLUMN data SET NOT NULL");
    }
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    try std.testing.expect(!store.external_only);
    var lease = store.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT max(version),(to_regclass('zigcho.chat_messages') IS NOT NULL)::int,(to_regclass('zigcho.chat_channels') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_rank_requests') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_rank_events') IS NOT NULL)::int,(to_regclass('zigcho.moderation_appeals') IS NOT NULL)::int,(to_regclass('zigcho.score_pins') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_hydration_failures') IS NOT NULL)::int,(to_regclass('zigcho.screenshots') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_media') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_comments') IS NOT NULL)::int,(to_regclass('zigcho.direct_messages') IS NOT NULL)::int,(to_regclass('zigcho.lazer_score_tokens') IS NOT NULL)::int,(to_regclass('zigcho.user_avatars') IS NOT NULL)::int,(to_regclass('zigcho.anticheat_observations') IS NOT NULL)::int,(to_regclass('zigcho.anticheat_replay_fingerprints') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('bio','preferred_mode','profile_source')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_scores' AND column_name IN('pp','best')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('profile_title','profile_pronouns','profile_location','profile_website','profile_accent','show_country','show_profile_stats','show_recent_scores')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='chat_messages' AND column_name IN('is_action','client_uuid')),(to_regclass('zigcho.lazer_channel_reads') IS NOT NULL)::int,(to_regclass('zigcho.user_blocks') IS NOT NULL)::int,(to_regclass('zigcho.user_achievements') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='direct_messages' AND column_name IN('is_action','client_uuid')),(to_regclass('zigcho.direct_messages_sender_uuid') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name IN('scores','lazer_scores') AND column_name='star_rating'),(SELECT count(*) FROM information_schema.tables WHERE table_schema='zigcho' AND table_name IN('lazer_comments','user_name_changes','user_banners','teams','team_members','team_applications','team_assets','lazer_presence','replay_objects','lazer_reports','beatmap_tag_votes','profile_score_pins')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('username_changes','username_changed_at')) FROM zigcho.schema_migrations");
    defer result.deinit();
    try std.testing.expectEqual(@as(i32, 36), try result.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 3));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 4));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 5));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 6));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 7));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 8));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 9));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 10));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 11));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 12));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 13));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 14));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 15));
    try std.testing.expectEqual(@as(i32, 3), try result.int(i32, 0, 16));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 17));
    try std.testing.expectEqual(@as(i32, 8), try result.int(i32, 0, 18));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 19));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 20));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 21));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 22));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 23));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 24));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 25));
    try std.testing.expectEqual(@as(i32, 12), try result.int(i32, 0, 26));
    try std.testing.expectEqual(@as(i32, 2), try result.int(i32, 0, 27));
    var bss_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.beatmap_submissions') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_submission_maps') IS NOT NULL)::int,(to_regclass('zigcho.bss_counters') IS NOT NULL)::int,(SELECT count(*) FROM zigcho.bss_counters),(SELECT min(next_id) FROM zigcho.bss_counters),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='beatmap_submissions' AND column_name='replacement_set_id'),(to_regclass('zigcho.beatmap_submissions_replacement') IS NOT NULL)::int");
    defer bss_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i32, 2), try bss_schema.int(i32, 0, 3));
    try std.testing.expect((try bss_schema.int(i64, 0, 4)) >= @as(i64, bss.private_id_floor));
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 5));
    try std.testing.expectEqual(@as(i32, 1), try bss_schema.int(i32, 0, 6));
    const kai = (try store.userById(std.testing.allocator, 3)).?;
    defer {
        std.testing.allocator.free(kai.name);
        std.testing.allocator.free(kai.safe_name);
    }
    try std.testing.expectEqualStrings("kai", kai.safe_name);
    try std.testing.expect(kai.privileges & (1 << 13) != 0);
    try std.testing.expect(kai.privileges & (1 << 14) != 0);
    var reopened = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer reopened.close();
    try reopened.migrate();
}

test "postgres BSS publishes an owned pending package into the BN queue" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_BSS_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    store.external_only = false;
    const owner_id = try store.register("bss pg owner", "bss-pg-owner@example.test", "00000000000000000000000000000000");
    const other_id = try store.register("bss pg other", "bss-pg-other@example.test", "11111111111111111111111111111111");
    {
        var owner_buf: [24]u8 = undefined;
        const owner = try std.fmt.bufPrint(&owner_buf, "{d}", .{owner_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var legacy = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmap_submissions(set_id,owner_id,target,state,last_error) VALUES(100000000,$1,'WIP','failed','InvalidBssBeatmaps')", &.{owner});
        legacy.deinit();
        var legacy_maps = try postgres.query(lease.conn, "INSERT INTO zigcho.beatmap_submission_maps(set_id,beatmap_id,position) VALUES(100000000,100000000,0),(100000000,100000001,1)");
        legacy_maps.deinit();
    }
    var legacy_retry = try bss.parseReserveInput(std.testing.allocator, "{\"beatmapset_id\":100000000,\"beatmaps_to_create\":0,\"beatmaps_to_keep\":[100000000,100000001],\"target\":\"Pending\",\"notify_on_discussion_replies\":true}");
    defer legacy_retry.deinit();
    var legacy_reissued = try store.reserveBssSubmission(std.testing.allocator, owner_id, legacy_retry);
    defer legacy_reissued.deinit();
    try std.testing.expect(legacy_reissued.set_id >= bss.private_id_floor);
    for (legacy_reissued.beatmap_ids) |id| try std.testing.expect(id >= bss.private_id_floor);
    var legacy_repeat = try store.reserveBssSubmission(std.testing.allocator, owner_id, legacy_retry);
    defer legacy_repeat.deinit();
    try std.testing.expectEqual(legacy_reissued.set_id, legacy_repeat.set_id);
    try std.testing.expectEqualSlices(i32, legacy_reissued.beatmap_ids, legacy_repeat.beatmap_ids);
    var create = try bss.parseReserveInput(std.testing.allocator, "{\"beatmapset_id\":null,\"beatmaps_to_create\":1,\"beatmaps_to_keep\":[],\"target\":\"Pending\",\"notify_on_discussion_replies\":true}");
    defer create.deinit();
    var reservation = try store.reserveBssSubmission(std.testing.allocator, owner_id, create);
    defer reservation.deinit();
    try std.testing.expect(reservation.set_id >= bss.private_id_floor);
    try std.testing.expect(reservation.beatmap_ids[0] >= bss.private_id_floor);
    const foreign_ids = store.bssReservedMapIds(std.testing.allocator, other_id, reservation.set_id);
    try std.testing.expectError(error.BssNotOwner, foreign_ids);

    const map_id_text = try std.fmt.allocPrint(std.testing.allocator, "BeatmapID:{d}", .{reservation.beatmap_ids[0]});
    defer std.testing.allocator.free(map_id_text);
    const set_id_text = try std.fmt.allocPrint(std.testing.allocator, "BeatmapSetID:{d}", .{reservation.set_id});
    defer std.testing.allocator.free(set_id_text);
    const with_map_id = try std.mem.replaceOwned(u8, std.testing.allocator, @embedFile("testdata/synthetic-standard.osu"), "BeatmapID:900000001", map_id_text);
    defer std.testing.allocator.free(with_map_id);
    const map = try std.mem.replaceOwned(u8, std.testing.allocator, with_map_id, "BeatmapSetID:900000000", set_id_text);
    defer std.testing.allocator.free(map);
    var archive_source: bss.Archive = .{ .allocator = std.testing.allocator };
    defer archive_source.deinit();
    try archive_source.entries.append(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .name = try std.testing.allocator.dupe(u8, "Zigcho [Postgres].osu"),
        .data = try std.testing.allocator.dupe(u8, map),
    });
    const archive = try bss.buildArchive(std.testing.allocator, &archive_source);
    defer std.testing.allocator.free(archive);
    var package = try bss.preparePackage(std.testing.allocator, archive, reservation.set_id, reservation.beatmap_ids);
    defer package.deinit();
    const digest = bss.archiveSha256(archive);
    try store.publishBssSubmission(owner_id, reservation.set_id, &package, archive, &digest);
    const info = (try store.beatmapInfoById(std.testing.allocator, reservation.beatmap_ids[0])).?;
    defer std.testing.allocator.free(info.artist);
    defer std.testing.allocator.free(info.title);
    defer std.testing.allocator.free(info.version);
    defer std.testing.allocator.free(info.creator);
    try std.testing.expectEqual(@as(i8, 2), info.status);
    {
        var set_buf: [24]u8 = undefined;
        const set = try std.fmt.bufPrint(&set_buf, "{d}", .{reservation.set_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var upstream = try postgres.query(lease.conn, "INSERT INTO zigcho.upstream_users(id,username,country,join_date) VALUES(35712887,'Raya_old_6','AU','2020-01-01T00:00:00Z') ON CONFLICT(id) DO UPDATE SET username=excluded.username");
        upstream.deinit();
        var collision = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.beatmaps SET creator_id=35712887 WHERE set_id=$1", &.{set});
        collision.deinit();
    }
    var local_creator = (try store.beatmapSetCreator(std.testing.allocator, reservation.set_id)).?;
    defer local_creator.deinit();
    try std.testing.expect(local_creator.is_local);
    try std.testing.expectEqual(owner_id, local_creator.user_id.?);
    try std.testing.expectEqualStrings("bss pg owner", local_creator.name);
    const lookup = (try store.lazerBeatmapLookup(std.testing.allocator, reservation.beatmap_ids[0], null, owner_id)).?;
    defer std.testing.allocator.free(lookup);
    var parsed_lookup = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup, .{});
    defer parsed_lookup.deinit();
    try std.testing.expectEqual(@as(i64, owner_id), parsed_lookup.value.object.get("user_id").?.integer);
    try std.testing.expectEqualStrings("bss pg owner", parsed_lookup.value.object.get("owners").?.array.items[0].object.get("username").?.string);
    const lookup_set = parsed_lookup.value.object.get("beatmapset").?.object;
    try std.testing.expectEqual(@as(i64, owner_id), lookup_set.get("user_id").?.integer);
    try std.testing.expectEqualStrings("bss pg owner", lookup_set.get("creator").?.string);
    try std.testing.expectEqualStrings("bss pg owner", lookup_set.get("user").?.object.get("username").?.string);
    const pending_sets = try store.lazerUserBeatmapSetsJson(std.testing.allocator, owner_id, "pending", 0, 50, owner_id);
    defer std.testing.allocator.free(pending_sets);
    var parsed_pending_sets = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pending_sets, .{});
    defer parsed_pending_sets.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_pending_sets.value.array.items.len);
    const score_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"beatmap_id\":{d},\"ruleset_id\":0,\"total_score\":987654,\"legacy_total_score\":900000,\"accuracy\":0.985,\"max_combo\":321,\"passed\":true,\"mods\":[],\"statistics\":{{}},\"client_version\":\"2026.823.0\"}}", .{reservation.beatmap_ids[0]});
    defer std.testing.allocator.free(score_body);
    var parsed_score = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, score_body, .{});
    defer parsed_score.deinit();
    _ = try store.insertLazerScore(owner_id, try lazer.parseScore(parsed_score.value), 100, "[]", "{}", "{}", "[]", &.{});
    const pending_board = try store.lazerLeaderboardJson(std.testing.allocator, owner_id, reservation.beatmap_ids[0], 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(pending_board);
    try std.testing.expect(std.mem.indexOf(u8, pending_board, "\"score_count\":0") != null);
    const site_profile = (try store.siteProfile(std.testing.allocator, owner_id, .all, 0)).?;
    defer std.testing.allocator.free(site_profile);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"beatmapsets\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"creator\":\"bss pg owner\"") != null);
    const ranking = try store.staffRankingJson(std.testing.allocator);
    defer std.testing.allocator.free(ranking);
    const marker = try std.fmt.allocPrint(std.testing.allocator, "\"set_id\":{d}", .{reservation.set_id});
    defer std.testing.allocator.free(marker);
    try std.testing.expect(std.mem.indexOf(u8, ranking, marker) != null);
}

test "postgres account auth stats and token slice" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const user_id = try store.register("ari", "ari@example.test", "00000000000000000000000000000000");
    const team_id = try store.createTeam(user_id, .{ .name = "uwu team", .short_name = "uwu", .url = "", .description = "postgres leaderboard flag", .is_open = true, .default_ruleset_id = 0 });
    var team_etag: [64]u8 = undefined;
    @memset(&team_etag, 'b');
    try store.setTeamAsset(team_id, "flag", "teams/1/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png", "image/png", team_etag, 64, 32);
    const observation_id = try store.recordAnticheatObservation(user_id, .{
        .source = .stable_login,
        .module = "private",
        .action = 1,
        .reason = 42,
        .risk_score = 150,
        .confidence_bps = 5000,
        .evidence = 1,
    });
    try store.reviewAnticheatObservation(user_id, observation_id, .clean, "verified test fixture");
    {
        var audit_lease = store.pool.acquire();
        defer audit_lease.release();
        var target_buf: [32]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
        var audit = try postgres.queryParams(std.testing.allocator, audit_lease.conn, "SELECT count(*) FROM zigcho.audit_log WHERE action IN('anticheat.observe','anticheat.review') AND target=$1", &.{target});
        defer audit.deinit();
        try std.testing.expectEqual(@as(i64, 2), try audit.int(i64, 0, 0));
    }
    const anticheat_json = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(anticheat_json);
    try std.testing.expect(std.mem.indexOf(u8, anticheat_json, "\"review_label\":\"clean\"") != null);
    try std.testing.expect((try store.registrationConflicts("ari", "ari@example.test")).username);
    try std.testing.expect((try store.avatarForUser(user_id)) != null);
    const user = (try store.authenticate(std.testing.allocator, "ari", "00000000000000000000000000000000")).?;
    defer {
        std.testing.allocator.free(user.name);
        std.testing.allocator.free(user.safe_name);
    }
    try std.testing.expectEqual(user_id, user.id);
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = true, .show_profile_stats = true, .show_recent_scores = true });
    const site_account = (try store.siteAccountJson(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(site_account);
    try std.testing.expect(std.mem.indexOf(u8, site_account, "\"bio\":\"postgres profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_account, "\"profile_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_account, "\"preferred_mode\":2") != null);
    var avatar_etag: [64]u8 = undefined;
    @memset(&avatar_etag, 'a');
    try store.setCustomAvatar(user_id, "4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png", "image/png", avatar_etag);
    var custom_avatar = (try store.customAvatarForUser(std.testing.allocator, user_id)).?;
    try std.testing.expectEqualStrings("image/png", custom_avatar.content_type);
    try std.testing.expectEqualStrings("4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png", custom_avatar.object_key);
    custom_avatar.deinit();
    try std.testing.expect(try store.deleteCustomAvatar(user_id));
    try std.testing.expect((try store.customAvatarForUser(std.testing.allocator, user_id)) == null);
    const screenshot_png = "\x89PNG\r\n\x1a\nbodyIEND\xaeB`\x82";
    try std.testing.expect(try store.putScreenshot(user_id, "Ab1_-xyZ", "png", screenshot_png));
    try std.testing.expect(!try store.putScreenshot(user_id, "Ab1_-xyZ", "png", "collision"));
    const stored_screenshot = (try store.screenshot(std.testing.allocator, "Ab1_-xyZ", "png")).?;
    defer std.testing.allocator.free(stored_screenshot);
    try std.testing.expectEqualSlices(u8, screenshot_png, stored_screenshot);
    try store.updateCountry(user_id, .{ 'A', 'U' });
    const stats = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(@as(i32, 0), stats.pp);
    const token = try store.issueToken(user_id, "identify scores:write", 60);
    const token_user = (try store.authenticateToken(std.testing.allocator, &token, "identify")).?;
    std.testing.allocator.free(token_user.name);
    std.testing.allocator.free(token_user.safe_name);
    try std.testing.expect(try store.revokeToken(&token));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &token, "identify")) == null);
    const refresh = try store.issueToken(user_id, "game:refresh", 60);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &refresh, "identify")) == null);
    const refreshed_user = (try store.consumeGameRefreshToken(std.testing.allocator, &refresh)).?;
    std.testing.allocator.free(refreshed_user.name);
    std.testing.allocator.free(refreshed_user.safe_name);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &refresh)) == null);

    {
        var lease = store.pool.acquire();
        defer lease.release();
        var map_insert = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(1,1,$1,'artist','title','hard','mapper',3,10)", &.{"0123456789abcdef0123456789abcdef"});
        map_insert.deinit();
    }
    const score: stable_score.Submission = .{
        .map_md5 = "0123456789abcdef0123456789abcdef",
        .username = "ari",
        .online_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .n300 = 10,
        .n100 = 0,
        .n50 = 0,
        .ngeki = 0,
        .nkatu = 0,
        .nmiss = 0,
        .total_score = 1_000_000,
        .max_combo = 10,
        .perfect = true,
        .grade = "X",
        .mods = 0,
        .passed = true,
        .mode = 0,
        .client_time = "260811000000",
        .client_flags = "0",
    };
    const score_id = try store.insertStableScore(user_id, score, 26.8, "replay", 12_000);
    const first_placement = (try store.scoreLeaderboardPlacement(score_id)).?;
    try std.testing.expect(first_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), first_placement.rank);
    const snapshot = (try store.ppSnapshot(score_id)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 26.8), snapshot.score, 0.001);
    try std.testing.expectEqual(@as(i64, 27), snapshot.player);
    const replay = (try store.replay(std.testing.allocator, score_id)).?;
    defer std.testing.allocator.free(replay);
    try std.testing.expectEqualStrings("replay", replay);
    const website_replay = (try store.siteReplay(std.testing.allocator, score_id)).?;
    defer std.testing.allocator.free(website_replay);
    try std.testing.expect(std.mem.indexOf(u8, website_replay, "replay") != null);
    try std.testing.expectEqual(score_id, std.mem.readInt(i64, website_replay[website_replay.len - 8 ..][0..8], .little));
    const website_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 1, .all, 0)).?;
    defer std.testing.allocator.free(website_board);
    try std.testing.expect(std.mem.indexOf(u8, website_board, "\"rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, website_board, "\"has_replay\":true") != null);
    const stable_website_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 1, .stable, 0)).?;
    defer std.testing.allocator.free(stable_website_board);
    try std.testing.expect(std.mem.indexOf(u8, stable_website_board, "\"source\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_website_board, "\"client\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_website_board, "\"client\":\"lazer\"") == null);
    const classic_lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .global, 50);
    defer std.testing.allocator.free(classic_lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, classic_lazer_board, "\"score_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_lazer_board, "\"username\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_lazer_board, "\"total_score\":1000000") != null);
    var parsed_classic_lazer_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, classic_lazer_board, .{});
    defer parsed_classic_lazer_board.deinit();
    const classic_team = parsed_classic_lazer_board.value.object.get("scores").?.array.items[0].object.get("user").?.object.get("team").?.object;
    try std.testing.expectEqual(@as(i64, team_id), classic_team.get("id").?.integer);
    try std.testing.expectEqualStrings("uwu", classic_team.get("short_name").?.string);
    try std.testing.expect(std.mem.startsWith(u8, classic_team.get("flag_url").?.string, "https://assets.kai.ovh/teams/"));

    const outsider_id = try store.register("outside", "outside@example.test", "11111111111111111111111111111111");
    try store.updateCountry(outsider_id, .{ 'N', 'Z' });
    try std.testing.expect(try store.addFriend(user_id, outsider_id));
    var outsider_score = score;
    outsider_score.username = "outside";
    outsider_score.online_checksum = "cccccccccccccccccccccccccccccccc";
    outsider_score.total_score = 2_000_000;
    _ = try store.insertStableScore(outsider_id, outsider_score, 40, "outside replay", 20_000);

    const global_scope = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .global, 50);
    defer std.testing.allocator.free(global_scope);
    try std.testing.expect(std.mem.indexOf(u8, global_scope, "\"score_count\":2") != null);
    const friend_scope = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .friend, 50);
    defer std.testing.allocator.free(friend_scope);
    try std.testing.expect(std.mem.indexOf(u8, friend_scope, "\"score_count\":2") != null);
    const country_scope = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .country, 50);
    defer std.testing.allocator.free(country_scope);
    try std.testing.expect(std.mem.indexOf(u8, country_scope, "\"score_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, country_scope, "\"username\":\"outside\"") == null);
    const team_scope = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .vanilla, "[]", true, true, 0, .team, 50);
    defer std.testing.allocator.free(team_scope);
    try std.testing.expect(std.mem.indexOf(u8, team_scope, "\"score_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, team_scope, "\"username\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, team_scope, "\"username\":\"outside\"") == null);
    var relax_hidden = score;
    relax_hidden.online_checksum = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    relax_hidden.total_score = 700_000;
    relax_hidden.mods = stable_mods.relax | stable_mods.hidden;
    const relax_hidden_id = try store.insertStableScore(user_id, relax_hidden, 33, "relax hidden replay", 12_000);
    const relax_namespace_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .relax, "[\"RX\"]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(relax_namespace_board);
    try std.testing.expect(std.mem.indexOf(u8, relax_namespace_board, "\"score_count\":1") != null);
    var relax_public_id_buf: [64]u8 = undefined;
    const relax_public_id = try std.fmt.bufPrint(&relax_public_id_buf, "\"id\":{d}", .{lazer.encodeStableScoreId(relax_hidden_id).?});
    try std.testing.expect(std.mem.indexOf(u8, relax_namespace_board, relax_public_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, relax_namespace_board, "\"acronym\":\"HD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relax_namespace_board, "\"acronym\":\"RX\"") != null);
    const relax_hidden_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 1, 0, .relax, "[\"HD\",\"RX\"]", true, false, stable_mods.hidden, .global, 50);
    defer std.testing.allocator.free(relax_hidden_board);
    try std.testing.expect(std.mem.indexOf(u8, relax_hidden_board, relax_public_id) != null);
    const after_pass = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(@as(i64, 1_000_000), after_pass.ranked_score);
    try std.testing.expectEqual(@as(i32, 27), after_pass.pp);
    try std.testing.expectEqual(@as(i32, 1), after_pass.plays);
    var failed = score;
    failed.online_checksum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    failed.total_score = 200_000;
    failed.n300 = 4;
    failed.n100 = 3;
    failed.nmiss = 9;
    failed.max_combo = 99;
    failed.perfect = false;
    failed.grade = "F";
    failed.passed = false;
    const failed_id = try store.insertStableScore(user_id, failed, 999, "", 45_123);
    try std.testing.expect((try store.scoreLeaderboardPlacement(failed_id)) == null);
    const after_fail = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(after_pass.ranked_score, after_fail.ranked_score);
    try std.testing.expectEqual(after_pass.pp, after_fail.pp);
    try std.testing.expectEqual(@as(i64, 1_200_000), after_fail.total_score);
    try std.testing.expectEqual(@as(i32, 2), after_fail.plays);
    try std.testing.expectEqual(after_pass.max_combo, after_fail.max_combo);
    var worse = score;
    worse.online_checksum = "dddddddddddddddddddddddddddddddd";
    worse.total_score = 900_000;
    const worse_id = try store.insertStableScore(user_id, worse, 20, "worse replay", 12_000);
    const worse_placement = (try store.scoreLeaderboardPlacement(worse_id)).?;
    try std.testing.expect(!worse_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 1), worse_placement.rank);
    try std.testing.expectEqual(score_id, try store.setScorePinned(user_id, score.map_md5, 0, 0, "vanilla", true));
    var hidden = score;
    hidden.online_checksum = "55555555555555555555555555555555";
    hidden.total_score = 800_000;
    hidden.mods = stable_mods.hidden;
    const hidden_id = try store.insertStableScore(user_id, hidden, 18, "hidden replay", 12_000);
    try std.testing.expectEqual(hidden_id, try store.setScorePinned(user_id, score.map_md5, 0, stable_mods.hidden, "vanilla", true));
    try std.testing.expectError(error.NoPassedScore, store.setScorePinned(user_id, score.map_md5, 0, stable_mods.hard_rock, "vanilla", true));
    {
        var user_id_buf: [24]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var pinned = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT count(*) FROM zigcho.score_pins WHERE user_id=$1", &.{user_id_text});
        defer pinned.deinit();
        try std.testing.expectEqual(@as(i64, 2), try pinned.int(i64, 0, 0));
    }
    const site_rankings = try store.siteRankings(std.testing.allocator, .all, 0, 0);
    defer std.testing.allocator.free(site_rankings);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_rankings, "\"name\":\"ari\"") != null);
    const lazer_performance_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, .performance, null, 1);
    defer std.testing.allocator.free(lazer_performance_rankings);
    try std.testing.expect(std.mem.indexOf(u8, lazer_performance_rankings, "\"ranking\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_performance_rankings, "\"username\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_performance_rankings, "\"global_rank\":1") != null);
    const lazer_country_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, .country, null, 1);
    defer std.testing.allocator.free(lazer_country_rankings);
    try std.testing.expect(std.mem.indexOf(u8, lazer_country_rankings, "\"code\":\"AU\"") != null);
    const filtered_lazer_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, .score, "AU", 1);
    defer std.testing.allocator.free(filtered_lazer_rankings);
    try std.testing.expect(std.mem.indexOf(u8, filtered_lazer_rankings, "\"country_code\":\"AU\"") != null);
    const site_profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 0)).?;
    defer std.testing.allocator.free(site_profile);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"country\":\"AU\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"global_rank\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"rank_history\":[0,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"artist\":\"artist\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"passed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"pinned_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"top_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"weight\":{\"percentage\":100.00,\"pp\":26.80}") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"recent_scores\":[{") != null);
    var relax = score;
    relax.online_checksum = "ffffffffffffffffffffffffffffffff";
    relax.total_score = 600_000;
    relax.mods = 128;
    _ = try store.insertStableScore(user_id, relax, 42.5, "relax replay", 15_000);
    const relax_profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 4)).?;
    defer std.testing.allocator.free(relax_profile);
    try std.testing.expect(std.mem.indexOf(u8, relax_profile, "\"selected_mode\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, relax_profile, "\"namespace\":\"relax\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, relax_profile, "\"namespace\":\"vanilla\"") == null);
    const relax_stats = (try store.statsForUser(user_id, 4)).?;
    try std.testing.expectEqual(@as(i64, 600_000), relax_stats.ranked_score);
    try std.testing.expectEqual(@as(i32, 43), relax_stats.pp);
    const vanilla_board = try store.stableLeaderboard(std.testing.allocator, user, score.map_md5, 0, 0, 0);
    defer std.testing.allocator.free(vanilla_board);
    try std.testing.expect(std.mem.indexOf(u8, vanilla_board, "artist - title [hard]") != null);
    try std.testing.expect(std.mem.indexOf(u8, vanilla_board, "|ari|1000000|") != null);
    const relax_board = try store.stableLeaderboard(std.testing.allocator, user, score.map_md5, 0, 0, 128);
    defer std.testing.allocator.free(relax_board);
    try std.testing.expect(std.mem.indexOf(u8, relax_board, "|ari|42|") != null);

    const metadata: beatmap.Metadata = .{
        .id = 2,
        .set_id = 2,
        .artist = "artist two",
        .title = "title two",
        .version = "insane",
        .creator = "mapper",
        .source = "source",
        .tags = "some tags",
        .hp = 5,
        .cs = 4,
        .od = 8,
        .ar = 9,
        .bpm = 180,
        .total_length = 90,
        .count_circles = 10,
        .count_sliders = 20,
        .count_spinners = 1,
    };
    const second_md5 = "fedcba9876543210fedcba9876543210";
    try store.upsertBeatmapMeta(metadata, second_md5, 3, 5.25, 300);
    try std.testing.expect(!try store.beatmapHasFile(second_md5));
    try store.upsertBeatmap(metadata, second_md5, 3, 5.25, 300, "osu file bytes");
    try std.testing.expect(try store.beatmapHasFile(second_md5));
    const map_file = (try store.beatmapFileById(std.testing.allocator, 2)).?;
    defer std.testing.allocator.free(map_file);
    try std.testing.expectEqualStrings("osu file bytes", map_file);
    const archive_bytes = "osz archive bytes";
    var archive_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_bytes, &archive_digest, .{});
    const archive_sha256 = std.fmt.bytesToHex(archive_digest, .lower);
    try store.upsertBeatmapArchive(2, &archive_sha256, archive_bytes);
    const archive = (try store.beatmapArchive(std.testing.allocator, 2)).?;
    defer std.testing.allocator.free(archive);
    try std.testing.expectEqualStrings(archive_bytes, archive);
    const cover = "\xff\xd8\xffcover\xff\xd9";
    try store.putBeatmapMedia(2, .cover, .jpeg, cover);
    var stored_cover = (try store.beatmapMedia(std.testing.allocator, 2, .cover)).?;
    defer stored_cover.deinit(std.testing.allocator);
    try std.testing.expectEqual(.jpeg, stored_cover.content_type);
    try std.testing.expectEqualStrings(cover, stored_cover.data);
    const media_stats = try store.beatmapMediaCacheStats();
    try std.testing.expectEqual(@as(i64, 1), media_stats.entries);
    try std.testing.expectEqual(@as(i64, cover.len), media_stats.bytes);
    try store.recordHydrationFailure("cccccccccccccccccccccccccccccccc", 2, "UpstreamUnavailable", 100);
    try std.testing.expect(!try store.hydrationRetryAllowed("cccccccccccccccccccccccccccccccc", 129));
    try std.testing.expect(try store.hydrationRetryAllowed("cccccccccccccccccccccccccccccccc", 130));
    try std.testing.expectEqual(@as(i64, 1), (try store.beatmapCacheStats()).hydration_failures);
    try store.clearHydrationFailure("cccccccccccccccccccccccccccccccc");
    const direct = try store.stableSearch(std.testing.allocator, "title two", -1, 4, 0);
    defer std.testing.allocator.free(direct);
    try std.testing.expect(std.mem.indexOf(u8, direct, "2.osz|artist two|title two|mapper") != null);
    const direct_set = try store.stableSearchSet(std.testing.allocator, null, null, second_md5);
    defer std.testing.allocator.free(direct_set);
    try std.testing.expect(std.mem.startsWith(u8, direct_set, "2.osz|"));
    const lazer_set = (try store.lazerBeatmapSet(std.testing.allocator, 2, null)).?;
    defer std.testing.allocator.free(lazer_set);
    try std.testing.expect(std.mem.indexOf(u8, lazer_set, "\"title\":\"title two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_set, "https://assets.kai.ovh/beatmaps/2/covers/cover.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_set, "https://b.kai.ovh/preview/2.mp3") != null);
    try std.testing.expect(try store.setLazerBeatmapTag(user_id, 2, 1, true));
    const tag_state = (try store.lazerBeatmapTagStateJson(std.testing.allocator, user_id, 2)).?;
    defer std.testing.allocator.free(tag_state);
    try std.testing.expect(std.mem.indexOf(u8, tag_state, "\"current_user_tag_ids\":[1]") != null);
    try std.testing.expect(try store.setLazerBeatmapTag(user_id, 2, 1, false));
    try std.testing.expect(try store.addLazerReport(user_id, "user", user_id, "Other", "postgres route report"));
    const report_queue = try store.staffLazerReportsJson(std.testing.allocator);
    defer std.testing.allocator.free(report_queue);
    const parsed_queue = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report_queue, .{});
    defer parsed_queue.deinit();
    const report_id = parsed_queue.value.object.get("reports").?.array.items[0].object.get("id").?.integer;
    try std.testing.expect(try store.resolveLazerReport(user_id, report_id, "resolved"));
    try std.testing.expect(!try store.resolveLazerReport(user_id, report_id, "dismissed"));
    try std.testing.expect(!try store.lazerMessageExists(999999));
    const lazer_search = try store.lazerBeatmapSearch(std.testing.allocator, "title two", 0, 0, null);
    defer std.testing.allocator.free(lazer_search);
    try std.testing.expect(std.mem.indexOf(u8, lazer_search, "\"beatmapsets\":[{") != null);
    const ordered_lazer_sets = try store.lazerBeatmapSets(std.testing.allocator, &.{2}, 0, null);
    defer std.testing.allocator.free(ordered_lazer_sets);
    try std.testing.expect(std.mem.indexOf(u8, ordered_lazer_sets, "\"beatmapsets\":[{\"id\":2") != null);
    const raw_lazer_score = "{\"beatmap_id\":2,\"ruleset_id\":0,\"total_score\":1234,\"legacy_total_score\":900,\"accuracy\":0.98,\"max_combo\":25,\"passed\":true,\"mods\":[],\"statistics\":{},\"client_version\":\"2026.811.0\"}";
    const parsed_lazer = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw_lazer_score, .{});
    defer parsed_lazer.deinit();
    const mods_json = try lazer.jsonField(std.testing.allocator, parsed_lazer.value.object, "mods", "[]");
    defer std.testing.allocator.free(mods_json);
    const statistics_json = try lazer.jsonField(std.testing.allocator, parsed_lazer.value.object, "statistics", "{}");
    defer std.testing.allocator.free(statistics_json);
    const lazer_input = try lazer.parseScore(parsed_lazer.value);
    const lazer_token = try store.createLazerScoreToken(user_id, 2, second_md5, 0, "11111111111111111111111111111111");
    var lazer_replay: [32]u8 = @splat(0);
    lazer_replay[0] = 0;
    std.mem.writeInt(i32, lazer_replay[1..5], 20_260_816, .little);
    const lazer_score_id = try store.submitLazerScoreToken(user_id, 2, lazer_token, lazer_input, 0, mods_json, statistics_json, "{}", "[]", &lazer_replay);
    try std.testing.expect(lazer_score_id > 0);
    try std.testing.expectError(error.LazerScoreTokenUsed, store.submitLazerScoreToken(user_id, 2, lazer_token, lazer_input, 0, mods_json, statistics_json, "{}", "[]", &.{}));
    const combined_stats = (try store.statsForUser(user_id, 0)).?;
    try std.testing.expectEqual(@as(i64, 2_900_900), combined_stats.total_score);
    try std.testing.expectEqual(@as(i64, 1_000_900), combined_stats.ranked_score);
    try std.testing.expectEqual(@as(i32, 5), combined_stats.plays);
    try std.testing.expectEqual(@as(i32, 25), combined_stats.max_combo);
    const stored_lazer_replay = (try store.lazerReplay(std.testing.allocator, lazer_score_id)).?;
    defer std.testing.allocator.free(stored_lazer_replay);
    try std.testing.expectEqualSlices(u8, &lazer_replay, stored_lazer_replay);
    const lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, lazer_board, "\"has_replay\":true") != null);
    {
        var score_id_buf: [24]u8 = undefined;
        const score_id_text = try std.fmt.bufPrint(&score_id_buf, "{d}", .{lazer_score_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var clear_replay = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.lazer_scores SET replay=NULL WHERE id=$1", &.{score_id_text});
        clear_replay.deinit();
    }
    const old_lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(old_lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, old_lazer_board, "\"has_replay\":false") != null);
    const lazer_placement = (try store.lazerScoreLeaderboardPlacement(lazer_score_id)).?;
    try std.testing.expect(lazer_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), lazer_placement.rank);
    const lazer_rankings = try store.siteRankings(std.testing.allocator, .lazer, 0, 0);
    defer std.testing.allocator.free(lazer_rankings);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"name\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"total_score\":900") != null);
    const stable_rankings = try store.siteRankings(std.testing.allocator, .stable, 0, 0);
    defer std.testing.allocator.free(stable_rankings);
    try std.testing.expect(std.mem.indexOf(u8, stable_rankings, "\"source\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_rankings, "\"name\":\"ari\"") != null);
    const lazer_profile = (try store.siteProfile(std.testing.allocator, user_id, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_profile);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"stats_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_stats\":{\"ranked_score\":900,\"total_score\":900,\"pp\":0,\"plays\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"mods_json\":[]") != null);
    const lazer_website_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 2, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_website_board);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"client\":\"stable\"") == null);
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES($1,$2,0,0,1100,120,0.97,30,97,3,0,0,0,0,false,true,'replay'::bytea,'vanilla',true)", &.{ user_text, second_md5 });
        inserted.deinit();
    }
    const mixed_client_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(mixed_client_board);
    var parsed_mixed_client_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mixed_client_board, .{});
    defer parsed_mixed_client_board.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_mixed_client_board.value.object.get("score_count").?.integer);
    const mixed_scores = parsed_mixed_client_board.value.object.get("scores").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), mixed_scores.len);
    try std.testing.expect(mixed_scores[0].object.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expect(std.mem.indexOf(u8, mixed_client_board, "\"pp\":120") != null);
    try std.testing.expectEqual(@as(i64, team_id), mixed_scores[0].object.get("user").?.object.get("team").?.object.get("id").?.integer);
    try std.testing.expect(parsed_mixed_client_board.value.object.get("user_score").?.object.get("score").?.object.get("id").?.integer >= lazer.stable_score_id_offset);
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var removed = try postgres.queryParams(std.testing.allocator, lease.conn, "DELETE FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND score=1100", &.{ user_text, second_md5 });
        removed.deinit();
    }
    var stable_relax_id: i64 = 0;
    var stable_autopilot_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES($1,$2,0,128,600,180,0.96,60,96,4,0,0,0,0,false,true,'relax-replay'::bytea,'relax',true),($1,$2,0,8192,620,190,0.97,62,97,3,0,0,0,0,false,true,'autopilot-replay'::bytea,'autopilot',true) RETURNING id", &.{ user_text, second_md5 });
        defer inserted.deinit();
        stable_relax_id = try inserted.int(i64, 0, 0);
        stable_autopilot_id = try inserted.int(i64, 1, 0);
    }
    const stable_relax_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .relax, "[\"RX\"]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(stable_relax_board);
    var parsed_stable_relax = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_relax_board, .{});
    defer parsed_stable_relax.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_stable_relax.value.object.get("score_count").?.integer);
    const relax_board_score = parsed_stable_relax.value.object.get("scores").?.array.items[0].object;
    try std.testing.expect(relax_board_score.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expectEqual(stable_relax_id, relax_board_score.get("legacy_score_id").?.integer);
    try std.testing.expectEqual(@as(i64, 600), relax_board_score.get("legacy_total_score").?.integer);
    try std.testing.expect(relax_board_score.get("ranked").?.bool);
    try std.testing.expect(relax_board_score.get("has_replay").?.bool);
    try std.testing.expectEqualStrings("RX", relax_board_score.get("mods").?.array.items[1].object.get("acronym").?.string);
    const stable_relax_replay = (try store.siteReplay(std.testing.allocator, stable_relax_id)).?;
    defer std.testing.allocator.free(stable_relax_replay);
    try std.testing.expect(std.mem.indexOf(u8, stable_relax_replay, "relax-replay") != null);

    const stable_autopilot_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .autopilot, "[\"AP\"]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(stable_autopilot_board);
    var parsed_stable_autopilot = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_autopilot_board, .{});
    defer parsed_stable_autopilot.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_stable_autopilot.value.object.get("score_count").?.integer);
    const autopilot_board_score = parsed_stable_autopilot.value.object.get("scores").?.array.items[0].object;
    try std.testing.expect(autopilot_board_score.get("id").?.integer >= lazer.stable_score_id_offset);
    try std.testing.expectEqual(stable_autopilot_id, autopilot_board_score.get("legacy_score_id").?.integer);
    try std.testing.expectEqual(@as(i64, 620), autopilot_board_score.get("legacy_total_score").?.integer);
    try std.testing.expect(autopilot_board_score.get("ranked").?.bool);
    try std.testing.expect(autopilot_board_score.get("has_replay").?.bool);
    try std.testing.expectEqualStrings("AP", autopilot_board_score.get("mods").?.array.items[1].object.get("acronym").?.string);
    const stable_autopilot_replay = (try store.siteReplay(std.testing.allocator, stable_autopilot_id)).?;
    defer std.testing.allocator.free(stable_autopilot_replay);
    try std.testing.expect(std.mem.indexOf(u8, stable_autopilot_replay, "autopilot-replay") != null);
    var hard_rock_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,pp,best) VALUES($1,2,0,500,500,0.95,50,true,'A','[{\"acronym\":\"HR\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'vanilla',150,false) RETURNING id", &.{user_text});
        defer inserted.deinit();
        hard_rock_id = try inserted.int(i64, 0, 0);
    }
    const hard_rock_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[\"HR\"]", true, false, stable_mods.hard_rock, .global, 50);
    defer std.testing.allocator.free(hard_rock_board);
    try std.testing.expect(std.mem.indexOf(u8, hard_rock_board, "\"total_score\":1234") == null);
    try std.testing.expect(std.mem.indexOf(u8, hard_rock_board, "\"total_score\":500") != null);
    const hard_rock_placement = (try store.lazerScoreLeaderboardPlacement(hard_rock_id)).?;
    try std.testing.expect(hard_rock_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), hard_rock_placement.rank);
    var custom_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,pp,best) VALUES($1,2,0,600,600,0.95,60,true,'A','[{\"acronym\":\"RX\"},{\"acronym\":\"WIGGLE\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'custom',60,true),($1,2,0,800,800,0.98,80,true,'A','[{\"acronym\":\"WIGGLE\"},{\"acronym\":\"HR\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'custom',80,false) RETURNING id", &.{user_text});
        defer inserted.deinit();
        custom_id = try inserted.int(i64, 0, 0);
    }
    const custom_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .custom, "[\"WIGGLE\"]", true, false, null, .global, 50);
    defer std.testing.allocator.free(custom_board);
    try std.testing.expect(std.mem.indexOf(u8, custom_board, "\"total_score\":600") != null);
    try std.testing.expect(std.mem.indexOf(u8, custom_board, "\"total_score\":800") == null);
    const custom_placement = (try store.lazerScoreLeaderboardPlacement(custom_id)).?;
    try std.testing.expect(custom_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), custom_placement.rank);
    try std.testing.expectEqual(Store.BeatmapRating.can_rate, try store.rateBeatmap(user_id, second_md5, null));
    const vote = try store.rateBeatmap(user_id, second_md5, 8);
    try std.testing.expectApproxEqAbs(@as(f64, 8), vote.already_voted, 0.001);

    const second_id = try store.register("raya", "raya@example.test", "11111111111111111111111111111111");
    const by_name = (try store.userByName(std.testing.allocator, "raya")).?;
    defer {
        std.testing.allocator.free(by_name.name);
        std.testing.allocator.free(by_name.safe_name);
    }
    try std.testing.expectEqual(second_id, by_name.id);
    const stable_info = (try store.stableBeatmapInfoByFilename(user_id, "artist - title (mapper) [hard].osu")).?;
    try std.testing.expectEqual(@as(i32, 1), stable_info.id);
    try std.testing.expectEqualStrings("X", stable_info.grades[0]);
    try store.addBeatmapComment(user_id, "map", 1, 12.5, "postgres map comment", null);
    const comments = try store.beatmapComments(std.testing.allocator, score_id, 1, 1);
    defer std.testing.allocator.free(comments);
    try std.testing.expect(std.mem.indexOf(u8, comments, "12.5\tmap\t\tpostgres map comment") != null);
    try store.storeDirectMessage(second_id, user_id, "postgres offline hello");
    const unread = try store.unreadDirectMessages(std.testing.allocator, user_id);
    defer {
        for (unread) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(unread);
    }
    try std.testing.expectEqual(@as(usize, 1), unread.len);
    try std.testing.expectEqualStrings("raya", unread[0].from_name);
    try store.markDirectMessagesRead(user_id, second_id);
    const dm_threads = try store.directMessageThreadsJson(std.testing.allocator, user_id, 50);
    defer std.testing.allocator.free(dm_threads);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"name\":\"raya\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"last_message\":\"postgres offline hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"unread\":0") != null);
    const initial_friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(initial_friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, initial_friends, 3) != null);
    try std.testing.expect(try store.addFriend(user_id, second_id));
    try std.testing.expect(!try store.addFriend(user_id, second_id));
    const friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, friends, 3) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, friends, second_id) != null);
    const reverse_friends = try store.friendIds(std.testing.allocator, second_id);
    defer std.testing.allocator.free(reverse_friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, reverse_friends, user_id) == null);
    try std.testing.expect(try store.removeFriend(user_id, second_id));
    try std.testing.expect(!try store.removeFriend(user_id, second_id));
    try std.testing.expect(try store.addBlock(user_id, second_id));
    try std.testing.expect(!try store.directMessageAllowed(user_id, second_id));
    try std.testing.expectError(error.DirectMessageBlocked, store.storeDirectMessage(second_id, user_id, "blocked postgres dm"));
    try std.testing.expect(try store.removeBlock(user_id, second_id));
    try std.testing.expect(try store.addFavourite(user_id, 900000000));
    try std.testing.expect(!try store.addFavourite(user_id, 900000000));
    const favourites = try store.favouriteSetIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(favourites);
    try std.testing.expect(std.mem.indexOfScalar(i32, favourites, 900000000) != null);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var pending_map = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(3,3,$1,'queue artist','queue title','hard','mapper',2,10)", &.{"33333333333333333333333333333333"});
        pending_map.deinit();
    }
    const requested = try store.requestBeatmapRank(user_id, "33333333333333333333333333333333");
    try std.testing.expectEqual(@as(u32, 1), requested.requests);
    _ = try store.nominateBeatmapSet(user_id, "33333333333333333333333333333333", "first postgres review");
    const nominated = try store.nominateBeatmapSet(second_id, "33333333333333333333333333333333", "second postgres review");
    try std.testing.expectEqual(@as(u32, 2), nominated.nominations);
    const qualified = try store.applyBeatmapRankAction(user_id, "33333333333333333333333333333333", .qualify, "postgres qualification");
    try std.testing.expectEqual(@as(i8, 5), qualified.status);
    const ranked = try store.applyBeatmapRankAction(second_id, "33333333333333333333333333333333", .rank, "postgres ranking");
    try std.testing.expectEqual(@as(i8, 3), ranked.status);
    const loved = try store.applyBeatmapRankAction(user_id, "33333333333333333333333333333333", .love, "postgres direct loved status");
    try std.testing.expectEqual(@as(i8, 6), loved.status);
    const approved = try store.applyBeatmapRankAction(second_id, "33333333333333333333333333333333", .approve, "postgres direct approved status");
    try std.testing.expectEqual(@as(i8, 4), approved.status);
    const pending = try store.applyBeatmapRankAction(user_id, "33333333333333333333333333333333", .pending, "postgres direct pending status");
    try std.testing.expectEqual(@as(i8, 2), pending.status);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var mixed_map = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(4,3,$1,'queue artist','queue title','insane','mapper',4,20)", &.{"44444444444444444444444444444444"});
        mixed_map.deinit();
    }
    const mixed_loved = try store.applyBeatmapRankAction(second_id, "33333333333333333333333333333333", .love, "postgres repair mixed set as loved");
    try std.testing.expectEqual(@as(i8, 6), mixed_loved.status);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var statuses = try postgres.query(lease.conn, "SELECT min(status),max(status),count(*) FROM zigcho.beatmaps WHERE set_id=3");
        defer statuses.deinit();
        try std.testing.expectEqual(@as(i32, 6), try statuses.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 6), try statuses.int(i32, 0, 1));
        try std.testing.expectEqual(@as(i64, 2), try statuses.int(i64, 0, 2));
    }
    const rank_queue = try store.beatmapRankQueue(std.testing.allocator);
    defer std.testing.allocator.free(rank_queue);
    try std.testing.expect(std.mem.indexOf(u8, rank_queue, "set 3") == null);
    try store.recordPublicMessage(user_id, "#osu", "postgres chat history");
    try store.recordAudit(user_id, "server.alert", "server", "postgres audit");
    try std.testing.expect(try store.channelCanWrite("#osu", 3));
    try std.testing.expect(!try store.channelCanWrite("#announce", 3));
    try store.setChannelLocked(user_id, "#osu", true, "fixture lock");
    try std.testing.expect(!try store.channelCanWrite("#osu", 3));
    try store.setChannelLocked(user_id, "#osu", false, "fixture unlock");
    try store.setSilence(user_id, second_id, 123456789, "account.silence", "fixture silence");
    try store.addModerationNote(user_id, second_id, "fixture note");
    const notes = try store.moderationNotes(std.testing.allocator, second_id, 10);
    defer std.testing.allocator.free(notes);
    try std.testing.expect(std.mem.indexOf(u8, notes, "fixture note") != null);
    const supporter_privileges = try store.changePrivileges(user_id, second_id, 1 << 4, true);
    try std.testing.expect(supporter_privileges & (1 << 4) != 0);
    try store.setRestricted(user_id, second_id, true, "fixture restrict");
    try store.setRestricted(user_id, second_id, false, "fixture unrestrict");
    const hardware: ClientHardware = .{
        .osu_path_md5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .adapters_md5 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .uninstall_md5 = "cccccccccccccccccccccccccccccccc",
        .disk_signature_md5 = "dddddddddddddddddddddddddddddddd",
        .client_version = "b20260811",
        .running_under_wine = false,
        .actionable = true,
    };
    var first_hardware = try store.recordClientHardware(user_id, hardware);
    defer first_hardware.deinit();
    try std.testing.expect(!first_hardware.restricted());
    var second_hardware = try store.recordClientHardware(second_id, hardware);
    defer second_hardware.deinit();
    try std.testing.expect(second_hardware.restricted());
    try std.testing.expectEqual(user_id, second_hardware.matched_user_ids[0]);
    const restricted_first = (try store.userById(std.testing.allocator, user_id)).?;
    defer {
        std.testing.allocator.free(restricted_first.name);
        std.testing.allocator.free(restricted_first.safe_name);
    }
    try std.testing.expect(restricted_first.restricted);
    try std.testing.expect(!try store.restrictForClientFlag(user_id, 1 << 19));
    try store.recordLastFmFlag(user_id, 1 << 19);

    const recalc_file = @embedFile("testdata/synthetic-standard.osu");
    const recalc_metadata = try beatmap.parse(recalc_file);
    const recalc_hash = beatmap.md5(recalc_file);
    try store.upsertBeatmap(recalc_metadata, &recalc_hash, 3, 1.7931, 10, recalc_file);
    var recalc_score = score;
    recalc_score.map_md5 = &recalc_hash;
    recalc_score.online_checksum = "66666666666666666666666666666666";
    recalc_score.total_score = 777_777;
    const recalc_score_id = try store.insertStableScore(user_id, recalc_score, 1, "recalc replay", 12_000);
    try std.testing.expectEqual(@as(u64, 3), try store.recalculatePerformance(std.testing.allocator));
    const before_scorev2 = (try store.statsForUser(user_id, 0)).?;
    var scorev2 = recalc_score;
    scorev2.online_checksum = "77777777777777777777777777777777";
    scorev2.total_score = 2_000_000;
    scorev2.max_combo = 999;
    scorev2.mods = stable_mods.score_v2;
    const scorev2_id = try store.insertStableScore(user_id, scorev2, 1, "scorev2 replay", 30_000);
    try std.testing.expectEqualDeep(before_scorev2, (try store.statsForUser(user_id, 0)).?);
    const scorev2_placement = (try store.scoreLeaderboardPlacement(scorev2_id)).?;
    try std.testing.expect(scorev2_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), scorev2_placement.rank);
    try store.setRestricted(second_id, user_id, false, "fixture source view");
    const scorev2_rankings = try store.siteRankings(std.testing.allocator, .scorev2, 0, 0);
    defer std.testing.allocator.free(scorev2_rankings);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_rankings, "\"source\":\"scorev2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_rankings, "\"name\":\"ari\"") != null);
    const scorev2_profile = (try store.siteProfile(std.testing.allocator, user_id, .scorev2, 0)).?;
    defer std.testing.allocator.free(scorev2_profile);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"selected_source\":\"scorev2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scorev2_profile, "\"namespace\":\"scorev2\"") != null);
    {
        var user_id_buf: [24]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var corrupt = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.stats SET ranked_score=1,total_score=2,pp=3,plays=4,play_time=5,total_hits=6,accuracy=0.7,max_combo=8 WHERE user_id=$1 AND mode=0", &.{user_id_text});
        corrupt.deinit();
    }
    try std.testing.expectEqual(@as(u64, 4), try store.recalculatePerformance(std.testing.allocator));
    try std.testing.expectEqualDeep(before_scorev2, (try store.statsForUser(user_id, 0)).?);
    const recalculated = (try store.ppSnapshot(recalc_score_id)).?;
    try std.testing.expect(recalculated.score > 1);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var recalc_audit = try postgres.query(lease.conn, "SELECT count(*) FROM zigcho.audit_log WHERE action='operations.pp_recalc' AND target='scores'");
        defer recalc_audit.deinit();
        try std.testing.expectEqual(@as(i64, 2), try recalc_audit.int(i64, 0, 0));
    }
    var failed_stable = score;
    failed_stable.passed = false;
    failed_stable.grade = "F";
    failed_stable.online_checksum = "abababababababababababababababab";
    failed_stable.total_score = 111_111;
    const failed_stable_id = try store.insertStableScore(user_id, failed_stable, 0, "failed", 12_000);
    try std.testing.expect((try store.replay(std.testing.allocator, failed_stable_id)) == null);
    var failed_lazer = lazer_input;
    failed_lazer.passed = false;
    failed_lazer.rank = "F";
    failed_lazer.total_score = 4_321;
    failed_lazer.legacy_total_score = 3_210;
    const failed_lazer_token = try store.createLazerScoreToken(user_id, 2, second_md5, 0, "44444444444444444444444444444444");
    const failed_lazer_id = try store.submitLazerScoreToken(user_id, 2, failed_lazer_token, failed_lazer, 0, mods_json, statistics_json, "{}", "[]", "failed");
    try std.testing.expect((try store.lazerReplay(std.testing.allocator, failed_lazer_id)) == null);
    {
        var stable_buf: [24]u8 = undefined;
        var lazer_buf: [24]u8 = undefined;
        const stable_text = try std.fmt.bufPrint(&stable_buf, "{d}", .{failed_stable_id});
        const lazer_text = try std.fmt.bufPrint(&lazer_buf, "{d}", .{failed_lazer_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var stored_failed = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT (SELECT octet_length(replay) FROM zigcho.scores WHERE id=$1),(SELECT octet_length(replay) FROM zigcho.lazer_scores WHERE id=$2)", &.{ stable_text, lazer_text });
        defer stored_failed.deinit();
        try std.testing.expectEqual(@as(i32, 6), try stored_failed.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 6), try stored_failed.int(i32, 0, 1));
    }
    const pruned = try store.pruneBeatmapArchives(1);
    try std.testing.expectEqual(@as(i64, 1), pruned.entries);
    try std.testing.expectEqual(@as(i64, 17), pruned.bytes);
}
