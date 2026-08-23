BEGIN;

ALTER TABLE zigcho.beatmap_media
    DROP CONSTRAINT beatmap_media_content_type_check,
    DROP CONSTRAINT beatmap_media_data_check;
ALTER TABLE zigcho.beatmap_media
    ADD CONSTRAINT beatmap_media_content_type_check CHECK(content_type IN (
        'image/jpeg','image/png','image/gif',
        'audio/ogg','audio/mpeg','audio/wav'
    )),
    ADD CONSTRAINT beatmap_media_data_check CHECK(
        data IS NULL OR
        (content_type LIKE 'image/%' AND octet_length(data) BETWEEN 1 AND 16777216) OR
        (content_type LIKE 'audio/%' AND octet_length(data) BETWEEN 1 AND 33554432)
    );

INSERT INTO zigcho.schema_migrations(version) VALUES(37);
COMMIT;
