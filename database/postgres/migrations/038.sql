BEGIN;

ALTER TABLE zigcho.direct_messages ADD COLUMN chat_message_id bigint;

WITH direct_ranked AS (
    SELECT
        id,
        from_id,
        to_id,
        message,
        is_action,
        client_uuid,
        created_at,
        row_number() OVER (
            PARTITION BY from_id,to_id,message,is_action,client_uuid,created_at
            ORDER BY id
        ) AS ordinal
    FROM zigcho.direct_messages
),
chat_ranked AS (
    SELECT
        id,
        sender_id,
        target,
        message,
        is_action,
        client_uuid,
        created_at,
        row_number() OVER (
            PARTITION BY sender_id,target,message,is_action,client_uuid,created_at
            ORDER BY id
        ) AS ordinal
    FROM zigcho.chat_messages
    WHERE target LIKE '@dm:%'
)
UPDATE zigcho.direct_messages destination
SET chat_message_id=chat.id
FROM direct_ranked ranked
JOIN chat_ranked chat
  ON chat.sender_id=ranked.from_id
 AND chat.target='@dm:'||least(ranked.from_id,ranked.to_id)||':'||greatest(ranked.from_id,ranked.to_id)
 AND chat.message=ranked.message
 AND chat.is_action=ranked.is_action
 AND chat.client_uuid=ranked.client_uuid
 AND chat.created_at=ranked.created_at
 AND chat.ordinal=ranked.ordinal
WHERE destination.id=ranked.id;

CREATE UNIQUE INDEX direct_messages_chat_message ON zigcho.direct_messages(chat_message_id) WHERE chat_message_id IS NOT NULL;
ALTER TABLE zigcho.direct_messages
    ADD CONSTRAINT direct_messages_chat_message_id_fkey
    FOREIGN KEY(chat_message_id) REFERENCES zigcho.chat_messages(id) ON DELETE CASCADE;

INSERT INTO zigcho.schema_migrations(version) VALUES(38);
COMMIT;
