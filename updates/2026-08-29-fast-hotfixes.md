# zigcho release 1.5

small server fixes were spending more time inside the release gate than they did being fixed. i still want exact builds, backups and rollback, but making a 50-line correction wait on the entire server test matrix every time was dumb.

## hotfixes have real patch files now

an eligible hotfix commit carries its exact unified patch and a small json manifest. the manifest pins the base commit, patch hash, schema and one to three existing tests that cover the changed bit. github rejects it if the source and patch disagree, if it is stacked on the wrong base, or if unrelated files get slipped into the commit.

## the runner only builds what it needs

release gates can now recognise a valid hotfix by itself. it runs the named tests, builds only the postgres server in the pinned linux container, boots that exact binary and attaches the patch record to the artifact. the normal full gate still handles normal releases.

## the live switch is shorter

the current server stays up while the candidate, patch hashes, database backup and restore drill are checked. activation then does one short restart and verifies health and metrics. if it fails, the old binary and matching database backup come straight back.

this is not a patch upload route and production never compiles source. database, storage, auth, crypto, pp, anticheat, staff controls, client changes and anything large still use the full release. the short path is for an actual hotfix, not an excuse to hide a release inside a patch file.
