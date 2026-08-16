BEGIN IMMEDIATE;

ALTER TABLE scores ADD COLUMN star_rating REAL NOT NULL DEFAULT 0;
ALTER TABLE lazer_scores ADD COLUMN star_rating REAL NOT NULL DEFAULT 0;

UPDATE scores
SET star_rating=coalesce((SELECT b.star_rating FROM beatmaps b WHERE b.md5=scores.map_md5),0);
UPDATE lazer_scores
SET star_rating=coalesce((SELECT b.star_rating FROM beatmaps b WHERE b.id=lazer_scores.beatmap_id),0);

COMMIT;
PRAGMA user_version=29;
