# stopped three lifetime bugs before they became live crashes

the review found three real P0s in current main, so I fixed those before adding another feature.

`config.ini` was returning values backed by a dead startup stack buffer. config values are owned by the app now.

bancho used to look up a session, drop into a race window, then lock when it started polling. reconnecting in that window could destroy the session under the old request. token lookup and packet handling are one locked operation now, and stale tokens get the normal restart path.

async score jobs now own every score string, replay byte, and map byte they use. pp failure, partial allocation, thread-start failure, database failure, and normal worker completion all have a complete cleanup path.

I also corrected the readme: the public installed-stable run is already proven, and metadata-only beatmaps already retry. those are not being carried as fake unfinished work anymore.

48 tests pass in Debug and ReleaseSafe, including source-buffer overwrite and session replacement regressions. this closes all three P0s from the review.

where it is: still a Debug alpha, around 48% of the way to an invite-only server I would let another person rely on. stable's real login/map/score/replay/pp/stats/chat path works. the next block is logout and idle expiry, bounded session queues, narrower locks, hostile score input, then more of lazer and multiplayer.
