BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS beatmap_comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_id INTEGER NOT NULL,
    target_type TEXT NOT NULL CHECK(target_type IN ('song','map','replay')),
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    time REAL NOT NULL,
    comment TEXT NOT NULL CHECK(length(comment) BETWEEN 1 AND 80),
    colour TEXT CHECK(colour IS NULL OR length(colour) = 6),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS beatmap_comments_target ON beatmap_comments(target_type, target_id, id);

CREATE TABLE IF NOT EXISTS direct_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message TEXT NOT NULL CHECK(length(message) BETWEEN 1 AND 2000),
    read INTEGER NOT NULL DEFAULT 0 CHECK(read IN (0, 1)),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS direct_messages_unread ON direct_messages(to_id, read, created_at, id);
CREATE INDEX IF NOT EXISTS direct_messages_conversation ON direct_messages(to_id, from_id, read, id);

COMMIT;
PRAGMA user_version=20;
