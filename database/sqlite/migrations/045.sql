BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS server_controls(
    key TEXT PRIMARY KEY CHECK(key IN('registrations','stable_login','lazer_login','stable_scores','lazer_scores','lazer_multiplayer','spectator','bss','beatmap_downloads','website_writes')),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN(0,1)),
    reason TEXT NOT NULL DEFAULT '' CHECK(length(reason)<=500),
    updated_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);
INSERT OR IGNORE INTO server_controls(key) VALUES('registrations'),('stable_login'),('lazer_login'),('stable_scores'),('lazer_scores'),('lazer_multiplayer'),('spectator'),('bss'),('beatmap_downloads'),('website_writes');
PRAGMA user_version=45;
COMMIT;
