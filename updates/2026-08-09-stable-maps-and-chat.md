**zigcho update — maps load now and chat stops saying everything twice**

Stable was calling every map unsubmitted because production had zero maps. Zigcho now fills a missing map the moment the client asks for its leaderboard. It looks the MD5 up through Nerinyan, downloads the set, extracts the exact `.osu`, checks the ZIP CRC, MD5, map ID and set ID, calculates the map, then stores the map and archive locally. A mismatch stays unsubmitted. There is no osu! API key in this build.

I proved it from an empty database with Nerinyan's real map 75. The client response came back ranked, the exact map file landed under the expected hash, and the set was cached for downloads.

Public chat also stops echoing the sender's message back through Bancho, which was the extra copy. The missing stable seasonal and menu-content requests return proper empty data now too.

We are about 44% of the way to an invite-only alpha. The next proof is this exact build in the installed stable client on `osu.kai.ovh`, then upstream timeout/retry controls, a real score submission on a hydrated map, wider mode fixtures, moderation, backups, multiplayer, and the rest of lazer's signed-in path.
