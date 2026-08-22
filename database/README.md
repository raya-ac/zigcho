# database

the sql lives here instead of being mixed through the server source.

- `sqlite/` keeps the local schema and ordered sqlite migrations.
- `postgres/` keeps the production bootstrap schema and postgres-only migrations.

the server embeds these files at build time, so a release never depends on loose sql files existing beside the binary.
