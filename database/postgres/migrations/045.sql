BEGIN;
CREATE TABLE zigcho.server_controls(
    key text PRIMARY KEY CHECK(key IN('registrations','stable_login','lazer_login','stable_scores','lazer_scores','lazer_multiplayer','spectator','bss','beatmap_downloads','website_writes')),
    enabled boolean NOT NULL DEFAULT true,
    reason text NOT NULL DEFAULT '' CHECK(length(reason)<=500),
    updated_by integer REFERENCES zigcho.users(id) ON DELETE SET NULL,
    updated_at bigint NOT NULL DEFAULT (extract(epoch FROM clock_timestamp())::bigint)
);
INSERT INTO zigcho.server_controls(key) VALUES('registrations'),('stable_login'),('lazer_login'),('stable_scores'),('lazer_scores'),('lazer_multiplayer'),('spectator'),('bss'),('beatmap_downloads'),('website_writes');
INSERT INTO zigcho.schema_migrations(version) VALUES(45);
COMMIT;
