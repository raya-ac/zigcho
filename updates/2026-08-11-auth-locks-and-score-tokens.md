# one password check doesn't stop the server anymore

login used to hold the global session lock, call SQLite, then run Argon2 while SQLite was still locked. one slow password could leave polling and unrelated database work waiting behind it.

authentication copies the credential row, unlocks SQLite, then verifies it. registration hashes before the write lock too. bancho login now authenticates first, briefly locks to create the session and copy online presence, then unlocks before loading stats or building packets. the response owns its token, so a reconnect cannot free memory under an HTTP header.

stable score tokens follow the compatibility rule we picked: your current token must be yours, another live player's token is rejected, and an unknown pre-restart token still works once the password-authenticated user is back online. missing tokens stay `401`; offline retries keep stable's existing `error: no` response.

the allocation pass found and fixed another leak in `Sessions.create` when appending the new session failed. 56 tests now pass in Debug and ReleaseSafe, including the legacy password upgrade, concurrent auth/database/poll work, login replacement, every token case, and every induced login allocation failure.

where it is: still a Debug alpha, around 54% of the way to an invite-only server I would let someone else rely on. next is hostile score input: bounded stable counters, typed lazer score bodies, mixed RX/custom precedence, and exact multipart delimiters.
