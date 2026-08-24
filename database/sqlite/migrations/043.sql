BEGIN IMMEDIATE;

ALTER TABLE lazer_scores
    ADD COLUMN total_score_without_mods INTEGER NOT NULL DEFAULT 0
    CHECK(total_score_without_mods BETWEEN 0 AND 1000000000000);

UPDATE lazer_scores
SET total_score_without_mods=coalesce(legacy_total_score,total_score),
    legacy_total_score=NULL;

CREATE TRIGGER lazer_scores_legacy_total_score_insert
BEFORE INSERT ON lazer_scores
WHEN NEW.legacy_total_score IS NOT NULL
 AND (typeof(NEW.legacy_total_score)!='integer' OR NEW.legacy_total_score<0 OR NEW.legacy_total_score>2147483647)
BEGIN
    SELECT raise(ABORT,'legacy_total_score outside nullable int32 range');
END;

CREATE TRIGGER lazer_scores_legacy_total_score_update
BEFORE UPDATE OF legacy_total_score ON lazer_scores
WHEN NEW.legacy_total_score IS NOT NULL
 AND (typeof(NEW.legacy_total_score)!='integer' OR NEW.legacy_total_score<0 OR NEW.legacy_total_score>2147483647)
BEGIN
    SELECT raise(ABORT,'legacy_total_score outside nullable int32 range');
END;

CREATE TRIGGER lazer_scores_total_score_without_mods_insert
BEFORE INSERT ON lazer_scores
WHEN NEW.total_score_without_mods IS NULL
 OR typeof(NEW.total_score_without_mods)!='integer'
 OR NEW.total_score_without_mods<0
 OR NEW.total_score_without_mods>1000000000000
BEGIN
    SELECT raise(ABORT,'total_score_without_mods outside required range');
END;

CREATE TRIGGER lazer_scores_total_score_without_mods_update
BEFORE UPDATE OF total_score_without_mods ON lazer_scores
WHEN NEW.total_score_without_mods IS NULL
 OR typeof(NEW.total_score_without_mods)!='integer'
 OR NEW.total_score_without_mods<0
 OR NEW.total_score_without_mods>1000000000000
BEGIN
    SELECT raise(ABORT,'total_score_without_mods outside required range');
END;

PRAGMA user_version=43;
COMMIT;
