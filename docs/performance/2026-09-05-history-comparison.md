# history writes, before and after

this follows the [login and profile query comparison](2026-09-05-query-comparison.md). the workload, eight-connection PostgreSQL pool and 512-connection ceiling stay unchanged. the target is still 1,000 concurrent players, not a capacity claim based on one short run.

## what changed

score submissions no longer delete and rebuild every player's daily history. the first submission for a source/mode seeds the day once. later submissions recalculate that player's source PP, leave unchanged PP rows alone, and update every rank that actually moved. expired history is pruned within the same source/mode. other players' rank changes are not discarded to make the query look cheaper.

Stable and lazer acquire a shared maintenance barrier and a mode lock before score, token, map or stats rows. restriction changes, map-status changes, BSS publication and recalculation take the maintenance barrier exclusively. authoritative scores, replays, stats, achievements and history remain transactional. this does serialize score transactions within a mode; the measured wait belongs in the result, not outside it.

first-place profile queries limit candidates to maps on which the profile owner has a qualifying play. every opponent on those maps remains eligible, with the same higher-PP selection, score ordering, ties and total-before-limit behavior. owners who have played every populated map still require a large comparison; this is not a promise that every first-place query becomes cheap.

optional geolocation gets four concurrent slots and a one-second deadline, with the existing zero-coordinate fallback for rejected, invalid or timed-out work. the mixed benchmark still resolves the provider to unused loopback for both versions. cancellation and admission are separately tested; the benchmark does not measure the public geolocation provider.

## the intermediate cold regression

`25e126b5403c1b5cb918be561c9cfd0a34e49392` passed its full release gate and removed the observed history deadlocks. its [100-player run](https://github.com/zigcho/zigcho/actions/runs/33950593811) nevertheless failed: nine of 24 cold-phase score requests timed out. history rank updates reached 15.427 seconds, and the mode-lock wait reached 40.179 seconds. warm traffic recovered to zero failures, but that did not make the cold failure acceptable.

the fixture analyzes historical dates before the server seeds today's rows. the update joined two slices whose new date could be badly underestimated. the replacement materializes ranked tuple identities and updates those exact visible rows, rather than joining the two date-filtered slices by user ID. a disposable SQL comparison recreates the stale statistics and compares every final history row; normal PostgreSQL tests also compare incremental histories against the full-rebuild oracle, including concurrent Stable/lazer submissions, unchanged lower/failed plays, day rollover and restrictions.

the [final release gate](https://github.com/zigcho/zigcho/actions/runs/33950945932) measured that deliberately stale-statistics query at **34,844.672 ms before and 35.262 ms after**, with identical final rows. this is a targeted SQL reproduction, not a claim that every score request becomes a thousand times faster. the full container, PostgreSQL integration, existing query parity, HTTPS backup round trip and exact-binary PostgreSQL boot also passed.

the same intermediate binary's [1,000-player run](https://github.com/zigcho/zigcho/actions/runs/33950615549) passed its receipt checks with zero deadlocks, admission rejections or HTTP timeouts. it acknowledged and persisted all 400/394 score attempts with inline replays and object archives. warm poll p95/p99 was 405/707 ms and score p95/p99 was 1,722/2,043 ms. there were still 8,793/6,246 missed scheduled slots. the differently sized initial history fixture matters: success at the larger cohort did not disprove the smaller cold-start defect.

## exact final candidate

| item | value |
| --- | --- |
| server commit | `f612185eed38d39bc6905a77079d1855b636b2f3` |
| binary SHA-256 | `5a45e38c7c31b2991ec90ffbc299b2f56dfa132fc47b733f95dbc4566c4edec6` |
| full gate | [33950945932](https://github.com/zigcho/zigcho/actions/runs/33950945932) |
| workload revision | `zigcho/stable-conformance` at `b4e18b1acddd1564d206d7a67f1cd9051ed45028` |
| final 100-player run | [33951763245](https://github.com/zigcho/zigcho/actions/runs/33951763245) |
| final 1,000-player run | [33951784807](https://github.com/zigcho/zigcho/actions/runs/33951784807) |

## hardware is not controlled across runs

all runs have four logical CPUs, but GitHub assigned different processors. these are **workload-matched comparisons, not hardware-controlled estimates of the code's speedup**. the SQL reproduction above compares both statements on the same runner and database. a same-host paired full workload is still needed to isolate the application change from runner variation.

| run | CPU model |
| --- | --- |
| [before 100](https://github.com/zigcho/zigcho/actions/runs/33944732327) | AMD EPYC 7763 64-Core Processor |
| [before 1000](https://github.com/zigcho/zigcho/actions/runs/33944921614) | AMD EPYC 9V74 80-Core Processor |
| [intermediate 100](https://github.com/zigcho/zigcho/actions/runs/33950593811) | AMD EPYC 9V45 96-Core Processor |
| [intermediate 1000](https://github.com/zigcho/zigcho/actions/runs/33950615549) | AMD EPYC 9V74 80-Core Processor |
| [final 100](https://github.com/zigcho/zigcho/actions/runs/33951763245) | AMD EPYC 9V74 80-Core Processor |
| [final 1000](https://github.com/zigcho/zigcho/actions/runs/33951784807) | Intel(R) Xeon(R) 6973P-C |

## 100-player workload

each cold and warm phase schedules sixty seconds. final login setup was 2.945 seconds; both phases completed without failed requests.

| measurement | before cold | final cold | before warm | final warm |
| --- | ---: | ---: | ---: | ---: |
| successful requests | 15,170 | 17,830 | 15,775 | 16,145 |
| failed requests | 0 | 0 | 0 | 0 |
| missed scheduled slots | 3,734 | 1,074 | 3,123 | 2,753 |
| poll p95 / p99 | 0.540 s / 0.891 s | 0.227 s / 0.705 s | 0.517 s / 0.748 s | 0.462 s / 0.741 s |
| website p95 / p99 | 0.992 s / 1.422 s | 0.850 s / 1.285 s | 0.917 s / 1.250 s | 0.822 s / 1.084 s |
| score p95 / p99 | 7.436 s / 9.169 s | 1.724 s / 2.154 s | 4.747 s / 4.747 s | 1.669 s / 1.669 s |
| scores attempted / acknowledged | 24 / 24 | 24 / 24 | 18 / 18 | 18 / 18 |
| sampled RSS peak | 125.2 MiB | 105.4 MiB | 123.0 MiB | 129.2 MiB |

final elapsed phase times, including in-flight completion, were 60.220 / 60.218 seconds. every final acknowledged score had a stored row, inline replay and object archive, with no duplicate best scopes. the cold regression's nine timed-out scores are gone in this repeat.

## 1,000-player workload

each cold and warm phase schedules 120 seconds. final login setup was 30.877 seconds. PostgreSQL deadlocks went from 51 in the earlier run to zero; final HTTP counters recorded zero admission rejections and zero server timeouts.

| measurement | before cold | final cold | before warm | final warm |
| --- | ---: | ---: | ---: | ---: |
| successful requests | 7,728 | 56,748 | 8,669 | 58,498 |
| failed requests | 11,839 | 0 | 11,025 | 0 |
| missed scheduled slots | 40,193 | 3,012 | 40,060 | 1,256 |
| poll p95 / p99 | >10 s / >10 s | 0.279 s / 1.367 s | >10 s / >10 s | 0.101 s / 0.515 s |
| website p95 / p99 | 4.220 s / 6.986 s | 0.631 s / 0.893 s | 4.260 s / 6.437 s | 0.554 s / 0.803 s |
| score p95 / p99 | >10 s / >10 s | 1.278 s / 1.664 s | >10 s / >10 s | 0.782 s / 1.200 s |
| scores attempted / acknowledged | 400 / 97 | 400 / 400 | 394 / 87 | 394 / 394 |
| sampled RSS peak | 613.9 MiB | 663.4 MiB | 643.3 MiB | 707.7 MiB |

final elapsed phase times, including in-flight completion, were 120.451 / 120.050 seconds. every final acknowledged score had a stored row, inline replay and object archive, with no duplicate best scopes. ordinary polling missed no scheduled slots, but the complete offered workload still missed 3,012 / 1,256 slots. a green receipt check is not proof that every scheduled task ran.

## remaining measured costs

first-place queries remain the largest aggregate database cost. their final mean execution was 455 / 553 ms at 100 players and 355 / 331 ms at 1,000 players. the fixture gives many players scores on the same populated maps, so limiting the map set cannot always eliminate much work. these statements still spill temporary sort data; this pass does not call the profile cost solved.

final rank-update means were 60.6 / 42.8 ms at 100 players and 42.7 / 41.3 ms at 1,000 players. the latter executed 800 / 250 times and changed 517,865 / 173,493 ranks across the two history sources. those are actual rank movements, not unchanged PP rows being rewritten. the earlier Stable-only rebuild and the new rank-update statements have different scopes and different successful-submission counts, so their raw row totals are not presented as a normalized speedup.

RSS at 1,000 players was higher in the final samples, reaching about 708 MiB in the warm phase. more work completed and the runner changed, but neither explains away the missing soak evidence. memory stability remains unproven.

[the machine-readable extract](2026-09-05-history-comparison.json) retains all six runs, hardware identities, failures, missed schedules, score receipts, timings and the relevant query samples. the linked runner artifacts contain the full logs and have limited retention.

## boundaries that remain

the generator, server, PostgreSQL and HTTPS MinIO share a disposable hosted runner. the fixture contains 10,000 accounts, 100,000 historical scores and 200 synthetic maps. this exercises Stable osu!standard vanilla traffic, not installed clients, lazer/RX/AP load, the private anticheat module, Cloudflare, Layerline or the real object store.

receipt checks establish the stored state of acknowledged scores. they do not reconcile every unacknowledged request from failed runs. failed requests and missed scheduled work stay in the comparison. client percentiles are one-millisecond upper bounds; overflow above ten seconds is not an exact ten-second latency. short RSS samples do not establish a memory plateau.

the peak-hour run, longer soak, agreed latency budgets and slow-dependency overload/recovery tests are still separate acceptance work. moving PP or uploads into background jobs is not credited here: those paths have not been changed to disguise database latency.

## deployment held at backup verification

at publication, this candidate is **not live**. production remains on `d7aafefc7db5b74259cfd06c52bc9e6c2d53f28a`, schema 48. the release backup and restore drill passed, but the origin could not complete the configured Singapore object store's read-back of the 119,806,438-byte dump. both the earlier 1 MiB attempt and the final 256 KiB range attempt exhausted retries. the final attempt also rejected truncated responses rather than accepting an incomplete backup.

four independent 256 KiB curl probes completed with full byte counts, taking roughly 8, 13, 26 and 41 seconds. that demonstrates variable transfer behavior, not verification of the whole backup. the public [Contabo status page](https://contabo-status.com/) listed no interruption when checked on 5 September; that does not establish the health of this particular storage path.

verification now happens before the service stop, so this failed preflight leaves the old server serving. the restore-tested local dump is retained. no new database migration, production score repair or Discord release announcement was made for this candidate. deployment needs either a verified off-host transfer or an explicit decision about the backup requirement.
