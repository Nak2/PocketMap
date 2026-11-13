-- The Water shader reads $reflecttexture and $refracttexture, which the engine only fills for the world it draws.
-- The water of a block is a mesh, so PreRender fills them here, mirroring what the engine does (viewrender.cpp):
-- refraction is the map below the water with the scene depth in alpha, reflection is the map above it seen from a mirrored eye.

PocketMap = PocketMap or {}
PocketMap.Water = PocketMap.Water or {}
local Water = PocketMap.Water

local RT_SCALE = 0.5
local WATER_RT_FLAGS = 4 + 8 -- TEXTUREFLAGS_CLAMPS | TEXTUREFLAGS_CLAMPT
local BUDGETED_REFRESH_SECONDS = 1 / 14
local SPREAD = 2
local MAX_PLANES = 32
local MAX_RENDERED_HEIGHTS = 4
local RELEASE_AFTER_FRAMES = 60
local FLAT_SIZE = 16
local MAX_MESH_VERTS = 30000
local PVS_BOUNDS_PAD = 8
local PVS_MAX_LEAFS = 512
local REFLECTION_TONE_SCALE = 0.25
local ENGINE_REFLECTION, ENGINE_REFRACTION = "_rt_WaterReflection", "_rt_WaterRefraction"

local cvWater = CreateClientConVar( "pocketmap_water", "1", true, false,
	"0 = flat water, 1 = budgeted reflection/refraction, 2 = full reflection/refraction every frame.", 0, 2 )
local cvReflectionPVS = CreateClientConVar( "pocketmap_water_reflection_pvs", "1", true, false,
	"Use the visibility of all water-surface leaves for reflections" )

Water.pass = nil
Water.sceneView = nil
Water.broken = false
Water.error = nil
Water.fovParam = nil
Water.view = nil

-- ── The material ──────────────────────────────────────────────────────────────

---@param material IMaterial?
---@return boolean
function Water.IsWaterMaterial( material )
	if not material or material:IsError() then return false end
	local shader = string.lower( material:GetShader() or "" )
	return string.find( shader, "^water" ) ~= nil and not string.find( shader, "cheap", 1, true )
end

---Faces name the cubemap copy of a material (maps/<map>/<material>_<x>_<y>_<z>), so the original .vmt is the fallback.
---@return table? # lower case key -> value
local function readVMT( name )
	name = PocketMap.Materials.Name( name )
	local text = file.Read( "materials/" .. name .. ".vmt", "GAME" )
	if not text or text == "" then
		local original = string.match( name, "^maps/[^/]+/(.+)_%-?%d+_%-?%d+_%-?%d+$" )
		text = original and file.Read( "materials/" .. original .. ".vmt", "GAME" )
	end
	if not text or text == "" then return nil end

	local parsed = util.KeyValuesToTable( text )
	if not istable( parsed ) then return nil end

	local only = next( parsed )
	if only and next( parsed, only ) == nil and istable( parsed[only] ) and string.sub( tostring( only ), 1, 1 ) ~= "$" then
		parsed = parsed[only]
	end
	return parsed
end

---"{7 58 66}" or "[0.03 0.2 0.25]" -> 0-255 numbers
local function parseColor( text )
	local a, b, c = string.match( tostring( text or "" ), "([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)" )
	a, b, c = tonumber( a ), tonumber( b ), tonumber( c )
	if not ( a and b and c ) then return 7, 58, 66 end
	if string.find( text, "[", 1, true ) and math.max( a, b, c ) <= 1 then return a * 255, b * 255, c * 255 end
	return a, b, c
end

-- An included/patch VMT does not contain its base material's fog values.
-- Material() has already resolved them, including the map's cubemap patch.
local function materialFog( material, source )
	local params = source or {}
	local start = tonumber( params["$fogstart"] ) or material:GetFloat( "$fogstart" ) or 0
	local finish = tonumber( params["$fogend"] ) or material:GetFloat( "$fogend" ) or 1024
	if finish <= start then finish = start + 1024 end
	local r, g, b = parseColor( params["$fogcolor"] or material:GetString( "$fogcolor" ) )
	return { r = math.floor( r ), g = math.floor( g ), b = math.floor( b ) }, finish - start, start, finish
end

-- Targets: a plane starts on tiny flat-color targets (shared per fog color) and gets full size ones, shared per height,
-- only while its height is being drawn.

local function useFlatTargets( plane )
	plane.reflectRT, plane.refractRT = plane.flat.reflect, plane.flat.refract
	plane.w, plane.h = FLAT_SIZE, FLAT_SIZE
	plane.cleared = false
end

-- Preserve target ownership when this client file is hot-reloaded while a miniature exists.
Water.sharedFlats = Water.sharedFlats or {}
local sharedFlats = Water.sharedFlats -- fog color -> { reflect, refract, users }, for every block

---@return table? flat # { reflect, refract }, nil if the card can't make them
local function acquireFlat( mini, fog )
	mini.waterFlats = mini.waterFlats or {}

	local id = fog.r .. "_" .. fog.g .. "_" .. fog.b
	if mini.waterFlats[id] then return sharedFlats[id] end

	local flat = sharedFlats[id]
	if not flat then
		local reflect = PocketMap.RT.Acquire( FLAT_SIZE, FLAT_SIZE )
		local refract = PocketMap.RT.Acquire( FLAT_SIZE, FLAT_SIZE )
		if not reflect or not refract then
			PocketMap.RT.Release( reflect )
			PocketMap.RT.Release( refract )
			return nil
		end

		PocketMap.RT.Clear( reflect, fog.r, fog.g, fog.b, 255 )
		PocketMap.RT.Clear( refract, fog.r, fog.g, fog.b, 255 )
		flat = { reflect = reflect, refract = refract, users = 0 }
		sharedFlats[id] = flat
	end

	flat.users = flat.users + 1
	mini.waterFlats[id] = true
	return flat
end

local function releaseFlats( mini )
	for id in pairs( mini.waterFlats or {} ) do
		local flat = sharedFlats[id]
		if flat then
			flat.users = flat.users - 1

			if flat.users == 0 then
				PocketMap.RT.Release( flat.reflect )
				PocketMap.RT.Release( flat.refract )
				sharedFlats[id] = nil
			end
		end
	end
	mini.waterFlats = nil
end

local function heightRecord( mini, z )
	mini.waterHeights = mini.waterHeights or {}
	mini.waterHeights[z] = mini.waterHeights[z] or { z = z, planes = {} }
	return mini.waterHeights[z]
end

-- Render targets can't be freed, so the number that ever exist is what counts: at most MAX_RENDERED_HEIGHTS heights hold full
-- size targets at a time, across all blocks. A new one takes the targets of the one drawn longest ago.
-- Keep the full-size target budget across a clientside hot reload, just like the shared flat targets.
Water.heldHeights = Water.heldHeights or {}
local heldHeights, heldCount = Water.heldHeights, 0
for _ in pairs( heldHeights ) do heldCount = heldCount + 1 end

local function releaseHeightTargets( rec )
	if not rec.reflect then return end

	PocketMap.RT.Release( rec.reflect )
	PocketMap.RT.Release( rec.refract )
	rec.reflect, rec.refract, rec.flags = nil, nil, nil
	rec.valid, rec.nextRefresh = false, nil

	if heldHeights[rec] then
		heldHeights[rec] = nil
		heldCount = heldCount - 1
	end

	for _, plane in ipairs( rec.planes ) do useFlatTargets( plane ) end
end

---@return boolean evicted # false if every held height was drawn this frame
local function evictStalest()
	local stalest
	for rec in pairs( heldHeights ) do
		local lastFrame = rec.lastFrame or 0
		if lastFrame ~= FrameNumber() and ( not stalest or lastFrame < ( stalest.lastFrame or 0 ) ) then stalest = rec end
	end

	if not stalest then return false end

	releaseHeightTargets( stalest )
	return true
end

---@return boolean ok # false if there are none to give: the water stays flat
local function acquireHeightTargets( rec, mini )
	local scale = RT_SCALE
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "water_high_resolution" ) then scale = 0.25 end
	local w, h = math.max( math.floor( ScrW() * scale ), 256 ), math.max( math.floor( ScrH() * scale ), 256 )
	if rec.reflect and rec.w == w and rec.h == h and rec.flags == WATER_RT_FLAGS then return true end

	releaseHeightTargets( rec )
	if heldCount >= MAX_RENDERED_HEIGHTS and not evictStalest() then return false end

	local reflect = PocketMap.RT.Acquire( w, h, { depth = true, flags = WATER_RT_FLAGS } )
	local refract = PocketMap.RT.Acquire( w, h, { depth = true, flags = WATER_RT_FLAGS } )
	if not reflect or not refract then
		PocketMap.RT.Release( reflect )
		PocketMap.RT.Release( refract )
		return false
	end

	rec.reflect, rec.refract, rec.w, rec.h, rec.flags = reflect, refract, w, h, WATER_RT_FLAGS
	rec.valid = false
	rec.nextRefresh = nil
	heldHeights[rec] = true
	heldCount = heldCount + 1

	for _, plane in ipairs( rec.planes ) do
		plane.reflectRT, plane.refractRT, plane.w, plane.h, plane.cleared = reflect, refract, w, h, false
	end
	return true
end

local function releaseIdleTargets( mini )
	for _, rec in pairs( mini.waterHeights or {} ) do
		if rec.reflect and FrameNumber() - ( rec.lastFrame or 0 ) > RELEASE_AFTER_FRAMES then releaseHeightTargets( rec ) end
	end
end

Water.materialCopies = Water.materialCopies or {}
local MATERIAL_MODE_VERSION = 3

-- Match the source material's water path. FORCECHEAP takes precedence, and
-- an undefined reflection texture means cubemap reflection, not another view.
local function materialMode( material )
	if ( material:GetInt( "$forcecheap" ) or 0 ) ~= 0 then return true, false, false end
	local values = material:GetKeyValues()
	local reflect, refract = material:GetTexture( "$reflecttexture" ), material:GetTexture( "$refracttexture" )
	-- GetTexture can return an "error" texture whose IsError() is false for
	-- an undefined shader variable. Check whether the variable exists too.
	local reflection = values["$reflecttexture"] ~= nil and reflect ~= nil and not reflect:IsError()
	local refraction = values["$refracttexture"] ~= nil and refract ~= nil and not refract:IsError()
	return not ( reflection or refraction ), reflection, refraction
end

local function sceneMaterial( material, scale, first, last, cheap )
	local key = "v3:" .. material:GetName() .. ":" .. string.format( "%.17g", scale ) .. ":" .. tostring( cheap )
	if not Water.materialCopies[key] then
		-- The shader builds separate static snapshots for cheap/expensive water.
		-- Choose our path at creation instead of toggling the native material's
		-- flags around draws; it may have compiled only the cheap snapshot.
		Water.materialCopies[key] = PocketMap.Materials.Copy( material,
			"PocketMap_WaterScene_v3_" .. util.CRC( key ), {
				["$forcecheap"] = cheap and 1 or 0, ["$forceexpensive"] = cheap and 0 or 1,
				["$fogstart"] = first * scale, ["$fogend"] = last * scale,
			} )
	end
	return Water.materialCopies[key]
end

local function ensurePlaneMode( mini, plane )
	if plane.materialModeVersion == MATERIAL_MODE_VERSION and plane.materialScale == mini.scale
		and plane.reflectEntities ~= nil then return end
	local material = plane.sourceMaterial or plane.material
	local _, _, first, last = materialFog( material )
	first, last = plane.sourceFogStart or first, plane.sourceFogEnd or last
	plane.sourceMaterial = material
	plane.cheap, plane.reflectScene, plane.refractScene = materialMode( material )
	plane.reflectEntities = ( material:GetInt( "$reflectentities" ) or 0 ) ~= 0
	plane.material = sceneMaterial( material, mini.scale, first, last, plane.cheap )
	plane.isolatedMaterial, plane.materialModeVersion, plane.materialScale = true, MATERIAL_MODE_VERSION, mini.scale
end

---@param key string # the material name of the faces
---@param z number # the height in the map
---@param source table? # the parameters of the .vmt
---@return table? plane # nil if the flat targets can't be made
local function makePlane( mini, key, z, source, material )
	local fog, fogRange, sourceStart, sourceEnd = materialFog( material, source )

	local plane = {
		key = key, z = z, material = material,
		sourceMaterial = material, isolatedMaterial = true,
		fog = fog, fogRange = fogRange, fogResolved = true,
		sourceFogStart = sourceStart, sourceFogEnd = sourceEnd,
		fogStart = sourceStart * mini.scale, fogEnd = sourceEnd * mini.scale,
		meshes = {}, faces = 0, vmt = source ~= nil,
		mins = Vector( math.huge, math.huge, z ), maxs = Vector( -math.huge, -math.huge, z ),
	}
	ensurePlaneMode( mini, plane )

	plane.flat = acquireFlat( mini, plane.fog )
	if not plane.flat then return nil end

	useFlatTargets( plane )
	plane.cleared = true
	return plane
end

-- A miniature may survive a clientside hot reload. Correct its old default
-- fog and flat targets without forcing a map reload or leaking render targets.
local function resolveOldFog( mini, plane )
	ensurePlaneMode( mini, plane )
	if plane.fogResolved then return end
	plane.fogResolved = true
	local fog, range = materialFog( plane.material )
	plane.fogRange = range
	if plane.fog.r == fog.r and plane.fog.g == fog.g and plane.fog.b == fog.b then return end
	local flat = acquireFlat( mini, fog )
	if not flat then return end
	local usingFlat = plane.reflectRT == plane.flat.reflect
	plane.flat, plane.fog = flat, fog
	if usingFlat then useFlatTargets( plane ) end
end

---A material can be shared by several planes. Save its original parameters once per draw and only update values that change.
local function bind( plane, materials, mini )
	if plane.cheap then return false end
	local material = plane.material
	local refractRT = plane.refractRT
	local reflectRT = plane.reflectRT
	if PocketMap.Settings and plane.flat then
		if not PocketMap.Settings.Enabled( mini, "water_reflections" ) then reflectRT = plane.flat.reflect end
		if not PocketMap.Settings.Enabled( mini, "water_refractions" ) then refractRT = plane.flat.refract end
	end
	local saved = materials[material]
	local changed = false
	if not saved then
		saved = {
			reflect = material:GetTexture( "$reflecttexture" ), refract = material:GetTexture( "$refracttexture" ),
			expensive = material:GetInt( "$forceexpensive" ), cheap = material:GetInt( "$forcecheap" ),
			fogStart = material:GetFloat( "$fogstart" ), fogEnd = material:GetFloat( "$fogend" ),
		}
		saved.currentReflect, saved.currentRefract = saved.reflect, saved.refract
		saved.currentExpensive, saved.currentFogStart, saved.currentFogEnd = saved.expensive, saved.fogStart, saved.fogEnd
		saved.currentCheap = saved.cheap
		materials[material] = saved
	end

	if plane.reflectScene and saved.currentReflect ~= reflectRT then
		material:SetTexture( "$reflecttexture", reflectRT )
		saved.currentReflect = reflectRT
		changed = true
	end
	if plane.refractScene and saved.currentRefract ~= refractRT then
		material:SetTexture( "$refracttexture", refractRT )
		saved.currentRefract = refractRT
		changed = true
	end
	if saved.currentExpensive ~= 1 then
		material:SetInt( "$forceexpensive", 1 )
		saved.currentExpensive = 1
		changed = true
	end
	-- FORCECHEAP wins over FORCEEXPENSIVE in the Water shader. Clear it
	-- while our scene targets are bound, otherwise submerged models are
	-- covered by opaque cheap water instead of appearing in refraction.
	if saved.currentCheap ~= 0 then
		material:SetInt( "$forcecheap", 0 )
		saved.currentCheap = 0
		changed = true
	end
	if saved.currentFogStart ~= plane.fogStart then
		material:SetFloat( "$fogstart", plane.fogStart )
		saved.currentFogStart = plane.fogStart
		changed = true
	end
	if saved.currentFogEnd ~= plane.fogEnd then
		material:SetFloat( "$fogend", plane.fogEnd )
		saved.currentFogEnd = plane.fogEnd
		changed = true
	end
	return changed
end

local function unbind( material, saved )
	if saved.currentReflect ~= saved.reflect then material:SetTexture( "$reflecttexture", saved.reflect or ENGINE_REFLECTION ) end
	if saved.currentRefract ~= saved.refract then material:SetTexture( "$refracttexture", saved.refract or ENGINE_REFRACTION ) end
	if saved.currentExpensive ~= saved.expensive then material:SetInt( "$forceexpensive", saved.expensive or 0 ) end
	if saved.currentCheap ~= saved.cheap then material:SetInt( "$forcecheap", saved.cheap or 0 ) end
	if saved.currentFogStart ~= saved.fogStart then material:SetFloat( "$fogstart", saved.fogStart or 0 ) end
	if saved.currentFogEnd ~= saved.fogEnd then material:SetFloat( "$fogend", saved.fogEnd or 0 ) end
end

---A target that was never drawn into holds garbage, so planes with no effects are filled with their fog color.
local function clearPlane( plane )
	local hasDepth = plane.reflectRT ~= plane.flat.reflect
	PocketMap.RT.Clear( plane.reflectRT, plane.fog.r, plane.fog.g, plane.fog.b, 255, hasDepth )
	PocketMap.RT.Clear( plane.refractRT, plane.fog.r, plane.fog.g, plane.fog.b, 255, hasDepth )
	plane.cleared = true
end

local TANGENT_S, TANGENT_T = Vector( 1, 0, 0 ), Vector( 0, 1, 0 )

-- UVs and proxy scroll rates share the source material's units. Scaling just
-- UVs increases apparent wave speed by 1 / uvScale and enlarges every ripple.
local function waterUVScale( scale )
	return 1
end

---The Water shader needs a tangent space, which the NikNaks MeshBuilder doesn't write. The surface is flat: S along x, T along y.
local function buildMeshes( plane, faces, uvScale )
	local yield = coroutine.yield
	uvScale = uvScale or 1
	local verts, n = {}, 0
	for i, face in ipairs( faces ) do
		local triangles = face:GenerateVertexTriangleData()
		if triangles then
			for _, v in ipairs( triangles ) do
				n = n + 1
				verts[n] = v
				local p = v.pos
				if p.x < plane.mins.x then plane.mins.x = p.x end
				if p.y < plane.mins.y then plane.mins.y = p.y end
				if p.z < plane.mins.z then plane.mins.z = p.z end
				if p.x > plane.maxs.x then plane.maxs.x = p.x end
				if p.y > plane.maxs.y then plane.maxs.y = p.y end
				if p.z > plane.maxs.z then plane.maxs.z = p.z end
			end
		end
		face:ClearMeshData()
		if i % 25 == 0 then yield() end
	end

	local first = 1
	while first <= n do
		local last = math.min( first + MAX_MESH_VERTS - 1, n )
		local m = Mesh( plane.material )
		mesh.Begin( m, MATERIAL_TRIANGLES, ( last - first + 1 ) / 3 )
		for i = first, last do
			local v = verts[i]
			mesh.Position( v.pos )
			mesh.Normal( v.normal )
			mesh.TangentS( TANGENT_S )
			mesh.TangentT( TANGENT_T )
			mesh.TexCoord( 0, v.u * uvScale, v.v * uvScale )
			mesh.Color( 255, 255, 255, 255 )
			mesh.AdvanceVertex()
		end
		mesh.End()
		plane.meshes[#plane.meshes + 1] = m
		first = last + 1
		coroutine.yield()
	end
end

---Is the face flat and level? Then it is a surface of water, and the height is that of its corners.
---@return number? z
local function levelHeight( face )
	if face:IsDisplacement() then return nil end
	local corners = face:GetVertexs()
	if not corners or #corners < 3 then return nil end
	local z = corners[1].z
	for i = 2, #corners do
		if math.abs( corners[i].z - z ) > 0.5 then return nil end
	end
	return math.floor( z + 0.5 )
end

---Water planes combine many faces, sometimes across distant parts of the map.
---Their full bounds are conservative for PVS: they include every touching
---leaf, so an unknown leaf or oversized query keeps the plane visible.
local function preparePlanePVS( mini, plane )
	if plane.pvsBSP == mini.bsp then return end
	plane.pvsBSP, plane.pvsClusters = mini.bsp, nil
	local bsp = mini.bsp
	if not bsp or plane.mins.x > plane.maxs.x or plane.mins.y > plane.maxs.y or plane.mins.z > plane.maxs.z then return end
	local leaves = bsp:AABBInLeafs( 0, plane.mins, plane.maxs, PVS_BOUNDS_PAD )
	if #leaves == 0 or #leaves > PVS_MAX_LEAFS then return end

	local clusters, seen = {}, {}
	for _, leaf in ipairs( leaves ) do
		local cluster = leaf.cluster
		if cluster == nil or ( cluster < 0 and bit.band( leaf.contents or 0, CONTENTS_SOLID ) == 0 ) then return end
		if cluster >= 0 and not seen[cluster] then
			seen[cluster] = true
			clusters[#clusters + 1] = cluster
		end
	end
	if #clusters > 0 then plane.pvsClusters = clusters end
end

local function visibleInPVS( plane, pvs )
	local clusters = plane.pvsClusters
	if not pvs or not clusters then return true end
	if plane.checkedPVS ~= pvs then
		plane.checkedPVS, plane.pvsVisible = pvs, false
		for i = 1, #clusters do
			if pvs[clusters[i]] then plane.pvsVisible = true break end
		end
	end
	return plane.pvsVisible
end

-- A reflected eye is often in solid space, where its PVS is meaningless.
-- Instead union VIS from EVERY cluster touching the water at this height.
-- Whole plane bounds deliberately overestimate disconnected surface patches.
-- This depends on map geometry, not the camera: compile once, over several
-- frames, and keep the unculled path until the entire union is available.
local function compileReflectionPVS( mini, rec )
	local bsp = mini.bsp
	local vis = bsp:GetVisibility()
	if not vis or not vis.VisData or bsp:IsVisibilityCorrupted() then return end
	local wanted = {}
	for _, plane in ipairs( rec.planes ) do
		preparePlanePVS( mini, plane )
		if not plane.pvsClusters then return end
		for _, cluster in ipairs( plane.pvsClusters ) do wanted[cluster] = true end
	end
	local leaves = {}
	for _, leaf in pairs( bsp:GetLeafs() ) do
		if wanted[leaf.cluster] then leaves[leaf.cluster] = leaf end
	end
	local union, count = {}, 0
	for cluster in pairs( wanted ) do
		local leaf = leaves[cluster]
		if not leaf or not vis.VisData[cluster] then return end
		for id, visible in pairs( leaf:CreatePVS() ) do
			if type( id ) == "number" and visible then union[id] = true end
		end
		union[cluster] = true
		count = count + 1
		coroutine.yield()
	end
	if count > 0 then rec.reflectionPVS = union end
end

local function reflectionPVS( mini, rec )
	local enabled = cvReflectionPVS:GetBool()
	if PocketMap.Settings then enabled = PocketMap.Settings.Compat( mini, "reflection_pvs", cvReflectionPVS ) and PocketMap.Settings.Enabled( mini, "pvs" ) end
	if not enabled or not mini.bsp then return end
	if rec.reflectionPVSBSP ~= mini.bsp or rec.reflectionPVSPlanes ~= #rec.planes then
		rec.reflectionPVSBSP, rec.reflectionPVSPlanes = mini.bsp, #rec.planes
		rec.reflectionPVS = nil
		rec.reflectionPVSJob = coroutine.create( function() compileReflectionPVS( mini, rec ) end )
	end
	return rec.reflectionPVS
end

-- Explicit scene context also prevents ordinary world/sky views from using
-- a water visibility set accidentally.
function Water.ReflectionPVS( mini )
	local view = Water.pass == "reflection" and Water.sceneView
	local enabled = cvReflectionPVS:GetBool()
	if PocketMap.Settings then enabled = PocketMap.Settings.Compat( mini, "reflection_pvs", cvReflectionPVS ) and PocketMap.Settings.Enabled( mini, "pvs" ) end
	if view and view.mini == mini and enabled then return view.pvs end
end

PocketMap.Hooks.Register( "Think", "PocketMap_WaterVisibility", function()
	local deadline = SysTime() + 0.001
	for mini in pairs( PocketMap.Active or {} ) do
		for _, rec in pairs( mini.waterHeights or {} ) do
			while rec.reflectionPVSJob do
				local ok, err = coroutine.resume( rec.reflectionPVSJob )
				if not ok or coroutine.status( rec.reflectionPVSJob ) == "dead" then
					rec.reflectionPVSJob = nil
					if not ok then
						rec.reflectionPVS = nil
						ErrorNoHalt( "[PocketMap] Water visibility: " .. tostring( err ) .. "\n" )
					end
				end
				if SysTime() >= deadline then return end
			end
		end
	end
end )

---Runs inside the loader (it yields). Level faces become planes by height; faces that can't be planes are returned to be built normally.
---@param key string # the texture name of the faces
---@param material IMaterial
---@param faces table[]
---@return table[] rest
function Water.Build( mini, key, material, faces )
	if not mini.waterPlanes then
		mini.waterPlanes = {}
		mini.waterBeneath = 0
	end
	local planes = mini.waterPlanes

	local source = readVMT( key ) or readVMT( material:GetName() )

	-- The underside ($abovewater 0) repeats the surface polygons and would z-fight with them
	if ( source and tostring( source["$abovewater"] ) == "0" ) or string.find( string.lower( key ), "beneath", 1, true ) then
		mini.waterBeneath = mini.waterBeneath + #faces
		return {}
	end

	local byHeight, order, rest = {}, {}, {}

	for i, face in ipairs( faces ) do
		local z = levelHeight( face )
		if z then
			if not byHeight[z] and #order < MAX_PLANES - #planes then
				byHeight[z] = {}
				order[#order + 1] = z
			end
			if byHeight[z] then byHeight[z][#byHeight[z] + 1] = face else rest[#rest + 1] = face end
		else
			rest[#rest + 1] = face
		end
		face:ClearMeshData()
		if i % 500 == 0 then coroutine.yield() end
	end

	table.sort( order )
	for _, z in ipairs( order ) do
		local plane = makePlane( mini, key, z, source, material )
		if plane then
			plane.uvScale = waterUVScale( mini.scale )
			plane.faces = #byHeight[z]
			planes[#planes + 1] = plane
			local rec = heightRecord( mini, z )
			rec.planes[#rec.planes + 1] = plane
			buildMeshes( plane, byHeight[z], plane.uvScale )
			preparePlanePVS( mini, plane )
		else
			table.Add( rest, byHeight[z] )
		end
	end

	-- Sloped water and displacements get the tangent space but no effects
	if #rest == 0 then return {} end

	local loose = makePlane( mini, key, 0, source, material )
	if not loose then return rest end

	loose.loose, loose.faces = true, #rest
	loose.uvScale = waterUVScale( mini.scale )
	-- Loose water is sloped, so its bounds must include its actual Z range.
	loose.mins.z, loose.maxs.z = math.huge, -math.huge
	mini.waterLoose = mini.waterLoose or {}
	mini.waterLoose[#mini.waterLoose + 1] = loose
	buildMeshes( loose, rest, loose.uvScale )
	loose.bounds3D = true
	preparePlanePVS( mini, loose )
	return {}
end

-- Rebuild water already loaded before a clientside hot reload. Keep drawing the
-- old meshes until their replacements are ready, then swap each plane at once.
function Water.RebuildUVs( mini )
	if not mini or not mini.bsp then return false end
	if Water.uvRebuild and not Water.uvRebuild.done then return false end

	local groups, planes = {}, {}
	for _, list in ipairs( { mini.waterPlanes or {}, mini.waterLoose or {} } ) do
		for _, plane in ipairs( list ) do
			local group = groups[plane.key] or {}
			groups[plane.key] = group
			group[plane.loose and "loose" or plane.z] = plane
			planes[#planes + 1] = plane
		end
	end

	local job = { done = false, rebuilt = 0, skipped = 0, total = #planes }
	Water.uvRebuild = job
	local thread = coroutine.create( function()
		local facesByPlane = {}
		local count = 0
		for _, face in pairs( mini.bsp:GetFaces() ) do
			local group = groups[face:GetTexture()]
			if group then
				local plane = group[levelHeight( face ) or "loose"]
				if plane then
					facesByPlane[plane] = facesByPlane[plane] or {}
					facesByPlane[plane][#facesByPlane[plane] + 1] = face
				end
			end
			count = count + 1
			if count % 250 == 0 then coroutine.yield() end
		end

		local uvScale = waterUVScale( mini.scale )
		for _, plane in ipairs( planes ) do
			local faces = facesByPlane[plane] or {}
			if #faces ~= plane.faces then
				job.skipped = job.skipped + 1
			else
				local replacement = {
					material = plane.material, meshes = {},
					mins = Vector( math.huge, math.huge, math.huge ),
					maxs = Vector( -math.huge, -math.huge, -math.huge ),
				}
				job.building = replacement
				buildMeshes( replacement, faces, uvScale )
				if mini.state == "removed" then return end
				local old = plane.meshes
				plane.meshes, plane.uvScale = replacement.meshes, uvScale
				job.building = nil
				for _, meshObject in ipairs( old ) do meshObject:Destroy() end
				job.rebuilt = job.rebuilt + 1
			end
			coroutine.yield()
		end
	end )

	hook.Add( "Think", "PocketMap_WaterUVRebuild", function()
		local deadline = SysTime() + 0.002
		repeat
			local ok, err = coroutine.resume( thread )
			if not ok then job.error = tostring( err ) end
			if not ok or coroutine.status( thread ) == "dead" then
				if job.building then
					for _, meshObject in ipairs( job.building.meshes ) do meshObject:Destroy() end
					job.building = nil
				end
				job.done = true
				hook.Remove( "Think", "PocketMap_WaterUVRebuild" )
				return
			end
		until SysTime() >= deadline
	end )
	return true
end

function Water.Free( mini )
	for _, plane in ipairs( mini.waterPlanes or {} ) do
		for _, m in ipairs( plane.meshes ) do m:Destroy() end
	end
	for _, plane in ipairs( mini.waterLoose or {} ) do
		for _, m in ipairs( plane.meshes ) do m:Destroy() end
	end
	mini.waterPlanes, mini.waterLoose = {}, {}

	for _, rec in pairs( mini.waterHeights or {} ) do releaseHeightTargets( rec ) end
	mini.waterHeights = nil
	releaseFlats( mini )
end

local boxVisible, planeWorldBounds

---Only cull against the main camera when the recorded view matches the one actually drawing.
---Nested cameras and older, already loaded loose water keep their original behavior.
local function drawView( mini )
	if render.GetRenderTarget and render.GetRenderTarget() then return end
	local view = Water.view
	if not view or view.frame ~= FrameNumber() or not view.origin or not view.angles or not view.fov or view.fov <= 0 or view.fov >= 170 then return end
	local sceneView = PocketMap.Scene and PocketMap.Scene.View( mini )
	local eye = sceneView and sceneView.origin or EyePos()
	local angles = sceneView and sceneView.angles or EyeAngles()
	if eye:DistToSqr( view.origin ) > 1 then return end
	if angles:Forward():Dot( view.angles:Forward() ) < 0.999 then return end
	-- NoteView replaces this record when the camera changes; both render passes
	-- can reuse the same frustum instead of building it twice per miniature.
	if not view.waterDrawView then
		view.waterDrawView = { origin = view.origin, angles = view.angles, fov = view.fov,
			aspect = ScrW() / math.max( ScrH(), 1 ) }
	end
	return view.waterDrawView
end

local function drawPlanes( mini, planes, materials, currentMaterial, view, pvs )
	for _, plane in ipairs( planes ) do
		-- Also handles water planes already loaded before a clientside hot reload.
		if plane.pvsBSP ~= mini.bsp then preparePlanePVS( mini, plane ) end
		if #plane.meshes > 0 and visibleInPVS( plane, pvs ) then
			local visible = true
			if view and ( not plane.loose or plane.bounds3D ) then
				local mins, maxs = planeWorldBounds( mini, plane )
				if mins then visible = boxVisible( mins, maxs, 1, view ) end
			end
			if visible then
				local changed = bind( plane, materials, mini )
				if changed or currentMaterial ~= plane.material then
					render.SetMaterial( plane.material )
					currentMaterial = plane.material
				end
				for _, m in ipairs( plane.meshes ) do m:Draw() end
			end
		end
	end
	return currentMaterial
end

local function drawWater( mini, planes, loose, materials, view, pvs )
	local currentMaterial = drawPlanes( mini, planes, materials, nil, view, pvs )
	if loose then drawPlanes( mini, loose, materials, currentMaterial, view, pvs ) end
end

---Not drawn inside its own reflection and refraction. Restore shared material parameters even if a mesh fails to draw.
function Water.Draw( mini )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "water_surface" ) then return end
	local planes, loose = mini.waterPlanes, mini.waterLoose
	if Water.pass or not planes or ( #planes == 0 and ( not loose or #loose == 0 ) ) then return end
	for _, plane in ipairs( planes ) do resolveOldFog( mini, plane ) end
	for _, plane in ipairs( loose or {} ) do resolveOldFog( mini, plane ) end

	local view = drawView( mini )
	-- The opaque world was drawn immediately before water, using this same
	-- view. Its PVS is valid only for the walker's camera inside the miniature.
	local pvs = view and mini.worldPVSActive and ( PocketMap.PVSFreeze.Get( mini ) or mini.worldPVS )
	local materials = {}
	cam.PushModelMatrix( mini.matrix )
	local ok, err = pcall( drawWater, mini, planes, loose, materials, view, pvs )
	for material, saved in pairs( materials ) do unbind( material, saved ) end
	cam.PopModelMatrix()
	if not ok then error( err, 0 ) end
end

---The shader looks the reflection up with the projection of the main view, so nested views need the same one. A point is projected
---by both, and since screen position scales with 1 / tan( fov / 2 ) the ratio gives the fov that makes them match.
function Water.Calibrate( mini )
	local mode = PocketMap.Settings and PocketMap.Settings.WaterMode( mini, cvWater ) or cvWater:GetInt()
	if Water.broken or mode == 0 then return end
	local setup = render.GetViewSetup()
	if not setup then return end

	local screenW, screenH = ScrW(), ScrH()
	if Water.calibratedW == screenW and Water.calibratedH == screenH and Water.calibratedFov == setup.fov and CurTime() < ( Water.nextCalibrate or 0 ) then return end
	Water.calibratedW, Water.calibratedH, Water.calibratedFov, Water.nextCalibrate = screenW, screenH, setup.fov, CurTime() + 5

	local origin, angles = setup.origin, setup.angles
	local point = origin + angles:Forward() * 1000 + angles:Right() * 500 + angles:Up() * 300

	local halfW, halfH = screenW / 2, screenH / 2
	local main = point:ToScreen()
	if not main.visible then return end
	local mx, my = ( main.x - halfW ) / halfW, ( halfH - main.y ) / halfH

	local candidate = Water.fovParam or setup.fov
	cam.Start3D( origin, angles, candidate, 0, 0, screenW, screenH, setup.znear, setup.zfar )
	local nested = point:ToScreen()
	cam.End3D()
	local nx, ny = ( nested.x - halfW ) / halfW, ( halfH - nested.y ) / halfH

	Water.measure = { main = { mx, my }, nested = { nx, ny }, candidate = candidate, setupFov = setup.fov }

	if nested.visible and math.abs( mx ) > 0.05 and math.abs( nx ) > 0.001 then
		local k = nx / mx
		if math.abs( k - 1 ) > 0.002 then
			Water.fovParam = math.Clamp( math.deg( 2 * math.atan( math.tan( math.rad( candidate ) / 2 ) * k ) ), 10, 170 )
		else
			Water.fovParam = candidate
		end
	end
end

function Water.NoteView( origin, angles, fov, znear, zfar )
	Water.view = { origin = origin, angles = angles, fov = fov, znear = znear, zfar = zfar, frame = FrameNumber() }
end

---Conservative frustum test of an axis-aligned box. The support radius keeps intersecting boxes visible.
boxVisible = function( mins, maxs, pad, view )
	local frustum = view.frustum
	if not frustum then
		local forward, right, up = view.angles:Forward(), view.angles:Right(), view.angles:Up()
		local halfH = math.tan( math.rad( view.fov ) / 2 ) * math.max( 1, view.aspect / ( 4 / 3 ) ) * 1.3
		local halfV = halfH / view.aspect
		frustum = { forward, forward * halfH + right, forward * halfH - right, forward * halfV + up, forward * halfV - up }
		view.frustum = frustum
	end

	local x, y, z = ( mins.x + maxs.x ) * 0.5, ( mins.y + maxs.y ) * 0.5, ( mins.z + maxs.z ) * 0.5
	local dx, dy, dz = x - view.origin.x, y - view.origin.y, z - view.origin.z
	local ex, ey, ez = ( maxs.x - mins.x ) * 0.5 + pad, ( maxs.y - mins.y ) * 0.5 + pad, ( maxs.z - mins.z ) * 0.5 + pad
	for _, normal in ipairs( frustum ) do
		local distance = dx * normal.x + dy * normal.y + dz * normal.z
		local radius = ex * math.abs( normal.x ) + ey * math.abs( normal.y ) + ez * math.abs( normal.z )
		if distance + radius < 0 then return false end
	end
	return true
end

local function withTarget( rt, fn )
	render.PushRenderTarget( rt )
	local ok, err = pcall( fn )
	render.PopRenderTarget()
	if not ok then error( err, 0 ) end
end

---Fitted around the block: with the range of the game everything in it would land in a sliver of the depth buffer.
local function depthRange( mini, origin, view )
	local boxMins, boxMaxs = mini.ent.BoxMins, mini.ent.BoxMaxs
	local znear, zfar = view.znear or 7, view.zfar or 30000
	if not boxMins or not boxMaxs then return znear, zfar end

	local center = mini.ent:LocalToWorld( ( boxMins + boxMaxs ) * 0.5 )
	local radius = ( boxMaxs - boxMins ):Length() * 0.5 + 8
	local dist = origin:Distance( center )
	znear = math.max( znear, dist - radius )
	zfar = math.min( zfar, dist + radius )
	if zfar <= znear then zfar = znear + 1 end
	return znear, zfar
end

local function in3D( plane, origin, angles, view, znear, zfar, fn )
	cam.Start3D( origin, angles, view.fov, 0, 0, plane.w, plane.h, znear, zfar )
	local ok, err = pcall( fn )
	cam.End3D()
	if not ok then error( err, 0 ) end
end

local function drawSceneClipped( mini, normal, distance, sceneView )
	local oldClipping = render.EnableClipping( true )
	render.PushCustomClipPlane( normal, distance )
	local previousView = Water.sceneView
	sceneView.clipNormal, sceneView.clipDistance = normal, distance
	Water.sceneView = sceneView
	local ok, err = pcall( mini.DrawScene, mini, mini:WaterDrawOptions() )
	Water.sceneView = previousView
	render.PopCustomClipPlane()
	render.EnableClipping( oldClipping )
	if not ok then error( err, 0 ) end
end

-- Mesh/model bounds use block coordinates. Transform the scene's clip plane
-- once per view, so fully clipped objects never reach expensive draw calls.
function Water.ClipPlane( mini )
	local view = Water.pass and Water.sceneView
	if not view or not view.clipNormal or not view.clipDistance then return end
	local position = mini.ent:GetPos()
	local normal = mini.ent:WorldToLocal( position + view.clipNormal )
	return { normal = normal, distance = view.clipDistance - view.clipNormal:Dot( position ) }
end

local function drawMirroredSky( mini, plane, origin, angles, view, znear, zfar )
	render.Clear( 0, 0, 0, 255, true, true )
	-- The sky cube is 1024 units from the eye. The miniature's depth
	-- range is often shorter, which clips away the sky in reflections.
	in3D( plane, origin, angles, view, znear, math.max( zfar, 2048 ), function()
		PocketMap.Sky.DrawCube( mini, origin, { angles = angles, fov = view.fov, w = plane.w, h = plane.h } )
	end )
	render.ClearDepth()
end

---Pitch and roll are negated and the eye is mirrored in the water, as in CAboveWaterView::CReflectionView.
local function renderReflection( mini, plane, zWorld, spread, view, required )
	Water.pass = "reflection"

	withTarget( plane.reflectRT, function()
		render.Clear( plane.fog.r, plane.fog.g, plane.fog.b, 255, true, true )

		local angles = Angle( -view.angles.p, view.angles.y, -view.angles.r )
		local origin = Vector( view.origin.x, view.origin.y, 2 * zWorld - view.origin.z )
		local znear, zfar = depthRange( mini, origin, view )

		if mini.skyBackdrop and ( not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "water_reflect_sky" ) ) then
			drawMirroredSky( mini, plane, origin, angles, view, znear, zfar )
		end

		in3D( plane, origin, angles, view, znear, zfar, function()
			drawSceneClipped( mini, Vector( 0, 0, 1 ), zWorld - spread,
				{ origin = origin, angles = angles, fov = view.fov, width = plane.w, height = plane.h,
					mini = mini, pvs = required and required.pvs,
					reflectEntities = not required or required.reflectEntities } )
		end )
	end )
end

-- Water samples fog thickness from refraction alpha, not the main framebuffer's
-- camera-depth alpha. Height fog selects Source's water-fog shader combination.
local function renderRefraction( mini, plane, zWorld, spread, view )
	Water.pass = "refraction"
	withTarget( plane.refractRT, function()
		render.Clear( plane.fog.r, plane.fog.g, plane.fog.b, 255, true, true )
		local znear, zfar = depthRange( mini, view.origin, view )
		in3D( plane, view.origin, view.angles, view, znear, zfar, function()
			local mode = render.GetFogMode()
			local first, last, height = render.GetFogDistances()
			local r, g, b = render.GetFogColor()
			local density = render.GetFogMaxDensity()
			render.SetWriteDepthToDestAlpha( false )
			render.FogMode( MATERIAL_FOG_LINEAR_BELOW_FOG_Z )
			render.SetFogZ( zWorld )
			render.FogStart( plane.fogStart )
			render.FogEnd( plane.fogEnd )
			render.FogColor( plane.fog.r, plane.fog.g, plane.fog.b )
			render.FogMaxDensity( 1 )
			local ok, err = pcall( drawSceneClipped, mini, Vector( 0, 0, -1 ), -zWorld - spread,
				{ origin = view.origin, angles = view.angles, fov = view.fov, width = plane.w, height = plane.h } )
			render.FogMode( mode )
			render.FogStart( first ) render.FogEnd( last ) render.SetFogZ( height )
			render.FogColor( r, g, b ) render.FogMaxDensity( density )
			render.SetWriteDepthToDestAlpha( true )
			if not ok then error( err, 0 ) end
		end )
	end )
end

local function renderPlane( mini, plane, zWorld, spread, view, pass, required )
	local toneScale = render.GetToneMappingScaleLinear and render.GetToneMappingScaleLinear()
	local hdr = toneScale and render.GetHDREnabled and render.GetHDREnabled()

	local ok, err = pcall( function()
		if pass ~= "reflection" and ( not required or required.refraction ) then renderRefraction( mini, plane, zWorld, spread, view ) end
		if pass ~= "refraction" and ( not required or required.reflection ) then
			if hdr then render.SetToneMappingScaleLinear( toneScale * REFLECTION_TONE_SCALE ) end
			renderReflection( mini, plane, zWorld, spread, view, required )
		end
	end )
	if toneScale then render.SetToneMappingScaleLinear( toneScale ) end

	Water.pass = nil
	if not ok then error( err, 0 ) end
end

local WATER_MAX_TILT = 0.5
local BOX_PAD_SCALE = 64

local function engineView()
	local setup = render.GetViewSetup and render.GetViewSetup()
	return setup and setup.origin and setup or nil
end

---The view of this frame for the effects, or nil when they are off.
local function currentEffectsView()
	if Water.broken or not PocketMap.Settings and not cvWater:GetBool() then return nil end

	local view = Water.view
	if not view or view.frame ~= FrameNumber() then view = engineView() end
	if not view then return nil end

	return { origin = view.origin, angles = view.angles, fov = Water.fovParam or view.fov, aspect = ScrW() / ScrH(), znear = view.znear, zfar = view.zfar }
end

local function markPlanesNotRendered( mini )
	for _, plane in ipairs( mini.waterPlanes or {} ) do plane.rendered = false end
	for _, plane in ipairs( mini.waterLoose or {} ) do plane.rendered = false end
end

---Only with the eye inside the block: from outside the tiny map is too small to be worth two more draws a frame.
local function wantsEffects( mini, view )
	if PocketMap.Settings and PocketMap.Settings.WaterMode( mini, cvWater ) == 0 then return false end
	local planes = mini.waterPlanes
	if not view or not planes or #planes == 0 then return false end

	return mini.state == "ready" and IsValid( mini.ent ) and mini.scaleVec ~= nil and mini.lightmapTexture ~= nil and mini:EyeInside()
end

local function isBlockLevel( ent )
	local ang = ent:GetAngles()
	return math.abs( math.NormalizeAngle( ang.p ) ) < WATER_MAX_TILT and math.abs( math.NormalizeAngle( ang.r ) ) < WATER_MAX_TILT
end

---The water plane's bounds in world space, also used for culling its draw call.
planeWorldBounds = function( mini, plane )
	if mini.matrixFrame and plane.worldFrame == mini.matrixFrame then
		return plane.worldMins, plane.worldMaxs, plane.worldHeight
	end
	if plane.mins.x > plane.maxs.x or plane.mins.y > plane.maxs.y or plane.mins.z > plane.maxs.z then return end

	local m = mini.matrix
	local wmins = Vector( math.huge, math.huge, math.huge )
	local wmaxs = Vector( -math.huge, -math.huge, -math.huge )
	local height = ( m * Vector( plane.mins.x, plane.mins.y, plane.z ) ).z

	for _, x in ipairs( { plane.mins.x, plane.maxs.x } ) do
		for _, y in ipairs( { plane.mins.y, plane.maxs.y } ) do
			for _, z in ipairs( { plane.mins.z, plane.maxs.z } ) do
				local corner = m * Vector( x, y, z )
				wmins.x, wmins.y, wmins.z = math.min( wmins.x, corner.x ), math.min( wmins.y, corner.y ), math.min( wmins.z, corner.z )
				wmaxs.x, wmaxs.y, wmaxs.z = math.max( wmaxs.x, corner.x ), math.max( wmaxs.y, corner.y ), math.max( wmaxs.z, corner.z )
			end
		end
	end

	if mini.matrixFrame then
		plane.worldFrame, plane.worldMins, plane.worldMaxs, plane.worldHeight = mini.matrixFrame, wmins, wmaxs, height
	end
	return wmins, wmaxs, height
end

---Fog distances are source-map lengths; scale them once without an eye-distance bias.
local function updatePlaneFog( plane, scale )
	if not plane.sourceFogEnd then
		local _, _, first, last = materialFog( plane.material )
		plane.sourceFogStart, plane.sourceFogEnd = first, last
	end
	plane.fogStart, plane.fogEnd = plane.sourceFogStart * scale, plane.sourceFogEnd * scale
end

local function turnOffEffects( err )
	Water.pass = nil
	Water.sceneView = nil
	Water.broken, Water.error = true, tostring( err )
	ErrorNoHalt( "[PocketMap] The water reflection / refraction failed and is turned off: " .. Water.error .. "\n" )
end

local function isNearer( a, b )
	return a.distanceSqr < b.distanceSqr
end

-- PreRender runs before the world draw updates mini.worldPVS. Resolve VIS
-- from this frame's effects camera, rather than reusing the previous frame
-- or rendering scenes for water the main view will never draw.
local function effectsPVS( mini, view )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "pvs" ) then return end
	local walk = PocketMap.Walk and PocketMap.Walk.session
	if not walk or walk.mini ~= mini or not mini.bsp or not mini.scale or mini.scale <= 0 then return end
	local frozen = PocketMap.PVSFreeze.Get( mini )
	if frozen then return frozen end
	local bsp = mini.bsp
	local eye = ( mini.ent:WorldToLocal( view.origin ) - mini.boxCenter ) / mini.scale + mini.mapCenter
	local cluster = bsp:ClusterFromPoint( eye )
	if not cluster or cluster < 0 then return end
	local vis = bsp:GetVisibility()
	if not vis or not vis.VisData or not vis.VisData[cluster] or bsp:IsVisibilityCorrupted() then return end
	if mini.waterEffectsPVSBSP ~= bsp or mini.waterEffectsPVSCluster ~= cluster then
		mini.waterEffectsPVSBSP, mini.waterEffectsPVSCluster = bsp, cluster
		mini.waterEffectsPVS = bsp:PVSForOrigin( eye )
	end
	return mini.waterEffectsPVS
end

---The heights of water that are in view, nearest first. One plane stands for its height: its box decides if it is in view, its fog is the one drawn.
local function visibleHeights( mini, view, scale )
	local found = {}
	local pvs = effectsPVS( mini, view )
	local forceEntities = GetConVar and GetConVar( "r_waterforcereflectentities" )
	forceEntities = forceEntities and forceEntities:GetBool()

	for _, rec in pairs( mini.waterHeights or {} ) do
		local entry
		for _, plane in ipairs( rec.planes ) do
			ensurePlaneMode( mini, plane )
			if plane.pvsBSP ~= mini.bsp then preparePlanePVS( mini, plane ) end
			if not plane.cheap and visibleInPVS( plane, pvs ) then
				local wmins, wmaxs, zWorld = planeWorldBounds( mini, plane )
				if wmins and view.origin.z > zWorld
					and boxVisible( wmins, wmaxs, BOX_PAD_SCALE * scale, view ) then
					if not entry then
						entry = { rec = rec, plane = plane, zWorld = zWorld, distanceSqr = view.origin:DistToSqr( ( wmins + wmaxs ) * 0.5 ), reflection = false, refraction = false, reflectEntities = false }
					end
					entry.reflection = entry.reflection or plane.reflectScene and ( not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "water_reflections" ) )
					entry.refraction = entry.refraction or plane.refractScene and ( not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "water_refractions" ) )
					entry.reflectEntities = entry.reflectEntities or ( plane.reflectScene and ( forceEntities or plane.reflectEntities )
						and ( not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "water_reflect_props" ) or PocketMap.Settings.Enabled( mini, "water_reflect_entities" ) ) )
				end
			end
		end
		if entry and ( entry.reflection or entry.refraction ) then found[#found + 1] = entry end
	end

	table.sort( found, isNearer )
	return found
end

---Draws the reflection and refraction of a height. All the planes at that height show it.
---@return boolean ok # false if the effects failed and were turned off
local function renderHeight( mini, entry, view, scale )
	local rec = entry.rec
	local mode = PocketMap.Settings and PocketMap.Settings.WaterMode( mini, cvWater ) or cvWater:GetInt()
	local budgeted = mode == 1
	-- Projected textures belong to the camera that rendered them. A moving
	-- camera or block needs both targets refreshed together to stay aligned.
	local pos, angles = mini.ent:GetPos(), mini.ent:GetAngles()
	local old = rec.camera
	if not old or old.origin ~= view.origin or old.angles ~= view.angles or old.fov ~= view.fov
		or old.pos ~= pos or old.rotation ~= angles
		or old.reflection ~= entry.reflection or old.refraction ~= entry.refraction
		or old.reflectEntities ~= entry.reflectEntities then
		budgeted = false
		rec.camera = { origin = Vector( view.origin ), angles = Angle( view.angles ), fov = view.fov,
			pos = Vector( pos ), rotation = Angle( angles ), reflection = entry.reflection, refraction = entry.refraction,
			reflectEntities = entry.reflectEntities }
	end
	local now = SysTime()
	if budgeted and Water.budgetFrame == FrameNumber() then
		-- Another visible height used this frame's render slot. Keep this
		-- height's valid targets alive: clearIdlePlanes would otherwise release
		-- them, forcing both scenes to be rebuilt on the following frame.
		if rec.valid and rec.reflect then
			rec.lastFrame = FrameNumber()
			for _, plane in ipairs( rec.planes ) do plane.lastFrame, plane.rendered = rec.lastFrame, true end
		end
		return true
	end
	if not acquireHeightTargets( rec, mini ) then return true end
	if budgeted and rec.valid and now < ( rec.nextRefresh or 0 ) then
		rec.lastFrame = FrameNumber()
		for _, plane in ipairs( rec.planes ) do plane.lastFrame, plane.rendered = rec.lastFrame, true end
		return true
	end

	local pass = budgeted and rec.valid and rec.nextPass or nil
	if pass and not entry.reflection then pass = "refraction" end
	if pass and not entry.refraction then pass = "reflection" end
	local ok, err = pcall( renderPlane, mini, entry.plane, entry.zWorld, SPREAD * scale, view, pass, entry )
	if not ok then
		turnOffEffects( err )
		return false
	end

	rec.valid = true
	if budgeted then
		Water.budgetFrame = FrameNumber()
		rec.nextRefresh = now + BUDGETED_REFRESH_SECONDS
		rec.nextPass = pass == "refraction" and "reflection" or "refraction"
	end
	rec.lastFrame = FrameNumber()
	for _, plane in ipairs( rec.planes ) do
		plane.lastFrame, plane.rendered, plane.cleared = rec.lastFrame, true, false
	end
	return true
end

---@return boolean ok # false if the effects failed and were turned off
local function renderEffects( mini, view )
	mini:UpdateMatrix()

	local ent = mini.ent
	local scale = mini.scaleVec.x

	for _, plane in ipairs( mini.waterPlanes ) do updatePlaneFog( plane, scale ) end
	if not isBlockLevel( ent ) then return true end

	local found = visibleHeights( mini, view, scale )
	for i = 1, math.min( #found, MAX_RENDERED_HEIGHTS ) do
		if found[i].reflection then found[i].pvs = reflectionPVS( mini, found[i].rec ) end
		if not renderHeight( mini, found[i], view, scale ) then return false end
	end
	return true
end

---A plane with no effects this frame holds its fog color (once), not whatever the target had.
local function clearIdlePlanes( mini )
	-- An inactive water height has shared full-size render targets. Return them
	-- before clearing so toggling effects off never clears large targets needlessly.
	for _, rec in pairs( mini.waterHeights or {} ) do
		if rec.reflect and not rec.planes[1].rendered then releaseHeightTargets( rec ) end
	end
	for _, plane in ipairs( mini.waterPlanes or {} ) do
		if not plane.rendered and not plane.cleared then clearPlane( plane ) end
	end
	for _, plane in ipairs( mini.waterLoose or {} ) do
		if not plane.cleared then clearPlane( plane ) end
	end
end

PocketMap.Hooks.Register( "PreRender", "PocketMap_Water", function()
	if Water.pass or not PocketMap.Active then return end

	local view = currentEffectsView()

	for mini in pairs( PocketMap.Active ) do
		markPlanesNotRendered( mini )

		if wantsEffects( mini, view ) and not renderEffects( mini, view ) then return end

		releaseIdleTargets( mini )
		clearIdlePlanes( mini )
	end
end )
