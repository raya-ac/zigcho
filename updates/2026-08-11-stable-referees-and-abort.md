# stable rooms have referees and abort now

the host is always a room referee now. they can add somebody with `!mp addref`, remove them again, or list who currently has control. refs disappear when that player leaves the room, so the permission does not hang around on an old session.

`!mp abort` now does what stable expects when a round gets stuck. everybody in the room, including tournament viewers, gets packet 106. playing slots go back to not ready, load and skip state gets cleared, the lobby sees the room stop playing, and kai confirms it in room chat. a normal player cannot fire it just by typing the command.

i checked the behavior against akatsuki's bancho.py. the 69-test harness covers the host, a promoted ref, an outsider, malformed commands, permission removal, a denied abort, both abort spellings, packet order, state reset, and cleanup when the ref leaves.

this closes the server-side stable multiplayer list i have been working through. i am still not calling multiplayer fully done until two real stable clients create a room, join, play, abort, finish, and leave over the public server. stable is around 71% of the way to the invite-only build. lazer stays frozen until that client run is green.
