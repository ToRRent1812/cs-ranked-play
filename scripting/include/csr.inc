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
