BEGIN IMMEDIATE;

ALTER TABLE users ADD COLUMN bio TEXT NOT NULL DEFAULT '' CHECK(length(bio) <= 500);
ALTER TABLE users ADD COLUMN preferred_mode INTEGER NOT NULL DEFAULT 0 CHECK(preferred_mode BETWEEN 0 AND 3);
ALTER TABLE users ADD COLUMN profile_source TEXT NOT NULL DEFAULT 'all' CHECK(profile_source IN ('all','lazer','scorev2'));

CREATE TABLE user_avatars (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    object_key TEXT NOT NULL UNIQUE CHECK(length(object_key) BETWEEN 1 AND 200),
    content_type TEXT NOT NULL CHECK(content_type IN ('image/png','image/jpeg','image/gif')),
    etag TEXT NOT NULL CHECK(length(etag) = 64),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

COMMIT;
PRAGMA user_version=23;
