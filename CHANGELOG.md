# changelog

This is the honest version of what changed in zigcho. I am not calling a phase done because a health endpoint went green. Each entry says what landed, what I checked on the public server, and what is still between this build and something I would let players rely on.

## 2026-08-09 — the real lazer client can speak our account format

I built the official osu! source at one pinned commit with zigcho's production and development endpoints. The client reached `api.kai.ovh` over TLS and gave us a useful failure instead of a synthetic guess: its registration body uses nested `user[...]` fields, while zigcho only understood the short curl fields.

The server now decodes the exact form shape lazer sends, including spaces and escaped characters, and accepts its raw password without creating a second account system. Stable's MD5 credential and lazer's raw password land on the same stored secret, still wrapped with Argon2id. The harmless but noisy seasonal-background startup request has a real empty response now too.

The first public registration check found one narrow password edge case: a 32-character raw password was being treated as stable's 32-character MD5 shape before its contents were checked. Only an all-hex value is treated as a stable credential now. A 32-character lazer password stays a raw password like it should.

The endpoint overrides, pinned upstream revision, and apply script are checked in. The macOS app I used is still an ad-hoc signed QA build. The next proof is registration and sign-in through the deployed server, then following the client's next authenticated request instead of pretending this one fix means lazer is finished.

## 2026-08-09 — beatmaps and real PP

I added the first real performance path. Stable standard scores are calculated from the exact `.osu` file we have stored, using `rosu-pp` 4.0.1 with the full Rust dependency lock checked in. If the file is missing, malformed, suspicious, or the calculation fails, the score is rejected. It does not get a made-up value and it does not quietly land with zero PP.

There is a local `zigcho-import` command now. It reads the map IDs, metadata, mode, difficulty values, BPM, length, and objects, calculates stars and maximum combo, and stores the original file plus its MD5 in SQLite. Imports start as pending unless I deliberately give them a ranked or approved status. Normal ranked plays update weighted player PP. Relax PP is kept on the relax score and does not leak into normal stats.

The pinned fixture currently covers stable osu!standard. It produces the same 1.7931 stars and 26.80pp on every checked build. Taiko, catch, mania, and lazer scoring need their own locked fixtures before I let those paths award PP.

Where this leaves us: the service is already live as infrastructure and the core stable login, chat, presence, score, replay, leaderboard, account, and token paths exist. I would call it roughly one third of the way to an invite-only player alpha, not a finished live server. The biggest blockers are beatmap search and downloads, full real-client runs against the public hosts, complete multiplayer state, moderation and backup tooling, and the custom lazer client/rooms work.

## 2026-08-09 — public request limits

I split registration, token, login, score, and authenticated traffic into separate limits, capped request bodies by route, and made overload fail closed. The live proxy address is used as the client boundary and blocked requests return a real retry time. I checked the public hosts, the direct origin, oversized uploads, and the database after deployment.
