# stable scoring is pinned across every mode now

the Stable PP gate covers the whole server instead of one standard map now. osu!, taiko, catch, and mania each have fixed no-mod, HD, HR, DT, miss, and FC snapshots. relax is locked to osu!/taiko/catch, autopilot is locked to osu!, and unsupported RX mania or AP side modes are rejected before they can touch stats.

stored-score coverage runs every valid mode and namespace separately. a failed play adds total score, playcount, playtime, hits, and the map play count. it still cannot change ranked score, PP, accuracy, max combo, best-score state, or pass count.

BN commands are direct now. after `/np`, `!mapstatus pending|qualified|ranked|approved|loved <reason>` puts the full set on that exact status. the short `!pending`, `!qualify`, `!rank`, `!approve`, and `!love` forms do the same thing. this works from any previous status, repairs mixed-status sets, freezes every difficulty together, rebuilds player stats, and keeps the written history. requests and nominations still exist for review; they are not a fake permission wall around the final BN decision.

the staff site has the same five direct choices. its browser/API smoke walks one set through loved, approved, pending, qualified, and ranked and checks the immutable history afterward.

Debug and ReleaseSafe passed 101/101 against fresh real PostgreSQL. the exact x86_64 Linux commit passed the native build, live backup/restore activation, all 21 hosts, Stable login, database integrity, metrics, and warning-log checks.

that is phase 2 of 5 Stable closure phases done. Stable is around 95%; friends/favourites/presence and the remaining account/media contract are next. lazer and BSS are still waiting.
