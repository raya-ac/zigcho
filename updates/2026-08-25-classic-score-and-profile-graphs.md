# Classic score actually means Classic now

i got the last score split wrong. lazer was storing the real modded score on the play, then quietly using `score without mods` whenever it rebuilt player stats. that made ranked score, total score and level wrong on both the website and the in-game lazer profile.

that fallback is gone. new lazer plays now get the same Classic score conversion used by our pinned lazer client: the real modded standardised score plus the map's maximum hit statistics. old plays are backfilled through schema 44 and every affected player total is rebuilt before the server comes back up. failed plays still only add total score, playcount, hits, play time and level progress; they do not add ranked score or pp.

the score itself is still the real lazer score. mods are not stripped and the website no longer wastes space showing a second `without mods` number. score details show the native score for the play and its Classic value for the shared Stable-style stats.

the profile graphs are fixed too. the website now draws an actual rank or pp graph even when tracking only has its first real day, and the in-game profile receives the 89-day shape the lazer graph expects. one known day becomes a flat honest line, not made-up history and not another number pretending to be a graph.

this correction used the short test pass on purpose: the Classic formula, schema backfill, score submission, shared Stable/lazer totals, website score details, profile serializer and PostgreSQL migration all passed, followed by a ReleaseSafe server build.
