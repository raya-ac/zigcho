BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS score_replay_views (
    source TEXT NOT NULL CHECK(source IN('stable','lazer')),
    score_id INTEGER NOT NULL CHECK(score_id > 0),
    viewer_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mode INTEGER NOT NULL CHECK(mode BETWEEN 0 AND 6 OR mode = 8),
    rank_namespace TEXT NOT NULL CHECK(length(rank_namespace) BETWEEN 1 AND 32),
    viewed_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(source, score_id, viewer_id),
    CHECK(viewer_id != owner_id)
);
CREATE INDEX IF NOT EXISTS score_replay_views_owner
    ON score_replay_views(owner_id, mode, source, rank_namespace, viewed_at DESC);
CREATE INDEX IF NOT EXISTS friends_inbound
    ON friends(friend_id, user_id);

PRAGMA user_version=42;
COMMIT;
