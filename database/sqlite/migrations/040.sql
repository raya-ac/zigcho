BEGIN IMMEDIATE;

ALTER TABLE lazer_channel_reads RENAME TO lazer_channel_reads_v39;
CREATE TABLE lazer_channel_reads (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    channel_id INTEGER NOT NULL CHECK(
        channel_id BETWEEN 1 AND 4 OR
        channel_id BETWEEN 2000000001 AND 2147483647
    ),
    last_read_id INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id, channel_id)
);
INSERT INTO lazer_channel_reads(user_id, channel_id, last_read_id, updated_at)
SELECT user_id, channel_id, last_read_id, updated_at
FROM lazer_channel_reads_v39;
DROP TABLE lazer_channel_reads_v39;

PRAGMA user_version=40;
COMMIT;
