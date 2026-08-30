BEGIN IMMEDIATE;

CREATE TABLE anticheat_review_exclusions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    scope TEXT NOT NULL CHECK(scope IN ('all','stable_login','stable_lastfm','stable_score')),
    reason TEXT NOT NULL CHECK(length(reason) BETWEEN 3 AND 500),
    created_by INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL,
    revoked_by INTEGER REFERENCES users(id) ON DELETE RESTRICT,
    revoked_at INTEGER,
    revoke_reason TEXT NOT NULL DEFAULT '' CHECK(length(revoke_reason) <= 500),
    CHECK(user_id != 3 AND created_by != 3 AND user_id != created_by),
    CHECK(revoked_by IS NULL OR (revoked_by != 3 AND revoked_by != user_id)),
    CHECK(expires_at BETWEEN created_at + 3600 AND created_at + 2592000),
    CHECK(
        (revoked_by IS NULL AND revoked_at IS NULL AND revoke_reason = '') OR
        (revoked_by IS NOT NULL AND revoked_at IS NOT NULL AND revoked_at >= created_at AND length(revoke_reason) BETWEEN 3 AND 500)
    )
);
CREATE INDEX anticheat_review_exclusions_user
    ON anticheat_review_exclusions(user_id, revoked_at, expires_at, scope, id DESC);
CREATE INDEX anticheat_review_exclusions_history
    ON anticheat_review_exclusions(created_at DESC, id DESC);

ALTER TABLE anticheat_observations
    ADD COLUMN review_exclusion_id INTEGER REFERENCES anticheat_review_exclusions(id) ON DELETE RESTRICT;
CREATE INDEX anticheat_observations_review_queue
    ON anticheat_observations(review_label, review_exclusion_id, created_at, id);

ALTER TABLE anticheat_replay_fingerprints
    ADD COLUMN replay_content_sha256 BLOB
    CHECK(replay_content_sha256 IS NULL OR length(replay_content_sha256) = 32);
CREATE INDEX anticheat_replay_fingerprints_content
    ON anticheat_replay_fingerprints(replay_content_sha256, user_id)
    WHERE replay_content_sha256 IS NOT NULL;

PRAGMA user_version=46;
COMMIT;
