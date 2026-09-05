-- Rank only narrow keys. Display metadata and replay checks belong after LIMIT.
WITH own_maps AS MATERIALIZED (
    SELECT DISTINCT s.beatmap_id AS beatmap_key
    FROM zigcho.lazer_scores s JOIN zigcho.beatmaps b ON b.id=s.beatmap_id
    WHERE s.user_id=$1 AND s.ruleset_id=$2 AND s.rank_namespace=$3
      AND s.passed AND s.best AND b.status IN(3,4)
), candidates AS (
    SELECT s.id, s.user_id, b.id AS beatmap_key, s.total_score AS score,
           s.pp, 'lazer'::text AS client, s.submitted_at
    FROM zigcho.lazer_scores s
    JOIN zigcho.beatmaps b ON b.id=s.beatmap_id
    JOIN own_maps own ON own.beatmap_key=b.id
    JOIN zigcho.users u ON u.id=s.user_id
    WHERE s.ruleset_id=$2 AND s.rank_namespace=$3
      AND s.passed AND s.best AND b.status IN(3,4) AND NOT u.restricted
), per_user AS (
    SELECT *, row_number() OVER (
        PARTITION BY user_id,beatmap_key ORDER BY pp DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC
    ) AS user_place FROM candidates
), board AS (
    SELECT *, row_number() OVER (
        PARTITION BY beatmap_key ORDER BY score DESC,CASE client WHEN 'stable' THEN 0 ELSE 1 END,id ASC
    ) AS map_place FROM per_user WHERE user_place=1
), firsts AS (
    SELECT *, count(*) OVER () AS first_count FROM board WHERE map_place=1 AND user_id=$1
), picked AS MATERIALIZED (
    SELECT * FROM firsts ORDER BY submitted_at DESC,client ASC,id DESC LIMIT 20
), hydrated AS (
    SELECT s.id, s.total_score AS score, s.pp, s.accuracy, s.max_combo,
           0 AS mods, s.ruleset_id AS mode, s.rank_namespace, s.passed, s.submitted_at,
           b.set_id, b.id AS map_id, b.artist, b.title, b.version, b.status,
           p.client, s.mods_json::text AS mods_json,
           s.passed AND (coalesce(octet_length(s.replay),0)>0 OR EXISTS(
               SELECT 1 FROM zigcho.replay_objects ro WHERE ro.source='lazer' AND ro.score_id=s.id
           )) AS has_replay,
           coalesce(nullif(s.star_rating,0),b.star_rating) AS star_rating,
           s.total_score_without_mods AS score_without_mods,
           s.legacy_total_score AS legacy_score, p.first_count
    FROM picked p JOIN zigcho.lazer_scores s ON p.client='lazer' AND s.id=p.id
    JOIN zigcho.beatmaps b ON b.id=s.beatmap_id
)
SELECT * FROM hydrated ORDER BY submitted_at DESC,client ASC,id DESC;
