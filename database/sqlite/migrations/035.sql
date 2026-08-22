BEGIN IMMEDIATE;

UPDATE bss_counters SET next_id=max(next_id,1000000000);
ALTER TABLE beatmap_submissions ADD COLUMN replacement_set_id INTEGER CHECK(replacement_set_id IS NULL OR (replacement_set_id>=1000000000 AND replacement_set_id!=set_id));
CREATE UNIQUE INDEX beatmap_submissions_replacement ON beatmap_submissions(replacement_set_id) WHERE replacement_set_id IS NOT NULL;

CREATE TABLE upstream_users(
    id INTEGER PRIMARY KEY CHECK(id>0),
    username TEXT NOT NULL CHECK(length(username) BETWEEN 1 AND 64),
    country TEXT NOT NULL CHECK(length(country)=2),
    join_date TEXT NOT NULL CHECK(length(join_date)=20),
    fetched_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX upstream_users_name ON upstream_users(lower(username),fetched_at DESC,id);

CREATE TABLE upstream_user_profiles(
    user_id INTEGER NOT NULL REFERENCES upstream_users(id) ON DELETE CASCADE,
    mode INTEGER NOT NULL CHECK(mode BETWEEN 0 AND 3),
    profile_json TEXT NOT NULL CHECK(json_valid(profile_json) AND json_type(profile_json)='object'),
    fetched_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id,mode)
);

CREATE TABLE beatmapset_metadata(
    set_id INTEGER PRIMARY KEY CHECK(set_id>0),
    favourites INTEGER NOT NULL DEFAULT 0 CHECK(favourites>=0),
    submitted_date TEXT NOT NULL CHECK(length(submitted_date)=20),
    last_updated TEXT NOT NULL CHECK(length(last_updated)=20),
    ranked_date TEXT CHECK(ranked_date IS NULL OR length(ranked_date)=20),
    has_video INTEGER NOT NULL DEFAULT 0 CHECK(has_video IN(0,1)),
    genre_id INTEGER NOT NULL DEFAULT 0 CHECK(genre_id>=0),
    language_id INTEGER NOT NULL DEFAULT 0 CHECK(language_id>=0),
    fetched_at INTEGER NOT NULL DEFAULT (unixepoch())
);

ALTER TABLE beatmaps ADD COLUMN creator_id INTEGER REFERENCES upstream_users(id) ON DELETE SET NULL;
ALTER TABLE beatmaps ADD COLUMN upstream_plays INTEGER NOT NULL DEFAULT 0 CHECK(upstream_plays>=0);
ALTER TABLE beatmaps ADD COLUMN upstream_passes INTEGER NOT NULL DEFAULT 0 CHECK(upstream_passes>=0);
ALTER TABLE beatmaps ADD COLUMN hit_length INTEGER NOT NULL DEFAULT 0 CHECK(hit_length>=0);
CREATE INDEX beatmaps_creator_id ON beatmaps(creator_id,set_id);

PRAGMA user_version=35;
COMMIT;
