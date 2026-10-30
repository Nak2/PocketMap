ENT.Type = "anim"
ENT.Base = "base_anim"

ENT.PrintName = "Pocket Map"
ENT.Author = "Nak"
ENT.Information = "A pocket-sized viewer for browsing maps."
ENT.Category = "#spawnmenu.category.fun_games"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.BlockModel = "models/hunter/blocks/cube8x8x8.mdl"

ENT.BoxMins = Vector( -190.05, -190.05, -23.975 )
ENT.BoxMaxs = Vector( 190.05, 190.05, 356.125 )

PocketMap = PocketMap or {}

local MAX_MAP_NAME_LENGTH = 255

function PocketMap.IsValidMapName( name )
	return #name <= MAX_MAP_NAME_LENGTH and not string.find( name, "%c" )
end

function ENT:IsOutsideBox(pos)
	local lP = self:WorldToLocal(pos)
	return lP.x < self.BoxMins.x or lP.x > self.BoxMaxs.x
		or lP.y < self.BoxMins.y or lP.y > self.BoxMaxs.y
		or lP.z < self.BoxMins.z or lP.z > self.BoxMaxs.z
end

function ENT:ClampToBox( localPosition )
	return Vector(
		math.Clamp( localPosition.x, self.BoxMins.x, self.BoxMaxs.x ),
		math.Clamp( localPosition.y, self.BoxMins.y, self.BoxMaxs.y ),
		math.Clamp( localPosition.z, self.BoxMins.z, self.BoxMaxs.z ) )
end

function ENT:SetupDataTables()
	-- Name of the map shown in the block, without maps/ and .bsp. "" = empty.
	self:NetworkVar( "String", 0, "MapName" )
end
