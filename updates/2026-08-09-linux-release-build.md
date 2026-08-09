**zigcho update — the Linux build gate did its job**

The first production container caught a missing Linux unwind link in the new Rust PP boundary. macOS provided it implicitly; Linux correctly refused to link the server without an explicit declaration. The old live release kept serving the whole time and the database was never migrated by the failed build.

I added the Linux runtime link to the server, importer, and test binary. The full test suite and both `ReleaseSafe` binaries now build in the pinned Linux container.

This does not move the player-readiness estimate by itself, so we are still about one third of the way to an invite-only alpha. It does make the PP release reproducible on the actual production operating system instead of only on my Mac.
