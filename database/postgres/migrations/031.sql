BEGIN;

ALTER TABLE zigcho.beatmap_archives ADD COLUMN object_bytes bigint NOT NULL DEFAULT 0 CHECK(object_bytes>=0);
UPDATE zigcho.beatmap_archives SET object_bytes=coalesce(octet_length(osz_file),0);
INSERT INTO zigcho.schema_migrations(version) VALUES(31);

COMMIT;
