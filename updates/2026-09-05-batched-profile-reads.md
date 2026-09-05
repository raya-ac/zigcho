# stop asking the same rank question thousands of times

this candidate batches the stats used in Stable login packets. ranks are calculated once per batch instead of once for every player already online, and the login path no longer fetches profile-only grades and replay views. packet values, mode selection and rank ties stay the same.

profile first-place queries now sort the score keys they need, then load the display fields and replay information for the selected results. opponents still participate in ranking, source and pp tie rules are unchanged, and the total first-place count still comes from the full result before the page limit.

the full hosted gate passed, including old-versus-new PostgreSQL comparisons in Debug and ReleaseSafe. there is no pool-size change, new cache or scoring change.

the matched 100-player run went from 42 seconds to 2.8 seconds for login setup. warm poll p95 went from 6.05 seconds to 517 ms, with over seven times as many requests completed. all acknowledged scores and replays were retained. there is still missed work, so this is not a capacity claim.

1,000 players now finish the isolated login ramp in 42 seconds, but mixed traffic fails: 51 history deadlocks, admission rejections and score timeouts. concurrent history rebuilds are next. we also found the benchmark was still calling the public geolocation API; both comparison binaries were rerun with that lookup failing locally.

the [full measurements and remaining work](https://github.com/zigcho/zigcho/blob/main/docs/performance/2026-09-05-query-comparison.md) are in the repo. nothing was deployed or announced to Discord in this pass.
