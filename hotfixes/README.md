# hotfixes

this is the short path for small server fixes. it keeps the change as a normal source commit, stores the exact unified patch beside it, builds on GitHub, and switches the verified binary with one short restart.

it is not arbitrary live code injection. there is no web route that accepts patches and production never compiles source. the active process keeps serving while the candidate is checked and the database backup is restore-tested. the service only stops for the symlink switch and restart. if health fails, the old binary and matching database backup come back automatically.

## make one

start from current `main`, edit the small server slice, then create the patch record:

```sh
python3 tools/hotfix.py create \
  --id 2026-08-29-short-name \
  --summary "plain description of the actual fix" \
  --test-filter "an existing focused test name"
```

inspect the generated `.patch` and `.json`, then commit the source change and both files together. it must be one commit directly on its declared base. pushing that commit makes `release gates` classify it as a hotfix, run only the named tests, build the PostgreSQL server in the pinned Linux container, boot the exact binary, and upload `zigcho-hotfix-linux-x64-<commit>`.

stage that exact artifact under `/opt/zigcho/hotfixes/<commit>` and run its `tools/activate-hotfix.sh` as root. the script checks the base commit, schema, PP marker, patch hash, binary hash and current rollback before touching the service.

## what does not belong here

schema, database/storage, auth, crypto, pp, anticheat, server controls, build files, deployment files, client changes, binary assets, deletes and renames use the full release path. the validator also sends patches over 600 changed lines or 12 source files back to a full release.

that limit is deliberate. a hotfix should be the bit that broke, not a release wearing a smaller name.
