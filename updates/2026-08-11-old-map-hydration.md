**zigcho update — old maps actually finish hydrating now**

found this from the live logs, not a made-up fixture. an old Basshunter map downloaded all 6.7 MB, matched the exact difficulty md5, passed the zip and crc checks, then got thrown away as `InvalidBeatmap`.

the reason was boring: old `.osu` files can have no `BeatmapID` or `BeatmapSetID` inside them. we already had both IDs from osu's metadata response, but the parser refused to use them.

old files can now fill missing IDs from that verified response. files with real IDs still have to match, so this doesn't weaken the archive checks or let the wrong difficulty through.

also fixed the retry state. the old code saw the metadata row and decided the whole map was finished, so one failed archive stayed broken forever. it now checks for the actual `.osu` file. failed downloads can be tried again without starting duplicate jobs for maps that are already downloading.

tests and the full ReleaseSafe build are green. we're around 43% of the way to an invite-only alpha: stable scores, pp, stats, maps, chat, the bot, avatars, countries, and the public routes work; multiplayer depth, lazer's complete signed-in run, moderation, backups, metrics, and proper retry/cache handling are still between this and live players.
