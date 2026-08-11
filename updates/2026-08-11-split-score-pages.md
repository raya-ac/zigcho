# score pages are actually split up now

the website was mixing every kind of score together. that made profiles pretty useless and it also let a failed play look like a normal submitted score.

rankings and profiles are split the same way the server stores stats now. vanilla has osu!, taiko, catch, and mania. relax has osu!, taiko, and catch. autopilot only has osu!. switching either part reloads the exact stats and the last 20 plays for that one namespace and ruleset, so relax and autopilot scores cannot leak into vanilla anymore.

failed plays have a red edge, a red `failed` label, and show no awarded PP. the score, accuracy, and combo are still there because the play happened, but it cannot be mistaken for a pass.

country codes have been replaced with their actual flags on profiles and rankings. i also split player names, map details, and result labels onto deliberate lines so the links do not run into the text beside them anymore.

i checked every supported mode against both SQLite and a disposable real PostgreSQL database, then clicked through the filters in the browser. this fixes the public display without changing score calculation or the stats stored by stable. the server is still around 82% of the way to the invite-only build; the next website slice is secure staff sessions and the BN/admin screens.
