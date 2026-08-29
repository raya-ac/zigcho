BEGIN;

CREATE TABLE IF NOT EXISTS zigcho.maintenance_markers (
    key text PRIMARY KEY,
    created_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint)
);

UPDATE zigcho.scores SET best=false;
WITH ordered AS (
    SELECT
        id,
        row_number() OVER (
            PARTITION BY user_id, map_md5, mode, rank_namespace
            ORDER BY
                CASE WHEN rank_namespace IN ('relax', 'autopilot') THEN pp END DESC NULLS LAST,
                CASE WHEN rank_namespace NOT IN ('relax', 'autopilot') THEN score END DESC NULLS LAST,
                id ASC
        ) AS place
    FROM zigcho.scores
    WHERE passed
)
UPDATE zigcho.scores AS scores
SET best=true
FROM ordered
WHERE scores.id=ordered.id AND ordered.place=1;

UPDATE zigcho.lazer_scores SET best=false;
WITH ordered AS (
    SELECT
        id,
        row_number() OVER (
            PARTITION BY user_id, beatmap_id, ruleset_id, rank_namespace
            ORDER BY pp DESC, total_score DESC, id ASC
        ) AS place
    FROM zigcho.lazer_scores
    WHERE passed
)
UPDATE zigcho.lazer_scores AS scores
SET best=true
FROM ordered
WHERE scores.id=ordered.id AND ordered.place=1;

CREATE UNIQUE INDEX scores_one_best_per_scope
    ON zigcho.scores(user_id, map_md5, mode, rank_namespace)
    WHERE best;
CREATE UNIQUE INDEX lazer_scores_one_best_per_scope
    ON zigcho.lazer_scores(user_id, beatmap_id, ruleset_id, rank_namespace)
    WHERE best;

INSERT INTO zigcho.maintenance_markers(key)
VALUES('schema46_ranked_stats_rebuild')
ON CONFLICT(key) DO NOTHING;
INSERT INTO zigcho.schema_migrations(version) VALUES(46);
COMMIT;
