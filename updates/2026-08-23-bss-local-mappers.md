# bss maps belong to the person who uploaded them now

private maps were being uploaded properly, then the normal mapper lookup saw the name in the `.osu` file and quietly replaced it with a matching Bancho account. that is how my map ended up pointing at the wrong user id and `Raya_old_6` instead of local user 4.

BSS ownership is separate now. submitted sets always use the local uploader's id, current username, avatar, roles and profile, and the upstream mapper lookup is skipped for them completely. the same sets now show under the mapper in lazer's profile view and in a new mapped beatmaps section on the website.

pending maps can still keep play history, but they do not have a leaderboard. Stable, lazer and the website all return an empty board until the set is qualified, ranked, approved or loved.
