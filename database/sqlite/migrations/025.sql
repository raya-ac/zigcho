BEGIN IMMEDIATE;

CREATE TABLE anticheat_observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    score_id INTEGER REFERENCES scores(id) ON DELETE SET NULL,
    source TEXT NOT NULL CHECK(source IN ('stable_login','stable_lastfm','stable_score')),
    module TEXT NOT NULL CHECK(length(module) BETWEEN 1 AND 64),
    action INTEGER NOT NULL CHECK(action BETWEEN 0 AND 3),
    sample_weight INTEGER NOT NULL DEFAULT 1 CHECK(sample_weight BETWEEN 1 AND 100000),
    reason INTEGER NOT NULL,
    risk_score INTEGER NOT NULL CHECK(risk_score BETWEEN 0 AND 1000),
    confidence_bps INTEGER NOT NULL CHECK(confidence_bps BETWEEN 0 AND 10000),
    evidence INTEGER NOT NULL DEFAULT 0 CHECK(evidence >= 0),
    decision_flags INTEGER NOT NULL DEFAULT 0 CHECK(decision_flags >= 0),
    rule_revision INTEGER NOT NULL DEFAULT 0,
    objects_checked INTEGER NOT NULL DEFAULT 0 CHECK(objects_checked >= 0),
    matched_clicks INTEGER NOT NULL DEFAULT 0 CHECK(matched_clicks BETWEEN 0 AND objects_checked),
    mean_abs_timing_error_milli INTEGER NOT NULL DEFAULT 0 CHECK(mean_abs_timing_error_milli >= 0),
    timing_stddev_milli INTEGER NOT NULL DEFAULT 0 CHECK(timing_stddev_milli >= 0),
    exact_timing_bps INTEGER NOT NULL DEFAULT 0 CHECK(exact_timing_bps BETWEEN 0 AND 10000),
    center_hits_bps INTEGER NOT NULL DEFAULT 0 CHECK(center_hits_bps BETWEEN 0 AND 10000),
    mean_center_distance_milli INTEGER NOT NULL DEFAULT 0 CHECK(mean_center_distance_milli >= 0),
    snap_events INTEGER NOT NULL DEFAULT 0 CHECK(snap_events BETWEEN 0 AND objects_checked),
    review_label TEXT NOT NULL DEFAULT 'pending' CHECK(review_label IN ('pending','clean','uncertain','cheat','dismissed')),
    reviewer_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    review_note TEXT NOT NULL DEFAULT '' CHECK(length(review_note) <= 1000),
    reviewed_at INTEGER,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    CHECK(
        (review_label = 'pending' AND reviewer_id IS NULL AND reviewed_at IS NULL AND review_note = '') OR
        (review_label != 'pending' AND reviewer_id IS NOT NULL AND reviewed_at IS NOT NULL AND length(review_note) BETWEEN 3 AND 1000)
    )
);

CREATE UNIQUE INDEX anticheat_observations_score ON anticheat_observations(score_id) WHERE score_id IS NOT NULL;
CREATE INDEX anticheat_observations_queue ON anticheat_observations(review_label,created_at,id);
CREATE INDEX anticheat_observations_user ON anticheat_observations(user_id,created_at DESC,id DESC);

COMMIT;
PRAGMA user_version=25;
