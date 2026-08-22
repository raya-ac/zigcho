# lazer profiles stop disappearing

profile banners use the same image-shaped URL the lazer profile overlay expects now, and the old banner URL still works for anything already pointing at it. the profile response, account page and asset host all agree on the same versioned image, so the cover no longer turns into an empty block in game.

lazer sessions finally have proper rotating refresh tokens. the client can close, come back later and renew its login instead of silently dropping into offline mode after the one-hour access token expires. a refresh token only works once, cannot be used as an API bearer token and is revoked with the rest of the game session when the account moves between Stable and lazer.

the in-game changelog contains the complete checked-in release history now, including this update. the pinned client surface is written down in `LAZER.md`, and the server-side account, profile, score, replay, chat, room, matchmaking, spectator and map paths are covered together instead of being guessed one endpoint at a time.
