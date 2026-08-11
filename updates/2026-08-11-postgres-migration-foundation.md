postgres has a real way in now

the live server is still using SQLite in this update. I am not swapping the database under bancho while half its storage calls still speak SQLite. this is the part that makes the cutover measurable instead of hoping the copy worked.

there is a proper PostgreSQL schema under its own `zigcho` namespace now, plus a hard eight-connection libpq pool. `zigcho-migrate-postgres` opens a stopped version 12 SQLite database read-only, checks its integrity and foreign keys, and refuses a PostgreSQL target that was already used.

all 13 tables copy inside one serializable transaction. the importer resets the identity sequences, compares every table count, and compares all stored blob bytes before it commits. replays, map files, archives, tokens, and password data are included in that check. if anything fails, the PostgreSQL side rolls back instead of leaving a half-migrated server.

I ran a fixture containing every table through it. the replay came back byte-for-byte, PostgreSQL stored the intended boolean/jsonb/bytea types, and a second import was rejected. the bounded pool was tested with more workers than available connections too.

stable multiplayer and spectating are accepted for this alpha, so they are not holding the rest up anymore. the next phase is porting the live runtime calls and doing the stopped database cutover with SQLite kept as rollback. after that: the full chat/admin commands, BN+ ranking, and the player site.

I would put the invite-only Stable server around 79% now. this is still a Debug alpha, and the live process does not become PostgreSQL-backed until the next phase passes the same real public checks.
