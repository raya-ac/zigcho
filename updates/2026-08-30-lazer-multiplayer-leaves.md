# zigcho release 1.9

this is the first clean cut through the 9,640-line lazer multiplayer file. i am doing it leaf-first so the scary session and shutdown code does not move until the boring wire and value code has somewhere stable to live.

## the wire layer is its own thing

SignalR and MessagePack framing now live under `lazer_multiplayer/signalr.zig`. the 60 KiB frame ceiling, five-byte prefix limit, nesting limit, handshake, completions and event envelopes are unchanged. spectator still gets the exact same public API through the old module facade.

## paths and scores stopped living beside sockets

room path parsing and list filters have their own module now. the pure room-score rules do too: total score first, score id as the deterministic tie-break, one best per user, failed scores only eligible in realtime rooms and zero scores never reaching a board.

## the value models have a home

fixed buffers, playlist items, room users, matchmaking state, ranked cards, countdowns and settings are split away from Manager. their field layout, limits, stage numbers and countdown arithmetic did not change.

## what changed for players

nothing. all 40 public multiplayer symbols are still there, the focused wire/path/scoring/ranked contracts pass, and this phase does not touch rooms, reconnects, persistence, event order or locking. `lazer_multiplayer.zig` is down to 8,888 lines; serializers and Manager ownership are next.
