# changelog

This is the honest version of what changed in zigcho. I am not calling a phase done because a health endpoint went green. Each entry says what landed, what I checked on the public server, and what is still between this build and something I would let players rely on.

## 2026-08-09 — beatmaps and real PP

I added the first real performance path. Stable standard scores are calculated from the exact `.osu` file we have stored, using `rosu-pp` 4.0.1 with the full Rust dependency lock checked in. If the file is missing, malformed, suspicious, or the calculation fails, the score is rejected. It does not get a made-up value and it does not quietly land with zero PP.

There is a local `zigcho-import` command now. It reads the map IDs, metadata, mode, difficulty values, BPM, length, and objects, calculates stars and maximum combo, and stores the original file plus its MD5 in SQLite. Imports start as pending unless I deliberately give them a ranked or approved status. Normal ranked plays update weighted player PP. Relax PP is kept on the relax score and does not leak into normal stats.

The pinned fixture currently covers stable osu!standard. It produces the same 1.7931 stars and 26.80pp on every checked build. Taiko, catch, mania, and lazer scoring need their own locked fixtures before I let those paths award PP.

Where this leaves us: the service is already live as infrastructure and the core stable login, chat, presence, score, replay, leaderboard, account, and token paths exist. I would call it roughly one third of the way to an invite-only player alpha, not a finished live server. The biggest blockers are beatmap search and downloads, full real-client runs against the public hosts, complete multiplayer state, moderation and backup tooling, and the custom lazer client/rooms work.

## 2026-08-09 — public request limits

I split registration, token, login, score, and authenticated traffic into separate limits, capped request bodies by route, and made overload fail closed. The live proxy address is used as the client boundary and blocked requests return a real retry time. I checked the public hosts, the direct origin, oversized uploads, and the database after deployment.
