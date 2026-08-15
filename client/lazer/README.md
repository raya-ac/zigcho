# zigcho lazer client

This is the small part of the custom lazer build that belongs to zigcho. I am not forking the whole osu! source tree into this repository just to change the service endpoints and one resource trust boundary.

`upstream-commit.txt` pins the official client revision I have built and opened. `apply-endpoints.sh` copies the checked-in endpoint configurations, trusted-resource store, and trust-boundary tests into a clean checkout at that exact revision. Production uses the normal `kai.ovh` hosts. Development keeps the same website and resource hosts, but its API is deliberately loopback-only for the isolated SSH-tunnel QA lane instead of quietly falling back to `dev.ppy.sh`. The store accepts HTTPS resources from `kai.ovh`, `ppy.sh`, and their proper subdomains; it still rejects plaintext, unrelated hosts, suffix lookalikes, data URLs, and relative paths.

Realtime websocket and SignalR clients are still disabled. Login, profiles, beatmaps, leaderboards, solo score submission, and public chat use the REST API; chat uses a bounded one-second poll. Multiplayer, spectating, and realtime presence stay offline until their separate SignalR service exists.

```sh
client/lazer/apply-endpoints.sh work/osu-client
work/dotnet/dotnet publish work/osu-client/osu.Desktop/osu.Desktop.csproj \
  -c Debug -r osx-arm64 --self-contained true
```

The local Debug endpoint is deliberately loopback HTTP so it can sit in front of an SSH tunnel without changing production routing. Start that QA bundle through `client/lazer/run-local-debug.sh`; it enables insecure requests only after checking that the checked-in API host is exactly `127.0.0.1`. Production still uses HTTPS and the normal framework restriction.

The current macOS app is an ad-hoc signed QA build. It is enough for real TLS compatibility work on this machine. It is not a public macOS release; distribution still needs a proper app identity, Developer ID signing, notarization, update metadata, and a clean player data path.

## windows x64

Windows has its own repeatable production build now. The PowerShell path applies the same pinned endpoint and resource patches, publishes a self-contained `win-x64` Release build, removes debug symbols, writes both project revisions into the package, includes both MIT licences, and checks every file before the zip is accepted.

```powershell
./client/lazer/build-windows.ps1 `
  -Checkout work/osu-client `
  -OutputDirectory artifacts/lazer
```

The result is `zigcho-lazer-0.1.0-alpha.1-windows-x64.zip` plus its SHA-256 file. It keeps its storage and IPC name separate from official lazer, and the official updater is disabled so it cannot replace the custom build. GitHub runs the same build on an actual Windows x64 runner whenever this client slice changes.

This is a portable alpha, not a signed installer. Open `app/osu!.exe` after extracting the whole folder. Windows SmartScreen may warn until the executable has an Authenticode certificate. Public chat now runs over the REST fallback; multiplayer and spectating are still missing, so the package stays marked as a prerelease even though the REST login, beatmap, profile, leaderboard, chat, and solo score paths are connected.
