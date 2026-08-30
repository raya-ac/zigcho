# lazer multiplayer models have their own file

the fixed strings, playlist items, room users, matchmaking state, ranked cards, countdowns and room settings are out of the 9,640-line multiplayer file now.

this was a straight move. the field layouts, limits, stage numbers, countdown maths and public names stayed the same, so players should not see a behaviour change from this commit.

it is the first leaf of the multiplayer split. the point is to give the boring value types a proper home before touching any of the live room or connection ownership.
