**zigcho update — chat works and kai is actually here**

this one fixes a lot of the stuff stable was still getting wrong.

- failed plays only add total score, playcount, playtime and hits now. they do not touch ranked score, pp, accuracy, combo or best score.
- normal, relax and autopilot stats stay in their own rows. switching to relax now switches the stats stable sees instead of mixing everything together.
- the old mixed live stats were rebuilt from the score history without losing the scores.
- ranked, approved, qualified and loved maps now use the right stable values. missing maps hydrate through akatsuki's beatmap service and keep the exact `.osu` file used for pp.
- stable ratings and lastfm are there now instead of 404ing.
- countries work through cloudflare's real two-letter country. presence uses osu!'s numeric table and the country leaderboard bug was fixed too.
- public chat only goes to people who joined the channel, arrives once, and does not echo back through the server.
- `kai` is always online as user id 3 and can answer a dm. the old qa account that had id 3 was moved with its stats and tokens intact.
- kai.ovh has the small live page now. it shows online players, accounts, plays, passes and cached maps, and the boat still moves.

this is live as a Debug alpha. i would call the full server about **52% done** right now. stable login, maps, score submit, pp, stats, leaderboards, chat and the basic bot are working. the big gaps are complete multiplayer, the full lazer client run, moderation/ops, more mode pp fixtures and release hardening.
