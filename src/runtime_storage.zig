const options = @import("build_options");
const sqlite = @import("storage.zig");
const backend = if (options.postgres_runtime) @import("postgres_store.zig") else sqlite;

pub const Store = backend.Store;
pub const ClientHardware = backend.ClientHardware;
pub const HardwareEvidence = backend.HardwareEvidence;
pub const AnticheatSource = backend.AnticheatSource;
pub const AnticheatExclusionScope = backend.AnticheatExclusionScope;
pub const anticheat_exclusion_min_seconds = backend.anticheat_exclusion_min_seconds;
pub const anticheat_exclusion_max_seconds = backend.anticheat_exclusion_max_seconds;
pub const AnticheatReviewLabel = backend.AnticheatReviewLabel;
pub const AnticheatObservation = backend.AnticheatObservation;
pub const LazerCommentable = backend.LazerCommentable;
pub const LazerCommentTarget = backend.LazerCommentTarget;
pub const LazerCommentSort = backend.LazerCommentSort;
pub const ReplaySource = backend.ReplaySource;
pub const UpstreamUserCache = backend.UpstreamUserCache;
pub const BeatmapSetCreator = backend.BeatmapSetCreator;
pub const is_postgres = backend.is_postgres;
pub const schema_version = backend.schema_version;

// PostgreSQL is the production server backend. SQLite remains available only
// for local fixtures, import/recalc tools and explicit legacy builds.
pub const c = sqlite.c;
