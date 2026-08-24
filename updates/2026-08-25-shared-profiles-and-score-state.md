# zigcho release 1.1

this is mostly the update where Stable, lazer and the website stop keeping three slightly different stories about the same player. friends, followers, replay views, score totals and profile history now come from shared state, while the bits that genuinely belong to one client stay separate.

## friends and followers are actually shared

Stable's friend list and lazer's follow routes now use the same directional relationships. following somebody in one client shows up in the other, mutual friends still mean both players followed each other, and kai stays in the Stable list without pretending to be a normal follow. restricted players, self-follows, missing users and attempts to follow kai are rejected instead of leaving junk rows behind.

the website now shows the real inbound follower count. it is returned consistently in profile, batch-user and compact-user responses, and privacy/restriction checks happen in the query rather than hiding a number after it has already leaked.

## replay views finally mean somebody watched a replay

Stable and lazer replay downloads now write into one replay-view ledger. the same viewer can only count once for the same play, watching your own replay does not count, failed plays cannot be downloaded, and a request only records a view after the replay bytes were actually found. this also works for replays that have already moved into object storage and for Stable plays opened through lazer's projected score ids.

profiles, rankings and the website show the combined Stable + lazer total while the Stable and lazer score tabs keep their own counts. replay downloads from the website and both game clients all feed the same number now.

## profiles stopped making history up

rank history is stored when score, restriction or map-status state actually changes. opening a profile no longer makes the server rebuild ninety days of pretend history from today's map statuses and today's pp. if zigcho did not record an old day, the graph is honest and says tracking starts now.

the current day stays live, old days stay frozen, and history older than ninety days gets removed. the website can switch between rank and pp on the same graph, followers and replay views sit with the profile stats, and combined boards pick a player's higher-pp Stable or lazer play instead of comparing two score systems that do not use the same scale.

## native and legacy score values are not the same field anymore

schema 43 splits lazer's native total score, score without mods and optional legacy score. native score submission cannot overwrite legacy-backed player stats anymore, and old schema-42 rows migrate without turning one value into all three. Stable plays still expose their real legacy score on the website; lazer plays show native score for the play and only show a legacy value when the client actually supplied one.

profile plays, first places, pins, recent plays and beatmap leaderboards now carry the same explicit fields in SQLite and PostgreSQL. the website labels Stable score and native score properly, shows the without-mods value for lazer, and keeps legacy scoring for the combined level and player-stat totals.

## finished multiplayer rooms keep their last scores

a score that finishes during the allowed post-room grace period now restores the archived playlist before rebuilding the room leaderboard. it cannot replace a valid archive with an empty board just because the live room object is gone. ended playlist rooms also keep their real ruleset ids in listings after every item has expired, so filtering by osu!, taiko, catch or mania does not make finished rooms disappear.

the archive path stays serialized away from the live room lock and keeps the existing token, participant and eligibility checks. the late-score tests now start with an existing leaderboard and prove it survives the update.

## country flags are images now

the website was building country flags out of regional emoji characters. Apple happened to render that as a flag, while Chrome and quite a few Windows/browser combinations just showed `AU`, `NZ` and the rest as plain letters. every profile, ranking, leaderboard, team and staff surface now uses the real osu flag PNG instead.

the images have a fixed size, safe unknown-country fallback and the correct content policy. i opened the built site in Chrome and checked the actual decode: the AU and NZ files loaded, rendered as flags, produced no console errors and left no country-code text sitting beside the player.

## the database gate got less trusting

PostgreSQL connections are returned to the pool in a clean idle state. if a future request forgets to close a transaction, the pool rolls it back before that connection can leak state into somebody else's request. the release gate now runs that regression alongside the full schema-43 Store, migration, BSS, room/chat and ranked-play databases.

this is a server and website update. it does not move the pinned lazer package past alpha.14, and it does not pretend the hidden-origin IRC edge is live. the parts above are the parts shipping.
