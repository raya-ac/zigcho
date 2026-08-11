# bad score bodies stop at the door now

stable trusted every hit counter that fit in an `i32`, then added those counters together before widening them. a made-up score could overflow while calculating accuracy or rebuilding the client checksum. hit counts and combo are capped at ten million, total score is capped at one trillion, and every sum is widened before it starts. those limits are well above a real map without leaving arithmetic open-ended.

lazer used to validate three fields, pass the original JSON into storage, then assume the rest had exactly the right JSON tags. a string where `ruleset_id` or `max_combo` belonged could reach a forced union access instead of a normal client error. the whole score is typed and range-checked once now. bad shapes return `422`; SQLite only receives the parsed score.

mixed mods have one deterministic rule too. RX stays in `relax`, but any custom mod moves the play into `custom` even when RX appeared first. custom scores cannot slip onto a relax board because of array order.

the multipart parser now looks for the complete boundary plus its legal suffix. random `CRLF--` bytes, near matches, and boundary text followed by ordinary replay data stay inside the replay instead of cutting the upload short.

61 tests pass in Debug and ReleaseSafe. the new fixtures cover stable's upper limits, widened checksum and accuracy work, every lazer field storage reads, the typed SQLite write, both RX/custom orders, and binary replays containing fake delimiters.

where it is: still a Debug alpha, around 58% of the way to an invite-only server I would let someone else rely on. next is the public-input edge: JSON escaping, one username policy everywhere, and only trusting forwarded client addresses from the proxy we actually run behind.
