# measuring where the time goes

added bounded latency histograms for the request families, PostgreSQL calls and pool waits, the main Stable and lazer session locks, PP calculation, replay analysis and object uploads/downloads. the labels are fixed. player names, tokens and individual URLs do not become metrics.

the existing pool, media and hydration work now exposes pending counts and oldest age. the measurement storage has a fixed limit too; if that fills, it reports dropped observations instead of allocating forever or rejecting game work.

`/metrics/runtime` gives the runtime measurements without waiting on database queries. it has the same local-host restriction as `/metrics`, which also includes the new timings. p50, p95 and p99 are histogram bucket bounds; the actual client-facing benchmark records its own request latency.

no PP changes, pool-size increase, new background score queue or keep-alive change. the next measurement is a disposable 1,000-player mixed-load baseline. that is a target to test, not a claim that the server already meets it.
