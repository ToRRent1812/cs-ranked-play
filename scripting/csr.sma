/*
 * CS Ranked Play — Competitive ranking system plugin for CS 1.6 and Czero
 *
 * HOW IT WORKS
 *   Each round players earn hidden score based on performance
 *   (damage, kills, objectives). 
 *   At map end, players are sorted by SPM (score per minute) and compared pairwise to determine MMR change.
 *   Participation scaling: the more rounds played, the larger the MMR swing.
 *   Anti-smurf: cannot drop below 1/2 of peak MMR in the current season.
 *   Shield: reduced MMR loss at lower ranks.
 *   Placement: first rank assigned after PLACEMENT_MAPS completed maps.
 *   Seasons: independent leaderboards; admins control season transitions.
 *   Ragequit protection: If player disconnects, his data will be saved until map change or reconnect  
 *
 *
 * MORE INFO ON GITHUB
 * https://github.com/ToRRent1812/cs-ranked-play
 */

#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <fakemeta>
#include <sqlx>
#include <lang>
#include <karlab>

#define PLUGIN     "CSR - CS Ranked Play"
#define VERSION    "2.0.0"
#define AUTHOR     "ToRRent"

enum
{
    STATE_WAITING = 0,      // Waiting for players
    STATE_WARMUP,           // Warmup is running
    STATE_STARTING,         // Prepping for ranked game
    STATE_LIVE,             // Ranked match is live
    STATE_PAUSED,           // Ranked match is paused
    STATE_ENDED,            // Ranked match ended
    STATE_LOCKED            // Ranked match is blocked until map change
}

enum
{
    END_NONE = 0,           // No reason of ending
    END_NATURAL,            // Normal match end
    END_CANCELLED           // Cancelled match
}

#define TASK_HUD_BASE           9800
#define TASK_WARMUP_TIMER       9901
#define TASK_WARMUP_COUNTDOWN   9903
#define TASK_MAP_END            9902
#define TASK_STARTING           9904
#define TASK_SHOW_MOTD          9905
#define TASK_COUNT_MINUTES      9906
#define TASK_RANK_CHAT          9907
#define TASK_REFRESH_POS        9908

#define MAX_PLAYERS             32
#define MAX_DCSLOTS             32
#define MAX_SLOTS               (MAX_PLAYERS + MAX_DCSLOTS)

#define TEAM_CT_ID             1
#define TEAM_T_ID              2

#define PLACEMENT_MAPS          8
#define START_POINTS            500
#define RANK_COUNT              18
#define MMR_CAP                 9999
#define MMR_MAX_GAIN            100
#define MMR_MAX_LOSE            -100

#define SCORE_KILL_BONUS        5       // Bonus for headshot/knife/nade/pistol kill
#define BAD_WEAPON_MULTIPLIER   2       // Bad weapons earn 2 points per 10 damage instead of 1
#define SCORE_LONGSHOT          2       // Bonus for longshot kill
#define SCORE_PLANT             20      // Bonus for bomb plant
#define SCORE_DEFUSE            30      // Bonus for bomb defuse
#define SCORE_HOSTAGE_RESCUE    15      // Bonus for rescuing a hostage
#define SCORE_HOSTAGE_KILL      -15     // Penalty for killing a hostage
#define SCORE_ROUND_WIN         25      // Bonus for winning a round
#define SCORE_ROUND_LOST        -15     // Penalty for losing a round
#define SCORE_DEATH             -10     // Penalty for dying
#define SCORE_TEAMKILL          -20     // Penalty for team killing
#define SCORE_KILLSTREAK        1       // Base bonus for each kill in a killstreak (starting from 2 kills in a row)
#define MAX_KILLSTREAK          10      // Maximum killstreak that grants bonus points

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

new const RankNamesShort[RANK_COUNT][] = {
    "Silver I","Silver II","Silver III","Silver IV","Silver Elite","Silver Master",
    "Gold I","Gold II","Gold III","Gold Master",
    "Guardian I","Guardian II","Guardian Elite","Master Guardian",
    "Eagle","Eagle Master","SUPREME","GLOBAL ELITE"
}

new const RankThresholds[RANK_COUNT + 1] = {
    0, 75, 150, 225, 300, 375,
    500, 625, 750, 875,
    1050, 1225, 1400, 1600,
    1900, 2200, 2600, 3000,
    9999
}

new const LossTakenPct[RANK_COUNT] = {
    0, 10, 20, 30, 40, 45,
    50, 55, 60, 65,
    70, 75, 80, 85,
    90, 95, 100, 100
}

new const WorseWin[11]   = {  50,  46,  42,  38,  34,  30,  26,  22,  18,  14,  10 }
new const BetterWin[11]  = {  50,  55,  60,  65,  70,  75,  80,  85, 90, 95, 100 }
new const WorseLose[11]  = { -50, -46, -42, -38, -34, -30, -26, -22, -18, -14, -10 }
new const BetterLose[11] = { -50, -55, -60, -65, -70, -75, -80, -85, -90, -95, -100 }

new g_iPoints[MAX_SLOTS + 1]
new g_iPeakPoints[MAX_SLOTS + 1]
new g_iMapsPlayed[MAX_SLOTS + 1]
new bool:g_bInDB[MAX_SLOTS + 1]
new g_szSteamID[MAX_SLOTS + 1][35]
new g_szName[MAX_SLOTS + 1][32]
new g_iMatchScore[MAX_SLOTS + 1]
new g_iMinuteJoined[MAX_SLOTS + 1]
new g_iMapKills[MAX_SLOTS + 1]
new g_iMapDeaths[MAX_SLOTS + 1]
new g_iKillStreak[MAX_SLOTS + 1]
new g_iRoundScoreEarned[MAX_SLOTS + 1]
new g_iEnemyDmgBuffer[MAX_SLOTS + 1]
new g_iTeamDmgBuffer[MAX_SLOTS + 1]
new bool:g_bBot[MAX_SLOTS + 1]
new g_iGlobalPos[MAX_SLOTS + 1]
new g_iStatusTeam[MAX_PLAYERS + 1]
new g_iMatchState = STATE_WAITING
new g_iTotalMinutes
new g_iTeamRounds[3]
new g_iCurrentSeason = 1
new g_iWarmupCountdown
new g_iEffectiveScoreCap
new g_iEndReason = END_NONE
new bool:g_bCalcPending = false
new bool:g_bResultsDone = false
new g_cvarDebug
new g_cvarMinPlayers
new g_cvarIdealPlayers
new g_cvarMinMinutes
new g_cvarScoreCap
new g_cvarWarmupTime
new g_cvarDBType
new g_cvarDBHost
new g_cvarDBUser
new g_cvarDBPass
new g_cvarDBName
new g_cvarDoubleGain
new g_cvarLongmatch
new g_cvarKarPort
new g_cvarMotdHost
new g_cvarMatchwin
new g_cvarManualScoring
new g_cvarLoyaltyBonus
new bool:g_bWelcome[MAX_SLOTS + 1] = false
new g_szResultsHTML[16384]
new g_szTopHTML[16384]
new bool:g_bKarLibLoaded = false
new g_statussync
new g_iMsgSayText
new g_PlayerName
new g_DisconnectCounter = 1
new Handle:g_hSQLTuple
new Handle:g_hSQL

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR)
    register_dictionary("csr.txt")

    g_cvarDebug = register_cvar("rank_debug","0",FCVAR_SERVER)                              // Debug mode
    g_cvarMinPlayers = register_cvar("rank_min_players","4",FCVAR_SERVER)                   // Minimum amount of human players to start ranked match
    g_cvarIdealPlayers = register_cvar("rank_ideal_players","10",FCVAR_SERVER)              // Ideal amount of players for max MMR gain/loss
    g_cvarMinMinutes = register_cvar("rank_min_minutes","5", FCVAR_SERVER)                  // Minimum amount of minutes a player need to play to be eligible for MMR change
    g_cvarScoreCap = register_cvar("rank_score_cap","250",FCVAR_SERVER)                     // Maximum score a player can earn in a single round
    g_cvarMatchwin = register_cvar("rank_match_win_bonus","0",FCVAR_SERVER)                 // How much score player should earn for winning a match (useful on scrim/pug/pro server)
    g_cvarManualScoring = register_cvar("rank_manual_scoring","0",FCVAR_SERVER)             // 1 = disable automatic match score from events, rely on external plugins using csr natives
    g_cvarLoyaltyBonus = register_cvar("rank_loyalty_bonus","1",FCVAR_SERVER)               // 1 = MMR bonus for playing a lot of matches (Bonus increases by 1 every 20 maps)
    g_cvarDoubleGain = register_cvar("rank_double_gain","0",FCVAR_SERVER)                   // 1 = double MMR gain bonus event
    g_cvarLongmatch = register_cvar("rank_longmatch_minutes","45",FCVAR_SERVER)             // Minutes a player must spend in a match to get 25% MMR bonus for playing long match
    g_cvarWarmupTime = register_cvar("rank_warmup_time","45",FCVAR_SERVER)                  // Warmup time in seconds
    g_cvarKarPort = register_cvar("rank_karlib_port","8090",FCVAR_SERVER|FCVAR_PROTECTED)   // Port to use MOTD webpages
    g_cvarMotdHost = register_cvar("rank_motd_host","",FCVAR_SERVER)                        // Override IP for MOTD iframes
    g_cvarDBType = register_cvar("rank_db_type","sqlite",FCVAR_SERVER|FCVAR_PROTECTED)      // Saving type: "sqlite" or "mariadb"
    g_cvarDBHost = register_cvar("rank_db_host","127.0.0.1",FCVAR_SERVER|FCVAR_PROTECTED)   // Mysql Database host
    g_cvarDBUser = register_cvar("rank_db_user","CSR",FCVAR_SERVER|FCVAR_PROTECTED)         // Mysql Database user
    g_cvarDBPass = register_cvar("rank_db_pass","",FCVAR_SERVER|FCVAR_PROTECTED)            // Mysql Database password
    g_cvarDBName = register_cvar("rank_db_name","CSR",FCVAR_SERVER|FCVAR_PROTECTED)         // Mysql Database name

    RegisterHookChain(RG_CBasePlayer_TakeDamage,"OnTakeDamage",false)
    RegisterHookChain(RG_CBasePlayer_Killed,"OnPlayerKilled",false)
    RegisterHookChain(RG_RoundEnd,"OnRoundEnd",false)
    RegisterHookChain(RG_CBasePlayer_Spawn,"OnPlayerSpawn",false)
    RegisterHookChain(RG_PlantBomb,"OnBombPlanted",true)
    RegisterHookChain(RG_CGrenade_DefuseBombEnd,"OnBombDefused",true)
    register_logevent("OnHostageRescued",2,"1=triggered","2=Rescued_A_Hostage")
    register_logevent("OnHostageKilled", 2,"1=triggered","2=Killed_A_Hostage")
    register_logevent("OnNewRound", 2, "1=Round_Start")
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


ValidateCvars()
{
    if (get_pcvar_num(g_cvarMinPlayers)   < 1)   set_pcvar_num(g_cvarMinPlayers, 1)
    if (get_pcvar_num(g_cvarIdealPlayers) < 1)   set_pcvar_num(g_cvarIdealPlayers, 1)
    if (get_pcvar_num(g_cvarMinMinutes)   < 1)   set_pcvar_num(g_cvarMinMinutes, 1)
    if (get_pcvar_num(g_cvarLongmatch)    < get_pcvar_num(g_cvarMinMinutes))   set_pcvar_num(g_cvarLongmatch, get_pcvar_num(g_cvarMinMinutes))
    if (get_pcvar_num(g_cvarScoreCap)     < 0)   set_pcvar_num(g_cvarScoreCap, 1000000)
    if (get_pcvar_num(g_cvarMatchwin)     < 0)   set_pcvar_num(g_cvarMatchwin, 0)
    if (get_pcvar_num(g_cvarDoubleGain)   < 0)   set_pcvar_num(g_cvarDoubleGain, 0)
    if (get_pcvar_num(g_cvarLoyaltyBonus) < 0)   set_pcvar_num(g_cvarLoyaltyBonus, 0)
    if (get_pcvar_num(g_cvarLoyaltyBonus) > 1)   set_pcvar_num(g_cvarLoyaltyBonus, 1)
    if (get_pcvar_num(g_cvarLongmatch)    < 1)   set_pcvar_num(g_cvarLongmatch, 1)
    if (get_pcvar_num(g_cvarWarmupTime)   < 0)   set_pcvar_num(g_cvarWarmupTime, 0)
}

InitKarLib()
{
    if (g_bKarLibLoaded) return
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

public plugin_cfg()
{
    remove_task(TASK_MAP_END)
    remove_task(TASK_REFRESH_POS)
    remove_task(TASK_SHOW_MOTD)
    remove_task(TASK_COUNT_MINUTES)
    g_bCalcPending = false
    g_bResultsDone = false
    g_iEndReason = END_NONE
    SetMatchState(STATE_WAITING)
    g_iTotalMinutes = 0
    g_DisconnectCounter = 1
    set_task(3.0, "Task_SQL_Init")

    ValidateCvars()
    InitKarLib()

    set_task(6.0, "Task_BuildTopHTML")
}

ParseSeasonParam(const params[], const values[])
{
    new iSemicolon = contain(params, "season")
    if (iSemicolon == -1) return 0
    new iIdx = 0
    for (new i = 0; i < iSemicolon; i++)
        if (params[i] == ';') iIdx++
    new szVal[12]
    new iCur = 0, iStart = 0
    for (new j = 0; values[j] != EOS; j++)
    {
        if (iCur == iIdx) { iStart = j; break; }
        if (values[j] == ';') iCur++
    }
    copyc(szVal, charsmax(szVal), values[iStart], ';')
    return str_to_num(szVal)
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
        new iReqSeason = ParseSeasonParam(params, values)

        if (iReqSeason > 0 && iReqSeason != g_iCurrentSeason)
            BuildLeaderboardHTML(iReqSeason, 10, szResp, charsmax(szResp))
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
    register_library("csr")
    register_native("csr_get_points","_native_get_points")
    register_native("csr_get_rank_name","_native_get_rank_name")
    register_native("csr_is_placement","_native_is_placement")
    register_native("csr_get_state","_native_get_state")
    register_native("csr_custom_win","_native_custom_win")
    register_native("csr_add_score","_native_add_score")
    register_native("csr_get_score","_native_get_score")
    register_native("csr_set_score","_native_set_score")
}

SetMatchState(iNew)
{
    if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] State %d -> %d", g_iMatchState, iNew)

    new iPrev = g_iMatchState
    g_iMatchState = iNew

    switch (iNew)
    {
        case STATE_WAITING:
        {
            ResetMapData()
            g_bResultsDone = false
            g_iEndReason = END_NONE
            g_iEffectiveScoreCap = 0
            remove_task(TASK_WARMUP_TIMER)
            remove_task(TASK_WARMUP_COUNTDOWN)
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_WAITING", get_pcvar_num(g_cvarMinPlayers))
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_WAITING")
        }
        case STATE_WARMUP:
        {
            if (CountHumanPlayers() < get_pcvar_num(g_cvarMinPlayers))
            {
                SetMatchState(STATE_WAITING)
                return
            }
            remove_task(TASK_WARMUP_TIMER)
            remove_task(TASK_WARMUP_COUNTDOWN)
            set_cvar_num("mp_forcerespawn", 2)
            g_iWarmupCountdown = get_pcvar_num(g_cvarWarmupTime)
            set_task(1.0, "Task_WarmupCountdown", TASK_WARMUP_COUNTDOWN, _, _, "a", g_iWarmupCountdown)
            set_task(float(get_pcvar_num(g_cvarWarmupTime)), "Task_WarmupExpired", TASK_WARMUP_TIMER)
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_WARMUP_START", get_pcvar_num(g_cvarWarmupTime))
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_WARMUP")
        }
        case STATE_STARTING:
        {
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_RESTARTING")
            set_cvar_num("mp_forcerespawn", 0)
            server_cmd("sv_restart 2")
            remove_task(TASK_WARMUP_COUNTDOWN)
            remove_task(TASK_STARTING)
            set_task(4.2, "Task_StartingFallback", TASK_STARTING)
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_STARTING, refreshing DB data")
        }
        case STATE_LIVE:
        {
            remove_task(TASK_STARTING)
            remove_task(TASK_WARMUP_COUNTDOWN)
            set_cvar_num("mp_forcerespawn", 0)
            client_print_color(0, print_team_default, "%L", LANG_PLAYER, "STATE_LIVE")
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_LIVE")
            if (iPrev != STATE_PAUSED)
            {
                ResetMapData()
                g_bResultsDone = false
                g_iEndReason = END_NONE
                if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Fresh match started, match data reset")
            }
            else if (get_pcvar_num(g_cvarDebug))
                log_amx("[CSR] Resumed STATE_LIVE, preserving match data")
            g_iEffectiveScoreCap = GetEffectiveScoreCap()
            remove_task(TASK_COUNT_MINUTES)
            set_task(1.0, "Task_CountMinutes", TASK_COUNT_MINUTES)
        }
        case STATE_PAUSED:
        {
            remove_task(TASK_WARMUP_TIMER)
            remove_task(TASK_WARMUP_COUNTDOWN)
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_PAUSED")
        }
        case STATE_LOCKED:
        {
            remove_task(TASK_WARMUP_TIMER)
            remove_task(TASK_WARMUP_COUNTDOWN)
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Entered STATE_LOCKED — waiting for map change")
        }
    }
}

public Task_CountMinutes()
{
    if(g_iMatchState == STATE_LIVE) g_iTotalMinutes++
    remove_task(TASK_COUNT_MINUTES)
    set_task(60.0, "Task_CountMinutes", TASK_COUNT_MINUTES)
}

public Task_StartingFallback()
{
    if (g_iMatchState != STATE_STARTING)
        return
    if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] STATE_STARTING fallback fired — forcing STATE_LIVE")
    SetMatchState(STATE_LIVE)
}

public Round_Restart()
{
    if (g_iMatchState == STATE_WAITING && CountHumanPlayers() >= get_pcvar_num(g_cvarMinPlayers))
        SetMatchState(STATE_WARMUP)
}

public Task_WarmupCountdown()
{
    if (g_iMatchState != STATE_WARMUP) return
    if(g_iWarmupCountdown > 0) g_iWarmupCountdown--
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
            if (iCount < iMin) SetMatchState(STATE_PAUSED)
        }
        case STATE_PAUSED:
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
    new players[32], iNum
    get_players(players, iNum, "ci")
    return iNum
}

GetTeamId(id)
{
    new iTeam = get_user_team(id)
    if (iTeam == _:TEAM_CT) return TEAM_CT_ID
    if (iTeam == _:TEAM_TERRORIST) return TEAM_T_ID
    return 0
}

GetPlayerRank(iPoints)
{
    if (iPoints >= MMR_CAP) return RANK_COUNT - 1
    for (new i = 0; i < RANK_COUNT; i++)
        if (iPoints < RankThresholds[i + 1])
            return i
    return RANK_COUNT - 1
}

stock bool:IsPlacement(id)
{
    return g_iMapsPlayed[id] < PLACEMENT_MAPS
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
    g_iMinuteJoined[id]     = -1
    g_iKillStreak[id]       = 0
    g_iRoundScoreEarned[id] = 0
    g_iEnemyDmgBuffer[id]   = 0
    g_iTeamDmgBuffer[id]    = 0
    g_iMapKills[id]         = 0
    g_iMapDeaths[id]        = 0
    g_szName[id][0]         = EOS
    g_bWelcome[id]          = false
}

TransferData(from, to, bool:bCopyStats)
{
    g_iMatchScore[to]       = g_iMatchScore[from]
    g_iMinuteJoined[to]     = g_iMinuteJoined[from]
    g_iKillStreak[to]       = g_iKillStreak[from]
    g_iRoundScoreEarned[to] = g_iRoundScoreEarned[from]
    g_iEnemyDmgBuffer[to]   = g_iEnemyDmgBuffer[from]
    g_iTeamDmgBuffer[to]    = g_iTeamDmgBuffer[from]
    g_bBot[to]              = g_bBot[from]
    g_iMapKills[to]         = g_iMapKills[from]
    g_iMapDeaths[to]        = g_iMapDeaths[from]
    if (bCopyStats)
    {
        g_iPoints[to]     = g_iPoints[from]
        g_iPeakPoints[to] = g_iPeakPoints[from]
        g_iMapsPlayed[to] = g_iMapsPlayed[from]
        g_bInDB[to]       = g_bInDB[from]
    }
    copy(g_szName[to], charsmax(g_szName[]), g_szName[from])
    copy(g_szSteamID[to], charsmax(g_szSteamID[]), g_szSteamID[from])
    ResetPlayerMatchData(from)
}

ResetMapData()
{
    g_iTotalMinutes  = 0
    g_iTeamRounds[TEAM_T_ID] = 0
    g_iTeamRounds[TEAM_CT_ID] = 0
    for (new id = 1; id <= MAX_SLOTS; id++)
        ResetPlayerMatchData(id)
}

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

    DB_CreateTables()
    DB_LoadCurrentSeason()
    log_amx("[CSR] Database ready (season %d).", g_iCurrentSeason)
}

DB_CreateTables()
{
    if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Creating tables...")

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
            name        VARCHAR(32) NOT NULL DEFAULT '', \
            points      INT         NOT NULL DEFAULT 400, \
            peak_points INT         NOT NULL DEFAULT 0, \
            maps_played INT         NOT NULL DEFAULT 0, \
            PRIMARY KEY (steamid, season))")

    SQL_SimpleQuery(g_hSQL,
        "CREATE INDEX IF NOT EXISTS idx_players_season_points ON csr_players (season, points DESC)")
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

    if (is_user_connected(id))
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
            g_iPeakPoints[id] = 0
            g_iMapsPlayed[id] = 0
            g_bInDB[id]       = false
        }
    }
    SQL_FreeHandle(hQuery)

    if (g_iMapsPlayed[id] < PLACEMENT_MAPS)
        g_iPeakPoints[id] = 0
    else if (g_iPeakPoints[id] < g_iPoints[id])
        g_iPeakPoints[id] = g_iPoints[id]

    g_iGlobalPos[id] = GetGlobalPosition(id)
}

DB_BulkLoadPlayers(iPlayers[], iNum)
{
    if (iNum <= 0) return
    if (g_hSQL == Empty_Handle) return

    static szList[5000], szQ[5200]
    szList[0] = EOS
    for (new i = 0; i < iNum; i++)
    {
        new szSafe[70]
        SQL_QuoteString(g_hSQL, szSafe, charsmax(szSafe), g_szSteamID[iPlayers[i]])
        if (szList[0] == EOS)
            formatex(szList, charsmax(szList), "'%s'", szSafe)
        else
        {
            add(szList, charsmax(szList), ",'")
            add(szList, charsmax(szList), szSafe)
            add(szList, charsmax(szList), "'")
        }
    }

    formatex(szQ, charsmax(szQ),
        "SELECT steamid,points,peak_points,maps_played FROM csr_players WHERE season=%d AND steamid IN (%s)",
        g_iCurrentSeason, szList)

    new Handle:hQuery = SQL_PrepareQuery(g_hSQL, "%s", szQ)
    if (hQuery == Empty_Handle) return

    if (SQL_Execute(hQuery))
    {
        while (SQL_MoreResults(hQuery))
        {
            new szSteam[35]
            SQL_ReadResult(hQuery, 0, szSteam, charsmax(szSteam))
            new iPoints = SQL_ReadResult(hQuery, 1)
            new iPeak   = SQL_ReadResult(hQuery, 2)
            new iMaps   = SQL_ReadResult(hQuery, 3)
            for (new i = 0; i < iNum; i++)
            {
                if (!equal(g_szSteamID[iPlayers[i]], szSteam)) continue
                g_iPoints[iPlayers[i]]     = iPoints
                g_iPeakPoints[iPlayers[i]] = (iMaps < PLACEMENT_MAPS) ? 0 : ((iPeak > iPoints) ? iPeak : iPoints)
                g_iMapsPlayed[iPlayers[i]] = iMaps
                g_bInDB[iPlayers[i]]       = true
                break
            }
            SQL_NextRow(hQuery)
        }
    }
    SQL_FreeHandle(hQuery)
}

GetPlayerName(id, szOut[], iOutLen)
{
    if (g_szName[id][0] != EOS)
        copy(szOut, iOutLen, g_szName[id])
    else
        copy(szOut, iOutLen, g_szSteamID[id])
}

DB_UpdateNickname(id, bool:bSync = false)
{
    if (g_hSQL == Empty_Handle || g_szSteamID[id][0] == EOS) return
    if (g_szName[id][0] == EOS) return

    new szPlayerName[32]
    copy(szPlayerName, charsmax(szPlayerName), g_szName[id])

    new szSafe[129]
    SQL_QuoteString(g_hSQL, szSafe, charsmax(szSafe), szPlayerName)

    new szQuery[256]
    formatex(szQuery, charsmax(szQuery),
        "UPDATE csr_players SET name='%s' WHERE steamid='%s' AND season=%d",
        szSafe, g_szSteamID[id], g_iCurrentSeason)

    if (bSync)
    {
        new Handle:hQuery = SQL_PrepareQuery(g_hSQL, "%s", szQuery)
        if (hQuery != Empty_Handle)
        {
            SQL_Execute(hQuery)
            SQL_FreeHandle(hQuery)
        }
    }
    else
    {
        DB_AsyncQuery(szQuery)
    }

    g_szTopHTML[0] = EOS
}

DB_QueueSavePlayer(id)
{
    if (g_hSQL == Empty_Handle)
    {
        SQL_Init()
        if (g_hSQL == Empty_Handle) return
    }

    if (!IsPlacement(id) && g_iPoints[id] > g_iPeakPoints[id])
        g_iPeakPoints[id] = g_iPoints[id]

    if (is_user_connected(id))
        get_user_name(id, g_szName[id], charsmax(g_szName[]))

    new szPlayerName[32]
    GetPlayerName(id, szPlayerName, charsmax(szPlayerName))

    new szSafeName[129]
    SQL_QuoteString(g_hSQL, szSafeName, charsmax(szSafeName), szPlayerName)

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
    new bool:bSaved[MAX_SLOTS + 1]

    for (new i = 0; i < iQualNum; i++)
    {
        DB_QueueSavePlayer(iQualPlayers[i])
        bSaved[iQualPlayers[i]] = true
    }
    for (new id = 1; id <= MAX_SLOTS; id++)
        if (bIsParticipant[id] && !bSaved[id] && g_bInDB[id])
            DB_QueueSavePlayer(id)
}

public client_authorized(id)
{
    g_bBot[id] = bool:is_user_bot(id)

    if (g_bBot[id])
    {
        get_user_name(id, g_szSteamID[id], charsmax(g_szSteamID[]))
        get_user_name(id, g_szName[id], charsmax(g_szName[]))
    }
    else
    {
        get_user_authid(id, g_szSteamID[id], charsmax(g_szSteamID[]))
    }

    for (new other = 1; other <= MAX_PLAYERS; other++)
    {
        if (other == id || !equal(g_szSteamID[other], g_szSteamID[id])) continue
        log_amx("[CSR] Duplicate SteamID '%s', clearing active slot %d.", g_szSteamID[id], other)
        ResetPlayerMatchData(other)
        g_szSteamID[other][0] = EOS
    }

    ResetPlayerMatchData(id)
    DB_LoadPlayer(id)
    DB_UpdateNickname(id)

    for (new other = MAX_PLAYERS + 1; other <= MAX_SLOTS; other++)
    {
        if (!equal(g_szSteamID[other], g_szSteamID[id])) continue
        TransferData(other, id, false)
        g_szSteamID[other][0] = EOS
        log_amx("[CSR] Player reconnected. Restoring data for SteamID '%s'", g_szSteamID[id])
        break
    }
    CheckPlayerCount()

    set_task(3.0, "Task_InitHUD", id)
    set_task(30.0, "Task_RankChat", TASK_RANK_CHAT + id)
}

public client_putinserver(id)
{
    g_bBot[id] = bool:is_user_bot(id)
    if (g_bBot[id])
        return

    if (g_szSteamID[id][0] == EOS)
        get_user_authid(id, g_szSteamID[id], charsmax(g_szSteamID[]))

    get_user_name(id, g_szName[id], charsmax(g_szName[]))
    DB_UpdateNickname(id, true)
    CheckPlayerCount()

    set_task(1.0, "Task_CheckPlayerCount")
}

public client_disconnected(id)
{
    remove_task(TASK_HUD_BASE + id)
    remove_task(TASK_RANK_CHAT + id)
    g_iGlobalPos[id] = -1

    if (g_szSteamID[id][0] != EOS && g_szName[id][0] != EOS)
        DB_UpdateNickname(id)

    SettleDamage(id)

    if (g_iMinuteJoined[id] >= 0 && g_iTotalMinutes - g_iMinuteJoined[id] >= get_pcvar_num(g_cvarMinMinutes))
    {
        g_DisconnectCounter++
        if(g_DisconnectCounter > MAX_DCSLOTS) g_DisconnectCounter = 1
        TransferData(id, MAX_PLAYERS + g_DisconnectCounter, true)
    }
    ResetPlayerMatchData(id)
    g_szSteamID[id][0] = EOS
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

public Task_RefreshHUD(taskId)
{
    new id = taskId - TASK_HUD_BASE
    if (!is_user_connected(id) || is_user_bot(id)) return

    remove_task(taskId)
    set_task(1.0, "Task_RefreshHUD", taskId)

    if (g_iMatchState == STATE_WARMUP)
    {
        new szLine[64]
        formatex(szLine, charsmax(szLine), "%L", id, "HUD_WARMUP", g_iWarmupCountdown)
        set_dhudmessage(255, 255, 0, -1.0, 0.1, 2, 0.6, 1.0, 0.0, 0.1)
        show_dhudmessage(id, szLine)
    }
    else if (!is_user_alive(id))
    {
        if (get_entvar(id, var_deadflag) == DEAD_DYING)
            return

        new iTarget = get_member(id, m_hObserverTarget)
        if (iTarget != id && iTarget > 0 && iTarget <= MAX_PLAYERS && is_user_connected(iTarget) && is_user_alive(iTarget))
        {
            new szLine[128]
            if (IsPlacement(iTarget))
                formatex(szLine, charsmax(szLine), "%L", id, "HUD_WATCH_PLACEMENT")
            else
                formatex(szLine, charsmax(szLine), "%L", id, "HUD_WATCH_RANKED", RankNamesShort[GetPlayerRank(g_iPoints[iTarget])], g_iPoints[iTarget], g_iGlobalPos[iTarget])
            set_hudmessage(255, 255, 200, -1.0, 0.85, 0, 0.0, 1.0, 0.3, 0.1, 1)
            show_hudmessage(id, szLine)
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
    g_iStatusTeam[id] = read_data(2)
}

public showStatus(id)
{
    new statsHudMessage = get_xvar_num(g_PlayerName)
    new pid = read_data(2)
    new s_targetname[32]
    new s_RankName[64]
    if(IsPlacement(pid)) copy(s_RankName, charsmax(s_RankName), "")
    else if(g_iPoints[pid] >= 3000) formatex(s_RankName, charsmax(s_RankName), "|  %s (TOP %d) |", RankNamesShort[RANK_COUNT - 1], g_iGlobalPos[pid])
    else formatex(s_RankName, charsmax(s_RankName), "|  %s  |", RankNamesShort[GetPlayerRank(g_iPoints[pid])])

    get_user_name(pid, s_targetname, charsmax(s_targetname))

    if(!statsHudMessage)
    {
        if (g_iStatusTeam[id] == 1)
        {
            set_hudmessage(30, 255, 30, -1.0, 0.56, 1, 0.02, 3.0, 0.01, 0.01, -1)
            ShowSyncHudMsg(id, g_statussync, "%s^n%s", s_targetname, s_RankName)
        }
        else
        {
            set_hudmessage(255, 30, 30, -1.0, 0.56, 1, 0.02, 3.0, 0.01, 0.01, -1)
            ShowSyncHudMsg(id, g_statussync, "%s^n%s", s_targetname, s_RankName)
        }
    }
}

public Task_RankChat(taskId)
{
    new id = taskId - TASK_RANK_CHAT
    if (!is_user_connected(id) || is_user_bot(id)) return
    ShowRankChat(id)
}

ShowRankChat(id)
{
    if (IsPlacement(id))
    {
        client_print_color(id, print_team_default, "%L", LANG_PLAYER, "CHAT_PLACEMENT", g_iCurrentSeason, g_iMapsPlayed[id], PLACEMENT_MAPS)
        return
    }

    new iRank = GetPlayerRank(g_iPoints[id])
    new iNextMMR = (iRank < RANK_COUNT - 1) ? RankThresholds[iRank + 1] : MMR_CAP

    new szPos[12]
    new iPos = g_iGlobalPos[id]
    if (iPos <= 0)
        copy(szPos, charsmax(szPos), "?")
    else if (iPos < 1000)
        formatex(szPos, charsmax(szPos), "#%d", iPos)
    else
        formatex(szPos, charsmax(szPos), "%dk", iPos / 1000)

    client_print_color(id, print_team_default, "%L", LANG_PLAYER, "CHAT_RANKED", g_iCurrentSeason, g_iMapsPlayed[id], RankNamesShort[iRank], g_iPoints[id], iNextMMR, szPos)
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

    if (equali(szText[start], "!rank", 5) || equali(szText[start], "/rank", 5))
    {
        ShowRankMenu(id)
        return PLUGIN_HANDLED
    }

    if (equali(szText[start], "!history", 8) || equali(szText[start], "/history", 8))
    {
        ShowHistoryMenu(id)
        return PLUGIN_HANDLED
    }

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
    if (IsPlacement(id) || g_hSQL == Empty_Handle)
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

    new players[32], iNum
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
    format_time(szOut, iOutLen, "%d.%m.%Y", iTimestamp)
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

BuildLeaderboardHTML(iSeason, iLimit, szOut[], iOutLen)
{
    if (g_hSQL == Empty_Handle)
    {
        SQL_Init()
        if (g_hSQL == Empty_Handle) return
    }

    if (iLimit < 1) iLimit = 1
    if (iLimit > 30) iLimit = 30

    static szTmp[512]
    static szRows[30][256]
    new iTotal = 0
    new bool:bHasRows = false

    new szQ[256]
    formatex(szQ, charsmax(szQ),
        "SELECT name,steamid,points,maps_played FROM csr_players WHERE maps_played>=%d AND season=%d ORDER BY points DESC LIMIT %d",
        PLACEMENT_MAPS, iSeason, iLimit)

    new Handle:hTop = SQL_PrepareQuery(g_hSQL, "%s", szQ)
    if (hTop != Empty_Handle)
    {
        if (SQL_Execute(hTop))
        {
            new iRow = 1
            while (SQL_MoreResults(hTop) && iRow <= iLimit)
            {
                new szName[32], szSteam[35], iPoints
                SQL_ReadResult(hTop, 0, szName,  charsmax(szName))
                SQL_ReadResult(hTop, 1, szSteam, charsmax(szSteam))
                iPoints = SQL_ReadResult(hTop, 2)

                new szDisplay[32]
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
                    szPos, szDisplay, RankNamesShort[GetPlayerRank(iPoints)], iPoints)

                bHasRows = true
                iTotal++
                iRow++
                SQL_NextRow(hTop)
            }
        }
        SQL_FreeHandle(hTop)
    }

    new szLabel[128]
    FormatSeasonHeader(iSeason, szLabel, charsmax(szLabel))

    static szHTML[16384]
    szHTML[0] = EOS

    add(szHTML, charsmax(szHTML), "<style>*{margin:0;padding:0}body{background:#111;color:#ccc;font:12px Arial}.col{vertical-align:top;padding:0 4px;border:none}table.outer{width:100%;table-layout:fixed;border-collapse:collapse;padding:4px}table{width:100%;border-collapse:collapse}th{background:#181818;color:#f4a800;padding:3px 5px;text-align:left;font-size:11px;border-bottom:1px solid #333}td{padding:3px 5px;border-bottom:1px solid #181818}.p{width:18px;text-align:center;font-weight:bold}.g{color:#FFD700}.s{color:#C0C0C0}.b{color:#CD7F32}.m{color:#f4a800;font-weight:bold}.nil{color:#555;text-align:center;padding:10px;font-style:italic}.hd{background:#181818;color:#f4a800;padding:4px 8px;font:bold 12px Arial;border-bottom:2px solid #333}</style>")
    formatex(szTmp, charsmax(szTmp), "<div class='hd'>%s</div><table class='outer'><tr>", szLabel)
    add(szHTML, charsmax(szHTML), szTmp)

    if (!bHasRows)
    {
        add(szHTML, charsmax(szHTML), "<td class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
        add(szHTML, charsmax(szHTML), "<tr><td colspan='4' class='nil'>No data...</td></tr>")
        add(szHTML, charsmax(szHTML), "</tbody></table></td>")
    }
    else
    {
        add(szHTML, charsmax(szHTML), "<td class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
        for (new r = 0; r < 15 && r < iTotal; r++)
            add(szHTML, charsmax(szHTML), szRows[r])
        add(szHTML, charsmax(szHTML), "</tbody></table></td>")

        if (iTotal > 15)
        {
            add(szHTML, charsmax(szHTML), "<td class='col'><table><thead><tr><th class='p'>#</th><th>Nick</th><th>Rank</th><th>MMR</th></tr></thead><tbody>")
            for (new r = 15; r < iTotal; r++)
                add(szHTML, charsmax(szHTML), szRows[r])
            add(szHTML, charsmax(szHTML), "</tbody></table></td>")
        }
    }

    add(szHTML, charsmax(szHTML), "</tr></table>")
    copy(szOut, iOutLen, szHTML)
}

BuildTopHTML()
{
    if (g_hSQL == Empty_Handle)
    {
        SQL_Init()
        if (g_hSQL == Empty_Handle) return
    }
    BuildLeaderboardHTML(g_iCurrentSeason, 30, g_szTopHTML, charsmax(g_szTopHTML))
}

public Task_BuildTopHTML()
{
    BuildTopHTML()
}

BuildKarlibIframe(const szPath[], szOut[], iOutLen)
{
    new szServerIP[32]
    get_pcvar_string(g_cvarMotdHost, szServerIP, charsmax(szServerIP))
    if (szServerIP[0] == EOS)
        get_cvar_string("net_address", szServerIP, charsmax(szServerIP))
    new iColon = contain(szServerIP, ":")
    if (iColon != -1) szServerIP[iColon] = EOS
    new iPort = get_pcvar_num(g_cvarKarPort)
    formatex(szOut, iOutLen,
        "<style>*{margin:0;padding:0}body,html{height:100%%}iframe{width:100%%;height:100%%;border:none}</style><iframe src='http://%s:%d/%s'></iframe>",
        szServerIP, iPort, szPath)
}

ShowTopMOTD(id, iReqSeason)
{
    new szTitle[32]

    if (iReqSeason > 0 && iReqSeason != g_iCurrentSeason)
    {
        new szChkQ[96]
        formatex(szChkQ, charsmax(szChkQ), "SELECT season FROM csr_seasons WHERE season=%d", iReqSeason)
        new Handle:hChk = SQL_PrepareQuery(g_hSQL, "%s", szChkQ)
        new bool:bExists = (hChk != Empty_Handle && SQL_Execute(hChk) && SQL_MoreResults(hChk))
        if (hChk != Empty_Handle) SQL_FreeHandle(hChk)

        if (!bExists)
        {
            client_print_color(id, print_team_default, "%L", LANG_PLAYER, "RANK_WRONG_SEASON", iReqSeason)
            return
        }

        formatex(szTitle, charsmax(szTitle), "Ranked season %d", iReqSeason)

        if (g_bKarLibLoaded)
        {
            new szPath[64], szMotd[512]
            formatex(szPath, charsmax(szPath), "csr_top?season=%d", iReqSeason)
            BuildKarlibIframe(szPath, szMotd, charsmax(szMotd))
            show_motd(id, szMotd, szTitle)
        }
        return
    }

    if (g_szTopHTML[0] == EOS) BuildTopHTML()
    if (g_szTopHTML[0] == EOS) return

    formatex(szTitle, charsmax(szTitle), "Ranked season %d", g_iCurrentSeason)

    new szMotd[512]
    BuildKarlibIframe("csr_top", szMotd, charsmax(szMotd))
    show_motd(id, szMotd, szTitle)
}

AppendRankRow(szMenu[], iMenuLen, const szColor[], const szName[], iPoints, bool:bPlacement, iMaps, iPosition)
{
    new szLine[128]
    new szTruncName[17]
    copy(szTruncName, charsmax(szTruncName), szName)

    if (bPlacement)
        formatex(szLine, charsmax(szLine), "\r%d%s %s \r[Placement %d/%d]^n", iPosition, szColor, szTruncName, iMaps, PLACEMENT_MAPS)
    else
        formatex(szLine, charsmax(szLine), "\r%d%s  %s  \r[%s]\y %d MMR^n", iPosition, szColor, szTruncName, RankNamesShort[GetPlayerRank(iPoints)], iPoints)

    add(szMenu, iMenuLen, szLine)
}

ShowRankMenu(id)
{
    if (g_hSQL == Empty_Handle) return
    if (g_szSteamID[id][0] == EOS) return

    new szMyName[33]
    get_user_name(id, szMyName, charsmax(szMyName))
    new iMyPoints = g_iPoints[id]
    new iMyMaps   = g_iMapsPlayed[id]
    new bool:bRanked = (iMyMaps >= PLACEMENT_MAPS)

    new szAboveName[3][33], iAbovePoints[3], iAboveCount
    new szQ[256]
    formatex(szQ, charsmax(szQ),
        "SELECT name,points FROM csr_players WHERE season=%d AND maps_played>=%d AND points>%d ORDER BY points ASC LIMIT 3",
        g_iCurrentSeason, PLACEMENT_MAPS, iMyPoints)
    new Handle:hAbove = SQL_PrepareQuery(g_hSQL, "%s", szQ)
    if (hAbove != Empty_Handle)
    {
        if (SQL_Execute(hAbove))
        {
            while (SQL_MoreResults(hAbove) && iAboveCount < 3)
            {
                SQL_ReadResult(hAbove, 0, szAboveName[iAboveCount], charsmax(szAboveName[]))
                iAbovePoints[iAboveCount] = SQL_ReadResult(hAbove, 1)
                iAboveCount++
                SQL_NextRow(hAbove)
            }
        }
        SQL_FreeHandle(hAbove)
    }

    new szBelowName[3][33], iBelowPoints[3], iBelowCount
    formatex(szQ, charsmax(szQ),
        "SELECT name,points FROM csr_players WHERE season=%d AND maps_played>=%d AND points<%d ORDER BY points DESC LIMIT 3",
        g_iCurrentSeason, PLACEMENT_MAPS, iMyPoints)
    new Handle:hBelow = SQL_PrepareQuery(g_hSQL, "%s", szQ)
    if (hBelow != Empty_Handle)
    {
        if (SQL_Execute(hBelow))
        {
            while (SQL_MoreResults(hBelow) && iBelowCount < 3)
            {
                SQL_ReadResult(hBelow, 0, szBelowName[iBelowCount], charsmax(szBelowName[]))
                iBelowPoints[iBelowCount] = SQL_ReadResult(hBelow, 1)
                iBelowCount++
                SQL_NextRow(hBelow)
            }
        }
        SQL_FreeHandle(hBelow)
    }

    static szMenu[768]
    szMenu[0] = EOS

    new szTitle[48]
    formatex(szTitle, charsmax(szTitle), "\ySeason %d^n^n", g_iCurrentSeason)
    add(szMenu, charsmax(szMenu), szTitle)

    new iMyPos = g_iGlobalPos[id]
    if (iMyPos < 1) iMyPos = 1

    for (new i = iAboveCount - 1; i >= 0; i--)
        AppendRankRow(szMenu, charsmax(szMenu), "\w", szAboveName[i], iAbovePoints[i], false, 0, (iMyPos - i - 1 >= 1) ? (iMyPos - i - 1) : 1)

    AppendRankRow(szMenu, charsmax(szMenu), "\y", szMyName, iMyPoints, !bRanked, iMyMaps, iMyPos)

    for (new i = 0; i < iBelowCount; i++)
        AppendRankRow(szMenu, charsmax(szMenu), "\d", szBelowName[i], iBelowPoints[i], false, 0, iMyPos + i + 1)

    add(szMenu, charsmax(szMenu), "^n\r0. \wOK")
    show_menu(id, MENU_KEY_0, szMenu, -1)
}

ShowHistoryMenu(id)
{
    if (g_hSQL == Empty_Handle) return
    if (g_szSteamID[id][0] == EOS) return

    new szQ[384]
    formatex(szQ, charsmax(szQ),
        "SELECT p.season,s.label,p.points,p.maps_played \
         FROM csr_players p \
         JOIN csr_seasons s ON p.season=s.season \
         WHERE p.steamid='%s' \
         ORDER BY p.season ASC",
        g_szSteamID[id])

    new Handle:hQuery = SQL_PrepareQuery(g_hSQL, "%s", szQ)
    if (hQuery == Empty_Handle) return

    static szMenu[768]
    szMenu[0] = EOS
    add(szMenu, charsmax(szMenu), "\yHistory^n^n")

    new bool:bFound = false
    if (SQL_Execute(hQuery))
    {
        while (SQL_MoreResults(hQuery))
        {
            new iSeason = SQL_ReadResult(hQuery, 0)
            new szLabel[32], iPoints, iMaps
            SQL_ReadResult(hQuery, 1, szLabel, charsmax(szLabel))
            iPoints = SQL_ReadResult(hQuery, 2)
            iMaps   = SQL_ReadResult(hQuery, 3)

            new bool:bCurrent = (iSeason == g_iCurrentSeason)
            new bool:bRanked  = (iMaps >= PLACEMENT_MAPS)
            new szLine[96]

            if (bRanked)
                formatex(szLine, charsmax(szLine), "%s %s [%s] %d MMR^n",
                    bCurrent ? "\y" : "\w", szLabel,
                    RankNamesShort[GetPlayerRank(iPoints)], iPoints)
            else
                formatex(szLine, charsmax(szLine), "%s %s [Placement %d/%d]^n",
                    bCurrent ? "\y" : "\w", szLabel, iMaps, PLACEMENT_MAPS)

            add(szMenu, charsmax(szMenu), szLine)
            bFound = true
            SQL_NextRow(hQuery)
        }
    }
    SQL_FreeHandle(hQuery)

    if (!bFound)
        add(szMenu, charsmax(szMenu), "\d  No data found.^n")

    add(szMenu, charsmax(szMenu), "^n\r0. \wOK")
    show_menu(id, MENU_KEY_0, szMenu, -1)
}

// ROUND EVENTS
public OnNewRound()
{
    CheckPlayerCount()

    if (g_iMatchState == STATE_STARTING)
    {
        ResetMapData()
        SetMatchState(STATE_LIVE)
    }

    if (g_iMatchState != STATE_LIVE && g_iMatchState != STATE_PAUSED) return

    new iRound = g_iTeamRounds[TEAM_T_ID] + g_iTeamRounds[TEAM_CT_ID] + 1
    if (iRound == 1 || iRound % 10 == 0)
    {
        for (new id = 1; id <= MAX_PLAYERS; id++)
            if (is_user_connected(id) && !is_user_bot(id))
                ShowRankChat(id)
    }

    g_iEffectiveScoreCap = GetEffectiveScoreCap()

    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        g_iKillStreak[id]       = 0
        g_iRoundScoreEarned[id] = 0

        if (is_user_connected(id) && is_user_alive(id) && g_szSteamID[id][0] != EOS && g_iMinuteJoined[id] < 0)
            g_iMinuteJoined[id] = g_iTotalMinutes
    }

    RefreshPlayerNames()
}

RefreshPlayerNames()
{
    new szName[32]

    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        if (!is_user_connected(id) || is_user_bot(id)) continue

        get_user_name(id, szName, charsmax(szName))
        if (szName[0] != EOS && (!g_szName[id][0] || !equal(szName, g_szName[id])))
        {
            copy(g_szName[id], charsmax(g_szName[]), szName)
            DB_UpdateNickname(id)
        }
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

    if (g_iMatchState != STATE_LIVE && g_iMatchState != STATE_PAUSED)
        return HC_CONTINUE

    if (g_iMinuteJoined[id] < 0) g_iMinuteJoined[id] = g_iTotalMinutes

    if(!g_bWelcome[id] && !is_user_bot(id))
    {
        g_bWelcome[id] = true
        client_print_color(id, print_team_default, "%L", LANG_PLAYER, "RANK_WELCOME_1")
        client_print_color(id, print_team_default, "%L", LANG_PLAYER, "RANK_WELCOME_2")
        client_print_color(id, print_team_default, "%L", LANG_PLAYER, "RANK_WELCOME_3")
    }

    return HC_CONTINUE
}

public OnRoundEnd(status, event, Float:tmDelay)
{
    if (g_iMatchState != STATE_LIVE && g_iMatchState != STATE_PAUSED)
        return HC_CONTINUE

    if (g_iMatchState == STATE_LIVE)
    {
        for (new id = 1; id <= MAX_PLAYERS; id++)
        {
            if (!is_user_connected(id) || g_iMinuteJoined[id] < 0)
                continue
            SettleDamage(id)
        }
    }

    new mapname[5]
    get_mapname(mapname, charsmax(mapname))

    if (equali(mapname, "gg_", 3))
        return HC_CONTINUE

    if (status != TEAM_CT_ID && status != TEAM_T_ID)
        return HC_CONTINUE

    new iWinTeam = status
    g_iTeamRounds[iWinTeam]++

    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        if (!is_user_connected(id) || g_iMinuteJoined[id] < 0)
            continue

        new iTeam = GetTeamId(id)
        if (iTeam == 0)
            continue

        if (g_iMatchState == STATE_LIVE)
            AddScore(id, (iTeam == iWinTeam) ? SCORE_ROUND_WIN : SCORE_ROUND_LOST)
    }

    return HC_CONTINUE
}

public AddScore(id, iAmount)
{
    if (get_pcvar_num(g_cvarManualScoring)) return
    AddScoreInternal(id, iAmount)
}

AddScoreInternal(id, iAmount)
{
    if (g_iMatchState != STATE_LIVE) return
    if (id < 1 || id > MAX_SLOTS) return

    new iOld = g_iRoundScoreEarned[id]
    new iNew = iOld + iAmount

    if (g_iEffectiveScoreCap > 0)
        iNew = clamp(iNew, -g_iEffectiveScoreCap, g_iEffectiveScoreCap)

    g_iRoundScoreEarned[id] = iNew
    g_iMatchScore[id] += iNew - iOld
    if (g_iMatchScore[id] < 0) g_iMatchScore[id] = 0
}

SettleDamage(id, bool:bForce = false)
{
    if (id < 1 || id > MAX_SLOTS) return
    if (!bForce && g_iMatchState != STATE_LIVE) return

    new iPoints  = g_iEnemyDmgBuffer[id] / 10
    new iPenalty = g_iTeamDmgBuffer[id] / 20
    g_iEnemyDmgBuffer[id] = 0
    g_iTeamDmgBuffer[id]  = 0

    new iDelta = iPoints - iPenalty
    if (iDelta == 0) return

    if (g_iMatchState == STATE_LIVE)
    {
        AddScore(id, iDelta)
    }
    else
    {
        new iOld = g_iRoundScoreEarned[id]
        new iNew = iOld + iDelta
        if (g_iEffectiveScoreCap > 0)
            iNew = clamp(iNew, -g_iEffectiveScoreCap, g_iEffectiveScoreCap)
        g_iRoundScoreEarned[id] = iNew
        g_iMatchScore[id] += iNew - iOld
        if (g_iMatchScore[id] < 0) g_iMatchScore[id] = 0
    }
}

GetEffectiveScoreCap()
{
    if (get_cvar_num("mp_winlimit") < 1 && get_cvar_num("mp_maxrounds") < 1)
        return 0

    return get_pcvar_num(g_cvarScoreCap)
}

// DAMAGE & KILLS
public OnTakeDamage(victim, inflictor, attacker, Float:fDamage, damagetype)
{
    if (g_iMatchState != STATE_LIVE) return HC_CONTINUE
    if (get_pcvar_num(g_cvarManualScoring)) return HC_CONTINUE
    if (attacker < 1 || attacker > MAX_PLAYERS) return HC_CONTINUE
    if (attacker == victim) return HC_CONTINUE

    new iDmg = floatround(fDamage, floatround_floor)
    new iHP = get_user_health(victim)
    if (iDmg > iHP) iDmg = iHP
    if (iDmg <= 0) return HC_CONTINUE

    if (GetTeamId(attacker) == GetTeamId(victim))
    {
        if (get_cvar_num("mp_friendlyfire") == 1)
            g_iTeamDmgBuffer[attacker] += iDmg
        return HC_CONTINUE
    }

    new szClass[32]
    new iWpnEnt = get_member(attacker, m_pActiveItem)
    if (iWpnEnt > 0) pev(iWpnEnt, pev_classname, szClass, charsmax(szClass))
    else copy(szClass, charsmax(szClass), "weapon_knife")

    if (IsBadWeapon(szClass))
        g_iEnemyDmgBuffer[attacker] += iDmg * BAD_WEAPON_MULTIPLIER
    else
        g_iEnemyDmgBuffer[attacker] += iDmg

    return HC_CONTINUE
}

public OnPlayerKilled(victim, killer, shouldgib)
{
    if (get_pcvar_num(g_cvarManualScoring)) return HC_CONTINUE
    if (g_iMatchState != STATE_LIVE) return HC_CONTINUE

    SettleDamage(victim)

    new bool:bPvP = (killer > 0 && killer <= MAX_PLAYERS && killer != victim)
    if (bPvP) AddScore(victim, SCORE_DEATH)
    g_iMapDeaths[victim]++

    if (killer < 1 || killer > MAX_PLAYERS) return HC_CONTINUE
    if (killer == victim)                    return HC_CONTINUE
    if (GetTeamId(killer) == GetTeamId(victim))
    {
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

    g_iKillStreak[killer]++
    if (g_iKillStreak[killer] >= 2 && g_iKillStreak[killer] <= MAX_KILLSTREAK)
        AddScore(killer, SCORE_KILLSTREAK*g_iKillStreak[killer])
    else if(g_iKillStreak[killer] > MAX_KILLSTREAK)
        AddScore(killer, SCORE_KILLSTREAK*MAX_KILLSTREAK)


    if (LongshotDist[iWpnClass] > 0)
    {
        new Float:vK[3], Float:vV[3]
        pev(killer, pev_origin, vK)
        pev(victim, pev_origin, vV)
        if (vector_distance(vK, vV) >= float(LongshotDist[iWpnClass]))
            AddScore(killer, SCORE_LONGSHOT)
    }

    if (get_pcvar_num(g_cvarDebug)) client_print(killer, print_console, "[CSR] Score:%d Streak:%d RoundScore:%d/%d", g_iMatchScore[killer], g_iKillStreak[killer], g_iRoundScoreEarned[killer], g_iEffectiveScoreCap)

    return HC_CONTINUE
}

public OnBombPlanted(planter)
{
    if (g_iMatchState != STATE_LIVE) return HC_CONTINUE
    AddScore(planter, SCORE_PLANT)
    return HC_CONTINUE
}

public OnBombDefused(defuser)
{
    if (g_iMatchState != STATE_LIVE) return HC_CONTINUE
    AddScore(defuser, SCORE_DEFUSE)
    return HC_CONTINUE
}

GetPlayerFromLogArg()
{
    new szBuf[128]
    read_logargv(0, szBuf, charsmax(szBuf))
    new iAngle = contain(szBuf, "<")
    if (iAngle == -1) return 0
    new szUid[8]
    copyc(szUid, charsmax(szUid), szBuf[iAngle + 1], '>')
    return find_player("k", str_to_num(szUid))
}

public OnHostageRescued()
{
    if (g_iMatchState != STATE_LIVE) return
    new id = GetPlayerFromLogArg()
    if (id < 1 || !is_user_alive(id)) return
    AddScore(id, SCORE_HOSTAGE_RESCUE)
}

public OnHostageKilled()
{
    if (g_iMatchState != STATE_LIVE) return
    new id = GetPlayerFromLogArg()
    if (id < 1) return
    AddScore(id, SCORE_HOSTAGE_KILL)
}

public OnMapEnd()
{
    if (g_iEndReason == END_CANCELLED || g_bResultsDone)
        return

    new iPrevState = g_iMatchState
    if (iPrevState == STATE_WAITING || iPrevState == STATE_WARMUP || iPrevState == STATE_STARTING || iPrevState == STATE_ENDED || iPrevState == STATE_LOCKED)
        return

    new iWinLimit  = get_cvar_num("mp_winlimit")
    new iMaxRounds = get_cvar_num("mp_maxrounds")
    new iTimeLimit = get_cvar_num("mp_timelimit")
    new bool:bWinLimitHit  = (iWinLimit  > 0 && (g_iTeamRounds[TEAM_T_ID] >= iWinLimit || g_iTeamRounds[TEAM_CT_ID] >= iWinLimit))
    new bool:bMaxRoundsHit = (iMaxRounds > 0 && (g_iTeamRounds[TEAM_T_ID] + g_iTeamRounds[TEAM_CT_ID]) >= iMaxRounds)
    new bool:bTimeLimitHit = (iTimeLimit > 0 && get_timeleft() <= 0)

    if (bWinLimitHit || bMaxRoundsHit || bTimeLimitHit)
        ScheduleResults(END_NATURAL)
    else
        SetMatchState(STATE_PAUSED)

    if (get_pcvar_num(g_cvarDebug))
        log_amx("[CSR] OnMapEnd: state=%d minutes=%d win=%d rounds=%d time=%d", iPrevState, g_iTotalMinutes, bWinLimitHit, bMaxRoundsHit, bTimeLimitHit)
}

ScheduleResults(iReason)
{
    if (g_bResultsDone || g_bCalcPending)
        return

    g_iEndReason = iReason
    g_bCalcPending = true
    SetMatchState(STATE_LOCKED)
    remove_task(TASK_MAP_END)
    set_task(1.5, "Task_MapEnd", TASK_MAP_END)
}

ApplyMatchWinBonus(bool:bForcedScore)
{
    if (bForcedScore) return
    if (get_pcvar_num(g_cvarManualScoring)) return
    new iBonus = get_pcvar_num(g_cvarMatchwin)
    if (iBonus <= 0) return
    new iWinningTeam = 0
    if (g_iTeamRounds[TEAM_CT_ID] > g_iTeamRounds[TEAM_T_ID]) iWinningTeam = TEAM_CT_ID
    else if (g_iTeamRounds[TEAM_T_ID] > g_iTeamRounds[TEAM_CT_ID]) iWinningTeam = TEAM_T_ID
    if (iWinningTeam == 0) return
    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        if (g_iMinuteJoined[id] < 0 || !is_user_connected(id)) continue
        if (GetTeamId(id) == iWinningTeam) g_iMatchScore[id] += iBonus
    }
}

BuildQualifierList(iMatch[], bool:bIsParticipant[], Float:fAvgScore[], Float:fParticipation[], iMinMinutes, bool:bForcedScore)
{
    new iQualNum = 0
    for (new id = 1; id <= MAX_SLOTS; id++)
    {
        if (!bIsParticipant[id] || g_iTotalMinutes - g_iMinuteJoined[id] < iMinMinutes || g_iMinuteJoined[id] < 0 || g_iTotalMinutes <= 0) continue

        new iInMatch = clamp(g_iTotalMinutes - g_iMinuteJoined[id], 1, g_iTotalMinutes)
        fParticipation[id] = floatclamp(float(iInMatch) / float(g_iTotalMinutes), 0.0, 1.0)

        if (get_pcvar_num(g_cvarManualScoring))
        {
            fAvgScore[id] = float(g_iMatchScore[id])
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Qual(manual): %s Score=%d", g_szSteamID[id], g_iMatchScore[id])
            iMatch[iQualNum++] = id
            continue
        }

        if (bForcedScore)
        {
            new iValidScore = (id > MAX_PLAYERS) ? 0 : g_iMatchScore[id]

            fAvgScore[id] = float(iValidScore) / float(iInMatch)
            if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Qual(forced): %s Score=%d SPM=%.2f", g_szSteamID[id], iValidScore, fAvgScore[id])
            iMatch[iQualNum++] = id
            continue
        }

        fAvgScore[id] = float(g_iMatchScore[id]) / float(iInMatch)
        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Qual: %s Minutes=%d Score=%d SPM=%.2f", g_szSteamID[id], iInMatch, g_iMatchScore[id], fAvgScore[id])

        // Apply presence modifier
        if      (fParticipation[id] < 0.50) fAvgScore[id] *= 0.8
        else if (fParticipation[id] < 0.65) fAvgScore[id] *= 0.9
        else if (fParticipation[id] < 0.80) fAvgScore[id] *= 1.0
        else if (fParticipation[id] < 0.90) fAvgScore[id] *= 1.1
        else                                fAvgScore[id] *= 1.2

        // Apply KDRatio modifier
        new Float:fKDRatio = 0.0
        if (g_iMapDeaths[id] > 0) fKDRatio = float(g_iMapKills[id]) / float(g_iMapDeaths[id])
        else fKDRatio = float(g_iMapKills[id])

        if      (fKDRatio < 0.5)            fAvgScore[id] *= 0.8
        else if (fKDRatio < 1.0)            fAvgScore[id] *= 0.9
        else if (fKDRatio < 1.5)            fAvgScore[id] *= 1.0
        else if (fKDRatio < 2.0)            fAvgScore[id] *= 1.1
        else                                fAvgScore[id] *= 1.2

        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] %s Presence=%.0f%% KDRatio=%.2f SPMupdate=%.2f", g_szSteamID[id], fParticipation[id] * 100.0, fKDRatio, fAvgScore[id])

        iMatch[iQualNum++] = id
    }
    return iQualNum
}

SortQualifiers(iPlayers[], iNum, Float:fAvgScore[])
{
    for (new i = 1; i < iNum; i++)
    {
        new key = iPlayers[i]
        new j   = i - 1
        while (j >= 0 && fAvgScore[iPlayers[j]] < fAvgScore[key])
        {
            iPlayers[j + 1] = iPlayers[j]
            j--
        }
        iPlayers[j + 1] = key
    }
}

CalcMMR(iPlayers[], iNum, iOutcome[], Float:fParticipation[], iNewPoints[])
{
    new iIdealPlayers = get_pcvar_num(g_cvarIdealPlayers)
    for (new i = 0; i < iNum; i++)
    {
        new id      = iPlayers[i]
        new iMyRank = GetPlayerRank(g_iPoints[id])
        new bool:bPlace = IsPlacement(id)

        new Float:fTotal = 0.0
        new iBeaten = 0
        new iBattles = 0
        for (new j = 0; j < iNum; j++)
        {
            new opp = iPlayers[j]
            if (opp == id || iOutcome[id] == iOutcome[opp]) continue

            iBattles++
            if (iOutcome[opp] > iOutcome[id]) iBeaten++

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

        if (iBattles > 0) fTotal /= float(iBattles)
        if (bPlace) fTotal *= 2.0 // Placement match
        fTotal *= fParticipation[id]
        if (iNum < iIdealPlayers) fTotal *= (float(iNum) / float(iIdealPlayers))

        new iChange = floatround(fTotal, floatround_floor)

        // long-match multiplier.
        if (g_iTotalMinutes - g_iMinuteJoined[id] > get_pcvar_num(g_cvarLongmatch))
            iChange = floatround(float(iChange) * 1.25, floatround_floor)

        // shield
        new iPreShield = iChange
        new iLossPct = 100
        if (!bPlace && iChange < 0)
        {
            iLossPct = (iMyRank < RANK_COUNT) ? LossTakenPct[iMyRank] : 100
            iChange = (iChange * iLossPct) / 100
        }

        // large-lobby bonus
        if (iNum > iIdealPlayers) iChange += iBeaten

        // loyalty bonus
        new iLoyalty = 0
        if (get_pcvar_num(g_cvarLoyaltyBonus))
        {
            iLoyalty = (g_iMapsPlayed[id] + 1) / 20
            iChange += iLoyalty
        }

        // double gain
        if (iChange > 0 && get_pcvar_num(g_cvarDoubleGain) == 1)
            iChange *= 2

        // hard cap.
        new iDouble
        if(bPlace) iDouble = 2
        else iDouble = 1
        iChange = clamp(iChange, MMR_MAX_LOSE*iDouble, MMR_MAX_GAIN*iDouble)

        new iFloor = bPlace ? 0 : g_iPeakPoints[id] / 2
        iNewPoints[id] = clamp(g_iPoints[id] + iChange, iFloor, MMR_CAP)

        if (get_pcvar_num(g_cvarDebug))
            log_amx("[CSR] MMR %s rank=%d place=%d battles=%d presence=%.2f raw=%.2f preShield=%d lossPct=%d loyalty=%d final=%d",
                g_szSteamID[id], iMyRank, bPlace ? 1 : 0, iBattles, fParticipation[id], fTotal, iPreShield, iLossPct, iLoyalty, iChange)
    }
}

GetPlayerDisplayName(id, szOut[], iOutLen)
{
    if (is_user_connected(id))
        get_user_name(id, szOut, iOutLen)
    else if (g_szName[id][0] != EOS)
        copy(szOut, iOutLen, g_szName[id])
    else
        copy(szOut, iOutLen, g_szSteamID[id])
}

BuildAndApplyResults(iPlayers[], iNum, iOutcome[], iNewPoints[], Float:fAvgScore[], Float:fParticipation[], bool:bIsParticipant[])
{
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
    _H("<th class='pos'>#</th><th>NICK</th><th>PRESENCE</th><th>CHANGE</th><th>MMR</th><th class='rk'>RANK</th>")
    _H("</tr></thead><tbody>")

    for (new i = 0; i < iNum; i++)
    {
        new id       = iPlayers[i]
        new iOld     = g_iPoints[id]
        new iNew     = iNewPoints[id]
        new iNewRank = GetPlayerRank(iNew)
        new iDiff    = iNew - iOld
        new bool:bPlacement = IsPlacement(id)

        g_iPoints[id] = iNew
        g_iMapsPlayed[id]++

        new szName[32]
        GetPlayerDisplayName(id, szName, charsmax(szName))

        log_amx("[CSR] Result #%d: %s (%s) MatchScore=%d SPM=%.2f MMR=%d->%d Change=%d Rank=%s Presence=%.0f%% Maps=%d",
            iOutcome[id], szName, g_szSteamID[id], g_iMatchScore[id], fAvgScore[id],
            iOld, iNew, iDiff, RankNamesShort[iNewRank],
            fParticipation[id] * 100.0, g_iMapsPlayed[id])

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
            formatex(szDiffCell, charsmax(szDiffCell), "<td class='pl'>Placement %d/%d</td>", g_iMapsPlayed[id], PLACEMENT_MAPS)
        else if (iNewRank > iOldRank)
            formatex(szDiffCell, charsmax(szDiffCell), "<td class='up'>+%d <span class='ru'>&#8679; +RANK</span></td>", iDiff)
        else if (iNewRank < iOldRank)
            formatex(szDiffCell, charsmax(szDiffCell), "<td class='dn'>%d <span class='rd'>&#8681; -RANK</span></td>", iDiff)
        else if (iDiff > 0)
            formatex(szDiffCell, charsmax(szDiffCell), "<td class='up'>+%d</td>", iDiff)
        else if (iDiff < 0)
            formatex(szDiffCell, charsmax(szDiffCell), "<td class='dn'>%d</td>", iDiff)
        else
            formatex(szDiffCell, charsmax(szDiffCell), "<td>--</td>")

        if (bPlacement)
            formatex(szTmp, charsmax(szTmp),
                "<tr>%s<td>%s</td><td>%.0f%%</td>%s<td class='pl'>??</td><td class='rk pl'>??</td></tr>",
                szPosCell, szName, fParticipation[id] * 100.0, szDiffCell)
        else
            formatex(szTmp, charsmax(szTmp),
                "<tr>%s<td>%s</td><td>%.0f%%</td>%s<td class='MMR'>%d</td><td class='rk'>%s</td></tr>",
                szPosCell, szName, fParticipation[id] * 100.0, szDiffCell,
                iNew, RankNamesShort[iNewRank])
        _H(szTmp)
    }

    _H("</tbody></table></body></html>")

    copy(g_szResultsHTML, charsmax(g_szResultsHTML), szHTML)

    DB_SaveAll(iPlayers, iNum, bIsParticipant)

    g_szTopHTML[0] = EOS
    remove_task(TASK_REFRESH_POS)
    set_task(2.0, "Task_RefreshPositions", TASK_REFRESH_POS)
}

public Task_RefreshPositions()
{
    for (new id = 1; id <= MAX_PLAYERS; id++)
    {
        if (!is_user_connected(id) || is_user_bot(id) || g_szSteamID[id][0] == EOS)
            continue
        g_iGlobalPos[id] = GetGlobalPosition(id)
    }

    BuildTopHTML()
}

public Task_ShowResultsMOTD()
{
    new szMotd[512]
    BuildKarlibIframe("csr_results", szMotd, charsmax(szMotd))

    new players[32], iNum
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
}

public Task_MapEnd()
{
    remove_task(TASK_MAP_END)
    g_bCalcPending = false

    if (g_iEndReason == END_CANCELLED || g_bResultsDone)
    {
        ResetMapData()
        g_iEndReason = END_NONE
        return
    }

    new iPrevState = g_iMatchState
    if (iPrevState == STATE_WARMUP || iPrevState == STATE_STARTING || iPrevState == STATE_WAITING)
    {
        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Map end ignored: minutes=%d prevstate=%d", g_iTotalMinutes, iPrevState)
        ResetMapData()
        g_iEndReason = END_NONE
        return
    }

    CalculateResults(false)
}

CalculateResults(bool:bForcedScore)
{
    if (g_bResultsDone)
        return

    if (g_iMatchState == STATE_WAITING || g_iMatchState == STATE_WARMUP || g_iMatchState == STATE_STARTING)
    {
        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Results ignored: state=%d", g_iMatchState)
        return
    }

    g_bResultsDone = true
    g_bCalcPending = false

    for (new id = 1; id <= MAX_SLOTS; id++)
        if (g_iMinuteJoined[id] >= 0 && g_szSteamID[id][0] != EOS)
            SettleDamage(id, true)

    ApplyMatchWinBonus(bForcedScore)

    new bool:bIsParticipant[MAX_SLOTS + 1]
    for (new id = 1; id <= MAX_SLOTS; id++)
        if (g_iMinuteJoined[id] >= 0 && g_szSteamID[id][0] != EOS)
            bIsParticipant[id] = true

    new Float:fAvgScore[MAX_SLOTS + 1]
    new Float:fParticipation[MAX_SLOTS + 1]
    new iQualPlayers[MAX_SLOTS + 1]
    new iMinMinutes = bForcedScore ? 1 : get_pcvar_num(g_cvarMinMinutes)

    new iQualNum = BuildQualifierList(iQualPlayers, bIsParticipant, fAvgScore, fParticipation, iMinMinutes, bForcedScore)

    new iMinPlayers = get_pcvar_num(g_cvarMinPlayers)
    if (iMinPlayers < 2) iMinPlayers = 2
    if (iQualNum < iMinPlayers)
    {
        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] Not enough: %d<%d MinMinutes=%d", iQualNum, iMinPlayers, iMinMinutes)
        client_print_color(0, print_team_default, "%L", LANG_PLAYER, "RANK_NOT_ENOUGH", iQualNum, iMinPlayers)
        DB_SaveAll(iQualPlayers, 0, bIsParticipant)
        ResetMapData()
        g_iEndReason = END_NONE
        SetMatchState(STATE_LOCKED)
        return
    }

    new iHumanQual = 0
    for (new i = 0; i < iQualNum; i++)
        if (!g_bBot[iQualPlayers[i]])
            iHumanQual++

    if (iHumanQual < 1)
    {
        if (get_pcvar_num(g_cvarDebug)) log_amx("[CSR] No qualified humans; skipping bot-only MMR.")
        client_print_color(0, print_team_default, "%L", LANG_PLAYER, "RANK_NOT_ENOUGH", iHumanQual, 1)
        DB_SaveAll(iQualPlayers, 0, bIsParticipant)
        ResetMapData()
        g_iEndReason = END_NONE
        SetMatchState(STATE_LOCKED)
        return
    }

    SortQualifiers(iQualPlayers, iQualNum, fAvgScore)

    new iOutcome[MAX_SLOTS + 1]
    new iPos = 1
    for (new i = 0; i < iQualNum; i++)
    {
        new id = iQualPlayers[i]
        if (i > 0 && fAvgScore[id] != fAvgScore[iQualPlayers[i - 1]])
            iPos = i + 1
        iOutcome[id] = iPos
    }

    DB_BulkLoadPlayers(iQualPlayers, iQualNum)

    new iNewPoints[MAX_SLOTS + 1]
    CalcMMR(iQualPlayers, iQualNum, iOutcome, fParticipation, iNewPoints)
    BuildAndApplyResults(iQualPlayers, iQualNum, iOutcome, iNewPoints, fAvgScore, fParticipation, bIsParticipant)

    remove_task(TASK_SHOW_MOTD)
    set_task(1.5, "Task_ShowResultsMOTD", TASK_SHOW_MOTD)

    ResetMapData()
    g_iEndReason = END_NONE
    SetMatchState(STATE_LOCKED)
}

// ADMIN COMMANDS
public CmdRankAdjust(id, level, cid)
{
    if (!cmd_access(id, level, cid, 3)) return PLUGIN_HANDLED

    new szSteamID[35], szAmount[16]
    read_argv(1, szSteamID, charsmax(szSteamID))
    read_argv(2, szAmount,  charsmax(szAmount))

    new iAmount = str_to_num(szAmount)

    new players[32], iNum
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
    if (g_hSQL == Empty_Handle)
    {
        console_print(id, "[CSR] No DB connection.")
        return PLUGIN_HANDLED
    }

    new szSafeSteam[70]
    SQL_QuoteString(g_hSQL, szSafeSteam, charsmax(szSafeSteam), szSteamID)

    formatex(szQ, charsmax(szQ),
        "UPDATE csr_players SET points=MAX(0,MIN(%d,points+(%d))) \
         WHERE steamid='%s' AND season=%d",
        MMR_CAP, iAmount, szSafeSteam, g_iCurrentSeason)
    DB_AsyncQuery(szQ)
    console_print(id, "[CSR] Queued DB adjustment of %d for %s", iAmount, szSteamID)
    log_amx("[CSR] Admin %n adjusted %s by %d MMR", id, szSteamID, iAmount)
    return PLUGIN_HANDLED
}

public CmdRankRecalc(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED

    if (g_iMatchState == STATE_WAITING || g_iMatchState == STATE_WARMUP || g_iMatchState == STATE_STARTING)
    {
        console_print(id, "[CSR] No active match to calculate.")
        return PLUGIN_HANDLED
    }

    console_print(id, "[CSR] Forcing map-end calculation...")
    client_print_color(0, print_team_default, "%L", LANG_PLAYER, "ADMIN_FORCE_RECALC")
    CalculateResults(false)
    return PLUGIN_HANDLED
}

public CmdRankCancel(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED

    remove_task(TASK_MAP_END)
    g_bCalcPending = false
    g_bResultsDone = true
    g_iEndReason = END_CANCELLED
    SetMatchState(STATE_LOCKED)
    ResetMapData()

    console_print(id, "[CSR] Match manually cancelled. No MMR will be calculated.")
    log_amx("[CSR] Admin %n manually cancelled the match.", id)
    return PLUGIN_HANDLED
}

public CmdRankStatus(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED

    new const szStateNames[][] = { "WAITING","WARMUP","STARTING","LIVE","PAUSED","ENDED","LOCKED" }
    console_print(id, "[CSR] State:%s Minutes:%d CT:%d T:%d",
        szStateNames[g_iMatchState], g_iTotalMinutes, g_iTeamRounds[TEAM_CT_ID], g_iTeamRounds[TEAM_T_ID])

    new players[32], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum; i++)
    {
        new pid = players[i]
        if (is_user_bot(pid)) continue
        new szName[32]
        get_user_name(pid, szName, charsmax(szName))
        new iPlayed = (g_iMinuteJoined[pid] >= 0) ? (g_iTotalMinutes - g_iMinuteJoined[pid]) : 0
        new Float:fAvg = (iPlayed > 0) ? float(g_iMatchScore[pid]) / float(iPlayed) : 0.0
        console_print(id, "  %s [%s] Score:%d Avg:%.2f Played:%d min K/D:%d/%d",
            szName, g_szSteamID[pid], g_iMatchScore[pid], fAvg,
            iPlayed, g_iMapKills[pid], g_iMapDeaths[pid])
    }
    return PLUGIN_HANDLED
}

public CmdRankNewSeason(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED

    if (g_hSQL == Empty_Handle)
    {
        console_print(id, "[CSR] No DB connection.")
        return PLUGIN_HANDLED
    }

    if (g_iMatchState == STATE_LIVE || g_iMatchState == STATE_PAUSED)
    {
        console_print(id, "[CSR] A match is currently live. Run amx_rank_recalc or amx_rank_cancel first.")
        return PLUGIN_HANDLED
    }

    new szLabel[32]
    if (read_argc() >= 2) read_args(szLabel, charsmax(szLabel))
    else                  formatex(szLabel, charsmax(szLabel), "Season %d", g_iCurrentSeason + 1)
    remove_quotes(szLabel)

    new szSafeLabel[65]
    SQL_QuoteString(g_hSQL, szSafeLabel, charsmax(szSafeLabel), szLabel)

    new iOldSeason = g_iCurrentSeason
    new iNewSeason = iOldSeason + 1
    new iNow       = get_systime()

    new szQ[512]
    formatex(szQ, charsmax(szQ),
        "UPDATE csr_seasons SET ended_at=%d WHERE season=%d", iNow, iOldSeason)
    DB_AsyncQuery(szQ)

    formatex(szQ, charsmax(szQ),
        "INSERT INTO csr_seasons (season, label, started_at, ended_at) \
         VALUES (%d, '%s', %d, 0)", iNewSeason, szSafeLabel, iNow)
    DB_AsyncQuery(szQ)

    g_iCurrentSeason = iNewSeason

    new players[32], iNum
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

    remove_task(TASK_MAP_END)
    g_bCalcPending = false
    g_bResultsDone = false
    g_iEndReason = END_NONE
    g_szTopHTML[0] = EOS
    g_szResultsHTML[0] = EOS
    SetMatchState(STATE_WAITING)
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
        new szLabel[32], szStart[32], szEnd[32]
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
    CalculateResults(true)
    return 1
}

public _native_get_points(plugin, params)
{
    new id = get_param(1)
    if (id < 1 || id > MAX_SLOTS) return 0
    return g_iPoints[id]
}

public _native_add_score(plugin, params)
{
    new id = get_param(1)
    if (id < 1 || id > MAX_SLOTS) return 0
    AddScoreInternal(id, get_param(2))
    return 1
}

public _native_set_score(plugin, params)
{
    new id = get_param(1)
    if (id < 1 || id > MAX_SLOTS) return 0
    g_iMatchScore[id] = get_param(2)
    return 1
}

public _native_get_score(plugin, params)
{
    new id = get_param(1)
    if (id < 1 || id > MAX_SLOTS) return 0
    return g_iMatchScore[id]
}

public _native_get_rank_name(plugin, params)
{
    new id = get_param(1)
    if (id < 1 || id > MAX_SLOTS) return 0
    if (IsPlacement(id))
        set_string(2, "Unranked", get_param(2))
    else
        set_string(2, RankNamesShort[GetPlayerRank(g_iPoints[id])], get_param(2))
    return 1
}

public _native_is_placement(plugin, params)
{
    new id = get_param(1)
    if (id < 1 || id > MAX_SLOTS) return 0
    return IsPlacement(id) ? 1 : 0
}

public _native_get_state(plugin, params)
    return g_iMatchState
