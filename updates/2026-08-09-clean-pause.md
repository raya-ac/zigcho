**zigcho update — this is the clean pause point**

The map build is live on `osu.kai.ovh`. The installed stable client has already pulled six real maps through the new Nerinyan path, so this is not just a curl check. Production has six verified map files and six cached archives now. The service is active, one client is connected, and the old release plus a fresh database backup are ready if we need to roll back.

There are still zero submitted scores. That is the next honest line: play one of those hydrated maps in the installed client, follow the score and replay all the way into SQLite, refresh the leaderboard in the client, and make sure the player stats move correctly.

We are paused at about 44% of the way to an invite-only alpha. The handoff now has the exact commit, release, backup, rollback, checks, database counts, remaining production gaps, and the next request to trace. Nothing secret was put in git.
