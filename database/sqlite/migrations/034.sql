BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS beatmap_submissions(
    set_id INTEGER PRIMARY KEY CHECK(set_id>=100000000),
    owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    target TEXT NOT NULL CHECK(target IN('WIP','Pending')),
    notify_replies INTEGER NOT NULL DEFAULT 0 CHECK(notify_replies IN(0,1)),
    state TEXT NOT NULL DEFAULT 'reserved' CHECK(state IN('reserved','published','failed')),
    revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0),
    last_error TEXT NOT NULL DEFAULT '' CHECK(length(last_error)<=500),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    uploaded_at INTEGER
);
CREATE INDEX IF NOT EXISTS beatmap_submissions_owner_time ON beatmap_submissions(owner_id,updated_at DESC,set_id DESC);
CREATE INDEX IF NOT EXISTS beatmap_submissions_state_time ON beatmap_submissions(state,updated_at,set_id);

CREATE TABLE IF NOT EXISTS beatmap_submission_maps(
    set_id INTEGER NOT NULL REFERENCES beatmap_submissions(set_id) ON DELETE CASCADE,
    beatmap_id INTEGER NOT NULL UNIQUE CHECK(beatmap_id>=100000000),
    active INTEGER NOT NULL DEFAULT 1 CHECK(active IN(0,1)),
    position INTEGER NOT NULL CHECK(position>=0),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(set_id,beatmap_id)
);
CREATE INDEX IF NOT EXISTS beatmap_submission_maps_active ON beatmap_submission_maps(set_id,active,position,beatmap_id);

CREATE TABLE IF NOT EXISTS bss_counters(
    kind TEXT PRIMARY KEY CHECK(kind IN('set','beatmap')),
    next_id INTEGER NOT NULL CHECK(next_id>=100000000)
);
INSERT OR IGNORE INTO bss_counters(kind,next_id) VALUES('set',100000000),('beatmap',100000000);

PRAGMA user_version=34;
COMMIT;
