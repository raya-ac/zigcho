BEGIN;

ALTER TABLE zigcho.lazer_scores
    ADD COLUMN total_score_without_mods bigint;

UPDATE zigcho.lazer_scores
SET total_score_without_mods=coalesce(legacy_total_score,total_score),
    legacy_total_score=NULL;

ALTER TABLE zigcho.lazer_scores
    ALTER COLUMN total_score_without_mods SET NOT NULL,
    ALTER COLUMN legacy_total_score TYPE integer USING legacy_total_score::integer;

ALTER TABLE zigcho.lazer_scores
    ADD CONSTRAINT lazer_scores_total_without_mods_range
        CHECK(total_score_without_mods BETWEEN 0 AND 1000000000000),
    ADD CONSTRAINT lazer_scores_legacy_total_score_range
        CHECK(legacy_total_score IS NULL OR legacy_total_score>=0);

INSERT INTO zigcho.schema_migrations(version) VALUES(43);
COMMIT;
