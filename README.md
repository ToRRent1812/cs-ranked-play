
# CS Ranked Play  

Competitive ranking system plugin for CS 1.6 and Czero  
Inspired by ranked matchmaking in Valorant, CS2, R6: Siege and Halo  
_____________________
#### DEMONSTRATION
You can test the plugin with bots on my servers  
1.6: ```connect 51.68.155.216:27015```  
CZero: ```connect 51.68.155.216:27016```  
_____________________
#### HOW IT WORKS

Plugin rates players by earning hidden points each round based on their performance  (damage, kills, objectives, etc)  
At map end, players are sorted by SPR (score per rounds played)  
and then compared to each other to determine MMR gain/lose  

__Participation scaling__ - The more rounds player played, the bigger percentage of final MMR gain/lose he will get  
__Anti-smurf__ - Player cannot drop down below 1/2 of their highest MMR in the current season  
__Shield__ - Player loses less MMR on lower ranks, less frustrating for casual players  
__Placement games__ - player receives first rank after 5 placement matches  
__Seasons__ - Each season is an independent leaderboard  
Previous season data is preserved in database. Server admins launch new ranked season using admin command.
_____________________
#### SCREENSHOTS
<img width="972" height="694" alt="Zrzut ekranu_20260308_152434" src="https://github.com/user-attachments/assets/d20953cc-7411-4844-968c-e485bd04f456" />
<img width="1372" height="1006" alt="Zrzut ekranu_20260308_152535" src="https://github.com/user-attachments/assets/d1e6145d-b19d-4e43-ab4b-883a4b46ad66" />
<img width="1360" height="1006" alt="Zrzut ekranu_20260308_153349" src="https://github.com/user-attachments/assets/ff5f466d-92d2-4eb2-be20-cfdd255753fe" />
<img width="590" height="128" alt="Zrzut ekranu_20260308_200938" src="https://github.com/user-attachments/assets/4eec219e-45fd-4b4d-b0d8-1cecfff02cde" />

_____________________
#### HIDDEN SCORING SYSTEM

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
+2 KD Ratio 2.0+
+1 KD Ratio > 1.0
-1 KD Ratio < 1.0

SPR Modifiers
Presence 0-50% -1 | 50-65% -0.5 | 65-80% 0 | 80-90% +0.5 | 90-100% +1

#### RANK TIERS
Just like CS:GO, from Silver 1 to Global Elite (at 5000 MMR)
_____________________
#### ADVICE
You can use this plugin on both public and private/pub/scrim servers BUT for public servers, make sure You are using:
- Good team balancer like PTB for example
- AFK Kicker
- High ping kicker
_____________________
#### INSTALLATION
Make sure You have __latest__ [ReHLDS with libraries](https://rehlds.dev/), [AMXX 1.10](https://www.amxmodx.org/downloads.php) and [Karlib](https://github.com/UnrealKaraulov/Unreal-KarLib/releases/tag/1)  
Download plugin package from [Releases](https://github.com/ToRRent1812/cs-ranked-play/releases) and put into server/cstrike/addons/amxmodx/  
Open server/cstrike/addons/amxmodx/configs/plugins.ini with text editor and at the end of the file, create a new line __csr.amxx__
_____________________
#### CVARS
__rank_debug 0__ - Toggle additional logging  
__rank_min_players 4__ - Minimum amount of human players to start ranked match  
__rank_ideal_players 10__ - Ideal amount of players (human+bots) for max MMR gain/loss  
__rank_min_rounds 5__ - Minimum amount of rounds a player need to play to be eligible for MMR change  
__rank_score_cap 10__ - Maximum score a player can earn in a single round  
__rank_dmg_cap 550__ - Maximum damage that counts towards player score in a single round  
__rank_warmup_time 45__ - Unranked warmup time in seconds  
__rank_double_gain 0__ - Enables 2x MMR gain on server(useful for happy hours/2xp weekends events)  
__rank_fancy_results 1__ - 1= Use fancy HTML Motd Pages. 0= Use plain text leaderboard(limited)  
__rank_karlib_port 8090__ - Open port to use for HTML Motd pages  
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
___!top___ or __/top__ - Open Top Seasonal leaderboard  
_____________________
#### DISCLAIMER
To add MySQL/MariaDB support, I used Claude AI. You have been warned
