# zigcho release 1.3

this one finishes the first proper anticheat review loop instead of pretending a scary number is enough to punish somebody. it also gives developers a sane place to manage roles and moves old usernames into the one place they actually belong.

## the private anticheat stopped accusing normal plays

standard scores were counting `geki` and `katu` twice when checking the object total. that was enough to make clean plays look structurally impossible. the private rules now count each mode correctly, match one replay click to one object and keep stacked objects from reusing the same input.

hardware matches and suspicious client telemetry are evidence now, not an instant restriction. one signal gets audited. related signals can ask for a challenge, but they do not get counted twice just because they came from the same underlying event. only a known cheat signature or a verified client integrity mismatch can propose a restriction, and even that stays in the review queue.

the module is still observe only. it cannot kick, restrict or delete a score by itself.

## rejected Stable scores reach the same review path

login hardware, client telemetry, replay checks and checksum failures now cross the same private module boundary with owned and bounded evidence. a missing replay or bad checksum still gets rejected exactly where Stable expects it, but staff can finally see why it happened instead of getting a dead error and no trail.

the fallback stays built in. if the private module is missing, broken or rejects an input, the public server keeps running and records the safe host decision instead.

## the anticheat page explains what the numbers mean

the staff page now decodes every action, reason, evidence flag, requested decision flag and gameplay metric from the server's canonical definitions. unknown future values keep their number instead of turning into a lie.

`risk` is a review priority from 0 to 1000. `rule confidence` is how confident that ruleset is in the reason it selected. neither one is a cheat probability or a verdict. the page also separates what the module proposed from what Zigcho actually did, which is currently nothing automatic.

## developers have a real roles workspace

developers can grant or revoke one named role at a time: supporter, permanent premium, alumni, tournament staff, beatmap nominator, moderator, admin or developer. raw privilege masks are gone from the website and the in-game commands use the same role names.

every change needs a reason and lands in the audit log. unrelated permissions are preserved, kai cannot be edited, developers cannot remove their own access through the page, and removing somebody's final staff role kills their staff session. active Stable users get a fresh privileges packet instead of waiting for another login.

premium is permanent until a developer explicitly removes it. there is no fake expiry hidden somewhere else.

## old usernames stay on the player page

username history is now a small dropdown directly to the left of the current profile name. it only appears when that account has previous names and it works with a keyboard as well as a mouse.

the old hover behaviour is gone from rankings and every other player list. names there are just names again. restricted accounts and kai's bot profile still do not leak history.

the dropdown was checked at desktop size and on a 390px mobile viewport without making the page wider than the screen.

## what is still waiting

custom clock rates need their own field in the private ABI before the anticheat can reason about them without guessing. the production rules are staying observe only while the reviewed sample grows. i would rather have a useful queue than automate a bad decision.
