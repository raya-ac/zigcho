BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS moderation_appeals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('restriction','hwid')),
    message TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','accepted','denied')),
    reviewer_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    resolution TEXT,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    resolved_at INTEGER
);

CREATE UNIQUE INDEX IF NOT EXISTS moderation_appeals_one_open
    ON moderation_appeals(user_id, kind) WHERE status='open';
CREATE INDEX IF NOT EXISTS moderation_appeals_queue
    ON moderation_appeals(status, created_at, id);

COMMIT;
PRAGMA user_version=15;
