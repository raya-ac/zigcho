**zigcho update — player pages actually feel connected now**

account settings have the stuff they were missing: a profile title, pronouns, location, website, accent, default mode and proper privacy controls. roles do not get flattened into one label anymore either, so developer, admin, BN and supporter can all show at the same time without making the page a mess.

beatmap pages have their own leaderboard for every difficulty and score lane now. it keeps Stable, lazer, ScoreV2, Relax and Autopilot in the right namespaces, shows the mods and gives every play its real map rank. previews play on the page instead of opening the mp3 in another tab.

stored Stable replays can be downloaded as actual `.osr` files from profiles and map leaderboards. failed scores still show clearly, but downloads are only offered for passed plays that really have replay data; restricted players stay private too.

the profile privacy switches are enforced by the API, not hidden with css. I ran the whole thing through SQLite and PostgreSQL in Debug and ReleaseSafe, then checked the real desktop and phone layouts in a browser.
