# changelog feed

`changelog.json` is the live feed manifest. the server polls the fixed raw GitHub path on `raya-ac/zigcho` main, verifies every filename and SHA-256, then swaps the whole parsed feed at once. it keeps the last good copy if GitHub, curl, the manifest or a Markdown file fails.

to publish a changelog without rebuilding the server or any client, add the Markdown file, add its metadata to `changelog.json`, then run:

```sh
tools/changelog-manifest.py --write
tools/changelog-manifest.py --check
```

the checked-in Zig history is still the startup fallback. new server releases should fold live-only entries back into that static list, but a normal changelog-only commit only needs the Markdown and manifest.
