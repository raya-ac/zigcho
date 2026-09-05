# the first load numbers

we now have actual measurements instead of guesses. the 1,000-player run reached 418 logged-in players before its ten-minute setup limit. login is repeatedly calculating ranks for everyone already online, and that needs fixing.

the smaller mixed-traffic run finished with score, replay, chat, spectator and multiplayer delivery checks passing. all 42 acknowledged scores kept their replay and object-storage copy, with no duplicate best scores. the latency was still bad: polls took seconds, some score requests approached thirty seconds, and the offered traffic was not sustained.

the profile first-place query was the main database cost during that run. PP calculation itself averaged about 1.7 ms for the fixture maps. next is batching login stats and cutting the unnecessary query work, then running the same workload again. the full report and compact measurement files are in `docs/performance/`.

these were disposable GitHub runners, not the live server. no scoring formula, pool-size increase or background score queue went into this pass. the 1,000-player target, long soak and slow-storage recovery checks are still open.
