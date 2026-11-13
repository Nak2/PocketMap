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
-- Larger world batches cut draw calls; MeshBuilder splits at its vertex limit.
-- Keep the 3D skybox's smaller batches for its existing draw path.
local WORLD_SLICES_PER_MESH = 4
local WORLD_CELL_SIZE = 1024
local WORLD_MIN_CELL_FACES = 24
local WORLD_SPARSE_CELL_SIZE = 4096
local WORLD_PVS_MAX_SPAN = 1536
local WORLD_PVS_MAX_LEAFS = 128
local WORLD_PVS_PAD = 8
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
	PocketMap.MapIO.Build( mini, job.entities )
	PocketMap.Effects.Build( mini, job.entities )

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
		-- Prepare the optional shader snapshots during the cooperative rebuild,
		-- rather than compiling every newly visible material in a draw callback.
		if PocketMap.Materials.ForWorld then
			PocketMap.Materials.ForWorld( material, mini.scale, mini )
			PocketMap.Materials.ForWorld( material, 1, mini )
		end
		if PocketMap.Settings and PocketMap.Settings.Enabled( mini, "minimal_preview" ) then
			PocketMap.Materials.ForPreview( material )
		end

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
	for _, dynamic in pairs( job.dynamicFaces or {} ) do table.Add( faces, dynamic ) end
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
		local useHDR = hdr and ( not ldr or render.GetHDREnabled() )

		mini:SetStatus( "Reading the lighting", 0.05 )
		mini.lighting = useHDR and "HDR" or "LDR"
		coroutine.yield()

		local toggle = cvLightToggle:GetBool()
		if PocketMap.Settings then toggle = PocketMap.Settings.Compat( mini, "lighttoggle", cvLightToggle ) end
		local atlas, lightUV = PocketMap.Atlas.Build( mini, allFaces( job ), useHDR, toggle )
		if atlas then
			mini.lightmapTexture = atlas
			job.addOptions.lightUV = lightUV
		else
			print( "[PocketMap] " .. mini.mapName .. ": no lightmap atlas (" .. tostring( mini.atlasFail or "unknown reason" ) .. ")" )
		end
	end
	coroutine.yield()
end

-- Group large opaque materials by the cells their faces occupy. A giant material
-- batch otherwise spans the map and cannot be rejected by a camera or the PVS.
-- The face corners are only used to choose a cell; the bounds used to cull are
-- calculated from the actual rendered triangles in buildSlice below.
local function worldSpatialLists( list, material )
	if #list < 2 or not material
		or NikNaks.MeshBuilder.BlendsWithBackground( material ) then return { list } end

	local cells, order, sparseKeys = {}, {}, {}
	for i = 1, #list do
		local face = list[i]
		local corners = face:GetVertexs()
		if not corners or #corners == 0 then return { list } end
		local x, y, z = 0, 0, 0
		for j = 1, #corners do
			local p = corners[j]
			x, y, z = x + p.x, y + p.y, z + p.z
		end
		local size = #corners * WORLD_CELL_SIZE
		local key = math.floor( x / size ) .. ":" .. math.floor( y / size ) .. ":" .. math.floor( z / size )
		local cell = cells[key]
		if not cell then
			local sparseSize = #corners * WORLD_SPARSE_CELL_SIZE
			cell = {}
			sparseKeys[cell] = math.floor( x / sparseSize ) .. ":" .. math.floor( y / sparseSize ) .. ":" .. math.floor( z / sparseSize )
			cells[key] = cell
			order[#order + 1] = cell
		end
		cell[#cell + 1] = face
		face:ClearMeshData()
		if i % FACES_PER_YIELD == 0 then coroutine.yield() end
	end

	if #order < 2 then return { list } end
	local batches, sparse, sparseOrder = {}, {}, {}
	for i = 1, #order do
		local cell = order[i]
		if #cell >= WORLD_MIN_CELL_FACES then
			batches[#batches + 1] = cell
		else
			-- Sparse cells must not be merged across the whole map: a single
			-- mesh mixing streets and isolated rooftop rooms defeats BSP PVS.
			local key = sparseKeys[cell]
			local group = sparse[key]
			if not group then
				group = {}
				sparse[key] = group
				sparseOrder[#sparseOrder + 1] = group
			end
			table.Add( group, cell )
		end
	end
	for i = 1, #sparseOrder do batches[#batches + 1] = sparseOrder[i] end
	return #batches > 1 and batches or { list }
end

-- Every MeshBuilder part from this slice is enclosed by these real triangle
-- bounds (including displacements and transformed brush models).
local function buildSlice( list, first, last, addOptions, shadowMini )
	local builder = NikNaks.MeshBuilder( true )
	for i = first, last do
		local face = list[i]
		builder:AddFace( face, addOptions )
		if shadowMini then PocketMap.Flashlight.AddWorldShadowFace( shadowMini, face, addOptions.material ) end
		if ( i - first ) % FACES_PER_YIELD == FACES_PER_YIELD - 1 then coroutine.yield() end
	end
	local object = builder:Build()
	for i = first, last do list[i]:ClearMeshData() end
	local mins, maxs = object:GetBounds()
	return object, mins, maxs
end

-- Any uncertain leaf, too many leaves or an oversized mesh disables PVS
-- culling for that mesh; frustum rejection can still be used independently.
local function worldClusters( bsp, mins, maxs )
	if not mins or not maxs or maxs.x - mins.x > WORLD_PVS_MAX_SPAN
		or maxs.y - mins.y > WORLD_PVS_MAX_SPAN or maxs.z - mins.z > WORLD_PVS_MAX_SPAN then return nil end
	local leaves = bsp:AABBInLeafs( 0, mins, maxs, WORLD_PVS_PAD )
	if #leaves == 0 or #leaves > WORLD_PVS_MAX_LEAFS then return nil end
	local clusters, seen = {}, {}
	for i = 1, #leaves do
		local leaf = leaves[i]
		if not leaf or not leaf.cluster then return nil end
		if leaf.cluster < 0 then
			if not leaf.contents or bit.band( leaf.contents, CONTENTS_SOLID ) == 0 then return nil end
		elseif not seen[leaf.cluster] then
			seen[leaf.cluster] = true
			clusters[#clusters + 1] = leaf.cluster
		end
	end
	return #clusters > 0 and clusters or nil
end

-- The BSP leaf-face table identifies which visibility clusters actually touch
-- each world face. Mesh bounds can cross unrelated rooms (or the void between
-- them), so their AABB alone is a poor way to identify the face's clusters.
-- An unlinked face remains unknown and uses the conservative AABB fallback.
local function worldFaceClusters( bsp )
	local result, faces = {}, bsp:GetFaces()
	for index, clusters in pairs( bsp:GetFaceClusters( coroutine.yield ) ) do
		-- Brush models need transformed triangle bounds, not their model-space leaf links.
		if faces[index] and faces[index]:IsWorld() then result[index] = clusters end
	end
	return result
end

local function sliceClusters( job, list, first, last, mins, maxs )
	local clusters, seen = {}, {}
	for i = first, last do
		local face = list[i]
		local linked = job.faceClusters[face.__id]
		if not linked or #linked == 0 then return worldClusters( job.bsp, mins, maxs ) end
		for j = 1, #linked do
			local cluster = linked[j]
			if not seen[cluster] then
				seen[cluster] = true
				clusters[#clusters + 1] = cluster
			end
		end
	end
	return #clusters > 0 and clusters or nil
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
		local sliceSize = PocketMap.Faces.SLICE_SIZE
		local facesPerMesh = isWorld and sliceSize * WORLD_SLICES_PER_MESH or sliceSize
		local batches = { list }
		if isWorld then
			for i, face in ipairs( list ) do
				PocketMap.Visibility.FaceClusters( mini, face )
				if i % FACES_PER_YIELD == 0 then coroutine.yield() end
			end
			if material and NikNaks.MeshBuilder.BlendsWithBackground( material ) then
				batches = PocketMap.Visibility.FaceBatches( mini, list )
			else
				batches = worldSpatialLists( list, material )
			end
		end
		for _, batch in ipairs( batches ) do
			if isWorld and material and not NikNaks.MeshBuilder.BlendsWithBackground( material ) then
				mini.worldFaceGroups[#mini.worldFaceGroups + 1] = { material = material, faces = batch }
			end
			for first = 1, #batch, facesPerMesh do
				mini:SetStatus( "Building " .. key, 0.15 + 0.45 * math.min( 1, progress.done / job.slicesTotal ) )
				local last = math.min( first + facesPerMesh - 1, #batch )
				local object, mins, maxs = buildSlice( batch, first, last, job.addOptions, isWorld and mini or nil )
				out[#out + 1] = object
				if isWorld then
					local center, radius, clusters, blockCenter, blockRadius
					if mins and maxs then
						center = ( mins + maxs ) * 0.5
						radius = ( maxs - mins ):Length() * 0.5 + 8
						clusters = sliceClusters( job, batch, first, last, mins, maxs )
						-- The mini's fit never changes after loading, so transform
						-- the bounds once instead of for every draw call.
						blockCenter = ( center - mini.mapCenter ) * mini.scale + mini.boxCenter
						blockRadius = radius * mini.scale
					end
					-- Mesh objects still own the IMesh handles; the draw list only
					-- references those handles and their conservative bounds.
					for _, part in ipairs( object:GetMeshes() ) do
						part.worldCenter, part.worldRadius, part.worldClusters = center, radius, clusters
						part.blockCenter, part.blockRadius = blockCenter, blockRadius
						-- Keep the real box as well as its enclosing sphere. Large,
						-- thin surfaces otherwise straddle water clip planes by radius.
						if mins and maxs then
							part.blockExtents = ( maxs - mins ) * ( mini.scale * 0.5 ) + Vector( 8, 8, 8 ) * mini.scale
						end
						local drawList = part.translucent and out.translucentMeshes or out.opaqueMeshes
						drawList[#drawList + 1] = part
					end
				end

				-- Faces.Sort estimates progress from the original material slices.
				progress.done = progress.done + math.ceil( ( last - first + 1 ) / sliceSize )
				coroutine.yield()
			end
		end
		groups[key] = nil
	end
end

local function buildWorldMeshes( mini, job )
	local progress = { done = 0 }
	mini.objects.opaqueMeshes = {}
	mini.objects.translucentMeshes = {}
	job.faceClusters = worldFaceClusters( job.bsp )
	mini.worldFaceGroups = {}
	mini.worldFaceClusters = job.faceClusters
	mini.worldLightUV = job.addOptions.lightUV

	buildMaterialGroups( mini, job, job.groups, job.order, mini.objects, true, progress )
	PocketMap.Flashlight.FlushWorldShadows( mini )
	if mini.lightmapTexture then buildMaterialGroups( mini, job, job.skyGroups, job.skyOrder, mini.skyObjects, false, progress ) end

	job.faceClusters = nil
	job.addOptions = nil
	coroutine.yield()
end

local function mountPackedAssetsIfPossible( mini, job )
	mini:SetStatus( "Mounting packed assets", 0.01 )

	local ok, result = pcall( PocketMap.Pak.Mount, job.bsp, coroutine.yield )
	if ok then
		mini.packedAssets = result
	else
		print( "[PocketMap] " .. mini.mapName .. ": the packed assets were not mounted (" .. tostring( result ) .. ")" )
	end
	coroutine.yield()
end

function Loader.Run( mini )
	local job = {}

	if not openMap( mini, job ) then return end
	mountPackedAssetsIfPossible( mini, job )
	readLumps( mini, job )
	if not fitToBlock( mini, job ) then return end
	readEntities( mini, job )
	PocketMap.Faces.Sort( mini, job )
	PocketMap.Displacements.Build( mini, job, coroutine.yield )
	loadMaterials( mini, job )
	prepareLight( mini, job )
	PocketMap.MapIO.BuildMeshes( mini, job )
	buildWorldMeshes( mini, job )
	mini:SetStatus( "Projecting map decals", 0.6 )
	if PocketMap.Decals then PocketMap.Decals.Build( mini, job ) end
	PocketMap.Props.Collect( mini, job )
	PocketMap.Detail.Build( mini, job )
	local lightToggle, bake = cvLightToggle:GetBool(), cvPropMeshes:GetBool()
	if PocketMap.Settings then
		lightToggle = PocketMap.Settings.Compat( mini, "lighttoggle", cvLightToggle )
		bake = PocketMap.Settings.Compat( mini, "baked_models", cvPropMeshes )
	end
	PocketMap.Props.Place( mini, job, lightToggle, bake )
	PocketMap.MapIO.PrepareDoorProps( mini )

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
