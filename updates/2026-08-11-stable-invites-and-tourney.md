# stable invites and tournament viewing work now

players inside a room can invite somebody and stable gets the real `osump://` join link, including the room password. kai still refuses because apparently he is too busy.

supporters using the tournament client can ask for the public room state and join its chat without taking a player slot. they get room messages, state changes, starts, score frames, and the rest of the live round traffic. normal accounts cannot open that path, and a tournament viewer cannot also join the same room as a player.

i checked this against akatsuki's bancho.py and added a full host, invite target, normal viewer, supporter viewer, and bot harness. the debug suite is at 68 tests.

stable is around 69% of the way to the invite-only build now. referee and abort control are still missing, and i still want the real two-client stable run before i call multiplayer complete. lazer stays frozen until stable gets through that.
