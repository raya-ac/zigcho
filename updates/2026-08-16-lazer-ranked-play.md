# lazer ranked play

ranked multiplayer is actually playable now. the ranked pool pairs two people, gives both players a real card hand, handles discards, draws and played cards, then runs the scores through the same token and replay path as every other lazer play. rounds move through damage and results until somebody wins. leaving the match forfeits it cleanly instead of leaving the other player in a dead room.

i fixed the score screen while i was in there. the leaderboard and rank panel now follow the exact mods you picked instead of comparing everything on the same board. custom mods still work when Relax or Autopilot is carrying the score namespace. losing the spectator socket while the score itself is submitting over HTTP also stops showing the big "connection to online servers was interrupted" warning. real multiplayer and spectator disconnects still show it.

Stable has not been disturbed by any of this. login, scores, PP, chat, multiplayer and spectating all passed again beside the lazer tests. Windows gets this as `0.1.0-alpha.8`, still as a portable zip. there is no installer or signing job attached to it anymore because we do not need one.
