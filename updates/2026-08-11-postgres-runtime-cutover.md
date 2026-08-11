postgres is actually running the server now

this is the other half of the database work. every Store call used by bancho, account creation, the score worker, map sync, the bot, Direct, ratings, OAuth, avatars, and the existing lazer API has a PostgreSQL version now. the production binary is built with that backend and refuses to quietly fall back to SQLite.

I kept the behavior people can already see. Stable pass, fail, and Relax plays went through the real PostgreSQL transaction tests. failed plays only add total score, playcount, play time, and hits. replay and map files come back byte-for-byte. country and mod boards, personal bests, duplicate scores, password upgrades, exact HWID restrictions, and token scopes are still part of the same contract.

the stopped version 12 SQLite database was copied once with the importer from the last update. all 13 table counts and stored blob bytes were compared before the import committed. PostgreSQL is the only live writer after the switch, while that SQLite file and the previous release stay untouched for rollback.

I also fixed the schema bootstrap so applying it directly cannot accidentally put the tables in `public`, and connection resets no longer hold the whole pool lock while libpq waits on the network.

Stable is still the lane I am finishing. the next work is the proper player and staff chat suite, moderation and audit commands, then the BN+ ranking flow and the website on top of this database. lazer feature work is still frozen.

I would put the invite-only Stable server around 82% now. it is still a Debug alpha, but SQLite is not sitting underneath every login and score anymore.
