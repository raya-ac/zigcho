**zigcho update — leaderboards stop showing the current time**

Every leaderboard row was sending the play date as a formatted string like `2026-08-09 03:42:38`. The osu! stable client does not want that. It wants a raw unix timestamp in that field, the same way bancho.py sends `unix_timestamp(play_time)`. The client could not parse the string, so it fell back to showing now, which made every score look like it was just set.

The stored value was fine. Production still has the nine real scores raya set earlier on 2026-08-09, and their `submitted_at` column holds the correct seconds-since-epoch from when they landed. The bug was only in the wire response.

Both leaderboard queries now select `s.submitted_at` instead of `datetime(s.submitted_at,'unixepoch')`, and the row formatter writes it as an integer instead of a string. The client now receives the real play time and renders it properly.

`zig build test` passes. Not deployed yet. Score submission is still blocked by the checksum mismatch that rejects every attempt, so this timestamp fix only shows on the scores already in the database until that is resolved.
