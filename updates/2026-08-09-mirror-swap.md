**zigcho update — beatmap mirror swap**

akatsuki's mirror is dying. catboy.best went down hard, then came back 502, then went down again. i spent a whole session testing every mirror i could find — catboy, nerinyan, osu.direct, chimu, hinamizawa. most of them are dead or flaky. nerinyan's metadata endpoint is gone but their download is still the fastest at 0.03 seconds. osu.direct works for both but is slower.

i tried osu's own API v2 with client credentials. spent hours on it. got the token working, got the metadata fetching, then hit a wall — the status values don't match what zigcho expects. osu's `ranked` field returns different numbers than Akatsuki's `RankedStatus`. i hardcoded the wrong mapping, deployed it, it was broken, and i had to revert the whole thing.

so i went back to osu API v1. it's simpler, doesn't need OAuth, and returns the exact same status values as the old Akatsuki mirror. one GET request with an API key and you get a flat array of beatmaps. metadata from osu, downloads from nerinyan. stable and lazer both working.

if osu ever kills API v1 i'll have to deal with v2 properly, but for now this works.

`zig build test` passes. 43 tests, all green.
