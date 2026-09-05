# stop sending the whole backup in one go

the 120 mb release backup hit the old single-upload deadline. the database restore was fine; the transfer stopped the release before it touched the running server.

backups now use the storage tools already installed on the host: 8 mb upload parts, four upload workers, independently retried 256 kb read ranges and a capped reader pool. the full downloaded SHA-256 has to match the original. credentials stay out of command arguments and release logs. a failed transfer keeps the original dump and stops activation.

normal releases, hotfixes, scheduled backups and rollback downloads use the same helper. hotfixes now verify their off-host backup before stopping the old service too. existing recovery files cannot be overwritten by a download.

the retained 119,808,422-byte production backup has now completed a full matching readback with this path. the multipart upload took about 50 seconds; the larger read streams were still too slow, which is why verification uses small requests.

the backup gate passed, and this is now deployed with `dae9643`. one production readback timed out before the service switch; the bounded retry completed all 119,808,421 bytes with a matching SHA-256. slow storage can still stop a release, but it leaves the old server online and the local backup intact.

this transport change does not change pp, scores, avatars or in-game map uploads. activation kept schema 48 and did not recalculate pp. the previous build remains available for rollback.
