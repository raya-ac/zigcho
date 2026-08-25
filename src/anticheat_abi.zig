pub const version: u32 = 1;

pub const Status = struct {
    pub const ok: u32 = 0;
    pub const null_event: u32 = 1;
    pub const null_decision: u32 = 2;
    pub const unsupported_version: u32 = 3;
    pub const event_too_small: u32 = 4;
    pub const invalid_gameplay_data: u32 = 5;
    pub const invalid_event_data: u32 = 6;
};

pub const EventKind = struct {
    pub const login: u32 = 1;
    pub const score: u32 = 2;
    pub const heartbeat: u32 = 3;
};

pub const ClientFamily = struct {
    pub const stable: u32 = 1;
    pub const lazer: u32 = 2;
};

pub const Namespace = struct {
    pub const vanilla: u32 = 1;
    pub const relax: u32 = 2;
    pub const autopilot: u32 = 3;
    pub const score_v2: u32 = 4;
    pub const custom: u32 = 5;
};

pub const EventFlag = struct {
    pub const passed: u64 = 1 << 0;
    pub const replay_required: u64 = 1 << 1;
    pub const known_mask: u64 = passed | replay_required;
};

pub const Evidence = struct {
    pub const exact_hardware_match: u64 = 1 << 0;
    pub const high_confidence_client_flag: u64 = 1 << 1;
    pub const registry_remnant: u64 = 1 << 2;
    pub const running_under_wine: u64 = 1 << 3;
    pub const required_replay_missing: u64 = 1 << 4;
    pub const replay_hash_reused: u64 = 1 << 5;
    pub const impossible_hit_totals: u64 = 1 << 6;
    pub const impossible_accuracy: u64 = 1 << 7;
    pub const impossible_combo: u64 = 1 << 8;
    pub const timing_outlier: u64 = 1 << 9;
    pub const pp_outlier: u64 = 1 << 10;
    pub const client_integrity_mismatch: u64 = 1 << 11;
    pub const known_cheat_signature: u64 = 1 << 12;
    pub const multiaccount_cluster: u64 = 1 << 13;
    pub const duplicate_score: u64 = 1 << 14;
    pub const checksum_mismatch: u64 = 1 << 15;
    pub const rate_anomaly: u64 = 1 << 16;
    pub const known_mask: u64 = (1 << 17) - 1;
};

pub const Action = struct {
    pub const allow: u32 = 0;
    pub const audit: u32 = 1;
    pub const challenge: u32 = 2;
    pub const restrict: u32 = 3;
};

pub const Reason = struct {
    pub const none: u32 = 0;
    pub const known_cheat_signature: u32 = 1001;
    pub const client_integrity_mismatch: u32 = 1002;
    pub const high_confidence_client_flag: u32 = 1003;
    pub const exact_hardware_match: u32 = 1004;
    pub const impossible_accuracy: u32 = 2001;
    pub const impossible_hit_totals: u32 = 2002;
    pub const impossible_combo: u32 = 2003;
    pub const checksum_mismatch: u32 = 2004;
    pub const replay_hash_reused: u32 = 2005;
    pub const required_replay_missing: u32 = 2006;
    pub const combined_anomalies: u32 = 2007;
    pub const invalid_replay_payload: u32 = 2008;
    pub const timing_outlier: u32 = 3001;
    pub const pp_outlier: u32 = 3002;
    pub const multiaccount_cluster: u32 = 3003;
    pub const rate_anomaly: u32 = 3004;
    pub const registry_remnant: u32 = 3005;
    pub const duplicate_score: u32 = 3006;
    pub const relax_keyless_play: u32 = 4001;
    pub const relax_timing_lock: u32 = 4002;
    pub const relax_hold_lock: u32 = 4003;
    pub const relax_alternation_lock: u32 = 4004;
    pub const aim_center_lock: u32 = 4101;
    pub const aim_snap_pattern: u32 = 4102;
    pub const aim_radial_lock: u32 = 4103;
    pub const aim_velocity_pattern: u32 = 4104;
    pub const combined_gameplay_anomalies: u32 = 4201;
};

pub const DecisionFlag = struct {
    pub const write_audit: u64 = 1 << 0;
    pub const hold_score: u64 = 1 << 1;
    pub const disconnect_session: u64 = 1 << 2;
    pub const require_staff_review: u64 = 1 << 3;
    pub const notify_player: u64 = 1 << 4;
    pub const known_mask: u64 = (1 << 5) - 1;
};

pub const EventV1 = extern struct {
    abi_version: u32 = version,
    struct_size: u32 = @sizeOf(EventV1),
    event_kind: u32 = 0,
    client_family: u32 = 0,
    ruleset: u32 = 0,
    namespace: u32 = 0,
    event_flags: u64 = 0,
    evidence: u64 = 0,
    score: u64 = 0,
    pp_milli: u64 = 0,
    accuracy_ppm: u32 = 0,
    max_combo: u32 = 0,
    map_max_combo: u32 = 0,
    n300: u32 = 0,
    n100: u32 = 0,
    n50: u32 = 0,
    nmiss: u32 = 0,
    ngeki: u32 = 0,
    nkatu: u32 = 0,
    map_objects: u32 = 0,
    elapsed_ms: u32 = 0,
    map_duration_ms: u32 = 0,
    hardware_match_count: u32 = 0,
    recent_risk_score: u32 = 0,
    account_age_seconds: u64 = 0,
    replay_match_count: u32 = 0,
    reserved32: u32 = 0,
    reserved: [7]u64 = [_]u64{0} ** 7,
};

pub const DecisionV1 = extern struct {
    abi_version: u32 = version,
    struct_size: u32 = @sizeOf(DecisionV1),
    action: u32 = Action.allow,
    reason: u32 = Reason.none,
    risk_score: u32 = 0,
    confidence_bps: u32 = 0,
    flags: u64 = 0,
    rule_revision: u32 = 0,
    reserved32: u32 = 0,
    reserved: [4]u64 = [_]u64{0} ** 4,
};

pub const ReplayFrameV1 = extern struct {
    time_ms: i64,
    x: f32,
    y: f32,
    keys: u32,
    reserved: u32 = 0,
};

pub const HitObjectKind = struct {
    pub const circle: u32 = 1 << 0;
    pub const slider: u32 = 1 << 1;
    pub const spinner: u32 = 1 << 3;
};

pub const HitObjectV1 = extern struct {
    time_ms: i64,
    x: f32,
    y: f32,
    kind: u32,
    reserved: u32 = 0,
};

pub const GameplayEventV1 = extern struct {
    abi_version: u32 = version,
    struct_size: u32 = @sizeOf(GameplayEventV1),
    base: EventV1 = .{},
    mods: u64 = 0,
    passed_hits: u32 = 0,
    hit_window_ms: u32 = 0,
    frames: ?[*]const ReplayFrameV1 = null,
    frame_count: u32 = 0,
    objects: ?[*]const HitObjectV1 = null,
    object_count: u32 = 0,
    reserved: [6]u64 = [_]u64{0} ** 6,
};

pub const GameplayResultV1 = extern struct {
    abi_version: u32 = version,
    struct_size: u32 = @sizeOf(GameplayResultV1),
    decision: DecisionV1 = .{},
    objects_checked: u32 = 0,
    matched_clicks: u32 = 0,
    mean_abs_timing_error_milli: u32 = 0,
    timing_stddev_milli: u32 = 0,
    exact_timing_bps: u32 = 0,
    center_hits_bps: u32 = 0,
    mean_center_distance_milli: u32 = 0,
    snap_events: u32 = 0,
    key_press_count: u32 = 0,
    key_hold_count: u32 = 0,
    mean_hold_duration_milli: u32 = 0,
    hold_duration_stddev_milli: u32 = 0,
    alternation_bps: u32 = 0,
    target_distance_stddev_milli: u32 = 0,
    velocity_spike_count: u32 = 0,
    movement_velocity_stddev_milli: u32 = 0,
    reserved: [2]u64 = [_]u64{0} ** 2,
};
