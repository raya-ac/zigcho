# changelog

This is the honest version of what changed in zigcho. I am not calling a phase done because a health endpoint went green. Each entry says what landed, what I checked on the public server, and what is still between this build and something I would let players rely on.

## 2026-08-09 — map ranks stop lying and failed plays get through

Zigcho's map table uses an internal status enum, while stable leaderboards, stable Direct and lazer all want different values. I was returning the database number directly to stable and had the Direct conversion wrong too. Pending became ranked. Ranked became approved. There are explicit conversions now for pending, ranked, approved, qualified and loved on every client surface. The Nerinyan data and cached rows were already correct; this fixes the wire response instead of rewriting good data to compensate for a protocol bug.

The first live score rejection reason also found that stable sends an empty replay file for a failed play. Zigcho checked for replay bytes before decrypting the score, so it rejected the request before it knew the play had failed. Replay validation now happens after parsing: failed scores may have an empty replay, passed scores may not, and the size cap still applies to both.

The next live trace found the 2026 stable client sends one trailing score field beyond the older 18-field shape. The established server parser already ignores trailing values after validating the original score fields; Zigcho required exactly 18. It now accepts one bounded trailing client field, still validates the original map, user, counts, checksum, mode, time and flags, and rejects a second extension instead of turning the payload into an open-ended format.

All 31 tests and the ReleaseSafe build pass locally. The next public proof is the corrected map state in stable followed by a passed score, replay download, leaderboard row and player-stat update. Until those are visible in the installed client, this is a fixed build waiting for acceptance—not a finished score path.

## 2026-08-09 — maps stop being unsubmitted when stable opens them

Stable now fills a missing map from Nerinyan on the first leaderboard request. Zigcho looks up the exact MD5, downloads that set, opens only bounded `.osu` entries, verifies the ZIP CRC and the file MD5, checks the map and set IDs again, calculates stars and max combo, then stores the map and archive together. A bad mirror response stays unsubmitted instead of becoming trusted data. No osu! API key is in the repo or the server.

I ran the whole path from a fresh database against Nerinyan's real map 75. The old response was unsubmitted. The new response was ranked, the exact 4,931-byte map landed under its expected MD5, and the set archive was cached for stable Direct and lazer downloads.

Public chat no longer comes back through Bancho to its sender, which removes the second copy beside the client's own local message. Stable's seasonal and menu-content startup requests also have proper empty responses now instead of 404s.

This moves the real invite-only alpha estimate to about 44%. Stable can create an account, log in, chat, resolve a ranked map, show a leaderboard, and has the score/replay path behind it. I still need the installed client to prove this exact public build, upstream timeout/retry and cache controls, wider mode scoring fixtures, moderation and backups, complete multiplayer, and the rest of lazer's signed-in flow.

## 2026-08-09 — the real lazer client can speak our account format

I built the official osu! source at one pinned commit with zigcho's production and development endpoints. The client reached `api.kai.ovh` over TLS and gave us a useful failure instead of a synthetic guess: its registration body uses nested `user[...]` fields, while zigcho only understood the short curl fields.

The server now decodes the exact form shape lazer sends, including spaces and escaped characters, and accepts its raw password without creating a second account system. Stable's MD5 credential and lazer's raw password land on the same stored secret, still wrapped with Argon2id. The harmless but noisy seasonal-background startup request has a real empty response now too.

The first public registration check found one narrow password edge case: a 32-character raw password was being treated as stable's 32-character MD5 shape before its contents were checked. Only an all-hex value is treated as a stable credential now. A 32-character lazer password stays a raw password like it should.

The first real token login found the next contract difference. The official framework sends `AddParameter()` bodies as multipart form data, including registration and OAuth. Zigcho now accepts both that real client body and the URL-encoded operator/curl body. The regression fixture uses the framework's exact boundary and the local integration run covers multipart registration, token issue, and `/me` together.

Registration through the deployed custom client now succeeds. Its first post-token request is `/api/v2/me/` with a trailing slash, while zigcho only matched `/api/v2/me`. API routes now canonicalize one trailing slash without turning the root page into an empty path.

The endpoint overrides, pinned upstream revision, and apply script are checked in. The macOS app I used is still an ad-hoc signed QA build. The next proof is registration and sign-in through the deployed server, then following the client's next authenticated request instead of pretending this one fix means lazer is finished.

## 2026-08-09 — beatmaps and real PP

I added the first real performance path. Stable standard scores are calculated from the exact `.osu` file we have stored, using `rosu-pp` 4.0.1 with the full Rust dependency lock checked in. If the file is missing, malformed, suspicious, or the calculation fails, the score is rejected. It does not get a made-up value and it does not quietly land with zero PP.

There is a local `zigcho-import` command now. It reads the map IDs, metadata, mode, difficulty values, BPM, length, and objects, calculates stars and maximum combo, and stores the original file plus its MD5 in SQLite. Imports start as pending unless I deliberately give them a ranked or approved status. Normal ranked plays update weighted player PP. Relax PP is kept on the relax score and does not leak into normal stats.

The pinned fixture currently covers stable osu!standard. It produces the same 1.7931 stars and 26.80pp on every checked build. Taiko, catch, mania, and lazer scoring need their own locked fixtures before I let those paths award PP.

Where this leaves us: the service is already live as infrastructure and the core stable login, chat, presence, score, replay, leaderboard, account, and token paths exist. I would call it roughly one third of the way to an invite-only player alpha, not a finished live server. The biggest blockers are beatmap search and downloads, full real-client runs against the public hosts, complete multiplayer state, moderation and backup tooling, and the custom lazer client/rooms work.

## 2026-08-09 — public request limits

I split registration, token, login, score, and authenticated traffic into separate limits, capped request bodies by route, and made overload fail closed. The live proxy address is used as the client boundary and blocked requests return a real retry time. I checked the public hosts, the direct origin, oversized uploads, and the database after deployment.
