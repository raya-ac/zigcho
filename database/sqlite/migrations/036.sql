BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS lazer_multiplayer_room_history(
    room_id INTEGER PRIMARY KEY CHECK(room_id>0),
    owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    category TEXT NOT NULL CHECK(category IN('normal','realtime','spotlight','featured_artist')),
    room_json TEXT NOT NULL CHECK(json_valid(room_json) AND json_type(room_json)='object'),
    leaderboard_json TEXT NOT NULL CHECK(json_valid(leaderboard_json) AND json_type(leaderboard_json)='object'),
    participant_ids_json TEXT NOT NULL CHECK(json_valid(participant_ids_json) AND json_type(participant_ids_json)='array'),
    ended_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS lazer_multiplayer_room_history_owner ON lazer_multiplayer_room_history(owner_id,ended_at DESC,room_id DESC);
CREATE INDEX IF NOT EXISTS lazer_multiplayer_room_history_time ON lazer_multiplayer_room_history(ended_at DESC,room_id DESC);

PRAGMA user_version=36;
COMMIT;
