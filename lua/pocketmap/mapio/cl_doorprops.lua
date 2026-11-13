-- Prop doors are models rather than brush faces, so draw them with the same
-- miniature placement as other entity props, using the session's current yaw.
local IO = PocketMap.MapIO
local FRUSTUM_PAD = 5
local PVS_MAX_RADIUS = 2048
local PVS_MAX_LEAVES = 128
local OCCLUSION_PAD = 8
local ZERO_ANGLE = Angle()
-- Loading prepares every sample. A refreshed renderer can briefly see older
-- entries, so bind neutral lighting rather than inheriting another model's state.
local FALLBACK_LIGHT = { direct = {} }
for side = 1, 6 do FALLBACK_LIGHT[side] = { 0.5, 0.5, 0.5 } end
local cvDoorOcclusion = CreateClientConVar( "pocketmap_door_occlusion", "1", true, false,
	"Skip miniature prop doors fully hidden behind BSP walls; checks are spread over frames.", 0, 1 )

local function doorFrustum( mini )
	return PocketMap.Visibility.View( mini, FRUSTUM_PAD )
end

local function inFrustum( entry, view )
	if not view or not entry.blockRadius then return true end
	local center, origin = entry.blockCenter, view.origin
	local dx, dy, dz = center.x - origin.x, center.y - origin.y, center.z - origin.z
	local forward, right, up = view.forward, view.right, view.up
	local distance = dx * forward.x + dy * forward.y + dz * forward.z
	local radius = entry.blockRadius
	local clip = view.clip
	if clip and center:Dot( clip.normal ) + radius < clip.distance then return false end
	if distance + radius < 0 then return false end
	if math.abs( dx * right.x + dy * right.y + dz * right.z ) > distance * view.halfWidth + radius * view.widthRadius then return false end
	if math.abs( dx * up.x + dy * up.y + dz * up.z ) > distance * view.halfHeight + radius * view.heightRadius then return false end
	return true
end

local function doorClusters( bsp, origin, radius )
	if not bsp or not radius or radius > PVS_MAX_RADIUS then return end
	local leaves = bsp:SphereInLeafs( 0, origin, radius + 4 )
	if not leaves or #leaves == 0 or #leaves > PVS_MAX_LEAVES then return end
	local clusters, seen = {}, {}
	for _, leaf in ipairs( leaves ) do
		if not leaf or not leaf.cluster then return end
		if leaf.cluster < 0 then
			if not leaf.contents or bit.band( leaf.contents, 1 ) == 0 then return end
		elseif not seen[leaf.cluster] then
			seen[leaf.cluster] = true
			clusters[#clusters + 1] = leaf.cluster
		end
	end
	if #clusters > 0 then return clusters end
end

local function doorPVS( mini, view )
	local walk = PocketMap.Walk and PocketMap.Walk.session
	if walk and walk.mini == mini then return PocketMap.Visibility.PVS( mini, view ) end
end

local function inPVS( info, pvs )
	if not pvs or not info.clusters then return true end
	if info.checkedPVS ~= pvs then
		info.checkedPVS, info.inPVS = pvs, false
		for _, cluster in ipairs( info.clusters ) do
			if pvs[cluster] then info.inPVS = true break end
		end
	end
	return info.inPVS
end

local function modelRadius( model )
	local mins, maxs = model:GetModelRenderBounds()
	if not mins or not maxs then return end
	local x = math.max( math.abs( mins.x ), math.abs( maxs.x ) )
	local y = math.max( math.abs( mins.y ), math.abs( maxs.y ) )
	local z = math.max( math.abs( mins.z ), math.abs( maxs.z ) )
	local radius = math.sqrt( x * x + y * y + z * z ) + 8
	if radius < math.huge and radius == radius then return radius end
end

-- Model bounds are resolved outside Draw. On some render passes, the model
-- entity temporarily reports no bounds immediately after SetModel.
PocketMap.Hooks.Register( "Think", "PocketMap_DoorBounds", function()
	local walk = PocketMap.Walk and PocketMap.Walk.session
	local mini = walk and walk.mini
	if not mini or mini.mapIODoorBoundsReady then return end
	local cache = mini.mapIODoorRenderBounds
	if not cache then return end
	if ( mini.mapIODoorBoundsAttempts or 0 ) >= 4 then return end
	if ( mini.mapIODoorBoundsNextTry or 0 ) > CurTime() then return end
	mini.mapIODoorBoundsNextTry = CurTime() + 1
	local missing = false
	for path, value in pairs( cache ) do
		if not value then
			local model = ClientsideModel( path, RENDERGROUP_OTHER )
			if IsValid( model ) then
				model:SetNoDraw( true )
				local mins, maxs = model:GetModelRenderBounds()
				if mins and maxs then cache[path] = { mins = mins, maxs = maxs }
				else missing = true end
				model:Remove()
			else missing = true end
		end
	end
	for _, entry in ipairs( mini.mapIODoorEntries or {} ) do
		entry.renderBounds = cache[entry.path]
	end
	mini.mapIODoorBoundsAttempts = ( mini.mapIODoorBoundsAttempts or 0 ) + 1
	mini.mapIODoorBoundsReady = not missing
end )

-- The model and the BSP leaves around a door's pivot are static until its
-- origin changes. Build this information once, instead of rereading 300+
-- Hammer entities and checking their frusta in every render pass.
local function doorEntries( mini, state, records, model )
	local previous = mini.mapIODoorEntries
	if mini.mapIODoorEntriesSource == records and mini.mapIODoorEntriesModel == model
		and mini.mapIODoorRenderBounds and previous and ( not previous[1] or previous[1].blockCenter ) then
		return mini.mapIODoorEntries
	end

	local boundsByModel = mini.mapIODoorModelBounds or {}
	local renderBounds = mini.mapIODoorRenderBounds or {}
	local entries = {}
	for _, record in ipairs( records ) do
		local path = IO.Value( record.entity, "model" )
		if type( path ) == "string" and path:lower():find( "%.mdl$" ) then
			local radius = boundsByModel[path]
			if radius == nil then
				model:SetModel( path )
				radius = modelRadius( model ) or false
				boundsByModel[path] = radius
			end
			if renderBounds[path] == nil then
				model:SetModel( path )
				local mins, maxs = model:GetModelRenderBounds()
				renderBounds[path] = mins and maxs and { mins = mins, maxs = maxs } or false
			end
			local position = IO.Position( state, record )
			local info = { bsp = mini.bsp, radius = radius,
				origin = Vector( position.x, position.y, position.z ),
				clusters = doorClusters( mini.bsp, position, radius or nil ) }
			entries[#entries + 1] = { record = record, path = path,
				skin = IO.Number( record.entity, "skin", 0 ), radius = radius, info = info,
				renderBounds = renderBounds[path],
				blockCenter = mini:BlockPosition( position ),
				blockRadius = radius and radius * mini.scale or nil }
		end
	end
	mini.mapIODoorModelBounds = boundsByModel
	mini.mapIODoorRenderBounds = renderBounds
	mini.mapIODoorBoundsReady = false
	mini.mapIODoorEntriesSource, mini.mapIODoorEntriesModel = records, model
	mini.mapIODoorEntries = entries
	mini.mapIODoorCandidateSource = nil
	mini.mapIODoorLastPath, mini.mapIODoorLastScale, mini.mapIODoorLastSkin = nil, nil, nil
	return entries
end

local function lightPosition( mini, entry, origin, angles )
	if entry.lightX ~= origin.x or entry.lightY ~= origin.y or entry.lightZ ~= origin.z
		or entry.lightPitch ~= angles.p or entry.lightYaw ~= angles.y or entry.lightRoll ~= angles.r then
		entry.lightX, entry.lightY, entry.lightZ = origin.x, origin.y, origin.z
		entry.lightPitch, entry.lightYaw, entry.lightRoll = angles.p, angles.y, angles.r
		entry.wantedLightAt = mini.propLightSampler:Position( { Origin = origin, Angles = angles }, entry.path )
	end
	return entry.wantedLightAt
end

function IO.PrepareDoorProps( mini )
	if not mini.mapIO or not mini.propLightSampler then return end
	local records = IO.OfClass( mini.mapIO, "prop_door_rotating" )
	if #records == 0 then return end
	if not IsValid( mini.mapIODoorProp ) then
		mini.mapIODoorProp = ClientsideModel( "models/error.mdl", RENDERGROUP_OTHER )
		if not IsValid( mini.mapIODoorProp ) then return end
		mini.mapIODoorProp:SetNoDraw( true )
	end
	local state = mini.mapIO.initial
	local entries = doorEntries( mini, state, records, mini.mapIODoorProp )
	for _, entry in ipairs( entries ) do
		local origin, angles = IO.Position( state, entry.record ), IO.Rotation( state, entry.record )
		lightPosition( mini, entry, origin, angles )
		entry.light = mini.propLightSampler:Of( { Origin = origin, Angles = angles }, entry.path, coroutine.yield )
		entry.lightAt = entry.light.at
		coroutine.yield()
	end
end

-- A door's illumination point often lies on its hinge axis. Rotation then needs
-- no new sample at all. Changed samples cooperate with a shared Think budget.
PocketMap.Hooks.Register( "Think", "PocketMap_DoorLighting", function()
	local deadline = SysTime() + 0.001
	for mini in pairs( PocketMap.Active or {} ) do
		if mini.state == "ready" and IsValid( mini.ent ) and mini.propLightSampler then
			local walk = PocketMap.Walk and PocketMap.Walk.session
			local state = walk and walk.mini == mini and walk.io or mini.mapIO and mini.mapIO.initial
			if state then
				local model = mini.mapIODoorProp
				if not IsValid( model ) and #IO.OfClass( state.world, "prop_door_rotating" ) > 0 then
					model = ClientsideModel( "models/error.mdl", RENDERGROUP_OTHER )
					mini.mapIODoorProp = model
					if IsValid( model ) then model:SetNoDraw( true ) end
				end
				if IsValid( model ) then
					local entries = doorEntries( mini, state, IO.OfClass( state.world, "prop_door_rotating" ), model )
					for _ = 1, #entries do
						local index = ( mini.mapIODoorLightIndex or 0 ) % #entries + 1
						mini.mapIODoorLightIndex = index
						local entry = entries[index]
						local origin, angles = IO.Position( state, entry.record ), IO.Rotation( state, entry.record )
						local at = lightPosition( mini, entry, origin, angles )
						if not entry.lightAt or entry.lightAt ~= at then
							if not entry.lightJob then
								local prop = { LightOrigin = Vector( at.x, at.y, at.z ), Origin = origin, Angles = angles }
								entry.lightJob = coroutine.create( function()
									return mini.propLightSampler:Of( prop, entry.path, coroutine.yield )
								end )
							end
							local ok, light = coroutine.resume( entry.lightJob )
							if not ok then
								entry.lightJob = nil
								ErrorNoHalt( "[PocketMap] Door lighting: " .. tostring( light ) .. "\n" )
							elseif coroutine.status( entry.lightJob ) == "dead" then
								entry.lightJob = nil
								if light.at == entry.wantedLightAt then entry.light, entry.lightAt = light, light.at end
							end
						end
						if SysTime() >= deadline then return end
					end
				end
			end
		end
	end
end )

local function doorBehindWorld( mini, state, entry, eye )
	local bounds = entry.renderBounds
	if not bounds then return false end
	local origin, angles = IO.Position( state, entry.record ), IO.Rotation( state, entry.record )
	local center = LocalToWorld( ( bounds.mins + bounds.maxs ) * 0.5, ZERO_ANGLE, origin, angles )
	local corners = PocketMap.Visibility.BoxCorners( bounds.mins, bounds.maxs, origin, angles, OCCLUSION_PAD )
	return PocketMap.Visibility.Occluded( mini.bsp, eye, center, corners )
end

-- Compute at most one door each frame, after the eye settles. A moving
-- camera draws unverified doors until a new conservative result is ready.
local function updateDoorOcclusion( mini, state, entries, candidates, pvs, view )
	if PocketMap.Water and PocketMap.Water.pass then return nil end
	local enabled = cvDoorOcclusion:GetBool()
	if PocketMap.Settings then enabled = PocketMap.Settings.Compat( mini, "door_occlusion", cvDoorOcclusion ) end
	if not enabled or not pvs or not view or not state then return nil end
	local eye = ( view.origin - mini.boxCenter ) / mini.scale + mini.mapCenter
	local cache = mini.mapIODoorOcclusion
	if not cache or cache.entries ~= entries then
		cache = { entries = entries, generation = 0 }
		mini.mapIODoorOcclusion = cache
	end
	if not cache.eye or cache.eye ~= eye or cache.pvs ~= pvs then
		cache.eye, cache.pvs, cache.nextIndex = eye, pvs, 1
		cache.generation = cache.generation + 1
		cache.nextAt = CurTime() + 0.25
	end
	if cache.nextIndex <= #candidates and CurTime() >= cache.nextAt and cache.frame ~= FrameNumber() then
		cache.frame = FrameNumber()
		local entry = candidates[cache.nextIndex]
		cache.nextIndex = cache.nextIndex + 1
		local position, rotation = IO.Position( state, entry.record ), IO.Rotation( state, entry.record )
		entry.occludedByWorld = doorBehindWorld( mini, state, entry, cache.eye )
		entry.occlusionPosition = Vector( position.x, position.y, position.z )
		entry.occlusionRotation = Angle( rotation.p, rotation.y, rotation.r )
		entry.occlusionGeneration = cache.generation
	end
	return cache
end

local function knownHidden( entry, state, cache )
	if not cache or entry.occlusionGeneration ~= cache.generation or not entry.occludedByWorld then return false end
	local position, rotation = IO.Position( state, entry.record ), IO.Rotation( state, entry.record )
	return entry.occlusionPosition == position and entry.occlusionRotation == rotation
end

-- PVS remains constant while the viewer stays in one BSP cluster. A door
-- rotates around its pivot; a map input changing that pivot invalidates the
-- candidate list via the session's draw revision.
local function doorCandidates( mini, state, entries, pvs )
	local revision = state and state.drawRevision
	if mini.mapIODoorCandidateSource == entries and mini.mapIODoorCandidatePVS == pvs
		and mini.mapIODoorCandidateState == state and mini.mapIODoorCandidateRevision == revision then
		return mini.mapIODoorCandidates
	end

	local candidates = mini.mapIODoorCandidates or {}
	for i = #candidates, 1, -1 do candidates[i] = nil end
	for _, entry in ipairs( entries ) do
		local position = IO.Position( state, entry.record )
		local info = entry.info
		if info.bsp ~= mini.bsp or info.origin:DistToSqr( position ) > 0 then
			info.bsp = mini.bsp
			info.origin = Vector( position.x, position.y, position.z )
			info.clusters = doorClusters( mini.bsp, position, entry.radius or nil )
			info.checkedPVS = nil
			entry.blockCenter = mini:BlockPosition( position )
		end
		if inPVS( info, pvs ) then candidates[#candidates + 1] = entry end
	end
	mini.mapIODoorCandidates = candidates
	mini.mapIODoorCandidateSource, mini.mapIODoorCandidatePVS = entries, pvs
	mini.mapIODoorCandidateState, mini.mapIODoorCandidateRevision = state, revision
	return candidates
end

local function drawEntries( mini, state, candidates, model, frustum, occlusion, lighting, stamp, entPos, entAng, shadowFlags )
	local lastPath, lastScale, lastSkin = mini.mapIODoorLastPath, mini.mapIODoorLastScale, mini.mapIODoorLastSkin
	local drawn, hidden = 0, 0
	for _, entry in ipairs( candidates ) do
		local record = entry.record
		local position = IO.Position( state, record )
		if inFrustum( entry, frustum ) then
			if knownHidden( entry, state, occlusion ) then
				hidden = hidden + 1
			else
				drawn = drawn + 1
				local changed = entry.path ~= lastPath
				if changed then model:SetModel( entry.path ) lastPath = entry.path end
				if changed or mini.scale ~= lastScale then model:SetModelScale( mini.scale, 0 ) lastScale = mini.scale end
				if changed or entry.skin ~= lastSkin then model:SetSkin( entry.skin ) lastSkin = entry.skin end
				-- Source selects the hardware bodygroup separately from the skin.
				-- Reset it for each reused model, including doors without handles.
				model:SetBodygroup( 1, IO.Number( record.entity, "hardware", 0 ) )
				local rotation = IO.Rotation( state, record )
				if not shadowFlags and mini.propLightSampler then
					PocketMap.Props.SetModelLight( lighting, entry.light or FALLBACK_LIGHT, mini.propLightTransform )
				end

				if entry.stamp ~= stamp or entry.origin ~= position or entry.rotation ~= rotation then
					entry.wpos, entry.wang = LocalToWorld( mini:BlockPosition( position ), rotation, entPos, entAng )
					entry.stamp = stamp
					entry.origin = Vector( position.x, position.y, position.z )
					entry.rotation = Angle( rotation.p, rotation.y, rotation.r )
				end
				model:SetPos( entry.wpos )
				model:SetAngles( entry.wang )
				-- Source caches the first bone transform. This model draws many doors.
				model:SetupBones()
				if shadowFlags then model:DrawModel( shadowFlags ) else model:DrawModel() end
			end
		end
	end
	return drawn, hidden, lastPath, lastScale, lastSkin
end

IO.OnDraw( "DoorProps", function( mini, state, translucent, shadowFlags )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "model_doors" ) then return end
	if translucent or not mini.mapIO or not ClientsideModel then return end
	local records = IO.OfClass( mini.mapIO, "prop_door_rotating" )
	if #records == 0 then return end
	if not IsValid( mini.mapIODoorProp ) or not mini.mapIODoorEntries then return end
	local model = mini.mapIODoorProp
	local frustum = not shadowFlags and doorFrustum( mini ) or nil
	local pvs = not shadowFlags and doorPVS( mini, frustum ) or nil
	local entries = mini.mapIODoorEntries
	local candidates = doorCandidates( mini, state, entries, pvs )
	local occlusion = not shadowFlags and updateDoorOcclusion( mini, state, entries, candidates, pvs, frustum ) or nil
	local stamp = mini:UpdateMatrix()
	local entPos, entAng = mini.ent:GetPos(), mini.ent:GetAngles()
	local lighting = {}
	if not shadowFlags and mini.propLightSampler then
		mini.propLightTransform = PocketMap.PropLight.Transform( mini.matrix, mini.propLightTransform )
		render.SuppressEngineLighting( true )
	end
	local ok, drawn, hidden, lastPath, lastScale, lastSkin = pcall( drawEntries,
		mini, state, candidates, model, frustum, occlusion, lighting, stamp, entPos, entAng, shadowFlags )
	if not shadowFlags and mini.propLightSampler then
		render.SetLocalModelLights()
		render.SuppressEngineLighting( false )
	end
	if not ok then
		mini.mapIODoorLastPath, mini.mapIODoorLastScale, mini.mapIODoorLastSkin = nil, nil, nil
		error( drawn, 0 )
	end
	mini.mapIODoorLastPath, mini.mapIODoorLastScale, mini.mapIODoorLastSkin = lastPath, lastScale, lastSkin
	if not shadowFlags then
		mini.mapIODoorsDrawn = drawn
		mini.mapIODoorsOccluded = hidden
	end
end )
