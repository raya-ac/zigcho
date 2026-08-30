# zigcho release 1.8

i finally put a proper regression harness around Stable instead of trusting that a route returning 200 means osu! actually accepted it. this release does not change player behaviour. it gives us a checked contract for the behaviour we already have, so the next refactor cannot quietly break half of bancho.

## the whole Stable surface is counted

all 46 handled Stable client packets and all 17 legacy web routes are inventoried from the source and covered by the corpus. login, reconnects, delayed score retries, presence, chat, spectators, multiplayer, tournament traffic, restricted users, silenced users and malformed traffic now have stateful transcripts.

## packets are checked as packets

the decoder checks the real little-endian framing, ordered duplicate packets, bounded payloads and the body shapes the client actually reads. CI now runs the inventory, full corpus validation and 87 focused harness tests on every relevant push.

## bancho.py is a pinned reference, not a story

the reference checkout is pinned to an exact clean commit. even the weird packet 98 set routing is source-attested instead of being normalised into something deterministic that bancho.py does not actually do.

## what this does not pretend

this is a complete checked corpus, not a fake claim that we ran a perfect live clone against two identical databases. the full two-origin replay still needs an isolated mirrored fixture. the Stable differences we already know about are written down and will fail visibly in a real differential run instead of being hidden.

## live state

the exact runner artifact went live on `44eba5ac` with schema 47 unchanged. the restore drill passed, `c4fa1f5` remains the rollback, every public host passed, and Stable relay routes, assets, avatars, API auth, multiplayer auth, the beatmap mirror and live client presence all checked out after restart.
