# changelog

## 2026-08-13 — stable social state actually survives a reconnect

friends are real stored relationships now. they are directional, kai stays in every player's list as ID 3, and login sends the complete Stable friends packet before the client starts asking for people again. add and remove packets update PostgreSQL even when the other player is offline.

the private-message switch works too. a player blocking non-friend DMs gets Stable's proper blocked packet, friends still get through, and an AFK player can send their away reply without eating the original message. presence-all restores every unrestricted online player and the client's friends-only update choice is kept on the session.

the old friends and favourites web routes are no longer empty placeholders. they require the real online Stable account, return the stored IDs, keep duplicate favourites idempotent, and use the exact response text the client expects.

## 2026-08-13 — stable scoring is pinned across every mode now

Stable PP has fixed snapshots for osu!, taiko, catch, and mania across no-mod, HD, HR, DT, miss, and FC paths. the stored-score matrix keeps vanilla, relax, and autopilot stats separate and proves failed plays only add the aggregates they are meant to add.

BNs can put a complete set straight into pending, qualified, ranked, approved, or loved from `/np` chat commands or the staff site. the decision works from any previous status, repairs mixed-status sets, freezes every difficulty together, rebuilds stored player stats, and keeps its written history.

## 2026-08-13 — map downloads stop hammering the same broken set

beatmap hydration has durable retry state now. failed upstream work backs off from 30 seconds to six hours and stays backed off across a restart. the `.osz` cache has a 2 GiB default ceiling and evicts the least recently used replaceable archives instead of growing inside PostgreSQL forever.

local metrics expose the cache size, pending failures, retry skips, outcomes, and evictions. schema 17 carries all of it through SQLite, PostgreSQL, imports, backups, restores, and rollback. the live daily backup timer now runs the verified dump-and-restore path automatically.

## 2026-08-11 — postgres has a real way in now

the live server is still on SQLite for this phase. I am not going to swap the database underneath bancho while half the storage calls still speak SQLite. what landed is the part that makes the eventual cutover measurable instead of hopeful.

there is a proper PostgreSQL schema under its own `zigcho` namespace, with booleans, jsonb, bytea, foreign keys, identities, and the indexes the current score and map paths need. libpq connections sit behind a hard eight-connection pool instead of growing with request count.

`zigcho-migrate-postgres` reads a stopped version 12 SQLite database in read-only mode. it refuses an old schema and refuses any target where the `zigcho` namespace already exists. the schema and all 13 tables are copied inside one serializable transaction. identity sequences are reset after the copy, then every table count and the total blob bytes are compared before commit. replay, map, archive, token, and password bytes do not get a special "probably fine" exception.

the migration fixture covers every table. PostgreSQL returned the replay byte-for-byte, stored the intended boolean/jsonb/bytea types, and rejected a second import. the pool test also opens both available connections, makes a third worker wait, and proves the lease is returned cleanly.

stable multiplayer and spectating are accepted for this alpha, so they are no longer blocking the rest of the server. the next database phase is the actual runtime port and stopped-data cutover. after that comes the full chat/admin command set, BN+ ranking, and the player site.

## 2026-08-11 — stable remembers the machine and kai looks like staff

zigcho now reads stable's complete login fingerprint instead of throwing it away. it stores the four hashes, client build, Wine state, first and last seen times, and repeat count. the raw adapter list is validated and then discarded.

automatic multiaccount restrictions need an exact adapter, uninstall, and disk match against the same other account. one matching value is only evidence. common empty and zero hashes cannot trigger it either. an exact match restricts both accounts atomically, records who matched who, disconnects the older live session, and gives the new login stable's restricted packet without announcing that player to everyone else.

the hq!osu assembly and file flags restrict and disconnect. the leftover registry flag is logged without the old random restriction behavior.

kai at user ID 3 now has durable admin and developer privileges. its real Stable presence packet carries both colour bits. 77 tests pass in Debug, ReleaseSafe, and the pinned x86 Linux build.

## 2026-08-11 — stop making every login wait for one password

login held the global session lock, then called into SQLite, then ran Argon2 while SQLite was still locked. one slow password check could make polling, another login, and unrelated database reads line up behind it.

authentication copies the user and credential bytes while SQLite is locked, then releases it before Argon2 or the old SHA compatibility check runs. registration hashes before taking the write lock too. an old credential upgrade now hashes outside the lock and only updates if the stored old hash is still the one that was checked.

bancho login authenticates and updates the country before touching the session list. the locked part now prunes, replaces the session, copies its token, and takes owned snapshots of online presence. stats reads and packet building happen after unlock. the HTTP result owns both its token and body, so another login can replace that session without leaving a response header pointing at freed memory.

stable score tokens got the compatibility rule we chose. the current token must belong to that user. another live player's token is a `401`. an unknown token is still allowed when the password-authenticated user is online, which keeps queued submissions working after a restart. missing stays `401`; offline stays stable's `error: no` retry response.

the allocation test found one more real leak while doing this: `Sessions.create` lost its allocated session object if the session-list append failed. that constructor rolls itself back now.

56 tests pass in Debug and ReleaseSafe. they cover the old credential upgrade, concurrent valid/invalid auth with database reads and Bancho polling, session replacement after login, the complete score-token matrix, and every induced allocation failure in the login path.

## 2026-08-11 — dead sessions stop staying online forever

the session list tracked `last_seen` but never did anything with it. logout returned an empty response without removing the player, a client that vanished stayed online forever, and every broadcast could keep growing that dead client's queue.

logout removes the session now and broadcasts the proper `user_logout` packet with the user ID and trailing zero byte. I checked bancho.py's current behavior here too: osu! sometimes sends a bogus logout 300–800 ms after login, so logout is deliberately ignored during the first second instead of instantly kicking a fresh client.

idle sessions expire after 300 seconds, matching bancho.py's `OSU_CLIENT_MIN_PING_INTERVAL`. cleanup happens under the same session lock as token polling. reconnect replacement, explicit logout, idle expiry, and queue overflow all leave the remaining clients with a logout event instead of ghost presence.

outgoing queues have a hard 1 MiB ceiling now. crossing it frees the queued allocation immediately, marks that client overflowed, and removes it on its next poll through the normal restart path. later broadcasts do not start growing the queue again while it waits.

51 tests pass in Debug and ReleaseSafe. the new coverage sends the real client logout packet, checks the first-second exception, forces a session past five minutes, fills a queue exactly to its cap, crosses it, and checks removal.

## 2026-08-11 — stop letting request memory outlive the request

the review found three real lifetime bugs in current main, so those came before adding another surface.

`config.ini` values were slices into a 4 kb stack buffer that disappeared as soon as startup parsing returned. they are owned allocations now and stay valid for the life of the app.

bancho looked up a raw session pointer without the session lock, then locked later when it started polling. a reconnect between those two steps could destroy the session while the old request still held it. token lookup and packet handling are one locked operation now. a replaced token gets the normal restart packet instead of touching freed memory.

the async score worker had six borrowed or duplicated score strings with no complete owner, plus leaks when pp calculation, setup, or thread creation failed. there is one owned submission and one destructor now. the map file stays with the request until the worker has actually accepted ownership, and the worker frees every field when it finishes or fails.

48 tests pass in Debug and ReleaseSafe. the new regressions overwrite the original config/request buffers and replace a live session before polling its old token. this closes the review's three P0s. it does not make zigcho public-ready: logout/expiry, queue caps, tighter lock scopes, hostile score parsing, and proxy/json hardening are the next reliability block.

## 2026-08-11 — stop putting stable credentials in the journal

the `/web/lastfm.php` debug line printed the entire query string before authentication. stable puts its reusable password credential in `ha`, so that one "temporary" log line was writing it straight into journald. removed it. the useful post-auth log already records the user ID, action, flags, and beatmap field without the password.

I checked the source for other raw request, authorization, token, and password logging while I was here. this was the only line printing a credential-bearing request.

## 2026-08-11 — old maps hydrate properly

some older `.osu` files don't contain `BeatmapID` or `BeatmapSetID` at all. the live server downloaded one of these sets, found the exact difficulty by md5, verified the zip and crc, then threw the map away as `InvalidBeatmap` because those two fields were missing. the archive was fine. the parser was being stricter than the file format's history allows.

hydration now carries the map and set IDs from the osu API metadata request into the archive worker. if the old file omitted those fields, it fills them from that already-verified response. if the file does contain IDs and they disagree with the API, it still gets rejected. the exact failing live set was Basshunter's `Ievan Polkka Trance Remix`, set 10406, difficulty md5 `f03510b839a01ec1a1dcc71f24d9c596`.

there was a second bug hiding behind it. once metadata had been stored, later leaderboard requests assumed the full `.osu` file was ready and never retried a failed archive. hydration now checks for the file itself. metadata-only rows stay eligible for another attempt, while the in-progress guard still stops duplicate downloads.

the regression tests cover legacy ID fallback, modern IDs not being overwritten, and metadata-only maps remaining retryable until their real file is stored.

This is the honest version of what changed in zigcho. I am not calling a phase done because a health endpoint went green. Each entry says what landed, what I checked on the public server, and what is still between this build and something I would let players rely on.

## 2026-08-09 — scores submit again and leaderboards show the real play time

Two bugs on the score path. Both are fixed on main, not yet deployed.

Every score submission was getting rejected with `checksum_mismatch` — vanilla, relax, all of them. The checksum formula itself was correct; I verified it byte-for-byte against bancho.py's exact code. The problem was the username. The real stable client sends the username in the score data with a trailing space glued on (`raya ` not `raya`) — a donor marker — but it signs the online checksum with the clean name. bancho.py never hits this because it reads `player.name` from the database, which never has the space. zigcho was using the raw wire field with the space, so the hash it built could never match the one the client sent. The fix trims the trailing space before building the checksum string, same thing bancho.py gets for free from the db lookup. I captured a real submission off the live server, decrypted it, and the trimmed name produces the exact checksum the client sent. Added a regression test with a trailing-space username.

Separately, every leaderboard row was sending the play date as a formatted string (`2026-08-09 03:42:38`) instead of the raw unix timestamp the client expects (bancho.py sends `unix_timestamp(play_time)`). The client couldn't parse the string, so it fell back to showing the current time. The stored time was never wrong — the bug was only in the wire response. Both leaderboard selects now read `s.submitted_at` directly and the row formatter writes it as an integer.

`zig build test` passes. Relax was broken by the same checksum line, so it submits again too once this builds.

## 2026-08-09 — map ranks stop lying and failed plays get through

Zigcho's map table uses an internal status enum, while stable leaderboards, stable Direct and lazer all want different values. I was returning the database number directly to stable and had the Direct conversion wrong too. Pending became ranked. Ranked became approved. There are explicit conversions now for pending, ranked, approved, qualified and loved on every client surface. The Nerinyan data and cached rows were already correct; this fixes the wire response instead of rewriting good data to compensate for a protocol bug.

The first live score rejection reason also found that stable sends an empty replay file for a failed play. Zigcho checked for replay bytes before decrypting the score, so it rejected the request before it knew the play had failed. Replay validation now happens after parsing: failed scores may have an empty replay, passed scores may not, and the size cap still applies to both.

The next live trace found the 2026 stable client sends one trailing score field beyond the older 18-field shape. bancho.py reads the original score fields and ignores later client values; Zigcho required exactly 18. It now does the same inside the existing decrypted-body limit while still validating the original map, user, counts, checksum, mode and time.

The last break was auth. bancho.py requires the score `token` header to exist, but it does not use that token value as the player's identity. It verifies the encrypted username and password against the online player. Zigcho required exact equality with the current in-memory session token, so a queued score retry stayed unauthorized after a server restart even once the player reconnected. The score path now follows bancho.py: trim stable's one supporter marker only for account lookup, verify the password, require that user ID to be online, and leave the supplied token out of identity selection.

The installed client passed after that change. Production data has score `1` on map `5028316`: `565,898`, `66.22pp`, `171x`, vanilla best, with an `18,274`-byte replay. The map is at one play and one pass. Raya's standard stats moved to one play, `565,898` ranked and total score, `66pp`, `97.66%`, and `171x`. SQLite integrity is still `ok`. This is the first real stable score accepted end to end on kai.ovh.

The score saved correctly but the in-client stats stayed at zero. That was not a cache problem: Zigcho's Bancho `user_stats` packet still had literal zeros for ranked score, accuracy, plays, total score, rank and PP. Those packets now read the selected mode from SQLite on login and status requests, calculate the PP rank, and are published again after every stable score. The installed client now visibly shows the updated stats. At the last check raya had three plays, `94pp`, `886,224` ranked score, `1,672,654` total score, `97.74%`, and `227x`; SQLite integrity remained `ok`.

The full tests and Debug build pass locally and on the x86 host. The installed client now proves map status, score acceptance, PP, replay persistence, counters, and live stats. Replay download and duplicate/mod acceptance still need their own visible client checks before the whole stable score surface is closed.

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

## 2026-08-10 — score submissions are async and hydration runs in background threads

Score submissions held the database locked for the entire insert, stats recalc, and webhook call. Two people submitting at the same time meant the second waited for the first to finish completely. The heavy path — SQLite transaction, player stats update, beatmap counters, and the Discord webhook POST — now runs in a detached background thread with its own copy of all the data. The HTTP response returns `"error: no"` immediately; the client treats that as "score accepted." The next leaderboard request picks up the new score. Validation still happens synchronously: decrypt, checksum, auth, beatmap lookup, and PP calc run on the request thread. Only the database write and post-processing got moved out. The `Submission` struct's string fields (`map_md5`, `grade`, `online_checksum`, `client_time`, `client_flags`) all point into the decrypted buffer, so each gets `allocator.dupe` before the thread takes ownership. The replay bytes and map file are duped the same way.

Beatmap hydration moved to background threads at the same time. The first leaderboard request fetches metadata from osu API v1 — title, artist, difficulty, star rating, max combo — and stores it immediately so the leaderboard renders with full map info even though nobody has played it yet. The heavy part (downloading the archive from hinamizawa, extracting the `.osu`, running rosu-pp for precise attributes) happens in a background thread. Each map gets its own thread with its own HTTP client, so multiple maps download at the same time without blocking each other or the request that triggered them.

The webhook is fire-and-forget too. Each score submission spawns a detached thread with its own `std.http.Client` for the Discord POST, so the score response is never blocked by Discord's latency. The previous version blocked the response writer on the webhook call; the client saw a delay on every score submission proportional to Discord's round-trip time.

## 2026-08-10 — kai bot commands and auto-pp

Kai can answer PP questions now. PM kai in-game with `!np` and it calculates PP for whatever map you are currently playing, using whatever mods you have on. `!with HDHR 98% 5m` lets you spec out a custom scenario — mods, accuracy, miss count — and get PP for a hypothetical play on your current map. The mod parser handles two-letter combos like HDHR, DTHD, FL. Accuracy converts to hitcounts using the map's object count; misses subtract from 300s. All the math goes through rosu-pp, same as score submission.

When you `/np` in-game (which the client sends as a status change), kai automatically PMs you the PP. You do not have to ask. The bot reply path was broken at first — kai was trying to send the reply to the bot's own session instead of the player who sent the PM. The fix routes replies back through `sessions.byToken` using the sender's token from the incoming message.

## 2026-08-10 — user geolocation and map logging

On the first login, the server looks up the client IP through `ip-api.com` and stores longitude and latitude in the `Session`. Presence packets carry both coordinates so other clients can see where players actually are. Kai is pinned to Reykjavik — longitude -21.9426, latitude 64.1466 — threshold between tectonic plates. The presence wire format puts longitude before latitude, both f32; this matches bancho.py's `services.py` exactly. Unknown or missing locations stay the default instead of inventing one.

Every step of the score path, hydration pipeline, and bot command flow now has colored log output. Green for success, red for failure, yellow for important values, cyan for context, blue for maps, magenta for PP. The box-drawing looked nice but interleaved between concurrent requests, so the hydration background threads switched to single-line `std.log.info` entries instead. Background threads must not use `std.debug.print` with box-drawing characters — it causes interleaved output.

## 2026-08-10 — beatmap metadata and mirror swap

Beatmap metadata switched from Akatsuki's Cheesegull to osu API v1. Cheesegull was returning stale or missing data for maps nobody had played yet. The osu API gives `difficultyrating`, `max_combo`, `total_length`, `bpm`, `artist`, `title`, `version`, and `creator` directly, same region as the server, fast. The leaderboard now shows correct star rating and combo on the first render, before rosu-pp runs in the background. The `OsuV1Map` struct expanded to include all the fields the leaderboard needs.

The archive mirror switched from Nerinyan to hinamizawa (osu.direct). Hinamizawa does not serve archives directly — it returns a tiny JSON blob with a `download_url` field pointing at osu.direct. The hydration code was treating that JSON as the actual archive and trying to unzip 160 bytes of `{"success":true,...}`. Now it parses the JSON, extracts the `download_url`, and follows it. Video downloads are skipped with `?noVideo=true` to save bandwidth.

## 2026-08-10 — score webhook

Score submissions post to Discord when the result is interesting. Top 10 on any map or any play over 500 PP gets a webhook with the player name, grade, mods, combo, accuracy, PP, star rating, rank on map, and the beatmap name. The embed description had nested JSON strings — `std.json.Stringify.value` wraps each value in quotes, so `""Artist" - "Title" [""Version""]"` is what Discord actually received. Now the description text is built into a buffer first and stringified once.

The webhook URL lives in `config.ini` under `score_webhook` and is not in the repository. Errors are logged to stdout now instead of vanishing into the void.

## 2026-08-10 — crash fixes and build improvements

A Zig 0.16.0 edge case: `std.http.Server.Request.iterateHeaders()` hits `unreachable` after the body has been consumed via `readerExpectContinue`. The score handler was reading the body first, then iterating headers to extract the client IP. The fix extracts `client_ip` before the body read. This was the most common crash on the public server.

Docker build got faster. The Rust PP library compile uses a release profile with LTO and `codegen-units=1`. The bare `zig build` on the server has no cargo, so the Dockerfile handles everything. BuildKit is not available on the server (no buildx, Docker 29.1.3), so the build uses plain `docker build`.

Stale token handling changed. Instead of returning 401 on a missing session, the server now sends `notification("Server has restarted.") + restart_server(0)` — matching bancho.py's approach at `app/api/domains/cho.py:213-221`. The client auto-reconnects after seeing this instead of staying on a dead screen. The previous attempt used a `sigwait` thread to broadcast restart packets on SIGTERM, but it timed out and got SIGKILL after 15 seconds. The stale-token approach is simpler and more reliable.

## 2026-08-09 — public request limits

I split registration, token, login, score, and authenticated traffic into separate limits, capped request bodies by route, and made overload fail closed. The live proxy address is used as the client boundary and blocked requests return a real retry time. I checked the public hosts, the direct origin, oversized uploads, and the database after deployment.

## 2026-08-11 — akatsuki-pp for real relax/autopilot PP, full recalc

The PP calculator was wrong for relax and autopilot. Vanilla `rosu-pp` 4.0.1 doesn't understand the relax (bit 7) or autopilot (bit 13) mod flags — it calculates PP as if you played the map without those mods, which gave nonsense values. Autopilot was especially broken because the calculator was running full aim calculations on scores where the player wasn't aiming at all.

Swapped to `akatsuki-pp` (osuAkatsuki/akatsuki-pp-rs on GitHub), which is Akatsuki's fork of rosu-pp with proper relax and autopilot formulas. The API is almost identical but based on an older rosu-pp: no `checked_calculate` (use `calculate`), no `check_suspicion`, no `osu_small_tick_hits` or `legacy_total_score` fields in `ScoreState`. Stripped those from the Rust FFI layer. The Zig side didn't change because the C struct boundary is identical. The `rosu-map` version pinned down from 0.2.1 to 0.2.0 to match akatsuki-pp's dependency.

PP values on relax and autopilot leaderboards now display as truncated integers via `@intFromFloat` in `writeBoardRow`. 18.81 PP shows as 18, not 1881 or 18.81. The deployed binary was stale from Aug 9 — it didn't have the PP leaderboard code at all, so it was reading the PP column as a raw integer through `sqlite3_column_int64` on a REAL column, which produced garbage.

Added a `recalc` subcommand: `zigcho recalc <db>`. It stops the server, walks every passed score, fetches the stored `.osu` file, recalculates PP with the new library, writes it back, then rebuilds weighted stats per user/mode/namespace. The stats rebuild correctly maps stats_mode back to (vanilla_mode, namespace): mode 0→vanilla/osu, mode 4→relax/osu, mode 8→autopilot/osu, etc. This was a bug in the first recalc attempt — it was filtering scores by `s.mode = stats_mode` but the scores table stores the vanilla mode (0), not the stats mode (4 or 8), so relax and autopilot stats came out as zero.

Ran it against all 27 existing scores. Vanilla PP stayed roughly the same (the formula is close). Relax and autopilot values shifted to Akatsuki's formula. User 4 mode 0 (vanilla) is now 424 PP, mode 4 (relax) is 130 PP, mode 8 (autopilot) is 338 PP.

The pinned test fixture updated from 26.80 PP / 1.7931 stars to 26.90 PP / 1.8065 stars. Same synthetic map, different formula, slightly different result. Tolerance widened slightly because the Akatsuki fork's difficulty calculation diverges a bit more from vanilla rosu-pp.
