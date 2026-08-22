PRAGMA defer_foreign_keys=ON;
BEGIN IMMEDIATE;

CREATE TEMP TABLE _zigcho_id3_rehome(new_id INTEGER NOT NULL);
INSERT INTO _zigcho_id3_rehome
SELECT coalesce(max(id),0)+1 FROM users
HAVING EXISTS(SELECT 1 FROM users WHERE id=3 AND safe_name!='kai');

UPDATE stats SET user_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE user_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE scores SET user_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE user_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE friends SET user_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE user_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE friends SET friend_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE friend_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE favourites SET user_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE user_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE ratings SET user_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE user_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE audit_log SET actor_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE actor_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE lazer_scores SET user_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE user_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE oauth_tokens SET user_id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE user_id=3 AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
UPDATE users SET id=(SELECT new_id FROM _zigcho_id3_rehome) WHERE id=3 AND safe_name!='kai' AND EXISTS(SELECT 1 FROM _zigcho_id3_rehome);
DROP TABLE _zigcho_id3_rehome;

CREATE TEMP TABLE _zigcho_kai_source(old_id INTEGER NOT NULL);
INSERT INTO _zigcho_kai_source SELECT id FROM users WHERE safe_name='kai' AND id!=3;
UPDATE stats SET user_id=3 WHERE user_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE scores SET user_id=3 WHERE user_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE friends SET user_id=3 WHERE user_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE friends SET friend_id=3 WHERE friend_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE favourites SET user_id=3 WHERE user_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE ratings SET user_id=3 WHERE user_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE audit_log SET actor_id=3 WHERE actor_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE lazer_scores SET user_id=3 WHERE user_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE oauth_tokens SET user_id=3 WHERE user_id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
UPDATE users SET id=3,name='kai',safe_name='kai' WHERE id=(SELECT old_id FROM _zigcho_kai_source) AND EXISTS(SELECT 1 FROM _zigcho_kai_source);
DROP TABLE _zigcho_kai_source;

INSERT OR IGNORE INTO users(id,name,safe_name,password_hash,password_salt,country,privileges,restricted)
VALUES(3,'kai','kai',x'','system','XX',3,0);
INSERT OR IGNORE INTO stats(user_id,mode) VALUES(3,0),(3,1),(3,2),(3,3),(3,4),(3,5),(3,6),(3,8);

COMMIT;
PRAGMA user_version=9;
