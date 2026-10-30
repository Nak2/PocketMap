PocketMap = PocketMap or {}
PocketMap.Materials = {}
local Materials = PocketMap.Materials

local CUBEMAP_COPY_PATTERN = "^maps/[^/]+/(.+)_%-?%d+_%-?%d+_%-?%d+$"

local function vmtExists( name )
	return file.Exists( "materials/" .. name .. ".vmt", "GAME" )
end

---Faces of a map name the cubemap copy of a material, which only exists inside that map's pakfile. The original is the fallback.
---Material() prints an error for a missing .vmt, so the file is checked first.
---@param name string # the texture name of a face
---@return IMaterial material # the engine's error material if nothing was found
---@return number seconds # how long loading took
function Materials.Load( name )
	local took = 0

	if vmtExists( name ) then
		local material, seconds = Material( name )
		took = seconds or 0
		if not material:IsError() then return material, took end
	end

	local original = string.match( name, CUBEMAP_COPY_PATTERN )
	if original and vmtExists( original ) then
		local material, seconds = Material( original )
		took = took + ( seconds or 0 )
		if not material:IsError() then return material, took end
	end

	return Material( "___error" ), took
end

---The debug material of the sky, or the cubemap copy of it that a map saves.
---@param name string?
---@return boolean
function Materials.IsSkyName( name )
	return type( name ) == "string" and string.find( string.lower( name ), "toolsskybox", 1, true ) ~= nil
end
