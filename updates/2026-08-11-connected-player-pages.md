# connected player pages

`kai.ovh` is a real part of the server now instead of a pretty health check. the front page reads the live server counts and top players from PostgreSQL, rankings can switch between vanilla, Relax, and Autopilot, and every listed player has a profile with their actual rank, PP, accuracy, playcount, ranked score, combo, country, role, avatar, and last 20 Stable plays.

maps have a proper public page too. a profile play links to the local beatmap set and its difficulties, status, stars, settings, play count, and archive. the download button only exists when we really have the checked `.osz`; metadata alone does not pretend a download is ready. `kai` and restricted users stay out of public rankings and profiles, and none of the account credential fields are sent to the page.

i kept the website basic on purpose. it is the same dark, small, pink-accented page with the moving boat, just connected now. the secure staff login and BN queue are the next website slice because i do not want moderation sitting behind a fake localStorage token. Stable is about 82% of the way to the invite-only gate: the remaining work is the staff review surface, backup and restore drills, then one complete installed-client launch run before lazer work starts again.
