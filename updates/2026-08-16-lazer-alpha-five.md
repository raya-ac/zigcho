# lazer alpha.5

alpha.4 made replayless old scores visible to PostgreSQL in a way it did not like, so leaderboards could fall out of the origin as a 502. missing replays are just `false` now across the game and website instead of an error.

room score tokens no longer sit behind a massive mapset download until lazer gives up. the map being played is pulled and verified first, the token comes back inside the client's timeout, then the rest of the set keeps filling the cache behind it.

tiny room ids also stop breaking Discord rich presence, and the visible client name is `zigcho!lazer` in both build lanes. the boring `zigcho-lazer-debug` name still exists underneath only to keep its files away from an official install.
