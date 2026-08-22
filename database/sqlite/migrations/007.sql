BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS ratings (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    map_md5 TEXT NOT NULL REFERENCES beatmaps(md5) ON UPDATE CASCADE ON DELETE CASCADE,
    rating INTEGER NOT NULL CHECK(rating BETWEEN 1 AND 10),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id,map_md5)
);
ALTER TABLE scores ADD COLUMN time_elapsed INTEGER NOT NULL DEFAULT 0;
ALTER TABLE stats ADD COLUMN total_hits INTEGER NOT NULL DEFAULT 0;
INSERT OR IGNORE INTO stats(user_id,mode) SELECT users.id,4 FROM users;
INSERT OR IGNORE INTO stats(user_id,mode) SELECT users.id,5 FROM users;
INSERT OR IGNORE INTO stats(user_id,mode) SELECT users.id,6 FROM users;
INSERT OR IGNORE INTO stats(user_id,mode) SELECT users.id,8 FROM users;
PRAGMA user_version=7;
COMMIT;
