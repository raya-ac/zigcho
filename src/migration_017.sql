BEGIN IMMEDIATE;

ALTER TABLE beatmap_archives ADD COLUMN last_accessed_at INTEGER NOT NULL DEFAULT 0;
UPDATE beatmap_archives SET last_accessed_at=imported_at WHERE last_accessed_at=0;
CREATE INDEX IF NOT EXISTS beatmap_archives_lru
    ON beatmap_archives(last_accessed_at, imported_at, set_id);

CREATE TABLE IF NOT EXISTS beatmap_hydration_failures (
    md5 TEXT PRIMARY KEY,
    set_id INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 1,
    next_retry_at INTEGER NOT NULL,
    last_error TEXT NOT NULL,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    CHECK(length(md5) = 32),
    CHECK(attempts BETWEEN 1 AND 32)
);
CREATE INDEX IF NOT EXISTS beatmap_hydration_retry
    ON beatmap_hydration_failures(next_retry_at, updated_at);

COMMIT;
PRAGMA user_version=17;
