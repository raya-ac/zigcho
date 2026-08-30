# zigcho release 1.7

this is the boring sort of release that makes every release after it less painful. `main.zig` and the Postgres backend had turned into two files that owned nearly everything, so changing one route meant digging through thousands of unrelated lines and hoping the build caught every hidden dependency.

## main is an entrypoint again

`main.zig` is down from 6,348 lines to 83. startup, HTTP, routes, IRC, workers, sessions, controls and command-line work now live under their own server directories. the public behaviour and router order are unchanged; the file that starts Zigcho just starts Zigcho now.

## Postgres is split by what it stores

`postgres_store.zig` is down from 9,971 lines to an 881-line compatibility facade. accounts, beatmaps, scores, social state, multiplayer, moderation and core database work each have their own module while the rest of the server keeps the same concrete Store API.

## the Stable session edge has a home

Stable login parsing, authentication, score-session authorization and HTTP boundaries are separate modules now. the persisted five-minute retry token stays client-bound, one-time and checksum-idempotent, and reconnect, logout, restriction, password changes or lazer takeover still revoke it exactly as before.

## what changed for players

nothing on purpose. schema stays at 47, the wire formats stay the same and the live client paths stay the same. this was about making the server possible to review without changing the game underneath people.
