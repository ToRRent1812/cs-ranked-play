/*
 * CS Ranked Play — Competitive ranking system plugin for CS 1.6 and Czero
 *
 * HOW IT WORKS
 *   Each round players earn hidden score based on performance
 *   (damage, kills, objectives). At map end players are sorted by SPR
 *   (score per round) and compared pairwise to determine MMR change.
 *   Participation scaling: the more rounds played, the larger the MMR swing.
 *   Anti-smurf: cannot drop below 1/2 of peak MMR in the current season.
 *   Shield: reduced MMR loss at lower ranks.
 *   Placement: first rank assigned after PLACEMENT_MAPS completed maps.
 *   Seasons: independent leaderboards; admins control season transitions.
 *
 * SCORING
 *   +1  per 60 damage dealt (capped at rank_dmg_cap per round)
 *   +1  headshot / knife / grenade / pistol kill
 *   +1  bad-weapon kill (≥50 dmg to victim)
 *   +1  killstreak kill bonus (up to ACE)
 *   +1  longshot kill
 *   +2  bomb plant
 *   +3  bomb defuse
 *   +1  round win / -1 round loss
 *   -1  PvP death
 *   +1  positive K/D at map end / -1 negative K/D
 *   Presence SPR bonus/penalty: 0-50% -1 | 50-65% -0.5 | 65-80% 0 | 80-90% +0.5 | 90-100% +1
 */

#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <fakemeta>
#include <sqlx>
#include <lang>
#include <karlab>

#define PLUGIN     "CSR - CS Ranked Play"
#define VERSION    "1.0.3"
#define AUTHOR     "ToRRent"

#define STATE_WAITING   0
#define STATE_WARMUP    1
#define STATE_STARTING  2
#define STATE_LIVE      3
#define STATE_CANCELLED 4
#define STATE_ENDED     5

#define TASK_WARMUP_TIMER 9901
#define TASK_HUD_BASE     9903
#define TASK_MAP_END      9902

#define MAX_PLAYERS     32
#define PLACEMENT_MAPS  5
#define START_POINTS    250
#define RANK_COUNT      18
#define MMR_CAP         9999
#define MMR_MAX_GAIN    125
#define MMR_MAX_LOSE    -125

#define SCORE_DMG_PER_POINT 40
#define SCORE_KILL_BONUS     1
#define SCORE_BAD_WEAPON     1
#define SCORE_LONGSHOT       1
#define SCORE_PLANT          2
#define SCORE_DEFUSE         3
#define SCORE_ROUND_WIN      1
#define SCORE_ROUND_LOST    -1
#define SCORE_DEATH         -1
#define SCORE_TEAMKILL      -2
#define SCORE_POSITIVE_KD    1
#define SCORE_NEGATIVE_KD   -1
#define BAD_WEAPON_MIN_DMG  50
#define MAX_KILLSTREAK       5

#define _H(%1) add(szHTML, charsmax(szHTML), %1)

#define WC_PISTOL  0
#define WC_SMG     1
#define WC_SHOTGUN 2
#define WC_RIFLE   3
#define WC_SNIPER  4
#define WC_KNIFE   5
#define WC_NADE    6

#define HIT_HEAD   1

new const LongshotDist[8] = { 800, 1200, 400, 2500, 3000, 0, 0, 0 }

new const RankNames[RANK_COUNT][] = {
    "Silver I", "Silver II", "Silver III", "Silver IV",
    "Silver Elite", "Silver Master",
    "Gold Nova I", "Gold Nova II", "Gold Nova III", "Gold Master",
    "Master Guardian I", "Master Guardian II", "Master Guardian Elite",
    "Distinguished Master Guardian",
    "Legendary Eagle", "Legendary Eagle Master",
    "Supreme Master", "Global Elite"
}

new const RankNamesShort[RANK_COUNT][] = {
    "Silver 1","Silver 2","Silver 3","Silver 4","Silv. Elite","Silv. Mst.",
    "Gold 1","Gold 2","Gold 3","Gold Mst.",
    "MG1","MG2","MGE","DMG",
    "LE","LEM","SUPREME","GLOBAL"
}

new const RankThresholds[RANK_COUNT + 1] = {
    0, 60, 125, 200, 280, 365,
    465, 610, 765, 945,
    1135, 1425, 1745, 2095,
    2480, 3055, 3750, 5000,
    9999
}

new const ShieldLossPct[RANK_COUNT] = {
    10, 10, 10, 20, 20, 20,
    30, 30, 40, 40,
    50, 50, 60, 60,
    70, 80, 90, 100
}

new const WorseWin[11]   = {  50,  46,  42,  38,  34,  30,  26,  22,  18,  14,  10 }
new const BetterWin[11]  = {  50,  55,  60,  65,  70,  75,  85,  95, 105, 115, 125 }
new const WorseLose[11]  = { -50, -46, -42, -38, -34, -30, -26, -22, -18, -14, -10 }
new const BetterLose[11] = { -50, -55, -60, -65, -70, -75, -85, -95,-105,-115,-125 }

new g_iPoints[MAX_PLAYERS + 1]
new g_iPeakPoints[MAX_PLAYERS + 1]
new g_iMapsPlayed[MAX_PLAYERS + 1]
new bool:g_bInDB[MAX_PLAYERS + 1]
new g_szSteamID[MAX_PLAYERS + 1][35]
new g_szName[MAX_PLAYERS + 1][64]
new g_iMatchScore[MAX_PLAYERS + 1]
new g_iDmgBuffer[MAX_PLAYERS + 1]
new g_iRoundsPresent[MAX_PLAYERS + 1]
new g_iRoundsInMatch[MAX_PLAYERS + 1]
new g_iPlayerTeam[MAX_PLAYERS + 1]
new bool:g_bParticipated[MAX_PLAYERS + 1]
new g_iMapKills[MAX_PLAYERS + 1]
new g_iMapDeaths[MAX_PLAYERS + 1]
new g_iKillStreak[MAX_PLAYERS + 1]
new g_iRoundDmgDealt[MAX_PLAYERS + 1]
new g_iRoundScoreEarned[MAX_PLAYERS + 1]
new g_iDmgToVictim[MAX_PLAYERS + 1]
new g_iGlobalPos[MAX_PLAYERS + 1]
new g_ifriend[MAX_PLAYERS + 1]
new g_iMatchState = STATE_WAITING
new g_iTotalRounds
new g_iTeamRounds[3]
new g_iCurrentSeason = 1
new g_cvarDebug
new g_cvarMinPlayers
new g_cvarIdealPlayers
new g_cvarMinRounds
new g_cvarScoreCap
new g_cvarDmgCap
new g_cvarWarmupTime
new g_cvarDBType
new g_cvarDBHost
new g_cvarDBUser
new g_cvarDBPass
new g_cvarDBName
new g_cvarDoubleGain
new g_cvarKarPort
new g_szResultsHTML[16384]
new g_szTopHTML[16384]
new bool:g_bKarLibLoaded = false
new g_statussync
new g_iMsgSayText
new g_PlayerName
new Handle:g_hSQLTuple
new Handle:g_hSQL
new bool:g_forcedwin = false

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR)
    register_dictionary("csr.txt")

    g_cvarDebug = register_cvar("rank_debug","0",FCVAR_SERVER) // Debug mode
    g_cvarMinPlayers = register_cvar("rank_min_players","4",FCVAR_SERVER) // Minimum amount of human players to start ranked match
    g_cvarIdealPlayers = register_cvar("rank_ideal_players","10",FCVAR_SERVER) // Ideal amount of players for max MMR gain/loss
    g_cvarMinRounds = register_cvar("rank_min_rounds","5", FCVAR_SERVER) // Minimum amount of rounds a player need to play to be eligible for MMR change
    g_cvarScoreCap = register_cvar("rank_score_cap","10",FCVAR_SERVER) // Maximum score a player can earn in a single round
    g_cvarDmgCap = register_cvar("rank_dmg_cap","550",FCVAR_SERVER) // Maximum damage that counts towards player score in a single round
    g_cvarDoubleGain = register_cvar("rank_double_gain","0",FCVAR_SERVER) // 1 = double MMR gain bonus event
    g_cvarWarmupTime = register_cvar("rank_warmup_time","45",FCVAR_SERVER) // Warmup time in seconds
    g_cvarKarPort = register_cvar("rank_karlib_port","8090",FCVAR_SERVER|FCVAR_PROTECTED) // Port to use MOTD webpages
    g_cvarDBType = register_cvar("rank_db_type","sqlite",FCVAR_SERVER) // Saving type: "sqlite" or "mariadb"
    g_cvarDBHost = register_cvar("rank_db_host","127.0.0.1",FCVAR_SERVER|FCVAR_PROTECTED) // Database host
    g_cvarDBUser = register_cvar("rank_db_user","CSR",FCVAR_SERVER|FCVAR_PROTECTED) // Database user
    g_cvarDBPass = register_cvar("rank_db_pass","",FCVAR_SERVER|FCVAR_PROTECTED) // Database password
    g_cvarDBName = register_cvar("rank_db_name","CSR",FCVAR_SERVER|FCVAR_PROTECTED) // Database name

    RegisterHookChain(RG_CBasePlayer_TakeDamage,"OnTakeDamage",false)
    RegisterHookChain(RG_CBasePlayer_Killed,"OnPlayerKilled",false)
    RegisterHookChain(RG_RoundEnd,"OnRoundEnd",false)
    RegisterHookChain(RG_CBasePlayer_Spawn,"OnPlayerSpawn",false)
    RegisterHookChain(RG_PlantBomb,"OnBombPlanted",true)
    RegisterHookChain(RG_CGrenade_DefuseBombEnd,"OnBombDefused",true)
    register_event("HLTV","OnNewRound","a","1=0","2=0")
    register_logevent("Round_Restart",2,"1&Restart_Round_","1=Game_Commencing")
    register_event("30","OnMapEnd","a");

    register_concmd("amx_rank_adjust","CmdRankAdjust",ADMIN_BAN, "<steamid> <mmr>")
    register_concmd("amx_rank_recalc","CmdRankRecalc",ADMIN_BAN, "Force map-end calculation")
    register_concmd("amx_rank_cancel","CmdRankCancel",ADMIN_BAN, "Cancel current match")
    register_concmd("amx_rank_status","CmdRankStatus",ADMIN_BAN, "Show match state and scores")
    register_concmd("amx_rank_newseason","CmdRankNewSeason",ADMIN_BAN, "[number] Start a new season")
    register_concmd("amx_rank_seasons","CmdRankSeasons",ADMIN_BAN, "List all seasons")

    register_clcmd("say","CmdSay")
    register_clcmd("say_team","CmdSay")

    register_event("StatusText", "HUD_ShowSelf", "b")
    register_event("StatusValue", "setTeam", "bef", "1=1")
    register_event("StatusValue", "showStatus", "bef", "1=2", "2!0")
    register_event("StatusValue", "hideStatus", "bef", "1=1", "2=0")

    SetMatchState(STATE_WAITING)
    set_task(2.0, "Task_CheckPlayerCount")
    g_statussync = CreateHudSyncObj()
    g_iMsgSayText = get_user_msgid("SayText")
    g_PlayerName = get_xvar_id("PlayerName")
    server_cmd("mp_chattime 20") // Making sure ranked play can show the end results
}

public Task_CheckPlayerCount()
{
    CheckPlayerCount()
}

public plugin_end()
{
    if (g_hSQL      != Empty_Handle) SQL_FreeHandle(g_hSQL)
    if (g_hSQLTuple != Empty_Handle) SQL_FreeHandle(g_hSQLTuple)
    if (g_bKarLibLoaded) karlib_stop_mini_server()
}


public plugin_cfg()
{
    remove_task(TASK_MAP_END)
    SetMatchState(STATE_WAITING)
    g_forcedwin = false
    set_task(3.0, "Task_SQL_Init")

    // KarLib stuff
    if (!g_bKarLibLoaded)
    {
        new iPort = get_pcvar_num(g_cvarKarPort)
        if (iPort > 0 && iPort < 65536)
        {
            karlib_init_mini_server(iPort)
            g_bKarLibLoaded = true
            server_print("[CSR] KarLib HTTP server started on port %d", iPort)
        }
        else
        {
            log_amx("[CSR] ERROR: rank_karlib_port is not set. KarLib is required.")
        }
    }

    set_task(6.0, "Task_BuildTopHTML")
}

public karlib_mini_server_req(const ip[], const params[], const values[], const path[])
{
    static szResp[16640]

    if (containi(path, "csr_results") != -1)
    {
        if (g_szResultsHTML[0] != EOS)
            copy(szResp, charsmax(szResp), g_szResultsHTML)
        else
            copy(szResp, charsmax(szResp), "<body bgcolor=#111><font color=#aaa>No results yet.</font></body>")
    }
    else if (containi(path, "csr_top") != -1)
    {
        new iReqSeason = 0
        new iSemicolon = contain(params, "season")
        if (iSemicolon != -1)
        {
            new iIdx = 0
            for (new i = 0; i < iSemicolon; i++)
                if (params[i] == ';') iIdx++

            new szVal[12]
            new iCur = 0, iStart = 0
            for (new j = 0; values[j] != EOS; j++)
            {
                if (iCur == iIdx)
                {
                    iStart = j
                    break
                }
                if (values[j] == ';') iCur++
            }
            copyc(szVal, charsmax(szVal), values[iStart], ';')
            iReqSeason = str_to_num(szVal)
        }

        if (iReqSeason > 0 && iReqSeason != g_iCurrentSeason)
            BuildSeasonHTML(iReqSeason, szResp, charsmax(szResp))
        else if (g_szTopHTML[0] != EOS)
            copy(szResp, charsmax(szResp), g_szTopHTML)
        else
            copy(szResp, charsmax(szResp), "<body bgcolor=#111><font color=#aaa>No top data yet.</font></body>")
    }
    else
    {
        copy(szResp, charsmax(szResp), "<body bgcolor=#111><font color=#aaa>Not found.</font></body>")
    }

    karlib_mini_server_res(ip, szResp)
}

public plugin_natives()
{
    register_library("csr");
    register_native("csr_get_points","_native_get_points")
    register_native("csr_get_rank_name","_native_get_rank_name")
    register_native("csr_is_placement","_native_is_placement")
    register_native("csr_get_state","_native_get_state")
    register_native("csr_custom_win","_native_custom_win")
    register_native("csr_add_score","_native_add_score")
}

SetMatchState(iNew)
{
    if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] State %d -> %d", g_iMatchState, iNew)

    g_iMatchState = iNew

    switch (iNew)
    {
        case STATE_WAITING:
        {
            ResetMapData();
            remove_task(TASK_WARMUP_TIMER)
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_WAITING", get_pcvar_num(g_cvarMinPlayers))
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_WAITING");
        }
        case STATE_WARMUP:
        {
            remove_task(TASK_WARMUP_TIMER)
            set_cvar_num("mp_forcerespawn", 2)
            set_task(float(get_pcvar_num(g_cvarWarmupTime)), "Task_WarmupExpired", TASK_WARMUP_TIMER)
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "RANK_WELCOME_1")
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "RANK_WELCOME_2")
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_WARMUP_START", get_pcvar_num(g_cvarWarmupTime))
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_WARMUP");
        }
        case STATE_STARTING:
        {
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_RESTARTING")
            set_cvar_num("mp_forcerespawn", 0)
            server_cmd("sv_restart 3")
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_STARTING, refreshing DB data");
        }
        case STATE_LIVE:
        {
            set_cvar_num("mp_forcerespawn", 0)
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_LIVE")
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_LIVE");
            ResetMapData()
        }
        case STATE_CANCELLED:
        {
            remove_task(TASK_WARMUP_TIMER)
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_CANCELLED");
        }
    }
}

public Round_Restart()
{
    if (g_iMatchState == STATE_WAITING) SetMatchState(STATE_WARMUP)
}

public Task_WarmupExpired()
{
    if (g_iMatchState != STATE_WARMUP) return
    new iState = (CountHumanPlayers() >= get_pcvar_num(g_cvarMinPlayers)) ? STATE_STARTING : STATE_WAITING
    SetMatchState(iState)
}

CheckPlayerCount()
{
    new iMin   = get_pcvar_num(g_cvarMinPlayers)
    new iCount = CountHumanPlayers()

    switch (g_iMatchState)
    {
        case STATE_WAITING:
        {
            if (iCount >= iMin) SetMatchState(STATE_WARMUP)
        }
        case STATE_WARMUP:
        {
            if (iCount < iMin) SetMatchState(STATE_WAITING)
        }
        case STATE_LIVE:
        {
            if (iCount < iMin) SetMatchState(STATE_CANCELLED)
        }
        case STATE_CANCELLED:
        {
            if (iCount >= iMin)
            {
                SetMatchState(STATE_LIVE)
                client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_RESUMED")
            }
        }
    }
}

CountHumanPlayers()
{
    new players[MAX_PLAYERS], iNum
    get_players(players, iNum, "c")
    return iNum
}

GetPlayerRank(iPoints)
{
    if (iPoints >= MMR_CAP) return RANK_COUNT - 1
    for (new i = 0; i < RANK_COUNT; i++)
        if (iPoints < RankThresholds[i + 1])
            return i
    return RANK_COUNT - 1
}

GetGlobalPosition(id)
{
    if (g_iMapsPlayed[id] < PLACEMENT_MAPS || g_hSQL == Empty_Handle)
    {
        g_iGlobalPos[id] = -1
        return -1
    }

    new szQuery[192]
    formatex(szQuery, charsmax(szQuery),
        "SELECT COUNT(*)+1 FROM csr_players WHERE maps_played>=%d AND points>%d AND season=%d",
        PLACEMENT_MAPS, g_iPoints[id], g_iCurrentSeason)

    new Handle:hQuery = SQL_PrepareQuery(g_hSQL, "%s", szQuery)
    if (hQuery == Empty_Handle) return g_iGlobalPos[id]

    if (SQL_Execute(hQuery) && SQL_NumResults(hQuery) > 0)
        g_iGlobalPos[id] = SQL_ReadResult(hQuery, 0)
    SQL_FreeHandle(hQuery)
    return g_iGlobalPos[id]
}

GetWeaponClass(const szClass[])
{
    if (equal(szClass, "weapon_knife")) return WC_KNIFE
    if (equal(szClass, "weapon_hegrenade") || equal(szClass, "weapon_flashbang") || equal(szClass, "weapon_smokegrenade")) return WC_NADE
    if (equal(szClass, "weapon_m3") || equal(szClass, "weapon_xm1014")) return WC_SHOTGUN
    if (equal(szClass, "weapon_awp") || equal(szClass, "weapon_g3sg1") || equal(szClass, "weapon_sg550") || equal(szClass, "weapon_scout")) return WC_SNIPER
    if (equal(szClass, "weapon_usp") || equal(szClass, "weapon_glock18") || equal(szClass, "weapon_deagle") || equal(szClass, "weapon_p228") || equal(szClass, "weapon_elite") || equal(szClass, "weapon_fiveseven")) return WC_PISTOL
    if (equal(szClass, "weapon_mp5navy") || equal(szClass, "weapon_tmp") || equal(szClass, "weapon_mac10") || equal(szClass, "weapon_p90") || equal(szClass, "weapon_ump45")) return WC_SMG
    return WC_RIFLE
}

bool:IsBadWeapon(const szClass[])
{
    return equal(szClass, "weapon_p228") || equal(szClass, "weapon_elite") || equal(szClass, "weapon_fiveseven") || equal(szClass, "weapon_scout")
        || equal(szClass, "weapon_ump45") || equal(szClass, "weapon_mac10") || equal(szClass, "weapon_tmp") || equal(szClass, "weapon_m3") || equal(szClass, "weapon_xm1014")
}

ResetPlayerMatchData(id)
{
    g_iMatchScore[id]       = 0
    g_iDmgBuffer[id]        = 0
    g_iRoundsPresent[id]    = 0
    g_iRoundsInMatch[id]    = 0
    g_iPlayerTeam[id]       = 0
    g_bParticipated[id]     = false
    g_iKillStreak[id]       = 0
    g_iRoundDmgDealt[id]    = 0
    g_iRoundScoreEarned[id] = 0
    g_iMapKills[id]         = 0
    g_iMapDeaths[id]        = 0
    g_iDmgToVictim[id]      = 0
    g_szName[id][0]         = EOS
}

ResetMapData()
{
    g_iTotalRounds   = 0
    g_iTeamRounds[1] = 0
    g_iTeamRounds[2] = 0
    for (new id = 1; id <= MAX_PLAYERS; id++)
        ResetPlayerMatchData(id)
}

// Claude AI SQL Stuff
public Task_SQL_Init()
{
    SQL_Init()
}

SQL_Init()
{
    if (g_hSQL != Empty_Handle)
        return

    new szType[10]
    get_pcvar_string(g_cvarDBType, szType, charsmax(szType))

    if (equali(szType, "mariadb") || equali(szType, "mysql"))
    {
        SQL_SetAffinity("mysql")
        new szHost[64], szUser[32], szPass[64], szName[64]
        get_pcvar_string(g_cvarDBHost, szHost, charsmax(szHost))
        get_pcvar_string(g_cvarDBUser, szUser, charsmax(szUser))
        get_pcvar_string(g_cvarDBPass, szPass, charsmax(szPass))
        get_pcvar_string(g_cvarDBName, szName, charsmax(szName))
        g_hSQLTuple = SQL_MakeDbTuple(szHost, szUser, szPass, szName)
        log_amx("[CSR] Using MariaDB: %s@%s/%s", szUser, szHost, szName)
    }
    else
    {
        SQL_SetAffinity("sqlite")
        g_hSQLTuple = SQL_MakeDbTuple("", "", "", "CSR.sqlite")
        log_amx("[CSR] Using SQLite: CSR.sqlite")
    }

    new szError[256], iError
    g_hSQL = SQL_Connect(g_hSQLTuple, iError, szError, charsmax(szError))
    if (g_hSQL == Empty_Handle)
    {
        log_amx("[CSR] DB connection FAILED: %s", szError)
        return
    }
    else if (get_pcvar_num(g_cvarDebug))
    {
        log_amx("[CSR] DB connection OK: handle=%d", g_hSQL)
    }

    if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Creating tables...");

    SQL_SimpleQuery(g_hSQL,
        "CREATE TABLE IF NOT EXISTS csr_seasons ( \
            season     INT         NOT NULL PRIMARY KEY, \
            label      VARCHAR(64) NOT NULL DEFAULT '', \
            started_at INT         NOT NULL DEFAULT 0, \
            ended_at   INT         NOT NULL DEFAULT 0)")

    SQL_SimpleQuery(g_hSQL,
        "CREATE TABLE IF NOT EXISTS csr_players ( \
            steamid     VARCHAR(35) NOT NULL, \
            season      INT         NOT NULL, \
            name        VARCHAR(64) NOT NULL DEFAULT '', \
            points      INT         NOT NULL DEFAULT 250, \
            peak_points INT         NOT NULL DEFAULT 250, \
            maps_played INT         NOT NULL DEFAULT 0, \
            PRIMARY KEY (steamid, season))")

    SQL_SimpleQuery(g_hSQL,
        "CREATE INDEX IF NOT EXISTS idx_players_season_points ON csr_players (season, points DESC)")

    DB_LoadCurrentSeason()
    log_amx("[CSR] Database ready (season %d).", g_iCurrentSeason)
}

DB_LoadCurrentSeason()
{
    new Handle:hQuery = SQL_PrepareQuery(g_hSQL, "%s",
        "SELECT season FROM csr_seasons ORDER BY season DESC LIMIT 1")

    new bool:bFound = false
    if (hQuery != Empty_Handle)
    {
        if (SQL_Execute(hQuery) && SQL_NumResults(hQuery) > 0)
        {
            g_iCurrentSeason = SQL_ReadResult(hQuery, 0)
            bFound = true
        }
        SQL_FreeHandle(hQuery)
    }

    if (!bFound)
    {
        g_iCurrentSeason = 1
        new szQ[128]
        formatex(szQ, charsmax(szQ),
            "INSERT INTO csr_seasons (season, label, started_at, ended_at) \
             VALUES (1, 'Season 1', %d, 0)", get_systime())
        SQL_SimpleQuery(g_hSQL, szQ)
    }
}

public DB_ErrorHandler(iFailState, Handle:hQuery, szError[], iErrNum, data[], iSize, Float:fQueueTime)
{
    if (iFailState != TQUERY_SUCCESS)
        log_amx("[CSR] DB Error (state=%d err=%d): %s", iFailState, iErrNum, szError)
    else if (get_pcvar_num(g_cvarDebug))
        log_amx("[CSR] DB query OK (handle=%d)", hQuery)
}

DB_AsyncQuery(const szQuery[])
{
    SQL_ThreadQuery(g_hSQLTuple, "DB_ErrorHandler", szQuery)
}

DB_LoadPlayer(id)
{
    if (g_hSQL == Empty_Handle)
    {
        SQL_Init()
        if (g_hSQL == Empty_Handle) return
    }

    get_user_name(id, g_szName[id], charsmax(g_szName[]))

    new szQuery[256]
    formatex(szQuery, charsmax(szQuery),
        "SELECT points,peak_points,maps_played FROM csr_players WHERE steamid='%s' AND season=%d",
        g_szSteamID[id], g_iCurrentSeason)

    new Handle:hQuery = SQL_PrepareQuery(g_hSQL, "%s", szQuery)
    if (hQuery == Empty_Handle) return

    if (SQL_Execute(hQuery))
    {
        if (SQL_NumResults(hQuery) > 0)
        {
            g_iPoints[id]     = SQL_ReadResult(hQuery, 0)
            g_iPeakPoints[id] = SQL_ReadResult(hQuery, 1)
            g_iMapsPlayed[id] = SQL_ReadResult(hQuery, 2)
            g_bInDB[id]       = true
        }
        else
        {
            g_iPoints[id]     = START_POINTS
            g_iPeakPoints[id] = START_POINTS
            g_iMapsPlayed[id] = 0
            g_bInDB[id]       = false
        }
    }
    SQL_FreeHandle(hQuery)

    g_iGlobalPos[id] = GetGlobalPosition(id)
}

DB_UpdateNickname(id)
{
    if (g_hSQL == Empty_Handle || g_szSteamID[id][0] == EOS || is_user_bot(id)) return

    new szSafe[129]
    new j = 0
    for (new i = 0; g_szName[id][i] != EOS && j < charsmax(szSafe) - 1; i++)
    {
        if (g_szName[id][i] == 39) szSafe[j++] = 39
        szSafe[j++] = g_szName[id][i]
    }
    szSafe[j] = EOS

    new szQuery[256]
    formatex(szQuery, charsmax(szQuery),
        "UPDATE csr_players SET name='%s' WHERE steamid='%s'",
        szSafe, g_szSteamID[id])
    DB_AsyncQuery(szQuery)
}

DB_QueueSavePlayer(id)
{
    if (g_hSQL == Empty_Handle)
    {
        SQL_Init()
        if (g_hSQL == Empty_Handle) return
    }

    if (g_iPoints[id] > g_iPeakPoints[id])
        g_iPeakPoints[id] = g_iPoints[id]

    if (is_user_connected(id))
        get_user_name(id, g_szName[id], charsmax(g_szName[]))

    new szSafeName[129]
    new j = 0
    for (new i = 0; g_szName[id][i] != EOS && j < charsmax(szSafeName) - 1; i++)
    {
        if (g_szName[id][i] == 39)
        {
            szSafeName[j++] = 39
            szSafeName[j++] = 39
        }
        else
        {
            szSafeName[j++] = g_szName[id][i]
        }
    }
    szSafeName[j] = EOS

    new szQuery[640]
    if (g_bInDB[id])
    {
        formatex(szQuery, charsmax(szQuery),
            "UPDATE csr_players SET name='%s',points=%d,peak_points=%d,maps_played=%d \
             WHERE steamid='%s' AND season=%d",
            szSafeName, g_iPoints[id], g_iPeakPoints[id], g_iMapsPlayed[id],
            g_szSteamID[id], g_iCurrentSeason)
    }
    else
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO csr_players(steamid,season,name,points,peak_points,maps_played) \
             VALUES('%s',%d,'%s',%d,%d,%d)",
            g_szSteamID[id], g_iCurrentSeason, szSafeName,
            g_iPoints[id], g_iPeakPoints[id], g_iMapsPlayed[id])
        g_bInDB[id] = true
    }
    DB_AsyncQuery(szQuery)
}

DB_SaveAll(iQualPlayers[], iQualNum, bool:bIsParticipant[])
{
    new bool:bSaved[MAX_PLAYERS + 1]

    for (new i = 0; i < iQualNum; i++)
    {
        DB_QueueSavePlayer(iQualPlayers[i])
        bSaved[iQualPlayers[i]] = true
    }
    for (new id = 1; id <= MAX_PLAYERS; id++)
        if (bIsParticipant[id] && !bSaved[id] && g_bInDB[id])
            DB_QueueSavePlayer(id)
}

// Connect/Disconnect stuff
public client_authorized(id)
{
    if (is_user_bot(id))
        get_user_name(id, g_szSteamID[id], charsmax(g_szSteamID[]))
    else
        get_user_authid(id, g_szSteamID[id], charsmax(g_szSteamID[]))

    for (new other = 1; other <= MAX_PLAYERS; other++)
    {
        if (other == id || !equal(g_szSteamID[other], g_szSteamID[id])) continue
        log_amx("[CSR] Duplicate SteamID '%s', clearing ghost slot %d.", g_szSteamID[id], other)
        ResetPlayerMatchData(other)
        g_szSteamID[other][0] = EOS
    }

    ResetPlayerMatchData(id)
    DB_LoadPlayer(id)
    DB_UpdateNickname(id)
    CheckPlayerCount()

    set_task(3.0, "Task_InitHUD", id)
}

public client_disconnected(id)
{
    remove_task(TASK_HUD_BASE + id)
    g_iGlobalPos[id] = -1
    if (!g_bParticipated[id]) ResetPlayerMatchData(id)
    CheckPlayerCount()
}

// HUD stuff
public Task_InitHUD(id)
{
    if (!is_user_connected(id) || is_user_bot(id)) return
    
    client_cmd(id, "hud_centerid 0")
    remove_task(TASK_HUD_BASE + id)

    set_task(0.2, "Task_RefreshHUD", TASK_HUD_BASE + id)
}

public Task_RefreshHUD(id)
{
    new pid = id - TASK_HUD_BASE
    if (!is_user_connected(pid) || is_user_bot(pid)) return

    remove_task(id)
    set_task(1.5, "Task_RefreshHUD", id)

    if (g_iMatchState == STATE_WARMUP)
    {
        new szLine[64]
        formatex(szLine, charsmax(szLine), "%L", pid, "HUD_WARMUP")
        set_dhudmessage(255, 255, 0, -1.0, 0.1, 2, 0.6, 1.8, 0.0, 2.0)
        show_dhudmessage(pid, szLine)
    }
    else if (!is_user_alive(pid))
    {
        new iTarget = get_member(pid, m_hObserverTarget)
        if (iTarget >= 1 && iTarget <= MAX_PLAYERS && is_user_connected(iTarget) && is_user_alive(iTarget))
        {
            new szLine[128]
            if (g_iMapsPlayed[iTarget] < PLACEMENT_MAPS)
            {
                formatex(szLine, charsmax(szLine), "%L", pid, "HUD_WATCH_PLACEMENT")
            }
            else
            {
                formatex(szLine, charsmax(szLine), "%L", pid, "HUD_WATCH_RANKED", RankNames[GetPlayerRank(g_iPoints[iTarget])], g_iPoints[iTarget], GetGlobalPosition(iTarget))
            }
            set_hudmessage(255, 255, 200, -1.0, 0.85, 0, 0.0, 1.8, 0.3, 0.5, 1)
            show_hudmessage(pid, szLine)
        }
    }
}

public hideStatus(id)
{
    if (get_xvar_num(g_PlayerName)) return
    ClearSyncHud(id, g_statussync)
}

public setTeam(id)
{
    g_ifriend[id] = read_data(2)
}

public showStatus(id)
{
    new statsHudMessage = get_xvar_num(g_PlayerName)
    new pid = read_data(2)
    new s_targetname[24]
    new s_RankName[64]
    if(g_iMapsPlayed[pid] < PLACEMENT_MAPS) copy(s_RankName, charsmax(s_RankName), "Rank ??")
    else copy(s_RankName, charsmax(s_RankName), RankNamesShort[GetPlayerRank(g_iPoints[pid])])

    get_user_name(pid, s_targetname, charsmax(s_targetname))

    if(!statsHudMessage)
    {
        if (g_ifriend[id] == 1)
        {
            set_hudmessage(30, 255, 30, -1.0, 0.56, 1, 0.01, 3.0, 0.01, 0.01, -1)
            ShowSyncHudMsg(id, g_statussync, "%s^n[- %s -]", s_targetname, s_RankName)
        }
        else
        {
            set_hudmessage(255, 30, 30, -1.0, 0.56, 1, 0.01, 3.0, 0.01, 0.01, -1)
            ShowSyncHudMsg(id, g_statussync, "%s^n[- %s -]", s_targetname, s_RankName)
        }
    }
}

public HUD_ShowSelf(id)
{
    if (!is_user_connected(id) || is_user_bot(id) || !is_user_alive(id) || g_iMatchState != STATE_LIVE) return
    new szLine[128]

    if (g_iMapsPlayed[id] < PLACEMENT_MAPS)
    {
        formatex(szLine, charsmax(szLine), "%L", id, "HUD_PLACEMENT", g_iCurrentSeason, g_iMapsPlayed[id], PLACEMENT_MAPS)
    }
    else
    {
        new iRank = GetPlayerRank(g_iPoints[id])
        new iNextMMR = (iRank < RANK_COUNT - 1) ? RankThresholds[iRank + 1] : MMR_CAP

        new szPos[12]
        if (g_iGlobalPos[id] > 0) formatex(szPos, charsmax(szPos), "#%d", g_iGlobalPos[id])
        else copy(szPos, charsmax(szPos), "?")

        formatex(szLine, charsmax(szLine), "%L", id, "HUD_RANKED", g_iCurrentSeason, RankNames[iRank], g_iPoints[id], iNextMMR, szPos)
    }

    message_begin(MSG_ONE, get_user_msgid("StatusText"), {0,0,0}, id)
    write_byte(0)
    write_string(szLine)
    message_end()
}

// Chat command /top
public CmdSay(id, level, cid)
{
    new szText[192]
    read_args(szText, charsmax(szText))
    remove_quotes(szText)

    new start = 0
    while (szText[start] == ' ' || szText[start] == ':') start++
    if (szText[start] == '"') start++

    if (equali(szText[start], "!top", 4) || equali(szText[start], "/top", 4))
    {
        new iReqSeason = 0
        new szArg[8]
        new iArgStart = start + 4
        while (szText[iArgStart] == ' ') iArgStart++
        if (szText[iArgStart] != EOS)
        {
            copy(szArg, charsmax(szArg), szText[iArgStart])
            iReqSeason = str_to_num(szArg)
        }
        ShowTopMOTD(id, iReqSeason)
        return PLUGIN_HANDLED
    }

    if (szText[start] == EOS) return PLUGIN_CONTINUE

    new szPrefix[32]
    if (g_iMapsPlayed[id] < PLACEMENT_MAPS || g_hSQL == Empty_Handle)
        copy(szPrefix, charsmax(szPrefix), "??")
    else
        copy(szPrefix, charsmax(szPrefix), RankNamesShort[GetPlayerRank(g_iPoints[id])])

    new szCmd[12]
    read_argv(0, szCmd, charsmax(szCmd))
    new bool:bTeam = bool:equal(szCmd, "say_team")

    new szName[33]
    get_user_name(id, szName, charsmax(szName))

    new szFull[256]
    if (bTeam)
        formatex(szFull, charsmax(szFull), "^x03(TEAM) ^x04[%s] ^x03%s^x01:  %s", szPrefix, szName, szText[start])
    else
        formatex(szFull, charsmax(szFull), "^x04[%s] ^x03%s^x01:  %s", szPrefix, szName, szText[start])

    new players[MAX_PLAYERS], iNum
    get_players(players, iNum, "c")
    for (new i = 0; i < iNum; i++)
    {
        new viewer = players[i]
        if (bTeam)
        {
            new iViewerTeam = get_user_team(viewer)
            new iSenderTeam = get_user_team(id)
            new bool:bViewerDead = !is_user_alive(viewer)
            if (iViewerTeam != iSenderTeam && !bViewerDead) continue
        }

        message_begin(MSG_ONE_UNRELIABLE, g_iMsgSayText, _, viewer)
        write_byte(id)
        write_string(szFull)
        message_end()
    }

    server_print("%s:  %s", szName, szText[start])

    return PLUGIN_HANDLED
}

UnixToDate(iTimestamp, szOut[], iOutLen)
{
    new iDays   = iTimestamp / 86400
    new iZ      = iDays + 719468
    new iEra    = (iZ >= 0 ? iZ : iZ - 146096) / 146097
    new iDoe    = iZ - iEra * 146097
    new iYoe    = (iDoe - iDoe/1460 + iDoe/36524 - iDoe/146096) / 365
    new iY      = iYoe + iEra * 400
    new iDoy    = iDoe - (365*iYoe + iYoe/4 - iYoe/100)
    new iMp     = (5*iDoy + 2) / 153
    new iDay    = iDoy - (153*iMp + 2)/5 + 1
    new iMonth  = iMp + (iMp < 10 ? 3 : -9)
    if (iMonth <= 2) iY++
    formatex(szOut, iOutLen, "%02d.%02d.%d", iDay, iMonth, iY)
}

FormatSeasonHeader(iSeason, szOut[], iOutLen)
{
    new szLabel[64]
    new iStarted, iEnded

    new szQ[128]
    formatex(szQ, charsmax(szQ),
        "SELECT label,started_at,ended_at FROM csr_seasons WHERE season=%d", iSeason)
    new Handle:h = SQL_PrepareQuery(g_hSQL, "%s", szQ)
    if (h != Empty_Handle && SQL_Execute(h) && SQL_MoreResults(h))
    {
        SQL_ReadResult(h, 0, szLabel, charsmax(szLabel))
        iStarted = SQL_ReadResult(h, 1)
        iEnded   = SQL_ReadResult(h, 2)
    }
    else
        formatex(szLabel, charsmax(szLabel), "Season %d", iSeason)
    if (h != Empty_Handle) SQL_FreeHandle(h)

    new szStart[16], szEnd[16]
    if (iStarted > 0)
        UnixToDate(iStarted, szStart, charsmax(szStart))
    if (iEnded > 0)
        UnixToDate(iEnded, szEnd, charsmax(szEnd))

    if (iStarted > 0 && iEnded > 0)
        formatex(szOut, iOutLen, "%s: %s - %s", szLabel, szStart, szEnd)
    else if (iStarted > 0)
        formatex(szOut, iOutLen, "%s: %s - active", szLabel, szStart)
    else
        copy(szOut, iOutLen, szLabel)
}

BuildSeasonHTML(iSeason, szOut[], iOutLen, iLimit = 10)
{
    if (g_hSQL == Empty_Handle)
    {
        SQL_Init()
        if (g_hSQL == Empty_Handle) return
    }

    static szTmp[512]
    static szRows[30][256]
    new iTotal = 0
    new bool:bHasRows = false

    new szQ[256]
    formatex(szQ, charsmax(szQ),
        "SELECT name,steamid,points FROM csr_players WHERE maps_played>=%d AND season=%d ORDER BY points DESC LIMIT %d",
        PLACEMENT_MAPS, iSeason, iLimit)

    new Handle:hTop = SQL_PrepareQuery(g_hSQL, "%s", szQ)
    if (hTop != Empty_Handle && SQL_Execute(hTop))
    {
        new iRow = 1
        while (SQL_MoreResults(hTop) && iRow <= iLimit)
        {
            new szName[64], szSteam[35], iPoints
            SQL_ReadResult(hTop, 0, szName,  charsmax(szName))
            SQL_ReadResult(hTop, 1, szSteam, charsmax(szSteam))
            iPoints = SQL_ReadResult(hTop, 2)

            new szDisplay[64]
            copy(szDisplay, charsmax(szDisplay), (szName[0] != EOS) ? szName : szSteam)

            new szPos[32]
            switch (iRow)
            {
                case 1:  formatex(szPos, charsmax(szPos), "<td class='p g'>&#9733;</td>")
                case 2:  formatex(szPos, charsmax(szPos), "<td class='p s'>&#9733;</td>")
                case 3:  formatex(szPos, charsmax(szPos), "<td class='p b'>&#9733;</td>")
                default: formatex(szPos, charsmax(szPos), "<td class='p'>%d</td>", iRow)
            }

            formatex(szRows[iTotal], charsmax(szRows[]), "<tr>%s<td>%s</td><td>%s</td><td class='m'>%d</td></tr>",
                szPos, szDisplay, RankNames[GetPlayerRank(iPoints)], iPoints)

            bHasRows = true
            iTotal++
            iRow++
            SQL_NextRow(hTop)
        }
        SQL_FreeHandle(hTop)
    }

    new szLabel[128]
    FormatSeasonHeader(iSeason, szLabel, charsmax(szLabel))

    static szHTML[16384]
    szHTML[0] = EOS

    add(szHTML, charsmax(szHTML), "<style>*{margin:0;padding:0}body{background:#111;color:#ccc;font:12px Arial}.w{display:flex;gap:4px;padding:4px}.col{flex:1;min-width:0}table{width:100%;border-collapse:collapse}th{background:#181818;color:#f4a800;padding:3px 5px;text-align:left;font-size:11px;border-bottom:1px solid #333}td{padding:3px 5px;border-bottom:1px solid #181818}.p{width:18px;text-align:center;font-weight:bold}.g{color:#FFD700}.s{color:#C0C0C0}.b{color:#CD7F32}.m{color:#f4a800;font-weight:bold}.nil{color:#555;text-align:center;padding:10px;font-style:italic}.hd{background:#181818;color:#f4a800;padding:4px 8px;font:bold 12px Arial;border-bottom:2px solid #333}</style>")
    formatex(szTmp, charsmax(szTmp), "<div class='hd'>%s</div><div class='w'>", szLabel)
    add(szHTML, charsmax(szHTML), szTmp)

    if (!bHasRows)
    {
        add(szHTML, charsmax(szHTML), "<div class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
        add(szHTML, charsmax(szHTML), "<tr><td colspan='4' class='nil'>No data...</td></tr>")
        add(szHTML, charsmax(szHTML), "</tbody></table></div>")
    }
    else
    {
        add(szHTML, charsmax(szHTML), "<div class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
        for (new r = 0; r < 15 && r < iTotal; r++)
            add(szHTML, charsmax(szHTML), szRows[r])
        add(szHTML, charsmax(szHTML), "</tbody></table></div>")

        if (iTotal > 15)
        {
            add(szHTML, charsmax(szHTML), "<div class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
            for (new r = 15; r < iTotal; r++)
                add(szHTML, charsmax(szHTML), szRows[r])
            add(szHTML, charsmax(szHTML), "</tbody></table></div>")
        }
    }

    add(szHTML, charsmax(szHTML), "</div>")
    copy(szOut, iOutLen, szHTML)
}

BuildTopHTML()
{
    if (g_hSQL == Empty_Handle)
    {
        SQL_Init()
        if (g_hSQL == Empty_Handle) return
    }

    static szHTML[16384]
    static szTmp[512]
    szHTML[0] = EOS

    new szLabel[128]
    FormatSeasonHeader(g_iCurrentSeason, szLabel, charsmax(szLabel))

    _H("<style>*{margin:0;padding:0}body{background:#111;color:#ccc;font:12px Arial}.w{display:flex;gap:4px;padding:4px}.col{flex:1;min-width:0}table{width:100%;border-collapse:collapse}th{background:#181818;color:#f4a800;padding:3px 5px;text-align:left;font-size:11px;border-bottom:1px solid #333}td{padding:3px 5px;border-bottom:1px solid #181818}.p{width:18px;text-align:center;font-weight:bold}.g{color:#FFD700}.s{color:#C0C0C0}.b{color:#CD7F32}.m{color:#f4a800;font-weight:bold}.nil{color:#555;text-align:center;padding:10px;font-style:italic}.hd{background:#181818;color:#f4a800;padding:4px 8px;font:bold 12px Arial;border-bottom:2px solid #333}</style>")
    formatex(szTmp, charsmax(szTmp), "<div class='hd'>%s</div><div class='w'>", szLabel)
    _H(szTmp)

    new szQ[256]
    formatex(szQ, charsmax(szQ),
        "SELECT name,steamid,points FROM csr_players WHERE maps_played>=%d AND season=%d ORDER BY points DESC LIMIT 30",
        PLACEMENT_MAPS, g_iCurrentSeason)

    new Handle:hTop = SQL_PrepareQuery(g_hSQL, "%s", szQ)
    new bool:bHasRows = false
    static szRows[30][256]
    new iTotal = 0

    if (hTop != Empty_Handle && SQL_Execute(hTop))
    {
        new iRow = 1
        while (SQL_MoreResults(hTop) && iRow <= 30)
        {
            new szName[64], szSteam[35], iPoints
            SQL_ReadResult(hTop, 0, szName,  charsmax(szName))
            SQL_ReadResult(hTop, 1, szSteam, charsmax(szSteam))
            iPoints = SQL_ReadResult(hTop, 2)

            new szDisplay[64]
            copy(szDisplay, charsmax(szDisplay), (szName[0] != EOS) ? szName : szSteam)

            new szPos[32]
            switch (iRow)
            {
                case 1:  formatex(szPos, charsmax(szPos), "<td class='p g'>&#9733;</td>")
                case 2:  formatex(szPos, charsmax(szPos), "<td class='p s'>&#9733;</td>")
                case 3:  formatex(szPos, charsmax(szPos), "<td class='p b'>&#9733;</td>")
                default: formatex(szPos, charsmax(szPos), "<td class='p'>%d</td>", iRow)
            }

            formatex(szRows[iTotal], charsmax(szRows[]), "<tr>%s<td>%s</td><td>%s</td><td class='m'>%d</td></tr>",
                szPos, szDisplay, RankNames[GetPlayerRank(iPoints)], iPoints)

            bHasRows = true
            iTotal++
            iRow++
            SQL_NextRow(hTop)
        }
        SQL_FreeHandle(hTop)
    }

    if (!bHasRows)
    {
        _H("<div class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
        _H("<tr><td colspan='4' class='nil'>Waiting for data...</td></tr>")
        _H("</tbody></table></div>")
    }
    else
    {
        _H("<div class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
        for (new r = 0; r < 15 && r < iTotal; r++)
            _H(szRows[r])
        _H("</tbody></table></div>")

        if (iTotal > 15)
        {
            _H("<div class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
            for (new r = 15; r < iTotal; r++)
                _H(szRows[r])
            _H("</tbody></table></div>")
        }
    }

    _H("</div>")

    copy(g_szTopHTML, charsmax(g_szTopHTML), szHTML)
}

public Task_BuildTopHTML()
{
    BuildTopHTML()
}

ShowTopMOTD(id, iReqSeason)
{
    new szTitle[64]

    if (iReqSeason > 0 && iReqSeason != g_iCurrentSeason)
    {
        new szChkQ[96]
        formatex(szChkQ, charsmax(szChkQ), "SELECT season FROM csr_seasons WHERE season=%d", iReqSeason)
        new Handle:hChk = SQL_PrepareQuery(g_hSQL, "%s", szChkQ)
        new bool:bExists = (hChk != Empty_Handle && SQL_Execute(hChk) && SQL_MoreResults(hChk))
        if (hChk != Empty_Handle) SQL_FreeHandle(hChk)

        if (!bExists)
        {
            client_print_color(id, print_team_default, "%l", LANG_PLAYER, "RANK_WRONG_SEASON", iReqSeason)
            return
        }

        formatex(szTitle, charsmax(szTitle), "Ranked season %d", iReqSeason)

        if (g_bKarLibLoaded)
        {
            new szServerIP[32]
            get_cvar_string("net_address", szServerIP, charsmax(szServerIP))
            new iColon = contain(szServerIP, ":")
            if (iColon != -1) szServerIP[iColon] = EOS

            new iPort = get_pcvar_num(g_cvarKarPort)
            new szMotd[512]
            formatex(szMotd, charsmax(szMotd),
                "<style>*{margin:0;padding:0}body,html{height:100%%}iframe{width:100%%;height:100%%;border:none}</style><iframe src='http://%s:%d/csr_top?season=%d'></iframe>",
                szServerIP, iPort, iReqSeason)
            show_motd(id, szMotd, szTitle)
        }
        return
    }

    if (g_szTopHTML[0] == EOS) BuildTopHTML()
    if (g_szTopHTML[0] == EOS) return

    formatex(szTitle, charsmax(szTitle), "Ranked season %d", g_iCurrentSeason)

    new szServerIP[32]
    get_cvar_string("net_address", szServerIP, charsmax(szServerIP))
    new iColon = contain(szServerIP, ":")
    if (iColon != -1) szServerIP[iColon] = EOS

    new iPort = get_pcvar_num(g_cvarKarPort)
    new szMotd[512]
    formatex(szMotd, charsmax(szMotd),
        "<style>*{margin:0;padding:0}body,html{height:100%%}iframe{width:100%%;height:100%%;border:none}</style><iframe src='http://%s:%d/csr_top'></iframe>",
        szServerIP, iPort)
    show_motd(id, szMotd, szTitle)
}
// ROUND EVENTS
public OnNewRound()
{
    CheckPlayerCount()

    if (g_iMatchState == STATE_STARTING)
    {
        ResetMapData()
        SetMatchState(STATE_LIVE)
        return
    }

    if (g_iMatchState != STATE_LIVE && g_iMatchState != STATE_CANCELLED) return

    g_iTotalRounds++

    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        g_iKillStreak[id]       = 0
        g_iRoundDmgDealt[id]    = 0
        g_iRoundScoreEarned[id] = 0

        if (g_bParticipated[id] && g_szSteamID[id][0] != EOS) g_iRoundsInMatch[id]++
    }
}

public OnPlayerSpawn(id)
{
    if (!is_user_connected(id) || g_szSteamID[id][0] == EOS)
        return HC_CONTINUE

    if (g_iMatchState == STATE_WARMUP || g_iMatchState == STATE_WAITING)
    {
        set_task(1.0, "Task_RefreshHUD", TASK_HUD_BASE + id)
        return HC_CONTINUE
    }

    if (g_iMatchState != STATE_LIVE && g_iMatchState != STATE_CANCELLED)
        return HC_CONTINUE

    g_iRoundsPresent[id]++
    g_iPlayerTeam[id] = get_member(id, m_iTeam)
    g_bParticipated[id] = true
    g_iDmgToVictim[id] = 0

    return HC_CONTINUE
}

public OnRoundEnd(status, event, Float:tmDelay)
{
    if (g_iMatchState != STATE_LIVE && g_iMatchState != STATE_CANCELLED)
        return HC_CONTINUE

    new mapname[32]
    get_mapname(mapname, charsmax(mapname))

    if (equali(mapname, "gg_", 3))
        return HC_CONTINUE

    if (status == 1) g_iTeamRounds[1]++
    else if (status == 2) g_iTeamRounds[2]++

    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        if (!g_bParticipated[id]) continue

        if (status != 0 && g_iMatchState == STATE_LIVE)
        {
            if (g_iPlayerTeam[id] == status) AddScore(id, SCORE_ROUND_WIN)
            else AddScore(id, SCORE_ROUND_LOST)
        }
    }

    return HC_CONTINUE
}

public AddScore(id, iAmount)
{
    if (g_iMatchState != STATE_LIVE) return

    if (iAmount > 0)
    {
        new iRoom = get_pcvar_num(g_cvarScoreCap) - g_iRoundScoreEarned[id]
        if (iRoom <= 0) return
        if (iAmount > iRoom) iAmount = iRoom
        g_iRoundScoreEarned[id] += iAmount
    }
    g_iMatchScore[id] += iAmount
}

// DAMAGE & KILLS
public OnTakeDamage(victim, inflictor, attacker, Float:fDamage, damagetype)
{
    if (g_iMatchState != STATE_LIVE) return HC_CONTINUE
    if (attacker < 1 || attacker > MAX_PLAYERS) return HC_CONTINUE
    if (attacker == victim) return HC_CONTINUE
    if (!g_bParticipated[attacker]) return HC_CONTINUE
    if (get_member(attacker, m_iTeam) == get_member(victim, m_iTeam)) return HC_CONTINUE

    new iDmg = floatround(fDamage)
    new iHP = get_user_health(victim)
    if (iDmg > iHP) iDmg = iHP
    if (iDmg <= 0) return HC_CONTINUE

    new iRoom = get_pcvar_num(g_cvarDmgCap) - g_iRoundDmgDealt[attacker]
    if (iRoom <= 0) return HC_CONTINUE
    if (iDmg > iRoom) iDmg = iRoom

    g_iRoundDmgDealt[attacker] += iDmg
    g_iDmgToVictim[attacker] += iDmg

    g_iDmgBuffer[attacker] += iDmg
    new iEarned = g_iDmgBuffer[attacker] / SCORE_DMG_PER_POINT
    if (iEarned > 0)
    {
        AddScore(attacker, iEarned)
        g_iDmgBuffer[attacker] -= iEarned * SCORE_DMG_PER_POINT
    }

    return HC_CONTINUE
}

public OnPlayerKilled(victim, killer, shouldgib)
{
    if (g_bParticipated[victim])
    {
        new bool:bPvP = (killer >= 1 && killer <= MAX_PLAYERS && killer != victim)
        if (bPvP) g_iMatchScore[victim] += SCORE_DEATH
        g_iMapDeaths[victim]++
    }

    if (killer < 1 || killer > MAX_PLAYERS) return HC_CONTINUE
    if (killer == victim)                    return HC_CONTINUE
    if (!g_bParticipated[killer])            return HC_CONTINUE
    if (g_iMatchState != STATE_LIVE)         return HC_CONTINUE
    if (get_member(killer, m_iTeam) == get_member(victim, m_iTeam))
    {
        g_iDmgToVictim[killer] = 0
        if(get_cvar_num("mp_friendlyfire") == 1) AddScore(killer, SCORE_TEAMKILL)
        return HC_CONTINUE
    }

    g_iMapKills[killer]++

    new szClass[32]
    new iWpnEnt = get_member(killer, m_pActiveItem)
    if (iWpnEnt > 0) pev(iWpnEnt, pev_classname, szClass, charsmax(szClass))
    else copy(szClass, charsmax(szClass), "weapon_knife")

    new iWpnClass = GetWeaponClass(szClass)

    if (get_member(victim, m_LastHitGroup) == HIT_HEAD
        || iWpnClass == WC_KNIFE
        || iWpnClass == WC_NADE
        || iWpnClass == WC_PISTOL)
        AddScore(killer, SCORE_KILL_BONUS)

    if (IsBadWeapon(szClass) && g_iDmgToVictim[killer] >= BAD_WEAPON_MIN_DMG)
        AddScore(killer, SCORE_BAD_WEAPON)

    g_iKillStreak[killer]++
    if (g_iKillStreak[killer] >= 2 && g_iKillStreak[killer] <= MAX_KILLSTREAK)
        AddScore(killer, 1)

    if (LongshotDist[iWpnClass] > 0)
    {
        new Float:vK[3], Float:vV[3]
        pev(killer, pev_origin, vK)
        pev(victim, pev_origin, vV)
        if (vector_distance(vK, vV) >= float(LongshotDist[iWpnClass]))
            AddScore(killer, SCORE_LONGSHOT)
    }

    g_iDmgToVictim[killer] = 0
    g_iDmgToVictim[victim] = 0

    if (get_pcvar_num(g_cvarDebug)) client_print(killer, print_console, "[CSR] Score:%d Streak:%d RoundScore:%d/%d", g_iMatchScore[killer], g_iKillStreak[killer], g_iRoundScoreEarned[killer], get_pcvar_num(g_cvarScoreCap))

    return HC_CONTINUE
}

public OnBombPlanted(planter)
{
    if (g_iMatchState != STATE_LIVE) return HC_CONTINUE
    if (!g_bParticipated[planter]) return HC_CONTINUE
    AddScore(planter, SCORE_PLANT)
    return HC_CONTINUE
}

public OnBombDefused(defuser)
{
    if (g_iMatchState != STATE_LIVE) return HC_CONTINUE
    if (!g_bParticipated[defuser]) return HC_CONTINUE
    AddScore(defuser, SCORE_DEFUSE)
    return HC_CONTINUE
}

public OnMapEnd()
{
    new iPrevState = g_iMatchState
    if (iPrevState == STATE_WAITING || iPrevState == STATE_ENDED) return
    // Detect map end via win conditions
    new iWinLimit  = get_cvar_num("mp_winlimit")
    new iMaxRounds = get_cvar_num("mp_maxrounds")
    new iTimeLimit = get_cvar_num("mp_timelimit")
    new bool:bWinLimitHit  = (iWinLimit  > 0 && (g_iTeamRounds[1] >= iWinLimit  || g_iTeamRounds[2] >= iWinLimit))
    new bool:bMaxRoundsHit = (iMaxRounds > 0 && (g_iTeamRounds[1] + g_iTeamRounds[2]) >= iMaxRounds)
    new bool:bTimeLimitHit = (iTimeLimit > 0 && get_timeleft() <= 0)
    if (bWinLimitHit || bMaxRoundsHit || bTimeLimitHit | g_forcedwin == true)
    {
        SetMatchState(STATE_ENDED)
        remove_task(TASK_MAP_END)
        set_task(2.0, "Task_MapEnd", TASK_MAP_END)
    }
    else SetMatchState(STATE_CANCELLED)
    if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] OnMapEnd called. State=%d Rounds=%d — results in 2s", iPrevState, g_iTotalRounds)
}

public Task_MapEnd()
{
    new iPrevState = g_iMatchState

    if (g_iTotalRounds <= 0 || iPrevState == STATE_WARMUP || iPrevState == STATE_STARTING || iPrevState == STATE_WAITING)
    {
        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Map end ignored: rounds=%d, prevstate=%d", g_iTotalRounds, iPrevState)
        ResetMapData()
        return
    }

    // K/D bonus
    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        if (!g_bParticipated[id]) continue
        if (g_iMapKills[id] > g_iMapDeaths[id]*2 && g_iMapDeaths[id] > 0)
            g_iMatchScore[id] += SCORE_POSITIVE_KD*2
        else if (g_iMapKills[id] > g_iMapDeaths[id] && g_iMapDeaths[id] > 0)
            g_iMatchScore[id] += SCORE_POSITIVE_KD
        else if (g_iMapKills[id] < g_iMapDeaths[id] && g_iMapKills[id] > 0)
            g_iMatchScore[id] += SCORE_NEGATIVE_KD
    }

    new bool:bIsParticipant[MAX_PLAYERS + 1]
    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        if (!g_bParticipated[id] || g_szSteamID[id][0] == EOS)
            continue
        
        bIsParticipant[id] = true
    }

    new Float:fAvgScore[MAX_PLAYERS + 1]
    new Float:fParticipation[MAX_PLAYERS + 1]
    new iQualPlayers[MAX_PLAYERS]
    new iQualNum = 0
    new iMinRounds = g_forcedwin == true ? 1 : get_pcvar_num(g_cvarMinRounds)

    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        if (!bIsParticipant[id] || g_iRoundsPresent[id] < iMinRounds || g_iRoundsPresent[id] <= 0) continue

        new iInMatch = max(g_iRoundsInMatch[id], g_iRoundsPresent[id])
        if (iInMatch > 0) fParticipation[id] = float(g_iRoundsPresent[id]) / float(iInMatch)
        else fParticipation[id] = float(g_iRoundsPresent[id])
        if (fParticipation[id] > 1.0) fParticipation[id] = 1.0

        fAvgScore[id] = float(g_iMatchScore[id]) / float(g_iRoundsPresent[id])
        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Qual: %s Rounds=%d Score=%d RawAvg=%.2f", g_szSteamID[id], g_iRoundsPresent[id], g_iMatchScore[id], fAvgScore[id])

        // Presence bonus/penalty
        new Float:fPrs = fParticipation[id]
        new Float:fPresenceBonus
        if      (fPrs < 0.50) fPresenceBonus = -1.0
        else if (fPrs < 0.65) fPresenceBonus = -0.5
        else if (fPrs < 0.80) fPresenceBonus =  0.0
        else if (fPrs < 0.90) fPresenceBonus =  0.5
        else                  fPresenceBonus =  1.0
        fAvgScore[id] += fPresenceBonus

        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] %s Presence=%.0f%% PresenceBonus=%.1f AdjAvg=%.2f", g_szSteamID[id], fPrs * 100.0, fPresenceBonus, fAvgScore[id])

        iQualPlayers[iQualNum++] = id
    }

    new iMinPlayers = get_pcvar_num(g_cvarMinPlayers)
    new iIdealPlayers = get_pcvar_num(g_cvarIdealPlayers)
    if (iQualNum < iMinPlayers || iQualNum <= 1)
    {
        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Not enough: %d<%d MinRounds=%d", iQualNum, iMinPlayers, iMinRounds)
        client_print_color(0, print_team_default, "%L", LANG_PLAYER, "RANK_NOT_ENOUGH", iQualNum, iMinPlayers)
        DB_SaveAll(iQualPlayers, 0, bIsParticipant)
        ResetMapData()
        return
    }

    // Sort qualifiers
    for (new i = 1; i < iQualNum; i++)
    {
        new key = iQualPlayers[i]
        new j   = i - 1
        while (j >= 0 && fAvgScore[iQualPlayers[j]] < fAvgScore[key])
        {
            iQualPlayers[j + 1] = iQualPlayers[j]
            j--
        }
        iQualPlayers[j + 1] = key
    }

    // Assign finish positions
    new iOutcome[MAX_PLAYERS + 1]
    new iPos = 1
    for (new i = 0; i < iQualNum; i++)
    {
        new id = iQualPlayers[i]
        if (i > 0 && fAvgScore[id] != fAvgScore[iQualPlayers[i - 1]])
            iPos = i + 1
        iOutcome[id] = iPos
    }

    // Refresh player MMR from DB before calculation
    for (new i = 0; i < iQualNum; i++)
        DB_LoadPlayer(iQualPlayers[i])

    // Calculate new MMR for each qualifier
    new iNewPoints[MAX_PLAYERS + 1]
    for (new i = 0; i < iQualNum; i++)
    {
        new id = iQualPlayers[i]
        new iMyRank = GetPlayerRank(g_iPoints[id])
        new bool:bPlace = (g_iMapsPlayed[id] < PLACEMENT_MAPS)

        new Float:fTotal = 0.0
        // 1v1
        for (new j = 0; j < iQualNum; j++)
        {
            new opp = iQualPlayers[j]
            if (opp == id || iOutcome[id] == iOutcome[opp]) continue

            new iOppRank  = GetPlayerRank(g_iPoints[opp])
            new iRankDiff = abs(iMyRank - iOppRank)
            if (iRankDiff > 10) iRankDiff = 10

            new iBattle
            if (iOutcome[id] < iOutcome[opp])
                iBattle = (iMyRank >= iOppRank) ? WorseWin[iRankDiff]   : BetterWin[iRankDiff]
            else
                iBattle = (iMyRank >= iOppRank) ? BetterLose[iRankDiff] : WorseLose[iRankDiff]

            fTotal += float(iBattle)
        }

        if (iQualNum > 1) fTotal /= float(iQualNum - 1)
        if (bPlace)       fTotal *= 2.0
        fTotal *= fParticipation[id]
        if(iQualNum < iIdealPlayers) fTotal *= (float(iQualNum) / float(iIdealPlayers))

        new iChange = floatround(fTotal, floatround_floor)
        if (iChange > 0 && get_pcvar_num(g_cvarDoubleGain) == 1)
            iChange *= 2
        if (!bPlace && iChange < 0)
        {
            new iShield = (iMyRank < RANK_COUNT) ? ShieldLossPct[iMyRank] : 100
            iChange = (iChange * iShield) / 100
        }
        if(bPlace)
        {
            if(iChange < MMR_MAX_LOSE*2) iChange = MMR_MAX_LOSE*2
            if(iChange > MMR_MAX_GAIN*2) iChange = MMR_MAX_GAIN*2
        }
        else
        {
            if(iChange < MMR_MAX_LOSE) iChange = MMR_MAX_LOSE
            if(iChange > MMR_MAX_GAIN) iChange = MMR_MAX_GAIN
        }
        iNewPoints[id] = clamp(g_iPoints[id] + iChange, g_iPeakPoints[id] / 2, MMR_CAP)
    }

    // Apply results and build MOTD
    static szHTML[16384]
    static szTmp[256]
    szHTML[0] = EOS


    _H("<!DOCTYPE html><html><head><meta charset='utf-8'><style>")
    _H("*{box-sizing:border-box;margin:0;padding:0}")
    _H("body{background:#0d0d0d;color:#ccc;font-family:Arial,sans-serif;font-size:13px}")
    _H("table{width:100%;border-collapse:collapse}")
    _H("th{background:#181818;color:#f4a800;padding:5px 8px;text-align:left;font-size:11px;border-bottom:1px solid #333}")
    _H("td{padding:5px 8px;border-bottom:1px solid #181818}")
    _H("tr:hover td{background:#141414}")
    _H(".pos{width:28px;text-align:center;font-weight:bold}")
    _H(".g{color:#FFD700}.s{color:#C0C0C0}.b{color:#CD7F32}")
    _H(".MMR{color:#f4a800;font-weight:bold}.rk{color:#7ec8e3;font-size:11px}")
    _H(".up{color:#4caf50;font-weight:bold}.dn{color:#f44336;font-weight:bold}.ru{color:#80e27e;font-size:10px;font-weight:normal}.rd{color:#ff7961;font-size:10px;font-weight:normal}")
    _H(".pl{color:#888;font-style:italic}")
    _H("</style></head><body>")
    _H("<table><thead><tr>")
    _H("<th class='pos'>#</th><th>NICK</th><th class='rk'>RANK</th><th>MMR</th><th>CHANGE</th><th>MATCH SCORE</th><th>PRESENCE</th>")
    _H("</tr></thead><tbody>")

    for (new i = 0; i < iQualNum; i++)
    {
        new id       = iQualPlayers[i]
            new iOld     = g_iPoints[id]
            new iNew     = iNewPoints[id]
            new iNewRank = GetPlayerRank(iNew)
            new iDiff    = iNew - iOld
            new bool:bPlacement = (g_iMapsPlayed[id] < PLACEMENT_MAPS-1)

            g_iPoints[id] = iNew
            g_iMapsPlayed[id]++

            new szName[16]
            if (is_user_connected(id)) get_user_name(id, szName, charsmax(szName))
            else if (g_szName[id][0] != EOS) copy(szName, charsmax(szName), g_szName[id])
            else copy(szName, charsmax(szName), g_szSteamID[id])

            new szPosCell[48]
            switch (iOutcome[id])
            {
                case 1:  formatex(szPosCell, charsmax(szPosCell), "<td class='pos g'>&#9733;</td>")
                case 2:  formatex(szPosCell, charsmax(szPosCell), "<td class='pos s'>&#9733;</td>")
                case 3:  formatex(szPosCell, charsmax(szPosCell), "<td class='pos b'>&#9733;</td>")
                default: formatex(szPosCell, charsmax(szPosCell), "<td class='pos'>%d</td>", iOutcome[id])
            }

            new iOldRank = GetPlayerRank(iOld)
            new szDiffCell[96]
            if (bPlacement)
            {
                formatex(szDiffCell, charsmax(szDiffCell), "<td class='pl'>Placement %d/%d</td>", g_iMapsPlayed[id], PLACEMENT_MAPS)
            }
            else if (iNewRank > iOldRank)
            {
                formatex(szDiffCell, charsmax(szDiffCell), "<td class='up'>+%d <span class='ru'>&#8679; +RANK</span></td>", iDiff)
            }
            else if (iNewRank < iOldRank)
            {
                formatex(szDiffCell, charsmax(szDiffCell), "<td class='dn'>%d <span class='rd'>&#8681; -RANK</span></td>", iDiff)
            }
            else if (iDiff > 0)
                formatex(szDiffCell, charsmax(szDiffCell), "<td class='up'>+%d</td>", iDiff)
            else if (iDiff < 0)
                formatex(szDiffCell, charsmax(szDiffCell), "<td class='dn'>%d</td>", iDiff)
            else
                formatex(szDiffCell, charsmax(szDiffCell), "<td>--</td>")

            if (bPlacement)
                formatex(szTmp, charsmax(szTmp),
                    "<tr>%s<td>%s</td><td class='rk pl'>??</td><td class='pl'>??</td>%s<td>%.2f</td><td>%.0f%%</td></tr>",
                    szPosCell, szName, szDiffCell, fAvgScore[id], fParticipation[id] * 100.0)
            else
                formatex(szTmp, charsmax(szTmp),
                    "<tr>%s<td>%s</td><td class='rk'>%s</td><td class='MMR'>%d</td>%s<td>%.2f</td><td>%.0f%%</td></tr>",
                    szPosCell, szName, RankNames[iNewRank], iNew,
                    szDiffCell, fAvgScore[id], fParticipation[id] * 100.0)
            _H(szTmp)
        }

    _H("</tbody></table></body></html>")

    copy(g_szResultsHTML, charsmax(g_szResultsHTML), szHTML)

    new szServerIP[32]
    get_cvar_string("net_address", szServerIP, charsmax(szServerIP))
    new iAddrColon = contain(szServerIP, ":")
    if (iAddrColon != -1) szServerIP[iAddrColon] = EOS

    new iPort = get_pcvar_num(g_cvarKarPort)
    new szMotd[512]
    formatex(szMotd, charsmax(szMotd),
        "<style>*{margin:0;padding:0}body,html{height:100%%}iframe{width:100%%;height:100%%;border:none}</style><iframe src='http://%s:%d/csr_results'></iframe>",
        szServerIP, iPort)

    new players[MAX_PLAYERS], iNum
    get_players(players, iNum, "c")
    for (new i = 0; i < iNum; i++)
    {
        new viewer = players[i]
        if (is_user_bot(viewer)) continue
        message_begin(MSG_ONE, SVC_FINALE, _, viewer)
        write_string("")
        message_end()
        show_motd(viewer, szMotd, "Ranked Match Results")
    }

    DB_SaveAll(iQualPlayers, iQualNum, bIsParticipant)

    // Refresh cached leaderboard positions
    for (new i = 0; i < iQualNum; i++)
        if (is_user_connected(iQualPlayers[i]))
            g_iGlobalPos[iQualPlayers[i]] = GetGlobalPosition(iQualPlayers[i])

    ResetMapData()
}

// ADMIN COMMANDS
public CmdRankAdjust(id, level, cid)
{
    if (!cmd_access(id, level, cid, 3)) return PLUGIN_HANDLED

    new szSteamID[35], szAmount[16]
    read_argv(1, szSteamID, charsmax(szSteamID))
    read_argv(2, szAmount,  charsmax(szAmount))

    new iAmount = str_to_num(szAmount)

    new players[MAX_PLAYERS], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum; i++)
    {
        if (!equal(g_szSteamID[players[i]], szSteamID)) continue

        new pid = players[i]
        g_iPoints[pid] = clamp(g_iPoints[pid] + iAmount, 0, MMR_CAP)
        DB_QueueSavePlayer(pid)
        console_print(id, "[CSR] Adjusted %s by %d. New MMR: %d", szSteamID, iAmount, g_iPoints[pid])
        log_amx("[CSR] Admin %n adjusted %s by %d MMR", id, szSteamID, iAmount)
        return PLUGIN_HANDLED
    }

    new szQ[256]
    formatex(szQ, charsmax(szQ),
        "UPDATE csr_players SET points=MAX(0,MIN(%d,points+(%d))) \
         WHERE steamid='%s' AND season=%d",
        MMR_CAP, iAmount, szSteamID, g_iCurrentSeason)
    DB_AsyncQuery(szQ)
    console_print(id, "[CSR] Queued DB adjustment of %d for %s", iAmount, szSteamID)
    log_amx("[CSR] Admin %n adjusted %s by %d MMR", id, szSteamID, iAmount)
    return PLUGIN_HANDLED
}

public CmdRankRecalc(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED
    console_print(id, "[CSR] Forcing map-end calculation...")
    client_print_color(0, print_team_default, "%L", LANG_PLAYER, "ADMIN_FORCE_RECALC")
    OnMapEnd()
    return PLUGIN_HANDLED
}

public CmdRankCancel(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED
    SetMatchState(STATE_CANCELLED)
    console_print(id, "[CSR] Match manually cancelled.")
    log_amx("[CSR] Admin %n manually cancelled the match.", id)
    return PLUGIN_HANDLED
}

public CmdRankStatus(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED

    new const szStateNames[][] = { "WAITING","WARMUP","STARTING","LIVE","CANCELLED","ENDED" }
    console_print(id, "[CSR] State:%s Rounds:%d CT:%d T:%d",
        szStateNames[g_iMatchState], g_iTotalRounds, g_iTeamRounds[1], g_iTeamRounds[2])

    new players[MAX_PLAYERS], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum; i++)
    {
        new pid = players[i]
        if (is_user_bot(pid)) continue
        new szName[64]
        get_user_name(pid, szName, charsmax(szName))
        new Float:fAvg = (g_iRoundsPresent[pid] > 0)
            ? float(g_iMatchScore[pid]) / float(g_iRoundsPresent[pid]) : 0.0
        console_print(id, "  %s [%s] Score:%d Avg:%.2f Played:%d/InMatch:%d K/D:%d/%d",
            szName, g_szSteamID[pid], g_iMatchScore[pid], fAvg,
            g_iRoundsPresent[pid], g_iRoundsInMatch[pid],
            g_iMapKills[pid], g_iMapDeaths[pid])
    }
    return PLUGIN_HANDLED
}

public CmdRankNewSeason(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED

    if (g_iMatchState == STATE_LIVE || g_iMatchState == STATE_CANCELLED)
    {
        console_print(id, "[CSR] A match is currently live. Run amx_rank_recalc first.")
        return PLUGIN_HANDLED
    }

    new szLabel[64]
    if (read_argc() >= 2) read_args(szLabel, charsmax(szLabel))
    else                  formatex(szLabel, charsmax(szLabel), "Season %d", g_iCurrentSeason + 1)
    remove_quotes(szLabel)

    new iOldSeason = g_iCurrentSeason
    new iNewSeason = iOldSeason + 1
    new iNow       = get_systime()

    new szQ[512]
    formatex(szQ, charsmax(szQ),
        "UPDATE csr_seasons SET ended_at=%d WHERE season=%d", iNow, iOldSeason)
    DB_AsyncQuery(szQ)

    formatex(szQ, charsmax(szQ),
        "INSERT INTO csr_seasons (season, label, started_at, ended_at) \
         VALUES (%d, '%s', %d, 0)", iNewSeason, szLabel, iNow)
    DB_AsyncQuery(szQ)

    g_iCurrentSeason = iNewSeason

    new players[MAX_PLAYERS], iNum
    get_players(players, iNum, "c")
    for (new i = 0; i < iNum; i++)
    {
        new pid = players[i]
        if (is_user_bot(pid)) continue
        ResetPlayerMatchData(pid)
        g_bInDB[pid] = false
        if (g_szSteamID[pid][0] != EOS)
            DB_LoadPlayer(pid)
    }

    ResetMapData()
    client_print_color(0, print_team_default, "%L", LANG_PLAYER, "SEASON_STARTED", iNewSeason, szLabel)
    log_amx("[CSR] Admin %n started Season %d ('%s'). Season %d closed.",
        id, iNewSeason, szLabel, iOldSeason)
    return PLUGIN_HANDLED
}

public CmdRankSeasons(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED
    if (g_hSQL == Empty_Handle)
    {
        console_print(id, "[CSR] No DB connection.")
        return PLUGIN_HANDLED
    }

    new Handle:hQuery = SQL_PrepareQuery(g_hSQL, "%s",
        "SELECT season, label, started_at, ended_at FROM csr_seasons ORDER BY season ASC")
    if (hQuery == Empty_Handle || !SQL_Execute(hQuery))
    {
        if (hQuery != Empty_Handle) SQL_FreeHandle(hQuery)
        console_print(id, "[CSR] Query failed.")
        return PLUGIN_HANDLED
    }

    console_print(id, "[CSR] All seasons:")
    while (SQL_MoreResults(hQuery))
    {
        new iSeason = SQL_ReadResult(hQuery, 0)
        new szLabel[64], szStart[32], szEnd[32]
        SQL_ReadResult(hQuery, 1, szLabel, charsmax(szLabel))
        new iStart = SQL_ReadResult(hQuery, 2)
        new iEnd   = SQL_ReadResult(hQuery,  3)

        if (iStart > 0) format_time(szStart, charsmax(szStart), "%Y-%m-%d", iStart)
        else            copy(szStart, charsmax(szStart), "---")
        if (iEnd > 0)   format_time(szEnd, charsmax(szEnd), "%Y-%m-%d", iEnd)
        else            copy(szEnd,   charsmax(szEnd),   "active")

        console_print(id, "  S%d%s  '%s'  %s -> %s",
            iSeason, (iSeason == g_iCurrentSeason) ? " *" : "", szLabel, szStart, szEnd)
        SQL_NextRow(hQuery)
    }
    SQL_FreeHandle(hQuery)
    return PLUGIN_HANDLED
}

// NATIVES
public _native_custom_win(plugin, params)
{
    if (g_iMatchState != STATE_LIVE && g_iMatchState != STATE_ENDED) return 0
    g_forcedwin = true
    OnMapEnd()
    return 1
}

public _native_get_points(plugin, params)
    return g_iPoints[get_param(1)]

public _native_add_score(plugin, params)
{
    new id = get_param(1)
    AddScore(id, get_param(2))
}

public _native_get_rank_name(plugin, params)
{
    new id = get_param(1)
    if (g_iMapsPlayed[id] < PLACEMENT_MAPS)
        set_string(2, "Unranked", get_param(2))
    else
        set_string(2, RankNames[GetPlayerRank(g_iPoints[id])], get_param(2))
    return 1
}

public _native_is_placement(plugin, params)
    return (g_iMapsPlayed[get_param(1)] < PLACEMENT_MAPS) ? 1 : 0

public _native_get_state(plugin, params)
    return g_iMatchState
