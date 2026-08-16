# lazer quick play

Quick Play actually has a server now. two people can queue into the same ruleset pool, accept the match, join a private room hosted by `kai`, pick maps and play all three rounds through to the final results.

the pool only uses ranked or approved maps that already have a real `.osu` file. picks are handled the same way as the current client, including random, and the match keeps each round's legacy score, accuracy, combo, placement and points. room scores still go through the normal lazer score token and replay path instead of disappearing into a fake multiplayer result.

the full flow is checked with two authenticated websocket clients and a real room score submission. normal rooms and spectating still work beside it. ranked multiplayer and a signed installer are still separate work, so i am not calling those done early.
