# the host map

osu! does not use one neat origin. stable and lazer both expect a collection of old, specific hostnames, so I keep the public contract here instead of hoping I remember it during a certificate renewal.

`deploy/hosts.txt` is the exact TLS list. Every name is one level below `kai.ovh`, routes through Layerline to the same Zig process, and gets the small host-aware landing page at `/`.

- `kai`, `osu`, and `api` are the general website and API entry points
- `c`, `c1` through `c6`, `ce`, and `cho` are the stable Bancho web relays
- `a`, `assets`, `i`, and `s` are kept for avatars, covers, images, and screenshots
- `b`, `bm6`, and `bm10` are kept for beatmap metadata and archive delivery
- `spectator` is kept for lazer spectator and multiplayer streams
- `bss` is kept for beatmap submission traffic

The names existing does not mean every protocol behind them is finished. Asset storage, lazer realtime streams, and beatmap submission are still reserved surfaces. The page says that plainly.

Stable IRC is a separate TCP service. A wildcard HTTPS route cannot provide it, so `irc.kai.ovh` is deliberately not in this list until there is an IRC listener and a separately verified TCP route.
