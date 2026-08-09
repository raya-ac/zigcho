**zigcho update — score submits are finally going to tell us where they break**

Stable is reaching the score endpoint, but Zigcho was turning every bad stage into the same `error: no`. That made a broken multipart body, decrypt failure, bad score shape and checksum mismatch look identical from the outside.

This update gives each rejection stage its own safe server-side reason. It only records the reason, error type and request size. It does not log names, passwords, tokens, hashes, replay data or decrypted score data. The client response stays compatible.

The existing protocol fixtures and the full ReleaseSafe build still pass. We are about 45% of the way to an invite-only alpha. The next real play will now show the exact stable incompatibility, then I can fix it and prove the score, replay, leaderboard and stats path end to end.
