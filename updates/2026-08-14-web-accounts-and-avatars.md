# the website has real player accounts now

players can sign into `kai.ovh` with the same account they use in game. settings can change the bio, main mode, default score view and default picture without making a second account system.

custom avatars work too. PNG, JPEG and GIF uploads are checked by their real bytes and dimensions, capped properly, then stored as private content-addressed objects in Cloudflare R2. the bucket is not public; Stable, lazer and the website still use the one `a.kai.ovh/{user_id}` address. resetting the picture removes the custom object and goes straight back to the bundled default.

profiles and rankings can now show the combined account, lazer-only scores or Stable ScoreV2 without any of those views rewriting the player's real Stable stats. the pages keep the exact client and mods attached to each play.

the website session is separate from Bancho and uses a secure host-only cookie, same-origin checks and CSRF on every write. PostgreSQL only stores avatar metadata, while the R2 key is limited to the one private bucket and never enters git or the Docker build.

i also cut the readme down from a release diary into the actual project, build and production boundaries. the long history stays in `updates/` where it belongs.

Debug and ReleaseSafe passed against fresh PostgreSQL databases, the private R2 upload/read/delete path passed, and the full login, settings, upload, public-avatar, reset and sign-out flow passed in the browser. Stable stays the complete live lane; lazer has a much better account and website surface now, but realtime and signed client releases are still the work between it and being finished.
