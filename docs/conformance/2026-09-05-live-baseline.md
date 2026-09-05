# first live Stable comparison

this is a baseline, not a compatibility percentage or a claim that Stable is finished.

## what actually ran

- Zigcho: `4432170f207afb1926f2d2bd5eb3d13d27d5ce30`, downloaded from [release gate 33954375557](https://github.com/zigcho/zigcho/actions/runs/33954375557).
- reference: `osuAkatsuki/bancho.py@0651b54c66daa839c1bb3998e4f9a8d1173e144d`.
- harness: `da0ad5f`, [live run 33955760710](https://github.com/zigcho/stable-conformance/actions/runs/33955760710).
- two real processes, disposable PostgreSQL/MySQL/Redis/HTTPS object storage, and synthetic users/maps/replays on a GitHub runner. no production traffic or data.
- both source checkouts were clean and pinned. the separate runtime evidence records the downloaded binary hash, process ids and the reference fixture-bootstrap hash.

the reference bootstrap uses its normal lifespan, then establishes the bot's public-channel memberships through its own `join_channel` method. it also supplies the typed empty seasonal-background setting. its packet handlers are not replaced. Kai remains id 3; the reference bot remains id 1.

## result

all 12 transcripts were attempted, with **3 passing, 9 failing and 0 skipped**. there were also 17 failed status preflight comparisons. each case stops at its first failed step, so later steps in failed cases are **not tested**.

| transcript | result at this build |
| --- | --- |
| spectator | passed, including all 16 action/drain steps |
| tournament | passed, including all 9 action/drain steps |
| static PHP routes | passed, 3 steps |
| account policy / session presence | stopped at the idle map-checksum difference |
| malformed login / framing | stopped at an upstream connection close presented as HTTP 502 |
| multiplayer | stopped at the intentional bot identity difference in the match-created message |
| fixture reads | stopped at that same bot identity difference in friends |
| fixture writes | stopped at a cold reference map-cache precondition for ratings |
| delayed score / reconnect | stopped at a harness field-name mistake for protocol version |

## fixes from the evidence

the idle checksum was a real server bug: an unset 32-byte buffer was being sent as an osu! string full of NUL bytes. the reference sends an empty string. the follow-up serializes the stored checksum up to its first NUL and includes a literal 53-byte idle-stats fixture.

malformed login text could reach PostgreSQL before validation, and malformed packet parsing could escape the HTTP route without a response. the follow-up rejects invalid login text before lookup and returns HTTP 400 for the known packet-input errors, after releasing the per-user lock. other errors are not silently treated as client mistakes.

the harness also needed repairs. it now checks `payload.protocol_version`, warms the reference map cache independently of earlier transcript failures, and maps the two known bot ids only at explicit identity fields. it does not discard message text, counts, scores, mods, packet ordering or duplicate packets.

`--continue-on-failure` can collect cases after a semantic status mismatch only when both replies have already proved their expected authenticated user identities. those failed preflights still make the run fail. invalid or missing sessions still stop mutations.

## still not proved

the next [diagnostic run, 33956053774](https://github.com/zigcho/stable-conformance/actions/runs/33956053774), used harness `1cfcc19` against the same server artifact. after the explicit bot-id mapping, the **whole multiplayer transcript passed: 113 action/drain/group checks**. spectator, tournament and static routes still passed. overall: 4 passed, 8 failed, 0 skipped, with the known 17 idle-status preflight failures retained.

that run also exposed the next fixture and wire details. Direct search requires a stored archive on Zigcho; the initial synthetic sets had only metadata, so the runner now supplies real ZIP fixtures. inspection of the pinned Direct renderer confirmed that search results use osu!api status values, while set lookup uses the legacy map status and stops after the metadata fields. the follow-up separates those serializers in both database backends. rating averages now keep the reference's `.0` suffix for integer averages without rounding non-integer averages.

a clean full differential result is still outstanding. Ari explicitly deferred installed Stable checks and redacted client captures for now. that acceptance is not being counted as passed. this pass does not deploy or announce a release.

## explicit comparison boundaries

the follow-up review also found a hardcoded zero in the presence packet's global-rank field. the candidate uses the same owned stats snapshots as the status packets, including their selected namespace and session-generation checks. those database reads stay outside the global session lock and use the existing batch query. country-visibility updates take an owned snapshot and recheck the session before broadcasting.

[`3b78fd8` passed hosted gate 33958591854](https://github.com/zigcho/zigcho/actions/runs/33958591854): pinned production build, the six Stable correction filters in Debug and ReleaseSafe, PostgreSQL query parity in both builds, isolated HTTPS backup transfers and exact-binary PostgreSQL boot. this was the explicit `stable` test scope, **not** another full test-suite run. the batched Stable checks took 71 seconds. earlier follow-up runs were cancelled or superseded and are not counted as passing gates.

the reference bot has random status text and deliberately off-map coordinates. the harness checks each bot's presence and zero gameplay statistics independently, then compares ordinary players unchanged. Kai stays id 3; the reference stays id 1. that is a declared branding boundary, not exact bot parity.

the calculators are different too. this Zigcho build uses `stable-rosu-4.0.1-lazer-2026.730.0-1129a7e-akatsuki-591de0d.1`; the pinned reference uses `akatsuki-pp-py==1.0.5`. the runner records both versions. Ari confirmed that this difference is intentional: the reference's pp value is not an equality oracle for Zigcho. the earlier runs still report their raw differences, but those numbers alone are not a bug or a release blocker. this pass does not change either calculator.

## latest failed comparison and local audit

[run 33959425121](https://github.com/zigcho/stable-conformance/actions/runs/33959425121) used server `3b78fd8` and harness `093be6a`. setup completed and all status preflights passed. the result was **7 passing cases, 5 failing, 0 skipped**. account policy, malformed login, malformed framing, multiplayer, spectator, tournament and static routes passed. later steps after a case's first failure remain untested.

the mismatch report was inspected. reconnect fixtures rejected repeated presence/stats/channel packet types even though the initial login allowed them. the submission fixture omitted the reference's required `x`, `fs` and `c1` fields, producing HTTP 422. the resulting one-sided score write also made later rank comparisons invalid as a parity measurement. a separate real server defect left the leaderboard rating as a literal `0`, instead of its stored average with the expected decimal representation.

the local corrections add those multipart fields with hardware preimages matching the login, and permit repeated reconnect packet types while retaining the exact comparison with the original bootstrap. focused checks reject added/removed users or changed stats, and verify multipart fields, checksum order and replay content. leaderboard rating reads use the already-held database connection in both backends; existing SQLite and PostgreSQL tests now assert its wire field.

[`74fbc6a` passed full gate 33960729739](https://github.com/zigcho/zigcho/actions/runs/33960729739), including Debug and ReleaseSafe tests, the unfiltered PostgreSQL integration step with all nine database environment variables, query parity, backup transfers and binary boot. that does not retroactively make gate 33958591854 a full PostgreSQL pass. score-chart and calculator differences are still compared, not hidden.

## release held after the full gate

the latest [live run, 33962178345](https://github.com/zigcho/stable-conformance/actions/runs/33962178345), uses that exact server artifact and harness `5bae355`. **9 cases passed, 3 failed, no preflight failures and no skipped cases.** reconnect takeover, all fixture reads, multiplayer, spectator and tournament flows now pass. the final chat case passes its message, away, blocking, friend and logout checks before stopping at packet 98.

the two score cases both return HTTP 200 and the expected score-chart markers, but their bodies differ. the identical synthetic play produces **126.064pp on Zigcho and 124.557pp on the pinned reference**, with aggregate pp of 126 and 125. there are also genuine serializer differences: missing `approvedDate`, `100.00` versus `100.0`, zero versus empty initial values, site URLs and achievement payloads. a later tied aggregate rank differs too. neither pp nor these fields have been normalized away. the replay readback and duplicate retry after those failed steps are not proved by this run.

the final presence-all request returns HTTP 500 on the reference. its traceback reaches `UserPresenceRequestAll.handle`, `packets.user_presence`, then `Player.gm_stats`, which raises `KeyError: vn!std`. Zigcho returns HTTP 200 with a packet stream. the existing reference-routing exception does not accept this error, so the case still fails; it is not called equivalent or silently passed.

the artifact was hash-checked and staged at `/opt/zigcho/releases/74fbc6a`, **not activated**. its executable sha256 is `bbead2fa5e32eccaf6f38bf19ce48b7e8a212b07df73cf9059433ff1316fb7f1`. Ari explicitly chose to hold deployment until score-response parity is complete. production remains on the earlier release, and no release announcement was posted. changing production PP or replacing the achievement catalogue just to match the reference is not authorized by this diagnostic result.

## score-chart formatting follow-up

the next candidate supplies the stored map update date through both database backends, leaves unknown dates empty, emits empty initial chart values, and uses the reference's decimal shape and ties-to-even rounding. a literal three-line response fixture keeps the supplied 126.064pp unchanged. a local test caught the `96.125` rounding tie before push; the corrected formatter passes in Debug and ReleaseSafe. these are serializer changes, not pp or aggregate-stat recalculations. no schema change is needed.

[`4803066` passed full release gate 33963019997](https://github.com/zigcho/zigcho/actions/runs/33963019997): production build, full PostgreSQL integration, query parity, isolated backup transfers and exact-binary boot. previous-best chart fields beyond first-score fixtures and installed-client rendering are not claimed as newly verified. site links, achievement catalogues and deterministic equal-pp ranking remain product contracts, not reasons to replace Zigcho's calculations with the reference's.

## shared score contract verified; deployment stopped at backup transfer

the [final comparison, 33964016406](https://github.com/zigcho/stable-conformance/actions/runs/33964016406), uses server `48030665a1576d6bcca3d54d1087594c173f2a99` and harness `87d0651`. **11 cases passed, 1 failed, no failed preflights and no skipped cases.** queued submission, the duplicate retry, the normal submission and the actual replay readback all passed.

the comparison now checks the shared score wire, not product equality. pp, aggregate rank policy and achievement contents are not equality requirements; Kai URLs are checked against Kai's own routes. score ids are captured separately and used for each target's replay request, since the database sequences can diverge after retries. score values, accuracy, combo, map identity, map placement, date, counters, field order and empty initial values remain checked. the report explicitly does not claim calculator or achievement-catalogue equivalence.

the sole failing case is still the reference's final presence-all request: reference HTTP 500 versus Zigcho HTTP 200 with a complete packet stream. that failed result is retained, not rewritten into a green full-parity claim. installed Stable acceptance remains deferred by Ari.

the verified executable, sha256 `c9e8f9f728372b3ccf6b46a8dd2f91da43949bf0470cdb97ff307160b1f94052`, is staged at `/opt/zigcho/releases/4803066`. activation created a 119,808,422-byte backup and passed its schema-48 restore drill, but `object-put` ended with `ObjectTransferTimedOut` before off-host verification completed. activation stopped **before stopping the old service**. production remains healthy on `6581496`; the local backup is retained. no Discord release announcement has been posted. the remaining release blocker is the backup transfer, not score-response compatibility.
