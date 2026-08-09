**zigcho update — the blank profile pictures are gone**

i made the avatar host do something real now.

- every account gets one random anime default from the two pictures in my Downloads.
- the choice is stored on the account, so it does not turn into a different person every time the client refreshes.
- stable gets the picture from `a.kai.ovh/{user_id}` with the right gif or jpeg type and normal cache headers.
- lazer gets the same public avatar url from `/api/v2/me`.
- all the accounts already in the database get a choice during migration 10. new registrations use secure randomness.
- fake user ids return 404 instead of getting an avatar and looking like a real account.

this keeps the server at about **53% done**. avatars are working now; the big work is still multiplayer, the full lazer client flow, moderation/ops, the other pp modes and the rest of the asset services.
