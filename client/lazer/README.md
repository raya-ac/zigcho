# zigcho lazer client

This is the small part of the custom lazer build that belongs to zigcho. I am not forking the whole osu! source tree into this repository just to change the service endpoints and one resource trust boundary.

`upstream-commit.txt` pins the official client revision I have built and opened. `apply-endpoints.sh` copies the checked-in endpoint configurations, trusted-resource store, and trust-boundary tests into a clean checkout at that exact revision. Production uses the normal `kai.ovh` hosts. Development keeps the same website and resource hosts, but its API is deliberately loopback-only for the isolated SSH-tunnel QA lane instead of quietly falling back to `dev.ppy.sh`. The store accepts HTTPS resources from `kai.ovh`, `ppy.sh`, and their proper subdomains; it still rejects plaintext, unrelated hosts, suffix lookalikes, data URLs, and relative paths.

Realtime websocket and SignalR clients are intentionally disabled for now. Solo login, profiles, beatmaps, leaderboards, and score submission use the REST API; spectator, multiplayer, metadata presence, and websocket chat stay offline without retrying dead endpoints until those services exist.

```sh
client/lazer/apply-endpoints.sh work/osu-client
work/dotnet/dotnet publish work/osu-client/osu.Desktop/osu.Desktop.csproj \
  -c Debug -r osx-arm64 --self-contained true
```

The local Debug endpoint is deliberately loopback HTTP so it can sit in front of an SSH tunnel without changing production routing. Start that QA bundle through `client/lazer/run-local-debug.sh`; it enables insecure requests only after checking that the checked-in API host is exactly `127.0.0.1`. Production still uses HTTPS and the normal framework restriction.

The current macOS app is an ad-hoc signed QA build. It is enough for real TLS compatibility work on this machine. It is not a public macOS release; distribution still needs a proper app identity, Developer ID signing, notarization, update metadata, and a clean player data path.
