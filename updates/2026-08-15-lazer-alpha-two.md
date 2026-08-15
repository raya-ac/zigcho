# lazer alpha two is actually live

the rankings screen works now instead of firing three 404s. performance, score and country rankings all use the real shared player stats, keep every ruleset separate, support country filtering and return the exact shape the pinned client expects.

score submission had a different bug. the server knew which map you were playing, but it only had the map metadata and still handed the client a score token before the actual `.osu` file was ready. that meant the pp calc had nothing to read and the finished play died with a 422. score tokens now wait for the real map payload, verify the hash and only exist once the play can be calculated. old tokens can recover the missing file on submit too.

map search is not trapped inside our own database anymore either. lazer searches the upstream catalogue, keeps the result order and caches every difficulty in every set it gets back. when one of those sets is pulled the server verifies the requested map, then stores the actual `.osu` for the whole current set instead of downloading six maps and only keeping one of them.

this is `0.1.0-alpha.2`. it is still a portable unsigned windows build, and full multiplayer and spectating still wait for the separate realtime service. the normal rest path is live: login, profiles, maps, chat, friends, favourites, rankings, leaderboards and solo score submission.
