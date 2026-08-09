CREATE TABLE beatmap_archives (
    set_id INTEGER PRIMARY KEY,
    sha256 TEXT NOT NULL,
    osz_file BLOB NOT NULL,
    imported_at INTEGER NOT NULL DEFAULT (unixepoch())
);
ALTER TABLE beatmaps ADD COLUMN count_circles INTEGER NOT NULL DEFAULT 0;
ALTER TABLE beatmaps ADD COLUMN count_sliders INTEGER NOT NULL DEFAULT 0;
ALTER TABLE beatmaps ADD COLUMN count_spinners INTEGER NOT NULL DEFAULT 0;
PRAGMA user_version=6;
