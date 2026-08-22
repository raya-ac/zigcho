# lazer finish line

the client is pinned to osu `12df2e4ff254975f4b66ae9efda808837ee9beea`. completion means that exact client can sign in, stay online, use every normal player surface, play and submit, download its replay, use rooms and spectating, then recover from a server restart without falling back to osu or offline mode.

there are 81 request targets in the pinned player client. the three beatmap submission requests now run through our own lazer-only BSS. uploading needs premium, sets stay mapper-owned, and pending packages go into the same BN queue as everything else. installers and distribution signing are not requirements. GitHub runners build the same patch for Windows, macOS, Linux, Android and iOS.

## closure matrix

| slice | required player path | current proof | left before complete |
|---|---|---|---|
| account and sessions | registration, oauth, `/me`, logout, expiry, one game session across Stable and lazer | rotating one-use refresh tokens, PostgreSQL tests, owned token tests, cross-client takeover tests | one packaged-client restart/reconnect run |
| online state | local player online, kai online as id 3, activity, bot DMs, notification socket | presence, bot and websocket contract tests | packaged-client visual check |
| profiles | all four rulesets, combined and separate stats, ranks, play time, recent/top/pinned/#1 plays, medals, roles and country | profile/storage tests and live profile API | prove the new image-style banner URL in game |
| teams | team identity on profiles and team flags on leaderboard users | nested team contract tests; `45a5941` live | packaged-client visual check |
| beatmaps | lookup, batch lookup, set lookup, search/listing, tags, favourites, media and downloads | map fallback smoke, hydration tests, mirror/object tests | one uncached set and one cached set in the packaged client |
| leaderboards | Stable Classic plus lazer, vanilla/RX/AP/custom namespaces, exact and combined mods, higher-pp per user | cross-source, mod filter and identity tests | packaged-client checks for NM, DT, RX, AP and Classic |
| solo scores | create token, submit replay, pp/stars/rate, best selection, stats, rank panel, achievement popups | typed score tests, pinned pp fixtures and solo smoke | one live passed score and one failed score |
| replays | Stable and lazer playback/download, object copy, failed data private | source-id, replay relay and object tests | play one Stable and one lazer replay from lazer |
| chat and social | channel list, joins, history, ack, public chat, DMs, kai commands, friends, blocks and reports | chat/bot smoke plus storage tests | packaged-client channel and kai DM check |
| normal rooms | create, join, invite, leave, playlist, room score and leaderboard | REST and two-client websocket smoke | packaged-client invite and complete round |
| Quick Play and ranked duel | queue, match, cards, rounds, results and requeue | canonical GUID/state tests and two-client websocket smoke | packaged-client queue and duel run |
| spectating | connect, state, frames, watcher list, chat and disconnect | spectator unit and websocket smoke | packaged-client watch/start/stop run |
| restart behaviour | short release switch, token survives, polls and hubs reconnect | token/session tests and bounded reconnect policy | packaged client must visibly return online after a controlled restart |
| beatmap submission | reserve set/map ids, full or patched package upload, WIP/Pending state, mapper ownership and BN handoff | bounded ZIP/package tests plus SQLite and PostgreSQL lifecycle gates | one premium packaged-client submission |
| changelog and package | complete in-game history and downloadable verified builds | all checked-in updates are in the API contract; the five-platform runner matrix owns release artifacts | publish the green runner artifacts and open the player builds |

## exact route groups

- account: registration, oauth token/revoke, verification, `/me`, users, lookup and search
- profile: ruleset profiles, user scores, recent activity, most played, mapsets, rankings and achievements
- beatmaps: lookup, batch, set lookup, listing, search, download, favourites and tags
- scores: solo create/submit, map leaderboards, replay download and rankings
- chat: channels, members, messages, read state, updates, polling fallback, DMs and ack
- social: friends, blocks, comments, votes, reports and notifications
- multiplayer: room list/create/read/close, users, playlist scores, user scores and room leaderboard
- content compatibility: mods, changelog, seasonal backgrounds, news, spotlights and wiki
- realtime: presence, notification websocket, multiplayer SignalR and spectator SignalR
- BSS: premium-gated id reservation, full package upload, incremental patching and BN queue handoff

## current open work

1. exercise the packaged client against production for each visual row above and fix anything it exposes.
2. remove the alpha wording only when those checks are green.
3. commit, push, deploy once, verify the public hosts, then post one final changelog.
