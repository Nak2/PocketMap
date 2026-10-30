-- Based on garrysmod/lua/menu/getmaplist.lua (Facepunch Studios, MIT license), moved to the client state.
-- Differences: the pattern list is kept in order, and "^asi-" is "^asi%-" (the original matches every map starting with "as").

PocketMap = PocketMap or {}

-- Lowercase map name or prefix (up to and including the first _) -> group
local function buildNames()
	local names = {}

	local function all( group, list )
		for _, name in ipairs( list ) do names[name] = group end
	end

	names["aoc_"] = "Age of Chivalry"
	names["infra_"] = "INFRA"

	names["lobby"] = "Alien Swarm"

	all( "Blade Symphony", {
		"cp_docks", "cp_parkour", "cp_sequence", "cp_terrace", "cp_test", "duel_", "ffa_community", "free_",
		"practice_box", "tut_training", "lightstyle_test",
	} )

	all( "Counter-Strike", { "ar_", "cs_", "de_", "es_", "fy_", "gd_", "dz_", "training1", "lobby_mapveto" } )

	-- Various custom cs maps
	all( "Counter-Strike (Custom)", { "35hp_", "aim_", "awp_", "am_", "fy_", "1v1_" } )

	names["dod_"] = "Day Of Defeat"
	names["ddd_"] = "Dino D-Day"

	all( "DIPRIP", {
		"de_dam", "dm_city", "dm_refinery", "dm_supermarket", "dm_village",
		"ur_city", "ur_refinery", "ur_supermarket", "ur_village",
	} )

	all( "Dystopia", { "dys_", "pb_dojo", "pb_rooftop", "pb_round", "pb_urbandome", "sav_dojo6", "varena" } )

	-- Done by name, so edits of these maps don't end up in the same group
	all( "Half-Life 2", {
		"d1_trainstation_01", "d1_trainstation_02", "d1_trainstation_03", "d1_trainstation_04", "d1_trainstation_05", "d1_trainstation_06",
		"d1_canals_01", "d1_canals_01a", "d1_canals_02", "d1_canals_03", "d1_canals_05", "d1_canals_06", "d1_canals_07", "d1_canals_08", "d1_canals_09",
		"d1_canals_10", "d1_canals_11", "d1_canals_12", "d1_canals_13", "d1_eli_01", "d1_eli_02",
		"d1_town_01", "d1_town_01a", "d1_town_02", "d1_town_02a", "d1_town_03", "d1_town_04", "d1_town_05",
		"d2_coast_01", "d2_coast_03", "d2_coast_04", "d2_coast_05", "d2_coast_07", "d2_coast_08", "d2_coast_09", "d2_coast_10", "d2_coast_11", "d2_coast_12",
		"d2_prison_01", "d2_prison_02", "d2_prison_03", "d2_prison_04", "d2_prison_05", "d2_prison_06", "d2_prison_07", "d2_prison_08",
		"d3_c17_01", "d3_c17_02", "d3_c17_03", "d3_c17_04", "d3_c17_05", "d3_c17_06a", "d3_c17_06b", "d3_c17_07", "d3_c17_08",
		"d3_c17_09", "d3_c17_10a", "d3_c17_10b", "d3_c17_11", "d3_c17_12", "d3_c17_12b", "d3_c17_13",
		"d3_citadel_01", "d3_citadel_02", "d3_citadel_03", "d3_citadel_04", "d3_citadel_05", "d3_breen_01",
	} )

	all( "Half-Life 2: Episode 1", {
		"ep1_citadel_00", "ep1_citadel_01", "ep1_citadel_02", "ep1_citadel_02b", "ep1_citadel_03", "ep1_citadel_04", "ep1_c17_00",
		"ep1_c17_00a", "ep1_c17_01", "ep1_c17_01a", "ep1_c17_02", "ep1_c17_02b", "ep1_c17_02a", "ep1_c17_05", "ep1_c17_06",
	} )

	all( "Half-Life 2: Episode 2", {
		"ep2_outland_01", "ep2_outland_01a", "ep2_outland_02", "ep2_outland_03", "ep2_outland_04", "ep2_outland_05", "ep2_outland_06", "ep2_outland_06a", "ep2_outland_07",
		"ep2_outland_08", "ep2_outland_09", "ep2_outland_10", "ep2_outland_10a", "ep2_outland_11", "ep2_outland_11a", "ep2_outland_11b", "ep2_outland_12", "ep2_outland_12a",
	} )

	all( "G String", {
		"dragon_girl", "dragon_girl1", "dragon_girl2", "dragon_girl3", "free_mars1", "free_mars2",
		"free_mars3", "hazardous_ai", "hazardous_ai_more", "hazardous_ai0", "hazardous_ai01", "hazardous_ai2", "hazardous_ai3", "hazardous_ai3b", "hazardous_ai4",
		"hazardous_ai5", "hazardous_ai6", "hazardous_ai7", "human_waste_x1", "human_waste1", "human_waste2",
		"human_waste3", "human_waste4", "human_waste5", "human_waste6", "human_waste7", "human_waste8", "human_waste9",
		"lab_rat", "lab_rat1", "money_is_dead", "money_is_dead_1", "money_is_dead0", "money_is_dead2", "money_is_dead2_1", "money_is_dead2_2", "money_is_dead3", "money_is_dead3_2",
		"money_is_dead4", "money_is_dead4_2", "money_is_dead4_3", "murdock_air_x1", "murdock_air_x2", "murdock_air_x3", "murdock_air_x4", "murdock_air_x5",
		"murdock_air_x6", "murdock_air1", "murdock_air2", "murdock_air3", "murdock_air4", "murdock_air5", "murdock_air6", "murdock_air7", "murdock_air8",
		"murdock_air9", "perp_org1", "perp_org2", "perp_org3", "perp_org4", "sabotage", "sabotage1",
		"smog_storm", "smog_storm1", "smog_storm2", "smog_storm3", "space_race", "space_race1",
		"space_race2", "space_race3", "space_race4", "space_race5", "terror_management_x1", "terror_management_x2",
		"terror_management_x3", "the_call1",
	} )

	all( "Insurgency", {
		"buhriz", "buhriz_coop", "buhriz_night", "contact", "contact_coop", "contact_night", "district", "district_coop", "district_night",
		"drycanal", "drycanal_coop", "drycanal_night", "embassy", "embassy_coop", "embassy_night", "heights", "heights_coop", "heights_night",
		"kandagal", "kandagal_night", "market", "market_coop", "market_night", "ministry", "ministry_coop", "ministry_night", "panj", "panj_night",
		"peak", "peak_night", "revolt", "revolt_coop", "revolt_night", "siege", "siege_coop", "sinjar", "sinjar_coop", "sinjar_night", "station",
		"station_night", "tell", "tell_coop", "tell_night", "training", "uprising", "uprising_night", "verticality", "verticality_coop", "verticality_night",
		"ins_",
	} )

	all( "Half-Life 2: Deathmatch", { "dm_", "halls3" } )
	names["d2_lostcoast"] = "Half-Life 2: Lost Coast"

	all( "Half-Life Deathmatch", {
		"boot_camp", "bounce", "crossfire", "datacore", "frenzy", "lambda_bunker", "rapidcore", "snarkpit",
		"stalkyard", "subtransit", "undertow",
	} )

	names["t_"] = "Klaus Veen's Treason"
	names["l4d_"] = "Left 4 Dead"
	all( "Left 4 Dead 2", { "curling_stadium", "tutorial_standards", "tutorial_standards_vs" } )

	all( "Nuclear Dawn", {
		"clocktower", "coast", "downtown", "gate", "hydro", "metro", "metro_training", "oasis", "oilfield", "silo", "sk_metro", "training",
	} )

	all( "Pirates, Vikings, & Knights II", { "bt_", "lts_", "te_", "tw_" } )

	all( "Portal", { "escape_", "testchmb_" } )
	names["e1912"] = "Portal 2"

	all( "Team Fortress 2", {
		"achievement_", "arena_", "cp_", "ctf_", "itemtest", "koth_", "mvm_", "pl_", "plr_", "rd_", "pd_", "sd_",
		"tc_", "tr_", "trade_", "pass_", "vsh_", "zi_", "tow_", "2koth_", "cppl_", "htf_",
	} )

	all( "Zombie Panic! Source", { "zpa_", "zpl_", "zpo_", "zps_", "zph_" } )
	all( "Fistful of Frags", { "fof_", "fofhr_", "cm_", "gt_", "tp_", "vs_" } )

	names["ff_"] = "Fortress Forever"
	names["mcv_"] = "Military Conflict: Vietnam"

	all( "Black Mesa", {
		"dm_boom", "dm_bounce", "dm_chopper", "dm_crossfire", "dm_gasworks", "dm_lambdabunker", "dm_power", "dm_rail", "dm_stack",
		"dm_stalkyard", "dm_subtransit", "dm_undertow", "bm_",
	} )

	names["bhop_"] = "Bunny Hop"
	names["cinema_"] = "Cinema"
	names["theater_"] = "Cinema"
	names["xc_"] = "Climb"
	names["deathrun_"] = "Deathrun"
	names["dr_"] = "Deathrun"
	names["fm_"] = "Flood"
	names["gmt_"] = "GMod Tower"
	names["gg_"] = "Gun Game"
	names["scoutzknivez"] = "Gun Game"
	names["ba_"] = "Jailbreak"
	names["jail_"] = "Jailbreak"
	names["jb_"] = "Jailbreak"
	names["mg_"] = "Minigames"
	names["pw_"] = "Pirate Ship Wars"
	names["ph_"] = "Prop Hunt"
	names["rp_"] = "Roleplay"
	names["slb_"] = "Sled Build"
	names["sb_"] = "Spacebuild"
	names["slender_"] = "Stop it Slender"
	names["gms_"] = "Stranded"
	names["surf_"] = "Surf"
	names["ts_"] = "The Stalker"
	names["zm_"] = "Zombie Survival"
	names["zombiesurvival_"] = "Zombie Survival"
	names["zs_"] = "Zombie Survival"
	names["ze_"] = "Zombie Escape"
	names["coop_"] = "Cooperative"

	return names
end

-- Patterns, tried in this order: { pattern, group }. The patterns of the gamemodes come last, and win.
local function buildPatterns()
	local patterns = {
		{ "^asi%-", "Alien Swarm" },
		{ "^c[%d]a", "Half-Life" },
		{ "^t0a", "Half-Life" },
		{ "^c[%d]m", "Left 4 Dead 2" },
		{ "^c1[%d]m", "Left 4 Dead 2" },
		{ "^mp_coop_", "Portal 2" },
		{ "^sp_a", "Portal 2" },
	}

	for _, gamemode in ipairs( engine.GetGamemodes() or {} ) do
		local title = gamemode.title or "Unnamed Gamemode"
		if isstring( gamemode.maps ) and gamemode.maps ~= "" then
			for _, pattern in ipairs( string.Split( gamemode.maps, "|" ) ) do
				patterns[#patterns + 1] = { string.lower( pattern ), title }
			end
		end
	end

	return patterns
end

-- Maps that are not worth listing
local IGNORE_PATTERNS = { "^background", "^devtest", "^ep1_background", "^ep2_background", "^styleguide" }
local IGNORE_MAPS = {
	-- Prefixes
	["sdk_"] = true, ["test_"] = true, ["vst_"] = true,

	-- Maps
	["c4a1y"] = true, ["credits"] = true, ["d2_coast_02"] = true, ["d3_c17_02_camera"] = true,
	["ep1_citadel_00_demo"] = true, ["c5m1_waterfront_sndscape"] = true, ["intro"] = true, ["test"] = true,
}

local FAVOURITES, OTHER = "Favourites", "Other"
local namesCache, patternsCache

local function readFavourites()
	local favourites = {}
	for _, map in ipairs( string.Split( cookie.GetString( "favmaps", "" ), ";" ) ) do
		if map ~= "" then favourites[string.lower( map )] = true end
	end
	return favourites
end

local function isIgnored( name, prefix )
	if IGNORE_MAPS[name] or ( prefix and IGNORE_MAPS[prefix] ) then return true end

	for _, pattern in ipairs( IGNORE_PATTERNS ) do
		if string.find( name, pattern ) then return true end
	end
	return false
end

---A name or prefix first, then the patterns (an embedded prefix, TTT, Sandbox, ...). The last matching pattern wins.
local function findGroup( name, prefix )
	local group = namesCache[name] or ( prefix and namesCache[prefix] )
	if group then return group end

	for _, entry in ipairs( patternsCache ) do
		if string.find( name, entry[1] ) then group = entry[2] end
	end
	return group or OTHER
end

local function isInGame( name, game )
	return file.Exists( "maps/" .. name .. ".bsp", game )
end

local function rankGroup( group )
	if group == FAVOURITES then return 0 end
	if group == OTHER then return 2 end
	return 1
end

local function sortGroupNames( groups )
	local order = {}
	for group in pairs( groups ) do order[#order + 1] = group end

	table.sort( order, function( a, b )
		if rankGroup( a ) ~= rankGroup( b ) then return rankGroup( a ) < rankGroup( b ) end
		return string.lower( a ) < string.lower( b )
	end )
	return order
end

---Sorts maps into groups.
---@param maps string[] # Map names, without maps/ and .bsp
---@return string[] order # Group names, in the order they are shown: Favourites, the rest by name, Other last
---@return table<string, string[]> groups # Group name -> map names
function PocketMap.GroupMaps( maps )
	namesCache = namesCache or buildNames()
	patternsCache = patternsCache or buildPatterns()

	local favourites = readFavourites()
	local groups = {}
	local function add( group, map )
		groups[group] = groups[group] or {}
		table.insert( groups[group], map )
	end

	for _, map in ipairs( maps ) do
		local name = string.lower( map )
		local prefix = string.match( name, "^(.-_)" )

		if not isIgnored( name, prefix ) then
			local group = findGroup( name, prefix )

			-- Only in CS:GO: a CS:GO map. In both: listed in both.
			local alsoGO = false
			if group == "Counter-Strike" and isInGame( name, "csgo" ) then
				alsoGO = isInGame( name, "cstrike" )
				if not alsoGO then group = "Counter-Strike: GO" end
			end

			add( group, map )
			if favourites[name] then add( FAVOURITES, map ) end
			if alsoGO then add( "Counter-Strike: GO", map ) end
		end
	end

	return sortGroupNames( groups ), groups
end
