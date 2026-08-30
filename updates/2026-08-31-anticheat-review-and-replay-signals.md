# zigcho release 2.0

this release keeps the anticheat observe only, but makes the evidence and the staff workflow much harder to lie to ourselves with.

## review exclusions do not erase evidence

admins can now give a player a scoped review exclusion for one hour, one day, one week or thirty days. it can cover Stable login, client flags, scores or every Stable signal. the reason, creator, expiry and revocation stay in the audit history.

an exclusion does not skip detection, replay fingerprints or hardware evidence. it only removes matching future findings from the default actionable count. suppressed findings remain visible and reviewable, and revoking an exclusion restores normal queue placement without rewriting the old evidence.

self exclusions, kai, ordinary moderators and staff targets are blocked unless a developer is managing the staff account. those checks are repeated inside the database transaction, so a concurrent role change cannot slip through an old permission check.

## replay evidence has a canonical shape now

Stable replay decoding now follows the official historical repairs for fractional deltas, the old prelude frames and remaining backwards frames. the server also stores a versioned digest of the repaired absolute frames, with mouse and keyboard aliases collapsed into the same two input lanes.

that gives staff a separate shadow signal when the same played content appears on another account, even if the compressed upload was repacked. same-account retries, failed plays, different maps, different modes and changed frame content do not count as a match.

long replays with an unusually uniform sub-14ms frame cadence can also create a shadow finding. normal 16ms cadence, multimodal timing, short samples, sparse 1-2ms noise and failed plays do not enter review from that signal.

both new signals are audit only. they cannot combine into a hold, disconnect or restriction.

## the private rules stopped trusting bad geometry

physical mouse and keyboard aliases now count as two logical input lanes, simultaneous chords do not inflate alternation and movement history resets across invalid or long gaps. failed plays still return metrics, but behavioral rules only act on passed plays.

cursor centre, snap and radial decisions are disabled for now because the public host does not yet apply Stable stacking to hitobject positions. those unreliable values are cleared before storage instead of being shown as meaningful staff evidence. timing and input checks remain active in the observe-only queue.

## a configured anticheat has to load

public and private artifacts now agree on exact rule revision 4. the release bundle carries a production host smoke, and activation loads the staged private module before the service is stopped. a configured module with the wrong revision, a missing export or a broken file fails the candidate instead of quietly starting Zigcho with no anticheat.

the module still cannot punish a player by itself. every action and decision flag remains a proposal stored for staff review.

## what is still waiting

lazer score submissions still need their own anticheat evidence contract. cursor rules need a future ABI with proven stacked gameplay-space coordinates. the private evaluator is still an in-process synchronous library, so real crash and timeout isolation needs a worker boundary rather than another threshold.
