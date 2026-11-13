-- Temporary clientside diagnostic: pin the miniature's BSP PVS to the eye
-- position at which the command was issued. Camera frustum culling still moves.
PocketMap.PVSFreeze = PocketMap.PVSFreeze or {}
local Freeze = PocketMap.PVSFreeze
local HUD_BACKGROUND = Color( 0, 0, 0, 190 )
local HUD_ACCENT = Color( 255, 212, 70 )

local function report( message )
	print( "[PocketMap] " .. message )
	chat.AddText( "[PocketMap] " .. message )
end

function Freeze.Get( mini )
	local state = Freeze.state
	if not state or state.mini ~= mini then return end
	local walk = PocketMap.Walk and PocketMap.Walk.session
	if not walk or walk.mini ~= mini or state.bsp ~= mini.bsp or mini.state ~= "ready" then
		Freeze.state = nil
		return
	end
	return state.pvs
end

concommand.Add( "pocketmap_pvs_freeze", function()
	if Freeze.state then
		Freeze.state = nil
		report( "PVS unfrozen; live visibility restored." )
		return
	end

	local walk = PocketMap.Walk and PocketMap.Walk.session
	local mini = walk and walk.mini
	if not mini or mini.state ~= "ready" or not mini.bsp then
		report( "Enter a loaded PocketMap to freeze its PVS." )
		return
	end

	local eye = walk.move.origin + PocketMap.Walk.EyeOffset( walk )
	local bsp = mini.bsp
	local cluster = bsp:ClusterFromPoint( eye )
	local vis = cluster and cluster >= 0 and bsp:GetVisibility()
	if not vis or not vis.VisData or not vis.VisData[cluster] or bsp:IsVisibilityCorrupted() then
		report( "PVS unavailable at this position (invalid BSP visibility cluster)." )
		return
	end

	-- Keep the already compiled world cache when freezing the current cluster.
	-- A new but equivalent table would unnecessarily start another mesh build.
	local pvs = mini.worldPVSBSP == bsp and mini.worldPVSCluster == cluster and mini.worldPVS
		or bsp:PVSForOrigin( eye )
	if not pvs then
		report( "Could not read the BSP PVS at this position." )
		return
	end

	local count = 0
	for clusterId, visible in pairs( pvs ) do
		if type( clusterId ) == "number" and visible then count = count + 1 end
	end
	Freeze.state = { mini = mini, bsp = bsp, eye = Vector( eye.x, eye.y, eye.z ),
		cluster = cluster, pvs = pvs, clusters = count }
	report( "PVS frozen at cluster " .. cluster .. " (" .. count .. " visible clusters). Walk around to inspect culling; run pocketmap_pvs_freeze again to resume." )
end )

PocketMap.Hooks.Register( "HUDPaint", "PocketMap_PVSFreeze", function()
	local state = Freeze.state
	if not state or not Freeze.Get( state.mini ) then return end

	-- The BSP lookup is useful feedback but needn't run on every rendered frame.
	if RealTime() >= ( state.nextHUDUpdate or 0 ) then
		local walk = PocketMap.Walk.session
		state.liveCluster = state.bsp:ClusterFromPoint( walk.move.origin + PocketMap.Walk.EyeOffset( walk ) )
		state.nextHUDUpdate = RealTime() + 0.15
	end
	local liveCluster = state.liveCluster
	local inPVS = liveCluster and liveCluster >= 0 and state.pvs[liveCluster]
	local mini = state.mini
	local x, y = 28, ScrH() * 0.22
	draw.RoundedBox( 4, x - 10, y - 8, 400, 84, HUD_BACKGROUND )
	draw.SimpleText( "PVS FROZEN  |  cluster " .. state.cluster .. "  |  " .. state.clusters .. " visible clusters", "DermaDefaultBold", x, y, HUD_ACCENT )
	draw.SimpleText( "Current cluster: " .. tostring( liveCluster ) .. "  |  in frozen PVS: " .. ( inPVS and "YES" or "NO" ), "DermaDefault", x, y + 18, color_white )
	draw.SimpleText( "World batches: " .. tostring( mini.worldMeshesDrawn or "?" ) .. "/" .. tostring( mini.worldMeshesTotal or "?" ), "DermaDefault", x, y + 36, color_white )
	draw.SimpleText( "pocketmap_pvs_freeze  to resume live PVS", "DermaDefault", x, y + 54, color_white )
end )
