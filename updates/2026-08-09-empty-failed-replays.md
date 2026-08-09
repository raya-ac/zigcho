**zigcho update — map ranks tell the truth and failed plays submit properly**

Map status had an offset on the wire. Zigcho kept its own internal values, then sent them straight to stable even though stable uses a different set of numbers. That made pending maps look ranked and ranked maps look approved. Stable, Direct and lazer now each get an explicit status conversion, including qualified and loved. The cached map rows were already correct, so there is no fake database rewrite hiding this.

The new live rejection log found the actual break on the first try: stable sends an empty replay file when a play fails, but Zigcho was rejecting every empty replay before it decrypted the score and found out whether the play passed.

Replay validation now happens after the score is parsed. A failed play can carry the empty replay stable actually sends. A passed play still needs replay data, and every replay still has the same 16 MiB limit.

I added the complete pending/ranked/approved/qualified/loved conversion matrix and the failed, passed and oversized replay cases to the tests. The old Direct test caught itself expecting the broken ranked value, which is fixed too. All 31 tests and the full ReleaseSafe build pass.

The passed 2026 client submission decrypts to 19 fields instead of the older 18-field fixture. bancho.py reads the original score fields and ignores trailing client values, so Zigcho does the same while keeping the original validation, checksum and request-size limit intact.

The final 401 was another contract mismatch. bancho.py requires the score token header but authenticates the encrypted username and password against the online player; it does not use that header value as the identity. Zigcho demanded the exact current session token, which breaks queued retries around a restart. That check now follows bancho.py, including its one-space supporter marker handling.

The installed stable client accepted the score after the fix. Score `1` landed on map `5028316` with `565,898`, `66.22pp`, `171x`, vanilla best and an `18,274`-byte replay. Map plays/passes and raya's stats updated, and SQLite still returns `ok`.

The stats display needed one more real fix. Zigcho was saving every value, then sending literal zeros in Bancho's user-stats packet. Login, status requests and successful score submissions now publish the selected mode's stored ranked score, total score, accuracy, plays, max combo, PP and PP rank. The installed client visibly shows them now. At the last check raya was on three plays, `94pp`, `886,224` ranked score, `1,672,654` total score, `97.74%`, and `227x`.

We are about 47% of the way to an invite-only alpha. The real stable score path now works through the installed client, but I still need replay download acceptance, more modes and mods, duplicate behavior, restore drills, moderation, multiplayer and the rest of lazer before this is live-player ready.
