# profile plays have proper score details now

every pinned, top and recent play has a details button now. it opens the full score without throwing you away from the profile: result, client, score lane, mode, score, pp, accuracy, combo, mods, exact play time, map status, map id and replay state are all there.

top plays also show their weighted pp and percentage in the popup. the beatmap and replay buttons are kept inside it, while the quick replay link still stays on desktop.

the popup works with the keyboard, closes on the backdrop or escape, and puts focus back where it started. i checked the real profile data on desktop and phone with no page overflow, then ran the full Debug and ReleaseSafe test suites and the ReleaseSafe build.
