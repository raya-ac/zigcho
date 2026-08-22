BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target TEXT NOT NULL,
    message TEXT NOT NULL,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS chat_messages_target_time ON chat_messages(target, created_at DESC);
CREATE INDEX IF NOT EXISTS chat_messages_sender_time ON chat_messages(sender_id, created_at DESC);

CREATE TABLE IF NOT EXISTS chat_channels (
    name TEXT PRIMARY KEY,
    topic TEXT NOT NULL,
    write_privileges INTEGER NOT NULL DEFAULT 1,
    locked INTEGER NOT NULL DEFAULT 0,
    updated_by INTEGER,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

INSERT OR IGNORE INTO chat_channels(name,topic,write_privileges) VALUES
    ('#osu','general chat',1),
    ('#announce','updates',8192),
    ('#lobby','multiplayer lobby',1),
    ('#lazer','lazer chat',1);

COMMIT;
PRAGMA user_version=13;
