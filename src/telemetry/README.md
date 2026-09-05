# measuring it

`/metrics` includes the usual database and cache totals plus timings. `/metrics/runtime` only reads bounded in-process observations and HTTP admission counters. use that one while investigating a slow database. both keep the existing local-host restriction and send `cache-control: no-store`.

the labels come from enums. no usernames, tokens, SQL text, map IDs, object keys or raw URLs get turned into a time series.

## what the numbers mean

- route durations start after parsing the request target and end when the handler returns, including response writes. they do not include accepting the connection or reading its headers. the load generator must measure the complete client-visible request too.
- `realtime_session` is websocket lifetime, not request latency. do not mix it into an HTTP latency budget.
- `postgres_query` is client-side libpq wall time, including parameter preparation, network and database work. use `pg_stat_statements` for the database's own execution measurements.
- `postgres_pool_acquire` includes waiting and connection restoration. `postgres_pool_wait` excludes restoration and counts the time spent selecting or waiting for a slot.
- session and multiplayer state mutexes report wait and hold separately. this does not change their ownership or unlock boundaries. the separate multiplayer transition/lifecycle locks are not included in the state-mutex metric.
- PP timings surround the existing calculator calls. the formulae are unchanged.
- `replay_analysis` surrounds Stable replay preparation and anticheat analysis. `replay_archive` includes the optional object copy, verification and reference update, after authoritative score/replay persistence. object upload and download durations are also reported separately, so those inclusive measurements overlap.

the histogram buckets are cumulative Prometheus buckets in seconds. the p50, p95 and p99 gauges are process-lifetime bucket upper bounds, not exact samples or rolling percentiles. take histogram differences between scrape snapshots for a benchmark window. the final bucket and overflowing quantiles stay `+Inf`; a slow request is not silently clipped to the last finite bucket.

pool/media acquisitions and in-flight hydration work have depth, oldest age and rejection counters. these are existing operations, not a new durable queue. observation slots are fixed at 4096 per kind. if that observation capacity is exhausted, `zigcho_work_untracked_total` rises; it does not reject application work or pretend that the partial depth is complete.

none of this moves score work into the background or increases the pool. the first baseline targets 1,000 concurrent players in isolation. an hour at peak and a longer soak still need their own evidence before making a production capacity claim.
