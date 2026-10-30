-- Turns a .bsp into something that can be drawn. It runs as a coroutine: every coroutine.yield() ends a step of a few
-- milliseconds, so the work is spread over many frames instead of freezing the game. The stages hand what the next one needs on in `job`.
--
--   1. open map            NikNaks.Map( name )                          the header only: lumps are parsed when first asked for
--   2. read lumps          bsp:GetFaces(), GetPlanes() ...              each lump in a step of its own
--   3. fit to block        PocketMap.FitMap                             scale and offset of the map inside the block
--   4. read entities       bsp:GetEntities()                            key-values of every entity, and the sky
--   5. sort faces          face:IsWorld(), face:GetTexture() ...        cl_faces.lua
--   6. load materials      Material()                                   one per group of faces
--   7. prepare light       bsp:GetLumpString( 8 )                       cl_atlas.lua
--   8. build world meshes  NikNaks.MeshBuilder()                        faces -> meshes, a slice at a time
--   9. collect props       bsp:GetStaticProps(), entities               cl_props.lua
--  10. detail props        bsp:GetDetailPropInfo()                      cl_detail.lua
--  11. place props         leaf:CalculateAmbientCube()                  cl_props.lua, cl_proplight.lua

if not PocketMap.Mini then return end

PocketMap.Loader = {}
local Loader = PocketMap.Loader

local Mini = PocketMap.Mini
local Water = PocketMap.Water

local cvLightToggle = CreateClientConVar( "pocketmap_lighttoggle", "1", true, false, "Light styles of a face are added: switchable and animated lights are part of the light.", 0, 1 )
local cvPropMeshes = CreateClientConVar( "pocketmap_propmeshes", "1", true, false, "Models are baked into the tiny map. Off: every model is a ClientsideModel (static-only models are baked either way).", 0, 1 )

local SLOW_MATERIAL_SECONDS = 0.5
local MATERIAL_FRAME_SECONDS = 0.1
local FACES_PER_YIELD = 10
local LDR_LIGHTING_LUMP, HDR_LIGHTING_LUMP, HDR_FACES_LUMP = 8, 53, 58
local MORE = "more"

local function openMap( mini, job )
	mini:SetStatus( "Opening the map", 0 )

	local bsp, err = NikNaks.Map( mini.mapName )
	if not bsp then
		mini:Fail( "Could not open maps/" .. mini.mapName .. ".bsp (NikNaks error " .. tostring( err ) .. ")" )
		return false
	end

	mini.bsp, job.bsp = bsp, bsp
	coroutine.yield()
	return true
end

---Each takes 10-100 ms the first time. Reading them here keeps that out of the steps that build meshes.
local function readLumps( mini, job )
	local bsp = job.bsp
	local lumps = {
		{ "brush models", bsp.GetBModels },
		{ "planes", bsp.GetPlanes },
		{ "vertices", bsp.GetVertex },
		{ "edges", bsp.GetEdges },
		{ "surface edges", bsp.GetSurfEdges },
		{ "texture info", bsp.GetTexInfo },
		{ "texture data", bsp.GetTexData },
		{ "nodes and leafs", bsp.GetNodes },
		{ "collision brushes", bsp.GetBrushes },
		{ "leaf brushes", bsp.GetLeafBrushes },
		{ "faces", bsp.GetFaces },
		{ "displacements", bsp.GetDispInfo },
		{ "displacement vertices", bsp.GetDispVerts },
	}

	for i, lump in ipairs( lumps ) do
		mini:SetStatus( "Reading " .. lump[1], 0.04 * ( i - 1 ) / #lumps )
		lump[2]( bsp )
		coroutine.yield()
	end
end

---A point P of the map ends up at ( P - mapCenter ) * scale + boxCenter in the block.
local function fitToBlock( mini, job )
	local fit, err = PocketMap.FitMap( job.bsp, mini.ent, coroutine.yield )
	if not fit then
		mini:Fail( err )
		return false
	end

	job.scale, job.skyArea = fit.scale, fit.skyArea

	mini.fit = fit
	mini.mapMins, mini.mapMaxs, mini.mapCenter, mini.boxCenter = fit.mins, fit.maxs, fit.mapCenter, fit.boxCenter
	mini.negCenter = -fit.mapCenter
	mini.scale = fit.scale
	mini.scaleVec = Vector( fit.scale, fit.scale, fit.scale )
	mini.skyOrigin, mini.skyScale, mini.skyReach, mini.skyScaleEff = fit.skyOrigin, fit.skyScale, fit.skyReach, fit.skyScaleEff
	return true
end

local function readEntities( mini, job )
	mini:SetStatus( "Reading the entities", 0.03 )
	job.entities = job.bsp:GetEntities()
	coroutine.yield()

	PocketMap.Sky.Read( mini, job.entities )
end

---Mostly the engine reading files, and a fast one costs next to nothing, so as many as possible are loaded in one frame:
---only a slow one ends it. Material() says how long each took.
local function loadMaterials( mini, job )
	local order = job.materialOrder
	job.materials = {}

	for i, key in ipairs( order ) do
		mini:SetStatus( "Material " .. key, 0.05 + 0.1 * ( i - 1 ) / #order )

		local material, seconds = PocketMap.Materials.Load( key )
		job.materials[key] = material

		mini.materialsLoaded = mini.materialsLoaded + 1
		mini.slowestMaterial = math.max( mini.slowestMaterial, seconds )

		coroutine.yield( seconds < SLOW_MATERIAL_SECONDS and MORE or nil )
	end
end

local function hasLighting( bsp )
	local lumps = bsp._lumpheader
	local ldr = lumps[LDR_LIGHTING_LUMP].filelen > 0
	local hdr = lumps[HDR_LIGHTING_LUMP].filelen > 0 and lumps[HDR_FACES_LUMP].filelen > 0
	return ldr, hdr
end

local function allFaces( job )
	local faces = {}
	for _, groups in ipairs( { job.groups, job.skyGroups } ) do
		for _, list in pairs( groups ) do table.Add( faces, list ) end
	end
	return faces
end

---The faces get lightmap coordinates into the atlas. Without one the map is drawn fullbright.
local function prepareLight( mini, job )
	local bsp = job.bsp
	mini.lightStyles = PocketMap.LightStyles.Analyze( job.entities, mini.mapName )
	mini.lightStyleWeights = mini.lightStyles.weights
	job.addOptions = { light = false }

	local ldr, hdr = hasLighting( bsp )
	if ldr or hdr then
		local useHDR = hdr and not ldr

		mini:SetStatus( "Reading the lighting", 0.05 )
		mini.lighting = useHDR and "HDR" or "LDR"
		coroutine.yield()

		local atlas, lightUV = PocketMap.Atlas.Build( mini, allFaces( job ), useHDR, cvLightToggle:GetBool() )
		if atlas then
			mini.lightmapTexture = atlas
			job.addOptions.lightUV = lightUV
		else
			print( "[PocketMap] " .. mini.mapName .. ": no lightmap atlas (" .. tostring( mini.atlasFail or "unknown reason" ) .. ")" )
		end
	end
	coroutine.yield()
end

local function buildSlice( list, first, last, addOptions )
	local builder = NikNaks.MeshBuilder()

	for i = first, last do
		builder:AddFace( list[i], addOptions )
		if ( i - first ) % FACES_PER_YIELD == FACES_PER_YIELD - 1 then coroutine.yield() end
	end

	local object = builder:Build()
	for i = first, last do list[i]:ClearMeshData() end
	return object
end

---@param out table # collects the MeshObjects
local function buildMaterialGroups( mini, job, groups, order, out, isWorld, progress )
	for _, key in ipairs( order ) do
		local list = groups[key]
		local material = job.materials[key]

		-- Flat water surfaces get the effects of cl_water.lua, which need the atlas
		if isWorld and mini.lightmapTexture and Water.IsWaterMaterial( material ) then
			list = Water.Build( mini, key, material, list )
		end

		-- Whatever the name of the texture was, this material is the sky's debug material
		if material and PocketMap.Materials.IsSkyName( material:GetName() ) then
			mini.skippedSkyFaces = ( mini.skippedSkyFaces or 0 ) + #list
			list = {}
		end

		job.addOptions.material = material
		for first = 1, #list, PocketMap.Faces.SLICE_SIZE do
			mini:SetStatus( "Building " .. key, 0.15 + 0.45 * progress.done / job.slicesTotal )
			out[#out + 1] = buildSlice( list, first, math.min( first + PocketMap.Faces.SLICE_SIZE - 1, #list ), job.addOptions )

			progress.done = progress.done + 1
			coroutine.yield()
		end
		groups[key] = nil
	end
end

local function buildWorldMeshes( mini, job )
	local progress = { done = 0 }

	buildMaterialGroups( mini, job, job.groups, job.order, mini.objects, true, progress )
	if mini.lightmapTexture then buildMaterialGroups( mini, job, job.skyGroups, job.skyOrder, mini.skyObjects, false, progress ) end

	job.addOptions = nil
	coroutine.yield()
end

local function mountPackedMaterialsIfPossible( mini, job )
	mini:SetStatus( "Mounting packed textures", 0.01 )

	local ok, result = pcall( PocketMap.Pak.Mount, job.bsp, coroutine.yield )
	if ok then
		mini.packedMaterials = result
	else
		print( "[PocketMap] " .. mini.mapName .. ": the packed materials were not mounted (" .. tostring( result ) .. ")" )
	end
	coroutine.yield()
end

function Loader.Run( mini )
	local job = {}

	if not openMap( mini, job ) then return end
	mountPackedMaterialsIfPossible( mini, job )
	readLumps( mini, job )
	if not fitToBlock( mini, job ) then return end
	readEntities( mini, job )
	PocketMap.Faces.Sort( mini, job )
	PocketMap.Displacements.Build( mini, job, coroutine.yield )
	loadMaterials( mini, job )
	prepareLight( mini, job )
	buildWorldMeshes( mini, job )
	PocketMap.Props.Collect( mini, job )
	PocketMap.Detail.Build( mini, job )
	PocketMap.Props.Place( mini, job, cvLightToggle:GetBool(), cvPropMeshes:GetBool() )

	mini.state = "ready"
	mini:SetStatus( "", 1 )
end

---Runs the loader for a while. A step that says "more" was cheap (a material that loaded fast), so the next one goes in this
---frame too, even when the time budget is used.
---@param deadline number # SysTime to stop at (at least one step is always done)
function Loader.Step( mini, deadline )
	local co = mini.co
	if mini.state ~= "loading" or not co then return end

	local started = SysTime()

	repeat
		local ok, hint = coroutine.resume( co )
		if not ok then
			mini:Fail( "Error while loading: " .. tostring( hint ) )
			ErrorNoHalt( tostring( hint ) .. "\n" )
			return
		end

		local now = SysTime()
		local goOn = now < deadline or ( hint == MORE and now - started < MATERIAL_FRAME_SECONDS )
	until coroutine.status( co ) == "dead" or not goOn
end
