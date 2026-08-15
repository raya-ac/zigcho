# lazer leaderboards stop guessing now

lazer was deciding most maps had no leaderboard before it even let zigcho answer. an online map could still have pending or unknown status cached locally for a moment, so the results screen showed "leaderboards are not available" even while our API had the real ranked map and a working board ready.

the custom client only needs a real online map id now. it asks zigcho for the board and leaves ranked, loved and custom status handling to the server where it belongs. this covers results, song select and the mapset screen instead of fixing one page and leaving the same check somewhere else.

this is `0.1.0-alpha.3`. it is still the portable unsigned windows build, and multiplayer plus spectating still wait for realtime.
