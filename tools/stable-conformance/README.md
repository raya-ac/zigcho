# Stable conformance

this is the bit that stops Stable compatibility becoming “it looked fine in one client”. it replays the same stateful HTTP and Bancho packet transcript against Zigcho and the pinned bancho.py reference, decodes both replies, and reports the first client-visible difference.

the reference is `osuAkatsuki/bancho.py@0651b54c66daa839c1bb3998e4f9a8d1173e144d` (5.3.0). the pin and the few intentional policy differences live in `reference.json`.

the runner is dependency-free Python on purpose: it sits outside both server implementations and never ships with the Zigcho production binary.

## what gets checked

- the source inventory fails if a Stable packet is added, removed, renumbered, duplicated or loses its explicit handler
- the same check covers every registered legacy `/web/*.php` route and catches method or ownership drift
- Bancho replies are decoded into packet names and typed payloads before comparison, including replay-frame bundles and Stable/ScoreV2 score frames
- packet order and duplicates stay intact
- tokens and fixture-specific ids are normalized only at exact declared fields
- every supplied session token is challenged with a status request and must return the configured user id before its transcript can run
- target variables and captures marked `secret` are stateful, target-separated and redacted from failure reports
- packet handlers need an executable packet, text or storage readback predicate; two matching invalid-session replies are not coverage
- requests cannot escape either configured origin, redirects are not followed, and every response has byte, packet-count and time limits
- state-changing transcripts need all three gates: the transcript marks the mutation, the command uses `--allow-mutating`, and every selected target sets `allow_mutating: true`

the checked surface is 46 registered client packets and 17 legacy PHP routes. packets 68 and 84 are also inventoried as deliberate compatibility no-ops, but they are not counted as registered handlers.

## run it

the inventory and transcript validator need only Python 3.11 or newer:

```sh
python3 tools/stable-conformance/run.py inventory
python3 tools/stable-conformance/run.py validate
python3 -m unittest discover -s tools/stable-conformance/tests -v
```

copy `config.example.json` somewhere outside the repo, set the fixture environment variables you need, then point the runner at one or both already-running servers:

```sh
python3 tools/stable-conformance/run.py run \
  --config /private/path/stable-conformance.json \
  --target zigcho \
  --zigcho-origin http://127.0.0.1:18090 \
  --transcript tools/stable-conformance/transcripts/route-static.json
```

for a real differential run, leave both `zigcho` and `reference` selected:

```sh
python3 tools/stable-conformance/run.py run \
  --config /private/path/stable-conformance.json \
  --reference-root /private/path/bancho.py \
  --allow-mutating \
  --require-all \
  --continue-on-failure \
  --report /private/path/stable-conformance-report.json
```

the harness does not install or start bancho.py. give it an isolated reference instance with a frozen upstream and the same logical users, maps, scores, friends, rooms and server channels as the Zigcho fixture. set the reference's `SEASONAL_BGS` to the JSON list `[]`; Zigcho intentionally returns that same empty seasonal list. the full corpus assumes one fresh mirrored fixture snapshot: its chat, malformed-input, three-session multiplayer, delayed-score and reconnect accounts are deliberately separate, and the multiplayer invitee is already a real `#lobby` observer. reset that snapshot before another full run.

never use `--allow-mutating` against production. score uploads, screenshots, comments, favourites, ratings and read marks all change state.

in a partial run, missing fixture variables skip only the transcript that needs them. `--require-all` accepts only the exact default corpus in manifest order, requires both distinct target origins, and dry-validates every variable, request and identity role before making a request. a complete corpus run also needs a real fixture evidence id, the timezone-aware `fixture_reset_at`, the 64-character `fixture_snapshot_sha256`, exact 40-hex Zigcho and reference commits, a clean Zigcho HEAD matching its metadata, and `--reference-root` pointing at the clean pinned reference commit. the report attests the two source checkouts it inspected, including the exact packet 98 handler and its unrestricted-player set comprehension. the fixture metadata is still an operator assertion, and the HTTP origins are unattested: aliases can reach one process and an origin cannot prove its binary or database snapshot.

## transcript contract

transcripts are JSON data, not scripts. a case declares its covered packets/routes, prerequisites, state-mutation boundary, requests, captures, response format and exact normalizers. request bodies can use UTF-8, hex, base64, JSON, forms, osu! strings, little-endian integers, concatenated fields and framed packet streams.

the comparison contract is intentionally strict:

- statuses, packet order, payload values and body delimiters compare by default
- content type can be disabled per step where Stable does not consume it
- `ignore` and `variable` rules must name one exact object path
- a missing path or a value that does not match its declared variable fails the case
- score value, PP, mods, beatmap status, leaderboard namespace, pass state and replay availability must not be normalized away
- generated screenshot names use one dedicated shape check; there is no generic whole-string substitution
- a policy can compare declared common packet ids as full per-id occurrence lists, so harmless cross-packet ordering differences cannot hide payload drift or an extra packet
- where the two servers deliver an actor update in different adjacent polls, the declared causal response group concatenates both decoded packet streams and compares the complete semantic sequence

the final JSON contains status, byte count, elapsed time and an ephemeral keyed body digest for both sides. the key is never written, so a tiny secret body cannot be brute-forced from a normal SHA-256. on a mismatch it includes only the first differing path and redacted values, so the report stays useful without dumping credentials or a full response.

## known boundary

the intentional differences are explicit policy matrices, not normalizers: server-branded login bootstrap packets, safe malformed-input handling, immediate reconnect takeover, visible silence feedback, Zigcho opening/closing `#lobby` when Stable enters or leaves the multiplayer lobby, and bancho.py routing packet 98 to the wrong session. the noncanonical string-marker probe pins the source behavior specifically: bancho.py treats marker `0x01` as an absent string and returns `200`, while the Zigcho target must turn `InvalidStringMarker` into a bounded `400` response rather than terminate the HTTP transport. their packet scopes are checked against `reference.json`, every matrix is owned by a causal assertion, and session readbacks are harmless packet 4 pings. a valid policy name cannot excuse unrelated packets.

packet 98 has one deliberately split proof because the pinned reference iterates a Python `set`: its final recipient is nondeterministic, so no named observer can honestly expose the routed body. a complete run first AST-attests the exact pinned set-comprehension, shadowed loop variable and final enqueue shape. runtime then executes packet 98 from the still-online peer, requires a complete Zigcho response containing only packet 83, and checks that the requesting peer occurs exactly once regardless of bundle order. the remaining visible members are fixture-dependent. the reference status is checked but its body is marked `uncompared`; the step report records `live_differential_body: false`, Zigcho's `executable_packet_contract`, the reference's `uncompared` body and `static_source` evidence. this waiver is rejected outside `--require-all`.

that request is the final step of the final manifest scenario, after primary logout and the peer's logout observation. bancho.py may leave the bundle queued on any unrestricted session, but the complete corpus performs no later poll that could consume it. reset the mirrored fixture snapshot before another full run as described above.

the pinned source trees still have real differences this harness is meant to fail on. Zigcho is missing normal public-channel join/part information, writes channel counts as `i32` instead of the reference `u16`, uses generic spectator and multiplayer channel topics, omits bancho.py's match-created bot message, and delivers the lobby `new_match` packet differently. none of those are policy exceptions. a green two-target run means fixing them, not hiding them here.

write-route checks include public readbacks for favourites, ratings, comments and submitted-score replay availability. screenshot object retrieval, direct unread-state inspection, and aggregate score/stat/achievement changes are not publicly observable through the pinned Stable routes, so those side effects still need fixture database assertions outside this HTTP harness. packet 79 is checked only for its immediate registered no-output contract because pinned bancho.py stores the presence filter but never reads it.

the checked-in corpus is hand-authored from the two pinned implementations. it is not a captured real-client trace. static inventory, local decoder tests and a Zigcho-only smoke are not a live compatibility result. a full claim still needs both isolated servers, a redacted Stable-client capture replayed through this harness, every transcript unskipped and the resulting report saved with the exact two commits.
