PocketMap.Walkers = {}

local FALLBACK_MODEL = "models/kleiner.mdl"
local MODEL_SCALE = 1
local STALE_SECONDS = 1
local MAX_EXTRAPOLATION_SECONDS = 0.2
local APPEARANCE_REFRESH_SECONDS = 1
local PLAYER_INDEX_BITS = 8
local IDLE_SPEED = 10
local RUN_SPEED = 260
local MIN_PLAYBACK_RATE, MAX_PLAYBACK_RATE = 0.2, 3

local walkers = {}
local selfWalker = {}

local function removeModel( walker )
	if IsValid( walker.model ) then walker.model:Remove() end
	walker.model, walker.modelPath, walker.sequence = nil, nil, nil
end

local function removeWalker( index )
	local walker = walkers[index]
	if not walker then return end

	removeModel( walker )
	walkers[index] = nil
end

local function storeWalker( index, block, velocity, position, angles )
	local walker = walkers[index] or { index = index }
	walker.block, walker.velocity, walker.position, walker.angles, walker.receivedAt = block, velocity, position, angles, RealTime()
	walkers[index] = walker
end

local function playerOf( walker )
	local ply = Entity( walker.index )
	return IsValid( ply ) and ply:IsPlayer() and ply or nil
end

local function modelPathOf( ply )
	local path = ply and ply:GetModel()
	if path and path ~= "" and util.IsValidModel( path ) then return path end
	return FALLBACK_MODEL
end

local function createModel( walker, path )
	local model = ClientsideModel( path )
	if not IsValid( model ) then return end

	model:SetNoDraw( true )
	model.GetPlayerColor = function() return walker.playerColor or vector_origin end
	walker.model, walker.modelPath, walker.sequence = model, path, nil
	return model
end

local function modelOf( walker, ply )
	local path = modelPathOf( ply )
	if IsValid( walker.model ) and walker.modelPath == path then return walker.model end

	removeModel( walker )
	return createModel( walker, path )
end

local function copyAppearance( walker, model, ply, now )
	if not ply or ( walker.nextAppearance or 0 ) > now then return end
	walker.nextAppearance = now + APPEARANCE_REFRESH_SECONDS

	model:SetSkin( ply:GetSkin() )
	for group = 0, ply:GetNumBodyGroups() - 1 do model:SetBodygroup( group, ply:GetBodygroup( group ) ) end
	walker.playerColor = ply:GetPlayerColor()
end

local function activityFor( speed )
	if speed < IDLE_SPEED then return ACT_HL2MP_IDLE end
	return speed < RUN_SPEED and ACT_HL2MP_WALK or ACT_HL2MP_RUN
end

local function playbackRateFor( model, sequence, speed )
	local groundSpeed = model:GetSequenceGroundSpeed( sequence )
	if speed < IDLE_SPEED or groundSpeed <= 0 then return 1 end
	return math.Clamp( speed / groundSpeed, MIN_PLAYBACK_RATE, MAX_PLAYBACK_RATE )
end

local function animate( walker, model, speed, now )
	local sequence = model:SelectWeightedSequence( activityFor( speed ) )
	if sequence < 0 then return end

	if walker.sequence ~= sequence then
		model:ResetSequence( sequence )
		walker.sequence = sequence
	end

	local duration = model:SequenceDuration( sequence )
	local elapsed = now - ( walker.lastAnimated or now )
	walker.lastAnimated = now
	walker.phase = ( ( walker.phase or 0 ) + ( duration > 0 and elapsed * playbackRateFor( model, sequence, speed ) / duration or 0 ) ) % 1

	model:SetCycle( walker.phase )
	model:SetPoseParameter( "move_x", speed < IDLE_SPEED and 0 or 1 )
	model:SetPoseParameter( "move_y", 0 )
end

local function clampedToMap( mini, position )
	local mins, maxs = mini.mapMins, mini.mapMaxs
	return Vector( math.Clamp( position.x, mins.x, maxs.x ), math.Clamp( position.y, mins.y, maxs.y ), math.Clamp( position.z, mins.z, maxs.z ) )
end

local function worldPosition( walker, mini, now )
	local elapsed = math.min( now - walker.receivedAt, MAX_EXTRAPOLATION_SECONDS )
	local mapPosition = clampedToMap( mini, walker.position + walker.velocity * elapsed )
	return walker.block:LocalToWorld( ( mapPosition - mini.mapCenter ) * mini.scale + mini.boxCenter )
end

local function facingYaw( walker, speed )
	if speed < IDLE_SPEED then return walker.angles.y end
	return math.deg( math.atan2( walker.velocity.y, walker.velocity.x ) )
end

local function drawWalker( walker, now )
	local block = walker.block
	local mini = block.Miniature
	if not mini or mini.state ~= "ready" then return end

	local ply = playerOf( walker )
	local model = modelOf( walker, ply )
	if not model then return end

	local speed = walker.velocity:Length2D()
	copyAppearance( walker, model, ply, now )
	animate( walker, model, speed, now )

	local position = worldPosition( walker, mini, now )
	model:SetModelScale( mini.scale * MODEL_SCALE )
	model:SetPos( position )
	model:SetAngles( block:LocalToWorldAngles( Angle( 0, facingYaw( walker, speed ), 0 ) ) )
	model:DrawModel()
end

local function isStale( walker, now )
	return now - walker.receivedAt > STALE_SECONDS or not IsValid( walker.block )
end

local function isViewingThroughAnotherEntityWhileWalking()
	local walk = PocketMap.Walk
	return walk ~= nil and walk.session ~= nil and LocalPlayer():GetViewEntity() ~= LocalPlayer()
end

local function drawSelf( now )
	if not isViewingThroughAnotherEntityWhileWalking() then return removeModel( selfWalker ) end

	local session = PocketMap.Walk.session
	local move = session.move
	selfWalker.index, selfWalker.block = LocalPlayer():EntIndex(), session.mini.ent
	selfWalker.velocity, selfWalker.position, selfWalker.angles, selfWalker.receivedAt = move.velocity, move.origin, move.angles, now
	if IsValid( selfWalker.block ) then drawWalker( selfWalker, now ) end
end

local function drawWalkers( drawingDepth, drawingSkybox )
	if drawingDepth or drawingSkybox then return end

	local now = RealTime()
	for index, walker in pairs( walkers ) do
		if isStale( walker, now ) then
			removeWalker( index )
		else
			drawWalker( walker, now )
		end
	end

	drawSelf( now )
end

net.Receive( "PocketMap_PlyRelay", function()
	local index, block, active = net.ReadUInt( PLAYER_INDEX_BITS ), net.ReadEntity(), net.ReadBool()
	if not active then return removeWalker( index ) end

	local velocity, position, angles = net.ReadVector(), net.ReadVector(), net.ReadAngle()
	if index ~= LocalPlayer():EntIndex() and IsValid( block ) then storeWalker( index, block, velocity, position, angles ) end
end )

PocketMap.Hooks.Register( "PostDrawOpaqueRenderables", "PocketMap_Walkers", drawWalkers )
