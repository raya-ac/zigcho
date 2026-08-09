**zigcho update — relax/autopilot leaderboards show pp, scorev2 gets its own board**

relax and autopilot leaderboards now sort by pp and show the pp value in the score column instead of total score. the stable client's score field now displays pp * 100 for those boards, so "12345" means 123.45pp. vanilla and scorev2 boards still sort and display total score.

scorev2 mod (bit 27) now gets its own leaderboard namespace. it was being lumped in with vanilla, which meant scorev2 plays were competing against vanilla plays on the same board. now scorev2 has its own section, same as relax and autopilot.

the namespace priority is autopilot > relax > scorev2 > vanilla. if you have multiple special mods on, the highest-priority one wins.

loved maps already accept scores and store the pp value in the database, but don't award it to weighted stats. `awards_ranked_pp` is only true for ranked (3) and approved (4), so loved (6) plays count toward total stats but don't affect your pp ranking. no code change needed — this was already correct.
