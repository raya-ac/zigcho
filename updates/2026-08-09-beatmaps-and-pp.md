**zigcho update — beatmaps and real PP**

I added the first real performance path. Stable standard scores now use the exact `.osu` file stored by the server and a pinned `rosu-pp` 4.0.1 build. Missing, malformed, suspicious, or uncalculable maps fail closed instead of writing fake or zero PP.

There is a local beatmap importer now. It stores the map metadata, difficulty values, stars, max combo, MD5, and original file in SQLite. Maps default to pending and only affect ranked score and PP when I deliberately mark them ranked or approved. Normal ranked plays update weighted player PP. Relax PP stays out of normal stats.

The locked standard fixture is 1.7931 stars and 26.80pp. Taiko, catch, mania, and lazer still need their own fixtures before those paths can award PP.

**how far off are we?**

The production service and core stable login, chat, presence, scores, replays, leaderboards, accounts, and tokens exist. I would call it about one third of the way to an invite-only player alpha, not ready for an open launch. Beatmap search/downloads, real stable+lazer client runs, complete multiplayer, moderation/backups/metrics, and the custom lazer rooms/client work are still the large blocks.
