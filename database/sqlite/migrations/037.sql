BEGIN IMMEDIATE;

DROP INDEX IF EXISTS beatmap_media_lru;
ALTER TABLE beatmap_media RENAME TO beatmap_media_v36;
CREATE TABLE beatmap_media (
    set_id INTEGER NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN (
        'cover','cover_2x','card','card_2x','list','list_2x',
        'slimcover','slimcover_2x','thumb','thumb_large','preview'
    )),
    content_type TEXT NOT NULL CHECK(content_type IN (
        'image/jpeg','image/png','image/gif',
        'audio/ogg','audio/mpeg','audio/wav'
    )),
    sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
    data BLOB NOT NULL CHECK(
        (content_type LIKE 'image/%' AND length(data) BETWEEN 1 AND 16777216) OR
        (content_type LIKE 'audio/%' AND length(data) BETWEEN 1 AND 33554432)
    ),
    fetched_at INTEGER NOT NULL DEFAULT (unixepoch()),
    last_accessed_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(set_id, kind)
);
INSERT INTO beatmap_media(set_id,kind,content_type,sha256,data,fetched_at,last_accessed_at)
SELECT set_id,kind,content_type,sha256,data,fetched_at,last_accessed_at FROM beatmap_media_v36;
DROP TABLE beatmap_media_v36;
CREATE INDEX beatmap_media_lru ON beatmap_media(last_accessed_at, fetched_at, set_id, kind);

PRAGMA user_version=37;
COMMIT;
