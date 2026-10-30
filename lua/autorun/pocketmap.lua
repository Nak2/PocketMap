if not file.Exists("includes/modules/niknaks.lua","LUA") then
	ErrorNoHalt( "[PocketMap] NikNaks module not found.\n" )
	return
end
require("niknaks")

if NikNaks.Version < 0.97 then
	ErrorNoHalt( "[PocketMap] This addon needs an up to date NikNaks.\n" )
	return
end

PocketMap = PocketMap or {}

local CLIENT_FILES = {
	"pocketmap/cl_hooks.lua",
	"pocketmap/cl_rt.lua",
	"pocketmap/cl_fit.lua",
	"pocketmap/cl_entities.lua",
	"pocketmap/cl_materials.lua",
	"pocketmap/cl_lightstyles.lua",
	"pocketmap/cl_hologram.lua",
	"pocketmap/cl_water.lua",
	"pocketmap/cl_miniature.lua",
	"pocketmap/cl_atlas.lua",
	"pocketmap/cl_propmesh.lua",
	"pocketmap/cl_proplight.lua",
	"pocketmap/cl_props.lua",
	"pocketmap/cl_detail.lua",
	"pocketmap/cl_faces.lua",
	"pocketmap/cl_sky.lua",
	"pocketmap/cl_loader.lua",
	"pocketmap/cl_draw.lua",
	"pocketmap/cl_lightanim.lua",
	"pocketmap/cl_maplist.lua",
	"pocketmap/cl_ui.lua",
}

if SERVER then
	util.AddNetworkString( "PocketMap_Open" )
	util.AddNetworkString( "PocketMap_Select" )

	for _, path in ipairs( CLIENT_FILES ) do AddCSLuaFile( path ) end
end

if CLIENT then
	for _, path in ipairs( CLIENT_FILES ) do include( path ) end
end
