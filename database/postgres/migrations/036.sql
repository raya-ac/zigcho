BEGIN;

CREATE TABLE zigcho.lazer_multiplayer_room_history(
    room_id bigint PRIMARY KEY CHECK(room_id>0),
    owner_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE RESTRICT,
    category text NOT NULL CHECK(category IN('normal','realtime','spotlight','featured_artist')),
    room_json jsonb NOT NULL CHECK(jsonb_typeof(room_json)='object'),
    leaderboard_json jsonb NOT NULL CHECK(jsonb_typeof(leaderboard_json)='object'),
    participant_ids_json jsonb NOT NULL CHECK(jsonb_typeof(participant_ids_json)='array'),
    ended_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint)
);
CREATE INDEX lazer_multiplayer_room_history_owner ON zigcho.lazer_multiplayer_room_history(owner_id,ended_at DESC,room_id DESC);
CREATE INDEX lazer_multiplayer_room_history_time ON zigcho.lazer_multiplayer_room_history(ended_at DESC,room_id DESC);

INSERT INTO zigcho.schema_migrations(version) VALUES(36);
COMMIT;
