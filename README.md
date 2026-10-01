[🇵🇱](https://github.com/ToRRent1812/cs-ranked-play/blob/main/README-PL.md)
# CS Ranked Play  

Competitive ranking system plugin for CS 1.6 and Czero  
Inspired by ranked matchmaking in Valorant, CS2, R6: Siege and Halo  
_____________________
#### DEMONSTRATION
You can test the plugin with bots on my gungame server  
1.6: ```connect 51.68.155.216:27015```  
_____________________
#### HOW IT WORKS

Plugin rates players by earning hidden points each round based on their performance  (damage, kills, objectives, etc)  
At map end, players are sorted by SPM (score per minute)  
and then compared to each other to determine MMR gain/lose  

__Participation scaling__ - The more rounds player played, the bigger percentage of final MMR gain/lose he will get  
__Anti-smurf__ - Player cannot drop down below 50% of their highest MMR in the current season  
__Shield__ - Player loses less MMR on lower ranks, less frustrating for casual players  
__Placement games__ - player receives first rank after 8 placement matches  
__Seasons__ - Each season is an independent leaderboard  
__Ragequit protection__ - If player disconnects, his data will be saved until map change or reconnect  
Previous season data is preserved in database. Server admins launch new ranked season using admin command.
_____________________
#### SCREENSHOTS
<img width="1918" height="1080" alt="Zrzut ekranu_20261001_235736" src="https://github.com/user-attachments/assets/409e7bd8-9c86-498a-84d6-a69de72e9bae" />
<img width="769" height="184" alt="Zrzut ekranu_20261001_235815" src="https://github.com/user-attachments/assets/7b9e6432-893a-431e-b71f-56249a8e205c" />
<img width="769" height="303" alt="Zrzut ekranu_20261001_235827" src="https://github.com/user-attachments/assets/c0baf921-e8f5-4c3b-a792-fac7b5869e2d" />
<img width="484" height="323" alt="Zrzut ekranu_20261001_235846" src="https://github.com/user-attachments/assets/184531f0-3a1c-400c-9164-ab1058f66b76" />


_____________________
#### HIDDEN SCORING SYSTEM

1 dmg = 1 point  
+20 Headshot/knife/nade/pistol kill  
20% bonus for dealing damage with bad weapon  
+20 Longshot kill  
+200 Bomb Plant  
+300 Bomb Defuse  
+125 Hostage rescued  
-150 Hostage killed  
+50 Round win  
-35 Round lost  
-50 Death  
-100 Teamkill  
10*killstreak Killstreak bonus until ACE
  
#### SPM Modifiers  
They modify SPM at the end of the match  

| PRESENCE % | SPM  |
| ---------- | ---- |
| <50%       | -20% |
| 50-65%     | -10% |
| 80-90%     | +10% |
| 90-100%    | +20% |

| KD RATIO   | SPM  |
| ---------- | ---- |
| <0.5       | -20% |
| 0.5-1.0    | -10% |
| 1.5-2.0    | +10% |
| >2.0       | +20% |

#### RANK TIERS
Just like CS:GO, from Silver 1 to Global Elite (at 3000 MMR)
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
__rank_debug 0/1__ - Toggle additional logging  
__rank_min_players 4__ - Minimum amount of human players to start ranked match  
__rank_ideal_players 10__ - Ideal amount of players (human+bots) for 100% MMR gain/loss  
__rank_min_minutes 5__ - Minimum amount of minutes a player need to play to be eligible for MMR change  
__rank_score_cap 1000__ - Maximum score a player can earn in a single round, doesn't work in round-less modes  
__rank_match_win_bonus 0__ - Give team that won a match extra map score(useful for pro/scrims/pugs)  
__rank_manual_scoring 0/1__ - 1=Disable hidden match scoring, rely on external plugins using csr natives (csr_add_score/csr_set_score)  
__rank_warmup_time 45__ - Unranked warmup time in seconds  
__rank_double_gain 0/1__ - Enables 2x MMR gain on server(useful for happy hours/2xp weekends events)   
__rank_karlib_port 8090__ - Open port to use for HTML Motd pages  
__rank_motd_host__ - Overrides default IP address if somehow HTML motd pages are blank  
__rank_longmatch_minutes 45__ - How many minutes a player need to spend in a match, to receive 20% MMR bonus for long commitment  
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
__/top__ - Open Top30 leaderboard for current season  
__/top 1__ - Open Top10 leaderboard for season 1  
__/rank__ - Show You and players close to you in leaderboard  
__/history__ - Show your seasonal rank history  
_____________________
#### DISCLAIMER
To add MySQL/MariaDB support, I used Claude AI. You have been warned
