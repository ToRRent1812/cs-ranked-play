[🇬🇧](https://github.com/ToRRent1812/cs-ranked-play/blob/main/README.md)
# CS Ranked Play  

Kompetytywny system rankingowy dla CS 1.6 oraz Czero  
Zainspirowany matchmakingiem turniejowym w grach ala Valorant, CS2, R6: Siege czy Halo  
_____________________
#### DEMONSTRACJA
Możesz zobaczyć plugin w użyciu na moich serwerach testowych  
1.6: ```connect 51.68.155.216:27015```  
CZero: ```connect 51.68.155.216:27016```  
_____________________
#### JAK TO DZIAŁA

Plugin ocenia w ukryciu graczy na podstawie różnych czynników jak obrażenia, zabójstwa, rozbrajanie bomby itd.    
Pod koniec meczu, gracze są sortowani przez WNR (Wynik Na Rundę)  
a później porównywani między sobą by obliczyć ile MMR gracz otrzyma/straci  

__Ocena obecności__ - Im więcej rund zagrasz, tym więcej punktów MMR dostaniesz/stracisz  
__Anty-smurfing__ - Gracze nie mogą spaść z MMR bardziej niż 50% swojego najlepszego rezultatu  
__Tarcza__ - Gracz traci mniej MMR na niższych rangach, mniej irytujące dla każuali  
__Gry kwalifikacyjne__ - Gracz musi rozegrać 5 meczy by otrzymać rangę  
__Sezony__ - Każdy sezon ma niezależny ranking  
__Anty ragequit__ - Jeżeli gracz wyjdzie z serwera, jego statystyki zostaną zapisane dopóki nie zmieni się mapa, lub dopóki nie wróci na serwer
Dane z poprzednich sezonów są zachowane w bazie danych. Admini serwera mogą uruchomić nowy sezon rankingowy w dowolnym dniu wpisując komendę.
_____________________
#### SCREENY
<img width="1372" height="1006" alt="Zrzut ekranu_20260308_152535" src="https://github.com/user-attachments/assets/d1e6145d-b19d-4e43-ab4b-883a4b46ad66" />
<img width="1360" height="1006" alt="Zrzut ekranu_20260308_153349" src="https://github.com/user-attachments/assets/ff5f466d-92d2-4eb2-be20-cfdd255753fe" />
<img width="590" height="128" alt="Zrzut ekranu_20260308_200938" src="https://github.com/user-attachments/assets/4eec219e-45fd-4b4d-b0d8-1cecfff02cde" />

_____________________
#### UKRYTY SYSTEM PUKTOWY

+1 40 DMG w przeciwnika (rank_dmg_cap blokuje maksymalną ilość DMG w rundzie za jaką gracz może otrzymać punkty)   
+1 Headshot / noż / granat / pistol kill   
+1 Zabójstwo ze słabej broni (min. 50 DMG w ofiarę)  
+1 Za każde kolejne zabójstwo w rundzie (aż do Ejsika)  
+1 Zabójstwo z dużej odległości  
+2 Podłożenie bomby  
+3 Rozbrojenie bomby  
+1 Wygranie rundy  
-1 Przegranie rundy  
-1 Śmierć z rąk innego gracza 
-2 Teamkill 
+2 KD Ratio 2.0+  
+1 KD Ratio > 1.0  
-2 KD Ratio < 1.0  
  
Modyfikatory WNR  
__Obecność__ 0-50% -1 | 50-65% -0.5 | 65-80% 0 | 80-90% +0.5 | 90-100% +1

#### RANGI
Takie same jak w CS:GO, Od Silver 1 do Global Elite (5000 MMR)
_____________________
#### RADA
Plugin można używać na serwerach publicznych i prywatnych ALE na serwerach publicznych, upewnij się że masz wgrany:
- Dobry balanser drużyn, jak PTB na przykład
- Wywalacz AFK
- Wywalacz graczy z wysokim pingiem
_____________________
#### INSTALACJA
Upewnij się że twój serwer ma __najnowszą wersję__ [ReHLDS z modułami](https://rehlds.dev/), [AMXX 1.10](https://www.amxmodx.org/downloads.php) oraz [Karlib](https://github.com/UnrealKaraulov/Unreal-KarLib/releases/tag/1)  
Pobierz csr.zip z zakładki [Releases](https://github.com/ToRRent1812/cs-ranked-play/releases) i umieść na serverze w folderze /cstrike/addons/amxmodx/  
Otwórz server/cstrike/addons/amxmodx/configs/plugins.ini edytorem tekstu i na końcu pliku dodaj nową linię __csr.amxx__
_____________________
#### CVARY
__rank_debug 0__ - Włącza dodatkowe logowanie  
__rank_min_players 4__ - Minimalna ilość prawdziwych graczy by rozpocząć ranking na mapie  
__rank_ideal_players 10__ - Idealna ilość graczy na serwerze (prawdziwi+boty) by zdobyć 100% MMR w meczu  
__rank_min_rounds 5__ - Minimalna ilość rund jaką gracz musi zagrać by się liczyć w meczu rankingowym  
__rank_score_cap 10__ - Maksymalna ilość punktów jaką gracz może zdobyć w 1 rundzie  
__rank_match_win_bonus 0__ - Pozwala dodać wygranej drużynie dodatkowe punkty(nie MMR, punkty meczu)
__rank_dmg_cap 540__ - Maksymalna ilość obrażeń jaką gracz może zamienić na punkty w 1 rundzie  
__rank_warmup_time 45__ - Czas rozgrzewki  
__rank_double_gain 0__ - Włącza podwójny zarobek MMR(użyteczne na happy hours/2xp weekendy)  
__rank_karlib_port 8090__ - Port który serwer musi mieć otwarty, by wyświetlać wyniki  
__rank_db_type sqlite__ - Metoda zapisu danych: "sqlite" lub "mariadb"  
__rank_db_host localhost__ - MariaDB host  
__rank_db_user CSR__ - MariaDB użytkownik  
__rank_db_pass password__ - MariaDB hasło  
__rank_db_name CSR__ - MariaDB nazwa bazy  
_____________________
#### KOMENDY ADMINA
__amx_rank_adjust <steamid> <ilość>__ - Dodaj/odejmij graczowi MMR  
__amx_rank_recalc__ - Wymuś koniec meczu rankingowego  
__amx_rank_cancel__ - Anuluj aktualny mecz rankingowy na mapie  
__amx_rank_status__ - Wyświetl w konsoli aktualny stan graczy  
__amx_rank_newseason__ - Rozpocznij nowy sezon rankingowy  
__amx_rank_seasons__ - Pokaż listę wszystkich sezonów rankingowych z datami  
_____________________
#### KOMENDY DLA GRACZY W CZACIE
__!top__ lub __/top__ - Otwiera Top30 najlepszych graczy sezonu  
__!top 1__ lub __/top 1__ - Otwiera Top10 najlepszych graczy pierwszego sezonu  
_____________________
#### UWAGA
By dodać integrację MySQL/MariaDB, użyłem sztucznej inteligencji Claude.
