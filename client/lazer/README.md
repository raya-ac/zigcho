# zigcho lazer client

This is the small part of the custom lazer build that belongs to zigcho. I am not forking the whole osu! source tree into this repository just to change eight endpoints.

`upstream-commit.txt` pins the official client revision I have built and opened. `apply-endpoints.sh` copies the two checked-in endpoint configurations into a clean checkout at that exact revision. Production and development builds both use the same `kai.ovh` hosts so a debug build cannot quietly fall back to `dev.ppy.sh`.

```sh
client/lazer/apply-endpoints.sh work/osu-client
work/dotnet/dotnet publish work/osu-client/osu.Desktop/osu.Desktop.csproj \
  -c Debug -r osx-arm64 --self-contained true
```

The current macOS app is an ad-hoc signed QA build. It is enough for real TLS compatibility work on this machine. It is not a public macOS release; distribution still needs a proper app identity, Developer ID signing, notarization, update metadata, and a clean player data path.
