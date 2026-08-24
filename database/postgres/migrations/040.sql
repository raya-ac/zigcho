BEGIN;

ALTER TABLE zigcho.lazer_channel_reads
    DROP CONSTRAINT lazer_channel_reads_channel_id_check,
    ALTER COLUMN channel_id TYPE bigint;
ALTER TABLE zigcho.lazer_channel_reads
    ADD CONSTRAINT lazer_channel_reads_channel_id_check CHECK (
        channel_id BETWEEN 1 AND 4 OR
        channel_id BETWEEN 2000000001 AND 2147483647
    );

INSERT INTO zigcho.schema_migrations(version) VALUES(40);
COMMIT;
