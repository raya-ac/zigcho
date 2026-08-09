**zigcho update — score webhook improvements**

the discord score webhook now shows more context. previously it just listed the score and mods in a flat line. now each score post shows your rank on the map, combo as a percentage of the map's max, the game mode, and accuracy as separate fields in the embed.

rank comes from `scoreRankOnMap` which counts how many plays on that map beat yours — so "#3 on the map" means two people scored higher. combo percentage only shows when the map has a known max_combo in the database, otherwise it falls back to raw number.

mode shows osu!, osu!taiko, osu!catch, or osu!mania instead of nothing.

also fixed a zig 0.16 compat issue in the webhook json builder — `std.json.encodeJsonString` doesn't exist in 0.16, it's `std.json.Stringify.value`. same deal with `std.io.fixedBufferStream` being `std.Io.Writer.fixed`. the committed version was broken, this push fixes it.
