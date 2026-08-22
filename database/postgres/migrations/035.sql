BEGIN;

UPDATE zigcho.bss_counters SET next_id=greatest(next_id,1000000000);
ALTER TABLE zigcho.beatmap_submissions ADD COLUMN replacement_set_id integer CHECK(replacement_set_id IS NULL OR (replacement_set_id>=1000000000 AND replacement_set_id<>set_id));
CREATE UNIQUE INDEX beatmap_submissions_replacement ON zigcho.beatmap_submissions(replacement_set_id) WHERE replacement_set_id IS NOT NULL;

CREATE TABLE zigcho.upstream_users(
    id integer PRIMARY KEY CHECK(id>0),
    username text NOT NULL CHECK(length(username) BETWEEN 1 AND 64),
    country char(2) NOT NULL,
    join_date char(20) NOT NULL,
    fetched_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint)
);
CREATE INDEX upstream_users_name ON zigcho.upstream_users(lower(username),fetched_at DESC,id);

CREATE TABLE zigcho.upstream_user_profiles(
    user_id integer NOT NULL REFERENCES zigcho.upstream_users(id) ON DELETE CASCADE,
    mode smallint NOT NULL CHECK(mode BETWEEN 0 AND 3),
    profile_json jsonb NOT NULL CHECK(jsonb_typeof(profile_json)='object'),
    fetched_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),
    PRIMARY KEY(user_id,mode)
);

CREATE TABLE zigcho.beatmapset_metadata(
    set_id integer PRIMARY KEY CHECK(set_id>0),
    favourites integer NOT NULL DEFAULT 0 CHECK(favourites>=0),
    submitted_date char(20) NOT NULL,
    last_updated char(20) NOT NULL,
    ranked_date char(20),
    has_video boolean NOT NULL DEFAULT false,
    genre_id smallint NOT NULL DEFAULT 0 CHECK(genre_id>=0),
    language_id smallint NOT NULL DEFAULT 0 CHECK(language_id>=0),
    fetched_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint)
);

ALTER TABLE zigcho.beatmaps
    ADD COLUMN creator_id integer REFERENCES zigcho.upstream_users(id) ON DELETE SET NULL,
    ADD COLUMN upstream_plays integer NOT NULL DEFAULT 0 CHECK(upstream_plays>=0),
    ADD COLUMN upstream_passes integer NOT NULL DEFAULT 0 CHECK(upstream_passes>=0),
    ADD COLUMN hit_length integer NOT NULL DEFAULT 0 CHECK(hit_length>=0);
CREATE INDEX beatmaps_creator_id ON zigcho.beatmaps(creator_id,set_id);

INSERT INTO zigcho.schema_migrations(version) VALUES(35);
COMMIT;
