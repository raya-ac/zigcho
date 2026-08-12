BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS screenshots (
    token TEXT PRIMARY KEY,
    extension TEXT NOT NULL CHECK(extension IN ('jpeg','png')),
    uploader_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    image BLOB NOT NULL CHECK(length(image) <= 4194304),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    CHECK(length(token) = 8)
);
CREATE INDEX IF NOT EXISTS screenshots_uploader_time ON screenshots(uploader_id, created_at DESC);

COMMIT;
PRAGMA user_version=18;
