# show the previous personal best on stable's result screen

the beatmap chart was leaving every previous value empty, even when you already had a score on the map. it now sends the old rank, score, combo, accuracy and pp alongside the new play.

the old best is copied inside the score transaction before anything can replace it. a worse play still compares against that same best. vanilla, relax, ap and scorev2 stay in their own lanes; a first score still has empty previous fields.

this fixes the result response. it doesn't change pp calculations, score selection or stored stats. there's no recalculation or database migration.

the focused fixture passed in Debug and ReleaseSafe, including PostgreSQL. [release gate 33966789517](https://github.com/zigcho/zigcho/actions/runs/33966789517) passed and `dae9643` is live. the running binary matches the artifact, all 22 hosts respond, and API authorization still rejects unsigned requests. installed Stable-client acceptance remains deferred.
