BEGIN IMMEDIATE;

UPDATE users
SET privileges = privileges | (1 << 13) | (1 << 14)
WHERE id = 3 AND safe_name = 'kai';

COMMIT;
PRAGMA user_version=12;
