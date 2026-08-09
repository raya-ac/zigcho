**zigcho update — instant maps, background downloads**

leaderboards load instantly now. when you open a map the server doesn't have, it fetches just the metadata from osu's api — title, artist, difficulty, star rating, max combo — and stores it immediately. the leaderboard renders right away with full map info even though nobody's played it yet. you see the map, not "not submitted."

the heavy part — downloading the beatmap archive, extracting the .osu, running rosu-pp for precise attributes — happens in a background thread. each map gets its own thread with its own http client, so multiple maps download at the same time without blocking each other or the request that triggered them. by the time you finish playing and submit your score, the .osu file is usually already there waiting.

before this, the entire hydration was one blocking call. metadata fetch, archive download, zip extraction, pp calculation — all serialized behind a single mutex. three people opening three different maps meant everyone waited in line. now the fast part (metadata from osu, same region) happens inline and the slow part (downloading 30 MB from a mirror) runs detached.

osu api v1 gives us `difficultyrating` and `max_combo` directly, so the initial metadata write includes star rating and combo. when the background thread finishes, it overwrites with rosu-pp's calculated values for precision. the leaderboard works either way.
