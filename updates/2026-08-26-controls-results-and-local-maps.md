# zigcho release 1.2

this one is mostly about making the server less annoying to run and less likely to lie to the client. the control panel can shut real things down, lazer score results stop waiting on an event they already missed, and map numbers finally belong to kai instead of leaking in from bancho metadata. i also went back over the ugly login and shutdown races instead of leaving them as "probably fine".

## the server controls actually control the server

developers now have one proper infrastructure page for registrations, logins, Stable and lazer scores, multiplayer, spectating, BSS, downloads and website writes. every switch is persisted, reasoned and audited, and the page shows the live server, storage, cache and realtime counts instead of a pile of blind buttons.

multiplayer and spectator switches also close existing realtime connections now. room score submits require both the score gate and the multiplayer gate, so somebody who was already connected cannot just keep going through a maintenance window. restart is still deliberately guarded and deploys, rollbacks, shell and SQL stay outside the browser.

opposite control requests are serialized too. the database is written first, then the live manager crosses the same boundary, so a failed write cannot kick everyone while the page still claims the feature is on.

## logins stop fighting each other

Stable, lazer, the player website and the staff website now share a per-account transition lock. password hashing for different users still happens concurrently, but two clients cannot both win the same login and revoke each other's new session anymore.

password changes, username changes and restrictions revoke the matching token family inside the same database transaction. the Stable kick packet is prepared before that commit and the actual session teardown cannot fail halfway through because an allocation failed. old Stable sessions lose score auth, multiplayer, spectating and public presence immediately instead of hanging around until the next poll.

the one-character account exception also works on Stable login now. registration still keeps the normal public username rules; an existing staff-approved name like `r` is not rejected by the login parser.

## multiplayer maintenance has an actual boundary

room creation, joining, leaving, closing, score token binding and score archiving all stop at the same disable or shutdown line. delayed REST work and websocket invocations drain before rooms are moved, so a room cannot appear behind the shutdown snapshot and vanish without history.

playlist rooms are checkpointed once during a planned restart. disabling multiplayer archives the rooms it closes, repeated disable calls stay harmless, and a later re-enable starts cleanly. if a score token gets created just as the boundary moves, it is deleted instead of sitting in the database unattached to a room.

## overall ranking stops spinning forever

the spectator bridge now accepts both the final V2 argument order and the order used by our shipped lazer build. that gets rid of the `ExpectedMessagePackInteger` failures which were sitting directly beside successful score submits in production.

the pinned client also refetches committed statistics after the score response instead of registering too late for a synchronous processed-score event. the result screen gets an owned before/after update even when the server finished the work before the client started listening.

## map counts are kai counts

beatmap and set playcounts, passcounts and favourites in lazer and on the website now come from plays and favourites on kai. upstream values are still stored for hydration and metadata, but they no longer get added into the numbers players see. that was why only some maps looked like they had randomly borrowed bancho's history.

accepted custom-mod plays count as local map plays as well. they still stay out of player aggregate stats when there is no supported stats namespace, but they no longer disappear from the map and set counters.

## anticheat stays evidence first

exact Stable hardware matches, suspicious client flags, missing passed replays and invalid replay payloads now land in the staff review queue instead of automatically restricting and kicking accounts. score-linked evidence stays attached to the score, replay reuse is only compared on the same map and ruleset, and malformed server-side map data is not blamed on the player.

reconnect and lastfm noise is coalesced into bounded review windows, old non-score noise has retention, and repeated hardware matches no longer fill the audit log forever. the private module boundary and replay parser also reject malformed sizes, flags and metrics before they can reach the rest of the server.

## the public side is simpler

the homepage now just says what kai is, shows the two playable client lanes and gets people to downloads or live status without the old "front door" and services-directory copy. profiles keep the sharper layout and can now show previous usernames from the real rename history anywhere a player name appears, while restricted users and kai's bot account stay out of that public history.

schema 45 carries the persisted control plane. the focused release gate now runs the actual 20-to-45 PostgreSQL migration test and checks all ten controls, and the client patch is still pinned to the exact osu revision used by the runner builds.

the release publisher now opens every package and checks its full zigcho commit before it can make the tag. Windows was only writing the short hash before; alpha.15 records and verifies the same 40-character revision on Windows, macOS, Linux, Android and iOS.
