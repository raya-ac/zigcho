# stable channel compatibility candidate

channel user counts now use the two-byte unsigned field Stable expects, with an independent literal-byte fixture checking the packet boundary.

joining and leaving ordinary public channels updates readable channel lists, including players who have not joined that channel. leaving returns the channel-kick response; repeated joins and parts do not send another update.

multiplayer and spectator channels use the reference's room-specific topics. kai sends the match-created message, lobby subscribers receive the room update without an extra new-match packet, and spectator departure packets follow the pinned reference's order and counts.

this is source work, not a deployment or a claim of complete compatibility. live differential comparison and installed Stable-client acceptance are still pending. the inventory covers 46 registered packets and 17 PHP routes; inventory coverage does not prove their behaviour matches.
