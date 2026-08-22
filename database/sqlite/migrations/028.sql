BEGIN IMMEDIATE;

ALTER TABLE direct_messages ADD COLUMN is_action INTEGER NOT NULL DEFAULT 0 CHECK(is_action IN (0,1));
ALTER TABLE direct_messages ADD COLUMN client_uuid TEXT NOT NULL DEFAULT '';
CREATE UNIQUE INDEX direct_messages_sender_uuid ON direct_messages(from_id,client_uuid) WHERE client_uuid!='';
UPDATE custom_mods SET ranked=1;

CREATE TABLE IF NOT EXISTS user_achievements (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    achievement_id INTEGER NOT NULL CHECK(achievement_id > 0),
    score_source TEXT NOT NULL CHECK(score_source IN ('stable','lazer')),
    score_id INTEGER NOT NULL CHECK(score_id > 0),
    achieved_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id, achievement_id)
);
CREATE INDEX IF NOT EXISTS user_achievements_score ON user_achievements(score_source, score_id);

COMMIT;
PRAGMA user_version=28;
