# stable is finished for this slice

the last client-shaped gaps are closed. beatmap info, comments, unread private messages, map and forum links, difficulty redirects, no-video downloads, and the small peppy compatibility routes now answer the way Stable expects instead of falling into generic pages or dead endpoints.

PP is ours now too. the Rust bridge and Akatsuki calculator are gone, and all four Stable modes run through one bounded Zig engine. Relax keeps std, taiko, and catch; Autopilot stays std-only; sliders, holds, combo, hit results, and the Stable mod set are all handled locally. this is our own versioned model, so I am not pretending every value is bit-for-bit Akatsuki. the server records the engine version and recalculates old plays and player totals when that version changes, which means the database cannot quietly mix two calculators.

Stable mail now survives reconnects properly. online and offline DMs stay unread until the client marks them read, login replays them with the sender header Stable uses, and the tests cover live delivery, offline delivery, replay, and clearing the unread state. beatmap comments are stored in both SQLite and PostgreSQL with the same supporter and BN presentation the client expects.

I cleaned up the last scoring details around this as well. grades follow each ruleset, native max combo feeds `/np` and `!with`, malformed score and comment values fail safely, and the bigger legacy request bodies stay bounded instead of becoming an allocation trap.

the database is schema 20 now. the SQLite to PostgreSQL importer matched every application table, row count, and blob byte. Debug and ReleaseSafe both passed 127/127 against real PostgreSQL, the Stable HTTP smoke passed, live beatmap hydration passed, and the final pinned Debian x86_64 build produced the exact native release artifacts.

lazer and BSS were left alone. this closes the Stable slice first, exactly like we said.
