# stable remembers the machine now

stable already sends its client build and machine fingerprint on every login. zigcho was throwing most of that away. it now checks the complete login shape, stores the four hashes with first and last seen times, and counts repeat sightings. the raw adapter list is only used to validate the client packet. it does not go into the database.

one matching value is not enough to punish anyone. an automatic restriction needs the adapter, uninstall, and disk hashes to match the same other account. the common empty and zero signatures are ignored for enforcement too. when the complete fingerprint matches, both accounts are restricted in one transaction, the old live session is removed, and the action is left in the audit log with the matched account ID. restricted players get stable's real restricted packet and can only see the normal online players; they are not announced back to everybody else.

the old lastfm anticheat flags follow the same careful line. the two direct hq!osu detections restrict and disconnect. the leftover registry flag is logged, but it does not roll dice with somebody's account.

kai is properly staff now as well. user ID 3 keeps the admin and developer server bits, and its stable presence carries the owner and developer colour bits instead of looking like a normal player.

77 tests pass in Debug and ReleaseSafe. the same tests and full ReleaseSafe build pass in the pinned Zig 0.16.0 x86 Linux image. coverage includes real Windows and Wine login shapes, malformed fingerprints, repeat sightings, partial matches, common signatures, exact dual restrictions, disconnecting the matched session, restricted presence, client flags, and kai's actual presence packet.

this is still a Debug alpha. I would call it around 77% of the way to the invite-only Stable server being safe for other players. the next infrastructure phase is moving the runtime to the PostgreSQL server already on the host, before chat history, admin tools, map ranking, and the public player site make the SQLite cutover larger.
