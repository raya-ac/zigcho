# stable multiplayer has real rooms now

the packet IDs were there, but most of them did nothing. stable could open the multiplayer screen without having a room system behind it.

rooms now keep their own slots, host, password, map, mode, teams, freemods, and room chat. players can find rooms in the lobby, join with the right password, move slots, ready up, change teams, lock or kick somebody, and hand host over. if the host leaves, the next player gets it. the room is removed when everybody is gone.

the wire format and behavior were checked against the current Akatsuki bancho.py implementation instead of filling the gaps from memory. malformed or oversized room packets are rejected, room-owned strings have fixed limits, and there can only be 64 live rooms.

64 tests pass in Debug and ReleaseSafe. the new tests run three stable sessions through the room lifecycle and fail every room allocation in turn under Zig's leak checker.

this is room lifecycle, not finished multiplayer. the next stable phase is starting the map, load completion, score frames, failures, completion, skipping, and getting everybody back to the right room state. invites, tournament control, reconnect recovery, and the real two-client check come after that.

where it is: still a Debug alpha, around 63% of the way to an invite-only stable server I would let somebody else use. lazer is staying where it is until stable passes the full client run.
