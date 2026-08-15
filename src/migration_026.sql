BEGIN IMMEDIATE;

ALTER TABLE anticheat_observations ADD COLUMN replay_match_count INTEGER NOT NULL DEFAULT 0 CHECK(replay_match_count BETWEEN 0 AND 100000);
ALTER TABLE anticheat_observations ADD COLUMN key_press_count INTEGER NOT NULL DEFAULT 0 CHECK(key_press_count >= 0);
ALTER TABLE anticheat_observations ADD COLUMN key_hold_count INTEGER NOT NULL DEFAULT 0 CHECK(key_hold_count BETWEEN 0 AND key_press_count);
ALTER TABLE anticheat_observations ADD COLUMN mean_hold_duration_milli INTEGER NOT NULL DEFAULT 0 CHECK(mean_hold_duration_milli >= 0);
ALTER TABLE anticheat_observations ADD COLUMN hold_duration_stddev_milli INTEGER NOT NULL DEFAULT 0 CHECK(hold_duration_stddev_milli >= 0);
ALTER TABLE anticheat_observations ADD COLUMN alternation_bps INTEGER NOT NULL DEFAULT 0 CHECK(alternation_bps BETWEEN 0 AND 10000);
ALTER TABLE anticheat_observations ADD COLUMN target_distance_stddev_milli INTEGER NOT NULL DEFAULT 0 CHECK(target_distance_stddev_milli >= 0);
ALTER TABLE anticheat_observations ADD COLUMN velocity_spike_count INTEGER NOT NULL DEFAULT 0 CHECK(velocity_spike_count >= 0);
ALTER TABLE anticheat_observations ADD COLUMN movement_velocity_stddev_milli INTEGER NOT NULL DEFAULT 0 CHECK(movement_velocity_stddev_milli >= 0);

CREATE TABLE anticheat_replay_fingerprints (
    score_id INTEGER PRIMARY KEY REFERENCES scores(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    replay_sha256 BLOB NOT NULL CHECK(length(replay_sha256) = 32),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX anticheat_replay_fingerprints_hash ON anticheat_replay_fingerprints(replay_sha256,user_id);
CREATE INDEX anticheat_replay_fingerprints_user ON anticheat_replay_fingerprints(user_id,created_at DESC,score_id DESC);

COMMIT;
PRAGMA user_version=26;
