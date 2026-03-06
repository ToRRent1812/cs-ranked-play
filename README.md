
CS Ranked Play — Competitive ranking system plugin for CS 1.6 and Czero

HOW IT WORKS
Plugin rates players by earning hidden points each round based on their performance
(damage, kills, objectives, etc)
At map end, players are sorted by SPR (score per rounds played)
and then compared to each other to determine MMR gain/lose.
Participation scaling - The more rounds player played, the bigger percentage of final MMR gain/lose he will get
anti-smurf - Player cannot drop down below 1/4 of their highest MMR in the current season
Shield - Player loses less MMR on lower ranks
Placement games - player receives first rank after 5 placement matches
Seasons - Each season is an independent leaderboard. 
Previous season data is preserved in database for preservation. Server admins decide when to launch new ranked seasons

GRADING SYSTEM
+1 60 enemy damage dealt (capped at rank_dmg_cap per round to avoid exploits) 
+1 Headshot / knife / grenade / pistol kill 
+1 Bad-weapon kill (>=50 dmg to victim)
+1 Killstreak kills in one round (until ACE)
+1 Longshot kill
+2 Bomb plant
+3 Bomb Defuse
+1 Round won
-1 Round lost
-1 PvP death
+1 Positive K/D at map end
-1 Negative K/D at map end

RANK TIERS
Just like CS:GO, from Silver 1 to Global Elite (at 5000 MMR)

ADVICE
You can use this plugin on both public and private/pub/scrim servers BUT for public servers, make sure You are using good team balancer like PTB for example
