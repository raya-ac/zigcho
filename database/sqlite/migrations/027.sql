BEGIN IMMEDIATE;

ALTER TABLE chat_messages ADD COLUMN is_action INTEGER NOT NULL DEFAULT 0 CHECK(is_action IN (0,1));
ALTER TABLE chat_messages ADD COLUMN client_uuid TEXT NOT NULL DEFAULT '' CHECK(length(client_uuid) IN (0,36));
CREATE UNIQUE INDEX chat_messages_sender_uuid ON chat_messages(sender_id,client_uuid) WHERE client_uuid!='';

CREATE TABLE lazer_channel_reads (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    channel_id INTEGER NOT NULL CHECK(channel_id BETWEEN 1 AND 4),
    last_read_id INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id, channel_id)
);

CREATE TABLE user_blocks (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id, blocked_id),
    CHECK(user_id != blocked_id)
);

COMMIT;
PRAGMA user_version=27;
