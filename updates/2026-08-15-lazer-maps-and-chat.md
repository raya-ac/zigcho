# lazer can actually load maps and chat now

the map error and channel error were two separate bugs. cold maps now carry their online id into the lookup, so the server can hydrate the map and its full set before gameplay instead of guessing from a checksum it has never seen. id, checksum, set and batch lookups all use the same stored result now.

chat does not fake being online anymore either. it waits until login is finished, loads `#osu`, `#announce`, `#lobby` and `#lazer`, then polls the authenticated REST feed once a second. joins, history, posting, dedupe, read state and the Stable-side broadcast are all wired up, and a dead request times out instead of leaving the client stuck forever.

the rest of the normal logged-in path got filled in around it: friends, blocks, favourites, batch user/map lookups, score profiles and top/recent/first-place plays. custom and Relax scores keep their mods and stay out of the vanilla ranked flag, while vanilla still updates its own stats normally.

i ran the real HTTP flow from account creation through login, maps, chat, custom score, vanilla score, leaderboards and profiles. SQLite and fresh PostgreSQL passed in Debug and ReleaseSafe, and the pinned client builds with no warnings. the solo/REST slice is ready to use; full lazer multiplayer and spectating are still the separate SignalR service, and the Windows build is still an unsigned portable alpha until that and signing are done.
