BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS client_hardware (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  osu_path_md5 TEXT NOT NULL CHECK(length(osu_path_md5)=32),
  adapters_md5 TEXT NOT NULL CHECK(length(adapters_md5)=32),
  uninstall_md5 TEXT NOT NULL CHECK(length(uninstall_md5)=32),
  disk_signature_md5 TEXT NOT NULL CHECK(length(disk_signature_md5)=32),
  client_version TEXT NOT NULL,
  running_under_wine INTEGER NOT NULL CHECK(running_under_wine IN (0,1)),
  first_seen INTEGER NOT NULL DEFAULT (unixepoch()),
  last_seen INTEGER NOT NULL DEFAULT (unixepoch()),
  occurrences INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY(user_id,osu_path_md5,adapters_md5,uninstall_md5,disk_signature_md5)
);

CREATE INDEX IF NOT EXISTS client_hardware_exact_match
ON client_hardware(adapters_md5,uninstall_md5,disk_signature_md5,user_id);

PRAGMA user_version=11;
COMMIT;
