# stable spectating stays between the people actually watching now

spectating used to be fake in a pretty bad way. the host got one joined packet, but zigcho never remembered who was watching them. stop and can't-spectate packets did nothing, fellow spectators did not exist, and every frame bundle was sent to every online player whether they were watching or not.

the server owns that relationship now. the host sees spectators join and leave, viewers see each other, `#spectator` opens and closes with the right group, its chat stays inside that group, and frames only go to the people watching that host. switching hosts removes the old relationship first. a viewer logout, host logout, reconnect, or expired session clears it instead of leaving a ghost spectator behind.

i worked from akatsuki's bancho.py contract again. the 71-test debug suite covers first and second viewers, same-host retries, malformed and self targets, private spectator chat, exact frame bytes, can't-spectate relay, stop, host switching, host logout, outsider isolation, and every induced allocation failure while the spectator packets are built.

this closes another server-side stable gap and fixes a real recipient leak. it still needs the installed stable host/viewer run before i call the client path done. stable is around 73% of the way to the invite-only build i would let somebody else use. lazer is still frozen.
