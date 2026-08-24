# zigcho

an osu! server written in Zig. i wanted one server i could actually understand, change and run properly without treating the production work as somebody else's problem.

release 1 is the point where Stable, zigcho!lazer and the website became one thing. they use the same local account, user id, moderation state, presence and shared player stats. none of it uses an official osu! account. their scoreboards stay separate where the clients genuinely score differently.

## what is here

- Stable login, chat, friends, spectating, multiplayer, tournaments and ScoreV2
- vanilla, Relax and Autopilot scores, stats, PP, replays, pins and weighted top plays
- zigcho!lazer profiles, maps, leaderboards, achievements, chat, spectating, Quick Play, rooms and ranked duels
- a proper website for profiles, beatmaps, scores, replays, teams, multiplayer and account settings
- the kai bot, player commands, staff controls, BN map ranking and moderation tools
- PostgreSQL, private object storage, beatmap mirroring, backups, restore drills and rollback releases

combined stats use lazer's legacy score value and keep the highest-PP play for each map. Stable and lazer plays still have their own views, because pretending their raw score values are interchangeable would be wrong.

the full release 1 notes are in [updates/2026-08-24-lazer-multiplayer-profiles-and-routes.md](updates/2026-08-24-lazer-multiplayer-profiles-and-routes.md). newer changelogs are read from the raw GitHub files, so an update does not need a client rebuild just to change the words.

## build

zigcho is pinned to Zig 0.16.0. the PP bridge also needs Rust, SQLite 3 and PostgreSQL with libpq.

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build -Dpostgres=true -Doptimize=ReleaseSafe
ZIGCHO_POSTGRES_URL='host=/var/run/postgresql dbname=zigcho user=zigcho connect_timeout=5' \
  ./zig-out/bin/zigcho 127.0.0.1 8080
```

copy `config.example.ini` to `config.ini` for local secrets. the real config is ignored. the useful player-path checks live in `tools/`, including Stable web/map checks and lazer solo, multiplayer and spectator runs.

production binaries come from the pinned Linux GitHub runner, not my Mac. each release lives at `/opt/zigcho/releases/<commit>` and is activated through `tools/activate-release.sh`, which backs up and restore-tests PostgreSQL before switching the live symlink. zigcho!lazer packages are built by runners for Windows, macOS, Linux, Android and unsigned iOS.

## layout

- `src/` — server, protocols, storage and website
- `database/` — schemas and ordered migrations
- `client/lazer/` — the pinned lazer patch and packaging
- `pp/` — the local PP bridge
- `deploy/` and `tools/` — production and acceptance work
- `updates/` — the release history

protocol work is checked against the official [osu! client](https://github.com/ppy/osu), the [Bancho documentation](https://osu.ppy.sh/wiki/en/Bancho_%28server%29) and the MIT-licensed [Akatsuki bancho.py](https://github.com/osuAkatsuki/bancho.py) implementation.

this is unofficial. osu! belongs to ppy Pty Ltd; zigcho is not affiliated with or endorsed by them.
