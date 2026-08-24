BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS user_stats_history (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source TEXT NOT NULL CHECK(source IN('all','stable','lazer','scorev2')),
    mode INTEGER NOT NULL CHECK(
        (source = 'scorev2' AND mode BETWEEN 0 AND 3) OR
        (source IN('all','stable','lazer') AND (mode BETWEEN 0 AND 6 OR mode = 8))
    ),
    day INTEGER NOT NULL CHECK(day >= 0 AND day % 86400 = 0),
    pp INTEGER NOT NULL CHECK(pp >= 0),
    global_rank INTEGER NOT NULL CHECK(global_rank >= 0),
    PRIMARY KEY(user_id, source, mode, day)
);
CREATE INDEX IF NOT EXISTS user_stats_history_lookup
    ON user_stats_history(source, mode, day DESC, global_rank, user_id);
CREATE INDEX IF NOT EXISTS user_stats_history_retention
    ON user_stats_history(day);

PRAGMA user_version=41;
COMMIT;
