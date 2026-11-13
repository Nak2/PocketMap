PocketMap.Compare = PocketMap.Compare or {}
local Compare = PocketMap.Compare

local function report( message ) chat.AddText( "[PocketMap] " .. message ) end

concommand.Add( "pocketmap_compare", function()
	if Compare.pending then return end
	if not IsValid( LocalPlayer() ) or not LocalPlayer():Alive() then return report( "Respawn before comparing maps." ) end
	local session = PocketMap.Walk.session
	local returning = session == nil
	if session then
		if session.mini.mapName ~= game.GetMap() then return report( "PocketMap and the server must be using the same map." ) end
		Compare.saved = session
	elseif not Compare.saved then
		return report( "Enter a PocketMap before comparing." )
	end
	Compare.pending = true
	net.Start( "PocketMap_Compare" )
	net.WriteBool( returning )
	if not returning then
		net.WriteEntity( session.mini.ent )
		net.WriteVector( session.move.origin + PocketMap.Walk.EyeOffset( session ) )
		net.WriteAngle( session.move.angles )
	end
	net.SendToServer()
end )

net.Receive( "PocketMap_Compare", function()
	local mode = net.ReadUInt( 2 )
	Compare.pending = false
	if mode == 2 then
		Compare.saved = nil
		return report( net.ReadString() )
	end
	if mode == 0 then
		PocketMap.Walk.Leave()
		return report( "Native map, with noclip for comparison. Run pocketmap_compare to return." )
	end
	local eye, angles = net.ReadVector(), net.ReadAngle()
	local saved = Compare.saved
	Compare.saved = nil
	if not saved or not IsValid( saved.mini.ent ) or saved.mini.state ~= "ready" then return end
	if PocketMap.Walk.session then PocketMap.Walk.Leave() end
	PocketMap.Walk.Enter( saved.mini.ent )
	local session = PocketMap.Walk.session
	if not session then return end
	session.io = saved.io
	session.io.touching = {}
	session.noclip, session.ducking, session.duckTarget, session.crouchFlag = saved.noclip, saved.ducking, saved.duckTarget, saved.crouchFlag
	session.viewOffset = saved.viewOffset
	session.move.origin = eye - PocketMap.Walk.EyeOffset( session )
	session.move.velocity = Vector()
	session.move.angles, session.move.moveAngles = angles, angles
	session.yawOffset = angles.y - LocalPlayer():EyeAngles().y
	-- Comparison switches should not obscure screenshots with the entry fade.
	session.enteredAt = RealTime() - 2
	report( "PocketMap, at the same eye position and viewing angle." )
end )
