# lazer scores actually count now

i pushed and deployed the first proper ranked lazer scoring slice. lazer submits through its real two-request score flow, calculates pp from the exact modern mods and settings the client sent, stores the result, and updates the same account stats Stable uses.

ranked passes now update weighted pp, accuracy, ranked score, total score, playcount, hits, and max combo. failed and unranked plays still count where they should without leaking into ranked pp. custom mods stay on their own unranked board, while relax and autopilot keep their own supported namespaces.

i also fixed the shared Stable/lazer edge instead of letting the same map count twice. the account takes the better pp result for that map no matter which client submitted second. old lazer scores were migrated carefully so the actual highest historical score keeps the best flag.

the exact x86_64 build is live as `98a0130`. the 2.43 GB production backup restored cleanly before the switch, schema 22 is healthy, every public host passed, Stable and lazer auth both passed through public TLS, and the service is running with zero restarts or warning logs. `f167ca3` is still there as rollback.

Stable bancho is already live and stays complete. lazer is around 55% of the way to a proper public release now: login, maps, downloads, social/profile responses, solo submission, modern-mod pp, leaderboards, and ranked stats are in. rooms, durable live events, multiplayer/spectating, and the signed public client are the big pieces left.
