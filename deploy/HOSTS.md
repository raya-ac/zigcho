# the host map

osu! does not use one neat origin. stable and lazer both expect a collection of old, specific hostnames, so I keep the public contract here instead of hoping I remember it during a certificate renewal.

`deploy/hosts.txt` is the exact HTTP/TLS list. the apex and every listed subdomain route through Layerline to the same Zig process, and each gets the small host-aware landing page at `/`.

- `kai`, `osu`, and `api` are the general website and API entry points
- `c`, `c1` through `c6`, `ce`, and `cho` are the stable Bancho web relays
- `a` serves the stored default avatar for each real user at `/{user_id}`
- `s` serves the Stable screenshot upload links under `/ss/{filename}`
- `assets` and `i` serve beatmap covers, previews, and images
- `b`, `bm6`, and `bm10` are kept for beatmap metadata and archive delivery
- `beatmaps` is the object-backed `.osz` mirror; a miss is fetched, fully checked, stored, and then served from Contabo
- `spectator` is kept for lazer spectator and multiplayer streams
- `bss` is kept for beatmap submission traffic

The names existing does not mean every protocol behind them is finished. BSS is live for premium-gated lazer submissions, package replacement, mapper ownership and the BN queue.

IRC is a separate TCP service, so `irc.kai.ovh` is deliberately not in this HTTP/TLS list. the Zig listener, stunnel configuration and smoke client are checked in; its production certificate and TCP edge still need their own activation and verification before I call that public.
