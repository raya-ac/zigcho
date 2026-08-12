# stable screenshots are real files now

the screenshot button used to land on the generic 404 because there was nothing behind Stable's upload route. it now checks the online account, accepts the same multipart fields the client sends, rejects anything over 4 MiB, and only stores actual PNG or JFIF data. each account stops at 1,000 files or 256 MiB.

the reply is the short filename Stable expects. `/ss/{filename}` returns the same bytes with the right image type, and unknown names get a proper 404 instead of the website shell. uploads have their own rate limit so this does not become a free unbounded file host.

screenshots are in PostgreSQL under schema 18. they survive deploys, verified backups, restores, and the SQLite rollback path. the importer now checks all 22 tables and includes screenshot bytes in its blob parity total.

I ran the real HTTP shape locally: register a fresh Stable account, log it into Bancho, upload a PNG, then fetch the returned name. the downloaded file had the exact same SHA-256.

the native Zig PP draft is still a shadow draft. its first parity run was more than ten times wrong on the pinned standard fixture, so it is not touching live ranks just because it compiles. Stable keeps the proven calculator until the Zig engine matches a real map corpus.

this closes the Stable screenshot surface. covers and previews are the remaining media service, then the long soak, restart, restore, rollback, and load gate. lazer and BSS are still parked.
