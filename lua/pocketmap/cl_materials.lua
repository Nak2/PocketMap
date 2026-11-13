PocketMap = PocketMap or {}
PocketMap.Materials = PocketMap.Materials or {}
local Materials = PocketMap.Materials
Materials.scaled = Materials.scaled or {}
-- Cache the last resolved material per source material and scale. The slower
-- string key and material-name lookup are only needed when the scale or native
-- seamless setting changes, instead of once per material slice per frame.
Materials.resolved = Materials.resolved or setmetatable( {}, { __mode = "k" } )

local CUBEMAP_COPY_PATTERN = "^maps/[^/]+/(.+)_%-?%d+_%-?%d+_%-?%d+$"

-- BSP texture names and entity material keys may include a leading slash,
-- backslashes, or the materials/ prefix. Source treats these as relative paths.
function Materials.Name( name )
	return tostring( name or "" ):lower():gsub( "\\", "/" ):gsub( "^/+", "" ):gsub( "^materials/", "" ):gsub( "%.vmt$", "" )
end

local function vmtExists( name )
	return file.Exists( "materials/" .. name .. ".vmt", "GAME" )
end

---Faces of a map name the cubemap copy of a material, which only exists inside that map's pakfile. The original is the fallback.
---Material() prints an error for a missing .vmt, so the file is checked first.
---@param name string # the texture name of a face
---@return IMaterial material # the engine's error material if nothing was found
---@return number seconds # how long loading took
function Materials.Load( name )
	name = Materials.Name( name )
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

local function materialProxies( name, seen )
	name = name:gsub( "^materials/", "" ):gsub( "%.vmt$", "" )
	if seen[name] then return end
	seen[name] = true
	local text = file.Read( "materials/" .. name .. ".vmt", "GAME" )
	local values = text and util.KeyValuesToTable( text )
	if not values then return end
	local proxies = values.include and materialProxies( values.include, seen )
	return values.proxies or ( values.replace and values.replace.proxies )
		or ( values.insert and values.insert.proxies ) or proxies
end

-- Preserve shader lighting inputs when a render path needs a local variant.
-- Recreating only the base texture loses normal maps, light warps, tint and
-- foliage lighting controls. Never change the native map's shared material.
function Materials.Copy( material, name, overrides )
	overrides = overrides or {}
	local values, matrices, textures = {}, {}, {}
	for key, value in pairs( material:GetKeyValues() ) do
		if type( value ) == "ITexture" then
			values[key], textures[key] = value:GetName(), value
		elseif ismatrix( value ) then
			matrices[key] = value
		elseif isvector( value ) then
			values[key] = string.format( "[%g %g %g]", value.x, value.y, value.z )
		else
			values[key] = value
		end
	end
	values.Proxies = materialProxies( material:GetName(), {} )
	for key, value in pairs( overrides ) do values[key] = value end
	local shader = material:GetShader():gsub( "_DX%d+$", "" )
	local copy = CreateMaterial( name, shader, values )
	for key, texture in pairs( textures ) do if overrides[key] == nil then copy:SetTexture( key, texture ) end end
	for key, matrix in pairs( matrices ) do if overrides[key] == nil then copy:SetMatrix( key, matrix ) end end
	copy:Recompute()
	return copy
end

-- Seamless shaders cache their world-position mapping scale in the material's
-- static command buffer. SetFloat around each draw cannot reliably update it.
-- Give each scale its own snapshot and leave the real map's material untouched.
function Materials.ForScale( material, scale )
	if not scale or scale ~= scale or scale <= 0 or scale == math.huge or scale == 1 then return material end
	local seamless = material:GetFloat( "$seamless_scale" )
	local byScale = Materials.resolved[material]
	local resolved = byScale and byScale[scale]
	if resolved and resolved.seamless == seamless then return resolved.material end
	if not byScale then byScale = {} Materials.resolved[material] = byScale end
	if not seamless or seamless == 0 then
		byScale[scale] = { seamless = seamless, material = material }
		return material
	end
	local key = material:GetName() .. ":" .. string.format( "%.17g:%.17g", scale, seamless )
	local cached = Materials.scaled[key]
	if cached then
		byScale[scale] = { seamless = seamless, material = cached }
		return cached
	end
	local copy = Materials.Copy( material, "PocketMap_Scaled_v1_" .. util.CRC( key ), { ["$seamless_scale"] = seamless / scale } )
	Materials.scaled[key] = copy
	byScale[scale] = { seamless = seamless, material = copy }
	return copy
end

-- Compile feature combinations once in memory. Refract/Water and other special
-- shaders retain their inputs; removing a normal map from them changes opacity.
Materials.worldVariants = Materials.worldVariants or setmetatable( {}, { __mode = "k" } )
function Materials.ForWorld( material, scale, mini )
	if not PocketMap.Settings then return Materials.ForScale( material, scale ) end
	local mask = ( PocketMap.Settings.Enabled( mini, "world_normalmaps" ) and 0 or 1 )
		+ ( PocketMap.Settings.Enabled( mini, "world_detailtextures" ) and 0 or 2 )
		+ ( PocketMap.Settings.Enabled( mini, "world_reflections" ) and 0 or 4 )
	if mask == 0 then return Materials.ForScale( material, scale ) end
	local seamless = material:GetFloat( "$seamless_scale" ) or 0
	local cache = Materials.worldVariants[material]
	if cache and cache.scale == scale and cache.mask == mask and cache.seamless == seamless then return cache.material end
	if not cache then cache = { variants = {} } Materials.worldVariants[material] = cache end
	local shader = material:GetShader():gsub( "_DX%d+$", "" )
	if shader ~= "LightmappedGeneric" and shader ~= "WorldVertexTransition" and shader ~= "UnlitGeneric" then
		return Materials.ForScale( material, scale )
	end
	local key = tostring( mask ) .. ":" .. tostring( scale ) .. ":" .. tostring( seamless )
	local copy = cache.variants[key]
	if not copy then
		local overrides = {}
		if not PocketMap.Settings.Enabled( mini, "world_normalmaps" ) then
			overrides["$bumpmap"], overrides["$bumpmap2"], overrides["$bumpmask"], overrides["$ssbump"] = "", "", "", 0
		end
		if not PocketMap.Settings.Enabled( mini, "world_detailtextures" ) then overrides["$detail"], overrides["$detailblendfactor"] = "", 0 end
		if not PocketMap.Settings.Enabled( mini, "world_reflections" ) then
			overrides["$envmap"], overrides["$envmapmask"] = "", ""
			overrides["$normalmapalphaenvmapmask"], overrides["$basealphaenvmapmask"] = 0, 0
		end
		if seamless ~= 0 and scale and scale > 0 and scale < math.huge and scale ~= 1 then overrides["$seamless_scale"] = seamless / scale end
		copy = Materials.Copy( material, "PocketMap_WorldFeatures_v1_" .. util.CRC( material:GetName() .. ":" .. key ), overrides )
		cache.variants[key] = copy
	end
	cache.scale, cache.mask, cache.seamless, cache.material = scale, mask, seamless, copy
	return copy
end

-- The outside shell uses only a base texture. A separate unlit shader also
-- removes special refract/reflect shaders and proxies without touching any
-- native host-map material or the interior's feature variants.
Materials.previews = Materials.previews or setmetatable( {}, { __mode = "k" } )
function Materials.ForPreview( material )
	local cached = Materials.previews[material]
	if cached then return cached end
	local source, values, matrices = material:GetKeyValues(), {}, {}
	for _, key in ipairs( { "$basetexture", "$basetexturetransform", "$color", "$alpha", "$alphatestreference" } ) do
		local value = source[key]
		if type( value ) == "ITexture" then values[key] = value:GetName()
		elseif ismatrix( value ) then matrices[key] = value
		elseif isvector( value ) then values[key] = string.format( "[%g %g %g]", value.x, value.y, value.z )
		elseif value ~= nil then values[key] = value end
	end
	local flags = material:GetInt( "$flags" ) or 0
	values["$alphatest"] = bit.band( flags, 0x100 ) ~= 0 and 1 or 0
	values["$nocull"] = bit.band( flags, 0x2000 ) ~= 0 and 1 or 0
	values["$model"] = 0
	local copy = CreateMaterial( "PocketMap_Preview_v1_" .. util.CRC( material:GetName() ), "UnlitGeneric", values )
	for key, matrix in pairs( matrices ) do copy:SetMatrix( key, matrix ) end
	copy:Recompute()
	Materials.previews[material] = copy
	return copy
end

function Materials.DrawOptions( options, scale )
	local wrappers = options.materialOptions
	if not wrappers then wrappers = {} options.materialOptions = wrappers end
	local previous = wrappers[scale]
	if previous and previous.system == Materials then return previous end
	local wrapped = setmetatable( {
		system = Materials,
		material = function( material )
			return options.preview and Materials.ForPreview( material ) or Materials.ForScale( material, scale )
		end,
	}, { __index = options } )
	wrappers[scale] = wrapped
	return wrapped
end
