BEGIN;

CREATE TABLE zigcho.score_replay_views (
    source text NOT NULL CHECK(source IN('stable','lazer')),
    score_id bigint NOT NULL CHECK(score_id > 0),
    viewer_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,
    owner_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,
    mode smallint NOT NULL CHECK(mode BETWEEN 0 AND 6 OR mode = 8),
    rank_namespace text NOT NULL CHECK(length(rank_namespace) BETWEEN 1 AND 32),
    viewed_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),
    PRIMARY KEY(source, score_id, viewer_id),
    CHECK(viewer_id != owner_id)
);
CREATE INDEX score_replay_views_owner
    ON zigcho.score_replay_views(owner_id, mode, source, rank_namespace, viewed_at DESC);
CREATE INDEX IF NOT EXISTS friends_inbound
    ON zigcho.friends(friend_id, user_id);

INSERT INTO zigcho.schema_migrations(version) VALUES(42);
COMMIT;
