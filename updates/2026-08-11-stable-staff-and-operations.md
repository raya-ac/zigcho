# stable staff tools and the boring safety work

the staff page is actually usable now. it signs in with the same account as stable, keeps the token in a secure httpOnly cookie, checks live privileges on every request, and binds every write to the session and the website origin. there is no auth token sitting in javascript or local storage.

BN+ can work through the real map queue and its immutable history. moderators can look up a player, add notes, silence them, review hardware matches without getting the full hashes, and answer appeals. admins can handle restrictions and persistent channel locks. none of those pages get their own version of the rules; they call the same storage and bancho paths as the in-game commands.

restricted players have a small appeal page now. it only accepts the account's real password, only works for restricted accounts, and only allows one open appeal of each type. accepting an appeal records the decision but does not secretly unrestrict somebody. that still needs an explicit staff action.

PostgreSQL is on schema 15 for the appeal records. the PP recalc command works against PostgreSQL now, rebuilds best scores and stats in one transaction, and leaves an audit row. local Prometheus metrics are available to the server without exposing them on `kai.ovh`.

the release path is less exciting and much safer. every release takes a checksumed dump, restores it into a disposable database, checks schema 15, invalid indexes, and unvalidated foreign keys, then runs the candidate preflight as the `zigcho` user. if the new process fails health or metrics after the symlink moves, the old release is put back automatically. daily backups run the same restore drill instead of assuming a successful `pg_dump` means the backup is good.

i ran the staff and appeal flows through a fresh HTTP database, then used the actual pages at desktop and phone width. the mobile tabs needed fixing because audit and channels were getting clipped. SQLite, real PostgreSQL, Debug, ReleaseSafe, and the pinned native x86_64 Linux build are part of the same gate. lazer stayed frozen through all of it.

this puts the invite build around 88%. the remaining Stable work is mostly open-launch hardening around map retry/cache cleanup and locking more ruleset PP fixtures. the bancho, score, chat, multiplayer, spectator, website, staff, database, and rollback paths are all real now; i am not calling it 100% until the long-running edge cases have had more player time.
