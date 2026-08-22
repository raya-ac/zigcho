BEGIN;

CREATE TABLE IF NOT EXISTS zigcho.beatmap_submissions(
    set_id integer PRIMARY KEY CHECK(set_id>=100000000),
    owner_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE RESTRICT,
    target text NOT NULL CHECK(target IN('WIP','Pending')),
    notify_replies boolean NOT NULL DEFAULT false,
    state text NOT NULL DEFAULT 'reserved' CHECK(state IN('reserved','published','failed')),
    revision integer NOT NULL DEFAULT 1 CHECK(revision>0),
    last_error text NOT NULL DEFAULT '' CHECK(length(last_error)<=500),
    created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),
    updated_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),
    uploaded_at bigint
);
CREATE INDEX IF NOT EXISTS beatmap_submissions_owner_time ON zigcho.beatmap_submissions(owner_id,updated_at DESC,set_id DESC);
CREATE INDEX IF NOT EXISTS beatmap_submissions_state_time ON zigcho.beatmap_submissions(state,updated_at,set_id);

CREATE TABLE IF NOT EXISTS zigcho.beatmap_submission_maps(
    set_id integer NOT NULL REFERENCES zigcho.beatmap_submissions(set_id) ON DELETE CASCADE,
    beatmap_id integer NOT NULL UNIQUE CHECK(beatmap_id>=100000000),
    active boolean NOT NULL DEFAULT true,
    position integer NOT NULL CHECK(position>=0),
    created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),
    PRIMARY KEY(set_id,beatmap_id)
);
CREATE INDEX IF NOT EXISTS beatmap_submission_maps_active ON zigcho.beatmap_submission_maps(set_id,active,position,beatmap_id);

CREATE TABLE IF NOT EXISTS zigcho.bss_counters(
    kind text PRIMARY KEY CHECK(kind IN('set','beatmap')),
    next_id integer NOT NULL CHECK(next_id>=100000000)
);
INSERT INTO zigcho.bss_counters(kind,next_id) VALUES('set',100000000),('beatmap',100000000) ON CONFLICT(kind) DO NOTHING;

INSERT INTO zigcho.schema_migrations(version) VALUES(34) ON CONFLICT(version) DO NOTHING;
COMMIT;
