BEGIN IMMEDIATE;

ALTER TABLE beatmaps ADD COLUMN status_frozen INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS beatmap_rank_requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    set_id INTEGER NOT NULL,
    map_id INTEGER NOT NULL REFERENCES beatmaps(id) ON DELETE CASCADE,
    requester_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    resolved_at INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS beatmap_rank_requests_active_user
    ON beatmap_rank_requests(set_id, requester_id) WHERE active=1;
CREATE INDEX IF NOT EXISTS beatmap_rank_requests_queue
    ON beatmap_rank_requests(active, created_at, set_id);

CREATE TABLE IF NOT EXISTS beatmap_nominations (
    set_id INTEGER NOT NULL,
    nominator_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (set_id, nominator_id)
);
CREATE INDEX IF NOT EXISTS beatmap_nominations_active
    ON beatmap_nominations(set_id, active);

CREATE TABLE IF NOT EXISTS beatmap_rank_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    set_id INTEGER NOT NULL,
    actor_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    from_status INTEGER NOT NULL,
    to_status INTEGER NOT NULL,
    reason TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS beatmap_rank_events_set_time
    ON beatmap_rank_events(set_id, created_at DESC, id DESC);

COMMIT;
PRAGMA user_version=14;
