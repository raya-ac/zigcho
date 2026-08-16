# lazer alpha.6

the website does not mash Stable and lazer boards together anymore. they have their own score views, while the player stats still use both clients. lazer feeds those stats with its legacy score and the highest pp play owns each map, so a lower pp retry cannot overwrite the play that actually matters.

lazer now asks zigcho again when a local map is stuck on unknown or says its leaderboard is unavailable. the client also stops calling the mods we accept unranked. Stable, lazer and ScoreV2 stay visible as separate score lanes instead of pretending their score numbers mean the same thing.

achievements work across Stable and lazer now. they are calculated on score submit, pop in game when they unlock, and show on both the lazer profile and the website. chat presence, private messages, `kai`, replay submission and room results are included in the same client patch too.

this is `0.1.0-alpha.6`. it is still the portable unsigned Windows build. normal rooms are live; matchmaking, lazer spectating and a signed installer are still not being called finished.
