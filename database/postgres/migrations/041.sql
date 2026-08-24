BEGIN;

CREATE TABLE zigcho.user_stats_history (
    user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,
    source text NOT NULL CHECK(source IN('all','stable','lazer','scorev2')),
    mode smallint NOT NULL CHECK(
        (source = 'scorev2' AND mode BETWEEN 0 AND 3) OR
        (source IN('all','stable','lazer') AND (mode BETWEEN 0 AND 6 OR mode = 8))
    ),
    day bigint NOT NULL CHECK(day >= 0 AND day % 86400 = 0),
    pp integer NOT NULL CHECK(pp >= 0),
    global_rank integer NOT NULL CHECK(global_rank >= 0),
    PRIMARY KEY(user_id, source, mode, day)
);
CREATE INDEX user_stats_history_lookup
    ON zigcho.user_stats_history(source, mode, day DESC, global_rank, user_id);
CREATE INDEX user_stats_history_retention
    ON zigcho.user_stats_history(day);

INSERT INTO zigcho.schema_migrations(version) VALUES(41);
COMMIT;
