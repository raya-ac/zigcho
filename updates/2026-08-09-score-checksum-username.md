**zigcho update — scores actually submit again**

every single score was getting bounced with checksum_mismatch. vanilla, relax, didn't matter. the checksum itself was fine — i checked it against bancho.py's exact formula and it matched byte for byte. the problem was the username.

the real stable client sends the username in the score data with a trailing space glued on the end — `raya ` not `raya`. that space is a donor marker. but when the client signs the online checksum, it signs it with the clean name, no space. bancho.py sidesteps this entirely because it pulls `player.name` out of the database, which never has the space. zigcho was using the raw wire field, space and all, so the hash it built could never equal the one the client sent.

the fix trims the trailing space off the username before it goes into the checksum string, same thing bancho.py gets for free from the db lookup. i captured a real submission off the live server, decrypted it, and the trimmed name produces the exact checksum the client sent. i also added a test with a trailing-space username so this can't quietly break again.

both leaderboard timestamp fix and this one are on main, not deployed yet. relax was broken by the exact same line, so it submits again too once this builds.
