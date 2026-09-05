# login and profile queries, before and after

this is the follow-up to the [first baseline](2026-09-05-baseline.md). it changes two database reads, not scoring, authentication or the pool size. the target is still 1,000 concurrent players; faster requests at 100 players do not establish that capacity.

## the change

Stable login used to load full profile stats separately for every online player. it now requests the six fields used by the Bancho stats packet in a batch. PostgreSQL calculates the relevant mode rankings together. request order, missing-stat defaults, restricted/bot handling and equal-PP user-ID ties stay the same. queries are chunked at 1,024 entries without adding an online-player cap. the offline SQLite reader still uses its existing implementation.

profile first places now carries score IDs, owner/map IDs and ordering values through its ranking windows. display metadata, mods and replay availability are loaded only for the final page. opponents are still included when choosing each map's winner; filtering them out would give the wrong first places. the combined board still chooses a user's higher-PP play before applying the existing board order.

the old queries are retained as test-only references. the comparison covers all returned columns, order, nulls, source-ID collisions, equal-PP and equal-score ties, restricted users, missing users, all four namespaces, pagination and the total first-place count. batched stats are compared with the original reader, including requests crossing the chunk boundary.

## exact candidate

| item | value |
| --- | --- |
| server commit | `6facd1669662604263188496937f621086455a4a` |
| binary SHA-256 | `bed0d53e958d584325c95f71d728f1614e0dc1f0a528f17aa1b6d2b514ec9248` |
| full hosted gate | [33943538360](https://github.com/zigcho/zigcho/actions/runs/33943538360) |
| workload revision | `zigcho/stable-conformance` at `b4e18b1acddd1564d206d7a67f1cd9051ed45028` |
| database/pool | PostgreSQL 17; eight connections, unchanged |
| fixture | 10,000 accounts, 100,000 historical scores, 200 synthetic maps |
| traffic | Stable osu!standard vanilla, chat, spectator/multiplayer frames, encrypted scores, website reads and replays |

the full Debug/ReleaseSafe container tests, existing PostgreSQL integration tests, new old-query parity checks in both modes and exact-binary PostgreSQL boot passed. an initial compile-name collision and a duplicate fixture mod tuple were fixed before that passing gate. no production deployment or Discord announcement is part of this measurement pass.

## a missed external dependency

the first optimized 100-player run completed and was substantially faster. the first optimized 1,000-player attempt then stopped after 188 successful logins when player index 188 timed out. completed polls stayed fast and pool wait was negligible, so the earlier slow-rank-query explanation did not fit this failure.

inspection found that `lookupGeo` calls the public geolocation API before authentication, including for synthetic benchmark addresses. the failed run did not capture an external-request trace, so that alone is not proof of the timeout's cause. it does mean the earlier runs were not free of external dependencies.

the comparison was therefore rerun with **both** binaries resolving `ip-api.com` to unused loopback `127.0.0.2:80` on the disposable runner. the optional lookup takes its existing zero-coordinate fallback. this excludes geolocation network latency; it does not claim that every background egress path is blocked. the earlier measurements remain recorded rather than silently replaced.

## matched 100-player comparison

the [old binary](https://github.com/zigcho/zigcho/actions/runs/33944703630) is `503b5f12604f6481a3775bd4cb972657b86a4b42`; the [new binary](https://github.com/zigcho/zigcho/actions/runs/33944732327) is the candidate above. both use the same workload revision and local geolocation failure. both runners report four logical CPUs on AMD EPYC 7763 hosts. this is a matched single-run comparison, not a confidence interval or dedicated-hardware result.

100-player login setup fell from **41.964 seconds to 2.817 seconds**. every login succeeded in both runs.

| measurement | old cold | new cold | old warm | new warm |
| --- | ---: | ---: | ---: | ---: |
| completed requests | 2,004 | 15,170 | 2,216 | 15,775 |
| missed scheduled slots | 16,900 | 3,734 | 16,682 | 3,123 |
| poll p95 / p99 | 7.141 / >10 s | 0.540 / 0.891 s | 6.049 / 7.435 s | 0.517 / 0.748 s |
| website p95 / p99 | 7.086 / 9.657 s | 0.992 / 1.422 s | 7.076 / 9.660 s | 0.917 / 1.250 s |
| score p50 / p95 / p99 | all >10 s | 3.038 / 7.436 / 9.169 s | all >10 s | 2.613 / 4.747 / 4.747 s |
| request timeouts | 0 | 0 | 1 | 0 |
| acknowledged scores | 24 | 24 | 17 | 18 |
| pool-wait p99 upper bound | 10 s | 0.5 s | 10 s | 0.5 s |

each phase scheduled sixty seconds. actual elapsed time, including in-flight completion, was 63.933 / 65.343 seconds before and 60.323 / 60.573 seconds after. all acknowledged scores had matching stored rows, inline replays and object archives; there were no duplicate best scopes. the old warm run is correctly marked failed because one of its eighteen score attempts timed out. checking acknowledged receipts does **not** establish the final state of that unacknowledged request.

the candidate delivered 6,790 / 7,174 spectator frames, 16,160 / 16,768 multiplayer score frames and 9,681 / 9,941 chat messages. ordinary polling missed no scheduled slots, but the high-frequency spectator/multiplayer traffic and some website reads still did. faster and more complete is not the same as sustaining the whole offered workload.

## what the database evidence says

the profile first-place query's mean PostgreSQL execution fell from **3.201 / 3.360 seconds to 0.572 / 0.589 seconds**. it ran 117 / 124 times before and 388 / 398 times after. temporary writes per execution fell from roughly 4,711 blocks to 1,720 blocks. total temporary writes increased because many more profile requests completed; the comparison does not claim otherwise.

the retained post-run plans still show two external-merge sorts over about 100,000 narrow rows. the no-first-place profile took 249.6 ms in that isolated plan, and the historical winner profile took 265.4 ms. these are post-run plan timings, not concurrent request percentiles. the query is much cheaper, but still the biggest aggregate database cost in this workload.

Stable history rebuilding remains expensive: 24 / 18 calls rewrote 240,000 / 180,000 history rows, averaging 1.834 / 1.243 seconds of PostgreSQL execution. it was intentionally unchanged in this pass. PP and uploads have not been moved to background tasks to disguise this database work.

## the 1,000-player result: setup passed, mixed traffic failed

with geolocation excluded, [the target run](https://github.com/zigcho/zigcho/actions/runs/33944921614) logged in all 1,000 players in **42.164 seconds**, with no recorded keepalive failures during the ramp. individual login p95/p99 was 515 / 576 ms. it reached both mixed phases instead of stopping during setup.

that is where it stopped being healthy:

| measurement | cold gameplay | warm |
| --- | ---: | ---: |
| scheduled / elapsed phase length | 120 / 136.501 s | 120 / 147.826 s |
| successful requests | 7,728 | 8,669 |
| failed requests | 11,839 | 11,025 |
| missed scheduled slots | 40,193 | 40,060 |
| successful poll p95 / p99 | both >10 s | both >10 s |
| score attempts / acknowledged | 400 / 97 | 394 / 87 |
| successful score p50 / p95 / p99 | all >10 s | all >10 s |
| pool-wait p99 upper bound | 10 s | 5 s |
| sampled RSS peak | 613.9 MiB | 643.3 MiB |

the final server counters recorded **22,681 admission rejections** against the unchanged 512-connection ceiling, and 65 server request timeouts. fast connection failures must not be mistaken for improved average latency. acknowledged scores all had stored rows and both replay representations, with no duplicate best scopes. hundreds of unsuccessful submissions remain outside that acknowledged-only guarantee.

PostgreSQL logged **51 deadlocks**. the first, at `04:38:48.262 UTC`, shows processes 38 and 36 waiting on each other's transactions while updating `user_stats_history`. subsequent entries show the daily history `DELETE` competing with the global history `INSERT ... ON CONFLICT DO UPDATE`. the source/mode history rebuild is unchanged between the old and new application commits; the larger workload exposes its concurrency problem.

those rebuilds now dominate: 145 / 128 Stable snapshot queries rewrote 1.45 / 1.28 million rows and averaged 3.70 / 4.26 seconds. the main Stable session mutex stayed short-lived, with wait/hold p99 bounds of 0.1 / 0.25 ms. PP averaged about 1.7 / 1.6 ms on these synthetic maps, and direct local object uploads averaged about 54 ms. this evidence puts history transaction ordering and write amplification ahead of calculator changes or a larger pool.

## what stays open

- [x] batch login reads and verify packet-field/rank parity
- [x] narrow first-place ranking rows and verify the old result contract
- [x] publish a matched before/after control, including failures and missed work
- [x] reach the 1,000-player cohort and retain the failed mixed-load evidence
- [ ] fix concurrent history rebuild lock ordering and reduce whole-slice writes without losing correct ranks or daily history
- [ ] bound optional production geolocation so a stalled lookup cannot hold login indefinitely; the runner workaround is not that fix
- [ ] further reduce profile first-place work, retaining every opponent on the relevant maps
- [ ] rerun the target, agree latency budgets, then do the peak hour, longer soak and slow-dependency recovery cases

**this is not a 1,000-player capacity pass and is not ready for deployment on the strength of these runs.** the code-change comparison is complete; the new load failures are the next work, not something to hide behind a green receipt check.

the [machine-readable extract](2026-09-05-query-comparison.json) retains the matched runs, earlier externally dependent attempts, timing windows, resource samples, leading SQL statements, compact plan evidence and the deadlock/admission counts. full runner artifacts are linked from each run and have limited retention.

## acceptance boundary

all runs share a hosted runner between the generator, application, PostgreSQL and local HTTPS MinIO. they do not measure Cloudflare, Layerline, the real object store, private anticheat, real client rendering or lazer/RX/AP traffic. short resource samples do not prove a memory plateau. a green workload job checks receipts and delivery, not latency budgets or sustainable capacity.

client quantiles are one-millisecond upper bounds. `>10 s` is the overflow bucket, not an exact ten-second result. server timing quantiles use coarser histogram buckets. missed slots count scheduled work that was not started; a lower latency paired with less completed work would not establish an improvement.
