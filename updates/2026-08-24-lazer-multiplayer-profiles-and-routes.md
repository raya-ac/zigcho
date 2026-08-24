# zigcho release 1

this is the first release where i am treating zigcho as one actual thing instead of a pile of Stable fixes, lazer fixes and website bits that happened to share a database. Stable still works, lazer has the normal player surface it kept tripping over, and the website is reading the same state instead of making up its own version of it. `release 1` is the name of the whole server release. the downloadable lazer client inside it is still technically `0.1.0-alpha.14` because i am not breaking its update line just to make the announcement look cleaner.

## multiplayer is a real lifecycle now

playlist rooms finally start with the time shown on the button. the countdown moves, the current item changes at the right point, attempts update while the room is running, and the room closes into finished history when everybody leaves instead of sitting on the website forever. normal rooms, playlists, Quick Play and ranked duels now share one typed state rather than four slightly different guesses about what a room is doing.

room settings, team modes, slots, host changes, queues, invites, match requests, rolls, skips and countdowns all go through the same checked state. expired invites actually expire. reconnecting replaces the old SignalR socket without duplicating the player, stealing the room, or letting the old disconnect remove the new connection. logging in from Stable while lazer is open, or lazer while Stable is open, detaches the old room and spectator state before the new session is allowed to carry on.

ranked results and ratings are stored instead of disappearing with the room. finished rooms keep their participants, playlist, results and score history, so the website can show a completed match instead of loading forever. clean shutdowns checkpoint live rooms and restore them after a restart. passwords and score tokens are not written into public room JSON or sent back through the website.

## room scoring stopped being loose

a multiplayer score token belongs to the exact player, room and playlist item that asked for it. it cannot be borrowed by another player, reused for another map, or quietly turn into a normal solo token if part of the room path fails. closing a room stops new tokens being minted. a play that genuinely started before the close still gets five minutes to finish, and that late result is written back into the archived room instead of becoming an orphan score.

lost success responses can be retried without creating a second score. consumed tokens remember the score they produced, so the same request gets the same result while a changed request is rejected. playlist and realtime eligibility stay separate when a late score is rebuilt. failed realtime attempts remain visible to the room without becoming fake normal-room bests.

room leaderboards now keep one eligible best per player, return the correct position, support scores-around and per-user high score requests, and keep enough attempts for a full sixteen-player playlist instead of silently dropping everything after 128 plays. every client-controlled MessagePack number is range checked before it gets narrowed into room state. allocation failures roll create, join, archive and score operations back rather than leaving a ghost player, a live token with no owner, or half a room in the database.

## profiles and presence agree everywhere

combined, Stable, lazer and Stable ScoreV2 views stay separate where the score systems differ and combine where the player stats are meant to be shared. all four rulesets are returned in multiplayer user batches, lookup uses the requested ruleset rank, and upstream mapper profiles keep their real public identity without being turned into local users. fake rank-history points are gone; if zigcho did not record the history, the graph says tracking starts now.

profile privacy applies to the API as well as the page. recent plays, stats, country and the other private sections are removed at the source instead of being hidden with CSS. pins keep their real order and best state. roles, teams, flags, banners, first places, activity, play time and the online client all come from the same user contract.

the lazer profile view now uses the real medal image URL returned by the server, keeps the server achievement data, and falls back to kai avatar/media hosts instead of wandering back to ppy assets when a local image is missing. kai is user id 3 everywhere, shows as the online bot, has a public bot profile without fake stats, and no longer looks like a broken offline player.

## sessions, chat and the bot got cleaned up

access and refresh tokens now belong to one game-session pair. refresh rotation is atomic, password login replaces the old game pair, and `/oauth/revoke` only revokes the pair that asked. a delayed logout from an old client cannot sign the replacement client out. a hidden Stable takeover session cannot keep authorising scores, receiving DMs, appearing online or broadcasting presence after lazer has replaced it.

session takeover sends one disconnect, not a loop of them. interrupted lazer presence emits the matching Stable logout once, and the new client owns the visible activity. Stable direct messages stay unread until the packet is actually polled rather than being marked read while a response is still being built. `#osu`, `#announce`, room chat, direct messages and the website all use the same stored history. score announcements belong in `#announce`; kai does not DM people every time somebody sets a play.

## the missing client surface is actually mapped

the pinned lazer source has 86 request targets mapped with no missing or placeholder entries. that includes registration, OAuth, `/me`, user batches, lookups, all-ruleset profiles, score pages, rankings, country and spotlight boards, maps, full set metadata, listing/search, favourites, tags, downloads, BSS, comments, reports, friends, blocks, notifications, chat, presence, spectator, multiplayer, news, wiki, changelog and logout.

news and wiki routes now return something the client can actually render instead of a friendly `200` that happens to be the wrong shape. the website changelog uses the same release history as the in-game page. changelog content now comes from the public raw GitHub markdown feed, cached by Zigcho with its last good copy kept available, so writing the next update does not mean rebuilding a client just to change some words.

the client patch also makes logout call the real revoke route, preserves server medal URLs, renders a populated medals section, and uses the kai media fallbacks for profile art. the patch is checked against the exact pinned osu commit before any platform build starts.

## the data survives the boring failures

schema 39 stores ranked ratings and match results. schema 40 fixes room-channel read tracking so persistent multiplayer chat does not collide with the normal channel ids. SQLite and PostgreSQL implement the same contracts, including room archives, consumed score tokens, user/ruleset batches, profile privacy and ranked state.

shutdown snapshots are bounded, owned data. failed archives have their own bounded retry queue instead of borrowing a room slot that another create can reuse. archive retry is serialized, reconnect work is scoped to the connection it belongs to, and socket sends do not hold one global multiplayer gate over every other room. the allocation-failure tests walk the credential, session, profile, room, archive and score ownership paths instead of only testing the happy result.

the release script was tightened too. it still makes a PostgreSQL backup and proves that backup can restore, but the candidate can no longer migrate the live database while the old server is running. production is stopped first, rollback becomes active, then the candidate check is allowed to move the schema. if anything after that fails, the previous release and its database come back together.

## what is shipping

the server is built once from the exact pushed commit by the pinned Linux container. Debug, ReleaseSafe and PostgreSQL gates run before that artifact can be deployed. the deployed executable has to match the runner hash, schema 40 has to be valid, all public hosts have to answer, and the actual website pages get opened after activation instead of calling a health JSON enough.

GitHub builds the same pinned lazer patch for Windows x64, macOS arm64, Linux x64, Android arm64 and unsigned iOS arm64. every package carries the Zigcho commit and osu commit it came from and gets its own checksum. nothing is built on my Mac. there is no installer or signing gate hiding behind this; the portable runner packages are the release for now.

raw IRC is not being smuggled around Cloudflare by exposing the origin. the listener and bridge code stay available, but the public TCP edge waits for a proper Spectrum or separate relay setup. everything in this announcement is the part that is actually built, tested and released.
