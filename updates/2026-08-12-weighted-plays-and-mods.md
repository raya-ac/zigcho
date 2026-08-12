# top plays show what they actually count for

player pp was already using the proper 95% decay in both SQLite and PostgreSQL. the profile just hid it, which made every top play look like its full raw pp counted toward the total.

top plays now carry the same weight shape as osu: 100%, 95%, 90.25%, and so on. the page shows both that percentage and the weighted pp contribution beside the raw play pp. pinned and recent plays do not get a made-up weight because their position there has nothing to do with the top-play calculation.

every score row also shows the mods that were actually used. normal plays say things like `+HDDT`, relax and autopilot keep `+RX` and `+AP`, and nomod says `+NM`. nightcore does not repeat double time and perfect does not repeat sudden death.

Debug and ReleaseSafe passed 97/98 against fresh real PostgreSQL databases, with the standalone importer fixture being the one expected skip. i also ran the page against a browser fixture with two weighted tops and a failed recent play: 100pp stayed 100pp at 100%, 80pp became a 76pp contribution at 95%, HDDT and NC rendered correctly, and the failed nomod play still had no pp.

this does not recalculate or change anybody's existing total. it exposes the weighting that was already being used and stops the website from leaving the mods out.
