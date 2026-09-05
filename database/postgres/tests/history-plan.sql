\set ON_ERROR_STOP on
\timing on
SET statement_timeout='45s';
CREATE TEMP TABLE history_plan_fixture (
    user_id integer NOT NULL, source text NOT NULL, mode smallint NOT NULL,
    day bigint NOT NULL, pp integer NOT NULL, global_rank integer NOT NULL,
    PRIMARY KEY(user_id,source,mode,day)
);
CREATE INDEX ON history_plan_fixture(source,mode,day DESC,global_rank,user_id);
CREATE INDEX ON history_plan_fixture(day);
INSERT INTO history_plan_fixture
SELECT 10000+n,'all',0,(extract(epoch FROM now())::bigint/86400-d)*86400,200+d,n+1
FROM generate_series(0,99) n CROSS JOIN generate_series(1,30) d;
ANALYZE history_plan_fixture;
-- Reproduce the first daily seed after the existing history was analyzed.
INSERT INTO history_plan_fixture
SELECT 10000+n,s,0,(extract(epoch FROM now())::bigint/86400)*86400,10000-n,n+1
FROM generate_series(0,9999) n CROSS JOIN (VALUES('all'),('stable')) sources(s);
UPDATE history_plan_fixture SET pp=30000 WHERE user_id=15000 AND source='all'
AND day=(extract(epoch FROM now())::bigint/86400)*86400;
BEGIN;
SAVEPOINT original_rows;
\echo original rank join with stale day statistics
EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON)
WITH ranked AS (
    SELECT user_id,row_number() OVER(ORDER BY pp DESC,user_id ASC) position
    FROM history_plan_fixture WHERE source='all' AND mode=0
    AND day=(extract(epoch FROM now())::bigint/86400)*86400
)
UPDATE history_plan_fixture h SET global_rank=r.position FROM ranked r
WHERE h.user_id=r.user_id AND h.source='all' AND h.mode=0
AND h.day=(extract(epoch FROM now())::bigint/86400)*86400
AND h.global_rank IS DISTINCT FROM r.position;
SELECT md5(string_agg(user_id||':'||source||':'||day||':'||pp||':'||global_rank,','
ORDER BY user_id,source,day)) AS original_digest FROM history_plan_fixture \gset
ROLLBACK TO SAVEPOINT original_rows;
\echo tuple rank update with the same stale day statistics
EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON)
WITH ranked AS MATERIALIZED (
    SELECT ctid row_id,row_number() OVER(ORDER BY pp DESC,user_id ASC) position
    FROM history_plan_fixture WHERE source='all' AND mode=0
    AND day=(extract(epoch FROM now())::bigint/86400)*86400
)
UPDATE history_plan_fixture h SET global_rank=r.position FROM ranked r
WHERE h.ctid=r.row_id AND h.global_rank IS DISTINCT FROM r.position;
SELECT md5(string_agg(user_id||':'||source||':'||day||':'||pp||':'||global_rank,','
ORDER BY user_id,source,day)) = :'original_digest' AS identical_rows FROM history_plan_fixture \gset
\if :identical_rows
\echo history plan row parity passed
\else
\echo history plan row parity FAILED
\quit 1
\endif
ROLLBACK;
