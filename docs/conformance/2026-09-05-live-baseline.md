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

a clean full differential result is still outstanding. so are real redacted Stable captures and installed-client acceptance across all four rulesets, supported Relax/AP, ScoreV2, reconnects and tournament workflows. no Warden connection was available in this task. this pass does not deploy or announce a release.
