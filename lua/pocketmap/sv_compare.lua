-- Developer comparison: preserve the rendered eye when switching to the same BSP.
util.AddNetworkString( "PocketMap_Compare" )
PocketMap.CompareReturns = PocketMap.CompareReturns or {}
local returns = PocketMap.CompareReturns

local function reject( ply, message )
	net.Start( "PocketMap_Compare" )
	net.WriteUInt( 2, 2 )
	net.WriteString( message )
	net.Send( ply )
end

local function finiteVector( value )
	for _, axis in ipairs( { "x", "y", "z" } ) do
		local n = value[axis]
		if n ~= n or math.abs( n ) > 65536 then return false end
	end
	return true
end

net.Receive( "PocketMap_Compare", function( _, ply )
	if not IsValid( ply ) or not ply:Alive() then return end
	local returning = net.ReadBool()
	if returning then
		local saved = returns[ply]
		if not saved then return reject( ply, "No native comparison is active." ) end
		local eye, angles = ply:EyePos(), ply:EyeAngles()
		returns[ply] = nil
		ply:SetPos( saved.position )
		ply:SetEyeAngles( saved.angles )
		ply:SetMoveType( saved.moveType )
		ply:SetLocalVelocity( Vector() )
		if not IsValid( saved.block ) or saved.block:GetMapName() ~= game.GetMap() then
			return reject( ply, "The comparison block was removed or changed maps." )
		end
		net.Start( "PocketMap_Compare" )
		net.WriteUInt( 1, 2 )
		net.WriteVector( eye )
		net.WriteAngle( angles )
		net.Send( ply )
		return
	end
	-- Servers can grant this diagnostic to a particular developer for a session.
	if not ( game.SinglePlayer() or ply:IsAdmin() or ply.PocketMapCanCompare ) then
		return reject( ply, "Native comparison requires admin or developer permission." )
	end
	local block, eye, angles = net.ReadEntity(), net.ReadVector(), net.ReadAngle()
	if not IsValid( block ) or block:GetClass() ~= "ent_pocketmap" or block:GetMapName() ~= game.GetMap() then
		return reject( ply, "PocketMap and the server must be using the same map." )
	end
	if not finiteVector( eye ) or not finiteVector( Vector( angles.p, angles.y, angles.r ) ) then return reject( ply, "Invalid comparison position or angle." ) end
	-- A client may have lost its comparison state (for example after a Lua reload).
	-- Allow a new valid entry and retain the original body position for the return.
	local previous = returns[ply]
	returns[ply] = {
		block = block,
		position = previous and previous.position or ply:GetPos(),
		angles = previous and previous.angles or ply:EyeAngles(),
		moveType = previous and previous.moveType or ply:GetMoveType()
	}
	-- Place the native player's eye exactly where the PocketMap camera was.
	local eyeOffset = ply:EyePos() - ply:GetPos()
	ply:SetPos( eye - eyeOffset )
	-- Noclip holds the exact eye position while taking screenshots, even midair.
	ply:SetMoveType( MOVETYPE_NOCLIP )
	ply:SetEyeAngles( angles )
	ply:SetLocalVelocity( Vector() )
	net.Start( "PocketMap_Compare" )
	net.WriteUInt( 0, 2 )
	net.Send( ply )
end )

hook.Add( "PlayerDisconnected", "PocketMap_Compare", function( ply ) returns[ply] = nil end )
hook.Add( "PlayerDeath", "PocketMap_Compare", function( ply ) returns[ply] = nil end )
hook.Add( "PlayerSpawn", "PocketMap_Compare", function( ply ) returns[ply] = nil end )
