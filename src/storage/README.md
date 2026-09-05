# storage

`contracts.zig` is the common vocabulary: owned result types, status mappings and shared validation. it must not import either database backend. both backends use those exact types.

`postgres/` is the production backend. `sqlite/` is kept for fixtures and offline tools. both are grouped into accounts, beatmaps, scores, social, multiplayer and moderation, with backend-specific connection and schema handling. `../postgres_store.zig` and `../storage.zig` keep their callers' existing entry points.

the split does not combine transactions or change when a lock is held. `Locked` helpers still require their caller's lock. keep query text, ordering, ownership and error handling with the operation. changing any of those is a behaviour change and should be reviewed as one.

shared types are no longer a reason for PostgreSQL to import SQLite. the fixtures and importers still are a reason to keep SQLite around until they have a replacement.
