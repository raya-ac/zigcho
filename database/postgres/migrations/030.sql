BEGIN;

ALTER TABLE zigcho.beatmap_archives ALTER COLUMN osz_file DROP NOT NULL;
ALTER TABLE zigcho.beatmap_media ALTER COLUMN data DROP NOT NULL;
UPDATE zigcho.beatmap_archives SET osz_file=NULL WHERE osz_file IS NOT NULL;
UPDATE zigcho.beatmap_media SET data=NULL WHERE data IS NOT NULL;
INSERT INTO zigcho.schema_migrations(version) VALUES(30);

COMMIT;
