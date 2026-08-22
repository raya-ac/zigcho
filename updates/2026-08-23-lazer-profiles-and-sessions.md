# zigcho is pretty much finished now

this one is massive. Stable has been the bit i trust for a while, but lazer was still the awkward half that worked until it found one route we had not finished. that is mostly gone now. it is a proper second client on the same server, not a pile of endpoints trying to look like one.

the annoying offline login thing has had a proper fix. lazer gets rotating one-use refresh tokens, can close and come back later, and cannot use a refresh token as a normal API token. if the same account moves between Stable and lazer, the old game session is actually closed. the site shows the one client they are on, what they are doing and the map they are playing. kai stays online as id 3, but its profile just says it is the bot instead of making up scores for it.

profiles finally agree everywhere. combined stats use the right legacy score and whichever play has more pp, while Stable and lazer still keep their own play tabs. recent, top, pinned and first-place plays work with medals, ranks, roles, teams, country, play time, activity and banners in the site and the lazer profile view. uploads were also being stupid. banners and team images are resized before upload now, bad files return the actual reason, and missing images stop turning into slow broken links.

score stuff has had another full cleanout. Stable Classic, lazer, Relax and Autopilot keep their own identities. exact mod filters are exact, the normal board combines the mods we accept, and a worse play cannot steal a user's place just because its raw score is strange. custom DT and NC rates keep their real speed. replays only get a download when there is a real replay we are allowed to give back. score submits update the correct stats, rank panel, achievements and announcements, including fails without pretending the fail passed.

chat is not three fake systems anymore. Stable, lazer, the website, DMs, kai commands and IRC use the same history and moderation rules. score posts go in `#announce`, not into some random kai DM. rooms, invites, room scores, Quick Play, ranked duels and live spectating all have their actual REST and realtime paths too.

BSS is here for lazer as well. premium users can reserve map ids, upload a full set or patch one, keep ownership of their set and send WIP or Pending maps into the same BN queue as the rest of the server. it is still lazer-only and it does not mess with Stable's map or score rules.

i also finally cleaned the repo up. schema 34 matches between SQLite and PostgreSQL, every schema and migration is under `database/` instead of being dumped through `src/`, object backups are restore-tested and read back before the local copy goes, and IRC has proper release files. the in-game changelog has the full checked-in history now instead of randomly forgetting most of it.

the client says `zigcho!lazer` everywhere the player can see it. GitHub builds Windows x64, Apple Silicon macOS, Linux x64, Android arm64 and an unsigned iOS arm64 build from the same pinned osu commit. not my mac. not anybody's laptop.

i am calling the server itself pretty much finished at this point. what is left is running every packaged client path against production and fixing the real bugs that finds. we are past the part where an entire foundation is missing.
