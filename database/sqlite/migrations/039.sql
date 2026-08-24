BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS lazer_ranked_ratings (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ruleset_id INTEGER NOT NULL CHECK(ruleset_id BETWEEN 0 AND 3),
    rating INTEGER NOT NULL DEFAULT 1500,
    games_played INTEGER NOT NULL DEFAULT 0 CHECK(games_played >= 0),
    wins INTEGER NOT NULL DEFAULT 0 CHECK(wins >= 0),
    losses INTEGER NOT NULL DEFAULT 0 CHECK(losses >= 0),
    updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY(user_id, ruleset_id),
    CHECK(games_played = wins + losses)
);
CREATE INDEX IF NOT EXISTS lazer_ranked_ratings_board
    ON lazer_ranked_ratings(ruleset_id, rating DESC, games_played DESC, user_id);

CREATE TABLE IF NOT EXISTS lazer_ranked_matches (
    room_id INTEGER PRIMARY KEY CHECK(room_id > 0),
    ruleset_id INTEGER NOT NULL CHECK(ruleset_id BETWEEN 0 AND 3),
    winner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    loser_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    winner_rating_before INTEGER NOT NULL,
    winner_rating_after INTEGER NOT NULL,
    loser_rating_before INTEGER NOT NULL,
    loser_rating_after INTEGER NOT NULL,
    completed_at INTEGER NOT NULL DEFAULT (unixepoch()),
    CHECK(winner_id != loser_id)
);
CREATE INDEX IF NOT EXISTS lazer_ranked_matches_users
    ON lazer_ranked_matches(winner_id, loser_id, completed_at DESC, room_id DESC);

PRAGMA user_version=39;
COMMIT;
