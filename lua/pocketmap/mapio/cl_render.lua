-- Dynamic brush meshes, visibility and resource ownership.
local IO = PocketMap.MapIO

-- Faces and collision of moving brush entities must stay out of the baked static world.
local function meshPasses( mesh )
	local opaque, translucent = false, false
	for _, part in ipairs( mesh:GetMeshes() ) do
		if part.translucent then translucent = true else opaque = true end
	end
	for _, part in ipairs( mesh:GetLightMeshes() ) do
		if part.translucent then translucent = true else opaque = true end
	end
	return opaque, translucent
end

local ZERO_ANGLE = Angle()
local PVS_MAX_RADIUS = 2048
local PVS_MAX_LEAFS = 128
local OCCLUSION_MAX_RADIUS = 350
local cvBrushOcclusion = CreateClientConVar( "pocketmap_mapio_occlusion", "1", true, false,
	"Cull miniature MapIO brushes fully behind static BSP surfaces while the viewer is stationary" )

-- Bounds come from the same triangles the builder consumes, in source-map space.
-- Displacements retain fail-open culling because their shaders can smooth geometry.
local function brushBounds( mesh, record )
	local mins, maxs = mesh:GetBounds()
	if not mins then return end
	local center = ( mins + maxs ) * 0.5
	local radius = ( maxs - mins ):Length() * 0.5 + 2
	return WorldToLocal( center, ZERO_ANGLE, record.origin, record.angles ), radius
end

function IO.BuildMeshes( mini, job )
	mini.dynamicMeshes = {}
	mini.dynamicOpaque, mini.dynamicTranslucent = {}, {}
	mini.mapIOPassesSource, mini.mapIODrawCache = mini.dynamicMeshes, nil
	mini.mapIOMeshWorld = nil
	for record, faces in pairs( job.dynamicFaces or {} ) do
		local conservative = true
		local builder = NikNaks.MeshBuilder( true )
		for _, face in ipairs( faces ) do
			if face:IsDisplacement() then conservative = false end
			job.addOptions.material = job.materials[face:GetTexture() or "?"]
			if job.addOptions.material then builder:AddFace( face, job.addOptions ) end
			face:ClearMeshData()
		end
		local inverse = Matrix()
		inverse:SetTranslation( record.origin )
		inverse:SetAngles( record.angles )
		inverse:Invert()
		local mesh = builder:Build()
		local localCenter, radius
		if conservative then localCenter, radius = brushBounds( mesh, record ) end
		local opaque, translucent = meshPasses( mesh )
		local item = {
			record = record, mesh = mesh, inverse = inverse, matrix = Matrix(),
			opaque = opaque, translucent = translucent,
			localCenter = localCenter, radius = radius,
		}
		mini.dynamicMeshes[#mini.dynamicMeshes + 1] = item
		if opaque then mini.dynamicOpaque[#mini.dynamicOpaque + 1] = item end
		if translucent then mini.dynamicTranslucent[#mini.dynamicTranslucent + 1] = item end
		coroutine.yield()
	end
end

-- A new walking session can rebuild its entity records after the miniature's
-- brush meshes were compiled. Rebind by BSP model index so animations use the
-- same records as the active I/O session. This runs only when the world changes.
local function bindMeshRecords( mini, world )
	if not world or mini.mapIOMeshWorld == world then return end
	for _, item in ipairs( mini.dynamicMeshes or {} ) do
		local old = item.record
		local current = old and world.dynamicModels[old.modelIndex]
		if current and current.class == old.class and current ~= old then
			item.record = current
			item.stamp, item.matrixPose = nil, nil
			item.visibleView, item.checkedPVS, item.clustersChecked = nil, nil, nil
		end
	end
	mini.mapIOMeshWorld = world
	mini.mapIODrawCache, mini.mapIOOcclusion = nil, nil
end

-- Existing miniatures can survive Lua auto-refresh. Index their compiled
-- meshes on demand instead of scanning every brush in both render passes.
local function passMeshes( mini, translucent )
	if mini.mapIOPassesSource ~= mini.dynamicMeshes or not mini.dynamicOpaque or not mini.dynamicTranslucent then
		local opaque, transparent = {}, {}
		for _, item in ipairs( mini.dynamicMeshes or {} ) do
			if item.opaque == nil then item.opaque, item.translucent = meshPasses( item.mesh ) end
			if item.opaque then opaque[#opaque + 1] = item end
			if item.translucent then transparent[#transparent + 1] = item end
		end
		mini.dynamicOpaque, mini.dynamicTranslucent = opaque, transparent
		mini.mapIOPassesSource, mini.mapIODrawCache = mini.dynamicMeshes, nil
	end
	return translucent and mini.dynamicTranslucent or mini.dynamicOpaque
end

local function drawView( mini )
	return PocketMap.Visibility.View( mini, 5 )
end

local function drawPVS( mini, walk, view )
	if walk and walk.mini == mini then return PocketMap.Visibility.PVS( mini, view ) end
end

-- A sphere encompassing the brush can span several visibility leaves. Cull
-- only if every valid cluster it touches is absent from the current PVS.
local function brushClusters( bsp, item )
	if not item.mapCenter or not item.radius or item.radius > PVS_MAX_RADIUS then return end
	local leaves = bsp:SphereInLeafs( 0, item.mapCenter, item.radius + 2 )
	if #leaves == 0 or #leaves > PVS_MAX_LEAFS then return end
	local clusters, seen = {}, {}
	for _, leaf in ipairs( leaves ) do
		local cluster = leaf and leaf.cluster
		if not cluster then return end
		if cluster < 0 then
			if not leaf.contents or bit.band( leaf.contents, CONTENTS_SOLID ) == 0 then return end
		elseif not seen[cluster] then
			seen[cluster] = true
			clusters[#clusters + 1] = cluster
		end
	end
	if #clusters > 0 then return clusters end
end

local function brushVisible( mini, item, view, pvs, poseChanged, stamp )
	if not view or not item.localCenter then return true end
	-- The opaque and translucent hooks often render the same brush and camera.
	if item.visibleView == view and item.visibleStamp == stamp and item.visiblePose == item.pose
		and item.visiblePVS == pvs then
		return item.visibleResult
	end
	local visible = true
	if pvs then
		if not item.clustersChecked then
			item.clusters = brushClusters( mini.bsp, item )
			item.clustersChecked = true
		end
		if item.clusters then
			if item.checkedPVS ~= pvs then
				item.checkedPVS, item.pvsVisible = pvs, false
				for _, cluster in ipairs( item.clusters ) do
					if pvs[cluster] then item.pvsVisible = true break end
				end
			end
			if not item.pvsVisible then visible = false end
		end
	end

	if visible then
		if poseChanged or item.worldStamp ~= stamp then
			item.worldCenter = mini:BlockPosition( item.mapCenter )
			item.worldStamp = stamp
		end
		local center, origin = item.worldCenter, view.origin
		local dx, dy, dz = center.x - origin.x, center.y - origin.y, center.z - origin.z
		local radius = item.radius * mini.scale
		if view.clip and center:Dot( view.clip.normal ) + radius < view.clip.distance then visible = false end
		for _, normal in ipairs( view.normals ) do
			if dx * normal.x + dy * normal.y + dz * normal.z < -radius then visible = false break end
		end
	end
	item.visibleView, item.visibleStamp, item.visiblePose, item.visiblePVS, item.visibleResult = view, stamp, item.pose, pvs, visible
	return visible
end

local function brushBehindWorld( mini, item, eye )
	if not item.mapCenter or not item.radius or item.radius <= 0 or item.radius > OCCLUSION_MAX_RADIUS then return false end
	local center = item.mapCenter
	local extent = Vector( item.radius + 5, item.radius + 5, item.radius + 5 )
	return PocketMap.Visibility.Occluded( mini.bsp, eye, center, PocketMap.Visibility.BoxCorners( center - extent, center + extent ) )
end

local function brushOcclusion( mini, pvs, view )
	if PocketMap.Water and PocketMap.Water.pass then return end
	local enabled = cvBrushOcclusion:GetBool()
	if PocketMap.Settings then enabled = PocketMap.Settings.Compat( mini, "brush_occlusion", cvBrushOcclusion ) end
	if not enabled or not pvs or not view or not mini.bsp.SurfaceTraceLine then return end
	local eye = view.mapOrigin
	local cache = mini.mapIOOcclusion
	if not cache or cache.meshes ~= mini.dynamicMeshes or cache.bsp ~= mini.bsp then
		cache = { meshes = mini.dynamicMeshes, bsp = mini.bsp, generation = 0 }
		mini.mapIOOcclusion = cache
	end
	if not cache.eye or cache.pvs ~= pvs or cache.eye ~= eye then
		cache.eye, cache.pvs = eye, pvs
		cache.generation = cache.generation + 1
		cache.queue, cache.nextIndex, cache.count = {}, 1, 0
		cache.nextAt = CurTime() + 0.2
	end
	return cache
end

local function brushKnownHidden( item, cache )
	if not cache or not item.mapCenter or not item.radius or item.radius > OCCLUSION_MAX_RADIUS then return false end
	if item.occlusionCache == cache and item.occlusionGeneration == cache.generation
		and item.occlusionPose == item.pose then return item.occludedByWorld end
	local request = item.occlusionRequest
	if request and request.pending and request.cache == cache and request.generation == cache.generation then
		-- Keep one queued job for an animating door; its latest pose wins.
		request.pose = item.pose
	else
		cache.count = cache.count + 1
		request = { item = item, pose = item.pose, cache = cache, generation = cache.generation, pending = true }
		cache.queue[cache.count] = request
		item.occlusionRequest = request
	end
	return false
end

-- One expensive BSP probe per frame. Pose changes invalidate moving doors,
-- and the view position invalidates cached results when the player walks.
local function traceNextBrush( mini, cache )
	if not cache or cache.frame == FrameNumber() or CurTime() < cache.nextAt then return end
	local index = cache.nextIndex
	if index > cache.count then return end
	cache.frame, cache.nextIndex = FrameNumber(), index + 1
	local queued = cache.queue[index]
	cache.queue[index] = nil
	queued.pending = false
	local item = queued.item
	if item.pose ~= queued.pose then return end
	item.occludedByWorld = brushBehindWorld( mini, item, cache.eye )
	item.occlusionCache, item.occlusionGeneration, item.occlusionPose = cache, cache.generation, item.pose
end


-- Pose, cull and transform once for a matching pair of main-view render
-- passes. Always prepare afresh for mirrors, water and unknown cameras.
local function visibleMeshes( mini, state, view, pvs, stamp, opaque, transparent )
	opaque, transparent = opaque or {}, transparent or {}
	local records = state and state.records
	local occlusion = brushOcclusion( mini, pvs, view )
	-- Reuse the prior main-view lists, retaining their capacity across frames.
	-- Unknown cameras get independent temporary lists.
	for i = #opaque, 1, -1 do opaque[i] = nil end
	for i = #transparent, 1, -1 do transparent[i] = nil end
	for _, item in ipairs( mini.dynamicMeshes or {} ) do
		if item.opaque or item.translucent then
			-- Render reads don't need to initialize session state. A single
			-- records lookup replaces two IO.State calls per brush per frame.
			local record = item.record
			local current = records and records[record]
			local origin = current and current.origin or record.origin
			local angles = current and current.angles or record.angles
			local poseChanged = item.x ~= origin.x or item.y ~= origin.y or item.z ~= origin.z
				or item.pitch ~= angles.p or item.yaw ~= angles.y or item.roll ~= angles.r
			if poseChanged then
				item.x, item.y, item.z = origin.x, origin.y, origin.z
				item.pitch, item.yaw, item.roll = angles.p, angles.y, angles.r
				item.pose = ( item.pose or 0 ) + 1
				if item.localCenter then item.mapCenter = LocalToWorld( item.localCenter, ZERO_ANGLE, origin, angles ) end
				item.clustersChecked, item.clusters, item.checkedPVS = nil, nil, nil
			end
			if brushVisible( mini, item, view, pvs, poseChanged, stamp ) and not brushKnownHidden( item, occlusion ) then
				if item.stamp ~= stamp or item.matrixPose ~= item.pose then
					local matrix = item.matrix
					matrix:Set( mini.matrix )
					matrix:Translate( origin )
					matrix:Rotate( angles )
					matrix:Mul( item.inverse )
					item.stamp = stamp
					item.matrixPose = item.pose
				end
				if item.opaque then opaque[#opaque + 1] = item end
				if item.translucent then transparent[#transparent + 1] = item end
			end
		end
	end
	traceNextBrush( mini, occlusion )
	return opaque, transparent
end

function IO.Draw( mini, options, translucent )
	local walk = PocketMap.Walk and PocketMap.Walk.session
	local state = walk and walk.mini == mini and walk.io or mini.mapIO and mini.mapIO.initial
	local brushes = not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "moving_brushes" )
	if brushes then bindMeshRecords( mini, state and state.world or mini.mapIO ) end
	local stamp = mini:UpdateMatrix()
	local pass = brushes and passMeshes( mini, translucent ) or {}
	if #pass > 0 then
		local view = not ( options and ( options.ignoreZ or options.lightOnly ) ) and drawView( mini )
		local frame = FrameNumber()
		local cache = mini.mapIODrawCache
		local time = state and state.time
		local revision = state and state.drawRevision
		if not view or not cache or cache.frame ~= frame or cache.view ~= view
			or cache.state ~= state or cache.time ~= time or cache.revision ~= revision
			or cache.stamp ~= stamp or cache.source ~= mini.dynamicMeshes then
			local pvs = drawPVS( mini, walk, view )
			if not view then cache = nil end
			local opaque, transparent = visibleMeshes( mini, state, view, pvs, stamp,
				cache and cache.opaque, cache and cache.translucent )
			cache = cache or {}
			cache.frame, cache.view, cache.state, cache.time = frame, view, state, time
			cache.revision, cache.stamp, cache.source = revision, stamp, mini.dynamicMeshes
			cache.opaque, cache.translucent = opaque, transparent
			if view then mini.mapIODrawCache = cache end
		end
		local visible = translucent and cache.translucent or cache.opaque
		for i = 1, #visible do
			local item = visible[i]
			if translucent then item.mesh:DrawTranslucent( item.matrix, options )
			else item.mesh:DrawOpaque( item.matrix, options ) end
		end
	end
	for _, callback in ipairs( IO.draws ) do callback( mini, state, translucent ) end
end

function IO.DrawDepth( mini, options, flags )
	mini:UpdateMatrix()
	local walk = PocketMap.Walk and PocketMap.Walk.session
	local state = walk and walk.mini == mini and walk.io or mini.mapIO and mini.mapIO.initial
	bindMeshRecords( mini, state and state.world or mini.mapIO )
	for _, item in ipairs( passMeshes( mini, false ) ) do
		local record = item.record
		local origin, angles = IO.Position( state, record ), IO.Rotation( state, record )
		local matrix = item.shadowMatrix or Matrix()
		item.shadowMatrix = matrix
		matrix:Set( mini.matrix )
		matrix:Translate( origin )
		matrix:Rotate( angles )
		matrix:Mul( item.inverse )
		item.mesh:DrawOpaque( matrix, options )
	end
	for _, callback in ipairs( IO.draws ) do callback( mini, state, false, flags ) end
end

function IO.Destroy( mini )
	for _, item in ipairs( mini.dynamicMeshes or {} ) do item.mesh:Destroy() end
	mini.dynamicMeshes = nil
	mini.dynamicOpaque, mini.dynamicTranslucent = nil, nil
	mini.mapIOPassesSource, mini.mapIODrawCache = nil, nil
	mini.mapIOMeshWorld = nil
	if IsValid and IsValid( mini.mapIODoorProp ) then mini.mapIODoorProp:Remove() end
	mini.mapIODoorProp = nil
	mini.mapIODoorEntries, mini.mapIODoorEntriesSource = nil, nil
	mini.mapIODoorRenderBounds, mini.mapIODoorOcclusion = nil, nil
end
