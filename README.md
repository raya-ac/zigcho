# zigcho

I'm building an osu! server in Zig because I want something small enough to understand properly, but still capable of running as a real server. The target is stable and a custom lazer client, one local account system, relax, custom lazer mods, multiplayer, spectating, leaderboards, and the boring production work that usually gets left until last.

It is not connected to official osu! accounts. When I say stable and lazer share an account, I mean both clients log into the same account on this server and use the same user ID, punishments, friends, and stats.

This is not ready to put in front of players yet. I would rather leave that sentence here than pretend a green health endpoint means the server is done.

## where it's at

The Bancho side can parse protocol 19 packets, log stable clients in, issue tokens, track presence and status, handle public and private messages, join channels, answer presence/stat requests, and relay spectator frames. Live requests run concurrently and access to sessions, outgoing queues, and SQLite is synchronized.

The lazer side has local bearer authentication, `/api/v2/me`, mod discovery, and JSON score submission. Tokens are random, stored by hash, scoped, expiring, and revocable. Password credentials are stored with Argon2id. Older development databases using the original hash format upgrade themselves after the next successful login.

Relax uses `RX`. Unknown valid lazer mod acronyms are allowed as custom mods with their settings left intact. Those scores do not quietly leak into the normal leaderboard:

- normal supported mods use `vanilla`
- `RX` uses `relax`
- custom mods use `custom`

That namespace is stored with the score. It is a database boundary, not a frontend filter someone can bypass.

## building it

You need Zig 0.16.0 and SQLite 3.

```sh
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zigcho 127.0.0.1 8080 zigcho.db
```

The arguments are bind address, port, and database path. Public deployments need TLS in front of the server, with the usual `c.`, `osu.`, `b.`, and `a.` hosts routed to it. Do not send stable login credentials over plain HTTP.

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

- stable score uploads need the real Rijndael-CBC cipher with 256-bit blocks, the versioned `osu!-scoreburgr` key, multipart parsing, checksum checks, replay storage, and stat updates
- beatmap search, metadata syncing, downloads, favourites, ratings, and screenshot storage need their backing services
- stable multiplayer needs full slot state, host transfer, freemod, team modes, match completion, invites, tournament control, and reconnect behavior
- lazer needs rooms, event streams, multiplayer spectating, and a client build pointed at this server
- PP needs a pinned calculator with test fixtures for every supported ruleset and scoring version
- public operation needs request limits, moderation tools, structured logs, backups, real migrations, metrics, deployment files, and rolling restart behavior
- both clients need to be tested against a TLS deployment, not just synthetic requests

The stable score cipher is Rijndael with a 32-byte block. AES-256 still has a 16-byte block and is not a compatible shortcut. I am calling that out because it is exactly the sort of almost-correct replacement that makes a private server look alive while every real score submission fails.

## current checks

The repository currently checks packet framing, malformed packets, safe-name handling, accuracy, relax/custom mod isolation, Argon2id authentication, scoped token access, revocation, and JSON score validation. The concurrent server has also been exercised with parallel health, authenticated lazer, and Bancho poll requests.

The protocol work is being checked against the official [osu! client](https://github.com/ppy/osu), the [Bancho wiki page](https://osu.ppy.sh/wiki/en/Bancho_%28server%29), and the MIT-licensed [Akatsuki bancho.py](https://github.com/osuAkatsuki/bancho.py) implementation.
