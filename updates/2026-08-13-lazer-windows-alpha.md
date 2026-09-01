windows finally has its own zigcho lazer build now.

i added a repeatable win-x64 release path instead of leaving it as a mac-only qa thing. the client is built on an actual windows runner, keeps its storage and ipc separate from official lazer, and has the official updater disabled so it cannot overwrite itself with the wrong client. every zip carries the zigcho and osu revisions, both licences, a full file manifest, and its own sha-256.

the first portable alpha is up here: https://github.com/zigcho/zigcho/releases/tag/lazer-v0.1.0-alpha.1

the release passed all 10 client patch tests, the native windows build, the package verifier, and a public download check. extract the full zip and open app/osu!.exe. it is not signed yet, so smartscreen can still warn.

stable is already live. lazer login, profiles, beatmaps, leaderboards, and solo scores are the working slice in this build. realtime chat, multiplayer, spectating, signing, and a proper installer are still what stand between this alpha and calling the lazer client finished.
