# zigcho

i'm building an osu! server in Zig because i want something small enough to understand properly without pretending the production work does not exist.

this is not connected to official osu! accounts. Stable and the custom lazer client use one local account, one user id, and the same moderation state. their score namespaces stay separate where the games actually differ.

## what works

- Stable login, registration, presence, chat, friends, spectating, multiplayer and tournament viewing
- vanilla, Relax, Autopilot and Stable ScoreV2 scores with separate boards and stats
- real replays, PP, weighted top plays, pins, map ratings, Direct and on-demand beatmap caching
- the `kai` bot, player commands, staff tools, BN map ranking and audited moderation
- PostgreSQL migrations, backups, restore drills, release rollback and bounded runtime caches
- `zigcho!lazer` accounts, profiles, beatmaps, vanilla/Relax/Autopilot boards, replay downloads and normal head-to-head rooms
- a public site with profiles, map leaderboards, replay downloads, player login and proper account settings
- private custom avatars in Cloudflare R2, served through `a.kai.ovh/{user_id}`

Stable is the complete public lane. lazer is still an alpha: ranked solo play and normal head-to-head rooms work, while matchmaking, spectating and the final signed client release are not finished.

## building it

zigcho is pinned to Zig 0.16.0. the live PP bridge also needs Rust, SQLite 3 and PostgreSQL with libpq.

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build -Dpostgres=true -Doptimize=ReleaseSafe
ZIGCHO_POSTGRES_URL='host=/var/run/postgresql dbname=zigcho user=zigcho connect_timeout=5' \
  ./zig-out/bin/zigcho 127.0.0.1 8080
```

copy `config.example.ini` to `config.ini` for private runtime settings. the real file is ignored by git and Docker. custom avatars need an R2 key scoped to object read and write on the one avatar bucket; the bucket itself stays private.

the full public hostname contract is in `deploy/hosts.txt`. production releases are built from an exact commit, placed under `/opt/zigcho/releases/<commit>`, then activated with `tools/activate-release.sh`. activation makes and restore-tests a PostgreSQL backup before changing the live symlink.

## useful checks

```sh
tools/stable-web-smoke.sh https://osu.kai.ovh
tools/stable-map-upstream-smoke.sh https://osu.kai.ovh
tools/lazer-solo-score-smoke.sh https://api.kai.ovh
tools/lazer-upstream-score-smoke.sh ./zig-out/bin/zigcho
tools/lazer-multiplayer-smoke.sh ./zig-out/bin/zigcho
```

the main test suite covers the wire formats, authentication, sessions, Stable scoring, lazer scoring, PP boundaries, chat, rooms, spectating, moderation, migrations, PostgreSQL parity, site sessions, CSRF and avatar validation. release builds also run inside the pinned Linux container before they are promoted.

## layout

- `src/` — server, protocol, storage and embedded website
- `client/lazer/` — pinned custom lazer patch and packaging work
- `pp/` — pinned local PP bridge
- `deploy/` — Linux build, service and host configuration
- `tools/` — smoke, backup, restore and release scripts
- `updates/` — the actual release history

protocol work is checked against the official [osu! client](https://github.com/ppy/osu), the [Bancho documentation](https://osu.ppy.sh/wiki/en/Bancho_%28server%29), and the MIT-licensed [Akatsuki bancho.py](https://github.com/osuAkatsuki/bancho.py) implementation.

this is an unofficial server. osu! belongs to ppy Pty Ltd; zigcho does not claim any affiliation with or endorsement by them.
