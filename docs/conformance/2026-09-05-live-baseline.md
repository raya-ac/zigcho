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

the calculators are different too. this Zigcho build uses `stable-rosu-4.0.1-lazer-2026.730.0-1129a7e-akatsuki-591de0d.1`; the pinned reference uses `akatsuki-pp-py==1.0.5`. the runner records both versions. numerical score/stat differences remain failures. the delayed-score fixture's identical-calculator precondition is therefore not yet satisfied, and this pass does not change the production calculator to manufacture a green result.

## latest failed comparison and local audit

[run 33959425121](https://github.com/zigcho/stable-conformance/actions/runs/33959425121) used server `3b78fd8` and harness `093be6a`. setup completed and all status preflights passed. the result was **7 passing cases, 5 failing, 0 skipped**. account policy, malformed login, malformed framing, multiplayer, spectator, tournament and static routes passed. later steps after a case's first failure remain untested.

the mismatch report was inspected. reconnect fixtures rejected repeated presence/stats/channel packet types even though the initial login allowed them. the submission fixture omitted the reference's required `x`, `fs` and `c1` fields, producing HTTP 422. the resulting one-sided score write also made later rank comparisons invalid as a parity measurement. a separate real server defect left the leaderboard rating as a literal `0`, instead of its stored average with the expected decimal representation.

the local corrections add those multipart fields with hardware preimages matching the login, and permit repeated reconnect packet types while retaining the exact comparison with the original bootstrap. focused checks reject added/removed users or changed stats, and verify multipart fields, checksum order and replay content. leaderboard rating reads use the already-held database connection in both backends; existing SQLite and PostgreSQL tests now assert its wire field.

these corrections have **not** passed a new hosted gate or live comparison yet. the next Stable-scoped gate also runs the unfiltered PostgreSQL integration step, with all nine database environment variables supplied. that workflow change does not retroactively make gate 33958591854 a full PostgreSQL pass. score-chart and calculator differences are still compared, not hidden.
