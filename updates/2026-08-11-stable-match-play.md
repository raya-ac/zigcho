# stable multiplayer can play a round now

rooms used to stop right before the part where you actually played. the host can start a round now, players wait for each other to load, score frames and failures go to the room with the right slot id, and everybody can skip together. when the last player finishes, the room drops out of play and the people who played go back to not ready.

i checked the packet order against akatsuki's bancho.py instead of making up a close-enough version. no-map players do not get dragged into the start packet. score frames have to be the exact stable v1 or scorev2 size, and the server replaces the client slot byte before it relays them. malformed frames get ignored.

the debug suite is at 67 tests and covers the whole room flow with a host, another player, a no-map player, and somebody watching the lobby. it also walks multiplayer packet building through allocation failures.

this is still not me calling multiplayer done. invites, tournament control, reconnect recovery, abort handling, and a real two-client run are left. stable as a whole is around 67% of the way to an invite-only build i would let somebody else use. lazer is staying frozen until that stable run is actually complete.
