# zigcho has its own github org now

the public server repo and the private zigcho anticheat repo now live under the `zigcho` github organisation. nothing was renamed and both repos kept their history, visibility and settings.

the Blacksmith migration was removed first. it landed before the repos were in an organisation and left every workflow pointing at runners this account could not use. the auto-created migration branch is gone too.

all active download, changelog, commit and raw github links now point straight at `zigcho/zigcho`. the old `raya-ac` links will redirect, but the server no longer depends on that redirect. workflows are still on the normal github-hosted runners until we deliberately decide to change them again.
