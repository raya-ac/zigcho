# changelog feed

`changelog.json` is the live feed manifest. the server polls the fixed raw GitHub path on `zigcho/zigcho` main, verifies every filename and SHA-256, then swaps the whole parsed feed at once. it keeps the last good copy if GitHub, curl, the manifest or a Markdown file fails.

to publish a changelog without rebuilding the server or any client, add the Markdown file, add its metadata to `changelog.json`, then run:

```sh
tools/changelog-manifest.py --write
tools/changelog-manifest.py --check
```

the server build generates its complete startup fallback from this manifest and embeds each Markdown file. there is no second hand-maintained release list in Zig. a changelog-only push still reaches running servers without a rebuild; the next binary automatically includes the same history for offline startup.
