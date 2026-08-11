# chat actually has staff tools now

kai is more than the pp command now. players can ask for help, roll, see who is online, check stats, and use the existing pp commands. moderators can inspect an account, silence or unsilence it, kick it, and keep staff notes. admins can restrict accounts, send announcements or alerts, and lock a channel while something is being dealt with. developers can change roles without touching the database by hand.

the important part is that these are not pretend commands. a silence blocks public chat and DMs, updates the live session, and sends the packets stable expects. restricted players are taken out of everybody else's presence and restarted into the restricted state. normal staff cannot punish other staff, themselves, or kai. every punishment, note, role change, announcement, alert, and channel lock leaves an audit row.

public chat history is in postgres now. normal channels keep their real name, multiplayer rooms are stored under their internal room id, and spectator chat is stored under its host id, so two tabs that both say `#multiplayer` do not get mixed together later. private messages are not stored. `#announce` is read-only unless you are an admin, and `!lock` keeps a normal channel admin-only until `!unlock` opens it again. those controls survive a restart.

the schema moves from 12 to 13 in one transaction. i tested both a fresh postgres database and the exact 12 to 13 upgrade path, plus sqlite rollback parity. the stable fixtures cover silenced senders, silenced DM targets, permission failures, notes, restrictions, channel locks, durable history, and the real client packet responses.

this puts the invite-only stable build around 86% for me. the bancho side is doing the normal player and staff chat work now. next is the BN+ map workflow, then the connected player/staff site and the remaining backup, restore, metrics, and restart work. lazer feature work is still staying where it is until those stable pieces are finished.
