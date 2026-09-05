# stable channel compatibility candidate

channel user counts now use the two-byte unsigned field Stable expects, with an independent literal-byte fixture checking the packet boundary.

joining and leaving ordinary public channels updates readable channel lists, including players who have not joined that channel. leaving returns the channel-kick response; repeated joins and parts do not send another update.

multiplayer and spectator channels use the reference's room-specific topics. kai sends the match-created message, lobby subscribers receive the room update without an extra new-match packet, and spectator departure packets follow the pinned reference's order and counts.

the first real two-server comparison caught another bug: idle stats sent a buffer full of NULs instead of an empty map checksum. that is fixed in the follow-up, along with malformed login text and packet framing closing the connection instead of returning a proper bad-request response.

the first complete diagnostic attempt ran all 12 transcripts without skips: spectator, tournament and the static routes passed; nine cases failed. some failures were harness/fixture mistakes, others were real server differences. the [comparison notes](https://github.com/zigcho/zigcho/blob/main/docs/conformance/2026-09-05-live-baseline.md) separate them. failed preflights and stopped steps are not being counted as passes.

this is source work, not a deployment or a claim of complete compatibility. a clean full differential run and installed Stable-client acceptance are still pending. the inventory covers 46 registered packets and 17 PHP routes; inventory coverage does not prove their behaviour matches.
