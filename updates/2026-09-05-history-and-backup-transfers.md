# zigcho release 2.7

## stop rebuilding everyone's history for one score

daily history still records the submitting player's pp and everyone else's changed rank. it now seeds each source and mode once for the day, recalculates that player's source pp, and writes only rows whose pp or rank changed. failed or lower plays with no pp change leave the existing history rows alone.

expired history is still pruned on submission, but within that source and mode instead of deleting across unrelated score transactions.

the first mixed run caught a cold-start problem in the new rank update. a fresh day's rows were missing from PostgreSQL's older statistics, so the join could pick a very slow plan and queue scores behind it. the update now materializes the ranked row identities once and targets those rows directly. the gate compares both results with deliberately stale day statistics.

Stable and lazer submissions take the mode lock before touching score, token, map or stats rows. restrictions, map-status changes, BSS updates and recalculation use the same maintenance boundary. score persistence and history stay in the same transaction.

profile first places now check opponents on maps the profile owner has a qualifying play on. they still include those opponents, use the same tie rules and count all first places before limiting the displayed rows.

## optional geolocation has a limit

location lookups get one second and at most four concurrent requests. extra work takes the existing zero-coordinate fallback instead of joining a queue. invalid coordinates are ignored. a stalled lookup is cancelled before its request resources are released.

## the history button

username history sits to the right of the profile name now, with a labelled button instead of the tiny arrow by itself. it stays on the profile page, opens from the keyboard, closes with Escape or an outside click, and fits on a phone screen.

## backups before the restart

the previous deployment rolled back because its backup read-back failed verification. a separate download was also crawling from storage, so the old release stayed live and no announcement went out for that attempt.

backup transfers now use eight bounded range readers, 256 KiB per range, with deadlines and limited retries. the real storage check showed that one-megabyte ranges could still exceed the individual deadline, so retries now cover smaller pieces and the whole transfer has a fifteen-minute ceiling. every response has to match the requested range and the same object version. upload verification still compares every byte with the local dump; an ETag alone does not count as a verified backup. restores use the same bounded download path and still check the saved SHA-256 before restoring.

the backup upload and read-back now finish before the old service is stopped. a storage failure leaves that service running, rather than failing after the new release has already started accepting players.

the short 100- and 1,000-player mixed runs now pass without request failures, database deadlocks or server timeouts. missed scheduled work and different runner hardware remain in the [measurement report](https://github.com/zigcho/zigcho/blob/main/docs/performance/2026-09-05-history-comparison.md); this is not a sustained 1,000-player capacity claim.

release 2.7 went live with explicit approval to use a fresh restore-tested local backup while Contabo read-back was still slow. rollback files remain on the server. off-site verification is pending, not fixed. there is no schema, calculator or score-value change here.
