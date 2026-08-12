# /np finally means /np

kai was doing this backwards. opening a map could trigger a pp message from the status packet, while the actual `/np` action still needed another bot command after it. stable already sends the exact map link when somebody uses `/np`, whether they are playing or sitting in a menu, so that link is the map now.

send `/np` to kai and it remembers the difficulty, mode, and mods, then gives the 90/95/98/99/100 pp spread. `!with` still changes the hypothetical play. the fake `!pp` and `!np` commands are gone from help because neither of them should exist.

profiles are split properly too. pinned plays come first, top plays are the player's ranked or approved bests sorted by pp, and recent plays stay chronological. failed attempts are still red, still say `failed`, and still show no pp. `/np` followed by `!pin` or `!unpin` manages the selected map. each vanilla, relax, or autopilot ruleset slice gets three pins, and pinning the same map again moves it to the newer best instead of making a duplicate.

schema 16 stores those pins in PostgreSQL and keeps the SQLite import and rollback path in sync. the release activator now checks the backup against the schema that was actually running before the upgrade. if a candidate fails after migrating, it restores both the old database and the old executable instead of putting a schema-15 binary in front of schema 16 and hoping for the best.

Debug and ReleaseSafe passed 98/98 against disposable real PostgreSQL, including the 15 to 16 migration. i checked the actual profile at desktop and phone width too: the score rows do not run together, the country is still a real flag, failed plays stay red without pp, and there is no horizontal overflow or browser error.

this puts the invite build around 90%. the main Stable path is working; what is left is the less glamorous open-launch work around longer player soak time, cache and retry cleanup, and more locked scoring fixtures. lazer stayed untouched.
