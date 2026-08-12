BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS score_pins (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    score_id INTEGER NOT NULL UNIQUE REFERENCES scores(id) ON DELETE CASCADE,
    pinned_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id, score_id)
);
CREATE INDEX IF NOT EXISTS score_pins_user_time
    ON score_pins(user_id, pinned_at DESC, score_id DESC);

COMMIT;
PRAGMA user_version=16;
