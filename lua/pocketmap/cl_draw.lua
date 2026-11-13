-- Drawing a loaded map. The engine draws a block in two passes (opaque, translucent), and the views that use the stencil (the
-- sky behind the map and the 3D skybox) can't be split, so they are drawn in the translucent call.

if not PocketMap.Mini then return end

local Mini = PocketMap.Mini
local Water = PocketMap.Water
local Sky = PocketMap.Sky
local Detail = PocketMap.Detail
local Props = PocketMap.Props

local WORLD_FRUSTUM_FOV_PAD = 6
local cvWorldFrustumCache = CreateClientConVar( "pocketmap_world_frustum_cache", "1", true, false,
	"Reuse visible world meshes while the rendered view and miniature are unchanged" )
local cvWaterSceneCull = CreateClientConVar( "pocketmap_water_scene_cull", "1", true, false,
	"Cull world meshes outside the water reflection and refraction cameras" )
local cvWorldDepthMaterial = CreateClientConVar( "pocketmap_world_depth_material", "0", true, false,
	"Use a simpler opaque shader in the miniature world depth-only pass" )
local cvWaterClipBounds = CreateClientConVar( "pocketmap_water_clip_bounds", "1", true, false,
	"Cache conservative world candidates on each side of a water plane" )
local worldDepthMaterial = CreateMaterial( "PocketMap_WorldDepthOpaque_v1", "UnlitGeneric", {
	["$basetexture"] = "models/debug/debugwhite",
	["$model"] = "0",
} )
local worldDepthSafe = setmetatable( {}, { __mode = "k" } )

-- A colorless depth pass still needs the original shader for alpha clipping,
-- two-sided surfaces and shaders that might change vertex positions.
local function depthMaterialFor( material )
	local safe = worldDepthSafe[material]
	if safe == nil then
		local shader = material:GetShader()
		safe = ( shader == "LightmappedGeneric" or shader == "WorldVertexTransition_DX9"
			or shader == "WorldVertexTransition" )
			and bit.band( material:GetInt( "$flags" ) or 0, 0x3200 ) == 0
			and ( material:GetInt( "$alphatest" ) or 0 ) == 0
		worldDepthSafe[material] = safe
	end
	return safe and worldDepthMaterial or nil
end

---Mark the miniature's pixels for its sky and backdrop passes.
local function beginStencil()
	render.ClearStencil()
	render.SetStencilEnable( true )
	render.SetStencilWriteMask( 255 )
	render.SetStencilTestMask( 255 )
	render.SetStencilReferenceValue( 1 )
	render.SetStencilCompareFunction( STENCIL_ALWAYS )
	render.SetStencilPassOperation( STENCIL_REPLACE )
	render.SetStencilFailOperation( STENCIL_KEEP )
	render.SetStencilZFailOperation( STENCIL_KEEP )
end

---Without an atlas the map is drawn fullbright.
local previewOptions = { light = false, fullbright = true, preview = true }
local function drawOptions( mini )
	if PocketMap.Settings and PocketMap.Settings.MinimalPreview( mini ) then return previewOptions end
	local options = mini.drawOptions
	local fullbright = mini.lightmapTexture == nil
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "lightmaps" ) then fullbright = true end
	if options and options.lightmap == mini.lightmapTexture and options.fullbright == fullbright then return options end

	options = { light = false, lightmap = mini.lightmapTexture, fullbright = fullbright }
	mini.drawOptions = options
	return options
end

-- The water pass supplies its own camera. Other render targets use the
-- primary-view checks before enabling world frustum culling.
local function worldView( mini )
	local waterCull, clipBounds = cvWaterSceneCull:GetBool(), cvWaterClipBounds:GetBool()
	if PocketMap.Settings then
		waterCull = PocketMap.Settings.Compat( mini, "water_scene_cull", cvWaterSceneCull )
		clipBounds = PocketMap.Settings.Compat( mini, "water_clip_bounds", cvWaterClipBounds )
	end
	local view = PocketMap.Visibility.View( mini, WORLD_FRUSTUM_FOV_PAD, waterCull )
	if view then view.boxClip = clipBounds end
	return view
end

local function worldPVS( mini, view )
	return PocketMap.Visibility.PVS( mini, view, true )
end

local function worldPartVisible( part, view )
	if not view then return true end
	local center, radius = part.blockCenter, part.blockRadius
	if center and radius then
		local clip = view.clip
		if clip then
			local extent, n = view.boxClip and part.blockExtents, clip.normal
			local support = extent and ( math.abs( n.x ) * extent.x + math.abs( n.y ) * extent.y + math.abs( n.z ) * extent.z ) or radius
			if center:Dot( n ) + support < clip.distance then return false end
		end
		local dx, dy, dz = center.x - view.origin.x, center.y - view.origin.y, center.z - view.origin.z
		local forward, right, up = view.forward, view.right, view.up
		local depth = dx * forward.x + dy * forward.y + dz * forward.z
		if depth + radius < 0 then return false end
		if math.abs( dx * right.x + dy * right.y + dz * right.z ) > depth * view.halfWidth + radius * view.widthRadius then return false end
		if math.abs( dx * up.x + dy * up.y + dz * up.z ) > depth * view.halfHeight + radius * view.heightRadius then return false end
	end
	return true
end

-- The BSP PVS only changes when the eye enters another visibility cluster.
-- Filter the material-ordered draw list once per PVS; the camera frustum is
-- still tested every draw, so turning or moving within a cluster stays exact.
local function worldPVSCandidates( mini, meshes, pvs, translucent, view )
	local clip = view and view.boxClip and view.clip
	if not pvs and not clip then return meshes end
	local cache = mini.worldPVSCandidates or {}
	local key = translucent and "translucent" or "opaque"
	if Water.pass then key = Water.pass .. "_" .. key end
	local entry = cache[key]
	if not entry or entry.source ~= meshes or entry.pvs ~= pvs then
		local parts = meshes
		if pvs then
			parts = {}
			for i = 1, #meshes do
				local part = meshes[i]
				local clusters = part.worldClusters
				local visible = not clusters
				if clusters then
					for j = 1, #clusters do
						if pvs[clusters[j]] then visible = true break end
					end
				end
				if visible then parts[#parts + 1] = part end
			end
		end
		entry = { source = meshes, pvs = pvs, parts = parts, clips = {} }
		cache[key], mini.worldPVSCandidates = entry, cache
	end
	if not clip then return entry.parts end

	-- The geometry and water plane are static while the camera moves. Filter
	-- once per plane/PVS, then frustum-test only meshes on the retained side.
	entry.clips = entry.clips or {}
	local n, distance = clip.normal, clip.distance
	local nx, ny, nz = n.x, n.y, n.z
	for i = 1, #entry.clips do
		local c = entry.clips[i]
		if c.x == nx and c.y == ny and c.z == nz and c.distance == distance then return c.parts end
	end
	local ax, ay, az = math.abs( nx ), math.abs( ny ), math.abs( nz )
	local parts = {}
	for i = 1, #entry.parts do
		local part = entry.parts[i]
		local center, radius, extent = part.blockCenter, part.blockRadius, part.blockExtents
		local visible = true
		if center and radius then
			local support = extent and ( ax * extent.x + ay * extent.y + az * extent.z ) or radius
			visible = not ( center.x * nx + center.y * ny + center.z * nz + support < distance )
		end
		if visible then parts[#parts + 1] = part end
	end
	-- Bound storage even when an externally animated miniature creates many
	-- distinct local clip planes. Eviction changes cost, never visibility.
	if #entry.clips >= 16 then table.remove( entry.clips, 1 ) end
	entry.clips[#entry.clips + 1] = { x = nx, y = ny, z = nz, distance = distance, parts = parts }
	return parts
end

-- The world meshes and their bounds are immutable after loading. Within the
-- same render view and PVS, avoid retesting hundreds of bounds every frame.
local function worldFrustumParts( mini, meshes, pvs, translucent, view )
	local cacheEnabled = cvWorldFrustumCache:GetBool()
	if PocketMap.Settings then cacheEnabled = PocketMap.Settings.Compat( mini, "world_frustum_cache", cvWorldFrustumCache ) end
	if not view or not cacheEnabled then return nil end
	local key = translucent and "translucent" or "opaque"
	if Water.pass then key = Water.pass .. "_" .. key end
	local cache = mini.worldFrustumParts and mini.worldFrustumParts[key]
	if cache and cache.source == meshes and cache.pvs == pvs then
		local old = cache.view
		local a, b = old.origin, view.origin
		local f, g = old.forward, view.forward
		local r, s = old.right, view.right
		local u, v = old.up, view.up
		if a.x == b.x and a.y == b.y and a.z == b.z
			and f.x == g.x and f.y == g.y and f.z == g.z
			and r.x == s.x and r.y == s.y and r.z == s.z
			and u.x == v.x and u.y == v.y and u.z == v.z
			and old.halfWidth == view.halfWidth and old.halfHeight == view.halfHeight
			and old.boxClip == view.boxClip
			and ( not old.clip and not view.clip or old.clip and view.clip
				and old.clip.normal == view.clip.normal and old.clip.distance == view.clip.distance ) then
			return cache.parts
		end
	end
	local candidates = worldPVSCandidates( mini, meshes, pvs, translucent, view )
	local parts = cache and cache.parts or {}
	local count = 0
	for i = 1, #candidates do
		local part = candidates[i]
		if worldPartVisible( part, view ) then
			count = count + 1
			parts[count] = part
		end
	end
	for i = count + 1, #parts do parts[i] = nil end
	mini.worldFrustumParts = mini.worldFrustumParts or {}
	mini.worldFrustumParts[key] = { source = meshes, pvs = pvs, view = view, parts = parts }
	return parts
end

---The reflection and refraction of the water are a second and third draw of the map, so they only get the opaque world:
---no props, plants or glass, which is most of the cost of a draw.
local sourceWorldMatrix = Matrix()

-- World shaders sample cubemaps with source-map directions and expect unit
-- tangent frames. A scaled/rotated model matrix changes both. Rebase the camera
-- instead, preserving the parent projection's depth so the flashlight and props
-- can still be drawn in miniature space afterwards.
local function beginSourceWorld( mini, options )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "world_source_camera" ) then return false end
	local walk = PocketMap.Walk and PocketMap.Walk.session
	if not walk or walk.mini ~= mini or not options.lightmap or options.flashlight or Water.pass or render.GetRenderTarget() then return false end
	local sceneView = PocketMap.Scene and PocketMap.Scene.View( mini )
	local view = sceneView or render.GetViewSetup()
	if not view or view.ortho or view.offcenter or view.subrect or not view.fov
		or not view.znear or not view.zfar or not mini.scale or mini.scale <= 0 then return false end
	local eye = ( mini.ent:WorldToLocal( sceneView and view.origin or EyePos() ) - mini.boxCenter ) / mini.scale + mini.mapCenter
	local angles = mini.ent:WorldToLocalAngles( sceneView and view.angles or EyeAngles() )
	cam.Start3D( eye, angles, view.fov, view.x, view.y, view.width, view.height,
		view.znear / mini.scale, view.zfar / mini.scale )
	return true
end

local function drawWorld( mini, options, translucent, depthOnly )
	if translucent and PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "translucent_world" ) then return end
	local objects = mini.objects
	local meshes = translucent and objects.translucentMeshes or objects.opaqueMeshes
	local batched = meshes and ( options.preview or options.lightmap or options.flashlight ) and not options.lightOnly and not options.ignoreZ
	if batched and #meshes == 0 then return end
	if not batched and #objects == 0 then return end

	-- Culling uses the parent camera, before entering source coordinates.
	local view = batched and worldView( mini )
	local pvs = not options.preview and batched and worldPVS( mini, view )
	if batched and not translucent and not options.preview and not Water.pass and PocketMap.WorldCache then
		meshes = PocketMap.WorldCache.Get( mini, pvs ) or meshes
	end
	local sourceView = not translucent and not depthOnly and beginSourceWorld( mini, options )
	local repairDepth = sourceView
	if sourceView and PocketMap.Settings then
		local flashlight = PocketMap.Flashlight
		repairDepth = PocketMap.Settings.Enabled( mini, "world_depth_repair" )
			or PocketMap.Settings.Enabled( mini, "flashlight" ) and flashlight and flashlight.IsOn()
	end
	local materialScale = sourceView and 1 or mini.scale
	-- Leave room for the following miniature-space depth pass. Its projection
	-- must exactly match the flashlight receiver pass, including float rounding.
	if repairDepth then render.DepthRange( 0.01, 1 ) end
	cam.PushModelMatrix( sourceView and sourceWorldMatrix or mini.matrix )
	if options.fullbright then render.SetLightingMode( 1 ) end
	local ok, err = pcall( function()
	if batched then
		-- One matrix and lightmap binding for all material slices of the static world.
		-- The ordering of the meshes within each pass stays the same as MeshBuilder's.
		local visible = worldFrustumParts( mini, meshes, pvs, translucent, view )
		local candidates = visible or worldPVSCandidates( mini, meshes, pvs, translucent, view )
		if translucent then render.OverrideDepthEnable( true, false ) end
		if options.lightmap then render.SetLightmapTexture( options.lightmap ) end
		local lastMaterial
		local lastBoundMaterial
		local fastDepth = depthOnly and cvWorldDepthMaterial:GetBool()
		if depthOnly and PocketMap.Settings then fastDepth = PocketMap.Settings.Compat( mini, "world_depth_material", cvWorldDepthMaterial ) end
		local drawn = 0
		for i = 1, #candidates do
			local part = candidates[i]
			if visible or worldPartVisible( part, view ) then
				if part.material ~= lastMaterial then
					local boundMaterial = options.preview and PocketMap.Materials.ForPreview( part.material )
						or fastDepth and depthMaterialFor( part.material )
						or ( PocketMap.Materials.ForWorld and PocketMap.Materials.ForWorld( part.material, materialScale, mini )
							or PocketMap.Materials.ForScale( part.material, materialScale ) )
					if boundMaterial ~= lastBoundMaterial then
						render.SetMaterial( boundMaterial )
						lastBoundMaterial = boundMaterial
					end
					lastMaterial = part.material
				end
				part.mesh:Draw()
				drawn = drawn + 1
			end
		end
		if not translucent then
			mini.worldMeshesDrawn = drawn
			mini.worldMeshesTotal = #meshes
			mini.worldPVSActive = pvs ~= nil
		end
		if translucent then render.OverrideDepthEnable( false ) end
	else
		-- Older loaded miniatures and maps without a lightmap use NikNaks' original drawing path.
		local drawOptions = PocketMap.Materials.DrawOptions( options, materialScale )
		for i = 1, #objects do
			if translucent then objects[i]:DrawTranslucent( nil, drawOptions )
			else objects[i]:DrawOpaque( nil, drawOptions ) end
		end
	end
	end )
	cam.PopModelMatrix()
	if options.fullbright then render.SetLightingMode( 0 ) end
	if sourceView then cam.End3D() end
	if sourceView then render.DepthRange( 0, 1 ) end
	if not ok then error( err, 0 ) end
	if repairDepth then
		render.OverrideColorWriteEnable( true, false )
		render.OverrideAlphaWriteEnable( true, false )
		local depthOK, depthError = pcall( drawWorld, mini, options, false, true )
		render.OverrideColorWriteEnable( false )
		render.OverrideAlphaWriteEnable( false )
		if not depthOK then error( depthError, 0 ) end
	end
end

local flashlightOptions = { light = false, fullbright = false, flashlight = true }
local function drawFlashlights( mini )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "flashlight" ) then return end
	if Water.pass then return end
	render.RenderFlashlights( function()
		drawWorld( mini, flashlightOptions, false )
		PocketMap.MapIO.Draw( mini, PocketMap.Materials.DrawOptions( flashlightOptions, mini.scale ), false )
		Props.Draw( mini, "opaque" )
	end )
end

---@param pass "opaque"|"translucent"|nil # nil draws both halves
local function drawContents( mini, options, pass )
	if options.preview then
		if pass ~= "translucent" then drawWorld( mini, options, false ) end
		mini.propsDrawn = 0
		return
	end
	local lite = Water.pass ~= nil
	local doOpaque, doTranslucent = pass ~= "translucent", pass ~= "opaque" and not lite

	if doOpaque then
		drawWorld( mini, options, false )
		if ( Water.pass ~= "reflection" or not Water.sceneView or Water.sceneView.reflectEntities ~= false )
			and ( Water.pass ~= "reflection" or not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "water_reflect_entities" ) ) then
			PocketMap.MapIO.Draw( mini, PocketMap.Materials.DrawOptions( options, mini.scale ), false )
		end
		local view = worldView( mini )
		local pvs = worldPVS( mini, view )
		if PocketMap.Decals then PocketMap.Decals.Draw( mini, nil, pvs ) end

		if not lite or Water.pass == "refraction" then
			if not Detail.Blends( mini ) then Detail.Draw( mini, pvs ) end
			if not lite or not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "water_refract_props" ) then Props.Draw( mini, "opaque" ) end
		elseif Water.pass == "reflection" and Water.sceneView and Water.sceneView.reflectEntities
			and PocketMap.Settings and PocketMap.Settings.Enabled( mini, "water_reflect_props" ) then
			Props.Draw( mini, "opaque" )
		end
		Water.Draw( mini )
		-- Light opaque surfaces before translucent effects. Drawing this pass
		-- over their quads erases the effects' transparency.
		drawFlashlights( mini )
	end

	if doTranslucent then
		Props.Draw( mini, "translucent" )
		local view = worldView( mini )
		local pvs = worldPVS( mini, view )

		-- A blended sprite sheet must not write depth, or the sprites would cut out what is behind them
		if Detail.Blends( mini ) then
			render.OverrideDepthEnable( true, false )
			Detail.Draw( mini, pvs )
			render.OverrideDepthEnable( true, true )
		end

		drawWorld( mini, options, true )
		PocketMap.MapIO.Draw( mini, PocketMap.Materials.DrawOptions( options, mini.scale ), true )
		PocketMap.Effects.Draw( mini, pvs, view, worldPartVisible )
		render.OverrideDepthEnable( true, true )
	end
end

function Mini:WaterDrawOptions()
	return drawOptions( self )
end

function Mini:RequiresEngineView()
	if PocketMap.Settings and PocketMap.Settings.MinimalPreview( self ) then return end
	local flashlight = PocketMap.Flashlight
	if flashlight and flashlight.IsOn() and ( not PocketMap.Settings or PocketMap.Settings.Enabled( self, "flashlight" ) ) then return "flashlight" end
	local effects = PocketMap.Effects
	local view = worldView( self )
	if effects and effects.RequiresEngineView( self, worldPVS( self, view ), view, worldPartVisible ) then return "glow" end
end

---The whole tiny map, both halves and no sky, in the current 3D view. The refraction and the reflection of the water use it.
function Mini:DrawScene( options )
	if self.entityRefresh then return end
	self:UpdateMatrix()
	render.OverrideDepthEnable( true, true )
	local preview = PocketMap.Settings and PocketMap.Settings.MinimalPreview( self )
	drawContents( self, preview and previewOptions or options, nil )
	render.OverrideDepthEnable( false )
end

---@param pass "opaque"|"translucent"|nil
function Mini:Draw( pass )
	if self.entityRefresh or self.state == "removed" or not self.scaleVec then return end
	if #self.objects == 0 and #self.propGroups == 0 and #self.detailMeshes == 0 then return end

	self:UpdateMatrix()

	local onScreen = not render.GetRenderTarget()
	local options = drawOptions( self )
	if not options.preview and self.waterPlanes and #self.waterPlanes > 0 and onScreen then Water.Calibrate( self ) end
	local sky = not options.preview and #self.skyObjects > 0 and onScreen and self:EyeInside()
	local backdrop = not options.preview and self.skyBackdrop ~= nil and onScreen

	local sceneView = PocketMap.Scene and PocketMap.Scene.View( self )
	local usesStencil = not sceneView and ( sky or backdrop )
	if usesStencil and pass == "opaque" then return end
	if usesStencil then
		pass = nil
		beginStencil()
	end

	if backdrop and not sceneView then Sky.DrawBackdrop( self ) end
	if sky and ( not sceneView or pass ~= "translucent" ) then Sky.Draw3D( self, options, sceneView ~= nil ) end

	render.OverrideDepthEnable( true, true )
	drawContents( self, options, pass )
	render.OverrideDepthEnable( false )

	if usesStencil then render.SetStencilEnable( false ) end
end
