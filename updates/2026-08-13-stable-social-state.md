# stable friends and favourites work like part of the server now

friends are stored instead of disappearing when the client closes. they are directional, kai is always there as ID 3, and the login response carries the full list. adding or removing someone works even if they are offline.

private-message privacy is wired up too. non-friends get the actual blocked packet, friends still get through, and AFK away messages answer without swallowing the DM. Stable can request the full unrestricted presence list after a reconnect, and the update filter no longer gets thrown away.

the legacy friends and favourites pages are backed by the account now. they only work while that Stable user is online, favourites survive restarts, and adding the same set twice gives the response the client expects instead of creating junk rows.

I caught the stats display while this was still held back too. switching to Relax or Autopilot updated everyone else but did not return the same `user_stats` packet to the player who changed mods, so their own client could drop back to the no-mod display. it now returns the chosen stats immediately and the test walks vanilla to Relax to Autopilot and back.

the local client-shaped smoke logs in through Bancho before touching any of those routes. the suite passed 102/102 locally and 105/105 in Debug and ReleaseSafe with all three real PostgreSQL fixtures connected. the exact x86_64 Linux build passed too.

`40bc007` is live with `372c321` kept as rollback. the 1.82 GB backup restored cleanly at schema 17, all 21 public hosts passed, Layerline and zigcho are active with zero restarts, and the installed Stable client reconnected and loaded its next map normally.

that is phase 3 of 5 done. Stable is around 97% now. native Zig PP is next, then the remaining media/account/proxy cleanup and the long soak, restart, restore, rollback, and load gate. lazer and BSS are still parked.
