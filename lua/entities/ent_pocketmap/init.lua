AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local ORIGIN_HEIGHT_ABOVE_FLOOR = 24
local MAX_REACH_SQR = 400 * 400
local MAX_NAME_LENGTH = 64
local SELECT_COOLDOWN = 0.5
local USE_COOLDOWN = 0.25

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

net.Receive( "PocketMap_Select", function( _, ply )
	if not tryStartCooldown( ply, "PocketMapNextSelect", SELECT_COOLDOWN ) then return end

	local ent = net.ReadEntity()
	local name = net.ReadString()

	if not isPocketMap( ent ) then return end
	if not isWithinReach( ply, ent ) then return end
	if not isValidMapName( name ) then return end

	name = string.gsub( name, "%.bsp$", "" )
	if not mayChangeMap( ply, ent, name ) then return end

	ent:SetMapName( name )
end )
