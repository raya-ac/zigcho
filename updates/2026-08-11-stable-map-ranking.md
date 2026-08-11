# stable has a real map review queue now

players can send the set they are playing into review with `!request`. BN+ can see the queue, nominate it, veto it, qualify it after two different people have signed off, then rank or love it with a reason. every action applies to the whole set and stays in the review history. a later beatmap refresh cannot quietly put a staff-ranked map back into pending, and admins can roll a bad change back without pretending it never happened.

ranking a map is not just a status number anymore either. zigcho rebuilds ranked score, weighted PP, accuracy, and combo from the scores already stored on that set. rolling it back removes those scores from ranked stats again. that work is inside the same transaction as the status change, so the map and player stats cannot land on opposite sides of an interrupted update.

i fixed the score result beside it. Stable now gets the actual committed map rank and updated overall stats after a pass instead of the generic retry response that left the result at zero. kai sends the same eligible play to `#announce` in game and Discord. both use the visible leaderboard result now: it has to become that player's best, stay inside the top 50, and either be top 10 or at least 500pp. a worse retry does not get announced just because it was accepted or had a large calculated pp value.

the Debug and ReleaseSafe suites cover the whole request, nomination, veto, qualify, rank, love, and rollback path in SQLite and real PostgreSQL. i also upgraded the exact schema currently deployed, rebuilt stats in both directions, checked Stable's wire status and score chart, copied all 18 tables through the importer with matching blob bytes, and proved a repeated import is rejected.

this puts Stable around 79% of the way to the invite-only build. the server-side multiplayer and spectator runs are already green. the big remaining pieces are the connected player/staff website, proper backup and restore operations, and the final installed-client pass over chat, ranking, and score announcements before anybody else gets invited. lazer is still frozen until that Stable gate is done.
