CREATE UNIQUE INDEX IF NOT EXISTS scores_checksum_unique ON scores(checksum) WHERE checksum IS NOT NULL;
PRAGMA user_version=3;
