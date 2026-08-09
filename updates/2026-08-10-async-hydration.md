**zigcho update — maps hydrate in background threads**

previously when you opened a leaderboard for a map the server didn't have, it would block the entire request while fetching metadata from osu, downloading the archive, extracting, parsing, and calculating pp. if three people requested three different maps at the same time, they'd all wait in line.

now hydration is fire-and-forget. each missing map spawns a detached thread with its own http client. multiple maps download and parse at the same time. the leaderboard request returns immediately (empty if the map isn't ready yet), and by the next time you open it the map should be there.

an in-progress set prevents the same map from being fetched twice. threads clean up after themselves.
