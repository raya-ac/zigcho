# zigcho release 1.6

this one is mostly the stuff you only notice when it goes wrong. the normal player path stays the same, but Stable score submit, sessions, Postgres and the HTTP edge have much harder boundaries now.

## a Stable score belongs to the client that logged in

Stable now binds score submit to the build date and hardware signature from that exact login. the raw hardware values are not kept on the session. an exact token from another client is rejected, and a queued retry after a restart only works when it still matches the current client.

## one play actually means one best play

two scores landing at the same time cannot both become best anymore. Stable, ScoreV2 and lazer take a transaction lock for the exact player, map, mode and scoring namespace, then pick one winner. Stable and lazer also take their shared map and stats locks in the same order now, so a score from each client cannot deadlock the other one. schema 46 repairs old duplicate winners, rebuilds the stats they affected and keeps a retry marker until that work is actually finished. the release backup now carries an exact object key, digest, old schema and restore-tested rollback command too, because an old binary on its own is not a rollback after a schema change.

## restricted accounts are properly restricted

restricted Stable users can stay connected, see their own state and log out. chat, friends, channels, multiplayer and spectator packets are stopped before their payload reaches a handler. their action changes are not broadcast to everyone else either.

## the Bancho lock is not waiting on Postgres

stats, friends, channel policy, direct messages, chat history and bot commands are prepared outside the global Stable session lock. each player has a small poll lease now, so a token is checked again before any database write and an old reconnect cannot finish somebody else's command afterwards. staff state is pulled back from Postgres on every owner poll, unread DMs are recovered without duplicating them, and an older stats snapshot cannot overwrite a newer in-game action. one slow query no longer freezes every Stable player behind it.

## the HTTP edge has a real budget

connections are capped before a task is spawned. headers, ordinary requests and large uploads/downloads have separate deadlines, while the actual realtime lazer transports keep their long-lived connection contract. the live developer page and Prometheus now show active, rejected and timed-out HTTP work.

## pp has a Zigcho-owned policy now

live Stable and lazer scores now pass through a versioned Zigcho policy before reaching the pinned calculation engines. it keeps exact lazer mod JSON, slider judgements and custom rates, canonicalises Stable NC/DT and PF/SD, and deliberately leaves Relax and Autopilot on their existing paths. developers also have a read-only pp lab for comparing exact inputs before any future policy change can touch scores. while wiring that in, i fixed the old lazer recalc bug that was passing the `passed` flag where mod JSON belonged, and made recalculation rebuild lazer best flags too.
