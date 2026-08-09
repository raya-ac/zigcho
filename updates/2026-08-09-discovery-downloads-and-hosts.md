**zigcho update — the old osu! hosts exist now**

I added the local beatmap path that both clients were missing. Stable Direct can search the maps we actually have, look up a set, and download its real `.osz`. Lazer can search the same catalog, read beatmapset metadata, download the same archive, and fetch the original `.osu` file. The server stores the real circle, slider, and spinner counts now too.

Archives go through a separate operator importer. It checks the ZIP shape, size, entries, and SHA-256 before putting anything in SQLite. A map without an archive is not advertised as downloadable. I would rather return a real 404 than hand the client an empty file and call it support.

I also mapped the old osu! host split under `kai.ovh`: the `c` relays, asset names, beatmap names, API names, spectator, and submission host. Their browser roots get one small zigcho page with the host's actual role and a moving boat. IRC is not in the list because it is TCP, not another website, and I am not pretending a TLS name solves that.

**how far off are we?**

Still about 34% of the way to an invite-only alpha. Login, chat, presence, scores, replays, leaderboards, real PP, local map search, and downloads now have working server paths. Full client runs, upstream map syncing, multiplayer, lazer realtime state, moderation, backups, and operator tooling are still between this and a server I would put in front of players.
