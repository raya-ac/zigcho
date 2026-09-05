# stable channel cleanup

channel user counts now use the two-byte unsigned field Stable expects, with an independent literal-byte fixture checking the packet boundary.

joining and leaving ordinary public channels updates readable channel lists, including players who have not joined that channel. leaving returns the channel-kick response; repeated joins and parts do not send another update.

multiplayer and spectator channels use the reference's room-specific topics. kai sends the match-created message, lobby subscribers receive the room update without an extra new-match packet, and spectator departure packets follow the pinned reference's order and counts.

the first real two-server comparison caught another bug: idle stats sent a buffer full of NULs instead of an empty map checksum. that is fixed in the follow-up, along with malformed login text and packet framing closing the connection instead of returning a proper bad-request response.

the first complete diagnostic attempt ran all 12 transcripts without skips: spectator, tournament and the static routes passed; nine cases failed. some failures were harness/fixture mistakes, others were real server differences. the [comparison notes](https://github.com/zigcho/zigcho/blob/main/docs/conformance/2026-09-05-live-baseline.md) separate them. failed preflights and stopped steps are not being counted as passes.

the next comparison also passed the whole multiplayer transcript. the follow-up corrects Direct search/set status fields and keeps set lookup to its actual metadata response, plus matching rating-average formatting. these are wire-format changes, not score or pp recalculations.

presence packets no longer hardcode everyone's rank to zero. login uses its existing stats snapshot, and poll requests prepare ranks outside the session lock, with generation and selected-mod checks before sending them. polling uses the existing bounded PostgreSQL batch query instead of adding one query per online player. the hosted gate also has a Stable-only correction scope; it still builds and boots the production binary and checks PostgreSQL query parity.

the full release gate has passed, including PostgreSQL integration. missing submission fields, reconnect assertions and chat setup were mistakes in our harness; those have been corrected. leaderboards now return their actual map rating.

the score chart now includes the map's known update date and formats empty values and decimals the way Stable expects. the rounding edge case was caught and fixed locally before pushing. our pp system stays exactly as it is; matching an older reference's number was never the goal. kai links and our achievement catalogue stay too.

the final comparison passes 11 cases, including score submission, duplicate retry and replay readback. the remaining failure is the reference throwing an error on its final presence-all request. we aren't making our pp, medals, links or rank tie-breaks identical to someone else's server to get a green comparison.

the first deployment attempt stopped before switching the service because the off-host backup transfer timed out. the new multipart backup path completed a full matching readback on retry, and `dae9643` is now live with these changes and the previous-personal-best chart fix. the Discord release summary is posted.

this is not a claim of complete compatibility. the reference presence-all failure remains documented; Ari has deferred installed Stable-client acceptance for now. the inventory covers 46 registered packets and 17 PHP routes; inventory coverage does not prove their behaviour matches.
