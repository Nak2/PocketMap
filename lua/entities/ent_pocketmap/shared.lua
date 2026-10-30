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

function ENT:SetupDataTables()
	-- Name of the map shown in the block, without maps/ and .bsp. "" = empty.
	self:NetworkVar( "String", 0, "MapName" )
end
