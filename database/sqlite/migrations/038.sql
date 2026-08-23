BEGIN IMMEDIATE;

ALTER TABLE direct_messages ADD COLUMN chat_message_id INTEGER;

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
    FROM direct_messages
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
    FROM chat_messages
    WHERE target LIKE '@dm:%'
)
UPDATE direct_messages
SET chat_message_id = (
    SELECT chat_ranked.id
    FROM direct_ranked
    JOIN chat_ranked
      ON chat_ranked.sender_id=direct_ranked.from_id
     AND chat_ranked.target='@dm:'||min(direct_ranked.from_id,direct_ranked.to_id)||':'||max(direct_ranked.from_id,direct_ranked.to_id)
     AND chat_ranked.message=direct_ranked.message
     AND chat_ranked.is_action=direct_ranked.is_action
     AND chat_ranked.client_uuid=direct_ranked.client_uuid
     AND chat_ranked.created_at=direct_ranked.created_at
     AND chat_ranked.ordinal=direct_ranked.ordinal
    WHERE direct_ranked.id=direct_messages.id
)
WHERE EXISTS (
    SELECT 1
    FROM direct_ranked
    JOIN chat_ranked
      ON chat_ranked.sender_id=direct_ranked.from_id
     AND chat_ranked.target='@dm:'||min(direct_ranked.from_id,direct_ranked.to_id)||':'||max(direct_ranked.from_id,direct_ranked.to_id)
     AND chat_ranked.message=direct_ranked.message
     AND chat_ranked.is_action=direct_ranked.is_action
     AND chat_ranked.client_uuid=direct_ranked.client_uuid
     AND chat_ranked.created_at=direct_ranked.created_at
     AND chat_ranked.ordinal=direct_ranked.ordinal
    WHERE direct_ranked.id=direct_messages.id
);

CREATE UNIQUE INDEX direct_messages_chat_message ON direct_messages(chat_message_id) WHERE chat_message_id IS NOT NULL;

PRAGMA user_version=38;
COMMIT;
