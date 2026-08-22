# zigcho!lazer

i keep one patch against the pinned official osu commit instead of dumping the whole client into this repo.

the patch gives the client its own name, storage and IPC identity, points every player route at `kai.ovh`, keeps official updates away from it, and adds the compatibility work for chat, profiles, leaderboards, scores, rooms, spectating and medals.

## builds

release builds happen on GitHub runners, not on somebody's laptop.

```sh
gh workflow run lazer-clients.yml
```

the workflow applies the patch from a clean checkout, runs the focused client tests once, then builds and verifies:

- Windows x64
- macOS arm64
- Linux x64
- Android arm64
- iOS arm64

every artifact has a SHA-256 sidecar. desktop builds are portable folders with no installer or updater. the Android APK uses runner signing; the iOS IPA is intentionally unsigned and needs signing when it is installed.

`run-local-debug.sh` is only for the loopback QA lane. production builds always use HTTPS on the normal `kai.ovh` hosts.
