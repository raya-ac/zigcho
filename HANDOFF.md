# where zigcho is paused

This is the clean stop after the first real stable-client map pass on 2026-08-09. The server stays live. Coding stops here so the next session can start from evidence instead of rebuilding the story.

## what is live

- public repo: `https://github.com/raya-ac/zigcho`, branch `main`
- deployed code commit: `49ab8d9fd05ac0dabc7381cbde8dd2b26bf0af9b`
- release: `/opt/zigcho/releases/49ab8d9fd05ac0dabc7381cbde8dd2b26bf0af9b`
- current symlink: `/opt/zigcho/current`
- service: `zigcho.service`, active on `127.0.0.1:27180`
- database: `/var/lib/zigcho/zigcho.db`
- pre-deploy backup: `/root/deployment-backups/zigcho-nerinyan-20260809T022652Z`
- rollback: `/opt/zigcho/releases/301ec6fc70cf920d0811522c9ef42e32f8034fde`

The x86 release was built on the production host from the pinned Dockerfile. Its `zigcho` SHA-256 is `7cf2abfd4b639a8ed65fe10cffe43ed7c2525ebad36bedcbb938a935ecb925cb`.

## what this phase fixed

Stable no longer calls every map unsubmitted. A missing leaderboard map is looked up by MD5 through Nerinyan, its set is downloaded, and only the exact `.osu` file is accepted after ZIP CRC, MD5, map ID, and set ID checks. Stars and max combo are calculated from that file before the map and archive reach SQLite. Ranked and approved maps affect normal scoring. Qualified and loved maps can have boards without changing normal ranked score or PP. Bad upstream data stays unsubmitted.

Public chat no longer sends the message back through Bancho to the sender. Stable's `/web/osu-getseasonal.php` and `assets.kai.ovh/menu-content.json` startup calls return proper empty data instead of 404.

The osu! API key Ari pasted was not used, committed, deployed, written to Discord, or saved in this handoff. Nerinyan is the only map source in this phase.

## what was actually checked

- `zig build test` passed locally
- `zig build -Doptimize=ReleaseSafe` passed locally
- the pinned amd64 Docker build ran both commands successfully on the x86 production host
- a fresh local database hydrated Nerinyan map 75 and returned a ranked stable leaderboard
- public `https://kai.ovh/health` returned the live Zig service
- public `https://osu.kai.ovh/web/osu-getseasonal.php` returned `[]`
- public `https://assets.kai.ovh/menu-content.json` returned `{"images":[]}`
- invalid public leaderboard auth returned `401`
- authenticated public hydration of map 75 returned a ranked board and stored the exact 4,931-byte map
- the installed stable client hydrated maps while connected, proving the real client path rather than just curl

At pause time production has 4 users, 6 beatmaps, 6 cached archives, 0 stable scores, 0 lazer scores, and 1 connected client. The six map IDs are `75`, `283252`, `447179`, `1149303`, `2104403`, and `2156323`. Their statuses are ranked or approved.

## resume here

The next useful vertical slice is a real installed-client score on one of those hydrated maps. Follow the request through `osu.kai.ovh`, the Zig submission handler, SQLite, replay download, leaderboard response, and player stats. Do not count the endpoint as done until the installed client shows the score after refresh.

After that, harden Nerinyan with an explicit upstream timeout, retry/backoff, cache pruning, and failure metrics. Then lock taiko, catch, mania, and lazer scoring fixtures before those modes award PP. The larger production gaps remain moderation, backups and restore drills, structured logs/metrics, full stable multiplayer state, complete lazer signed-in startup, rooms, realtime multiplayer/spectating, and a properly signed public client.

The Discord changelog is sent directly with `tools/publish-update.sh`; its webhook URL stays outside git. The local QA password file is `/tmp/zigcho-lazer-qa-password`, mode `0600`; never print or commit its contents.
