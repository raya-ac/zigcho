# stable is live now

I am calling the Stable side done. not "the health endpoint is green" done — the actual client, website, database, map service, staff tools, backups, and release path have been run together.

map hydration no longer needs an osu API key. Nerinyan gives us the metadata, Akatsuki serves the archive first, Nerinyan is the fallback, and zigcho checks the exact map checksum before it stores or ranks anything. the real upstream smoke pulled a ranked set, found the requested difficulty inside the archive, stored the `.osu`, and served the finished Stable leaderboard response.

accounts now use the same Stable username, email, and credential rules everywhere. imported names and countries cannot break JSON, forwarded IP and country headers are only trusted from the loopback proxy, and reconnects use indexed session ownership instead of scanning every player. a completely empty PostgreSQL database also boots properly with kai as ID 3, the right staff colour and permissions, every stats mode, and the real chat channels.

the website got its last annoying mobile fix too. long map and difficulty names stay inside the page, mods stay visible, failed scores are still red, flags are flags, and pinned, top, and recent plays keep their own sections.

the final source passed 121/121 in Debug and 121/121 in ReleaseSafe with fresh PostgreSQL databases. registration/staff/web smoke passed, the real map-provider smoke passed, and the pinned x86_64 Linux container built the ReleaseSafe PostgreSQL binary and booted it against another empty database at schema 19.

lazer and BSS were not dragged into this. they stay parked until the Stable release has had time in front of real players.
