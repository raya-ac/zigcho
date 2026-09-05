# show the previous personal best on stable's result screen

the beatmap chart was leaving every previous value empty, even when you already had a score on the map. it now sends the old rank, score, combo, accuracy and pp alongside the new play.

the old best is copied inside the score transaction before anything can replace it. a worse play still compares against that same best. vanilla, relax, ap and scorev2 stay in their own lanes; a first score still has empty previous fields.

this fixes the result response. it doesn't change pp calculations, score selection or stored stats. there's no recalculation or database migration.

the focused fixture covers first scores, worse plays and improvements in both storage backends. deployment status will be recorded after the candidate is live.
