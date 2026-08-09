**zigcho update — the real lazer client is talking to us now**

I built a custom arm64 lazer client from one pinned official osu! commit and pointed both its production and development paths at the `kai.ovh` hosts. The client reached our API over TLS and immediately found a real mismatch: lazer sends nested `user[...]` registration fields, while zigcho only understood the short fields from my curl checks.

That contract is fixed. Zigcho now decodes the exact form lazer sends, including escaped characters, and turns its raw password into the same credential stable uses. Both clients still share one account and one stored Argon2id secret. I also added the empty seasonal-background response lazer asks for at startup, so that request stops producing a fake error.

The pinned endpoint overrides and apply script are in the public repo. The local macOS client is an ad-hoc signed QA build, not a public release.

**how far off are we?**

About 38% of the way to an invite-only alpha. The custom lazer client is now real and the first account request is understood. I still need to prove registration, token login, `/me`, and the next authenticated requests on the deployed build, then rooms, realtime multiplayer/spectating, moderation, backups, and a properly signed client release.
