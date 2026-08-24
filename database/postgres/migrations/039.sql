BEGIN;

CREATE TABLE zigcho.lazer_ranked_ratings (
    user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,
    ruleset_id smallint NOT NULL CHECK(ruleset_id BETWEEN 0 AND 3),
    rating integer NOT NULL DEFAULT 1500,
    games_played integer NOT NULL DEFAULT 0 CHECK(games_played >= 0),
    wins integer NOT NULL DEFAULT 0 CHECK(wins >= 0),
    losses integer NOT NULL DEFAULT 0 CHECK(losses >= 0),
    updated_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),
    PRIMARY KEY(user_id, ruleset_id),
    CHECK(games_played = wins + losses)
);
CREATE INDEX lazer_ranked_ratings_board
    ON zigcho.lazer_ranked_ratings(ruleset_id, rating DESC, games_played DESC, user_id);

CREATE TABLE zigcho.lazer_ranked_matches (
    room_id bigint PRIMARY KEY CHECK(room_id > 0),
    ruleset_id smallint NOT NULL CHECK(ruleset_id BETWEEN 0 AND 3),
    winner_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE RESTRICT,
    loser_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE RESTRICT,
    winner_rating_before integer NOT NULL,
    winner_rating_after integer NOT NULL,
    loser_rating_before integer NOT NULL,
    loser_rating_after integer NOT NULL,
    completed_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint),
    CHECK(winner_id != loser_id)
);
CREATE INDEX lazer_ranked_matches_users
    ON zigcho.lazer_ranked_matches(winner_id, loser_id, completed_at DESC, room_id DESC);

INSERT INTO zigcho.schema_migrations(version) VALUES(39);
COMMIT;
