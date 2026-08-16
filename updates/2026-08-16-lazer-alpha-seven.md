# lazer alpha.7

lazer spectating is actually connected now. you can watch somebody before they start, follow their frames through the play, see the result process, and keep watching when they start the next map. it is its own bounded realtime path and does not turn every unfinished lazer socket back on with it.

the chat channel response now sends real users instead of two bare ids, so the client can show both you and `kai` as online instead of losing their profile state. the website also keeps the line clear: Stable and lazer scores have their own boards and play lists, while the stats above them combine both clients. lazer uses its legacy score there and pp decides which client owns the map.

this is `0.1.0-alpha.7`. it is still the portable unsigned Windows build. normal rooms and live spectating work; matchmaking, ranked multiplayer and a signed installer are still not being called finished.
