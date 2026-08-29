BEGIN;

CREATE TABLE zigcho.stable_score_sessions (
    token_hash bytea PRIMARY KEY CHECK(octet_length(token_hash)=32),
    user_id integer NOT NULL REFERENCES zigcho.users(id) ON DELETE CASCADE,
    version_date char(8) NOT NULL CHECK(version_date ~ '^[0-9]{8}$'),
    hardware_digest bytea NOT NULL CHECK(octet_length(hardware_digest)=32),
    issued_at bigint NOT NULL,
    grace_expires_at bigint,
    consumed_at bigint,
    submission_checksum char(32) CHECK(submission_checksum ~ '^[0-9a-f]{32}$'),
    revoked_at bigint,
    CHECK(grace_expires_at IS NULL OR grace_expires_at BETWEEN issued_at AND issued_at+900),
    CHECK((consumed_at IS NULL)=(submission_checksum IS NULL)),
    CHECK(consumed_at IS NULL OR grace_expires_at IS NOT NULL),
    CHECK(consumed_at IS NULL OR consumed_at>=issued_at),
    CHECK(revoked_at IS NULL OR revoked_at>=issued_at)
);
CREATE UNIQUE INDEX stable_score_sessions_one_current
    ON zigcho.stable_score_sessions(user_id)
    WHERE grace_expires_at IS NULL AND revoked_at IS NULL;
CREATE INDEX stable_score_sessions_user_grace
    ON zigcho.stable_score_sessions(user_id,grace_expires_at DESC,issued_at DESC);

INSERT INTO zigcho.schema_migrations(version) VALUES(47);
COMMIT;
