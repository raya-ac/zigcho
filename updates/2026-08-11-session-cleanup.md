# dead sessions stop staying online forever

zigcho tracked `last_seen` but never cleaned anything up. logout didn't remove the player, vanished clients stayed online forever, and broadcasts could keep growing their queues.

logout now removes the session and sends the proper `user_logout` packet to everyone left online. I matched bancho.py's weird-client guard too: osu! sometimes logs out 300–800 ms after login, so that first second is ignored instead of kicking a fresh login.

clients that stop polling expire after 300 seconds, the osu!-defined ping window bancho.py uses. outgoing queues are capped at 1 MiB. if a stopped client crosses that cap, the queued allocation is freed immediately and the session goes through the normal restart/reconnect path on its next request. it cannot start growing again while it waits.

51 tests pass in Debug and ReleaseSafe. they cover the actual logout packet, the first-second exception, five-minute expiry, the exact queue boundary, overflow, removal, and logout delivery to the clients still there.

where it is: still a Debug alpha, now around 51% of the way to an invite-only server I would let someone else rely on. the three P0 lifetime bugs are closed and dead Bancho sessions are bounded. next is shrinking the login/session/database lock scope, binding score tokens to the actual user, hardening hostile score bodies, then continuing lazer and multiplayer.
