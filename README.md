
## CS Ranked Play  
Competitive ranking system plugin for CS 1.6 and Czero
_____________________

#### HOW IT WORKS

Plugin rates players by earning hidden points each round based on their performance  
(damage, kills, objectives, etc)  
At map end, players are sorted by SPR (score per rounds played)  
and then compared to each other to determine MMR gain/lose.  

__Participation scaling__ - The more rounds player played, the bigger percentage of final MMR gain/lose he will get  
__Anti-smurf__ - Player cannot drop down below 1/4 of their highest MMR in the current season  
__Shield__ - Player loses less MMR on lower ranks  
__Placement games__ - player receives first rank after 5 placement matches  
__Seasons__ - Each season is an independent leaderboard.   
Previous season data is preserved in database. Server admins launch new ranked season using admin command.
______________________
#### SCREENSHOTS
<img width="1375" height="1004" alt="Zrzut ekranu_20260305_153025" src="https://github.com/user-attachments/assets/287b7d7d-672b-4f7b-9140-3cbd2a3627a1" />  
<img width="728" height="170" alt="Zrzut ekranu_20260305_153033" src="https://github.com/user-attachments/assets/bfc0f7ba-c30a-4297-adbb-85b86d7c5a59" />  

______________________
#### GRADING SYSTEM

+1 60 enemy damage dealt (capped at rank_dmg_cap per round to avoid exploits)   
+1 Headshot / knife / grenade / pistol kill   
+1 Bad-weapon kill (>=50 dmg to victim)  
+1 Killstreak kills in one round (until ACE)  
+1 Longshot kill  
+3 Bomb plant  
+4 Bomb Defuse  
+1 Round won  
-1 Round lost  
-2 PvP death  
+1 Positive K/D at map end  
-1 Negative K/D at map end  

#### RANK TIERS
Just like CS:GO, from Silver 1 to Global Elite (at 5000 MMR)
_______________________
#### ADVICE
You can use this plugin on both public and private/pub/scrim servers BUT for public servers, make sure You are using:
- Good team balancer like PTB for example
- AFK Kicker
- High ping kicker
_____________________
#### CVARS
__rank_debug 0__ - Toggle additional logging  
__rank_min_players 4__ - Minimum amount of human players to start ranked match  
__rank_ideal_players 10__ - Ideal amount of players (human+bots) for max MMR gain/loss  
__rank_min_rounds 5__ - Minimum amount of rounds a player need to play to be eligible for MMR change  
__rank_score_cap 10__ - Maximum score a player can earn in a single round  
__rank_dmg_cap 550__ - Maximum damage that counts towards player score in a single round  
__rank_snapshot_freq 10__ - How often in rounds, the plugin should save data  
__rank_warmup_time 45__ - Unranked warmup time in seconds  
__rank_db_type sqlite__ - Saving type: "sqlite" or "mariadb"  
__rank_db_host localhost__ - MariaDB database host  
__rank_db_user CSR__ - MariaDB user  
__rank_db_pass password__ - MariaDB password  
__rank_db_name CSR__ - MariaDB database name  
_____________________
#### ADMIN COMMANDS
__amx_rank_adjust <steamid> <MMR>__ - Add/Substract player MMR by specified number  
__amx_rank_recalc__ - Force map-end calculation  
__amx_rank_cancel__ - Cancel ranked match on current map  
__amx_rank_status__ - Show player match data in console  
__amx_rank_newseason__ - Start a new ranked season  
__amx_rank_seasons__ - List all ranked seasons  
_____________________
#### PLAYER CHAT COMMANDS
___!top___ or __/top__ - Open Seasonal leaderboard  
_____________________
#### INSTALLATION
Make sure You have __latest__ [ReHLDS with libraries](https://rehlds.dev/) and [AMXX 1.10](https://www.amxmodx.org/downloads.php)  
Download csr.amxx from [Releases](https://github.com/ToRRent1812/cs-ranked-play/releases) and put into server/cstrike/addons/amxmodx/plugins  
Open server/cstrike/addons/amxmodx/configs, open plugins.ini with text editor and at the end of the file, create a new line csr.amxx

_____________________
#### DISCLAIMER
To add MySQL/MariaDB support, I used Claude AI. You have been warned
