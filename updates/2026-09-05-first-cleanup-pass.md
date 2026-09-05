# cutting the stuff we stopped using

removed the old native Zig PP prototype. the server was already using the pinned Rust calculators; the leftover prototype only had tests calling it. the exported-map BOM check now runs through the calculator we actually ship, and the Stable, lazer, Relax and Autopilot calculation paths stay as they were.

the changelog has one release list now. the build reads the JSON manifest, checks the Markdown hashes and generates the complete offline startup history in the build cache. adding an update no longer means copying the same metadata into Zig and changing a handful of test counts.

removed redundant tests that searched for exact implementation strings. the stored role, BSS ownership, session takeover and score behaviour checks remain. the external Stable harness now pins the code it checks out as well as the workflow file, and the internal org diagram uses the actual production release path.

normal server builds also stopped compiling and shipping the old import and migration utilities every time. those are still available through `zig build legacy-tools` or the explicit release-workflow option. backups and rollback stay in the normal release.

the two remaining giant runtime files have their own domain folders now. multiplayer is split into room lifecycle, settings, gameplay, playlists, ranked queues and cards, archives, scores and protocol handling. its existing tests live beside those parts. SQLite is split into accounts, social, moderation, beatmaps, scores, multiplayer and object storage. the old entry points still work; this is a move, not a scoring or protocol rewrite.

PostgreSQL no longer gets its shared types and validation rules by importing the SQLite backend. those live in `storage/contracts.zig` now. SQLite still exists for the fixtures and offline tools that use it; removing that backend is a separate job, not something hidden in a folder cleanup.

shared grade mapping and room-score token bits live there too. the changelog test reads its manifest through the changelog module, so the Linux package boundary stays intact.
