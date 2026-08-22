BEGIN IMMEDIATE;
ALTER TABLE users ADD COLUMN avatar_key INTEGER NOT NULL DEFAULT 1 CHECK(avatar_key IN (1,2));
UPDATE users SET avatar_key=1+(random()&1);
PRAGMA user_version=10;
COMMIT;
