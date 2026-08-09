**zigcho update — leaderboards stop showing the time as right now**

every leaderboard row was sending the play date as a formatted string like `2026-08-09 03:42:38`. the stable client doesn't want that. it wants a raw unix timestamp in that slot — same shape bancho.py sends with `unix_timestamp(play_time)`. the client couldn't parse the string, so it fell back to showing now, and every score looked like it was just set.

the stored time was never wrong. production still has raya's nine real scores from earlier with the right `submitted_at`. the bug was only in the wire response. both leaderboard queries now read `s.submitted_at` straight instead of wrapping it in `datetime(...)`, and the row formatter writes it as an integer instead of a string.

`zig build test` passes. this only fixes the display on scores already in the database though — submissions are still getting rejected by a separate checksum bug that's being fixed in the same push.
