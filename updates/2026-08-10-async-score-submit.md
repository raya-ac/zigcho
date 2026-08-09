**zigcho update — score submissions are async now**

score submissions used to hold the server hostage. every submit locked the database for the entire insert, stats recalc, and webhook call. if two people submitted at the same time, the second one waited for the first to finish completely.

now the heavy lifting runs in a background thread. the request returns immediately, and the db insert + stats + discord webhook all happen behind the client's back. the next leaderboard request picks up the new score.

validation still happens synchronously — decrypt, checksum, auth, pp calc all run on the request thread. only the database write and post-processing got moved out. each submission gets its own thread with properly duped data so nothing gets freed under it.
