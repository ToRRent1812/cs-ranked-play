#if defined _csr_included
#endinput
#endif

#define _csr_included

#pragma library "csr"

// Get the current points of a player.
native csr_get_points(playerid)

// Get the current rank name of a player.
native csr_get_rank_name(playerid, maxlength)

// Check if a player is in the placement phase.
native csr_is_placement(playerid)

// Get the current state of a match.
native csr_get_state()

// Trigger MMR calculation when gamemode does not have classic win by rounds mechanic (gungame, deathmatch)
native csr_custom_win()

// Get the current match score of the player.
native csr_get_score(playerid)

// Add/Substract match score from the player (like custom conditions, ex: gungame win)
native csr_add_score(playerid, score)


// Set the exact amount of match score for the player (like custom conditions, ex: gungame win)
native csr_set_score(playerid, score)
