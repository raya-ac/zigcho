# zigcho

I'm building an osu! server in Zig because I want something small enough to understand properly, but still capable of running as a real server. The target is stable and a custom lazer client, one local account system, relax, custom lazer mods, multiplayer, spectating, leaderboards, and the boring production work that usually gets left until last.

It is not connected to official osu! accounts. When I say stable and lazer share an account, I mean both clients log into the same account on this server and use the same user ID, punishments, friends, and stats.

This is not ready to put in front of players yet. I would rather leave that sentence here than pretend a green health endpoint means the server is done.

Stable is the active lane now. I am finishing its real client contract before adding anything else to lazer. The existing lazer API stays available, but new lazer work is frozen unless stable needs shared code underneath it.

## where it's at

The Bancho side can parse protocol 19 packets, log stable clients in, issue tokens, track presence and status, handle joined public channels and private messages, answer presence/stat requests, and relay spectator frames. Multiplayer has real room and play state now: stable can discover rooms in the lobby, create or join passworded rooms, invite another player, use room chat, move and lock slots, transfer host, change teams and freemods, update the selected map, kick players, start the map, wait for everybody to load, relay score frames and failures, skip together, finish or abort the round, and clean rooms up when the last player leaves. Hosts can add and remove room referees through `!mp`; referees can abort a broken round and everybody gets the real abort packet plus the reset room state. Supporters can use the tournament client to read a room without taking a player slot, and they receive its chat, state, and live play packets. The server-side stable multiplayer contract is covered now, but I am not calling it client-complete until the real two-client run passes. Chat is delivered once to the people actually inside the channel instead of being sprayed at every session. Real logout removes the session and tells everyone else; clients that stop polling expire after osu!'s five-minute ping window. Each outgoing session queue is capped at 1 MiB. If a dead client falls behind far enough to hit it, that session is removed and sent through the normal restart/reconnect path instead of owning memory forever. Login does not hold the whole server's session list while Argon2 or SQLite runs. It copies a short owned view of online sessions, releases the lock, then builds the login response and loads stats from that snapshot. The response owns its token too, so a reconnect cannot free the memory backing an HTTP header. `kai` is the always-online system account at user ID 3; it can answer private messages with PP calculations (`!np` for current map, `!with HDHR 98% 5m` for custom scenarios) and automatically PMs you the PP when you `/np` in-game. User-stat packets come from the selected mode's SQLite row on login, status requests, and after a submitted score instead of returning placeholder zeros.

Score submissions are async. Validation — decrypt, checksum, auth, beatmap lookup, PP calc — runs on the request thread. The database write, stats update, and webhook POST run in a detached background thread with one owned score object and one cleanup path. Every request-backed string, replay byte, and map byte stays alive until that worker is finished, including failure paths before the thread starts. The client gets its response immediately. The webhook posts to Discord for top-10 or 500+ PP plays and is fire-and-forget — each submission spawns a detached thread with its own HTTP client so the score response is never blocked by Discord's latency. The webhook URL lives in `config.ini` under `score_webhook`, is copied into server-owned memory at startup, and is not in the repository.

Stable logins keep the validated two-letter country Cloudflare saw. On the first login I look up the client IP through `ip-api.com` and store longitude and latitude in the session. Presence packets carry both coordinates so other clients can see where players actually are. Unknown or missing locations stay `XX` instead of inventing one.

Accounts get one random anime default from the bundled avatar set. The choice is stored instead of changing on every refresh. Stable loads it from `https://a.kai.ovh/{user_id}`, and lazer gets the same URL in `/api/v2/me`. Unknown user IDs return `404` instead of getting a fake profile.

Stable's in-game account form uses its real two-request contract. `check=1` validates the username, email, and password without writing anything; `check=0` creates the account. Both successful stages return the plain `ok` response stable expects, while field problems use its nested `form_error` JSON. Lazer keeps its separate one-request registration response.

Stable score submission uses the actual Rijndael cipher with a 32-byte block. The server parses both multipart `score` fields, decrypts the score and client hash, checks the online checksum, verifies the online player and password using bancho.py's real contract, stores the replay, and updates player and beatmap counters in one transaction. Multipart boundaries have to match the complete delimiter and suffix, so boundary-looking bytes inside a binary replay stay replay bytes. Hit counts, combo, and total score are bounded before any calculation, and counter arithmetic is widened before adding it. A current token must belong to the submitting user. A token from another live player is rejected, while an unknown pre-restart token is still accepted when the password-authenticated user has already reconnected; that keeps stable's queued retry behavior working. Replays can be downloaded again through the stable endpoint. Duplicate checksums are rejected without touching stats.

PP is calculated from the exact `.osu` file stored with the beatmap. The calculator is `akatsuki-pp` (Akatsuki's fork of rosu-pp with proper relax and autopilot formulas) behind a small C boundary, with Cargo's complete dependency lock checked in. Vanilla `rosu-pp` does not understand relax or autopilot mods — it would calculate PP as if those mods weren't there. Akatsuki's fork handles them properly. A calculation error rejects the score instead of writing a believable-looking zero. Normal, Relax, and Autopilot scores use separate stat rows; changing mods makes stable display the matching plays, total score, ranked score, accuracy, combo, and weighted PP without leaking them into another mode. A `recalc` subcommand (`zigcho recalc <db>`) walks every passed score, recalculates PP with the current library, and rebuilds weighted stats per user/mode/namespace.

Beatmaps can still be imported with the local operator command, but stable no longer needs somebody to seed every map by hand. The first leaderboard request fetches metadata from osu API v1 and stores it immediately so the leaderboard renders right away. The background thread then downloads the archive from hinamizawa (osu.direct), extracts the exact `.osu` file, and checks its CRC, MD5, map ID, and set ID before it reaches SQLite. Some old beatmaps predate embedded map IDs; those use the already-verified API IDs when the fields are absent, but a file containing conflicting IDs is still rejected. Ranked and approved maps are allowed into normal scoring; qualified and loved maps get a board without changing ranked score or PP. Failed or mismatched downloads stay unsubmitted.

Stable Direct search and set lookup use that local catalog. On-demand hydration caches the matching `.osz` archive with its SHA-256; the separate operator command can still seed one deliberately. Stable `/d/{set}` and lazer's authenticated download route return the same stored bytes. A map without its archive is not advertised as downloadable just because its metadata exists.

Stable leaderboards return the normal client response with map data, a personal-best row, and the top 50. Global, exact-mod, friends, and country filters are handled in SQL. Ratings use stable's exact `no exist`, `not ranked`, `ok`, and `alreadyvoted` responses and keep one vote per player and map. Only one best score per player/map/mode/namespace is listed. A worse play still counts toward total score and plays, but it does not inflate ranked score. Relax and Autopilot have their own boards and their own displayed stats.

The lazer side has local bearer authentication, `/api/v2/me`, mod discovery, beatmapset search and metadata, archive downloads, raw `.osu` downloads, and JSON score submission. A score body is converted into one typed, bounded input before SQLite sees it; wrong field types get `422` instead of reaching a forced JSON union tag inside storage. It accepts lazer's nested registration fields and raw password login without splitting stable and lazer into separate accounts. Raw lazer passwords are reduced to the same MD5 credential stable sends, then that credential is wrapped with Argon2id in storage. Tokens are random, stored by hash, scoped, expiring, and revocable. Older development databases using the original hash format upgrade themselves after the next successful login.

The custom client endpoint files are checked in under `client/lazer/` against one pinned official osu! commit. I have built and opened the arm64 macOS client and confirmed it reaches `api.kai.ovh` over TLS. The local app is an ad-hoc signed QA build, not something I am calling a public macOS release.

Account registration, token requests, Bancho logins, authenticated reads, and score uploads have separate per-client limits. The limits use Cloudflare's client address when the server is behind the production proxy. They are synchronized, bounded in memory, and return `429` with a real retry time. Small account and token requests are capped at 8 KiB instead of getting the replay upload budget. OAuth token responses are explicitly marked `no-store`.

Relax uses `RX`. Unknown valid lazer mod acronyms are allowed as custom mods with their settings left intact. If RX and a custom mod are both present, custom wins no matter which one arrived first. Those scores do not quietly leak into the normal leaderboard:

- normal supported mods use `vanilla`
- `RX` uses `relax`
- custom mods use `custom`

That namespace is stored with the score. It is a database boundary, not a frontend filter someone can bypass.

## building it

You need Zig 0.16.0, Rust 1.94 or newer, and SQLite 3. The Rust toolchain builds the pinned PP library (akatsuki-pp from GitHub); the server and storage code are still Zig.

```sh
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zigcho 127.0.0.1 8080 zigcho.db
```

The arguments are bind address, port, and database path. The server reads `config.ini` from the working directory for runtime settings like `osu_api_key` and `score_webhook`. Public deployments need TLS in front of the server. The complete hostname contract is in `deploy/hosts.txt`, with the reason for each group in `deploy/HOSTS.md`. Do not send stable login credentials over plain HTTP.

Import a map as pending while checking it:

```sh
./zig-out/bin/zigcho-import zigcho.db map.osu
```

Pass the status as the last argument when the map is ready. `3` is ranked and `4` is approved. This is a local operator command; it is not exposed over HTTP.

Import the matching archive after the maps inside it have been checked:

```sh
./zig-out/bin/zigcho-import-archive zigcho.db 1234 mapset.osz
```

The archive importer rejects malformed, empty, trailing, and oversized ZIP files. Re-importing a set replaces its archive deliberately.

## where it is running

The current build is live at `https://kai.ovh`. It is a Debug alpha while the client bugs are being fixed. The stable and lazer names in `deploy/hosts.txt` go to the same process. Bancho token lookup and packet handling happen under the same session lock, so reconnecting cannot leave a request holding a session that another login just destroyed. Infrastructure roots get one small live display instead of a blank response: connected players, accounts, plays, passed plays, cached maps, and the little moving boat. Layerline terminates TLS and sends the traffic to zigcho on `127.0.0.1:27180`. The process runs as its own system user and keeps the SQLite database in `/var/lib/zigcho`.

The systemd and Layerline files are in `deploy/`. A release is built from a pinned commit under `/opt/zigcho/releases`, then `/opt/zigcho/current` is moved to it. That gives me a boring rollback path instead of replacing the live binary in place.

## trying the lazer API

Register a local account. Stable sends an MD5 password credential, which is still a reusable secret and is wrapped with Argon2id before it reaches the database.

```sh
curl -X POST http://127.0.0.1:8080/users \
  -d 'name=player&email=player@example.test&password_md5=00000000000000000000000000000000'
```

Get a one-hour token:

```sh
curl -X POST http://127.0.0.1:8080/oauth/token \
  -d 'grant_type=password&username=player&password_md5=00000000000000000000000000000000'
```

Submit a relax score:

```sh
curl -X POST http://127.0.0.1:8080/api/v2/scores \
  -H 'Authorization: Bearer TOKEN' \
  -H 'Content-Type: application/json' \
  --data '{"beatmap_id":75,"ruleset_id":0,"total_score":987654,"accuracy":0.985,"max_combo":321,"passed":true,"mods":[{"acronym":"RX","settings":{}}],"statistics":{"great":300,"ok":4,"miss":1}}'
```

A custom mod uses the same shape:

```json
{"acronym":"WIGGLE","settings":{"strength":1.25,"seed":42}}
```

Custom acronyms are two to eight uppercase ASCII characters. They are unranked and go into the `custom` namespace unless the server is deliberately configured to understand and rank them later.

## what still needs doing

This is the actual production list, not a wishlist:

- covers, previews, favourites, and screenshot storage still need their backing services
- beatmap hydration from osu API v1 and hinamizawa retries metadata-only maps, but still needs bounded backoff, cache-pruning, and failure metrics before an open launch
- stable multiplayer rooms now cover the server-side room, play, invite, tournament-viewer, referee, and abort contract; the real two-client installed stable run is still the completion gate
- lazer is frozen until stable passes the complete installed-client acceptance run; after that it still needs rooms, event streams, multiplayer spectating, and a properly signed public client release
- PP now uses akatsuki-pp with a pinned stable standard fixture; taiko, catch, mania, and lazer scoring fixtures still need to be locked before those paths can award PP
- public operation still needs moderation tools, structured logs, backups, migration tooling, metrics, and rolling restart behavior
- stable has passed the installed-client login, map, score, replay, PP, stats, chat, country, and mod-switch paths against public TLS; lazer is still being tested there one real request path at a time

The stable score cipher is Rijndael with a 32-byte block. AES-256 still has a 16-byte block and is not a compatible shortcut. There is a fixture for this because it is exactly the sort of almost-correct replacement that makes a private server look alive while every real score submission fails.

## current checks

The repository currently checks packet framing, malformed packets, safe-name handling, stable's two-stage account creation, server-to-client privilege mapping, country numbers and country boards, stored default avatars and their real image signatures, owned config memory, reconnect-safe token polling, owned login snapshots and tokens, real logout, idle expiry, bounded outgoing queues, stable multiplayer wire parsing, room lifecycle, match start, load completion, exact score frames, failures, shared skipping, round completion, and recipient scoping, stable score token authorization, owned async score data, bounded score counters, widened accuracy and checksum arithmetic, failed-score stat isolation, one-time joined chat delivery, the ID-3 `kai` migration, Relax/custom mod isolation and precedence, typed lazer score bodies, lazer form decoding and password compatibility, Argon2id authentication, legacy credential upgrades, scoped token access, revocation, bounded rate-limit windows, Rijndael block output, CBC padding, multipart duplicate fields and binary false-boundary bytes, stable score decryption, online checksums, beatmap parsing and MD5s, bounded ZIP extraction, archive CRCs, archive storage, stable Direct results, persistent ratings, lazer beatmapset JSON, a pinned PP result (akatsuki-pp formula), score webhook delivery, PP bot commands, and geolocation lookup. Authentication, database reads, and Bancho polling are exercised together, and every login allocation is failed in turn under the leak checker. Multiplayer packet construction is also walked through allocation failure. Full score/replay and leaderboard runs use fresh migrated databases in `ReleaseSafe`, including repeated mixed-size uploads, personal ranks, displaced best scores, exact-mod boards, friends boards, country boards, and Relax separation. Akatsuki's live service has been checked against the exact ranked set and MD5 from the installed stable client.

The protocol work is being checked against the official [osu! client](https://github.com/ppy/osu), the [Bancho wiki page](https://osu.ppy.sh/wiki/en/Bancho_%28server%29), and the MIT-licensed [Akatsuki bancho.py](https://github.com/osuAkatsuki/bancho.py) implementation.
