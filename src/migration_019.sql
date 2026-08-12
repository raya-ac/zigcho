BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS beatmap_media (
    set_id INTEGER NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN (
        'cover','cover_2x','card','card_2x','list','list_2x',
        'slimcover','slimcover_2x','thumb','thumb_large','preview'
    )),
    content_type TEXT NOT NULL CHECK(content_type IN ('image/jpeg','audio/ogg','audio/mpeg')),
    sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
    data BLOB NOT NULL CHECK(length(data) BETWEEN 1 AND 4194304),
    fetched_at INTEGER NOT NULL DEFAULT (unixepoch()),
    last_accessed_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(set_id, kind)
);
CREATE INDEX IF NOT EXISTS beatmap_media_lru ON beatmap_media(last_accessed_at, fetched_at, set_id, kind);

COMMIT;
PRAGMA user_version=19;
