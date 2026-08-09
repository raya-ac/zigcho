**zigcho update — kai bot commands**

kai can actually do stuff now. PM kai in-game with `!np` and it'll calculate pp for whatever map you're currently playing, using whatever mods you have on. there's also `!with HDHR 98% 5m` which lets you spec out a custom scenario — mods, accuracy, miss count — and get pp for a hypothetical play on your current map.

also when you `/np` in-game (which the client sends as a status change), kai automatically PMs you the pp. you don't have to ask.

the mod parser handles two-letter combos like HDHR, DTHD, FL, whatever. accuracy converts to hitcounts using the map's object count. misses subtract from 300s. all the math goes through rosu-pp same as score submission.
