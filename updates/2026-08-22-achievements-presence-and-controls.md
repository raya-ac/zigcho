# the server looks alive from both clients now

the site shows whether somebody is actually online, which client they are using and what they are doing. Stable keeps its real action and map text, while lazer reports lobby, queue, room, play and spectator state instead of making every account look offline.

one account cannot sit in Stable and lazer at the same time anymore. the second login is refused with a useful message, same-client reconnects still work, and the staff panel can kick or restrict somebody across either client without leaving a dead token or room behind.

the achievement catalogue is 229 medals now. the 105 core medals we can prove from a score and the player's real stats unlock on both clients and pop in game. failed replay data is retained for evidence, but it cannot be downloaded as a replay somebody actually completed.

the lazer client also clears dead presence state and retries after a server restart instead of staying stuck in a fake connected state.
