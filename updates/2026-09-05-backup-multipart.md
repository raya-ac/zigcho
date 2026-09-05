# stop sending the whole backup in one go

the 120 mb release backup hit the old single-upload deadline. the database restore was fine; the transfer stopped the release before it touched the running server.

backups now use the storage tools already installed on the host: 8 mb upload parts, four upload workers, independently retried 256 kb read ranges and a capped reader pool. the full downloaded SHA-256 has to match the original. credentials stay out of command arguments and release logs. a failed transfer keeps the original dump and stops activation.

normal releases, hotfixes, scheduled backups and rollback downloads use the same helper. hotfixes now verify their off-host backup before stopping the old service too. existing recovery files cannot be overwritten by a download.

the retained 119,808,422-byte production backup has now completed a full matching readback with this path. the multipart upload took about 50 seconds; the larger read streams were still too slow, which is why verification uses small requests.

this does not change pp, scores, avatars or in-game map uploads. the shared Stable score, retry and replay checks are already passing. the backup fix still needs its own release gate and live activation before this is called deployed.
