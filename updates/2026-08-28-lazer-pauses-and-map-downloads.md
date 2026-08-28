# zigcho release 1.4

two fairly normal things were getting turned into much bigger failures than they needed to be. pausing during the map lead-in could kill a score submission, and a cached map could still be impossible to download because the client was sent straight to the storage provider.

## paused lazer scores submit properly

lazer can record a pause before the map clock reaches zero. zigcho was rejecting every negative pause time, so pausing during the lead-in came back as `invalid_score_or_mod` even when the account, map, mods and score token were all fine.

lead-in pauses now use the same signed time range as the client. the existing limits on pause count and integer size stay in place. this does not change pp, mods, best-score selection or player stats.

## map downloads stay on kai

cached beatmap downloads used to redirect the client straight to the raw Contabo hostname. if Windows could not resolve that hostname, the download died before it received a single byte even though the archive was already stored and valid.

cache hits now stream through Zigcho on the first-party route. the client gets the stored byte count and the proper `.osz` response without needing to know which object store is behind it. cache misses still use the existing bounded fill path.

## what did not change

there is no database migration and no new client package in this one. alpha.15 stays current. this is just the server stopping two valid client actions from falling into dumb failure paths.
