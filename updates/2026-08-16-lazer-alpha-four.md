# zigcho!lazer is properly online now

the client is `zigcho!lazer` now, not an osu development build with our urls pasted over it. Debug and Release keep their own storage and IPC names so it still cannot touch an official lazer install, but the name people actually see is ours.

the multiplayer hub was accepting the wrong SignalR handshake. the real client uses the binary MessagePack handshake, so it would login normally and then quietly fall back offline. that handshake is fixed and the full two-player room run passes again: create, join, ready, load, play, submit, results and leave.

lazer leaderboards now say which score lane they are showing. vanilla, Relax and Autopilot stay separate, use their own ordering and keep the exact mods on every play. `kai` is visible and online in chat too instead of only existing in the friends response.

replays finally travel with the score. the client encodes the actual play, the server validates and stores it in the same transaction, and both lazer and the website can download it again. scores only hit Discord and `#announce` when they really made the leaderboard, and the returned position is the real map rank instead of null.

this is `0.1.0-alpha.4`. it is still a portable unsigned Windows alpha. normal rooms are live; matchmaking, lazer spectating and a signed installer are still their own work.
