# lazer leaderboards stop guessing now

lazer was deciding most maps had no leaderboard before it even let zigcho answer. an online map could still have pending or unknown status cached locally for a moment, so the results screen showed "leaderboards are not available" even while our API had the real ranked map and a working board ready.

the custom client only needs a real online map id now. it asks zigcho for the board and leaves ranked, loved and custom status handling to the server where it belongs. this covers results, song select and the mapset screen instead of fixing one page and leaving the same check somewhere else.

supporter was split between the two clients too. stable already gives every player the normal supporter client permissions, but lazer was only reading the old supporter bit from the database. lazer now gets the same supporter access as stable, while premium still keeps its separate level.

normal multiplayer is alive in this build too. the client only opens the multiplayer hub, while chat stays on the REST fallback and the unfinished spectator and metadata sockets stay off. head-to-head rooms can create, join, leave, change settings and mods, ready up, load together, play, submit the room score and show the results without borrowing stable's bancho match state.

this is `0.1.0-alpha.3`. it is still the portable unsigned windows build. matchmaking, ranked play and spectator streaming are still separate work instead of being labelled done early.
