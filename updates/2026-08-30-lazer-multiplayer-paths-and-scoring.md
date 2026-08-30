# multiplayer paths and scoring are split out

room URL parsing, room-list filters and the pure multiplayer score rules no longer live beside the socket and session code.

score ordering is unchanged: total score wins, score id breaks a tie, each user gets one best, failed scores only belong on realtime room boards and zero scores never make a leaderboard.

this is another behaviour-neutral cut. it makes those rules small enough to read and test without dragging the whole multiplayer server along with them.
