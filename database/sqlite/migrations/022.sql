BEGIN IMMEDIATE;

ALTER TABLE lazer_scores ADD COLUMN pp REAL NOT NULL DEFAULT 0;
ALTER TABLE lazer_scores ADD COLUMN best INTEGER NOT NULL DEFAULT 0 CHECK(best IN (0,1));
UPDATE lazer_scores SET best=1 WHERE id IN (
    SELECT id FROM (
        SELECT id,row_number() OVER (
            PARTITION BY user_id,beatmap_id,ruleset_id,rank_namespace
            ORDER BY CASE WHEN rank_namespace IN ('relax','autopilot') AND pp>0 THEN pp ELSE total_score END DESC,id ASC
        ) AS place
        FROM lazer_scores
        WHERE passed=1
    ) ranked
    WHERE place=1
);
CREATE INDEX lazer_scores_user_best ON lazer_scores(user_id,ruleset_id,rank_namespace,beatmap_id,best);

COMMIT;
PRAGMA user_version=22;
