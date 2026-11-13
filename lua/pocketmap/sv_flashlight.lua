-- Keep the native flashlight toggle and permissions, but render the walking
-- player's light in miniature coordinates instead of at their parked body.
PocketMap.FlashlightServer = PocketMap.FlashlightServer or {}
local Flashlight = PocketMap.FlashlightServer
Flashlight.players = Flashlight.players or {}
local players = Flashlight.players

function Flashlight.Start( ply )
	if players[ply] ~= nil then return end
	players[ply] = ply:FlashlightIsOn()
	ply:SetNWBool( "PocketMap_FlashlightOn", players[ply] )
	ply:SetNWBool( "PocketMap_FlashlightActive", true )
	ply:RemoveEffects( EF_DIMLIGHT )
end

function Flashlight.Stop( ply )
	local enabled = players[ply]
	players[ply] = nil
	if enabled == nil or not IsValid( ply ) then return end
	ply:SetNWBool( "PocketMap_FlashlightActive", false )
	if ply:Alive() and enabled then ply:Flashlight( true ) end
end

hook.Add( "StartCommand", "PocketMap_Flashlight", function( ply, command )
	local enabled = players[ply]
	if enabled == nil or command:GetImpulse() ~= 100 then return end
	command:SetImpulse( 0 )
	if not ply:Alive() or not ply:CanUseFlashlight() then return end
	if hook.Run( "PlayerSwitchFlashlight", ply, not enabled ) == false then return end
	players[ply] = not enabled
	ply:SetNWBool( "PocketMap_FlashlightOn", not enabled )
	ply:EmitSound( "HL2Player.FlashlightOn" )
end )

hook.Add( "PlayerDisconnected", "PocketMap_Flashlight", function( ply ) players[ply] = nil end )
