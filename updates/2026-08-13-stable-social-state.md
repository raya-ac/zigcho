# stable friends and favourites work like part of the server now

friends are stored instead of disappearing when the client closes. they are directional, kai is always there as ID 3, and the login response carries the full list. adding or removing someone works even if they are offline.

private-message privacy is wired up too. non-friends get the actual blocked packet, friends still get through, and AFK away messages answer without swallowing the DM. Stable can request the full unrestricted presence list after a reconnect, and the update filter no longer gets thrown away.

the legacy friends and favourites pages are backed by the account now. they only work while that Stable user is online, favourites survive restarts, and adding the same set twice gives the response the client expects instead of creating junk rows.

the local client-shaped smoke logs in through Bancho before touching any of those routes. Debug is at 101/101 with the PostgreSQL and exact Linux gates following before this commit can go live.

that is phase 3 of 5 done once the public checks pass. Stable is around 97% now. the remaining work is media/account/proxy packet cleanup, then the long soak, restart, restore, rollback, and load gate. lazer and BSS are still parked.
