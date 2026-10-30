AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local ORIGIN_HEIGHT_ABOVE_FLOOR = 24
local MAX_REACH_SQR = 400 * 400
local MAX_NAME_LENGTH = 64
local SELECT_COOLDOWN = 1
local BLOCK_CHANGE_COOLDOWN = 3
local USE_COOLDOWN = 0.25

local WALK_UPDATE_INTERVAL = 0.04
local WALK_REACH_SQR = 600 * 600
local WALK_RELAY_RANGE_SQR = 1500 * 1500
local WALK_RECIPIENT_REFRESH_SECONDS = 0.5
local WALK_LEAVE_GRACE_SECONDS = 0.25
local WALK_STALE_SECONDS = 1.5
local WALK_STALE_CHECK_SECONDS = 0.5
local WALK_BOUNDS_MARGIN = 64
local MAX_WALK_COORDINATE = 32768
local MAX_WALK_SPEED = 10000
local WALKER_ID = "PocketMap_Walkers"

local walkers = {}
local stopWalkersOn

local cvAdminOnly = CreateConVar( "pocketmap_adminonly", "0", FCVAR_ARCHIVE, "1 = only admins can change the map of a block.", 0, 1 )

---@return boolean # false while the player is still waiting out the last time this was done
local function tryStartCooldown( ply, field, delay )
	local now = CurTime()
	if ( ply[field] or 0 ) > now then return false end

	ply[field] = now + delay
	return true
end

local function isValidMapName( name )
	if name == "" then return true end
	if #name > MAX_NAME_LENGTH then return false end

	return string.match( name, "^[%w_%-][%w_%-%.]*$" ) ~= nil
end

local function isWithinReach( ply, ent )
	local eye = ply:EyePos()
	return ent:NearestPoint( eye ):DistToSqr( eye ) <= MAX_REACH_SQR
end

local function isPocketMap( ent )
	return IsValid( ent ) and ent:GetClass() == "ent_pocketmap"
end

---Other addons can refuse a change (prop protection, gamemode rules) by returning false from PocketMap_CanSelect.
local function mayChangeMap( ply, ent, name )
	if not ply:Alive() then return false end
	if cvAdminOnly:GetBool() and not ply:IsAdmin() then return false end

	return hook.Run( "PocketMap_CanSelect", ply, ent, name ) ~= false
end

function ENT:SpawnFunction( ply, tr, class )
	if not tr.Hit then return end
	if not NikNaks or NikNaks.Version < 0.975 then
		ply:ChatPrint( "[PocketMap] This addon needs an up to date NikNaks." )
		return
	end

	local ent = ents.Create( class )
	ent:SetPos( tr.HitPos + tr.HitNormal * ORIGIN_HEIGHT_ABOVE_FLOOR )
	ent:SetAngles( Angle( 0, ply:EyeAngles().y, 0 ) )
	ent:Spawn()
	ent:Activate()
	return ent
end

function ENT:Initialize()
	if not NikNaks or NikNaks.Version < 0.975 then
		SafeRemoveEntity( self )
		return
	end
	self:SetModel( self.BlockModel )
	self:PhysicsInit( SOLID_VPHYSICS )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:SetUseType( SIMPLE_USE )
	self:SetMaterial( "phoenix_storms/black_chrome" )

	local phys = self:GetPhysicsObject()
	if IsValid( phys ) then phys:Wake() end
end

---@param activator Player
function ENT:Use( activator )
	if not IsValid( activator ) or not activator:IsPlayer() then return end
	if not tryStartCooldown( activator, "PocketMapNextUse", USE_COOLDOWN ) then return end

	net.Start( "PocketMap_Open" )
		net.WriteEntity( self )
	net.Send( activator )
end

local function stripBspExtension( name )
	return ( string.gsub( name, "%.bsp$", "" ) )
end

local function isInstalledOnServer( name )
	return name == "" or file.Exists( "maps/" .. name .. ".bsp", "GAME" )
end

net.Receive( "PocketMap_Select", function( _, ply )
	if not tryStartCooldown( ply, "PocketMapNextSelect", SELECT_COOLDOWN ) then return end

	local ent = net.ReadEntity()
	local name = stripBspExtension( net.ReadString() )

	if not isPocketMap( ent ) or not isWithinReach( ply, ent ) then return end
	if not isValidMapName( name ) or not isInstalledOnServer( name ) then return end
	if name == ent:GetMapName() or not mayChangeMap( ply, ent, name ) then return end

	if not tryStartCooldown( ent, "PocketMapNextChange", BLOCK_CHANGE_COOLDOWN ) then
		ply:ChatPrint( "[PocketMap] Wait a moment before changing this block again." )
		return
	end

	ent:SetMapName( name )
	stopWalkersOn( ent )
end )

function ENT:OnRemove()
	stopWalkersOn( self )
end

local function isFinite( number )
	return number == number and number > -math.huge and number < math.huge
end

local function isBounded( x, y, z, limit )
	return isFinite( x ) and isFinite( y ) and isFinite( z ) and math.abs( x ) <= limit and math.abs( y ) <= limit and math.abs( z ) <= limit
end

local function isValidWalkState( velocity, position, angles )
	return isBounded( velocity.x, velocity.y, velocity.z, MAX_WALK_SPEED )
		and isBounded( position.x, position.y, position.z, MAX_WALK_COORDINATE )
		and isFinite( angles.p ) and isFinite( angles.y ) and isFinite( angles.r )
end

local worldBoundsByMap = {}

local function worldBoundsOf( mapName )
	local bounds = worldBoundsByMap[mapName]
	if bounds ~= nil then return bounds or nil end

	local ok, bsp = pcall( NikNaks.Map, mapName )
	local world = ok and bsp and bsp:GetBModels()[0]
	bounds = world and { mins = world.mins, maxs = world.maxs } or false
	worldBoundsByMap[mapName] = bounds
	return bounds or nil
end

local function isInsideWorldBounds( position, mapName )
	local bounds = worldBoundsOf( mapName )
	if not bounds then return false end

	local mins, maxs, margin = bounds.mins, bounds.maxs, WALK_BOUNDS_MARGIN
	return position.x >= mins.x - margin and position.x <= maxs.x + margin
		and position.y >= mins.y - margin and position.y <= maxs.y + margin
		and position.z >= mins.z - margin and position.z <= maxs.z + margin
end

local function isWithinWalkReach( ply, block )
	local eye = ply:EyePos()
	return block:NearestPoint( eye ):DistToSqr( eye ) <= WALK_REACH_SQR
end

local function nearbyPlayers( walker )
	local origin, players = walker.block:GetPos(), {}
	for _, other in ipairs( player.GetAll() ) do
		if other ~= walker.ply and other:GetPos():DistToSqr( origin ) <= WALK_RELAY_RANGE_SQR then players[#players + 1] = other end
	end
	return players
end

local function refreshRecipients( walker )
	walker.recipients = nearbyPlayers( walker )
	walker.nextRecipientRefresh = CurTime() + WALK_RECIPIENT_REFRESH_SECONDS
end

local function relayWalker( walker, active, unreliable )
	if #walker.recipients == 0 then return end

	net.Start( "PocketMap_PlyRelay", unreliable )
		net.WriteUInt( walker.index, 8 )
		net.WriteEntity( walker.block )
		net.WriteBool( active )
		if active then
			net.WriteVector( walker.velocity )
			net.WriteVector( walker.position )
			net.WriteAngle( walker.angles )
		end
	net.Send( walker.recipients )
end

local function removeWalkerHooksIfIdle()
	if next( walkers ) ~= nil then return end

	hook.Remove( "PlayerDisconnected", WALKER_ID )
	hook.Remove( "PostPlayerDeath", WALKER_ID )
	timer.Remove( WALKER_ID )
end

local function stopWalker( ply )
	local walker = walkers[ply]
	if not walker then return end

	walkers[ply] = nil
	if IsValid( walker.block ) then
		refreshRecipients( walker )
		relayWalker( walker, false )
	end
	removeWalkerHooksIfIdle()
end

local function isStale( ply, walker, now )
	return not IsValid( ply ) or not ply:Alive() or not IsValid( walker.block ) or walker.lastUpdate + WALK_STALE_SECONDS < now
end

local function stopStaleWalkers()
	local now = CurTime()
	for ply, walker in pairs( walkers ) do
		if isStale( ply, walker, now ) then stopWalker( ply ) end
	end
end

local function installWalkerHooks()
	hook.Add( "PlayerDisconnected", WALKER_ID, stopWalker )
	hook.Add( "PostPlayerDeath", WALKER_ID, stopWalker )
	timer.Create( WALKER_ID, WALK_STALE_CHECK_SECONDS, 0, stopStaleWalkers )
end

local function mayStartWalking( ply, block )
	if not ply:Alive() or block:GetMapName() == "" then return false end

	return hook.Run( "PocketMap_CanWalk", ply, block ) ~= false
end

local function trackedWalker( ply, block )
	local walker = walkers[ply]
	if walker and walker.block == block then return walker end

	stopWalker( ply )
	if not mayStartWalking( ply, block ) then return end

	local wasIdle = next( walkers ) == nil
	walker = { ply = ply, index = ply:EntIndex(), block = block, recipients = {}, nextRecipientRefresh = 0 }
	walkers[ply] = walker
	if wasIdle then installWalkerHooks() end
	return walker
end

local function updateWalker( ply, block, velocity, position, angles )
	local walker = trackedWalker( ply, block )
	if not walker then return end

	angles:Normalize()
	walker.velocity, walker.position, walker.angles, walker.lastUpdate = velocity, position, angles, CurTime()
	if walker.nextRecipientRefresh <= CurTime() then refreshRecipients( walker ) end

	relayWalker( walker, true, walker.hasRelayed == true )
	walker.hasRelayed = true
end

function stopWalkersOn( block )
	for ply, walker in pairs( walkers ) do
		if walker.block == block then stopWalker( ply ) end
	end
end

net.Receive( "PocketMap_Ply", function( _, ply )
	local block, active = net.ReadEntity(), net.ReadBool()
	if not active then
		ply.PocketMapIgnoreWalkUntil = CurTime() + WALK_LEAVE_GRACE_SECONDS
		return stopWalker( ply )
	end

	if ( ply.PocketMapIgnoreWalkUntil or 0 ) > CurTime() then return end
	if not isPocketMap( block ) or not isWithinWalkReach( ply, block ) then return stopWalker( ply ) end
	if not tryStartCooldown( ply, "PocketMapNextWalkUpdate", WALK_UPDATE_INTERVAL ) then return end

	local velocity, position, angles = net.ReadVector(), net.ReadVector(), net.ReadAngle()
	if not isValidWalkState( velocity, position, angles ) then return end
	if not isInsideWorldBounds( position, block:GetMapName() ) then return end

	updateWalker( ply, block, velocity, position, angles )
end )
