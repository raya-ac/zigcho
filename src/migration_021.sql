BEGIN IMMEDIATE;

ALTER TABLE lazer_scores ADD COLUMN rank TEXT NOT NULL DEFAULT 'F';
ALTER TABLE lazer_scores ADD COLUMN maximum_statistics_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE lazer_scores ADD COLUMN pauses_json TEXT NOT NULL DEFAULT '[]';

CREATE TABLE IF NOT EXISTS lazer_score_tokens (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    beatmap_id INTEGER NOT NULL REFERENCES beatmaps(id) ON DELETE CASCADE,
    beatmap_hash TEXT NOT NULL CHECK(length(beatmap_hash) = 32),
    ruleset_id INTEGER NOT NULL CHECK(ruleset_id BETWEEN 0 AND 3),
    version_hash TEXT NOT NULL CHECK(length(version_hash) = 32),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER,
    score_id INTEGER REFERENCES lazer_scores(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS lazer_score_tokens_user_expiry
    ON lazer_score_tokens(user_id, expires_at DESC);

COMMIT;
PRAGMA user_version=21;
