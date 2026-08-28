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
const server_control = @import("server_control.zig");
const account_roles = @import("account_roles.zig");
const anticheat_evidence = @import("anticheat_evidence.zig");
const anticheat_review = @import("anticheat_review.zig");
const database_sql = @import("database_sql");

pub const ClientHardware = sqlite_storage.ClientHardware;
pub const HardwareEvidence = sqlite_storage.HardwareEvidence;
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
pub const ConsumedLazerScoreToken = sqlite_storage.ConsumedLazerScoreToken;
const archive_object_limit: usize = 128 * 1024 * 1024;
const max_replay_object_bytes: usize = 32 * 1024 * 1024;
const visible_follower_count_sql = "CASE WHEN NOT u.restricted AND u.id!=3 THEN (SELECT count(*) FROM zigcho.friends relation JOIN zigcho.users follower ON follower.id=relation.user_id WHERE relation.friend_id=u.id AND relation.user_id!=u.id AND NOT follower.restricted) ELSE 0 END";

fn hasOauthScope(scopes: []const u8, wanted: []const u8) bool {
    var values = std.mem.splitScalar(u8, scopes, ' ');
    while (values.next()) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

fn hasGameAccessScopes(scopes: []const u8) bool {
    return hasOauthScope(scopes, "identify") and hasOauthScope(scopes, "scores:write");
}

fn randomOauthToken(io: std.Io) ![64]u8 {
    var raw: [32]u8 = undefined;
    try std.Io.randomSecure(io, &raw);
    var token: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&token, "{x}", .{raw}) catch unreachable;
    return token;
}

fn randomOauthClientId(io: std.Io) !i32 {
    var raw: [4]u8 = undefined;
    try std.Io.randomSecure(io, &raw);
    const value = std.mem.readInt(u32, &raw, .little) & std.math.maxInt(i32);
    return @intCast(if (value == 0) 1 else value);
}

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
    pub const LazerRankedRating = sqlite_storage.Store.LazerRankedRating;
    pub const LazerRankedResult = sqlite_storage.Store.LazerRankedResult;
    pub const BeatmapRating = sqlite_storage.Store.BeatmapRating;
    pub const PpSnapshot = sqlite_storage.Store.PpSnapshot;
    pub const CustomAvatar = sqlite_storage.Store.CustomAvatar;
    pub const LazerChatWrite = sqlite_storage.Store.LazerChatWrite;
    pub const GameTokenPair = sqlite_storage.Store.GameTokenPair;
    pub const GameTokenRefresh = sqlite_storage.Store.GameTokenRefresh;
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
        } else if (version < 13 or version > 45) return error.UnsupportedSchemaVersion;
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
            try self.rebuildRankedStats(lease.conn, true);
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
        if (version <= 36) try postgres.exec(lease.conn, database_sql.postgresMigration(37));
        if (version <= 37) try postgres.exec(lease.conn, database_sql.postgresMigration(38));
        if (version <= 38) try postgres.exec(lease.conn, database_sql.postgresMigration(39));
        if (version <= 39) try postgres.exec(lease.conn, database_sql.postgresMigration(40));
        if (version <= 40) try postgres.exec(lease.conn, database_sql.postgresMigration(41));
        if (version <= 41) try postgres.exec(lease.conn, database_sql.postgresMigration(42));
        if (version <= 42) try postgres.exec(lease.conn, database_sql.postgresMigration(43));
        if (version <= 43) try postgres.exec(lease.conn, database_sql.postgresMigration(44));
        if (version <= 44) try postgres.exec(lease.conn, database_sql.postgresMigration(45));
        try self.backfillLazerClassicScoresWithConnection(lease.conn);
        if (version <= 43) try self.rebuildRankedStats(lease.conn, false);
        try postgres.exec(lease.conn, "DELETE FROM zigcho.user_stats_history WHERE day<((extract(epoch FROM clock_timestamp())::bigint/86400)-89)*86400");
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
            .show_country = try result.boolean(row, 12),
            .privileges = try result.int(u32, row, 4),
            .silence_end = try result.int(i64, row, 5),
            .restricted = try result.boolean(row, 6),
            .follower_count = try result.int(i32, row, 13),
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

    fn insertAudit(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, actor_id: i32, action: []const u8, target_user_id: i32, detail: []const u8) !void {
        var actor_buf: [24]u8 = undefined;
        var target_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_user_id});
        var result = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,$2,$3,$4)", &.{ actor, action, target, detail });
        result.deinit();
    }

    fn insertHardwareMatchAudit(allocator: std.mem.Allocator, conn: *postgres.c.PGconn, target_user_id: i32, detail: []const u8) !void {
        var target_buf: [24]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{target_user_id});
        var result = try postgres.queryParams(allocator, conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) SELECT 3,'anticheat.hardware_match',$1,$2 WHERE NOT EXISTS(SELECT 1 FROM zigcho.audit_log WHERE actor_id=3 AND action='anticheat.hardware_match' AND target=$1 AND detail=$2 AND created_at>=extract(epoch FROM clock_timestamp())::bigint-86400)", &.{ target, detail });
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
        if (observation.score_id == null) {
            var user_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE id=$1 FOR UPDATE", &.{params[0]});
            defer user_lock.deinit();
        }
        try postgres.exec(lease.conn, "DELETE FROM zigcho.anticheat_observations WHERE id IN (SELECT id FROM zigcho.anticheat_observations WHERE score_id IS NULL AND source!='stable_score' AND ((review_label!='pending' AND reviewed_at<extract(epoch FROM clock_timestamp())::bigint-15552000) OR (review_label='pending' AND created_at<extract(epoch FROM clock_timestamp())::bigint-7776000)) ORDER BY created_at,id LIMIT 128)");
        try postgres.exec(lease.conn, "DELETE FROM zigcho.audit_log WHERE id IN (SELECT id FROM zigcho.audit_log WHERE ((action='anticheat.observe' AND detail LIKE '% score_id=0 mode=observe %') OR action IN('anticheat.hardware_match','stable.lastfm_flag')) AND created_at<extract(epoch FROM clock_timestamp())::bigint-15552000 ORDER BY created_at,id LIMIT 128)");
        if (observation.score_id == null) {
            const coalesce_params = [_]?[]const u8{ params[0], params[2], params[3], params[4], params[5], params[6], params[7], params[8], params[9], params[10], params[11], params[12], params[13], params[14], params[15], params[16], params[17], params[18], params[19], params[20], params[21], params[22], params[23], params[24], params[25], params[26], params[27], params[28] };
            var existing = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.anticheat_observations WHERE user_id=$1 AND score_id IS NULL AND review_label='pending' AND source=$2 AND module=$3 AND action=$4 AND sample_weight=$5 AND reason=$6 AND risk_score=$7 AND confidence_bps=$8 AND evidence=$9 AND decision_flags=$10 AND rule_revision=$11 AND objects_checked=$12 AND matched_clicks=$13 AND mean_abs_timing_error_milli=$14 AND timing_stddev_milli=$15 AND exact_timing_bps=$16 AND center_hits_bps=$17 AND mean_center_distance_milli=$18 AND snap_events=$19 AND replay_match_count=$20 AND key_press_count=$21 AND key_hold_count=$22 AND mean_hold_duration_milli=$23 AND hold_duration_stddev_milli=$24 AND alternation_bps=$25 AND target_distance_stddev_milli=$26 AND velocity_spike_count=$27 AND movement_velocity_stddev_milli=$28 AND created_at>=extract(epoch FROM clock_timestamp())::bigint-86400 ORDER BY id DESC LIMIT 1", &coalesce_params);
            defer existing.deinit();
            if (existing.rows() != 0) {
                const observation_id = try existing.int(i64, 0, 0);
                try postgres.exec(lease.conn, "COMMIT");
                return observation_id;
            }
        }
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
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT least(count(DISTINCT other_fp.user_id),100000) FROM zigcho.anticheat_replay_fingerprints current_fp JOIN zigcho.scores current_score ON current_score.id=current_fp.score_id JOIN zigcho.anticheat_replay_fingerprints other_fp ON other_fp.replay_sha256=current_fp.replay_sha256 AND other_fp.user_id!=current_fp.user_id AND other_fp.user_id!=3 JOIN zigcho.scores other_score ON other_score.id=other_fp.score_id WHERE current_fp.replay_sha256=$1 AND current_fp.user_id=$2 AND current_score.passed AND other_score.passed AND other_score.map_md5=current_score.map_md5 AND other_score.mode=current_score.mode", &.{ encoded, user });
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

    pub fn recordClientHardware(self: *Store, user_id: i32, hardware: ClientHardware) !HardwareEvidence {
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
        try postgres.exec(lease.conn, "DELETE FROM zigcho.audit_log WHERE id IN (SELECT id FROM zigcho.audit_log WHERE action='anticheat.hardware_match' AND created_at<extract(epoch FROM clock_timestamp())::bigint-15552000 ORDER BY created_at,id LIMIT 128)");

        if (hardware.actionable) {
            var matches = try postgres.queryParams(self.allocator, lease.conn, "SELECT DISTINCT user_id FROM zigcho.client_hardware WHERE user_id!=$1 AND user_id!=3 AND adapters_md5=$2 AND uninstall_md5=$3 AND disk_signature_md5=$4 ORDER BY user_id", &.{ id, hardware.adapters_md5, hardware.uninstall_md5, hardware.disk_signature_md5 });
            defer matches.deinit();
            for (0..matches.rows()) |row| try matched.append(self.allocator, try matches.int(i32, row, 0));
        }

        var upsert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.client_hardware(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5,client_version,running_under_wine) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5) DO UPDATE SET client_version=excluded.client_version,running_under_wine=excluded.running_under_wine,last_seen=extract(epoch FROM clock_timestamp())::bigint,occurrences=zigcho.client_hardware.occurrences+1", &.{ id, hardware.osu_path_md5, hardware.adapters_md5, hardware.uninstall_md5, hardware.disk_signature_md5, hardware.client_version, wine });
        upsert.deinit();

        if (matched.items.len != 0) {
            var detail_buf: [128]u8 = undefined;
            for (matched.items) |matched_user_id| {
                const detail = try std.fmt.bufPrint(&detail_buf, "mode=observe exact_hardware_match matched_user:{d} match_count:{d}", .{ matched_user_id, matched.items.len });
                try insertHardwareMatchAudit(self.allocator, lease.conn, user_id, detail);
                const matched_detail = try std.fmt.bufPrint(&detail_buf, "mode=observe exact_hardware_match matched_user:{d} match_count:{d}", .{ user_id, matched.items.len });
                try insertHardwareMatchAudit(self.allocator, lease.conn, matched_user_id, matched_detail);
            }
        }

        const owned_matches = try matched.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_matches);
        try postgres.exec(lease.conn, "COMMIT");
        return .{ .allocator = self.allocator, .matched_user_ids = owned_matches };
    }

    pub fn recordLastFmFlag(self: *Store, user_id: i32, flags: u32) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var user_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT id FROM zigcho.users WHERE id=$1 FOR UPDATE", &.{user});
        defer user_lock.deinit();
        try postgres.exec(lease.conn, "DELETE FROM zigcho.audit_log WHERE id IN (SELECT id FROM zigcho.audit_log WHERE action='stable.lastfm_flag' AND created_at<extract(epoch FROM clock_timestamp())::bigint-15552000 ORDER BY created_at,id LIMIT 128)");
        var target_buf: [24]u8 = undefined;
        var detail_buf: [32]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
        const detail = try std.fmt.bufPrint(&detail_buf, "flags:{d}", .{flags});
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) SELECT $1,'stable.lastfm_flag',$2,$3 WHERE NOT EXISTS(SELECT 1 FROM zigcho.audit_log WHERE actor_id=$1 AND action='stable.lastfm_flag' AND target=$2 AND detail=$3 AND created_at>=extract(epoch FROM clock_timestamp())::bigint-86400)", &.{ user, target, detail });
        result.deinit();
        try postgres.exec(lease.conn, "COMMIT");
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
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var previous = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.status,b.status_frozen,EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.map_md5=b.md5) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.beatmap_id=b.id) FROM zigcho.beatmaps b WHERE b.id=$1 FOR UPDATE", &.{map_id});
        defer previous.deinit();
        const previous_status: ?i8 = if (previous.rows() == 0) null else try previous.int(i8, 0, 0);
        const previous_frozen = previous.rows() != 0 and try previous.boolean(0, 1);
        const had_scores = previous.rows() != 0 and try previous.boolean(0, 2);
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ map_id, set_id, md5, metadata.artist, metadata.title, metadata.version, metadata.creator, status_text, total_length, combo, mode, bpm, cs, ar, od, hp, star_rating, metadata.source, metadata.tags, file_param, circles, sliders, spinners });
        result.deinit();
        if (update_existing) if (previous_status) |old_status| {
            const effective_status = if (previous_frozen) old_status else status;
            const leaderboard_changed = (old_status >= 3) != (effective_status >= 3);
            const ranked_changed = (old_status == 3 or old_status == 4) != (effective_status == 3 or effective_status == 4);
            if (had_scores and (leaderboard_changed or ranked_changed)) {
                try self.rebuildRankedStats(lease.conn, false);
                try self.recordBeatmapStatsHistoryCurrentWithConnection(lease.conn, metadata.id, md5);
            }
        };
        try postgres.exec(lease.conn, "COMMIT");
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
        errdefer allocator.free(participant_ids_json);
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
        var result = try postgres.query(lease.conn, "SELECT greatest(coalesce((SELECT max(room_id) FROM zigcho.lazer_multiplayer_room_history),0),coalesce((SELECT max(room_id) FROM zigcho.lazer_ranked_matches),0))+1");
        defer result.deinit();
        if (result.rows() != 1) return error.DatabaseQueryFailed;
        return result.int(i64, 0, 0);
    }

    pub fn saveLazerMultiplayerRoomArchive(self: *Store, room_id: i64, owner_id: i32, category: []const u8, room_json: []const u8, leaderboard_json: []const u8, participant_ids_json: []const u8) !void {
        if (room_id <= 0 or owner_id <= 0 or room_json.len == 0 or room_json.len > 8 * 1024 * 1024 or leaderboard_json.len == 0 or leaderboard_json.len > 512 * 1024 or participant_ids_json.len == 0 or participant_ids_json.len > 4096) return error.InvalidMultiplayerArchive;
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

    pub fn updateLazerMultiplayerRoomArchive(self: *Store, room_id: i64, room_json: []const u8, leaderboard_json: []const u8) !void {
        if (room_id <= 0 or room_json.len == 0 or room_json.len > 8 * 1024 * 1024 or leaderboard_json.len == 0 or leaderboard_json.len > 512 * 1024) return error.InvalidMultiplayerArchive;
        var room_buf: [24]u8 = undefined;
        const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.lazer_multiplayer_room_history SET room_json=$2::jsonb,leaderboard_json=$3::jsonb WHERE room_id=$1 AND coalesce((room_json->>'zigcho_resumable')::boolean,false)=false RETURNING room_id", &.{ room_id_text, room_json, leaderboard_json });
        defer result.deinit();
        if (result.rows() != 1) return error.InvalidMultiplayerArchive;
    }

    pub fn lazerMultiplayerRoomArchive(self: *Store, allocator: std.mem.Allocator, room_id: i64) !?MultiplayerRoomArchive {
        if (room_id <= 0) return null;
        var room_buf: [24]u8 = undefined;
        const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT room_id,owner_id,category,room_json::text,leaderboard_json::text,participant_ids_json::text,ended_at FROM zigcho.lazer_multiplayer_room_history WHERE room_id=$1 AND coalesce((room_json->>'zigcho_resumable')::boolean,false)=false", &.{room_id_text});
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
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT room_id,owner_id,category,room_json::text,leaderboard_json::text,participant_ids_json::text,ended_at FROM zigcho.lazer_multiplayer_room_history WHERE coalesce((room_json->>'zigcho_resumable')::boolean,false)=false ORDER BY ended_at DESC,room_id DESC LIMIT $1", &.{limit_text});
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

    pub fn lazerMultiplayerRoomCheckpoints(self: *Store, allocator: std.mem.Allocator) ![]MultiplayerRoomArchive {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.query(lease.conn, "SELECT room_id,owner_id,category,room_json::text,leaderboard_json::text,participant_ids_json::text,ended_at FROM zigcho.lazer_multiplayer_room_history WHERE coalesce((room_json->>'zigcho_resumable')::boolean,false)=true ORDER BY room_id LIMIT 64");
        defer result.deinit();
        const checkpoints = try allocator.alloc(MultiplayerRoomArchive, result.rows());
        var initialized: usize = 0;
        errdefer {
            for (checkpoints[0..initialized]) |*checkpoint| checkpoint.deinit();
            allocator.free(checkpoints);
        }
        for (checkpoints, 0..) |*checkpoint, row| {
            checkpoint.* = try multiplayerRoomArchiveFromResult(allocator, result, row);
            initialized += 1;
        }
        return checkpoints;
    }

    pub fn deleteLazerMultiplayerRoomCheckpoint(self: *Store, room_id: i64) !void {
        if (room_id <= 0) return error.InvalidMultiplayerArchive;
        var room_buf: [24]u8 = undefined;
        const room_id_text = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_multiplayer_room_history WHERE room_id=$1 AND coalesce((room_json->>'zigcho_resumable')::boolean,false)=true", &.{room_id_text});
        result.deinit();
    }

    pub fn lazerRankedRating(self: *Store, user_id: i32, ruleset_id: u8) !LazerRankedRating {
        if (user_id <= 0 or ruleset_id > 3) return error.InvalidRankedPlayUser;
        var user_buf: [16]u8 = undefined;
        var ruleset_buf: [4]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const ruleset = try std.fmt.bufPrint(&ruleset_buf, "{d}", .{ruleset_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT rating,games_played,wins,losses FROM zigcho.lazer_ranked_ratings WHERE user_id=$1 AND ruleset_id=$2", &.{ user, ruleset });
        defer result.deinit();
        if (result.rows() == 0) return .{};
        return .{
            .rating = try result.int(i32, 0, 0),
            .games_played = try result.int(i32, 0, 1),
            .wins = try result.int(i32, 0, 2),
            .losses = try result.int(i32, 0, 3),
        };
    }

    pub fn applyLazerRankedResult(self: *Store, room_id: i64, ruleset_id: u8, winner_id: i32, loser_id: i32) !LazerRankedResult {
        try sqlite_storage.validateRankedPlayResult(room_id, ruleset_id, winner_id, loser_id);
        var room_buf: [24]u8 = undefined;
        var ruleset_buf: [4]u8 = undefined;
        var winner_buf: [16]u8 = undefined;
        var loser_buf: [16]u8 = undefined;
        const room = try std.fmt.bufPrint(&room_buf, "{d}", .{room_id});
        const ruleset = try std.fmt.bufPrint(&ruleset_buf, "{d}", .{ruleset_id});
        const winner = try std.fmt.bufPrint(&winner_buf, "{d}", .{winner_id});
        const loser = try std.fmt.bufPrint(&loser_buf, "{d}", .{loser_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        var committed = false;
        defer if (!committed) postgres.exec(lease.conn, "ROLLBACK") catch {};

        var advisory = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{room});
        advisory.deinit();
        var existing = try postgres.queryParams(self.allocator, lease.conn, "SELECT ruleset_id,winner_id,loser_id,winner_rating_before,winner_rating_after,loser_rating_before,loser_rating_after FROM zigcho.lazer_ranked_matches WHERE room_id=$1", &.{room});
        if (existing.rows() != 0) {
            if (try existing.int(u8, 0, 0) != ruleset_id or try existing.int(i32, 0, 1) != winner_id or try existing.int(i32, 0, 2) != loser_id) {
                existing.deinit();
                return error.RankedPlayResultConflict;
            }
            const stored: LazerRankedResult = .{
                .applied = false,
                .winner_rating_before = try existing.int(i32, 0, 3),
                .winner_rating_after = try existing.int(i32, 0, 4),
                .loser_rating_before = try existing.int(i32, 0, 5),
                .loser_rating_after = try existing.int(i32, 0, 6),
            };
            existing.deinit();
            try postgres.exec(lease.conn, "COMMIT");
            committed = true;
            return stored;
        }
        existing.deinit();

        var initialise = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_ranked_ratings(user_id,ruleset_id) VALUES($1,$3),($2,$3) ON CONFLICT(user_id,ruleset_id) DO NOTHING", &.{ winner, loser, ruleset });
        initialise.deinit();
        var ratings = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id,rating FROM zigcho.lazer_ranked_ratings WHERE ruleset_id=$3 AND user_id IN($1,$2) ORDER BY user_id FOR UPDATE", &.{ winner, loser, ruleset });
        defer ratings.deinit();
        if (ratings.rows() != 2) return error.DatabaseQueryFailed;
        var winner_rating_before: ?i32 = null;
        var loser_rating_before: ?i32 = null;
        for (0..ratings.rows()) |row| {
            const user_id = try ratings.int(i32, row, 0);
            if (user_id == winner_id) winner_rating_before = try ratings.int(i32, row, 1);
            if (user_id == loser_id) loser_rating_before = try ratings.int(i32, row, 1);
        }
        const winner_before = winner_rating_before orelse return error.DatabaseQueryFailed;
        const loser_before = loser_rating_before orelse return error.DatabaseQueryFailed;
        const winner_after = std.math.add(i32, winner_before, sqlite_storage.ranked_play_rating_delta) catch return error.RankedPlayRatingOverflow;
        const loser_after = std.math.sub(i32, loser_before, sqlite_storage.ranked_play_rating_delta) catch return error.RankedPlayRatingOverflow;
        var winner_after_buf: [16]u8 = undefined;
        var loser_after_buf: [16]u8 = undefined;
        const winner_after_text = try std.fmt.bufPrint(&winner_after_buf, "{d}", .{winner_after});
        const loser_after_text = try std.fmt.bufPrint(&loser_after_buf, "{d}", .{loser_after});
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.lazer_ranked_ratings SET rating=CASE user_id WHEN $1 THEN $4::integer ELSE $5::integer END,games_played=games_played+1,wins=wins+CASE WHEN user_id=$1 THEN 1 ELSE 0 END,losses=losses+CASE WHEN user_id=$2 THEN 1 ELSE 0 END,updated_at=extract(epoch FROM clock_timestamp())::bigint WHERE ruleset_id=$3 AND user_id IN($1,$2) RETURNING user_id", &.{ winner, loser, ruleset, winner_after_text, loser_after_text });
        defer update.deinit();
        if (update.rows() != 2) return error.DatabaseQueryFailed;
        var winner_before_buf: [16]u8 = undefined;
        var loser_before_buf: [16]u8 = undefined;
        const winner_before_text = try std.fmt.bufPrint(&winner_before_buf, "{d}", .{winner_before});
        const loser_before_text = try std.fmt.bufPrint(&loser_before_buf, "{d}", .{loser_before});
        var match = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_ranked_matches(room_id,ruleset_id,winner_id,loser_id,winner_rating_before,winner_rating_after,loser_rating_before,loser_rating_after) VALUES($1,$2,$3,$4,$5,$6,$7,$8)", &.{ room, ruleset, winner, loser, winner_before_text, winner_after_text, loser_before_text, loser_after_text });
        match.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        committed = true;
        return .{
            .applied = true,
            .winner_rating_before = winner_before,
            .winner_rating_after = winner_after,
            .loser_rating_before = loser_before,
            .loser_rating_after = loser_after,
        };
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

    pub fn consumedLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64) !?ConsumedLazerScoreToken {
        var buffers: [3][64]u8 = undefined;
        var cursor: usize = 0;
        const token = try param(&buffers, &cursor, token_id);
        const user = try param(&buffers, &cursor, user_id);
        const map = try param(&buffers, &cursor, beatmap_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT t.score_id,s.total_score,s.accuracy,s.max_combo,s.passed FROM zigcho.lazer_score_tokens t JOIN zigcho.lazer_scores s ON s.id=t.score_id WHERE t.id=$1 AND t.user_id=$2 AND t.beatmap_id=$3 AND t.consumed_at IS NOT NULL", &.{ token, user, map });
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{
            .score_id = try result.int(i64, 0, 0),
            .total_score = try result.int(i64, 0, 1),
            .accuracy = try result.float(f64, 0, 2),
            .max_combo = try result.int(i32, 0, 3),
            .passed = try result.boolean(0, 4),
        };
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
        var stats_eligibility_changed = false;
        for (package.maps) |map| {
            if (map.metadata.set_id != set_id) return error.BssRevisionMismatch;
            var map_id_buf: [24]u8 = undefined;
            const map_id = try std.fmt.bufPrint(&map_id_buf, "{d}", .{map.metadata.id});
            var active = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.beatmap_submission_maps WHERE set_id=$1 AND beatmap_id=$2 AND active", &.{ set, map_id });
            defer active.deinit();
            if (active.rows() != 1) return error.BssRevisionMismatch;
            var previous_map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.status,EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.map_md5=b.md5) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.beatmap_id=b.id) FROM zigcho.beatmaps b WHERE b.id=$1 FOR UPDATE", &.{map_id});
            defer previous_map.deinit();
            if (previous_map.rows() != 0 and try previous_map.boolean(0, 1)) {
                const old_status = try previous_map.int(i32, 0, 0);
                const new_status = target.status();
                stats_eligibility_changed = stats_eligibility_changed or (old_status >= 3) != (new_status >= 3) or (old_status == 3 or old_status == 4) != (new_status == 3 or new_status == 4);
            }
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
        if (stats_eligibility_changed) {
            try self.rebuildRankedStats(lease.conn, false);
            try self.recordAllStatsHistoryCurrentWithConnection(lease.conn);
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
        const filter = " FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.map_md5=$1 AND s.mode=$2 AND s.passed AND s.best AND s.rank_namespace=$3 AND ($4::int!=2 OR s.mods=$5) AND ($4::int!=3 OR s.user_id=$6 OR EXISTS(SELECT 1 FROM zigcho.friends f JOIN zigcho.users friend_sender ON friend_sender.id=f.user_id JOIN zigcho.users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=$6 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND NOT friend_sender.restricted AND NOT friend_target.restricted)) AND ($4::int!=4 OR u.country=$7)";
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
                "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1"
            else
                "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id WHERE s.id=$1", &.{personal_id_text});
            defer personal_row.deinit();
            if (personal_row.rows() == 0) return error.DatabaseQueryFailed;
            try writeBoardRow(writer, personal_row, 0, try personal_rank.int(i32, 0, 0), uses_pp);
        }
        try writer.writeByte('\n');
        var rows = try postgres.queryParams(self.allocator, lease.conn, if (uses_pp)
            "SELECT s.id,u.name,s.pp,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id))" ++ filter ++ " ORDER BY s.pp DESC,s.id ASC LIMIT 50"
        else
            "SELECT s.id,u.name,s.score,s.max_combo,s.n50,s.n100,s.n300,s.nmiss,s.nkatu,s.ngeki,s.perfect,s.mods,s.user_id,s.submitted_at,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id))" ++ filter ++ " ORDER BY s.score DESC,s.id ASC LIMIT 50", params);
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
        var set_result = try postgres.queryParams(self.allocator, conn, "SELECT b.set_id,min(b.artist),min(b.title),coalesce(max(owner.name),min(b.creator)),min(b.status),max(b.bpm),min(b.source),min(b.tags),coalesce(max(m.submitted_date),coalesce(to_char(to_timestamp(max(b.last_update)) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),sum(b.plays),least((SELECT count(*) FROM zigcho.favourites f WHERE f.set_id=b.set_id),2147483647),coalesce(max(m.last_updated),coalesce(to_char(to_timestamp(max(b.last_update)) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),max(m.ranked_date),coalesce(bool_or(m.has_video),false),coalesce(max(m.genre_id),0),coalesce(max(m.language_id),0),coalesce(max(owner.id),max(b.creator_id),0) FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.set_id=$1 GROUP BY b.set_id", &.{set});
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
        // The pinned APIBeatmapSet.user setter dereferences null. Search responses
        // intentionally omit detailed mapper data when it has not been cached.
        const local_profile_sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ " FROM zigcho.beatmap_submissions submission JOIN zigcho.users u ON u.id=submission.owner_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE submission.set_id=$1 AND submission.state='published'";
        var local_profile = try postgres.queryParams(self.allocator, conn, local_profile_sql, &.{set});
        defer local_profile.deinit();
        if (local_profile.rows() != 0) {
            try writer.writeAll(",\"user\":");
            const local_user = try userFromResult(self.allocator, local_profile, 0);
            defer self.allocator.free(local_user.name);
            defer self.allocator.free(local_user.safe_name);
            try user_json.writeCompact(writer, local_user, local_user.show_country);
        } else if (creator_id > 0) {
            var creator_buf: [24]u8 = undefined;
            const creator = try std.fmt.bufPrint(&creator_buf, "{d}", .{creator_id});
            var profile = try postgres.queryParams(self.allocator, conn, "SELECT profile_json::text FROM zigcho.upstream_user_profiles WHERE user_id=$1 ORDER BY mode=0 DESC,mode LIMIT 1", &.{creator});
            defer profile.deinit();
            if (profile.rows() != 0) {
                try writer.writeAll(",\"user\":");
                try writer.writeAll(profile.value(0, 0));
            }
        }
        try writer.writeAll(",\"beatmaps\":[");
        var maps = try postgres.queryParams(self.allocator, conn, "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.set_id=$1 ORDER BY b.star_rating,b.id", &.{set});
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
            "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.md5=$1"
        else
            "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.id=$1";
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

    pub fn lazerOwnedBeatmapSearch(self: *Store, allocator: std.mem.Allocator, user_id: i32, query: []const u8, mode: i8, offset: u16, requester_id: ?i32) ![]u8 {
        var user_buf: [24]u8 = undefined;
        var mode_buf: [4]u8 = undefined;
        var offset_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const mode_text = try std.fmt.bufPrint(&mode_buf, "{d}", .{mode});
        const offset_text = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});
        var lease = self.pool.acquire();
        defer lease.release();
        var count = try postgres.queryParams(self.allocator, lease.conn, "SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=$1 AND submission.state='published' AND ($2::int=-1 OR b.mode=$2::int) AND ($3='' OR strpos(lower(b.artist||' '||b.title||' '||b.creator||' '||b.source||' '||b.tags),lower($3))>0) GROUP BY submission.set_id) owned", &.{ user, mode_text, query });
        defer count.deinit();
        const total: usize = @intCast(try count.int(i64, 0, 0));
        var ids = try postgres.queryParams(self.allocator, lease.conn, "SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=$1 AND submission.state='published' AND ($2::int=-1 OR b.mode=$2::int) AND ($3='' OR strpos(lower(b.artist||' '||b.title||' '||b.creator||' '||b.source||' '||b.tags),lower($3))>0) GROUP BY submission.set_id,submission.updated_at ORDER BY submission.updated_at DESC,submission.set_id DESC LIMIT 50 OFFSET $4", &.{ user, mode_text, query, offset_text });
        defer ids.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"beatmapsets\":[");
        var written: usize = 0;
        for (0..ids.rows()) |row| {
            var set_output: std.Io.Writer.Allocating = .init(allocator);
            defer set_output.deinit();
            if (!try self.appendLazerSet(lease.conn, &set_output.writer, try ids.int(i32, row, 0), requester_id)) continue;
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try output.writer.writeAll(set_output.written());
        }
        const next_offset = @as(usize, offset) + ids.rows();
        try output.writer.print("],\"total\":{d},\"cursor\":", .{total});
        if (next_offset < total) try output.writer.print("{{\"offset\":{d}}}", .{next_offset}) else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
        return output.toOwnedSlice();
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

    pub fn lazerMostPlayedJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, requester_id: i32, offset: u16, limit: u8) ![]u8 {
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
            var map = try postgres.queryParams(self.allocator, lease.conn, "SELECT b.id,b.set_id,b.status,b.md5,b.plays,b.passes,b.mode,b.star_rating,b.hp,b.cs,b.ar,b.od,b.total_length,b.version,b.max_combo,coalesce(m.last_updated,coalesce(to_char(to_timestamp(b.last_update) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),'1970-01-01T00:00:00Z')),b.bpm,b.count_circles,b.count_sliders,b.count_spinners,coalesce(owner.id,b.creator_id,0),coalesce(owner.name,b.creator),CASE WHEN b.hit_length>0 THEN b.hit_length ELSE b.total_length END FROM zigcho.beatmaps b LEFT JOIN zigcho.beatmapset_metadata m ON m.set_id=b.set_id LEFT JOIN zigcho.beatmap_submissions submission ON submission.set_id=b.set_id AND submission.state='published' LEFT JOIN zigcho.users owner ON owner.id=submission.owner_id WHERE b.id=$1", &.{map_id});
            defer map.deinit();
            if (map.rows() == 0) continue;
            var set: std.Io.Writer.Allocating = .init(allocator);
            defer set.deinit();
            if (!try self.appendLazerSet(lease.conn, &set.writer, try map.int(i32, 0, 1), requester_id)) continue;
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try output.writer.print("{{\"beatmap_id\":{d},\"count\":{d},\"beatmap\":", .{ beatmap_id, try rows.int(i64, row, 1) });
            try self.appendLazerMap(lease.conn, &output.writer, map, 0, requester_id);
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

    pub fn lazerProfileSummary(self: *Store, user_id: i32) !?domain.ProfileSummary {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        const sql =
            "SELECT u.created_at,coalesce(u.last_login,0),coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.preferred_mode,u.profile_title,u.profile_location,u.profile_website,u.show_country,u.show_profile_stats,u.show_recent_scores," ++
            "(SELECT count(*) FROM zigcho.favourites f WHERE f.user_id=u.id)," ++
            "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status) IN(3,4)) sets)," ++
            "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=6) sets)," ++
            "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=2) sets)," ++
            "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=1) sets)," ++
            "(SELECT count(*) FROM (SELECT submission.set_id FROM zigcho.beatmap_submissions submission JOIN zigcho.beatmaps b ON b.set_id=submission.set_id WHERE submission.owner_id=u.id AND submission.state='published' GROUP BY submission.set_id HAVING min(b.status)=5) sets)," ++
            "(SELECT count(*) FROM (SELECT b.id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=u.id UNION SELECT s.beatmap_id FROM zigcho.lazer_scores s WHERE s.user_id=u.id) played)," ++
            visible_follower_count_sql ++ " " ++
            "FROM zigcho.users u WHERE u.id=$1";
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        var summary = try domain.ProfileSummary.init(
            try result.int(i64, 0, 0),
            try result.int(i64, 0, 1),
            try result.int(i64, 0, 2),
            try result.int(u8, 0, 3),
            result.value(0, 4),
            result.value(0, 5),
            result.value(0, 6),
        );
        summary.show_country = try result.boolean(0, 7);
        summary.show_profile_stats = try result.boolean(0, 8);
        summary.show_recent_scores = try result.boolean(0, 9);
        summary.favourite_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 10)));
        summary.ranked_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 11)));
        summary.loved_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 12)));
        summary.pending_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 13)));
        summary.graveyard_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 14)));
        summary.nominated_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 15)));
        summary.played_beatmap_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 16)));
        summary.follower_count = @intCast(@min(@as(i64, std.math.maxInt(i32)), try result.int(i64, 0, 17)));
        return summary;
    }

    pub fn lazerBatchUserVisibility(self: *Store, user_id: i32) !?domain.BatchUserVisibility {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        const sql = "SELECT coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.show_country,u.show_profile_stats," ++ visible_follower_count_sql ++ " FROM zigcho.users u WHERE u.id=$1";
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return .{
            .avatar_version = try result.int(i64, 0, 0),
            .show_country = try result.boolean(0, 1),
            .show_profile_stats = try result.boolean(0, 2),
            .follower_count = try result.int(i32, 0, 3),
        };
    }

    pub fn lazerMonthlyPlaycountsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const sql =
            "WITH plays AS (SELECT submitted_at FROM zigcho.scores WHERE user_id=$1 UNION ALL SELECT submitted_at FROM zigcho.lazer_scores WHERE user_id=$1) " ++
            "SELECT to_char(date_trunc('month',to_timestamp(submitted_at) AT TIME ZONE 'UTC'),'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),count(*) FROM plays GROUP BY date_trunc('month',to_timestamp(submitted_at) AT TIME ZONE 'UTC') ORDER BY 1";
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{id});
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"start_date\":");
            try jsonString(&output.writer, result.value(row, 0));
            try output.writer.print(",\"count\":{d}}}", .{try result.int(i64, row, 1)});
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerReplaysWatchedCountsJson(self: *Store, allocator: std.mem.Allocator, user_id: i32, ruleset_id: u8) ![]u8 {
        if (ruleset_id > 3) return error.InvalidRulesetId;
        var buffers: [2][24]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffers[0], "{d}", .{user_id});
        const mode = try std.fmt.bufPrint(&buffers[1], "{d}", .{ruleset_id});
        const sql =
            "SELECT to_char(date_trunc('month',to_timestamp(viewed_at) AT TIME ZONE 'UTC'),'YYYY-MM-DD'),count(*) FROM zigcho.score_replay_views " ++
            "WHERE owner_id=$1 AND mode=$2 AND rank_namespace='vanilla' " ++
            "GROUP BY date_trunc('month',to_timestamp(viewed_at) AT TIME ZONE 'UTC') ORDER BY 1";
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{ id, mode });
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"start_date\":");
            try jsonString(&output.writer, result.value(row, 0));
            try output.writer.print(",\"count\":{d}}}", .{try result.int(i64, row, 1)});
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
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
        var token_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
        token_lock.deinit();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET password_hash=$1,password_salt=convert_to('argon2id','UTF8') WHERE id=$2 AND id!=3 RETURNING id", &.{ hash_bytea, id });
        defer result.deinit();
        if (result.rows() != 1) return error.UserNotFound;
        try insertAudit(self.allocator, lease.conn, user_id, "account.password", user_id, "password changed");
        var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL", &.{id});
        revoke.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
        clear.deinit();
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
        var token_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
        token_lock.deinit();
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
        var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL", &.{id});
        revoke.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
        clear.deinit();
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn revokeAllTokensForUser(self: *Store, user_id: i32) !usize {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL RETURNING 1", &.{id});
        const revoked = result.rows();
        result.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
        clear.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return revoked;
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
        const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ ",u.password_hash,u.password_salt FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.safe_name=$1";
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{safe});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const user = try userFromResult(allocator, result, 0);
        errdefer {
            allocator.free(user.name);
            allocator.free(user.safe_name);
        }
        const password_hash = try postgres.decodeBytea(allocator, result.value(0, 14));
        errdefer allocator.free(password_hash);
        const password_salt = try postgres.decodeBytea(allocator, result.value(0, 15));
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
        const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ " FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1";
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try userFromResult(allocator, result, 0);
    }

    pub fn userByName(self: *Store, allocator: std.mem.Allocator, name: []const u8) !?domain.User {
        const safe = try domain.safeName(allocator, name);
        defer allocator.free(safe);
        var lease = self.pool.acquire();
        defer lease.release();
        const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ " FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.safe_name=$1";
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{safe});
        defer result.deinit();
        if (result.rows() == 0) return null;
        return try userFromResult(allocator, result, 0);
    }

    pub fn siteNameHistoryJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        const sql =
            "SELECT u.id,u.name,h.old_name,h.changed_at FROM zigcho.users u " ++
            "LEFT JOIN LATERAL (SELECT old_name,changed_at,id FROM zigcho.user_name_changes WHERE user_id=u.id ORDER BY changed_at DESC,id DESC LIMIT 20) h ON true " ++
            "WHERE u.id=$1 AND u.id!=3 AND NOT u.restricted ORDER BY h.changed_at DESC,h.id DESC";
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;

        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"id\":{d},\"name\":", .{try result.int(i32, 0, 0)});
        try jsonString(&output.writer, result.value(0, 1));
        try output.writer.writeAll(",\"history\":[");
        var first = true;
        for (0..result.rows()) |row| {
            if (result.isNull(row, 2)) continue;
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.writeAll("{\"name\":");
            try jsonString(&output.writer, result.value(row, 2));
            try output.writer.print(",\"changed_at\":{d}}}", .{try result.int(i64, row, 3)});
        }
        try output.writer.writeAll("]}");
        var list = output.toArrayList();
        return @as(?[]u8, try list.toOwnedSlice(allocator));
    }

    pub fn friendIds(self: *Store, allocator: std.mem.Allocator, user_id: i32) ![]i32 {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        const sql = "SELECT relation.friend_id FROM zigcho.friends relation JOIN zigcho.users sender ON sender.id=relation.user_id JOIN zigcho.users target ON target.id=relation.friend_id WHERE relation.user_id=$1 AND NOT sender.restricted AND NOT target.restricted ORDER BY relation.friend_id LIMIT 1000";
        var result = try postgres.queryParams(allocator, lease.conn, sql, &.{id});
        defer result.deinit();
        var list: std.ArrayList(i32) = .empty;
        errdefer list.deinit(allocator);
        for (0..result.rows()) |row| try list.append(allocator, try result.int(i32, row, 0));
        if (user_id != 3 and std.mem.indexOfScalar(i32, list.items, 3) == null) try list.append(allocator, 3);
        return list.toOwnedSlice(allocator);
    }

    pub fn addFriend(self: *Store, user_id: i32, friend_id: i32) !domain.RelationshipAddResult {
        var user_buf: [24]u8 = undefined;
        var friend_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const friend = try std.fmt.bufPrint(&friend_buf, "{d}", .{friend_id});
        var lease = self.pool.acquire();
        defer lease.release();
        const sql =
            "WITH eligible AS (SELECT sender.id user_id,target.id friend_id FROM zigcho.users sender JOIN zigcho.users target ON target.id=$2 " ++
            "WHERE sender.id=$1 AND sender.id!=target.id AND target.id!=3 AND NOT sender.restricted AND NOT target.restricted)," ++
            "inserted AS (INSERT INTO zigcho.friends(user_id,friend_id) SELECT user_id,friend_id FROM eligible ON CONFLICT DO NOTHING RETURNING 1) " ++
            "SELECT CASE WHEN EXISTS(SELECT 1 FROM inserted) THEN 1 WHEN EXISTS(SELECT 1 FROM eligible) THEN 2 ELSE 0 END";
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ user, friend });
        defer result.deinit();
        return switch (try result.int(u8, 0, 0)) {
            1 => .inserted,
            2 => .existing,
            else => .ineligible,
        };
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
        const sql = "SELECT EXISTS(SELECT 1 FROM zigcho.friends relation JOIN zigcho.users sender ON sender.id=relation.user_id JOIN zigcho.users target ON target.id=relation.friend_id WHERE relation.user_id=$1 AND relation.friend_id=$2 AND sender.id!=target.id AND target.id!=3 AND NOT sender.restricted AND NOT target.restricted)::int";
        var result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ friend, user });
        defer result.deinit();
        return try result.int(i32, 0, 0) != 0;
    }

    fn replayViewCountWithConnection(self: *Store, conn: *postgres.c.PGconn, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !i32 {
        if (!domain.validSiteMode(source, stats_mode)) return error.InvalidScoreSource;
        var buffers: [2][24]u8 = undefined;
        const user = try std.fmt.bufPrint(&buffers[0], "{d}", .{user_id});
        const mode = try std.fmt.bufPrint(&buffers[1], "{d}", .{stats_mode});
        var result = try postgres.queryParams(self.allocator, conn, "SELECT count(*) FROM zigcho.score_replay_views WHERE owner_id=$1 AND mode=$2 AND rank_namespace=$3 AND ($4='all' OR ($4='scorev2' AND source='stable') OR source=$4)", &.{ user, mode, domain.siteNamespace(source, stats_mode), @tagName(source) });
        defer result.deinit();
        return try result.int(i32, 0, 0);
    }

    pub fn replayViewCount(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !i32 {
        var lease = self.pool.acquire();
        defer lease.release();
        return self.replayViewCountWithConnection(lease.conn, user_id, source, stats_mode);
    }

    pub fn recordReplayView(self: *Store, viewer_id: i32, source: ReplaySource, score_id: i64) !bool {
        if (viewer_id <= 0 or score_id <= 0) return false;
        var buffers: [2][32]u8 = undefined;
        const viewer = try std.fmt.bufPrint(&buffers[0], "{d}", .{viewer_id});
        const score = try std.fmt.bufPrint(&buffers[1], "{d}", .{score_id});
        const stable_sql =
            "INSERT INTO zigcho.score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) " ++
            "SELECT 'stable',s.id,$1,s.user_id,CASE WHEN (s.mods&8192)!=0 THEN s.mode+8 WHEN (s.mods&128)!=0 THEN s.mode+4 ELSE s.mode END,s.rank_namespace FROM zigcho.scores s " ++
            "WHERE s.id=$2 AND s.user_id!=$1 AND s.passed AND s.rank_namespace IN('vanilla','relax','autopilot','scorev2') " ++
            "ON CONFLICT(source,score_id,viewer_id) DO UPDATE SET viewed_at=extract(epoch FROM clock_timestamp())::bigint RETURNING 1";
        const lazer_sql =
            "INSERT INTO zigcho.score_replay_views(source,score_id,viewer_id,owner_id,mode,rank_namespace) " ++
            "SELECT 'lazer',s.id,$1,s.user_id,CASE s.rank_namespace WHEN 'vanilla' THEN s.ruleset_id WHEN 'relax' THEN s.ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE -1 END,s.rank_namespace FROM zigcho.lazer_scores s " ++
            "WHERE s.id=$2 AND s.user_id!=$1 AND s.passed AND s.rank_namespace IN('vanilla','relax','autopilot') " ++
            "ON CONFLICT(source,score_id,viewer_id) DO UPDATE SET viewed_at=extract(epoch FROM clock_timestamp())::bigint RETURNING 1";
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, if (source == .stable) stable_sql else lazer_sql, &.{ viewer, score });
        defer result.deinit();
        return result.rows() != 0;
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
            const user_sql = "SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,u.restricted," ++ visible_follower_count_sql ++ " FROM zigcho.users u WHERE u.id=$1";
            var user_row = try postgres.queryParams(allocator, lease.conn, user_sql, &.{id_text});
            defer user_row.deinit();
            if (user_row.rows() == 0) continue;
            if (index != 0) try output.writer.writeByte(',');
            const country = user_row.value(0, 2);
            const user_value: domain.User = .{ .id = id, .name = user_row.value(0, 1), .safe_name = "", .country = .{ country[0], country[1] }, .privileges = try user_row.int(u32, 0, 3), .restricted = try user_row.boolean(0, 4), .follower_count = try user_row.int(i32, 0, 5) };
            try user_json.writeCompact(&output.writer, user_value, true);
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

    pub fn storeDirectMessage(self: *Store, from_id: i32, to_id: i32, message: []const u8) !i64 {
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
        var mirror = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message) VALUES($1,$2,$3) RETURNING id", &.{ from, target, message });
        defer mirror.deinit();
        const chat_message_id = try mirror.int(i64, 0, 0);
        var chat_buf: [24]u8 = undefined;
        const chat = try std.fmt.bufPrint(&chat_buf, "{d}", .{chat_message_id});
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.direct_messages(from_id,to_id,message,chat_message_id) VALUES($1,$2,$3,$4) RETURNING id", &.{ from, to, message, chat });
        defer result.deinit();
        const direct_message_id = try result.int(i64, 0, 0);
        try postgres.exec(lease.conn, "COMMIT");
        return direct_message_id;
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

    pub fn markDirectMessageRead(self: *Store, to_id: i32, message_id: i64) !bool {
        var to_buf: [24]u8 = undefined;
        var message_buf: [32]u8 = undefined;
        const to = try std.fmt.bufPrint(&to_buf, "{d}", .{to_id});
        const id = try std.fmt.bufPrint(&message_buf, "{d}", .{message_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.direct_messages SET read=true WHERE id=$1 AND to_id=$2 AND NOT read RETURNING 1", &.{ id, to });
        defer result.deinit();
        return result.rows() != 0;
    }

    pub fn recordPublicMessage(self: *Store, sender_id: i32, target: []const u8, message: []const u8) !void {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{sender_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message) VALUES($1,$2,$3)", &.{ id, target, message });
        result.deinit();
    }

    pub fn recordStaffAnnouncement(self: *Store, actor_id: i32, message: []const u8, reason: []const u8) !void {
        var actor_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var chat = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.chat_messages(sender_id,target,message) VALUES(3,'#announce',$1)", &.{message});
        chat.deinit();
        var audit = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,'infra.announcement','server',$2)", &.{ actor, reason });
        audit.deinit();
        try postgres.exec(lease.conn, "COMMIT");
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

    pub fn recordLazerRoomMessage(self: *Store, allocator: std.mem.Allocator, sender_id: i32, room_id: i64, message: []const u8, is_action: bool, uuid: []const u8) !LazerChatWrite {
        const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
        var sender_buffer: [24]u8 = undefined;
        var target_buffer: [64]u8 = undefined;
        const sender = try std.fmt.bufPrint(&sender_buffer, "{d}", .{sender_id});
        const target = try lazer.roomChannelName(&target_buffer, room_id);
        var lease = self.pool.acquire();
        defer lease.release();
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
        var direct_message_id: ?i64 = null;
        if (inserted) {
            var chat_buf: [24]u8 = undefined;
            const chat = try std.fmt.bufPrint(&chat_buf, "{d}", .{try row.int(i64, 0, 0)});
            var direct = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.direct_messages(from_id,to_id,message,is_action,client_uuid,chat_message_id) VALUES($1,$2,$3,$4,$5,$6) RETURNING id", &.{ sender, receiver, message, if (is_action) "true" else "false", uuid, chat });
            direct_message_id = try direct.int(i64, 0, 0);
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
        return .{ .json = try output.toOwnedSlice(), .inserted = inserted, .direct_message_id = direct_message_id };
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
        var viewer_buf: [24]u8 = undefined;
        var since_buf: [24]u8 = undefined;
        var limit_buf: [8]u8 = undefined;
        const low_pattern = try std.fmt.bufPrint(&low_pattern_buf, "@dm:{d}:%", .{viewer_id});
        const high_pattern = try std.fmt.bufPrint(&high_pattern_buf, "@dm:%:{d}", .{viewer_id});
        const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
        const since_text = try std.fmt.bufPrint(&since_buf, "{d}", .{since});
        const limit_text = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var lease = self.pool.acquire();
        defer lease.release();
        const filter = "target IN('#osu','#announce','#lobby','#lazer') OR target LIKE $1 OR target LIKE $2";
        const unread_filter = "(m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>coalesce((SELECT r.last_read_id FROM zigcho.lazer_channel_reads r WHERE r.user_id=$3::int AND r.channel_id=CASE m.target WHEN '#osu' THEN 1 WHEN '#announce' THEN 2 WHEN '#lobby' THEN 3 WHEN '#lazer' THEN 4 END),0)) OR ((m.target LIKE $1 OR m.target LIKE $2) AND EXISTS(SELECT 1 FROM zigcho.direct_messages d WHERE d.chat_message_id=m.id AND d.to_id=$3::int AND NOT d.read))";
        const sql = if (since == 0)
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT m.* FROM zigcho.chat_messages m WHERE " ++ unread_filter ++ " ORDER BY m.id DESC LIMIT $4::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
        else
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE (" ++ filter ++ ") AND m.id>$3::bigint AND NOT u.restricted ORDER BY m.id LIMIT $4::int";
        var result = if (since == 0)
            try postgres.queryParams(allocator, lease.conn, sql, &.{ low_pattern, high_pattern, viewer, limit_text })
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

    pub fn lazerAllMessagesForRoomJson(self: *Store, allocator: std.mem.Allocator, viewer_id: i32, room_id: i64, since: i64, limit: u16) ![]u8 {
        const room_channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
        if (viewer_id <= 0 or since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
        var low_pattern_buffer: [64]u8 = undefined;
        var high_pattern_buffer: [64]u8 = undefined;
        var room_target_buffer: [64]u8 = undefined;
        var viewer_buffer: [24]u8 = undefined;
        var since_buffer: [24]u8 = undefined;
        var limit_buffer: [8]u8 = undefined;
        var room_channel_buffer: [24]u8 = undefined;
        const low_pattern = try std.fmt.bufPrint(&low_pattern_buffer, "@dm:{d}:%", .{viewer_id});
        const high_pattern = try std.fmt.bufPrint(&high_pattern_buffer, "@dm:%:{d}", .{viewer_id});
        const room_target = try lazer.roomChannelName(&room_target_buffer, room_id);
        const viewer = try std.fmt.bufPrint(&viewer_buffer, "{d}", .{viewer_id});
        const since_text = try std.fmt.bufPrint(&since_buffer, "{d}", .{since});
        const limit_text = try std.fmt.bufPrint(&limit_buffer, "{d}", .{limit});
        const room_channel = try std.fmt.bufPrint(&room_channel_buffer, "{d}", .{room_channel_id});
        var lease = self.pool.acquire();
        defer lease.release();
        const filter = "target IN('#osu','#announce','#lobby','#lazer') OR target LIKE $1 OR target LIKE $2 OR target=$5";
        const unread_filter = "(m.target IN('#osu','#announce','#lobby','#lazer') AND m.id>coalesce((SELECT r.last_read_id FROM zigcho.lazer_channel_reads r WHERE r.user_id=$3::int AND r.channel_id=CASE m.target WHEN '#osu' THEN 1 WHEN '#announce' THEN 2 WHEN '#lobby' THEN 3 WHEN '#lazer' THEN 4 END),0)) OR ((m.target LIKE $1 OR m.target LIKE $2) AND EXISTS(SELECT 1 FROM zigcho.direct_messages d WHERE d.chat_message_id=m.id AND d.to_id=$3::int AND NOT d.read)) OR (m.target=$5 AND m.id>coalesce((SELECT r.last_read_id FROM zigcho.lazer_channel_reads r WHERE r.user_id=$3::int AND r.channel_id=$6::bigint),0))";
        const sql = if (since == 0)
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM (SELECT m.* FROM zigcho.chat_messages m WHERE " ++ unread_filter ++ " ORDER BY m.id DESC LIMIT $4::int) m JOIN zigcho.users u ON u.id=m.sender_id WHERE NOT u.restricted ORDER BY m.id"
        else
            "SELECT m.id,m.target,m.sender_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,m.message,m.is_action,m.client_uuid,to_char(to_timestamp(m.created_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),u.privileges FROM zigcho.chat_messages m JOIN zigcho.users u ON u.id=m.sender_id WHERE (" ++ filter ++ ") AND m.id>$3::bigint AND NOT u.restricted ORDER BY m.id LIMIT $4::int";
        var result = if (since == 0)
            try postgres.queryParams(allocator, lease.conn, sql, &.{ low_pattern, high_pattern, viewer, limit_text, room_target, room_channel })
        else
            try postgres.queryParams(allocator, lease.conn, sql, &.{ low_pattern, high_pattern, since_text, limit_text, room_target });
        defer result.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeByte('[');
        var written: usize = 0;
        for (0..result.rows()) |row| {
            const message_target = result.value(row, 1);
            const channel_id = if (std.mem.eql(u8, message_target, room_target))
                room_channel_id
            else
                lazer.channelId(message_target) orelse private: {
                    const other_id = lazer.directMessageOther(message_target, viewer_id) orelse continue;
                    break :private lazer.privateChannelId(other_id).?;
                };
            if (written != 0) try output.writer.writeByte(',');
            written += 1;
            try lazer.writeChatMessage(&output.writer, .{
                .id = try result.int(i64, row, 0),
                .channel_id = channel_id,
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

    pub fn lazerRoomMessagesJson(self: *Store, allocator: std.mem.Allocator, room_id: i64, since: i64, limit: u16) ![]u8 {
        const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
        if (since < 0 or limit == 0 or limit > 100) return error.InvalidChatQuery;
        var target_buffer: [64]u8 = undefined;
        var since_buffer: [24]u8 = undefined;
        var limit_buffer: [8]u8 = undefined;
        const target = try lazer.roomChannelName(&target_buffer, room_id);
        const since_text = try std.fmt.bufPrint(&since_buffer, "{d}", .{since});
        const limit_text = try std.fmt.bufPrint(&limit_buffer, "{d}", .{limit});
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
        for (0..result.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try lazer.writeChatMessage(&output.writer, .{
                .id = try result.int(i64, row, 0),
                .channel_id = channel_id,
                .sender_id = try result.int(i32, row, 1),
                .sender_name = result.value(row, 2),
                .sender_country = result.value(row, 3),
                .sender_privileges = try result.int(u32, row, 8),
                .content = result.value(row, 4),
                .is_action = try result.boolean(row, 5),
                .uuid = result.value(row, 6),
                .timestamp = result.value(row, 7),
            });
        }
        try output.writer.writeByte(']');
        return output.toOwnedSlice();
    }

    pub fn lazerRoomChannelCursor(self: *Store, user_id: i32, room_id: i64) !ChatCursor {
        if (user_id <= 0) return error.InvalidUser;
        const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
        var user_buffer: [24]u8 = undefined;
        var channel_buffer: [24]u8 = undefined;
        var target_buffer: [64]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buffer, "{d}", .{user_id});
        const channel = try std.fmt.bufPrint(&channel_buffer, "{d}", .{channel_id});
        const target = try lazer.roomChannelName(&target_buffer, room_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT (SELECT max(id) FROM zigcho.chat_messages WHERE target=$1),(SELECT last_read_id FROM zigcho.lazer_channel_reads WHERE user_id=$2::int AND channel_id=$3::bigint)", &.{ target, user, channel });
        defer result.deinit();
        if (result.rows() != 1) return error.DatabaseQueryFailed;
        return .{
            .last_message_id = if (result.isNull(0, 0)) null else try result.int(i64, 0, 0),
            .last_read_id = if (result.isNull(0, 1)) null else try result.int(i64, 0, 1),
        };
    }

    pub fn markLazerRoomChannelRead(self: *Store, user_id: i32, room_id: i64, message_id: i64) !void {
        if (user_id <= 0 or message_id <= 0) return error.InvalidChatQuery;
        const channel_id = lazer.roomChannelId(room_id) orelse return error.UnknownChannel;
        var user_buffer: [24]u8 = undefined;
        var channel_buffer: [24]u8 = undefined;
        var message_buffer: [24]u8 = undefined;
        var target_buffer: [64]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buffer, "{d}", .{user_id});
        const channel = try std.fmt.bufPrint(&channel_buffer, "{d}", .{channel_id});
        const message = try std.fmt.bufPrint(&message_buffer, "{d}", .{message_id});
        const target = try lazer.roomChannelName(&target_buffer, room_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_channel_reads(user_id,channel_id,last_read_id) SELECT $1::int,$2::bigint,$3::bigint WHERE EXISTS(SELECT 1 FROM zigcho.chat_messages WHERE id=$3::bigint AND target=$4) ON CONFLICT(user_id,channel_id) DO UPDATE SET last_read_id=greatest(zigcho.lazer_channel_reads.last_read_id,excluded.last_read_id),updated_at=extract(epoch FROM clock_timestamp())::bigint RETURNING 1", &.{ user, channel, message, target });
        defer result.deinit();
        if (result.rows() == 0) return error.ChatMessageNotFound;
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
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT max(m.id),CASE WHEN (SELECT min(d.chat_message_id) FROM zigcho.direct_messages d WHERE d.to_id=$2::int AND d.from_id=$3::int AND NOT d.read AND d.chat_message_id IS NOT NULL) IS NULL THEN max(m.id) ELSE (SELECT max(previous.id) FROM zigcho.chat_messages previous WHERE previous.target=$1 AND previous.id<(SELECT min(d.chat_message_id) FROM zigcho.direct_messages d WHERE d.to_id=$2::int AND d.from_id=$3::int AND NOT d.read AND d.chat_message_id IS NOT NULL)) END FROM zigcho.chat_messages m WHERE m.target=$1", &.{ target, viewer, other });
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

    pub fn markLazerDirectMessageRead(self: *Store, viewer_id: i32, other_id: i32, message_id: i64) !void {
        if (viewer_id <= 0 or other_id <= 0 or viewer_id == other_id or message_id <= 0) return error.InvalidChatQuery;
        var viewer_buf: [24]u8 = undefined;
        var other_buf: [24]u8 = undefined;
        var message_buf: [24]u8 = undefined;
        var target_buf: [64]u8 = undefined;
        const viewer = try std.fmt.bufPrint(&viewer_buf, "{d}", .{viewer_id});
        const other = try std.fmt.bufPrint(&other_buf, "{d}", .{other_id});
        const message = try std.fmt.bufPrint(&message_buf, "{d}", .{message_id});
        const target = try lazer.directMessageTarget(&target_buf, viewer_id, other_id);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var found = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.chat_messages WHERE id=$1::bigint AND target=$2", &.{ message, target });
        defer found.deinit();
        if (found.rows() == 0) return error.ChatMessageNotFound;
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.direct_messages SET read=true WHERE to_id=$1::int AND from_id=$2::int AND NOT read AND (chat_message_id IS NULL OR chat_message_id<=$3::bigint)", &.{ viewer, other, message });
        update.deinit();
        try postgres.exec(lease.conn, "COMMIT");
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
        try self.rebuildRankedStats(lease.conn, false);
        try self.recordAllStatsHistoryCurrentWithConnection(lease.conn);
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

    fn backfillLazerClassicScoresWithConnection(self: *Store, conn: *postgres.c.PGconn) !void {
        try postgres.exec(conn, "BEGIN");
        errdefer postgres.exec(conn, "ROLLBACK") catch {};
        var rows = try postgres.query(conn, "SELECT id,ruleset_id,total_score,statistics_json::text,maximum_statistics_json::text FROM zigcho.lazer_scores WHERE legacy_total_score IS NULL ORDER BY id");
        defer rows.deinit();
        for (0..rows.rows()) |row| {
            const id = try rows.int(i64, row, 0);
            const ruleset_id = try rows.int(i64, row, 1);
            const total_score = try rows.int(i64, row, 2);
            const classic = lazer.classicTotalScoreFromJson(self.allocator, ruleset_id, total_score, rows.value(row, 3), rows.value(row, 4)) catch lazer.stableLegacyTotalScore(total_score);
            var id_buf: [32]u8 = undefined;
            var classic_buf: [32]u8 = undefined;
            const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
            const classic_text = try std.fmt.bufPrint(&classic_buf, "{d}", .{classic});
            var updated = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.lazer_scores SET legacy_total_score=$1 WHERE id=$2 AND legacy_total_score IS NULL", &.{ classic_text, id_text });
            updated.deinit();
        }
        try postgres.exec(conn, "COMMIT");
    }

    fn rebuildRankedStats(self: *Store, conn: *postgres.c.PGconn, pre_schema_43: bool) !void {
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
        const lazer_score = "coalesce(l.legacy_total_score,l.total_score)";
        const reset_sql = try std.fmt.allocPrintSentinel(self.allocator, "UPDATE zigcho.stats st SET " ++
            "total_score=coalesce((SELECT sum(s.score) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum({s}) FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
            "plays=coalesce((SELECT count(*) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT count(*) FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
            "play_time=coalesce((SELECT sum(s.time_elapsed/1000) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum(greatest(b.total_length,0)) FROM zigcho.lazer_scores l JOIN zigcho.beatmaps b ON b.id=l.beatmap_id WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
            "total_hits=coalesce((SELECT sum(s.n300+s.n100+s.n50+CASE WHEN s.mode IN(1,3) THEN s.ngeki+s.nkatu ELSE 0 END) FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode),0)+coalesce((SELECT sum(" ++ lazer_hits ++ ") FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode),0)," ++
            "ranked_score=0," ++
            "max_combo=greatest(coalesce((SELECT max(s.max_combo) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode AND s.passed AND b.status>=3),0),coalesce((SELECT max(l.max_combo) FROM zigcho.lazer_scores l JOIN zigcho.beatmaps b ON b.id=l.beatmap_id WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode AND l.passed AND b.status>=3),0))," ++
            "pp=0,accuracy=0 WHERE st.user_id!=3 AND (EXISTS(SELECT 1 FROM zigcho.scores s WHERE s.user_id=st.user_id AND s.rank_namespace!='scorev2' AND " ++ internal_mode ++ "=st.mode) OR EXISTS(SELECT 1 FROM zigcho.lazer_scores l WHERE l.user_id=st.user_id AND " ++ lazer_internal_mode ++ "=st.mode))", .{lazer_score}, 0);
        defer self.allocator.free(reset_sql);
        var reset = try postgres.query(conn, reset_sql);
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
            try self.rebuildCombinedPerformanceWithConnection(conn, user_id, stats_mode % 4, stats_mode, namespace, pre_schema_43);
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
        var lazer_scores = try postgres.query(lease.conn, "SELECT s.id,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods,s.legacy_total_score,s.accuracy,s.max_combo,s.passed,s.mods_json::text,s.statistics_json::text,s.rank_namespace,b.osu_file FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE b.osu_file IS NOT NULL ORDER BY s.id");
        defer lazer_scores.deinit();
        for (0..lazer_scores.rows()) |row| {
            const namespace = std.meta.stringToEnum(lazer.Namespace, lazer_scores.value(row, 11)) orelse continue;
            if (namespace == .custom) continue;
            var parsed_mods = std.json.parseFromSlice(std.json.Value, allocator, lazer_scores.value(row, 9), .{}) catch continue;
            defer parsed_mods.deinit();
            const mods = switch (parsed_mods.value) {
                .array => |value| value,
                else => continue,
            };
            var parsed_statistics = std.json.parseFromSlice(std.json.Value, allocator, lazer_scores.value(row, 10), .{}) catch continue;
            defer parsed_statistics.deinit();
            const statistics = switch (parsed_statistics.value) {
                .object => |value| value,
                else => continue,
            };
            const input: lazer.ScoreInput = .{
                .beatmap_id = try lazer_scores.int(i64, row, 1),
                .ruleset_id = try lazer_scores.int(i64, row, 2),
                .total_score = try lazer_scores.int(i64, row, 3),
                .total_score_without_mods = try lazer_scores.int(i64, row, 4),
                .legacy_total_score = if (lazer_scores.isNull(row, 5)) null else try lazer_scores.int(i32, row, 5),
                .accuracy = try lazer_scores.float(f64, row, 6),
                .max_combo = try lazer_scores.int(i64, row, 7),
                .passed = try lazer_scores.boolean(row, 8),
                .mods = mods,
                .statistics = statistics,
                .namespace = namespace,
            };
            const state = (lazer.performanceState(input) catch continue) orelse continue;
            const map_file = try postgres.decodeBytea(allocator, lazer_scores.value(row, 12));
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
        try self.rebuildRankedStats(lease.conn, false);
        try self.recordAllStatsHistoryCurrentWithConnection(lease.conn);
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
        var token_lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{target});
        token_lock.deinit();
        var update = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.users SET restricted=$1 WHERE id=$2 AND id!=3 RETURNING 1", &.{ if (restricted) "true" else "false", target });
        defer update.deinit();
        if (update.rows() == 0) return error.InvalidModerationTarget;
        try insertAudit(self.allocator, lease.conn, actor_id, if (restricted) "account.restrict" else "account.unrestrict", target_id, reason);
        if (restricted) {
            var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)')", &.{target});
            revoke.deinit();
            var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{target});
            clear.deinit();
        }
        try self.recordAllStatsHistoryCurrentWithConnection(lease.conn);
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn changePrivileges(self: *Store, actor_id: i32, target_id: i32, bits: u32, add: bool) !u32 {
        const role = account_roles.Role.fromBit(bits) orelse return error.InvalidRoleChange;
        return (try self.changeRole(actor_id, target_id, role, add, "legacy typed role command")).privileges;
    }

    pub fn changeRole(self: *Store, actor_id: i32, target_id: i32, role: account_roles.Role, grant: bool, reason: []const u8) !account_roles.ChangeResult {
        if (actor_id <= 0 or target_id <= 0 or !account_roles.validReason(reason)) return error.InvalidRoleChange;
        const definition = role.definition();
        const trimmed_reason = std.mem.trim(u8, reason, " \t\r\n");
        var actor_buf: [24]u8 = undefined;
        var target_buf: [24]u8 = undefined;
        var bit_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
        const bit = try std.fmt.bufPrint(&bit_buf, "{d}", .{definition.bit});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        const sql = if (grant)
            "UPDATE zigcho.users SET privileges=privileges | $1::bigint WHERE id=$2 AND id!=3 AND (privileges & $1::bigint)=0 RETURNING privileges"
        else
            "UPDATE zigcho.users SET privileges=privileges & ~$1::bigint WHERE id=$2 AND id!=3 AND (privileges & $1::bigint)!=0 RETURNING privileges";
        var update = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ bit, target });
        defer update.deinit();
        if (update.rows() == 0) return error.RoleStateUnchanged;
        const privileges = try update.int(u32, 0, 0);
        var staff_sessions_revoked = false;
        if (!account_roles.isStaff(privileges)) {
            var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND scopes='web:staff' AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint RETURNING token_hash", &.{target});
            defer revoke.deinit();
            staff_sessions_revoked = revoke.rows() != 0;
        }
        const detail = try std.fmt.allocPrint(self.allocator, "{s} role:{s} bit:{d} permanent:{} reason:{s}", .{ if (grant) "grant" else "revoke", @tagName(role), definition.bit, definition.permanent, trimmed_reason });
        defer self.allocator.free(detail);
        var audit = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,'account.role','user:'||$2,$3)", &.{ actor, target, detail });
        audit.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return .{ .privileges = privileges, .staff_sessions_revoked = staff_sessions_revoked };
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
        try output.writer.print("{{\"pending\":{d},\"policy\":", .{try pending_result.int(i64, 0, 0)});
        try anticheat_review.writePolicyJson(&output.writer);
        try output.writer.writeAll(",\"observations\":[");
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
            try output.writer.writeAll(",\"meaning\":");
            try anticheat_review.writeObservationJson(&output.writer, .{
                .action = try result.int(u32, row, 6),
                .reason = try result.int(u32, row, 8),
                .risk_score = try result.int(u32, row, 9),
                .confidence_bps = try result.int(u32, row, 10),
                .evidence = try result.int(u64, row, 11),
                .decision_flags = try result.int(u64, row, 12),
                .rule_revision = try result.int(u32, row, 13),
                .metrics = .{
                    .objects_checked = try result.int(u32, row, 14),
                    .matched_clicks = try result.int(u32, row, 15),
                    .mean_abs_timing_error_milli = try result.int(u32, row, 16),
                    .timing_stddev_milli = try result.int(u32, row, 17),
                    .exact_timing_bps = try result.int(u32, row, 18),
                    .center_hits_bps = try result.int(u32, row, 19),
                    .mean_center_distance_milli = try result.int(u32, row, 20),
                    .snap_events = try result.int(u32, row, 21),
                    .replay_match_count = try result.int(u32, row, 22),
                    .key_press_count = try result.int(u32, row, 23),
                    .key_hold_count = try result.int(u32, row, 24),
                    .mean_hold_duration_milli = try result.int(u32, row, 25),
                    .hold_duration_stddev_milli = try result.int(u32, row, 26),
                    .alternation_bps = try result.int(u32, row, 27),
                    .target_distance_stddev_milli = try result.int(u32, row, 28),
                    .velocity_spike_count = try result.int(u32, row, 29),
                    .movement_velocity_stddev_milli = try result.int(u32, row, 30),
                },
            });
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

    pub fn serverControlEnabled(self: *Store, feature: server_control.Feature) !bool {
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT enabled FROM zigcho.server_controls WHERE key=$1", &.{feature.key()});
        defer result.deinit();
        return result.rows() == 0 or try result.boolean(0, 0);
    }

    pub fn staffServerControlsJson(self: *Store, allocator: std.mem.Allocator) ![]u8 {
        var lease = self.pool.acquire();
        defer lease.release();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll("{\"schema\":45,\"controls\":[");
        for (server_control.definitions, 0..) |definition, index| {
            if (index != 0) try output.writer.writeByte(',');
            var result = try postgres.queryParams(allocator, lease.conn, "SELECT c.enabled,c.reason,c.updated_at,coalesce(u.name,'system') FROM zigcho.server_controls c LEFT JOIN zigcho.users u ON u.id=c.updated_by WHERE c.key=$1", &.{definition.feature.key()});
            defer result.deinit();
            try output.writer.writeAll("{\"key\":");
            try jsonString(&output.writer, definition.feature.key());
            try output.writer.writeAll(",\"label\":");
            try jsonString(&output.writer, definition.label);
            try output.writer.writeAll(",\"group\":");
            try jsonString(&output.writer, definition.group);
            try output.writer.writeAll(",\"description\":");
            try jsonString(&output.writer, definition.description);
            if (result.rows() != 0) {
                try output.writer.print(",\"enabled\":{},\"reason\":", .{try result.boolean(0, 0)});
                try jsonString(&output.writer, result.value(0, 1));
                try output.writer.print(",\"updated_at\":{d},\"updated_by\":", .{try result.int(i64, 0, 2)});
                try jsonString(&output.writer, result.value(0, 3));
            } else {
                try output.writer.writeAll(",\"enabled\":true,\"reason\":\"\",\"updated_at\":0,\"updated_by\":\"system\"");
            }
            try output.writer.writeByte('}');
        }
        try output.writer.writeAll("]}");
        return output.toOwnedSlice();
    }

    pub fn setServerControl(self: *Store, actor_id: i32, feature: server_control.Feature, enabled: bool, reason: []const u8) !void {
        var actor_buf: [24]u8 = undefined;
        const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
        var target_buf: [80]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "feature:{s}", .{feature.key()});
        var detail_buf: [560]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "state={s} reason={s}", .{ if (enabled) "enabled" else "disabled", reason });
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var update = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.server_controls(key,enabled,reason,updated_by,updated_at) VALUES($1,$2,$3,$4,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(key) DO UPDATE SET enabled=excluded.enabled,reason=excluded.reason,updated_by=excluded.updated_by,updated_at=excluded.updated_at", &.{ feature.key(), if (enabled) "true" else "false", reason, actor });
        update.deinit();
        var audit = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.audit_log(actor_id,action,target,detail) VALUES($1,'infra.feature',$2,$3)", &.{ actor, target, detail });
        audit.deinit();
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

    pub fn staffRolesJson(self: *Store, allocator: std.mem.Allocator, user_id: i32) !?[]u8 {
        var id_buf: [24]u8 = undefined;
        var target_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const target = try std.fmt.bufPrint(&target_buf, "user:{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var user = try postgres.queryParams(allocator, lease.conn, "SELECT id,name,country,privileges,restricted,created_at,coalesce(last_login,0) FROM zigcho.users WHERE id=$1 AND id!=3", &.{id});
        defer user.deinit();
        if (user.rows() == 0) return null;
        const privileges = try user.int(u32, 0, 3);
        var audit = try postgres.queryParams(allocator, lease.conn, "SELECT a.id,coalesce(actor.name,'system'),coalesce(a.detail,''),a.created_at FROM zigcho.audit_log a LEFT JOIN zigcho.users actor ON actor.id=a.actor_id WHERE a.target=$1 AND a.action='account.role' ORDER BY a.id DESC LIMIT 100", &.{target});
        defer audit.deinit();
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.print("{{\"user\":{{\"id\":{d},\"name\":", .{try user.int(i32, 0, 0)});
        try jsonString(&output.writer, user.value(0, 1));
        try output.writer.writeAll(",\"country\":");
        try jsonString(&output.writer, user.value(0, 2));
        try output.writer.print(",\"privileges\":{d},\"restricted\":{},\"created_at\":{d},\"last_login\":{d}}},\"roles\":", .{ privileges, try user.boolean(0, 4), try user.int(i64, 0, 5), try user.int(i64, 0, 6) });
        try account_roles.writeCatalogJson(&output.writer, privileges);
        try output.writer.writeAll(",\"audit\":[");
        for (0..audit.rows()) |row| {
            if (row != 0) try output.writer.writeByte(',');
            try output.writer.print("{{\"id\":{d},\"actor\":", .{try audit.int(i64, row, 0)});
            try jsonString(&output.writer, audit.value(row, 1));
            try output.writer.writeAll(",\"detail\":");
            try jsonString(&output.writer, audit.value(row, 2));
            try output.writer.print(",\"created_at\":{d}}}", .{try audit.int(i64, row, 3)});
        }
        try output.writer.writeAll("]}");
        const owned = try output.toOwnedSlice();
        return owned;
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
            "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted AND u.show_profile_stats ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET $3";
        const lazer_sql =
            "WITH source_scores AS (" ++
            "SELECT s.user_id,s.id score_id,coalesce(s.legacy_total_score,s.total_score) total_score,s.pp,s.accuracy,s.max_combo,s.passed,b.status,s.beatmap_id " ++
            "FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$1 AND s.rank_namespace=$2)," ++
            "map_scores AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id ORDER BY pp DESC,score_id ASC) map_place FROM source_scores WHERE passed AND status IN(3,4))," ++
            "ranked AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC,score_id ASC)-1 performance_index FROM map_scores WHERE map_place=1)," ++
            "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*)::double precision))) pp,sum(accuracy*power(0.95,performance_index))/(20*(1-power(0.95,count(*)::double precision))) accuracy FROM ranked GROUP BY user_id)," ++
            "activity AS (SELECT user_id,count(*) plays,coalesce(sum(total_score),0) total_score,coalesce((SELECT sum(r.total_score) FROM ranked r WHERE r.user_id=source_scores.user_id),0) ranked_score,coalesce(max(CASE WHEN passed AND status>=3 THEN max_combo ELSE 0 END),0) max_combo FROM source_scores GROUP BY user_id) " ++
            "SELECT row_number() OVER(ORDER BY coalesce(p.pp,0) DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,coalesce(p.pp,0),coalesce(p.accuracy,0),a.plays,a.ranked_score,a.total_score,a.max_combo FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted AND u.show_profile_stats ORDER BY coalesce(p.pp,0) DESC,u.id ASC LIMIT 100 OFFSET $3";
        var result = switch (source) {
            .all => try postgres.queryParams(allocator, lease.conn, "SELECT row_number() OVER(ORDER BY s.pp DESC,u.id ASC),u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.pp,s.accuracy,s.plays,s.ranked_score,s.total_score,s.max_combo FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND u.id!=3 AND NOT u.restricted AND u.show_profile_stats AND s.plays>0 ORDER BY s.pp DESC,u.id ASC LIMIT 100 OFFSET $2", &.{ mode_text, offset_text }),
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
            "WITH visible AS (SELECT CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.plays,s.ranked_score,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted AND u.show_profile_stats) " ++
            "SELECT country,count(*),sum(plays),sum(ranked_score),sum(pp) FROM visible WHERE country!='XX' GROUP BY country ORDER BY sum(pp) DESC,country ASC LIMIT 50 OFFSET $2";
        const performance_sql =
            "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,least((SELECT count(*) FROM zigcho.score_replay_views v WHERE v.owner_id=u.id AND v.mode=s.mode AND v.rank_namespace='vanilla'),2147483647)::int replay_views," ++
            "row_number() OVER(ORDER BY s.pp DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country THEN u.country ELSE 'XX' END ORDER BY s.pp DESC,u.id ASC) country_rank " ++
            "FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted AND u.show_profile_stats) " ++
            "SELECT * FROM visible WHERE ($2='' OR country=$2) ORDER BY pp DESC,id ASC LIMIT 50 OFFSET $3";
        const score_sql =
            "WITH visible AS (SELECT u.id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,u.privileges,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,least((SELECT count(*) FROM zigcho.score_replay_views v WHERE v.owner_id=u.id AND v.mode=s.mode AND v.rank_namespace='vanilla'),2147483647)::int replay_views," ++
            "row_number() OVER(ORDER BY s.total_score DESC,u.id ASC) global_rank,row_number() OVER(PARTITION BY CASE WHEN u.show_country THEN u.country ELSE 'XX' END ORDER BY s.total_score DESC,u.id ASC) country_rank " ++
            "FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$1 AND s.plays>0 AND u.id!=3 AND NOT u.restricted AND u.show_profile_stats) " ++
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
            const stats: domain.Stats = .{ .mode = @enumFromInt(ruleset_id), .ranked_score = try result.int(i64, row, 4), .total_score = try result.int(i64, row, 5), .pp = try result.int(i32, row, 6), .plays = try result.int(i32, row, 7), .play_time = try result.int(i32, row, 8), .total_hits = try result.int(i64, row, 9), .accuracy = try result.float(f64, row, 10), .max_combo = try result.int(i32, row, 11), .replay_views = try result.int(i32, row, 12) };
            try user_json.writeRankingStatistics(&output.writer, user, stats, try result.int(i32, row, 13), try result.int(i32, row, 14));
        }
        try output.writer.writeAll("],\"cursor\":null}");
        return output.toOwnedSlice();
    }

    fn writeSiteScores(writer: *std.Io.Writer, scores: *postgres.Result, include_weight: bool) !void {
        try writer.writeByte('[');
        for (0..scores.rows()) |row| {
            if (row != 0) try writer.writeByte(',');
            try writer.print("{{\"id\":{d},\"score\":{d},\"score_without_mods\":{d},\"legacy_score\":", .{ try scores.int(i64, row, 0), try scores.int(i64, row, 1), try scores.int(i64, row, 20) });
            if (scores.isNull(row, 21)) try writer.writeAll("null") else try writer.print("{d}", .{try scores.int(i32, row, 21)});
            try writer.print(",\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"mode\":{d},\"namespace\":", .{ try scores.float(f64, row, 2), try scores.float(f64, row, 3), try scores.int(i32, row, 4), try scores.int(i32, row, 5), try scores.int(u8, row, 6) });
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

    fn readStatsHistoryWithConnection(self: *Store, conn: *postgres.c.PGconn, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !domain.StatsHistory {
        var buffers: [2][24]u8 = undefined;
        const user = try std.fmt.bufPrint(&buffers[0], "{d}", .{user_id});
        const mode = try std.fmt.bufPrint(&buffers[1], "{d}", .{stats_mode});
        var rows = try postgres.queryParams(
            self.allocator,
            conn,
            "SELECT day,pp,global_rank FROM zigcho.user_stats_history WHERE user_id=$1 AND source=$2 AND mode=$3 AND day BETWEEN ((extract(epoch FROM clock_timestamp())::bigint/86400)-89)*86400 AND (extract(epoch FROM clock_timestamp())::bigint/86400)*86400 ORDER BY day LIMIT 90",
            &.{ user, @tagName(source), mode },
        );
        defer rows.deinit();

        var history: domain.StatsHistory = .{};
        for (0..@min(rows.rows(), domain.StatsHistory.max_points)) |row| {
            history.points[row] = .{
                .day = try rows.int(i64, row, 0),
                .pp = try rows.int(i32, row, 1),
                .global_rank = try rows.int(i32, row, 2),
            };
            history.len += 1;
        }
        return history;
    }

    fn pruneStatsHistoryWithConnection(_: *Store, conn: *postgres.c.PGconn) !void {
        try postgres.exec(conn, "DELETE FROM zigcho.user_stats_history WHERE day<((extract(epoch FROM transaction_timestamp())::bigint/86400)-89)*86400");
    }

    fn recordStatsHistorySliceCurrentWithConnection(self: *Store, conn: *postgres.c.PGconn, source: domain.SiteScoreSource, stats_mode: u8, user_id: i32) !void {
        const score_mode = domain.siteScoreMode(stats_mode);
        const namespace = domain.siteNamespace(source, stats_mode);
        var history_mode_buf: [24]u8 = undefined;
        const history_mode = try std.fmt.bufPrint(&history_mode_buf, "{d}", .{stats_mode});
        // Rank is a property of the whole source/mode slice. Updating only the
        // submitting player can leave both sides of a rank swap at the same
        // position for the rest of the day.
        if (user_id != 0) return self.recordStatsHistorySliceCurrentWithConnection(conn, source, stats_mode, 0);
        if (user_id == 0) {
            var clear = try postgres.queryParams(self.allocator, conn, "DELETE FROM zigcho.user_stats_history WHERE source=$1 AND mode=$2 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400", &.{ @tagName(source), history_mode });
            defer clear.deinit();
        }
        const sql: [:0]const u8 = switch (source) {
            .all => if (user_id == 0)
                "WITH players AS (SELECT s.user_id,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$2 AND s.plays>0 AND u.id!=3 AND NOT u.restricted),ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                    "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ordered " ++
                    "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
            else
                "WITH player AS (SELECT s.user_id,s.pp FROM zigcho.stats s JOIN zigcho.users u ON u.id=s.user_id WHERE s.user_id=$3 AND s.mode=$2 AND s.plays>0 AND u.id!=3 AND NOT u.restricted),ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM zigcho.user_stats_history h WHERE h.source=$1 AND h.mode=$2 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                    "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ranked " ++
                    "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
            .stable, .scorev2 => if (user_id == 0)
                "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.mode=$3 AND s.rank_namespace=$4)," ++
                    "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                    "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                    "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                    "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer pp FROM weighted GROUP BY user_id)," ++
                    "players AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
                    "ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                    "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ordered " ++
                    "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
            else
                "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$5 AND s.mode=$3 AND s.rank_namespace=$4)," ++
                    "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                    "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                    "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                    "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer pp FROM weighted GROUP BY user_id)," ++
                    "player AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
                    "ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM zigcho.user_stats_history h WHERE h.source=$1 AND h.mode=$2 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                    "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ranked " ++
                    "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
            .lazer => if (user_id == 0)
                "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.ruleset_id=$3 AND s.rank_namespace=$4)," ++
                    "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                    "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                    "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                    "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer pp FROM weighted GROUP BY user_id)," ++
                    "players AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
                    "ordered AS (SELECT user_id,pp,row_number() OVER(ORDER BY pp DESC,user_id ASC) global_rank FROM players) " ++
                    "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ordered " ++
                    "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank"
            else
                "WITH source_scores AS (SELECT s.user_id,b.id beatmap_id,s.pp,s.passed,b.status FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$5 AND s.ruleset_id=$3 AND s.rank_namespace=$4)," ++
                    "activity AS (SELECT DISTINCT user_id FROM source_scores)," ++
                    "best AS (SELECT user_id,beatmap_id,max(pp) pp FROM source_scores WHERE passed AND status IN(3,4) GROUP BY user_id,beatmap_id)," ++
                    "weighted AS (SELECT user_id,pp,row_number() OVER(PARTITION BY user_id ORDER BY pp DESC,beatmap_id ASC)-1 performance_index FROM best)," ++
                    "performance AS (SELECT user_id,round(sum(pp*power(0.95,performance_index))+416.6667*(1-power(0.9994,count(*))))::integer pp FROM weighted GROUP BY user_id)," ++
                    "player AS (SELECT a.user_id,coalesce(p.pp,0) pp FROM activity a JOIN zigcho.users u ON u.id=a.user_id LEFT JOIN performance p ON p.user_id=a.user_id WHERE u.id!=3 AND NOT u.restricted)," ++
                    "ranked AS (SELECT p.user_id,p.pp,1+(SELECT count(*) FROM zigcho.user_stats_history h WHERE h.source=$1 AND h.mode=$2 AND h.day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND h.user_id!=p.user_id AND (h.pp>p.pp OR (h.pp=p.pp AND h.user_id<p.user_id))) global_rank FROM player p) " ++
                    "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) SELECT user_id,$1,$2,(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400,pp,global_rank FROM ranked " ++
                    "ON CONFLICT(user_id,source,mode,day) DO UPDATE SET pp=excluded.pp,global_rank=excluded.global_rank",
        };
        var buffers: [3][24]u8 = undefined;
        const mode = try std.fmt.bufPrint(&buffers[1], "{d}", .{score_mode});
        const user = try std.fmt.bufPrint(&buffers[2], "{d}", .{user_id});
        const params: []const ?[]const u8 = if (source == .all)
            if (user_id == 0)
                &.{ @tagName(source), history_mode }
            else
                &.{ @tagName(source), history_mode, user }
        else if (user_id == 0)
            &.{ @tagName(source), history_mode, mode, namespace }
        else
            &.{ @tagName(source), history_mode, mode, namespace, user };
        var insert = try postgres.queryParams(self.allocator, conn, sql, params);
        defer insert.deinit();
    }

    fn statsHistoryUserVisibleWithConnection(self: *Store, conn: *postgres.c.PGconn, user_id: i32) !bool {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var visible = try postgres.queryParams(self.allocator, conn, "SELECT 1 FROM zigcho.users WHERE id=$1 AND id!=3 AND NOT restricted", &.{user});
        defer visible.deinit();
        return visible.rows() != 0;
    }

    pub fn statsHistory(self: *Store, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !domain.StatsHistory {
        if (user_id <= 0 or !domain.validSiteMode(source, stats_mode)) return error.InvalidStatsHistory;
        var lease = self.pool.acquire();
        defer lease.release();
        if (!try self.statsHistoryUserVisibleWithConnection(lease.conn, user_id)) return error.InvalidStatsHistory;
        return self.readStatsHistoryWithConnection(lease.conn, user_id, source, stats_mode);
    }

    fn recordAllStatsHistoryCurrentWithConnection(self: *Store, conn: *postgres.c.PGconn) !void {
        try self.pruneStatsHistoryWithConnection(conn);
        const full_modes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 8 };
        for ([_]domain.SiteScoreSource{ .all, .stable, .lazer }) |source| {
            for (full_modes) |stats_mode| try self.recordStatsHistorySliceCurrentWithConnection(conn, source, stats_mode, 0);
        }
        for ([_]u8{ 0, 1, 2, 3 }) |stats_mode| try self.recordStatsHistorySliceCurrentWithConnection(conn, .scorev2, stats_mode, 0);
    }

    fn recordBeatmapStatsHistoryCurrentWithConnection(self: *Store, conn: *postgres.c.PGconn, map_id: i32, md5: []const u8) !void {
        var map_buf: [24]u8 = undefined;
        const map = try std.fmt.bufPrint(&map_buf, "{d}", .{map_id});
        var keys = try postgres.queryParams(
            self.allocator,
            conn,
            "WITH keys(source,mode) AS (" ++
                "SELECT CASE rank_namespace WHEN 'scorev2' THEN 'scorev2' ELSE 'stable' END,CASE rank_namespace WHEN 'relax' THEN mode+4 WHEN 'autopilot' THEN 8 ELSE mode END FROM zigcho.scores WHERE map_md5=$1 " ++
                "UNION SELECT 'lazer',CASE rank_namespace WHEN 'relax' THEN ruleset_id+4 WHEN 'autopilot' THEN 8 ELSE ruleset_id END FROM zigcho.lazer_scores WHERE beatmap_id=$2)," ++
                "expanded(source,mode) AS (SELECT source,mode FROM keys UNION SELECT 'all',mode FROM keys WHERE source!='scorev2') " ++
                "SELECT DISTINCT source,mode FROM expanded",
            &.{ md5, map },
        );
        defer keys.deinit();
        var slices = [_][9]bool{[_]bool{false} ** 9} ** 4;
        for (0..keys.rows()) |row| {
            const source = domain.parseSiteScoreSource(keys.value(row, 0)) orelse continue;
            const stats_mode = try keys.int(u8, row, 1);
            if (stats_mode > 8 or !domain.validSiteMode(source, stats_mode)) continue;
            slices[@intFromEnum(source)][stats_mode] = true;
        }
        try self.pruneStatsHistoryWithConnection(conn);
        for (slices, 0..) |modes, source_index| {
            const source: domain.SiteScoreSource = @enumFromInt(source_index);
            for (modes, 0..) |present, stats_mode| if (present) try self.recordStatsHistorySliceCurrentWithConnection(conn, source, @intCast(stats_mode), 0);
        }
    }

    pub fn refreshStatsHistory(self: *Store) !void {
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        try self.recordAllStatsHistoryCurrentWithConnection(lease.conn);
        try postgres.exec(lease.conn, "COMMIT");
    }

    pub fn siteProfile(self: *Store, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8) !?[]u8 {
        return self.siteProfileForViewer(allocator, user_id, source, stats_mode, false);
    }

    pub fn siteProfileForViewer(self: *Store, allocator: std.mem.Allocator, user_id: i32, source: domain.SiteScoreSource, stats_mode: u8, owner_view: bool) !?[]u8 {
        if (user_id <= 0 or !domain.validSiteMode(source, stats_mode)) return error.InvalidStatsHistory;
        var id_buf: [24]u8 = undefined;
        var score_mode_buf: [4]u8 = undefined;
        var stats_mode_buf: [4]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const score_mode = domain.siteScoreMode(stats_mode);
        const score_mode_text = try std.fmt.bufPrint(&score_mode_buf, "{d}", .{score_mode});
        const stats_mode_text = try std.fmt.bufPrint(&stats_mode_buf, "{d}", .{stats_mode});
        const namespace = domain.siteNamespace(source, stats_mode);
        var lease = self.pool.acquire();
        defer lease.release();
        const user_sql = "SELECT u.id,u.name,CASE WHEN $2::boolean OR u.show_country THEN u.country ELSE 'XX' END,u.privileges,u.created_at,u.bio,u.preferred_mode,u.profile_source,coalesce((SELECT updated_at FROM zigcho.user_avatars a WHERE a.user_id=u.id),u.avatar_key),u.profile_title,u.profile_pronouns,u.profile_location,u.profile_website,u.profile_accent,u.show_profile_stats,u.show_recent_scores,coalesce((SELECT updated_at FROM zigcho.user_banners b WHERE b.user_id=u.id),0),tm.team_id,t.name,t.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets a WHERE a.team_id=t.id AND a.kind='flag'),0)," ++ visible_follower_count_sql ++ " FROM zigcho.users u LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id WHERE u.id=$1 AND u.id!=3 AND NOT u.restricted";
        var user = try postgres.queryParams(allocator, lease.conn, user_sql, &.{ id, if (owner_view) "true" else "false" });
        defer user.deinit();
        if (user.rows() == 0) return null;
        var stats = try postgres.queryParams(allocator, lease.conn, "SELECT s.mode,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(*)+1 FROM zigcho.stats r JOIN zigcho.users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND ru.id!=3 AND NOT ru.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM zigcho.stats s WHERE s.user_id=$1 ORDER BY s.mode", &.{id});
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
            .all => try postgres.queryParams(allocator, lease.conn, "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.accuracy,s.max_combo,(SELECT count(*)+1 FROM zigcho.stats r JOIN zigcho.users ru ON ru.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND ru.id!=3 AND NOT ru.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) FROM zigcho.stats s WHERE s.user_id=$1 AND s.mode=$2 AND s.plays>0", &.{ id, stats_mode_text }),
            .stable, .scorev2 => try postgres.queryParams(allocator, lease.conn, stable_stats_sql, &.{ id, score_mode_text, namespace }),
            .lazer => try postgres.queryParams(allocator, lease.conn, lazer_stats_sql, &.{ id, score_mode_text, namespace }),
        };
        defer selected_stats.deinit();
        const stable_columns = "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score score_without_mods,s.score legacy_score FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 ";
        const lazer_columns = "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id map_id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods score_without_mods,s.legacy_total_score legacy_score FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id ";
        const pinned_sql: [:0]const u8 = switch (source) {
            .all => "WITH pinned_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,pinned_at) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,p.pinned_at FROM zigcho.profile_score_pins p JOIN zigcho.scores s ON p.source='stable' AND s.id=p.score_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE p.user_id=$1 AND p.mode=$2 AND p.rank_namespace=$3 AND s.passed UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,p.pinned_at FROM zigcho.profile_score_pins p JOIN zigcho.lazer_scores s ON p.source='lazer' AND s.id=p.score_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE p.user_id=$1 AND p.mode=$2 AND p.rank_namespace=$3 AND s.passed) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score FROM pinned_scores ORDER BY pinned_at DESC,client,id DESC LIMIT 3",
            .stable, .scorev2 => stable_columns ++ "JOIN zigcho.profile_score_pins p ON p.source='stable' AND p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
            .lazer => lazer_columns ++ "JOIN zigcho.profile_score_pins p ON p.source='lazer' AND p.score_id=s.id AND p.user_id=s.user_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed ORDER BY p.pinned_at DESC,p.score_id DESC LIMIT 3",
        };
        const top_sql: [:0]const u8 = switch (source) {
            .all => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,b.id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4) UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,b.id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4))," ++
                "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) map_place FROM candidates) " ++
                "SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_key ASC,id ASC LIMIT 100",
            .stable, .scorev2 => "WITH candidates AS (" ++ stable_columns ++ "WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
            .lazer => "WITH candidates AS (" ++ lazer_columns ++ "WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4)), ranked AS (SELECT *,row_number() OVER(PARTITION BY map_id ORDER BY pp DESC,id ASC) map_place FROM candidates) SELECT * FROM ranked WHERE map_place=1 ORDER BY pp DESC,map_id ASC,id ASC LIMIT 100",
        };
        const recent_sql: [:0]const u8 = switch (source) {
            .all => "WITH recent_scores(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3) " ++
                "SELECT * FROM recent_scores ORDER BY submitted_at DESC,client ASC,id DESC LIMIT 20",
            .lazer => lazer_columns ++ "WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 ORDER BY s.id DESC LIMIT 20",
            .stable, .scorev2 => stable_columns ++ "WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 ORDER BY s.id DESC LIMIT 20",
        };
        const first_sql: [:0]const u8 = switch (source) {
            .all => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key,user_id) AS (" ++
                "SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,b.id,s.user_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted UNION ALL " ++
                "SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,b.id,s.user_id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted)," ++
                "per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=$1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,first_count FROM firsts ORDER BY submitted_at DESC,client,id DESC LIMIT 20",
            .stable, .scorev2 => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key,user_id) AS (SELECT s.id,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'stable',NULL::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.score,s.score,b.id,s.user_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted),per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=$1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,first_count FROM firsts ORDER BY submitted_at DESC,id DESC LIMIT 20",
            .lazer => "WITH candidates(id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,beatmap_key,user_id) AS (SELECT s.id,s.total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.passed,s.submitted_at,b.set_id,b.id,b.artist,b.title,b.version,b.status,'lazer',s.mods_json::text,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)),coalesce(nullif(s.star_rating,0),b.star_rating),s.total_score_without_mods,s.legacy_total_score,b.id,s.user_id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted),per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_key ORDER BY pp DESC,id ASC) user_place FROM candidates),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_key ORDER BY score DESC,id ASC) map_place FROM per_user WHERE user_place=1),firsts AS (SELECT *,count(*) OVER() first_count FROM board WHERE map_place=1 AND user_id=$1) SELECT id,score,pp,accuracy,max_combo,mods,mode,rank_namespace,passed,submitted_at,set_id,map_id,artist,title,version,status,client,mods_json,has_replay,star_rating,score_without_mods,legacy_score,first_count FROM firsts ORDER BY submitted_at DESC,id DESC LIMIT 20",
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
        const show_profile_stats = owner_view or try user.boolean(0, 14);
        const show_recent_scores = owner_view or try user.boolean(0, 15);
        try output.writer.print(",\"follower_count\":{d},\"stats_public\":{},\"recent_scores_public\":{},\"selected_source\":\"{s}\",\"stats_source\":\"{s}\",\"selected_mode\":{d},\"selected_stats\":", .{ try user.int(i32, 0, 21), show_profile_stats, show_recent_scores, @tagName(source), if (source == .all) "combined" else @tagName(source), stats_mode });
        if (!show_profile_stats or selected_stats.rows() == 0) {
            try output.writer.writeAll("null");
        } else {
            const total_score = @max(@as(i64, 0), try selected_stats.int(i64, 0, 1));
            const level = domain.levelFromTotalScore(total_score);
            const global_rank = try selected_stats.int(i32, 0, 7);
            const selected_pp = try selected_stats.int(i32, 0, 2);
            const replay_views = try self.replayViewCountWithConnection(lease.conn, user_id, source, stats_mode);
            const stats_history = try self.readStatsHistoryWithConnection(lease.conn, user_id, source, stats_mode);
            try output.writer.print("{{\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d},\"level_current\":{d},\"level_progress\":{d},\"replay_views\":{d},", .{ try selected_stats.int(i64, 0, 0), total_score, selected_pp, try selected_stats.int(i32, 0, 3), try selected_stats.int(i32, 0, 4), try selected_stats.float(f64, 0, 5), try selected_stats.int(i32, 0, 6), global_rank, level.current, level.progress, replay_views });
            try user_json.writeSiteStatsHistory(&output.writer, stats_history);
            try output.writer.writeByte('}');
        }
        try output.writer.writeAll(",\"stats\":[");
        for (0..if (show_profile_stats) stats.rows() else 0) |row| {
            if (row != 0) try output.writer.writeByte(',');
            const raw_mode = try stats.int(u8, row, 0);
            try output.writer.print("{{\"mode\":{d},\"ranked_score\":{d},\"total_score\":{d},\"pp\":{d},\"plays\":{d},\"play_time\":{d},\"total_hits\":{d},\"accuracy\":{d},\"max_combo\":{d},\"global_rank\":{d},\"replay_views\":{d}}}", .{ raw_mode, try stats.int(i64, row, 1), try stats.int(i64, row, 2), try stats.int(i32, row, 3), try stats.int(i32, row, 4), try stats.int(i32, row, 5), try stats.int(i64, row, 6), try stats.float(f64, row, 7), try stats.int(i32, row, 8), try stats.int(i32, row, 9), try self.replayViewCountWithConnection(lease.conn, user_id, .all, raw_mode) });
        }
        try output.writer.writeAll("],\"pinned_scores\":");
        if (show_profile_stats) try writeSiteScores(&output.writer, &pinned, false) else try output.writer.writeAll("[]");
        try output.writer.writeAll(",\"top_scores\":");
        if (show_profile_stats) try writeSiteScores(&output.writer, &top, true) else try output.writer.writeAll("[]");
        try output.writer.writeAll(",\"recent_scores\":");
        if (show_recent_scores) try writeSiteScores(&output.writer, &recent, false) else try output.writer.writeAll("[]");
        const first_count: i64 = if (!show_profile_stats or firsts.rows() == 0) 0 else try firsts.int(i64, 0, 22);
        try output.writer.print(",\"first_place_count\":{d},\"first_place_scores\":", .{first_count});
        if (show_profile_stats) try writeSiteScores(&output.writer, &firsts, false) else try output.writer.writeAll("[]");
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
            "WITH candidates(id,user_id,name,country,privileges,total_score,score_without_mods,legacy_score,pp,accuracy,max_combo,mods,mode,rank_namespace,submitted_at,client,mods_json,has_replay) AS (" ++
            "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.score,s.score,s.score,s.pp,s.accuracy,s.max_combo,s.mods,s.mode,s.rank_namespace,s.submitted_at,'stable',NULL::text,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE b.id=$1 AND b.status>=3 AND s.mode=$2 AND s.rank_namespace=$4 AND s.passed AND NOT u.restricted AND u.id!=3 AND ($3='all' OR $3='stable' OR $3='scorev2') AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') UNION ALL " ++
            "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,u.privileges,s.total_score,s.total_score_without_mods,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,0,s.ruleset_id,s.rank_namespace,s.submitted_at,'lazer',s.mods_json::text,(coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE s.beatmap_id=$1 AND b.status>=3 AND s.ruleset_id=$2 AND s.rank_namespace=$4 AND s.passed AND NOT u.restricted AND u.id!=3 AND ($3='all' OR $3='lazer') AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto'))," ++
            "per_user AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN $3='all' OR $5::boolean THEN pp ELSE total_score::double precision END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) user_place FROM candidates)," ++
            "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN $5::boolean THEN pp ELSE total_score::double precision END DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC) position FROM per_user WHERE user_place=1) " ++
            "SELECT position,id,user_id,name,country,privileges,total_score,score_without_mods,legacy_score,pp,accuracy,max_combo,mods,rank_namespace,submitted_at,client,mods_json,has_replay FROM board ORDER BY position LIMIT 100";
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
            try output.writer.print(",\"privileges\":{d},\"score\":{d},\"score_without_mods\":{d},\"legacy_score\":", .{ try result.int(u32, row, 5), try result.int(i64, row, 6), try result.int(i64, row, 7) });
            if (result.isNull(row, 8)) try output.writer.writeAll("null") else try output.writer.print("{d}", .{try result.int(i32, row, 8)});
            try output.writer.print(",\"pp\":{d},\"accuracy\":{d},\"max_combo\":{d},\"mods\":{d},\"namespace\":", .{ try result.float(f64, row, 9), try result.float(f64, row, 10), try result.int(i32, row, 11), try result.int(i32, row, 12) });
            try jsonString(&output.writer, result.value(row, 13));
            try output.writer.print(",\"submitted_at\":{d},\"client\":", .{try result.int(i64, row, 14)});
            try jsonString(&output.writer, result.value(row, 15));
            try output.writer.writeAll(",\"mods_json\":");
            if (result.isNull(row, 16)) try output.writer.writeAll("null") else try output.writer.writeAll(result.value(row, 16));
            try output.writer.print(",\"has_replay\":{}}}", .{try result.boolean(row, 17)});
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
        const sql = if (source == .all)
            "WITH candidates AS (" ++
                "SELECT s.user_id,b.id beatmap_id,s.ruleset_id mode,s.total_score,s.pp,1 source_order,s.id source_id,s.submitted_at FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id JOIN zigcho.users u ON u.id=s.user_id WHERE $3='all' AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted " ++
                "UNION ALL SELECT s.user_id,b.id,s.mode,s.score,s.pp,0,s.id,s.submitted_at FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 JOIN zigcho.users u ON u.id=s.user_id WHERE $3='all' AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted)," ++
                "user_best AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,mode ORDER BY pp DESC,source_order ASC,submitted_at DESC,source_id ASC) source_place FROM candidates)," ++
                "board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id,mode ORDER BY total_score DESC,source_order ASC,source_id ASC) board_place FROM user_best WHERE source_place=1) " ++
                "SELECT (SELECT count(*) FROM user_best WHERE user_id=$1 AND source_place=1),(SELECT count(*) FROM board WHERE user_id=$1 AND board_place=1)," ++
                "(SELECT count(*) FROM zigcho.lazer_scores WHERE user_id=$1 AND ruleset_id=$2)+(SELECT count(*) FROM zigcho.scores WHERE user_id=$1 AND mode=$2)," ++
                "(SELECT count(*) FROM zigcho.profile_score_pins WHERE user_id=$1 AND mode=$2)"
        else
            "SELECT " ++
                "(SELECT count(*) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE $3!='stable' AND s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4))+(SELECT count(*) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE $3!='lazer' AND s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4))," ++
                "(SELECT count(*) FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE $3!='stable' AND s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.lazer_scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.beatmap_id=s.beatmap_id AND o.ruleset_id=s.ruleset_id AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.total_score>s.total_score OR (o.total_score=s.total_score AND o.id<s.id))))+(SELECT count(*) FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE $3!='lazer' AND s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4) AND NOT EXISTS(SELECT 1 FROM zigcho.scores o JOIN zigcho.users ou ON ou.id=o.user_id WHERE o.map_md5=s.map_md5 AND o.mode=s.mode AND o.rank_namespace=s.rank_namespace AND o.passed AND o.best AND NOT ou.restricted AND (o.score>s.score OR (o.score=s.score AND o.id<s.id))))," ++
                "(SELECT count(*) FROM zigcho.lazer_scores WHERE $3!='stable' AND user_id=$1 AND ruleset_id=$2)+(SELECT count(*) FROM zigcho.scores WHERE $3!='lazer' AND user_id=$1 AND mode=$2)," ++
                "(SELECT count(*) FROM zigcho.profile_score_pins p WHERE p.user_id=$1 AND p.mode=$2 AND p.source=$3)";
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
        const canonical_combined = source == .all and (kind == .best or kind == .firsts);
        const filters = if (canonical_combined) .{
            "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)",
            "AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)",
            if (kind == .best) "pp DESC,submitted_epoch DESC,id DESC" else "submitted_epoch DESC,id DESC",
        } else switch (kind) {
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
                "pin_epoch DESC,source ASC,id DESC",
            },
        };
        const lazer_pin_epoch = if (kind == .pinned) "(SELECT p.pinned_at FROM zigcho.profile_score_pins p WHERE p.user_id=s.user_id AND p.source='lazer' AND p.score_id=s.id)" else "0";
        const stable_pin_epoch = if (kind == .pinned) "(SELECT p.pinned_at FROM zigcho.profile_score_pins p WHERE p.user_id=s.user_id AND p.source='stable' AND p.score_id=s.id)" else "0";
        const lazer_owner_filter = if (source == .all and kind == .firsts) "s.ruleset_id=$2 AND NOT u.restricted" else "s.user_id=$1 AND s.ruleset_id=$2";
        const stable_owner_filter = if (source == .all and kind == .firsts) "s.mode=$2 AND NOT u.restricted" else "s.user_id=$1 AND s.mode=$2";
        const select_rows = if (source == .all and kind == .best)
            "),selected AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id ORDER BY pp DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,submitted_epoch DESC,id ASC) source_place FROM combined) SELECT * FROM selected WHERE source_place=1"
        else if (source == .all and kind == .firsts)
            "),user_best AS (SELECT *,row_number() OVER(PARTITION BY user_id,beatmap_id,ruleset_id ORDER BY pp DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,submitted_epoch DESC,id ASC) user_place FROM combined),board AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id,ruleset_id ORDER BY total_score DESC,CASE source WHEN 'stable' THEN 0 ELSE 1 END,id ASC) board_place FROM user_best WHERE user_place=1) SELECT * FROM board WHERE user_id=$1 AND board_place=1"
        else
            ") SELECT * FROM combined";
        const sql = try std.fmt.allocPrintSentinel(allocator,
            \\WITH combined AS (
            \\SELECT 'lazer'::text source,s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods total_without,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,false perfect,s.best preserve,{s}::bigint pin_epoch
            \\FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE {s} {s} {s}
            \\UNION ALL
            \\SELECT 'stable'::text source,4000000000000000000+s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,least(greatest(s.score,0),2147483647)::integer legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,''::text rank,'[]'::text mods_json,'{{}}'::text statistics_json,'{{}}'::text maximum_statistics_json,'[]'::text pauses_json,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') ended_at,s.submitted_at submitted_epoch,b.status,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect,s.best preserve,{s}::bigint pin_epoch
            \\FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE {s} {s} {s}
            \\{s} ORDER BY {s} LIMIT $3 OFFSET $4
        , .{ lazer_pin_epoch, lazer_owner_filter, filters[0], if (source == .stable) "AND false" else "", stable_pin_epoch, stable_owner_filter, filters[1], if (source == .lazer) "AND false" else "", select_rows, filters[2] }, 0);
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
            const status = try result.int(i32, row, 21);
            var mods: std.Io.Writer.Allocating = .init(allocator);
            defer mods.deinit();
            var statistics: std.Io.Writer.Allocating = .init(allocator);
            defer statistics.deinit();
            if (stable) {
                try stable_mods.writeLazerJson(&mods.writer, try result.int(i32, row, 32), true);
                try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, try result.int(i32, row, 33), try result.int(i32, row, 34), try result.int(i32, row, 35), try result.int(i32, row, 36), try result.int(i32, row, 37), try result.int(i32, row, 38));
            }
            try lazer.writeLeaderboardScore(&output.writer, .{
                .id = try result.int(i64, row, 1),
                .legacy_score_id = if (stable) lazer.decodeStableScoreId(try result.int(i64, row, 1)) else null,
                .legacy_total_score = if (stable) lazer.stableLegacyTotalScore(try result.int(i64, row, 7)) else if (result.isNull(row, 9)) null else try result.int(i32, row, 9),
                .user_id = try result.int(i32, row, 2),
                .username = result.value(row, 3),
                .country = result.value(row, 4),
                .beatmap_id = try result.int(i32, row, 5),
                .ruleset_id = try result.int(i32, row, 6),
                .total_score = try result.int(i64, row, 7),
                .total_score_without_mods = try result.int(i64, row, 8),
                .pp = try result.float(f64, row, 10),
                .accuracy = try result.float(f64, row, 11),
                .max_combo = try result.int(i32, row, 12),
                .passed = try result.boolean(row, 13),
                .rank = if (stable) sqlite_storage.Store.stableGrade(ruleset_id, try result.int(i32, row, 32), try result.float(f64, row, 11), try result.int(i32, row, 33), try result.int(i32, row, 34), try result.int(i32, row, 35), try result.int(i32, row, 38)) else result.value(row, 14),
                .mods_json = if (stable) mods.written() else result.value(row, 15),
                .statistics_json = if (stable) statistics.written() else result.value(row, 16),
                .maximum_statistics_json = result.value(row, 17),
                .pauses_json = result.value(row, 18),
                .ended_at = result.value(row, 19),
                .ranked = status == 3 or status == 4,
                .preserve = try result.boolean(row, 40),
                .has_replay = try result.boolean(row, 31),
                .beatmap = .{
                    .id = try result.int(i32, row, 5),
                    .set_id = try result.int(i32, row, 22),
                    .status = lazerStatus(status),
                    .checksum = result.value(row, 23),
                    .ruleset_id = try result.int(i32, row, 24),
                    .star_rating = try result.float(f64, row, 25),
                    .version = result.value(row, 26),
                    .artist = result.value(row, 27),
                    .title = result.value(row, 28),
                    .creator = result.value(row, 29),
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
            "SELECT position,score_count,id,user_id,(SELECT name FROM zigcho.users WHERE id=board.user_id),(SELECT country FROM zigcho.users WHERE id=board.user_id),beatmap_id,mode,score,pp,accuracy,max_combo,n300,n100,n50,ngeki,nkatu,nmiss,perfect,mods,to_char(to_timestamp(submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),status,set_id,map_md5,beatmap_star_rating,version,artist,title,creator,team_id,team_name,team_short_name,team_flag_version,(coalesce(octet_length(replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=board.id)) " ++
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
                .legacy_total_score = lazer.stableLegacyTotalScore(try result.int(i64, row, 8)),
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
                .has_replay = try result.boolean(row, 33),
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
            "SELECT 'lazer'::text source,s.id source_id,s.id public_id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods total_without,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') ended_at,b.status,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id)) has_replay,0 stable_mods,0 n300,0 n100,0 n50,0 ngeki,0 nkatu,0 nmiss,false perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,1 source_order,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version " ++
            "FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id " ++
            "WHERE s.beatmap_id=$1 AND b.status>=3 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND NOT u.restricted AND NOT $6::boolean AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') " ++
            "AND ($11='global' OR ($11='country' AND u.country=(SELECT country FROM zigcho.users WHERE id=$10)) OR ($11='friend' AND (s.user_id=$10 OR EXISTS(SELECT 1 FROM zigcho.friends f JOIN zigcho.users friend_sender ON friend_sender.id=f.user_id JOIN zigcho.users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=$10 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND NOT friend_sender.restricted AND NOT friend_target.restricted))) OR ($11='team' AND tm.team_id IS NOT NULL AND tm.team_id=(SELECT team_id FROM zigcho.team_members WHERE user_id=$10))) " ++
            "AND (NOT $5::boolean OR (" ++
            "NOT EXISTS(SELECT upper(stored.value->>'acronym') FROM jsonb_array_elements(s.mods_json) stored WHERE $3!='custom' OR upper(stored.value->>'acronym') NOT IN('RX','AP') EXCEPT SELECT upper(value) FROM jsonb_array_elements_text($4::jsonb) WHERE $3!='custom' OR upper(value) NOT IN('RX','AP')) " ++
            "AND NOT EXISTS(SELECT upper(value) FROM jsonb_array_elements_text($4::jsonb) WHERE $3!='custom' OR upper(value) NOT IN('RX','AP') EXCEPT SELECT upper(stored.value->>'acronym') FROM jsonb_array_elements(s.mods_json) stored WHERE $3!='custom' OR upper(stored.value->>'acronym') NOT IN('RX','AP')))) " ++
            "UNION ALL " ++
            "SELECT 'stable'::text source,s.id source_id,4000000000000000000+s.id public_id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END country,b.id beatmap_id,s.mode ruleset_id,s.score total_score,s.score total_without,least(greatest(s.score,0),2147483647)::integer legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,''::text rank,'[]'::text mods_json,'{}'::text statistics_json,'{}'::text maximum_statistics_json,'[]'::text pauses_json,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') ended_at,b.status,s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='stable' AND ro.score_id=s.id)) has_replay,s.mods stable_mods,s.n300,s.n100,s.n50,s.ngeki,s.nkatu,s.nmiss,s.perfect,b.set_id,b.md5,b.mode map_mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace,0 source_order,tm.team_id,t.name team_name,t.short_name team_short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=t.id AND ta.kind='flag'),0) team_flag_version " ++
            "FROM zigcho.scores s JOIN zigcho.users u ON u.id=s.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams t ON t.id=tm.team_id JOIN zigcho.beatmaps b ON b.md5=s.map_md5 " ++
            "WHERE b.id=$1 AND b.status>=3 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND NOT u.restricted AND $3!='custom' AND $7::boolean AND (NOT $5::boolean OR (s.mods & $12::integer)=$8) AND NOT EXISTS(SELECT 1 FROM zigcho.beatmap_rank_events veto_event WHERE veto_event.set_id=b.set_id AND veto_event.id=(SELECT max(latest_event.id) FROM zigcho.beatmap_rank_events latest_event WHERE latest_event.set_id=b.set_id) AND veto_event.action='veto') " ++
            "AND ($11='global' OR ($11='country' AND u.country=(SELECT country FROM zigcho.users WHERE id=$10)) OR ($11='friend' AND (s.user_id=$10 OR EXISTS(SELECT 1 FROM zigcho.friends f JOIN zigcho.users friend_sender ON friend_sender.id=f.user_id JOIN zigcho.users friend_target ON friend_target.id=f.friend_id WHERE f.user_id=$10 AND f.friend_id=s.user_id AND friend_sender.id!=friend_target.id AND friend_target.id!=3 AND NOT friend_sender.restricted AND NOT friend_target.restricted))) OR ($11='team' AND tm.team_id IS NOT NULL AND tm.team_id=(SELECT team_id FROM zigcho.team_members WHERE user_id=$10))))," ++
            "ordered AS (SELECT *,row_number() OVER(PARTITION BY user_id ORDER BY CASE WHEN rank_namespace IN('vanilla','relax','autopilot') THEN pp ELSE total_score::double precision END DESC,source_order,source_id) user_place FROM candidates)," ++
            "board AS (SELECT *,row_number() OVER(ORDER BY CASE WHEN rank_namespace IN('relax','autopilot') THEN pp ELSE total_score::double precision END DESC,source_order,source_id) position,count(*) OVER() score_count FROM ordered WHERE user_place=1) " ++
            "SELECT position,score_count,source,public_id,user_id,name,country,beatmap_id,ruleset_id,total_score,total_without,legacy_total_score,pp,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,ended_at,status,has_replay,stable_mods,n300,n100,n50,ngeki,nkatu,nmiss,perfect,set_id,md5,map_mode,star_rating,version,artist,title,creator,rank_namespace,team_id,team_name,team_short_name,team_flag_version " ++
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
                try stable_mods.writeLazerJson(&mods.writer, try result.int(i32, row, 24), true);
                try stable_mods.writeLazerStatistics(&statistics.writer, ruleset_id, try result.int(i32, row, 25), try result.int(i32, row, 26), try result.int(i32, row, 27), try result.int(i32, row, 28), try result.int(i32, row, 29), try result.int(i32, row, 30));
            }
            const score: lazer.LeaderboardScore = .{
                .id = try result.int(i64, row, 3),
                .legacy_score_id = if (stable) lazer.decodeStableScoreId(try result.int(i64, row, 3)) else null,
                .legacy_total_score = if (stable) lazer.stableLegacyTotalScore(try result.int(i64, row, 9)) else if (result.isNull(row, 11)) null else try result.int(i32, row, 11),
                .user_id = try result.int(i32, row, 4),
                .username = result.value(row, 5),
                .country = result.value(row, 6),
                .beatmap_id = try result.int(i32, row, 7),
                .ruleset_id = try result.int(i32, row, 8),
                .total_score = try result.int(i64, row, 9),
                .total_score_without_mods = try result.int(i64, row, 10),
                .pp = try result.float(f64, row, 12),
                .accuracy = try result.float(f64, row, 13),
                .max_combo = try result.int(i32, row, 14),
                .passed = try result.boolean(row, 15),
                .rank = if (stable) sqlite_storage.Store.stableGrade(ruleset_id, try result.int(i32, row, 24), try result.float(f64, row, 13), try result.int(i32, row, 25), try result.int(i32, row, 26), try result.int(i32, row, 27), try result.int(i32, row, 30)) else result.value(row, 16),
                .mods_json = if (stable) mods.written() else result.value(row, 17),
                .statistics_json = if (stable) statistics.written() else result.value(row, 18),
                .maximum_statistics_json = result.value(row, 19),
                .pauses_json = result.value(row, 20),
                .ended_at = result.value(row, 21),
                .ranked = (try result.int(i32, row, 22)) == 3 or (try result.int(i32, row, 22)) == 4,
                .has_replay = try result.boolean(row, 23),
                .team = if (result.isNull(row, 41)) null else try domain.TeamSummary.init(try result.int(i32, row, 41), result.value(row, 42), result.value(row, 43), try result.int(i64, row, 44)),
                .beatmap = .{
                    .id = try result.int(i32, row, 7),
                    .set_id = try result.int(i32, row, 32),
                    .status = lazerStatus(try result.int(i32, row, 22)),
                    .checksum = result.value(row, 33),
                    .ruleset_id = try result.int(i32, row, 34),
                    .star_rating = try result.float(f64, row, 35),
                    .version = result.value(row, 36),
                    .artist = result.value(row, 37),
                    .title = result.value(row, 38),
                    .creator = result.value(row, 39),
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
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.id,s.user_id,u.name,CASE WHEN u.show_country THEN u.country ELSE 'XX' END,s.beatmap_id,s.ruleset_id,s.total_score,s.total_score_without_mods,s.legacy_total_score,s.pp,s.accuracy,s.max_combo,s.passed,s.rank,s.mods_json::text,s.statistics_json::text,s.maximum_statistics_json::text,s.pauses_json::text,to_char(to_timestamp(s.submitted_at) AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),b.status,(s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id))),b.set_id,b.md5,b.mode,b.star_rating,b.version,b.artist,b.title,b.creator,s.rank_namespace FROM zigcho.lazer_scores s JOIN zigcho.users u ON u.id=s.user_id JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.id=$1 AND s.beatmap_id=$2 AND NOT u.restricted", &.{ score_text, map_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        const status = try result.int(i32, 0, 19);
        const score: lazer.LeaderboardScore = .{
            .id = try result.int(i64, 0, 0),
            .legacy_total_score = if (result.isNull(0, 8)) null else try result.int(i32, 0, 8),
            .user_id = try result.int(i32, 0, 1),
            .username = result.value(0, 2),
            .country = result.value(0, 3),
            .beatmap_id = try result.int(i32, 0, 4),
            .ruleset_id = try result.int(i32, 0, 5),
            .total_score = try result.int(i64, 0, 6),
            .total_score_without_mods = try result.int(i64, 0, 7),
            .pp = try result.float(f64, 0, 9),
            .accuracy = try result.float(f64, 0, 10),
            .max_combo = try result.int(i32, 0, 11),
            .passed = try result.boolean(0, 12),
            .rank = result.value(0, 13),
            .mods_json = result.value(0, 14),
            .statistics_json = result.value(0, 15),
            .maximum_statistics_json = result.value(0, 16),
            .pauses_json = result.value(0, 17),
            .ended_at = result.value(0, 18),
            .ranked = status == 3 or status == 4,
            .has_replay = try result.boolean(0, 20),
            .beatmap = .{
                .id = try result.int(i32, 0, 4),
                .set_id = try result.int(i32, 0, 21),
                .status = lazerStatus(status),
                .checksum = result.value(0, 22),
                .ruleset_id = try result.int(i32, 0, 23),
                .star_rating = try result.float(f64, 0, 24),
                .version = result.value(0, 25),
                .artist = result.value(0, 26),
                .title = result.value(0, 27),
                .creator = result.value(0, 28),
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
        const total_score_without_mods = try param(&buffers, &cursor, input.total_score_without_mods);
        const legacy_total_score = try param(&buffers, &cursor, lazer.classicTotalScore(input));
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
        var result = try postgres.queryParams(self.allocator, conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,client_version,pp,best,replay,star_rating) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12::jsonb,$13::jsonb,$14::jsonb,$15,$16,$17,$18,$19,$20) RETURNING id", &.{ user, beatmap_id, ruleset_id, total_score, total_score_without_mods, legacy_total_score, accuracy, max_combo, passed, rank, mods_json, statistics_json, maximum_statistics_json, pauses_json, namespace, input.client_version, pp_text, if (is_best) "true" else "false", replay_encoded, star_rating });
        defer result.deinit();
        const score_id = try result.int(i64, 0, 0);
        if (is_best and previous_best_id != 0) {
            var previous_buffer: [32]u8 = undefined;
            const previous_id = try std.fmt.bufPrint(&previous_buffer, "{d}", .{previous_best_id});
            var unset = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.lazer_scores SET best=false WHERE id=$1", &.{previous_id});
            unset.deinit();
        }
        try self.updateLazerStatsWithConnection(conn, user_id, input);
        if (lazer.statsMode(input)) |stats_mode| {
            try self.pruneStatsHistoryWithConnection(conn);
            try self.recordStatsHistorySliceCurrentWithConnection(conn, .lazer, stats_mode, user_id);
            try self.recordStatsHistorySliceCurrentWithConnection(conn, .all, stats_mode, user_id);
        }
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
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const beatmap_id = try param(&buffers, &cursor, input.beatmap_id);

        var map = try postgres.queryParams(self.allocator, conn, "SELECT md5,status,greatest(total_length,0) FROM zigcho.beatmaps WHERE id=$1 FOR UPDATE", &.{beatmap_id});
        defer map.deinit();
        if (map.rows() == 0) return;
        const map_status = try map.int(i32, 0, 1);
        if (lazer.statsMode(input)) |stats_mode| {
            const stats_mode_text = try param(&buffers, &cursor, stats_mode);
            const legacy_score = try param(&buffers, &cursor, lazer.classicTotalScore(input));
            const max_combo = try param(&buffers, &cursor, input.max_combo);
            const hits = try param(&buffers, &cursor, lazer.totalHits(input));
            const play_time = try param(&buffers, &cursor, try map.int(i32, 0, 2));
            var update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.stats SET total_score=total_score+$1,plays=plays+1,play_time=play_time+$2,total_hits=total_hits+$3,max_combo=CASE WHEN $4::boolean THEN greatest(max_combo,$5) ELSE max_combo END WHERE user_id=$6 AND mode=$7", &.{ legacy_score, play_time, hits, if (input.passed and map_status >= 3) "true" else "false", max_combo, user, stats_mode_text });
            update.deinit();
        }
        var map_update = try postgres.queryParams(self.allocator, conn, "UPDATE zigcho.beatmaps SET plays=plays+1,passes=passes+$1 WHERE id=$2", &.{ if (input.passed) "1" else "0", beatmap_id });
        map_update.deinit();
        if (lazer.statsMode(input)) |stats_mode| {
            if (input.passed and (map_status == 3 or map_status == 4)) try self.rebuildCombinedPerformanceWithConnection(conn, user_id, @intCast(input.ruleset_id), stats_mode, @tagName(input.namespace), false);
        }
    }

    fn rebuildCombinedPerformanceWithConnection(self: *Store, conn: *postgres.c.PGconn, user_id: i32, ruleset_id: u8, stats_mode: u8, namespace: []const u8, pre_schema_43: bool) !void {
        var buffers: [32][64]u8 = undefined;
        var cursor: usize = 0;
        const user = try param(&buffers, &cursor, user_id);
        const ruleset = try param(&buffers, &cursor, ruleset_id);
        const mode = try param(&buffers, &cursor, stats_mode);
        const sql = if (pre_schema_43)
            "WITH candidates AS (" ++
                "SELECT b.id beatmap_id,s.pp,s.accuracy,s.score legacy_score,0 source,s.id score_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4) " ++
                "UNION ALL SELECT s.beatmap_id,s.pp,s.accuracy,coalesce(s.legacy_total_score,s.total_score),1,s.id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4))," ++
                "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id ORDER BY pp DESC,source ASC,score_id ASC) map_place FROM candidates) " ++
                "SELECT pp,accuracy,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_id ASC"
        else
            "WITH candidates AS (" ++
                "SELECT b.id beatmap_id,s.pp,s.accuracy,s.score legacy_score,0 source,s.id score_id FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4) " ++
                "UNION ALL SELECT s.beatmap_id,s.pp,s.accuracy,coalesce(s.legacy_total_score,s.total_score),1,s.id FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3 AND s.passed AND b.status IN(3,4))," ++
                "per_map AS (SELECT *,row_number() OVER(PARTITION BY beatmap_id ORDER BY pp DESC,source ASC,score_id ASC) map_place FROM candidates) " ++
                "SELECT pp,accuracy,legacy_score FROM per_map WHERE map_place=1 ORDER BY pp DESC,beatmap_id ASC";
        var result = try postgres.queryParams(self.allocator, conn, sql, &.{ user, ruleset, namespace });
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

    pub fn isLazerRoomScoreToken(token_id: i64) bool {
        return sqlite_storage.Store.isLazerRoomScoreToken(token_id);
    }

    const lazer_room_score_token_tag: u64 = 0x7f_ff_ff_00_00_00_00_00;
    const lazer_room_score_token_mask: u64 = 0x7f_ff_ff_00_00_00_00_00;
    const lazer_room_score_token_payload_mask: u64 = 0x00_00_00_ff_ff_ff_ff_ff;

    pub fn createLazerScoreToken(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
        return self.createLazerScoreTokenScoped(user_id, beatmap_id, beatmap_hash, ruleset_id, version_hash, false);
    }

    pub fn createLazerRoomScoreToken(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8) !i64 {
        return self.createLazerScoreTokenScoped(user_id, beatmap_id, beatmap_hash, ruleset_id, version_hash, true);
    }

    pub fn discardUnusedLazerRoomScoreToken(self: *Store, user_id: i32, token_id: i64) !bool {
        if (!isLazerRoomScoreToken(token_id)) return false;
        var buffers: [2][32]u8 = undefined;
        var cursor: usize = 0;
        const token = try param(&buffers, &cursor, token_id);
        const user = try param(&buffers, &cursor, user_id);
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_score_tokens WHERE id=$1 AND user_id=$2 AND consumed_at IS NULL AND score_id IS NULL RETURNING 1", &.{ token, user });
        defer result.deinit();
        return result.rows() == 1;
    }

    fn createLazerScoreTokenScoped(self: *Store, user_id: i32, beatmap_id: i32, beatmap_hash: []const u8, ruleset_id: i64, version_hash: []const u8, room_scoped: bool) !i64 {
        var random_bytes: [8]u8 = undefined;
        try std.Io.randomSecure(self.io, &random_bytes);
        var raw = std.mem.readInt(u64, &random_bytes, .little) & std.math.maxInt(i64);
        if (room_scoped) {
            raw = Store.lazer_room_score_token_tag | (raw & Store.lazer_room_score_token_payload_mask);
        } else if ((raw & Store.lazer_room_score_token_mask) == Store.lazer_room_score_token_tag) {
            raw &= ~Store.lazer_room_score_token_mask;
        }
        const token_id: i64 = @intCast(raw | 1);
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
        return self.submitLazerScoreTokenScoped(user_id, beatmap_id, token_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data, false);
    }

    pub fn submitLazerRoomScoreToken(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8) !i64 {
        return self.submitLazerScoreTokenScoped(user_id, beatmap_id, token_id, input, pp_value, mods_json, statistics_json, maximum_statistics_json, pauses_json, replay_data, true);
    }

    fn submitLazerScoreTokenScoped(self: *Store, user_id: i32, beatmap_id: i32, token_id: i64, input: lazer.ScoreInput, pp_value: f64, mods_json: []const u8, statistics_json: []const u8, maximum_statistics_json: []const u8, pauses_json: []const u8, replay_data: []const u8, room_scoped: bool) !i64 {
        if (isLazerRoomScoreToken(token_id) != room_scoped) return error.InvalidLazerScoreToken;
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
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND NOT u.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND NOT u.restricted AND u.country=me.country AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM zigcho.stats s JOIN zigcho.users me ON me.id=s.user_id WHERE s.user_id=$1 AND s.mode=$2", &.{ id, mode_text });
        defer result.deinit();
        if (result.rows() == 0) return null;
        var stats: domain.Stats = .{ .mode = @enumFromInt(mode % 4), .ranked_score = try result.int(i64, 0, 0), .total_score = try result.int(i64, 0, 1), .pp = try result.int(i32, 0, 2), .plays = try result.int(i32, 0, 3), .play_time = try result.int(i32, 0, 4), .total_hits = try result.int(i64, 0, 5), .accuracy = try result.float(f64, 0, 6), .max_combo = try result.int(i32, 0, 7), .global_rank = try result.int(i32, 0, 8), .country_rank = try result.int(i32, 0, 9), .replay_views = try self.replayViewCountWithConnection(lease.conn, user_id, .all, mode) };
        var stable = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{ id, mode_text });
        defer stable.deinit();
        for (0..stable.rows()) |row| stats.addGrade(sqlite_storage.Store.stableGrade(mode, try stable.int(i32, row, 0), try stable.float(f64, row, 1), try stable.int(i32, row, 2), try stable.int(i32, row, 3), try stable.int(i32, row, 4), try stable.int(i32, row, 5)));
        var modern = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.rank FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{ id, mode_text });
        defer modern.deinit();
        for (0..modern.rows()) |row| stats.addGrade(modern.value(row, 0));
        return stats;
    }

    pub fn statsRulesetsForUser(self: *Store, user_id: i32) ![4]?domain.Stats {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = [_]?domain.Stats{null} ** 4;
        var rows = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.mode,s.ranked_score,s.total_score,s.pp,s.plays,s.play_time,s.total_hits,s.accuracy,s.max_combo,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND NOT u.restricted AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END,CASE WHEN s.plays>0 THEN (SELECT count(1)+1 FROM zigcho.stats r JOIN zigcho.users u ON u.id=r.user_id WHERE r.mode=s.mode AND r.plays>0 AND u.id!=3 AND NOT u.restricted AND u.country=me.country AND (r.pp>s.pp OR (r.pp=s.pp AND r.user_id<s.user_id))) ELSE 0 END FROM zigcho.stats s JOIN zigcho.users me ON me.id=s.user_id WHERE s.user_id=$1 AND s.mode BETWEEN 0 AND 3 ORDER BY s.mode", &.{id});
        defer rows.deinit();
        for (0..rows.rows()) |row| {
            const mode = try rows.int(u8, row, 0);
            result[mode] = .{
                .mode = @enumFromInt(mode),
                .ranked_score = try rows.int(i64, row, 1),
                .total_score = try rows.int(i64, row, 2),
                .pp = try rows.int(i32, row, 3),
                .plays = try rows.int(i32, row, 4),
                .play_time = try rows.int(i32, row, 5),
                .total_hits = try rows.int(i64, row, 6),
                .accuracy = try rows.float(f64, row, 7),
                .max_combo = try rows.int(i32, row, 8),
                .global_rank = try rows.int(i32, row, 9),
                .country_rank = try rows.int(i32, row, 10),
            };
        }
        var stable = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.mode,s.mods,s.accuracy,s.n300,s.n100,s.n50,s.nmiss FROM zigcho.scores s JOIN zigcho.beatmaps b ON b.md5=s.map_md5 WHERE s.user_id=$1 AND s.mode BETWEEN 0 AND 3 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{id});
        defer stable.deinit();
        for (0..stable.rows()) |row| {
            const mode = try stable.int(u8, row, 0);
            if (result[mode]) |*stats| stats.addGrade(sqlite_storage.Store.stableGrade(mode, try stable.int(i32, row, 1), try stable.float(f64, row, 2), try stable.int(i32, row, 3), try stable.int(i32, row, 4), try stable.int(i32, row, 5), try stable.int(i32, row, 6)));
        }
        var modern = try postgres.queryParams(self.allocator, lease.conn, "SELECT s.ruleset_id,s.rank FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id WHERE s.user_id=$1 AND s.ruleset_id BETWEEN 0 AND 3 AND s.rank_namespace='vanilla' AND s.passed AND s.best AND b.status IN(3,4)", &.{id});
        defer modern.deinit();
        for (0..modern.rows()) |row| {
            const mode = try modern.int(u8, row, 0);
            if (result[mode]) |*stats| stats.addGrade(modern.value(row, 1));
        }
        for (0..result.len) |mode| if (result[mode]) |*stats| {
            stats.replay_views = try self.replayViewCountWithConnection(lease.conn, user_id, .all, @intCast(mode));
        };
        return result;
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
            .replay_views = try self.replayViewCountWithConnection(lease.conn, user_id, source, mode),
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
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,max_combo,artist,title,version,creator,status,star_rating,greatest(total_length,0),greatest(CASE WHEN hit_length>0 THEN hit_length ELSE total_length END,0) FROM zigcho.beatmaps WHERE md5=$1", &.{md5});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const artist = try allocator.dupe(u8, result.value(0, 3));
        errdefer allocator.free(artist);
        const title = try allocator.dupe(u8, result.value(0, 4));
        errdefer allocator.free(title);
        const version = try allocator.dupe(u8, result.value(0, 5));
        errdefer allocator.free(version);
        const creator = try allocator.dupe(u8, result.value(0, 6));
        return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .max_combo = try result.int(i32, 0, 2), .artist = artist, .title = title, .version = version, .creator = creator, .status = try result.int(i8, 0, 7), .star_rating = try result.float(f64, 0, 8), .total_length = try result.int(i32, 0, 9), .hit_length = try result.int(i32, 0, 10) };
    }

    pub fn beatmapInfoById(self: *Store, allocator: std.mem.Allocator, map_id: i32) !?BeatmapInfo {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{map_id});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT id,set_id,max_combo,artist,title,version,creator,status,star_rating,greatest(total_length,0),greatest(CASE WHEN hit_length>0 THEN hit_length ELSE total_length END,0) FROM zigcho.beatmaps WHERE id=$1", &.{id});
        defer result.deinit();
        if (result.rows() == 0) return null;
        const artist = try allocator.dupe(u8, result.value(0, 3));
        errdefer allocator.free(artist);
        const title = try allocator.dupe(u8, result.value(0, 4));
        errdefer allocator.free(title);
        const version = try allocator.dupe(u8, result.value(0, 5));
        errdefer allocator.free(version);
        const creator = try allocator.dupe(u8, result.value(0, 6));
        return .{ .id = try result.int(i32, 0, 0), .set_id = try result.int(i32, 0, 1), .max_combo = try result.int(i32, 0, 2), .artist = artist, .title = title, .version = version, .creator = creator, .status = try result.int(i8, 0, 7), .star_rating = try result.float(f64, 0, 8), .total_length = try result.int(i32, 0, 9), .hit_length = try result.int(i32, 0, 10) };
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
            try self.rebuildCombinedPerformanceWithConnection(lease.conn, user_id, score.mode, stats_mode, namespace, false);
        }
        try self.pruneStatsHistoryWithConnection(lease.conn);
        try self.recordStatsHistorySliceCurrentWithConnection(lease.conn, if (std.mem.eql(u8, namespace, "scorev2")) .scorev2 else .stable, stats_mode, user_id);
        if (updates_player_stats) try self.recordStatsHistorySliceCurrentWithConnection(lease.conn, .all, stats_mode, user_id);
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

    pub fn stableReplay(self: *Store, allocator: std.mem.Allocator, score_id: i64) !?[]u8 {
        return self.replayData(allocator, .stable, score_id, true);
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

    pub fn issueGameTokenPair(self: *Store, user_id: i32, access_lifetime_seconds: i64, refresh_lifetime_seconds: i64, replace_existing: bool) !GameTokenPair {
        if (user_id <= 0 or access_lifetime_seconds <= 0 or refresh_lifetime_seconds <= 0) return error.InvalidOauthTokenPair;
        const access = try randomOauthToken(self.io);
        const refresh = try randomOauthToken(self.io);
        const client_id = try randomOauthClientId(self.io);
        var access_digest: [32]u8 = undefined;
        var refresh_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&access, &access_digest, .{});
        std.crypto.hash.sha2.Sha256.hash(&refresh, &refresh_digest, .{});
        const access_bytea = try postgres.encodeBytea(self.allocator, &access_digest);
        defer self.allocator.free(access_bytea);
        const refresh_bytea = try postgres.encodeBytea(self.allocator, &refresh_digest);
        defer self.allocator.free(refresh_bytea);
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        var user_buf: [24]u8 = undefined;
        var client_buf: [24]u8 = undefined;
        var now_buf: [32]u8 = undefined;
        var access_expiry_buf: [32]u8 = undefined;
        var refresh_expiry_buf: [32]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        const client = try std.fmt.bufPrint(&client_buf, "{d}", .{client_id});
        const now = try std.fmt.bufPrint(&now_buf, "{d}", .{now_seconds});
        const access_expiry = try std.fmt.bufPrint(&access_expiry_buf, "{d}", .{now_seconds + access_lifetime_seconds});
        const refresh_expiry = try std.fmt.bufPrint(&refresh_expiry_buf, "{d}", .{now_seconds + refresh_lifetime_seconds});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{user});
        lock.deinit();
        if (replace_existing) {
            var revoke = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)')", &.{user});
            revoke.deinit();
            var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{user});
            clear.deinit();
        }
        var access_insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,client_id,expires_at,last_used_at) VALUES($1,$2,'identify scores:write',$3,$4,$5)", &.{ access_bytea, user, client, access_expiry, now });
        access_insert.deinit();
        var refresh_insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,client_id,expires_at) VALUES($1,$2,'game:refresh',$3,$4)", &.{ refresh_bytea, user, client, refresh_expiry });
        refresh_insert.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return .{ .access = access, .refresh = refresh };
    }

    pub fn rotateGameTokenPair(self: *Store, allocator: std.mem.Allocator, refresh_token: []const u8, access_lifetime_seconds: i64, refresh_lifetime_seconds: i64) !?GameTokenRefresh {
        if (refresh_token.len != 64 or access_lifetime_seconds <= 0 or refresh_lifetime_seconds <= 0) return null;
        var old_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(refresh_token, &old_digest, .{});
        const old_bytea = try postgres.encodeBytea(self.allocator, &old_digest);
        defer self.allocator.free(old_bytea);
        const access = try randomOauthToken(self.io);
        const refresh = try randomOauthToken(self.io);
        const new_client_id = try randomOauthClientId(self.io);
        var access_digest: [32]u8 = undefined;
        var refresh_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&access, &access_digest, .{});
        std.crypto.hash.sha2.Sha256.hash(&refresh, &refresh_digest, .{});
        const access_bytea = try postgres.encodeBytea(self.allocator, &access_digest);
        defer self.allocator.free(access_bytea);
        const refresh_bytea = try postgres.encodeBytea(self.allocator, &refresh_digest);
        defer self.allocator.free(refresh_bytea);
        const now_seconds = std.Io.Clock.real.now(self.io).toSeconds();
        const rotated_user_id: i32 = rotate: {
            var lease = self.pool.acquire();
            defer lease.release();
            try postgres.exec(lease.conn, "BEGIN");
            errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
            var current = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id,client_id FROM zigcho.oauth_tokens WHERE token_hash=$1 AND scopes='game:refresh' AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint", &.{old_bytea});
            if (current.rows() == 0) {
                current.deinit();
                try postgres.exec(lease.conn, "ROLLBACK");
                return null;
            }
            const user_id = try current.int(i32, 0, 0);
            const legacy = current.isNull(0, 1);
            const old_client_id = if (legacy) @as(i32, 0) else try current.int(i32, 0, 1);
            current.deinit();
            var user_buf: [24]u8 = undefined;
            var old_client_buf: [24]u8 = undefined;
            var new_client_buf: [24]u8 = undefined;
            var now_buf: [32]u8 = undefined;
            var access_expiry_buf: [32]u8 = undefined;
            var refresh_expiry_buf: [32]u8 = undefined;
            const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
            const old_client = try std.fmt.bufPrint(&old_client_buf, "{d}", .{old_client_id});
            const new_client = try std.fmt.bufPrint(&new_client_buf, "{d}", .{new_client_id});
            const now = try std.fmt.bufPrint(&now_buf, "{d}", .{now_seconds});
            const access_expiry = try std.fmt.bufPrint(&access_expiry_buf, "{d}", .{now_seconds + access_lifetime_seconds});
            const refresh_expiry = try std.fmt.bufPrint(&refresh_expiry_buf, "{d}", .{now_seconds + refresh_lifetime_seconds});
            var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{user_text});
            lock.deinit();
            var consume = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND scopes='game:refresh' AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint RETURNING 1", &.{old_bytea});
            const consumed = consume.rows() != 0;
            consume.deinit();
            if (!consumed) {
                try postgres.exec(lease.conn, "ROLLBACK");
                return null;
            }
            var revoke = if (legacy)
                try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND client_id IS NULL AND revoked_at IS NULL AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)'", &.{user_text})
            else
                try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND client_id=$2 AND revoked_at IS NULL AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)'", &.{ user_text, old_client });
            revoke.deinit();
            var access_insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,client_id,expires_at,last_used_at) VALUES($1,$2,'identify scores:write',$3,$4,$5)", &.{ access_bytea, user_text, new_client, access_expiry, now });
            access_insert.deinit();
            var refresh_insert = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.oauth_tokens(token_hash,user_id,scopes,client_id,expires_at) VALUES($1,$2,'game:refresh',$3,$4)", &.{ refresh_bytea, user_text, new_client, refresh_expiry });
            refresh_insert.deinit();
            try postgres.exec(lease.conn, "COMMIT");
            break :rotate user_id;
        };
        const user = (try self.userById(allocator, rotated_user_id)) orelse return error.UserNotFound;
        return .{ .user = user, .tokens = .{ .access = access, .refresh = refresh } };
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
            const sql = "SELECT u.id,u.name,u.safe_name,u.country,u.privileges,u.silence_end,u.restricted,coalesce((SELECT updated_at FROM zigcho.user_banners ub WHERE ub.user_id=u.id),0),tm.team_id,team.name,team.short_name,coalesce((SELECT updated_at FROM zigcho.team_assets ta WHERE ta.team_id=team.id AND ta.kind='flag'),0),u.show_country," ++ visible_follower_count_sql ++ ",t.scopes FROM zigcho.oauth_tokens t JOIN zigcho.users u ON u.id=t.user_id LEFT JOIN zigcho.team_members tm ON tm.user_id=u.id LEFT JOIN zigcho.teams team ON team.id=tm.team_id WHERE t.token_hash=$1 AND t.revoked_at IS NULL AND t.expires_at>$2";
            var query_result = try postgres.queryParams(self.allocator, lease.conn, sql, &.{ digest_bytea, now });
            defer query_result.deinit();
            if (query_result.rows() == 0) return null;
            var allowed = required_scope.len == 0;
            var scopes = std.mem.splitScalar(u8, query_result.value(0, 14), ' ');
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

    pub fn setLazerActivityForToken(self: *Store, token: []const u8, expected_user_id: i32, status: []const u8, detail: []const u8, beatmap_id: ?i32, ruleset_id: ?u8) !bool {
        if (token.len != 64 or expected_user_id <= 0) return false;
        if (!domain.validLazerActivity(status, detail, beatmap_id, ruleset_id)) return error.InvalidLazerActivity;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var id_buf: [24]u8 = undefined;
        var beatmap_buf: [24]u8 = undefined;
        var ruleset_buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{expected_user_id});
        const beatmap_value: ?[]const u8 = if (beatmap_id) |value| try std.fmt.bufPrint(&beatmap_buf, "{d}", .{value}) else null;
        const ruleset_value: ?[]const u8 = if (ruleset_id) |value| try std.fmt.bufPrint(&ruleset_buf, "{d}", .{value}) else null;
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var owner = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.oauth_tokens WHERE token_hash=$1 AND user_id=$2 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)' FOR UPDATE", &.{ digest_bytea, id });
        if (owner.rows() == 0) {
            owner.deinit();
            try postgres.exec(lease.conn, "ROLLBACK");
            return false;
        }
        owner.deinit();
        var activity = try postgres.queryParams(self.allocator, lease.conn, "INSERT INTO zigcho.lazer_presence(user_id,status,detail,beatmap_id,ruleset_id,updated_at) VALUES($1,$2,$3,$4,$5,extract(epoch FROM clock_timestamp())::bigint) ON CONFLICT(user_id) DO UPDATE SET status=excluded.status,detail=excluded.detail,beatmap_id=excluded.beatmap_id,ruleset_id=excluded.ruleset_id,updated_at=excluded.updated_at", &.{ id, status, detail, beatmap_value, ruleset_value });
        activity.deinit();
        var touch = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET last_used_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND user_id=$2 AND revoked_at IS NULL RETURNING 1", &.{ digest_bytea, id });
        defer touch.deinit();
        if (touch.rows() != 1) return error.DatabaseQueryFailed;
        try postgres.exec(lease.conn, "COMMIT");
        return true;
    }

    pub fn clearLazerActivityForToken(self: *Store, token: []const u8, expected_user_id: i32) !bool {
        if (token.len != 64 or expected_user_id <= 0) return false;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{expected_user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var owner = try postgres.queryParams(self.allocator, lease.conn, "SELECT 1 FROM zigcho.oauth_tokens WHERE token_hash=$1 AND user_id=$2 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)' FOR UPDATE", &.{ digest_bytea, id });
        if (owner.rows() == 0) {
            owner.deinit();
            try postgres.exec(lease.conn, "ROLLBACK");
            return false;
        }
        owner.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
        clear.deinit();
        var touch = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET last_used_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND user_id=$2 AND revoked_at IS NULL RETURNING 1", &.{ digest_bytea, id });
        defer touch.deinit();
        if (touch.rows() != 1) return error.DatabaseQueryFailed;
        try postgres.exec(lease.conn, "COMMIT");
        return true;
    }

    pub fn lazerActivity(self: *Store, allocator: std.mem.Allocator, user_id: i32, cutoff: i64) !?domain.LazerActivity {
        var id_buf: [24]u8 = undefined;
        var cutoff_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        const cutoff_value = try std.fmt.bufPrint(&cutoff_buf, "{d}", .{cutoff});
        var lease = self.pool.acquire();
        defer lease.release();
        var result = try postgres.queryParams(self.allocator, lease.conn, "SELECT status,detail,beatmap_id,ruleset_id FROM zigcho.lazer_presence WHERE user_id=$1 AND updated_at>=$2", &.{ id, cutoff_value });
        defer result.deinit();
        if (result.rows() == 0) return null;
        const status = try allocator.dupe(u8, result.value(0, 0));
        errdefer allocator.free(status);
        const detail = try allocator.dupe(u8, result.value(0, 1));
        return .{
            .allocator = allocator,
            .status = status,
            .detail = detail,
            .beatmap_id = if (result.isNull(0, 2)) null else try result.int(i32, 0, 2),
            .ruleset_id = if (result.isNull(0, 3)) null else try result.int(u8, 0, 3),
        };
    }

    pub fn revokeToken(self: *Store, token: []const u8) !bool {
        if (token.len != 64) return false;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        const digest_bytea = try postgres.encodeBytea(self.allocator, &digest);
        defer self.allocator.free(digest_bytea);
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var current = try postgres.queryParams(self.allocator, lease.conn, "SELECT user_id,scopes FROM zigcho.oauth_tokens WHERE token_hash=$1 AND revoked_at IS NULL", &.{digest_bytea});
        if (current.rows() == 0) {
            current.deinit();
            try postgres.exec(lease.conn, "ROLLBACK");
            return false;
        }
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{try current.int(i32, 0, 0)});
        const game_lookup = hasGameAccessScopes(current.value(0, 1)) or hasOauthScope(current.value(0, 1), "game:refresh");
        current.deinit();
        if (game_lookup) {
            var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
            lock.deinit();
        }
        var locked = try postgres.queryParams(self.allocator, lease.conn, "SELECT scopes,client_id FROM zigcho.oauth_tokens WHERE token_hash=$1 AND revoked_at IS NULL FOR UPDATE", &.{digest_bytea});
        if (locked.rows() == 0) {
            locked.deinit();
            try postgres.exec(lease.conn, "ROLLBACK");
            return false;
        }
        const scopes = locked.value(0, 0);
        const game_session = hasGameAccessScopes(scopes) or hasOauthScope(scopes, "game:refresh");
        const legacy_game_session = game_session and locked.isNull(0, 1);
        const client_id = if (legacy_game_session or !game_session) @as(i32, 0) else try locked.int(i32, 0, 1);
        locked.deinit();
        var client_buf: [24]u8 = undefined;
        const client = try std.fmt.bufPrint(&client_buf, "{d}", .{client_id});
        var result = if (game_session)
            if (legacy_game_session)
                try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND client_id IS NULL AND revoked_at IS NULL AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)') RETURNING 1", &.{id})
            else
                try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND client_id=$2 AND revoked_at IS NULL AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)') RETURNING 1", &.{ id, client })
        else
            try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE token_hash=$1 AND revoked_at IS NULL RETURNING 1", &.{digest_bytea});
        const revoked = result.rows() != 0;
        result.deinit();
        if (game_session and revoked) {
            var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1 AND NOT EXISTS(SELECT 1 FROM zigcho.oauth_tokens WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)')", &.{id});
            clear.deinit();
        }
        try postgres.exec(lease.conn, "COMMIT");
        return revoked;
    }

    pub fn revokeGameTokensForUser(self: *Store, user_id: i32) !usize {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var lock = try postgres.queryParams(self.allocator, lease.conn, "SELECT pg_advisory_xact_lock($1::bigint)", &.{id});
        lock.deinit();
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>extract(epoch FROM clock_timestamp())::bigint AND ((scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)') OR scopes ~ '(^| )game:refresh( |$)') RETURNING 1", &.{id});
        const revoked = result.rows();
        result.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
        clear.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return revoked;
    }

    pub fn revokeLazerAccessTokensForUser(self: *Store, user_id: i32) !usize {
        var id_buf: [24]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "{d}", .{user_id});
        var lease = self.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "BEGIN");
        errdefer postgres.exec(lease.conn, "ROLLBACK") catch {};
        var result = try postgres.queryParams(self.allocator, lease.conn, "UPDATE zigcho.oauth_tokens SET revoked_at=extract(epoch FROM clock_timestamp())::bigint WHERE user_id=$1 AND revoked_at IS NULL AND scopes ~ '(^| )identify( |$)' AND scopes ~ '(^| )scores:write( |$)' RETURNING 1", &.{id});
        const revoked = result.rows();
        result.deinit();
        var clear = try postgres.queryParams(self.allocator, lease.conn, "DELETE FROM zigcho.lazer_presence WHERE user_id=$1", &.{id});
        clear.deinit();
        try postgres.exec(lease.conn, "COMMIT");
        return revoked;
    }
};

test "postgres score submissions refresh both sides of a daily rank swap" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_HISTORY_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const first_id = try store.register("history first", "history-first@example.test", "00000000000000000000000000000000");
    const second_id = try store.register("history second", "history-second@example.test", "11111111111111111111111111111111");
    const map_md5 = "99999999999999999999999999999991";
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var map = try postgres.query(lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(990000001,990000001,'99999999999999999999999999999991','history','rank swap','test','zigcho',3,10)");
        map.deinit();
    }

    const base: stable_score.Submission = .{
        .map_md5 = map_md5,
        .username = "history first",
        .online_checksum = "99999999999999999999999999999992",
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
        .client_time = "260825000000",
        .client_flags = "0",
    };
    _ = try store.insertStableScore(first_id, base, 40, "first replay", 12_000);
    var second_low = base;
    second_low.username = "history second";
    second_low.online_checksum = "99999999999999999999999999999993";
    second_low.total_score = 900_000;
    _ = try store.insertStableScore(second_id, second_low, 20, "second low replay", 12_000);
    try std.testing.expectEqual(@as(i32, 1), (try store.statsHistory(first_id, .all, 0)).points[0].global_rank);
    try std.testing.expectEqual(@as(i32, 2), (try store.statsHistory(second_id, .all, 0)).points[0].global_rank);

    var second_high = second_low;
    second_high.online_checksum = "99999999999999999999999999999994";
    second_high.total_score = 1_100_000;
    _ = try store.insertStableScore(second_id, second_high, 80, "second high replay", 12_000);
    const first_history = try store.statsHistory(first_id, .all, 0);
    const second_history = try store.statsHistory(second_id, .all, 0);
    try std.testing.expectEqual(@as(u8, 1), first_history.len);
    try std.testing.expectEqual(@as(u8, 1), second_history.len);
    try std.testing.expectEqual(@as(i32, 2), first_history.points[0].global_rank);
    try std.testing.expectEqual(@as(i32, 1), second_history.points[0].global_rank);
    {
        var buffers: [2][24]u8 = undefined;
        const first = try std.fmt.bufPrint(&buffers[0], "{d}", .{first_id});
        const second = try std.fmt.bufPrint(&buffers[1], "{d}", .{second_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var ranks = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT count(*),count(DISTINCT global_rank) FROM zigcho.user_stats_history WHERE source='all' AND mode=0 AND day=(extract(epoch FROM transaction_timestamp())::bigint/86400)*86400 AND user_id IN($1,$2)", &.{ first, second });
        defer ranks.deinit();
        try std.testing.expectEqual(@as(i64, 2), try ranks.int(i64, 0, 0));
        try std.testing.expectEqual(@as(i64, 2), try ranks.int(i64, 0, 1));
    }
}

test "postgres runtime migrates through server controls schema forty five" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_MIGRATE_URL") orelse return error.SkipZigTest;
    {
        var old_store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
        defer old_store.close();
        try old_store.migrate();
        var previous = old_store.pool.acquire();
        defer previous.release();
        try postgres.exec(previous.conn, "DROP TABLE zigcho.server_controls; DROP TABLE IF EXISTS zigcho.score_replay_views; DROP TABLE zigcho.user_stats_history; DROP TABLE zigcho.lazer_ranked_matches; DROP TABLE zigcho.lazer_ranked_ratings; DROP TABLE zigcho.lazer_multiplayer_room_history; DROP TABLE zigcho.beatmapset_metadata; DROP TABLE zigcho.upstream_user_profiles; ALTER TABLE zigcho.beatmaps DROP COLUMN creator_id,DROP COLUMN upstream_plays,DROP COLUMN upstream_passes,DROP COLUMN hit_length; DROP TABLE zigcho.upstream_users; DROP TABLE zigcho.beatmap_submission_maps; DROP TABLE zigcho.beatmap_submissions; DROP TABLE zigcho.bss_counters; DROP TABLE zigcho.profile_score_pins; DROP TABLE zigcho.beatmap_tag_votes; DROP TABLE zigcho.lazer_reports; DROP TABLE zigcho.replay_objects; DROP TABLE zigcho.lazer_presence; DROP TABLE zigcho.team_assets; DROP TABLE zigcho.team_applications; DROP TABLE zigcho.team_members; DROP TABLE zigcho.teams; DROP TABLE zigcho.user_banners; DROP TABLE zigcho.user_name_changes; ALTER TABLE zigcho.users DROP COLUMN username_changes,DROP COLUMN username_changed_at; DROP TABLE zigcho.lazer_comment_reports; DROP TABLE zigcho.lazer_comment_votes; DROP TABLE zigcho.lazer_comments");
        try postgres.exec(previous.conn, "ALTER TABLE zigcho.scores DROP COLUMN star_rating; ALTER TABLE zigcho.lazer_scores DROP CONSTRAINT lazer_scores_legacy_total_score_range; ALTER TABLE zigcho.lazer_scores DROP COLUMN star_rating,DROP COLUMN total_score_without_mods; ALTER TABLE zigcho.lazer_scores ALTER COLUMN legacy_total_score TYPE bigint USING legacy_total_score::bigint; ALTER TABLE zigcho.beatmap_archives DROP COLUMN object_bytes; DROP TABLE zigcho.user_achievements; ALTER TABLE zigcho.direct_messages DROP COLUMN chat_message_id; DROP INDEX zigcho.direct_messages_sender_uuid; ALTER TABLE zigcho.direct_messages DROP COLUMN is_action,DROP COLUMN client_uuid; DROP TABLE zigcho.user_blocks; DROP TABLE zigcho.lazer_channel_reads; DROP INDEX zigcho.chat_messages_sender_uuid; ALTER TABLE zigcho.chat_messages DROP COLUMN is_action,DROP COLUMN client_uuid; DROP TABLE zigcho.anticheat_replay_fingerprints; DROP TABLE zigcho.anticheat_observations; DROP TABLE zigcho.user_avatars; ALTER TABLE zigcho.users DROP COLUMN bio,DROP COLUMN preferred_mode,DROP COLUMN profile_source,DROP COLUMN profile_title,DROP COLUMN profile_pronouns,DROP COLUMN profile_location,DROP COLUMN profile_website,DROP COLUMN profile_accent,DROP COLUMN show_country,DROP COLUMN show_profile_stats,DROP COLUMN show_recent_scores; DROP INDEX zigcho.lazer_scores_user_best; DROP TABLE zigcho.lazer_score_tokens; ALTER TABLE zigcho.lazer_scores DROP COLUMN rank,DROP COLUMN maximum_statistics_json,DROP COLUMN pauses_json,DROP COLUMN pp,DROP COLUMN best; TRUNCATE zigcho.schema_migrations; INSERT INTO zigcho.schema_migrations(version) VALUES(20)");
        try postgres.exec(previous.conn, "ALTER TABLE zigcho.beatmap_archives ALTER COLUMN osz_file SET NOT NULL; ALTER TABLE zigcho.beatmap_media ALTER COLUMN data SET NOT NULL");
        try postgres.exec(previous.conn, "DELETE FROM zigcho.lazer_scores WHERE id=2147483000; DELETE FROM zigcho.beatmaps WHERE id=2147483000; DELETE FROM zigcho.users WHERE id=2147483000; INSERT INTO zigcho.users(id,name,safe_name,password_hash,password_salt) VALUES(2147483000,'schema43 migration','schema43_migration',decode('00','hex'),decode('00','hex')); INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status) VALUES(2147483000,2147483000,'fffffffffffffffffffffffffffffff0','artist','title','diff','mapper',3); INSERT INTO zigcho.lazer_scores(id,user_id,beatmap_id,ruleset_id,total_score,legacy_total_score,accuracy,max_combo,passed,mods_json,statistics_json,rank_namespace) VALUES(2147483000,2147483000,2147483000,0,987654,900000,0.98,321,true,'[]'::jsonb,'{}'::jsonb,'vanilla')");
    }
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    try std.testing.expect(!store.external_only);
    var lease = store.pool.acquire();
    defer lease.release();
    var result = try postgres.query(lease.conn, "SELECT max(version),(to_regclass('zigcho.chat_messages') IS NOT NULL)::int,(to_regclass('zigcho.chat_channels') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_rank_requests') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_rank_events') IS NOT NULL)::int,(to_regclass('zigcho.moderation_appeals') IS NOT NULL)::int,(to_regclass('zigcho.score_pins') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_hydration_failures') IS NOT NULL)::int,(to_regclass('zigcho.screenshots') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_media') IS NOT NULL)::int,(to_regclass('zigcho.beatmap_comments') IS NOT NULL)::int,(to_regclass('zigcho.direct_messages') IS NOT NULL)::int,(to_regclass('zigcho.lazer_score_tokens') IS NOT NULL)::int,(to_regclass('zigcho.user_avatars') IS NOT NULL)::int,(to_regclass('zigcho.anticheat_observations') IS NOT NULL)::int,(to_regclass('zigcho.anticheat_replay_fingerprints') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('bio','preferred_mode','profile_source')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_scores' AND column_name IN('pp','best')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('profile_title','profile_pronouns','profile_location','profile_website','profile_accent','show_country','show_profile_stats','show_recent_scores')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='chat_messages' AND column_name IN('is_action','client_uuid')),(to_regclass('zigcho.lazer_channel_reads') IS NOT NULL)::int,(to_regclass('zigcho.user_blocks') IS NOT NULL)::int,(to_regclass('zigcho.user_achievements') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='direct_messages' AND column_name IN('is_action','client_uuid')),(to_regclass('zigcho.direct_messages_sender_uuid') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name IN('scores','lazer_scores') AND column_name='star_rating'),(SELECT count(*) FROM information_schema.tables WHERE table_schema='zigcho' AND table_name IN('lazer_comments','user_name_changes','user_banners','teams','team_members','team_applications','team_assets','lazer_presence','replay_objects','lazer_reports','beatmap_tag_votes','profile_score_pins')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='users' AND column_name IN('username_changes','username_changed_at')),(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='direct_messages' AND column_name='chat_message_id'),(to_regclass('zigcho.direct_messages_chat_message') IS NOT NULL)::int,(SELECT count(*) FROM pg_constraint WHERE connamespace='zigcho'::regnamespace AND conname='direct_messages_chat_message_id_fkey' AND convalidated) FROM zigcho.schema_migrations");
    defer result.deinit();
    try std.testing.expectEqual(@as(i32, 45), try result.int(i32, 0, 0));
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
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 28));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 29));
    try std.testing.expectEqual(@as(i32, 1), try result.int(i32, 0, 30));
    var ranked_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.lazer_ranked_ratings') IS NOT NULL)::int,(to_regclass('zigcho.lazer_ranked_matches') IS NOT NULL)::int");
    defer ranked_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try ranked_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try ranked_schema.int(i32, 0, 1));
    var room_cursor_schema = try postgres.query(lease.conn, "SELECT (SELECT (data_type='bigint')::int FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_channel_reads' AND column_name='channel_id'),(SELECT count(*) FROM pg_constraint WHERE connamespace='zigcho'::regnamespace AND conrelid='zigcho.lazer_channel_reads'::regclass AND conname='lazer_channel_reads_channel_id_check' AND convalidated)");
    defer room_cursor_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try room_cursor_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try room_cursor_schema.int(i32, 0, 1));
    var history_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.user_stats_history') IS NOT NULL)::int,(to_regclass('zigcho.user_stats_history_lookup') IS NOT NULL)::int,(to_regclass('zigcho.user_stats_history_retention') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='user_stats_history' AND column_name IN('user_id','source','mode','day','pp','global_rank'))");
    defer history_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try history_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try history_schema.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try history_schema.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i32, 6), try history_schema.int(i32, 0, 3));
    var replay_views_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.score_replay_views') IS NOT NULL)::int,(to_regclass('zigcho.score_replay_views_owner') IS NOT NULL)::int,(SELECT count(*) FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='score_replay_views' AND column_name IN('source','score_id','viewer_id','owner_id','mode','rank_namespace','viewed_at'))");
    defer replay_views_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try replay_views_schema.int(i32, 0, 0));
    try std.testing.expectEqual(@as(i32, 1), try replay_views_schema.int(i32, 0, 1));
    try std.testing.expectEqual(@as(i32, 7), try replay_views_schema.int(i32, 0, 2));
    var friends_schema = try postgres.query(lease.conn, "SELECT (to_regclass('zigcho.friends_inbound') IS NOT NULL)::int");
    defer friends_schema.deinit();
    try std.testing.expectEqual(@as(i32, 1), try friends_schema.int(i32, 0, 0));
    var score_schema = try postgres.query(lease.conn, "SELECT total_score,total_score_without_mods,(legacy_total_score IS NULL)::int,(SELECT (data_type='bigint')::int FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_scores' AND column_name='total_score_without_mods'),(SELECT (data_type='integer')::int FROM information_schema.columns WHERE table_schema='zigcho' AND table_name='lazer_scores' AND column_name='legacy_total_score') FROM zigcho.lazer_scores WHERE id=2147483000");
    defer score_schema.deinit();
    try std.testing.expectEqual(@as(i64, 987654), try score_schema.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i64, 900000), try score_schema.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i32, 0), try score_schema.int(i32, 0, 2));
    try std.testing.expectEqual(@as(i32, 1), try score_schema.int(i32, 0, 3));
    try std.testing.expectEqual(@as(i32, 1), try score_schema.int(i32, 0, 4));
    var control_schema = try postgres.query(lease.conn, "SELECT count(*),count(DISTINCT key),bool_and(enabled)::int FROM zigcho.server_controls");
    defer control_schema.deinit();
    try std.testing.expectEqual(@as(i64, server_control.definitions.len), try control_schema.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i64, server_control.definitions.len), try control_schema.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i32, 1), try control_schema.int(i32, 0, 2));
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

test "postgres room chat acknowledgements stay monotonic across reconnect" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_ROOM_CHAT_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    errdefer store.close();
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "DELETE FROM zigcho.users WHERE safe_name='room_cursor_pg'");
    }
    const user_id = try store.register("room cursor pg", "room-cursor-pg@example.test", "00000000000000000000000000000000");

    const first = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "postgres room first", false, "41000000-0000-0000-0000-000000000001");
    defer std.testing.allocator.free(first.json);
    const second = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "postgres room second", false, "41000000-0000-0000-0000-000000000002");
    defer std.testing.allocator.free(second.json);
    const foreign = try store.recordLazerRoomMessage(std.testing.allocator, user_id, 42, "postgres other room", false, "41000000-0000-0000-0000-000000000003");
    defer std.testing.allocator.free(foreign.json);
    const public = try store.recordLazerPublicMessage(std.testing.allocator, user_id, "#lazer", "postgres public unread", false, "41000000-0000-0000-0000-000000000004");
    defer std.testing.allocator.free(public.json);

    const parsed_first = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first.json, .{});
    defer parsed_first.deinit();
    const first_id = parsed_first.value.object.get("message_id").?.integer;
    const parsed_second = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, second.json, .{});
    defer parsed_second.deinit();
    const second_id = parsed_second.value.object.get("message_id").?.integer;
    const parsed_foreign = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, foreign.json, .{});
    defer parsed_foreign.deinit();
    const foreign_id = parsed_foreign.value.object.get("message_id").?.integer;

    try std.testing.expectEqual(@as(?i64, null), (try store.lazerRoomChannelCursor(user_id, 41)).last_read_id);
    try store.markLazerRoomChannelRead(user_id, 41, first_id);
    try store.markLazerRoomChannelRead(user_id, 41, first_id);
    try store.markLazerRoomChannelRead(user_id, 41, second_id);
    try store.markLazerRoomChannelRead(user_id, 41, first_id);
    try std.testing.expectEqual(second_id, (try store.lazerRoomChannelCursor(user_id, 41)).last_read_id.?);
    try std.testing.expectError(error.ChatMessageNotFound, store.markLazerRoomChannelRead(user_id, 41, foreign_id));

    store.close();
    var reopened = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer reopened.close();
    try reopened.migrate();
    try std.testing.expectEqual(second_id, (try reopened.lazerRoomChannelCursor(user_id, 41)).last_read_id.?);
    const reconnect_feed = try reopened.lazerAllMessagesForRoomJson(std.testing.allocator, user_id, 41, 0, 100);
    defer std.testing.allocator.free(reconnect_feed);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "postgres room first") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "postgres room second") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "postgres other room") == null);
    try std.testing.expect(std.mem.indexOf(u8, reconnect_feed, "postgres public unread") != null);

    const third = try reopened.recordLazerRoomMessage(std.testing.allocator, user_id, 41, "postgres room third", false, "41000000-0000-0000-0000-000000000005");
    defer std.testing.allocator.free(third.json);
    const after_reconnect = try reopened.lazerAllMessagesForRoomJson(std.testing.allocator, user_id, 41, 0, 100);
    defer std.testing.allocator.free(after_reconnect);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "postgres room first") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "postgres room second") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_reconnect, "postgres room third") != null);
}

test "postgres ranked result updates two users atomically and deduplicates its room" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_RANKED_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    {
        var lease = store.pool.acquire();
        defer lease.release();
        try postgres.exec(lease.conn, "DELETE FROM zigcho.lazer_ranked_matches WHERE room_id=9000000039; DELETE FROM zigcho.users WHERE safe_name IN('ranked_pg_one','ranked_pg_two')");
    }
    const winner_id = try store.register("ranked pg one", "ranked-pg-one@example.test", "00000000000000000000000000000000");
    const loser_id = try store.register("ranked pg two", "ranked-pg-two@example.test", "11111111111111111111111111111111");
    try std.testing.expectEqual(@as(i32, 1500), (try store.lazerRankedRating(winner_id, 2)).rating);

    const first = try store.applyLazerRankedResult(9_000_000_039, 2, winner_id, loser_id);
    try std.testing.expect(first.applied);
    try std.testing.expectEqual(@as(i32, 1516), first.winner_rating_after);
    try std.testing.expectEqual(@as(i32, 1484), first.loser_rating_after);
    const repeat = try store.applyLazerRankedResult(9_000_000_039, 2, winner_id, loser_id);
    try std.testing.expect(!repeat.applied);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerRankedRating(winner_id, 2)).games_played);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerRankedRating(loser_id, 2)).games_played);
}

test "postgres BSS publishes an owned pending package into the BN queue" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_BSS_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    store.external_only = false;
    const owner_id = try store.register("bss pg owner", "bss-pg-owner@example.test", "00000000000000000000000000000000");
    const other_id = try store.register("bss pg other", "bss-pg-other@example.test", "11111111111111111111111111111111");
    try store.updateCountry(owner_id, .{ 'A', 'U' });
    try store.updateSiteProfile(owner_id, .{ .bio = "", .title = "", .pronouns = "", .location = "", .website = "", .accent = .pink, .preferred_mode = 0, .profile_source = .all, .avatar_key = 1, .show_country = false, .show_profile_stats = true, .show_recent_scores = true });
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
    const cover_bytes = "\x89PNG\r\n\x1a\npostgres BSS cover";
    const preview_bytes = "RIFFxxxxWAVEpostgres BSS preview";
    try store.putBeatmapMedia(reservation.set_id, .cover, .png, cover_bytes);
    try store.putBeatmapMedia(reservation.set_id, .preview, .wav, preview_bytes);
    var stored_cover = (try store.beatmapMedia(std.testing.allocator, reservation.set_id, .cover)).?;
    defer stored_cover.deinit(std.testing.allocator);
    try std.testing.expectEqual(media_contract.ContentType.png, stored_cover.content_type);
    try std.testing.expectEqualSlices(u8, cover_bytes, stored_cover.data);
    var stored_preview = (try store.beatmapMedia(std.testing.allocator, reservation.set_id, .preview)).?;
    defer stored_preview.deinit(std.testing.allocator);
    try std.testing.expectEqual(media_contract.ContentType.wav, stored_preview.content_type);
    try std.testing.expectEqualSlices(u8, preview_bytes, stored_preview.data);
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
    try std.testing.expectEqualStrings("XX", lookup_set.get("user").?.object.get("country_code").?.string);
    const pending_sets = try store.lazerUserBeatmapSetsJson(std.testing.allocator, owner_id, "pending", 0, 50, owner_id);
    defer std.testing.allocator.free(pending_sets);
    var parsed_pending_sets = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, pending_sets, .{});
    defer parsed_pending_sets.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_pending_sets.value.array.items.len);
    const owned_search = try store.lazerOwnedBeatmapSearch(std.testing.allocator, owner_id, "", -1, 0, owner_id);
    defer std.testing.allocator.free(owned_search);
    var parsed_owned_search = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, owned_search, .{});
    defer parsed_owned_search.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_owned_search.value.object.get("beatmapsets").?.array.items.len);
    try std.testing.expectEqual(@as(i64, reservation.set_id), parsed_owned_search.value.object.get("beatmapsets").?.array.items[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed_owned_search.value.object.get("total").?.integer);
    try std.testing.expect(parsed_owned_search.value.object.get("cursor").? == .null);
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
    try std.testing.expect(try store.serverControlEnabled(.spectator));
    try store.setServerControl(user_id, .spectator, false, "postgres control fixture");
    try std.testing.expect(!try store.serverControlEnabled(.spectator));
    const controls_json = try store.staffServerControlsJson(std.testing.allocator);
    defer std.testing.allocator.free(controls_json);
    try std.testing.expect(std.mem.indexOf(u8, controls_json, "\"key\":\"spectator\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, controls_json, "postgres control fixture") != null);
    try store.setServerControl(user_id, .spectator, true, "postgres control restored");
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
    const default_profile_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expect(default_profile_summary.created_at > 0);
    try std.testing.expectEqual(@as(i64, 2), default_profile_summary.avatar_version);
    try std.testing.expectEqual(@as(u8, 2), default_profile_summary.preferred_mode);
    const batch_visibility = (try store.lazerBatchUserVisibility(user_id)).?;
    try std.testing.expect(batch_visibility.show_country);
    try std.testing.expect(batch_visibility.show_profile_stats);
    const batch_rulesets = try store.statsRulesetsForUser(user_id);
    try std.testing.expectEqual(@as(i32, 0), batch_rulesets[0].?.plays);
    try std.testing.expectEqualStrings("mapper", default_profile_summary.title());
    try std.testing.expectEqualStrings("adelaide", default_profile_summary.location());
    try std.testing.expectEqualStrings("https://kai.ovh", default_profile_summary.website());
    try std.testing.expect(default_profile_summary.show_country);
    try std.testing.expect(default_profile_summary.show_profile_stats);
    try std.testing.expect(default_profile_summary.show_recent_scores);
    var avatar_etag: [64]u8 = undefined;
    @memset(&avatar_etag, 'a');
    try store.setCustomAvatar(user_id, "4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png", "image/png", avatar_etag);
    var custom_avatar = (try store.customAvatarForUser(std.testing.allocator, user_id)).?;
    try std.testing.expectEqualStrings("image/png", custom_avatar.content_type);
    try std.testing.expectEqualStrings("4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png", custom_avatar.object_key);
    const custom_avatar_version = custom_avatar.updated_at;
    custom_avatar.deinit();
    const custom_profile_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expectEqual(custom_avatar_version, custom_profile_summary.avatar_version);
    try std.testing.expect(try store.deleteCustomAvatar(user_id));
    try std.testing.expect((try store.customAvatarForUser(std.testing.allocator, user_id)) == null);
    const reset_profile_summary = (try store.lazerProfileSummary(user_id)).?;
    try std.testing.expectEqual(@as(i64, 2), reset_profile_summary.avatar_version);
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
    const refresh_token = try store.issueToken(user_id, "game:refresh", 60);
    const token_user = (try store.authenticateToken(std.testing.allocator, &token, "identify")).?;
    std.testing.allocator.free(token_user.name);
    std.testing.allocator.free(token_user.safe_name);
    try std.testing.expect(try store.setLazerActivityForToken(&token, user_id, "playing", "postgres fixture", 1, 0));
    var activity = (try store.lazerActivity(std.testing.allocator, user_id, 0)).?;
    try std.testing.expectEqualStrings("postgres fixture", activity.detail);
    activity.deinit();
    try std.testing.expect(try store.revokeToken(&token));
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &token, "identify")) == null);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &refresh_token)) == null);
    try std.testing.expect((try store.lazerActivity(std.testing.allocator, user_id, 0)) == null);
    const refresh = try store.issueToken(user_id, "game:refresh", 60);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &refresh, "identify")) == null);
    const refreshed_user = (try store.consumeGameRefreshToken(std.testing.allocator, &refresh)).?;
    std.testing.allocator.free(refreshed_user.name);
    std.testing.allocator.free(refreshed_user.safe_name);
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &refresh)) == null);
    const old_pair = try store.issueGameTokenPair(user_id, 60, 60, false);
    const current_pair = try store.issueGameTokenPair(user_id, 60, 60, false);
    try std.testing.expect(try store.revokeToken(&old_pair.access));
    try std.testing.expect((try store.consumeGameRefreshToken(std.testing.allocator, &old_pair.refresh)) == null);
    const current_pair_user = (try store.authenticateToken(std.testing.allocator, &current_pair.access, "identify")).?;
    std.testing.allocator.free(current_pair_user.name);
    std.testing.allocator.free(current_pair_user.safe_name);
    const rotated_pair = (try store.rotateGameTokenPair(std.testing.allocator, &current_pair.refresh, 60, 60)).?;
    std.testing.allocator.free(rotated_pair.user.name);
    std.testing.allocator.free(rotated_pair.user.safe_name);
    const rotated_pair_user = (try store.authenticateToken(std.testing.allocator, &rotated_pair.tokens.access, "identify")).?;
    std.testing.allocator.free(rotated_pair_user.name);
    std.testing.allocator.free(rotated_pair_user.safe_name);

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
    const replay = (try store.stableReplay(std.testing.allocator, score_id)).?;
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
    {
        var parsed_stable_website_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stable_website_board, .{});
        defer parsed_stable_website_board.deinit();
        const stable_website_score = parsed_stable_website_board.value.object.get("scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 1_000_000), stable_website_score.get("score_without_mods").?.integer);
        try std.testing.expectEqual(@as(i64, 1_000_000), stable_website_score.get("legacy_score").?.integer);
    }
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
    try std.testing.expectEqual(domain.RelationshipAddResult.inserted, try store.addFriend(user_id, outsider_id));
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
    {
        var parsed_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, site_profile, .{});
        defer parsed_profile.deinit();
        const selected = parsed_profile.value.object.get("selected_stats").?.object;
        const ranks = selected.get("rank_history").?.array.items;
        const pp_values = selected.get("pp_history").?.array.items;
        const days = selected.get("history_days").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), ranks.len);
        try std.testing.expectEqual(ranks.len, pp_values.len);
        try std.testing.expectEqual(ranks.len, days.len);
        try std.testing.expectEqual(selected.get("global_rank").?.integer, ranks[ranks.len - 1].integer);
        try std.testing.expectEqual(selected.get("pp").?.integer, pp_values[pp_values.len - 1].integer);
    }
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var user_id_buf: [24]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id});
        var inserted_history = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.user_stats_history(user_id,source,mode,day,pp,global_rank) VALUES($1,'all',0,((extract(epoch FROM clock_timestamp())::bigint/86400)-90)*86400,6,10),($1,'all',0,((extract(epoch FROM clock_timestamp())::bigint/86400)-89)*86400,7,9)", &.{user_id_text});
        defer inserted_history.deinit();
    }
    var history_score = score;
    history_score.online_checksum = "44444444444444444444444444444444";
    history_score.total_score = 700_000;
    _ = try store.insertStableScore(user_id, history_score, 10, "history replay", 12_000);
    const observed_history = try store.statsHistory(user_id, .all, 0);
    try std.testing.expectEqual(@as(usize, 2), observed_history.len);
    try std.testing.expectEqual(@as(i32, 7), observed_history.points[0].pp);
    try std.testing.expectEqual(@as(i32, 9), observed_history.points[0].global_rank);
    try std.testing.expectEqual(@as(i32, 27), observed_history.points[1].pp);
    try std.testing.expectEqual(@as(i32, 2), observed_history.points[1].global_rank);
    try std.testing.expectEqual(observed_history, try store.statsHistory(user_id, .all, 0));
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var pruned = try postgres.query(lease.conn, "SELECT count(*) FROM zigcho.user_stats_history WHERE day<((extract(epoch FROM clock_timestamp())::bigint/86400)-89)*86400");
        defer pruned.deinit();
        try std.testing.expectEqual(@as(i64, 0), try pruned.int(i64, 0, 0));
    }
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"artist\":\"artist\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"passed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"pinned_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"top_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"weight\":{\"percentage\":100.00,\"pp\":26.80}") != null);
    try std.testing.expect(std.mem.indexOf(u8, site_profile, "\"recent_scores\":[{") != null);
    {
        var user_id_buf: [24]u8 = undefined;
        const user_id_text = try std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var map_insert = try postgres.query(lease.conn, "INSERT INTO zigcho.beatmaps(id,set_id,md5,artist,title,version,creator,status,max_combo) VALUES(3,3,'33333333333333333333333333333333','first artist','first title','first diff','mapper',3,10)");
        map_insert.deinit();
        var first_insert = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES($1,'33333333333333333333333333333333',0,0,1234,1,1,10,10,0,0,0,0,0,true,true,'first-replay'::bytea,'vanilla',true)", &.{user_id_text});
        first_insert.deinit();
    }
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = false, .show_profile_stats = false, .show_recent_scores = false });
    try std.testing.expect(try store.recordReplayView(3, .stable, score_id));
    for ([_]domain.SiteScoreSource{ .all, .stable }) |private_source| {
        const private_site_rankings = try store.siteRankings(std.testing.allocator, private_source, 0, 0);
        defer std.testing.allocator.free(private_site_rankings);
        var parsed_private_site = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, private_site_rankings, .{});
        defer parsed_private_site.deinit();
        const private_site_players = parsed_private_site.value.object.get("players").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), private_site_players.len);
        try std.testing.expectEqual(@as(i64, outsider_id), private_site_players[0].object.get("id").?.integer);
        try std.testing.expectEqual(@as(i64, 1), private_site_players[0].object.get("rank").?.integer);
    }
    for ([_]lazer.RankingKind{ .performance, .score }) |private_kind| {
        const private_lazer_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, private_kind, null, 1);
        defer std.testing.allocator.free(private_lazer_rankings);
        var parsed_private_lazer = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, private_lazer_rankings, .{});
        defer parsed_private_lazer.deinit();
        const private_lazer_rows = parsed_private_lazer.value.object.get("ranking").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), private_lazer_rows.len);
        try std.testing.expectEqual(@as(i64, outsider_id), private_lazer_rows[0].object.get("user").?.object.get("id").?.integer);
        try std.testing.expectEqual(@as(i64, 1), private_lazer_rows[0].object.get("global_rank").?.integer);
        try std.testing.expectEqual(@as(i64, 0), private_lazer_rows[0].object.get("replays_watched_by_others").?.integer);
    }
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = true, .show_profile_stats = false, .show_recent_scores = false });
    const private_countries_json = try store.lazerRankingsJson(std.testing.allocator, 0, .country, null, 1);
    defer std.testing.allocator.free(private_countries_json);
    var private_countries = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, private_countries_json, .{});
    defer private_countries.deinit();
    const private_country_rows = private_countries.value.object.get("ranking").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), private_country_rows.len);
    try std.testing.expectEqualStrings("NZ", private_country_rows[0].object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 1), private_country_rows[0].object.get("active_users").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, private_countries_json, "\"code\":\"AU\"") == null);
    {
        var score_buf: [24]u8 = undefined;
        const score_text = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var remove_privacy_view = try postgres.queryParams(std.testing.allocator, lease.conn, "DELETE FROM zigcho.score_replay_views WHERE viewer_id=3 AND source='stable' AND score_id=$1", &.{score_text});
        remove_privacy_view.deinit();
    }
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = false, .show_profile_stats = false, .show_recent_scores = false });
    const hidden_lookup = (try store.userById(std.testing.allocator, user_id)).?;
    defer std.testing.allocator.free(hidden_lookup.name);
    defer std.testing.allocator.free(hidden_lookup.safe_name);
    try std.testing.expect(!hidden_lookup.show_country);
    const hidden_auth = (try store.authenticate(std.testing.allocator, "ari", "00000000000000000000000000000000")).?;
    defer std.testing.allocator.free(hidden_auth.name);
    defer std.testing.allocator.free(hidden_auth.safe_name);
    try std.testing.expect(!hidden_auth.show_country);
    const hidden_token = try store.issueToken(user_id, "web:account", 60);
    const hidden_token_user = (try store.authenticateToken(std.testing.allocator, &hidden_token, "web:account")).?;
    defer std.testing.allocator.free(hidden_token_user.name);
    defer std.testing.allocator.free(hidden_token_user.safe_name);
    try std.testing.expect(!hidden_token_user.show_country);
    const hidden_public_profile = (try store.siteProfile(std.testing.allocator, user_id, .all, 0)).?;
    defer std.testing.allocator.free(hidden_public_profile);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"country\":\"XX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"selected_stats\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"pinned_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"top_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"recent_scores\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"first_place_count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_public_profile, "\"first_place_scores\":[]") != null);
    const hidden_owner_profile = (try store.siteProfileForViewer(std.testing.allocator, user_id, .all, 0, true)).?;
    defer std.testing.allocator.free(hidden_owner_profile);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"country\":\"AU\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"selected_stats\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"pinned_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"top_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"recent_scores\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"first_place_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_owner_profile, "\"first_place_scores\":[{") != null);
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var first_delete = try postgres.query(lease.conn, "DELETE FROM zigcho.scores WHERE map_md5='33333333333333333333333333333333'");
        first_delete.deinit();
        var map_delete = try postgres.query(lease.conn, "DELETE FROM zigcho.beatmaps WHERE id=3");
        map_delete.deinit();
    }
    try store.updateSiteProfile(user_id, .{ .bio = "postgres profile", .title = "mapper", .pronouns = "they/them", .location = "adelaide", .website = "https://kai.ovh", .accent = .mint, .preferred_mode = 2, .profile_source = .lazer, .avatar_key = 2, .show_country = true, .show_profile_stats = true, .show_recent_scores = true });
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
    {
        var parsed_relax_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, relax_profile, .{});
        defer parsed_relax_profile.deinit();
        const selected = parsed_relax_profile.value.object.get("selected_stats").?.object;
        const pp_values = selected.get("pp_history").?.array.items;
        try std.testing.expectEqual(@as(i64, 43), selected.get("pp").?.integer);
        try std.testing.expectEqual(@as(usize, 1), pp_values.len);
        try std.testing.expectEqual(@as(i64, 43), pp_values[pp_values.len - 1].integer);
    }
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
    try store.upsertBeatmapSetMetadata(.{
        .set_id = 2,
        .favourites = 39,
        .submitted_date = "2026-08-20T00:00:00Z",
        .last_updated = "2026-08-22T05:45:08Z",
        .ranked_date = "2026-08-22T05:45:08Z",
        .has_video = false,
        .genre_id = 4,
        .language_id = 2,
    }, 1_787_456_000);
    try store.updateBeatmapUpstreamStats(2, 123, 45, 80);
    try std.testing.expect(try store.addFavourite(user_id, 2));
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
    {
        var parsed_local_set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_set, .{});
        defer parsed_local_set.deinit();
        try std.testing.expectEqual(@as(i64, 0), parsed_local_set.value.object.get("play_count").?.integer);
        try std.testing.expectEqual(@as(i64, 1), parsed_local_set.value.object.get("favourite_count").?.integer);
        const local_map = parsed_local_set.value.object.get("beatmaps").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 0), local_map.get("playcount").?.integer);
        try std.testing.expectEqual(@as(i64, 0), local_map.get("passcount").?.integer);
    }
    const lookup_by_id = (try store.lazerBeatmapLookup(std.testing.allocator, 2, null, null)).?;
    defer std.testing.allocator.free(lookup_by_id);
    const parsed_lookup_by_id = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup_by_id, .{});
    defer parsed_lookup_by_id.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup_by_id.value.object.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup_by_id.value.object.get("passcount").?.integer);
    const lookup_by_checksum = (try store.lazerBeatmapLookup(std.testing.allocator, null, second_md5, null)).?;
    defer std.testing.allocator.free(lookup_by_checksum);
    const parsed_lookup_by_checksum = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lookup_by_checksum, .{});
    defer parsed_lookup_by_checksum.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup_by_checksum.value.object.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed_lookup_by_checksum.value.object.get("passcount").?.integer);
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
    try std.testing.expect(std.mem.indexOf(u8, ordered_lazer_sets, "\"user\":null") == null);
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
    const consumed_lazer = (try store.consumedLazerScoreToken(user_id, 2, lazer_token)).?;
    try std.testing.expectEqual(lazer_score_id, consumed_lazer.score_id);
    try std.testing.expectEqual(lazer_input.total_score, consumed_lazer.total_score);
    try std.testing.expectEqual(lazer_input.accuracy, consumed_lazer.accuracy);
    try std.testing.expectEqual(@as(i32, @intCast(lazer_input.max_combo)), consumed_lazer.max_combo);
    try std.testing.expectEqual(lazer_input.passed, consumed_lazer.passed);
    try std.testing.expect((try store.consumedLazerScoreToken(user_id + 1, 2, lazer_token)) == null);
    const combined_stats = (try store.statsForUser(user_id, 0)).?;
    // The server derives Classic score from the submitted native score and
    // judgements; it never trusts the client-provided legacy_total_score.
    try std.testing.expectEqual(@as(i64, 3_600_123), combined_stats.total_score);
    try std.testing.expectEqual(@as(i64, 1_000_123), combined_stats.ranked_score);
    try std.testing.expectEqual(@as(i32, 6), combined_stats.plays);
    try std.testing.expectEqual(@as(i32, 25), combined_stats.max_combo);
    const most_played_json = try store.lazerMostPlayedJson(std.testing.allocator, user_id, user_id, 0, 50);
    defer std.testing.allocator.free(most_played_json);
    var parsed_most_played = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, most_played_json, .{});
    defer parsed_most_played.deinit();
    var found_local_map = false;
    for (parsed_most_played.value.array.items) |row_value| {
        const row = row_value.object;
        if (row.get("beatmap_id").?.integer != 2) continue;
        found_local_map = true;
        const nested_map = row.get("beatmap").?.object;
        try std.testing.expectEqual(@as(i64, 1), nested_map.get("playcount").?.integer);
        try std.testing.expectEqual(@as(i64, 1), nested_map.get("passcount").?.integer);
        const nested_set = row.get("beatmapset").?.object;
        try std.testing.expectEqual(@as(i64, 1), nested_set.get("play_count").?.integer);
        try std.testing.expectEqual(@as(i64, 1), nested_set.get("favourite_count").?.integer);
    }
    try std.testing.expect(found_local_map);
    const stored_lazer_replay = (try store.lazerReplay(std.testing.allocator, lazer_score_id)).?;
    defer std.testing.allocator.free(stored_lazer_replay);
    try std.testing.expectEqualSlices(u8, &lazer_replay, stored_lazer_replay);
    const lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, lazer_board, "\"has_replay\":true") != null);
    {
        var parsed_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_board, .{});
        defer parsed_board.deinit();
        const board_score = parsed_board.value.object.get("scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 1234), board_score.get("total_score").?.integer);
        try std.testing.expectEqual(@as(i64, 123), board_score.get("legacy_total_score").?.integer);
    }
    const lazer_score_detail = (try store.lazerScoreJson(std.testing.allocator, lazer_score_id, 2)).?;
    defer std.testing.allocator.free(lazer_score_detail);
    {
        var parsed_detail = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_score_detail, .{});
        defer parsed_detail.deinit();
        try std.testing.expectEqual(@as(i64, 1234), parsed_detail.value.object.get("total_score").?.integer);
        try std.testing.expectEqual(@as(i64, 123), parsed_detail.value.object.get("legacy_total_score").?.integer);
    }
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
    const missing_lazer_detail_json = (try store.lazerScoreJson(std.testing.allocator, lazer_score_id, 2)).?;
    defer std.testing.allocator.free(missing_lazer_detail_json);
    var missing_lazer_detail = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, missing_lazer_detail_json, .{});
    defer missing_lazer_detail.deinit();
    try std.testing.expect(!missing_lazer_detail.value.object.get("has_replay").?.bool);
    {
        var stable_id_buf: [24]u8 = undefined;
        var lazer_id_buf: [24]u8 = undefined;
        const stable_id_text = try std.fmt.bufPrint(&stable_id_buf, "{d}", .{score_id});
        const lazer_id_text = try std.fmt.bufPrint(&lazer_id_buf, "{d}", .{lazer_score_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var clear_stable = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.scores SET replay=NULL WHERE id=$1", &.{stable_id_text});
        clear_stable.deinit();
        var replay_objects = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.replay_objects(source,score_id,object_key,etag,object_bytes) VALUES('stable',$1::bigint,'replays/stable/postgres-'||$1::text,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',6),('lazer',$2::bigint,'replays/lazer/postgres-'||$2::text,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',32) ON CONFLICT(source,score_id) DO UPDATE SET object_key=excluded.object_key,etag=excluded.etag,object_bytes=excluded.object_bytes", &.{ stable_id_text, lazer_id_text });
        replay_objects.deinit();
    }
    const object_lazer_board = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(object_lazer_board);
    try std.testing.expect(std.mem.indexOf(u8, object_lazer_board, "\"has_replay\":true") != null);
    const object_lazer_detail_json = (try store.lazerScoreJson(std.testing.allocator, lazer_score_id, 2)).?;
    defer std.testing.allocator.free(object_lazer_detail_json);
    var object_lazer_detail = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_lazer_detail_json, .{});
    defer object_lazer_detail.deinit();
    try std.testing.expect(object_lazer_detail.value.object.get("has_replay").?.bool);
    const object_stable_board_json = (try store.siteBeatmapLeaderboard(std.testing.allocator, 1, .stable, 0)).?;
    defer std.testing.allocator.free(object_stable_board_json);
    var object_stable_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_stable_board_json, .{});
    defer object_stable_board.deinit();
    try std.testing.expect(object_stable_board.value.object.get("scores").?.array.items[0].object.get("has_replay").?.bool);
    const object_stable_scores_json = try store.lazerUserScoresJson(std.testing.allocator, user_id, 0, .recent, .stable, 0, 50);
    defer std.testing.allocator.free(object_stable_scores_json);
    var object_stable_scores = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_stable_scores_json, .{});
    defer object_stable_scores.deinit();
    try std.testing.expect(object_stable_scores.value.array.items[0].object.get("has_replay").?.bool);
    const object_stable_profile_json = (try store.siteProfile(std.testing.allocator, user_id, .stable, 0)).?;
    defer std.testing.allocator.free(object_stable_profile_json);
    var object_stable_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, object_stable_profile_json, .{});
    defer object_stable_profile.deinit();
    try std.testing.expect(object_stable_profile.value.object.get("recent_scores").?.array.items[0].object.get("has_replay").?.bool);
    const lazer_placement = (try store.lazerScoreLeaderboardPlacement(lazer_score_id)).?;
    try std.testing.expect(lazer_placement.submitted_is_best);
    try std.testing.expectEqual(@as(i32, 0), lazer_placement.rank);
    const lazer_rankings = try store.siteRankings(std.testing.allocator, .lazer, 0, 0);
    defer std.testing.allocator.free(lazer_rankings);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"name\":\"ari\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_rankings, "\"total_score\":123") != null);
    const stable_rankings = try store.siteRankings(std.testing.allocator, .stable, 0, 0);
    defer std.testing.allocator.free(stable_rankings);
    try std.testing.expect(std.mem.indexOf(u8, stable_rankings, "\"source\":\"stable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stable_rankings, "\"name\":\"ari\"") != null);
    const lazer_profile = (try store.siteProfile(std.testing.allocator, user_id, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_profile);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"stats_source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"selected_stats\":{\"ranked_score\":123,\"total_score\":123,\"pp\":0,\"plays\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_profile, "\"mods_json\":[]") != null);
    {
        var parsed_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_profile, .{});
        defer parsed_profile.deinit();
        const profile_score = parsed_profile.value.object.get("recent_scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 1234), profile_score.get("score").?.integer);
        try std.testing.expectEqual(@as(i64, 900), profile_score.get("score_without_mods").?.integer);
        try std.testing.expectEqual(@as(i64, 123), profile_score.get("legacy_score").?.integer);
        const first_place_score = parsed_profile.value.object.get("first_place_scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 900), first_place_score.get("score_without_mods").?.integer);
        try std.testing.expectEqual(@as(i64, 123), first_place_score.get("legacy_score").?.integer);
    }
    const lazer_website_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 2, .lazer, 0)).?;
    defer std.testing.allocator.free(lazer_website_board);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"source\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"client\":\"lazer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lazer_website_board, "\"client\":\"stable\"") == null);
    {
        var parsed_lazer_website_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lazer_website_board, .{});
        defer parsed_lazer_website_board.deinit();
        const lazer_website_score = parsed_lazer_website_board.value.object.get("scores").?.array.items[0].object;
        try std.testing.expectEqual(@as(i64, 1234), lazer_website_score.get("score").?.integer);
        try std.testing.expectEqual(@as(i64, 900), lazer_website_score.get("score_without_mods").?.integer);
        try std.testing.expectEqual(@as(i64, 123), lazer_website_score.get("legacy_score").?.integer);
    }
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
    const combined_site_board = (try store.siteBeatmapLeaderboard(std.testing.allocator, 2, .all, 0)).?;
    defer std.testing.allocator.free(combined_site_board);
    var parsed_combined_site_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, combined_site_board, .{});
    defer parsed_combined_site_board.deinit();
    const combined_site_score = parsed_combined_site_board.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqualStrings("stable", combined_site_score.get("client").?.string);
    try std.testing.expectEqual(@as(i64, 1100), combined_site_score.get("score").?.integer);
    try std.testing.expectEqual(@as(i64, 120), combined_site_score.get("pp").?.integer);
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var removed = try postgres.queryParams(std.testing.allocator, lease.conn, "DELETE FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND score=1100", &.{ user_text, second_md5 });
        removed.deinit();
    }
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,pp,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed,replay,rank_namespace,best) VALUES($1,$2,0,0,3000000000,500,0.99,300,300,0,0,0,0,0,true,true,'high-score-replay'::bytea,'vanilla',true)", &.{ user_text, second_md5 });
        inserted.deinit();
    }
    const high_recent_json = try store.lazerUserScoresJson(std.testing.allocator, user_id, 0, .recent, .stable, 0, 50);
    defer std.testing.allocator.free(high_recent_json);
    var high_recent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, high_recent_json, .{});
    defer high_recent.deinit();
    const high_recent_score = high_recent.value.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 3_000_000_000), high_recent_score.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)), high_recent_score.get("legacy_total_score").?.integer);
    const high_board_json = try store.lazerLeaderboardJson(std.testing.allocator, user_id, 2, 0, .vanilla, "[]", false, false, 0, .global, 50);
    defer std.testing.allocator.free(high_board_json);
    var high_board = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, high_board_json, .{});
    defer high_board.deinit();
    const high_board_score = high_board.value.object.get("scores").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 3_000_000_000), high_board_score.get("total_score").?.integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)), high_board_score.get("legacy_total_score").?.integer);
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var removed = try postgres.queryParams(std.testing.allocator, lease.conn, "DELETE FROM zigcho.scores WHERE user_id=$1 AND map_md5=$2 AND score=3000000000", &.{ user_text, second_md5 });
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
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,pp,best) VALUES($1,2,0,500,500,NULL,0.95,50,true,'A','[{\"acronym\":\"HR\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'vanilla',150,false) RETURNING id", &.{user_text});
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
    const native_profile_json = (try store.siteProfile(std.testing.allocator, user_id, .lazer, 0)).?;
    defer std.testing.allocator.free(native_profile_json);
    var native_profile = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, native_profile_json, .{});
    defer native_profile.deinit();
    const native_recent = native_profile.value.object.get("recent_scores").?.array.items[0].object;
    try std.testing.expectEqual(hard_rock_id, native_recent.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 500), native_recent.get("score_without_mods").?.integer);
    try std.testing.expect(std.meta.activeTag(native_recent.get("legacy_score").?) == .null);
    var custom_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user_text = try std.fmt.bufPrint(&user_buf, "{d}", .{user_id});
        var lease = store.pool.acquire();
        defer lease.release();
        var inserted = try postgres.queryParams(std.testing.allocator, lease.conn, "INSERT INTO zigcho.lazer_scores(user_id,beatmap_id,ruleset_id,total_score,total_score_without_mods,legacy_total_score,accuracy,max_combo,passed,rank,mods_json,statistics_json,maximum_statistics_json,pauses_json,rank_namespace,pp,best) VALUES($1,2,0,600,600,NULL,0.95,60,true,'A','[{\"acronym\":\"RX\"},{\"acronym\":\"WIGGLE\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'custom',60,true),($1,2,0,800,800,NULL,0.98,80,true,'A','[{\"acronym\":\"WIGGLE\"},{\"acronym\":\"HR\"}]'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'custom',80,false) RETURNING id", &.{user_text});
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
    const stored_direct_id = try store.storeDirectMessage(second_id, user_id, "postgres offline hello");
    const initial_dm_feed = try store.lazerAllMessagesJson(std.testing.allocator, user_id, 0, 100);
    defer std.testing.allocator.free(initial_dm_feed);
    const parsed_dm_feed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, initial_dm_feed, .{});
    defer parsed_dm_feed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed_dm_feed.value.array.items.len);
    const dm_message_id = parsed_dm_feed.value.array.items[0].object.get("message_id").?.integer;
    const unread = try store.unreadDirectMessages(std.testing.allocator, user_id);
    defer {
        for (unread) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(unread);
    }
    try std.testing.expectEqual(@as(usize, 1), unread.len);
    try std.testing.expectEqualStrings("raya", unread[0].from_name);
    try std.testing.expectEqual(stored_direct_id, unread[0].id);
    try std.testing.expect(try store.markDirectMessageRead(user_id, stored_direct_id));
    try std.testing.expect(!try store.markDirectMessageRead(user_id, stored_direct_id));
    try store.markLazerDirectMessageRead(user_id, second_id, dm_message_id);
    const cleared_dm_feed = try store.lazerAllMessagesJson(std.testing.allocator, user_id, 0, 100);
    defer std.testing.allocator.free(cleared_dm_feed);
    try std.testing.expectEqualStrings("[]", cleared_dm_feed);
    const dm_threads = try store.directMessageThreadsJson(std.testing.allocator, user_id, 50);
    defer std.testing.allocator.free(dm_threads);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"name\":\"raya\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"last_message\":\"postgres offline hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dm_threads, "\"unread\":0") != null);
    const initial_friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(initial_friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, initial_friends, 3) != null);
    try std.testing.expectEqual(domain.RelationshipAddResult.inserted, try store.addFriend(user_id, second_id));
    try std.testing.expectEqual(domain.RelationshipAddResult.existing, try store.addFriend(user_id, second_id));
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerProfileSummary(second_id)).?.follower_count);
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerBatchUserVisibility(second_id)).?.follower_count);
    const followed_user = (try store.userById(std.testing.allocator, second_id)).?;
    defer std.testing.allocator.free(followed_user.name);
    defer std.testing.allocator.free(followed_user.safe_name);
    try std.testing.expectEqual(@as(i32, 1), followed_user.follower_count);
    var compact_user: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer compact_user.deinit();
    try user_json.writeCompact(&compact_user.writer, followed_user, followed_user.show_country);
    var parsed_compact_user = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, compact_user.written(), .{});
    defer parsed_compact_user.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed_compact_user.value.object.get("follower_count").?.integer);
    const friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, friends, 3) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, friends, second_id) != null);
    const reverse_friends = try store.friendIds(std.testing.allocator, second_id);
    defer std.testing.allocator.free(reverse_friends);
    try std.testing.expect(std.mem.indexOfScalar(i32, reverse_friends, user_id) == null);
    var relationship_buffers: [2][24]u8 = undefined;
    const relationship_user = try std.fmt.bufPrint(&relationship_buffers[0], "{d}", .{user_id});
    const relationship_target = try std.fmt.bufPrint(&relationship_buffers[1], "{d}", .{second_id});
    {
        var relationship_lease = store.pool.acquire();
        defer relationship_lease.release();
        var restrict_sender = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "UPDATE zigcho.users SET restricted=true WHERE id=$1 RETURNING id,restricted::int", &.{relationship_user});
        try std.testing.expectEqual(@as(usize, 1), restrict_sender.rows());
        try std.testing.expectEqual(user_id, try restrict_sender.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 1), try restrict_sender.int(i32, 0, 1));
        restrict_sender.deinit();
    }
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerProfileSummary(second_id)).?.follower_count);
    const restricted_sender_friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(restricted_sender_friends);
    try std.testing.expectEqualSlices(i32, &.{3}, restricted_sender_friends);
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, second_id));
    {
        var relationship_lease = store.pool.acquire();
        defer relationship_lease.release();
        var unrestrict_sender = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "UPDATE zigcho.users SET restricted=false WHERE id=$1 RETURNING id,restricted::int", &.{relationship_user});
        try std.testing.expectEqual(@as(usize, 1), unrestrict_sender.rows());
        try std.testing.expectEqual(user_id, try unrestrict_sender.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 0), try unrestrict_sender.int(i32, 0, 1));
        unrestrict_sender.deinit();
        var restrict_target = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "UPDATE zigcho.users SET restricted=true WHERE id=$1 RETURNING id,restricted::int", &.{relationship_target});
        try std.testing.expectEqual(@as(usize, 1), restrict_target.rows());
        try std.testing.expectEqual(second_id, try restrict_target.int(i32, 0, 0));
        try std.testing.expectEqual(@as(i32, 1), try restrict_target.int(i32, 0, 1));
        restrict_target.deinit();
        var restricted_state = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "SELECT restricted::int FROM zigcho.users WHERE id=$1", &.{relationship_target});
        defer restricted_state.deinit();
        try std.testing.expectEqual(@as(i32, 1), try restricted_state.int(i32, 0, 0));
        try std.testing.expect(postgres.c.PQtransactionStatus(relationship_lease.conn) == postgres.c.PQTRANS_IDLE);
    }
    const restricted_target_friends = try store.friendIds(std.testing.allocator, user_id);
    defer std.testing.allocator.free(restricted_target_friends);
    try std.testing.expectEqual(@as(usize, 2), restricted_target_friends.len);
    try std.testing.expect(std.mem.indexOfScalar(i32, restricted_target_friends, outsider_id) != null);
    try std.testing.expect(std.mem.indexOfScalar(i32, restricted_target_friends, second_id) == null);
    try std.testing.expect(std.mem.indexOfScalar(i32, restricted_target_friends, 3) != null);
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, second_id));
    {
        var relationship_lease = store.pool.acquire();
        defer relationship_lease.release();
        var unrestrict = try postgres.queryParams(std.testing.allocator, relationship_lease.conn, "UPDATE zigcho.users SET restricted=false WHERE id IN($1,$2)", &.{ relationship_user, relationship_target });
        unrestrict.deinit();
    }
    try std.testing.expectEqual(@as(i32, 1), (try store.lazerProfileSummary(second_id)).?.follower_count);
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, user_id));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, 3));
    try std.testing.expectEqual(domain.RelationshipAddResult.ineligible, try store.addFriend(user_id, 2_000_000_000));
    try std.testing.expect(try store.removeFriend(user_id, second_id));
    try std.testing.expect(!try store.removeFriend(user_id, second_id));
    try std.testing.expectEqual(@as(i32, 0), (try store.lazerProfileSummary(second_id)).?.follower_count);
    try std.testing.expect(try store.recordReplayView(second_id, .stable, score_id));
    try std.testing.expect(try store.recordReplayView(second_id, .lazer, lazer_score_id));
    try std.testing.expectEqual(@as(i32, 2), try store.replayViewCount(user_id, .all, 0));
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(user_id, .stable, 0));
    try std.testing.expectEqual(@as(i32, 1), try store.replayViewCount(user_id, .lazer, 0));
    try std.testing.expectEqual(@as(i32, 2), (try store.statsForUser(user_id, 0)).?.replay_views);
    {
        var replay_history_lease = store.pool.acquire();
        defer replay_history_lease.release();
        var set_replay_months = try postgres.queryParams(
            std.testing.allocator,
            replay_history_lease.conn,
            "UPDATE zigcho.score_replay_views SET viewed_at=CASE source WHEN 'stable' THEN extract(epoch FROM timestamptz '2026-07-15 00:00:00+00')::bigint ELSE extract(epoch FROM timestamptz '2026-08-15 00:00:00+00')::bigint END WHERE owner_id=$1 RETURNING source",
            &.{relationship_user},
        );
        defer set_replay_months.deinit();
        try std.testing.expectEqual(@as(usize, 2), set_replay_months.rows());
    }
    const replay_watch_history = try store.lazerReplaysWatchedCountsJson(std.testing.allocator, user_id, 0);
    defer std.testing.allocator.free(replay_watch_history);
    var parsed_replay_watch_history = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, replay_watch_history, .{});
    defer parsed_replay_watch_history.deinit();
    const replay_watch_months = parsed_replay_watch_history.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), replay_watch_months.len);
    try std.testing.expectEqualStrings("2026-07-01", replay_watch_months[0].object.get("start_date").?.string);
    try std.testing.expectEqual(@as(i64, 1), replay_watch_months[0].object.get("count").?.integer);
    try std.testing.expectEqualStrings("2026-08-01", replay_watch_months[1].object.get("start_date").?.string);
    try std.testing.expectEqual(@as(i64, 1), replay_watch_months[1].object.get("count").?.integer);
    const empty_replay_watch_history = try store.lazerReplaysWatchedCountsJson(std.testing.allocator, user_id, 1);
    defer std.testing.allocator.free(empty_replay_watch_history);
    try std.testing.expectEqualStrings("[]", empty_replay_watch_history);
    try std.testing.expectError(error.InvalidRulesetId, store.lazerReplaysWatchedCountsJson(std.testing.allocator, user_id, 4));
    const replay_rankings = try store.lazerRankingsJson(std.testing.allocator, 0, .performance, null, 1);
    defer std.testing.allocator.free(replay_rankings);
    try std.testing.expect(std.mem.indexOf(u8, replay_rankings, "\"replays_watched_by_others\":2") != null);
    try std.testing.expect(try store.recordReplayView(second_id, .stable, score_id));
    try std.testing.expect(!try store.recordReplayView(user_id, .stable, score_id));
    try std.testing.expectEqual(@as(i32, 2), try store.replayViewCount(user_id, .all, 0));
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
        .osu_path_md5 = "acacacacacacacacacacacacacacacac",
        .adapters_md5 = "bdbdbdbdbdbdbdbdbdbdbdbdbdbdbdbd",
        .uninstall_md5 = "cececececececececececececececece",
        .disk_signature_md5 = "dfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdf",
        .client_version = "b20260811",
        .running_under_wine = false,
        .actionable = true,
    };
    var first_hardware = try store.recordClientHardware(user_id, hardware);
    defer first_hardware.deinit();
    try std.testing.expectEqual(@as(usize, 0), first_hardware.matched_user_ids.len);
    var second_hardware = try store.recordClientHardware(second_id, hardware);
    defer second_hardware.deinit();
    try std.testing.expectEqual(user_id, second_hardware.matched_user_ids[0]);
    const observed_first = (try store.userById(std.testing.allocator, user_id)).?;
    defer {
        std.testing.allocator.free(observed_first.name);
        std.testing.allocator.free(observed_first.safe_name);
    }
    const observed_second = (try store.userById(std.testing.allocator, second_id)).?;
    defer {
        std.testing.allocator.free(observed_second.name);
        std.testing.allocator.free(observed_second.safe_name);
    }
    try std.testing.expect(!observed_first.restricted);
    try std.testing.expect(!observed_second.restricted);
    {
        var first_target_buf: [32]u8 = undefined;
        var second_target_buf: [32]u8 = undefined;
        const first_target = try std.fmt.bufPrint(&first_target_buf, "user:{d}", .{user_id});
        const second_target = try std.fmt.bufPrint(&second_target_buf, "user:{d}", .{second_id});
        var hardware_lease = store.pool.acquire();
        defer hardware_lease.release();
        var hardware_audit = try postgres.queryParams(std.testing.allocator, hardware_lease.conn, "SELECT count(*) FROM zigcho.audit_log WHERE action='anticheat.hardware_match' AND target IN($1,$2)", &.{ first_target, second_target });
        defer hardware_audit.deinit();
        try std.testing.expectEqual(@as(i64, 2), try hardware_audit.int(i64, 0, 0));
    }
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
    try std.testing.expect((try store.stableReplay(std.testing.allocator, failed_stable_id)) == null);
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

test "postgres custom lazer plays update local map counters without touching player stats" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const user_id = try store.register("pg custom counter", "pg-custom-counter@example.test", "22222222222222222222222222222222");
    const map_md5 = "90909090909090909090909090909090";
    try store.upsertBeatmapMeta(.{
        .id = 2_000_000_101,
        .set_id = 2_000_000_100,
        .artist = "postgres counter artist",
        .title = "postgres counter title",
        .version = "postgres counter difficulty",
        .creator = "postgres counter mapper",
        .total_length = 120,
    }, map_md5, 3, 4.5, 500);

    const raw = "{\"beatmap_id\":2000000101,\"ruleset_id\":0,\"total_score\":123456,\"accuracy\":0.8,\"max_combo\":40,\"passed\":false,\"rank\":\"F\",\"mods\":[{\"acronym\":\"WIGGLE\"}],\"statistics\":{\"great\":4,\"miss\":1}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const mods_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "mods", "[]");
    defer std.testing.allocator.free(mods_json);
    const statistics_json = try lazer.jsonField(std.testing.allocator, parsed.value.object, "statistics", "{}");
    defer std.testing.allocator.free(statistics_json);
    const failed_input = try lazer.parseScore(parsed.value);
    try std.testing.expectEqual(lazer.Namespace.custom, failed_input.namespace);
    try std.testing.expect(lazer.statsMode(failed_input) == null);
    const stats_before = (try store.statsForUser(user_id, 0)).?;

    _ = try store.insertLazerScore(user_id, failed_input, 0, mods_json, statistics_json, "{}", "[]", &.{});
    const after_fail = (try store.beatmapForScore(map_md5)).?;
    try std.testing.expectEqual(@as(i32, 1), after_fail.plays);
    try std.testing.expectEqual(@as(i32, 0), after_fail.passes);

    var passed_input = failed_input;
    passed_input.passed = true;
    passed_input.rank = "A";
    passed_input.total_score = 654_321;
    _ = try store.insertLazerScore(user_id, passed_input, 999, mods_json, statistics_json, "{}", "[]", &.{});
    const after_pass = (try store.beatmapForScore(map_md5)).?;
    try std.testing.expectEqual(@as(i32, 2), after_pass.plays);
    try std.testing.expectEqual(@as(i32, 1), after_pass.passes);
    try std.testing.expectEqualDeep(stats_before, (try store.statsForUser(user_id, 0)).?);

    const set_json = (try store.lazerBeatmapSet(std.testing.allocator, 2_000_000_100, null)).?;
    defer std.testing.allocator.free(set_json);
    var set = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, set_json, .{});
    defer set.deinit();
    try std.testing.expectEqual(@as(i64, 2), set.value.object.get("play_count").?.integer);
    const map = set.value.object.get("beatmaps").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 2), map.get("playcount").?.integer);
    try std.testing.expectEqual(@as(i64, 1), map.get("passcount").?.integer);
}

test "postgres unbound room score tokens can be discarded" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const user_id = try store.register("pg room token owner", "pg-room-token-owner@example.test", "44444444444444444444444444444444");
    const map_md5 = "91919191919191919191919191919191";
    try store.upsertBeatmapMeta(.{ .id = 2_000_000_111, .set_id = 2_000_000_110, .artist = "pg token artist", .title = "pg token title", .version = "pg token difficulty", .creator = "pg token mapper" }, map_md5, 3, 4, 100);
    const room_token = try store.createLazerRoomScoreToken(user_id, 2_000_000_111, map_md5, 0, "55555555555555555555555555555555");
    try std.testing.expect(Store.isLazerRoomScoreToken(room_token));
    try std.testing.expect(try store.discardUnusedLazerRoomScoreToken(user_id, room_token));
    try std.testing.expect(!try store.discardUnusedLazerRoomScoreToken(user_id, room_token));
}

test "postgres staff announcements persist chat and audit atomically" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const actor_id = try store.register("pg announce admin", "pg-announce-admin@example.test", "33333333333333333333333333333333");
    try store.recordStaffAnnouncement(actor_id, "postgres server is back", "postgres maintenance finished");
    var actor_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var committed = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT (SELECT count(*) FROM zigcho.chat_messages WHERE sender_id=3 AND target='#announce' AND message='postgres server is back'),(SELECT count(*) FROM zigcho.audit_log WHERE actor_id=$1 AND action='infra.announcement' AND target='server' AND detail='postgres maintenance finished')", &.{actor});
        defer committed.deinit();
        try std.testing.expectEqual(@as(i64, 1), try committed.int(i64, 0, 0));
        try std.testing.expectEqual(@as(i64, 1), try committed.int(i64, 0, 1));
    }
}

test "postgres credential and restriction commits revoke matching token families" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();

    const password_id = try store.register("pg password target", "pg-password-target@example.test", "00000000000000000000000000000000");
    const password_game = try store.issueGameTokenPair(password_id, 60, 60, false);
    const password_web = try store.issueToken(password_id, "web:account", 60);
    try store.updateAccountPassword(password_id, "11111111111111111111111111111111");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_game.refresh, "")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &password_web, "web:account")) == null);

    const username_id = try store.register("pg username target", "pg-username-target@example.test", "00000000000000000000000000000000");
    const username_game = try store.issueGameTokenPair(username_id, 60, 60, false);
    const username_web = try store.issueToken(username_id, "web:account", 60);
    try store.updateAccountUsername(username_id, "pg renamed target");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_game.refresh, "")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &username_web, "web:account")) == null);

    const restricted_id = try store.register("pg restricted target", "pg-restricted-target@example.test", "00000000000000000000000000000000");
    const restricted_game = try store.issueGameTokenPair(restricted_id, 60, 60, false);
    const restricted_web = try store.issueToken(restricted_id, "web:account", 60);
    try store.setRestricted(password_id, restricted_id, true, "postgres token transition fixture");
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &restricted_game.access, "identify")) == null);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &restricted_game.refresh, "")) == null);
    const appeal_session = (try store.authenticateToken(std.testing.allocator, &restricted_web, "web:account")).?;
    defer {
        std.testing.allocator.free(appeal_session.name);
        std.testing.allocator.free(appeal_session.safe_name);
    }
}

test "postgres developer role changes preserve unrelated bits and revoke final staff sessions" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const actor_id = try store.register("pg role developer", "pg-role-developer@example.test", "44444444444444444444444444444444");
    const target_id = try store.register("pg role target", "pg-role-target@example.test", "55555555555555555555555555555555");
    var actor_buf: [24]u8 = undefined;
    var target_buf: [24]u8 = undefined;
    const actor = try std.fmt.bufPrint(&actor_buf, "{d}", .{actor_id});
    const target = try std.fmt.bufPrint(&target_buf, "{d}", .{target_id});
    {
        var lease = store.pool.acquire();
        defer lease.release();
        var roles = try postgres.queryParams(std.testing.allocator, lease.conn, "UPDATE zigcho.users SET privileges=CASE id WHEN $1 THEN 16387 ELSE 4115 END WHERE id IN($1,$2) RETURNING id", &.{ actor, target });
        defer roles.deinit();
        try std.testing.expectEqual(@as(usize, 2), roles.rows());
    }
    const staff_token = try store.issueToken(target_id, "web:staff", 3600);
    const premium = try store.changeRole(actor_id, target_id, .premium, true, "postgres permanent premium grant");
    try std.testing.expectEqual(@as(u32, 4147), premium.privileges);
    try std.testing.expect(!premium.staff_sessions_revoked);
    try std.testing.expectError(error.InvalidRoleChange, store.changePrivileges(actor_id, target_id, 3, false));
    try std.testing.expectError(error.InvalidRoleChange, store.changePrivileges(actor_id, target_id, (1 << 4) | (1 << 5), false));
    const admin = try store.changeRole(actor_id, target_id, .administrator, true, "postgres move onto admin access");
    try std.testing.expectEqual(@as(u32, 12_339), admin.privileges);
    const downgraded = try store.changeRole(actor_id, target_id, .moderator, false, "postgres moderation role replaced");
    try std.testing.expectEqual(@as(u32, 8_243), downgraded.privileges);
    try std.testing.expect(!downgraded.staff_sessions_revoked);
    const refreshed = (try store.authenticateToken(std.testing.allocator, &staff_token, "web:staff")).?;
    defer {
        std.testing.allocator.free(refreshed.name);
        std.testing.allocator.free(refreshed.safe_name);
    }
    try std.testing.expect(refreshed.privileges & (1 << 13) != 0);
    try std.testing.expect(refreshed.privileges & (1 << 12) == 0);
    const removed = try store.changeRole(actor_id, target_id, .administrator, false, "postgres admin access ended");
    try std.testing.expectEqual(@as(u32, 51), removed.privileges);
    try std.testing.expect(removed.staff_sessions_revoked);
    try std.testing.expect((try store.authenticateToken(std.testing.allocator, &staff_token, "web:staff")) == null);
    const roles_json = (try store.staffRolesJson(std.testing.allocator, target_id)).?;
    defer std.testing.allocator.free(roles_json);
    try std.testing.expect(std.mem.indexOf(u8, roles_json, "\"key\":\"premium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, roles_json, "permanent premium grant") != null);
}

test "postgres anticheat hardware and flags stay review only" {
    const raw_conninfo = std.c.getenv("ZIGCHO_TEST_POSTGRES_STORE_URL") orelse return error.SkipZigTest;
    var store = try Store.open(std.testing.allocator, std.testing.io, std.mem.span(raw_conninfo));
    defer store.close();
    try store.migrate();
    const first_id = try store.register("pg ac first", "pg-ac-first@example.test", "00000000000000000000000000000000");
    const second_id = try store.register("pg ac second", "pg-ac-second@example.test", "11111111111111111111111111111111");
    const hardware: ClientHardware = .{
        .osu_path_md5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .adapters_md5 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .uninstall_md5 = "cccccccccccccccccccccccccccccccc",
        .disk_signature_md5 = "dddddddddddddddddddddddddddddddd",
        .client_version = "b20260826",
        .running_under_wine = false,
        .actionable = true,
    };
    var first = try store.recordClientHardware(first_id, hardware);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.matched_user_ids.len);
    var second = try store.recordClientHardware(second_id, hardware);
    defer second.deinit();
    try std.testing.expectEqualSlices(i32, &.{first_id}, second.matched_user_ids);
    var second_again = try store.recordClientHardware(second_id, hardware);
    defer second_again.deinit();
    try std.testing.expectEqualSlices(i32, &.{first_id}, second_again.matched_user_ids);

    const hq_flags: u32 = (@as(u32, 1) << 17) | (@as(u32, 1) << 18);
    try store.recordLastFmFlag(second_id, hq_flags);
    try store.recordLastFmFlag(second_id, hq_flags);
    const observation = anticheat_evidence.stableLastFm(hq_flags).?;
    const observation_id = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
    });
    try std.testing.expectEqual(observation_id, try store.recordAnticheatObservation(second_id, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
    }));
    const distinct_observation_id = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
        .movement_velocity_stddev_milli = 1,
    });
    try std.testing.expect(distinct_observation_id != observation_id);

    var score_id: i64 = 0;
    {
        var user_buf: [24]u8 = undefined;
        const user = try std.fmt.bufPrint(&user_buf, "{d}", .{second_id});
        var score_lease = store.pool.acquire();
        defer score_lease.release();
        var score = try postgres.queryParams(std.testing.allocator, score_lease.conn, "INSERT INTO zigcho.scores(user_id,map_md5,mode,mods,score,accuracy,max_combo,n300,n100,n50,nmiss,ngeki,nkatu,perfect,passed) VALUES($1,'abababababababababababababababab',0,0,123456,0.98,100,100,0,0,0,0,0,true,true) RETURNING id", &.{user});
        defer score.deinit();
        score_id = try score.int(i64, 0, 0);
    }
    const score_observation_id = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .score_id = score_id,
        .action = 1,
        .reason = 1001,
        .risk_score = 300,
        .confidence_bps = 8000,
        .evidence = 8,
    });
    const rejected_score_observation = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .action = 1,
        .reason = 2006,
        .risk_score = 200,
        .confidence_bps = 10_000,
        .evidence = 16,
    });
    try std.testing.expectEqual(rejected_score_observation, try store.recordAnticheatObservation(second_id, .{
        .source = .stable_score,
        .module = anticheat_evidence.module_name,
        .action = 1,
        .reason = 2006,
        .risk_score = 200,
        .confidence_bps = 10_000,
        .evidence = 16,
    }));
    try store.reviewAnticheatObservation(first_id, score_observation_id, .uncertain, "retain postgres score evidence");
    {
        var score_buf: [24]u8 = undefined;
        var observation_buf: [24]u8 = undefined;
        const score = try std.fmt.bufPrint(&score_buf, "{d}", .{score_id});
        const score_observation = try std.fmt.bufPrint(&observation_buf, "{d}", .{score_observation_id});
        var retention_lease = store.pool.acquire();
        defer retention_lease.release();
        var aged = try postgres.queryParams(std.testing.allocator, retention_lease.conn, "UPDATE zigcho.anticheat_observations SET created_at=1,reviewed_at=1 WHERE id=$1", &.{score_observation});
        aged.deinit();
        var deleted_score = try postgres.queryParams(std.testing.allocator, retention_lease.conn, "DELETE FROM zigcho.scores WHERE id=$1", &.{score});
        deleted_score.deinit();
    }
    _ = try store.recordAnticheatObservation(second_id, .{
        .source = .stable_lastfm,
        .module = anticheat_evidence.module_name,
        .action = observation.action,
        .reason = observation.reason + 1,
        .risk_score = observation.risk_score,
        .confidence_bps = observation.confidence_bps,
        .evidence = observation.evidence,
        .decision_flags = observation.decision_flags,
        .rule_revision = observation.rule_revision,
    });
    const first_user = (try store.userById(std.testing.allocator, first_id)).?;
    defer {
        std.testing.allocator.free(first_user.name);
        std.testing.allocator.free(first_user.safe_name);
    }
    const second_user = (try store.userById(std.testing.allocator, second_id)).?;
    defer {
        std.testing.allocator.free(second_user.name);
        std.testing.allocator.free(second_user.safe_name);
    }
    try std.testing.expect(!first_user.restricted);
    try std.testing.expect(!second_user.restricted);
    const review = try store.staffAnticheatJson(std.testing.allocator);
    defer std.testing.allocator.free(review);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"module\":\"zigcho-host\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"source\":\"stable_lastfm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "\"display\":\"required replay missing (2006)\"") != null);
    var first_target_buf: [32]u8 = undefined;
    var second_target_buf: [32]u8 = undefined;
    const first_target = try std.fmt.bufPrint(&first_target_buf, "user:{d}", .{first_id});
    const second_target = try std.fmt.bufPrint(&second_target_buf, "user:{d}", .{second_id});
    var lease = store.pool.acquire();
    defer lease.release();
    var score_observation_buf: [24]u8 = undefined;
    const score_observation = try std.fmt.bufPrint(&score_observation_buf, "{d}", .{score_observation_id});
    var audit = try postgres.queryParams(std.testing.allocator, lease.conn, "SELECT (SELECT count(*) FROM zigcho.audit_log WHERE action='anticheat.hardware_match' AND target IN($1,$2)),(SELECT count(*) FROM zigcho.audit_log WHERE action='stable.lastfm_flag' AND target=$2),(SELECT count(*) FROM zigcho.anticheat_observations WHERE id=$3 AND source='stable_score')", &.{ first_target, second_target, score_observation });
    defer audit.deinit();
    try std.testing.expectEqual(@as(i64, 2), try audit.int(i64, 0, 0));
    try std.testing.expectEqual(@as(i64, 1), try audit.int(i64, 0, 1));
    try std.testing.expectEqual(@as(i64, 1), try audit.int(i64, 0, 2));
}
