# map downloads stop hammering the same broken set

beatmap hydration has memory now. a failed upstream request is stored with the map, error, attempt count, and next retry time. retries start at 30 seconds, back off to six hours, survive a restart, and the failure ledger is capped at 10,000 maps. one bad archive cannot get downloaded on every leaderboard refresh anymore.

the `.osz` cache also has a real ceiling instead of growing inside PostgreSQL forever. it defaults to 2 GiB, updates the last-used time when a player downloads a set, and removes the coldest replaceable archives when the limit is crossed. map metadata and `.osu` files stay put, so an evicted set can hydrate again when somebody actually wants it.

local metrics now show cache bytes, cached sets, blocked hydrations, attempts, successes, failures, backoff skips, and pruned bytes. schema 17 carries the retry and LRU state through SQLite, PostgreSQL, imports, backups, restores, and rollback.

the daily PostgreSQL backup timer is installed on the live host now. every dump is checksummed and restored into a disposable database before it counts as good.

Debug and ReleaseSafe passed 99/99 against fresh real PostgreSQL. the exact x86_64 Linux commit passed the pinned container build, the schema 16 to 17 upgrade, live backup restore, 21 public hosts, Stable login, local metrics, database integrity, and warning-log checks.

Stable is around 93%. scoring coverage and the BN map-state fixes are next. BSS is waiting until lazer has enough real surface to justify it.
