# zigcho release 2.7

## stop rebuilding everyone's history for one score

daily history still records the submitting player's pp and everyone else's changed rank. it now seeds each source and mode once for the day, recalculates that player's source pp, and writes only rows whose pp or rank changed. failed or lower plays with no pp change leave the existing history rows alone.

expired history is still pruned on submission, but within that source and mode instead of deleting across unrelated score transactions.

Stable and lazer submissions take the mode lock before touching score, token, map or stats rows. restrictions, map-status changes, BSS updates and recalculation use the same maintenance boundary. score persistence and history stay in the same transaction.

profile first places now check opponents on maps the profile owner has a qualifying play on. they still include those opponents, use the same tie rules and count all first places before limiting the displayed rows.

## optional geolocation has a limit

location lookups get one second and at most four concurrent requests. extra work takes the existing zero-coordinate fallback instead of joining a queue. invalid coordinates are ignored. a stalled lookup is cancelled before its request resources are released.

## the history button

username history sits to the right of the profile name now, with a labelled button instead of the tiny arrow by itself. it stays on the profile page, opens from the keyboard, closes with Escape or an outside click, and fits on a phone screen.

## backups before the restart

the previous deployment rolled back because its backup read-back failed verification. a separate download was also crawling from storage, so the old release stayed live and no announcement went out for that attempt.

backup transfers now use eight bounded range readers, one megabyte per range, with deadlines and limited retries. every response has to match the requested range and the same object version. upload verification still compares every byte with the local dump; an ETag alone does not count as a verified backup. restores use the same bounded download path and still check the saved SHA-256 before restoring.

the backup upload and read-back now finish before the old service is stopped. a storage failure leaves that service running, rather than failing after the new release has already started accepting players.

there is no schema, calculator or score-value change here. the mixed-load benchmark still needs to establish the result; a passing build is not a 1,000-player capacity claim.
