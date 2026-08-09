**zigcho update — map ranks tell the truth and failed plays submit properly**

Map status had an offset on the wire. Zigcho kept its own internal values, then sent them straight to stable even though stable uses a different set of numbers. That made pending maps look ranked and ranked maps look approved. Stable, Direct and lazer now each get an explicit status conversion, including qualified and loved. The cached map rows were already correct, so there is no fake database rewrite hiding this.

The new live rejection log found the actual break on the first try: stable sends an empty replay file when a play fails, but Zigcho was rejecting every empty replay before it decrypted the score and found out whether the play passed.

Replay validation now happens after the score is parsed. A failed play can carry the empty replay stable actually sends. A passed play still needs replay data, and every replay still has the same 16 MiB limit.

I added the complete pending/ranked/approved/qualified/loved conversion matrix and the failed, passed and oversized replay cases to the tests. The old Direct test caught itself expecting the broken ranked value, which is fixed too. All 31 tests and the full ReleaseSafe build pass.

The passed 2026 client submission decrypts to 19 fields instead of the older 18-field fixture. The established server parser reads the original fields and ignores trailing values. Zigcho now accepts one bounded trailing client field while keeping the original validation and checksum intact, and rejects anything beyond it.

We are about 46% of the way to an invite-only alpha. This closes the real failed-score compatibility bug. The next proof is a passed installed-client score showing up in SQLite, the leaderboard, replay download and player stats before I call the stable score path working.
