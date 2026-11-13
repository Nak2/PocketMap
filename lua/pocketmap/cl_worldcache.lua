-- Combine static opaque faces for a visibility set, rather than submitting
-- every spatial slice that happens to contain one visible face. Compilation
-- cooperates with Think; the ordinary meshes remain visible until it finishes.
PocketMap.WorldCache = PocketMap.WorldCache or {}
local Cache = PocketMap.WorldCache
local LIMIT = 3

local function free( entry )
	for _, object in ipairs( entry.objects ) do object:Destroy() end
	entry.objects, entry.parts, entry.co = {}, {}, nil
end

function Cache.Destroy( mini )
	for _, entry in ipairs( mini.worldVisibilityCache or {} ) do free( entry ) end
	mini.worldVisibilityCache = nil
end

local function visible( face, clusters, pvs )
	local linked = clusters[face.__id]
	if not linked or #linked == 0 then return true end
	for i = 1, #linked do if pvs[linked[i]] then return true end end
	return false
end

local function compile( mini, entry )
	local options = { light = false, lightUV = mini.worldLightUV }
	for _, group in ipairs( mini.worldFaceGroups ) do
		local builder, count = NikNaks.MeshBuilder( true ), 0
		options.material = group.material
		for i, face in ipairs( group.faces ) do
			if visible( face, mini.worldFaceClusters, entry.pvs ) then
				builder:AddFace( face, options )
				face:ClearMeshData()
				count = count + 1
			end
			if i % 16 == 0 then coroutine.yield() end
		end
		if count > 0 then
			local object = builder:Build()
			entry.objects[#entry.objects + 1] = object
			local center, radius
			local mins, maxs = object:GetBounds()
			if mins then
				center = ( mins + maxs ) * 0.5
				radius = ( maxs - mins ):Length() * 0.5 + 8
			end
			for _, part in ipairs( object:GetMeshes() ) do
				if center then
					part.blockCenter = ( center - mini.mapCenter ) * mini.scale + mini.boxCenter
					part.blockRadius = radius * mini.scale
				end
				entry.parts[#entry.parts + 1] = part
			end
		end
		coroutine.yield()
	end
	entry.ready = true
end

function Cache.Get( mini, pvs )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "world_cache" ) then return end
	if not pvs or not mini.worldFaceGroups or not mini.worldFaceClusters or not mini.worldLightUV then return end
	local entries = mini.worldVisibilityCache
	if entries and ( entries.source ~= mini.worldFaceGroups or entries.bsp ~= mini.bsp
		or entries.lightUV ~= mini.worldLightUV or entries.settings ~= mini.settings ) then Cache.Destroy( mini ) entries = nil end
	if not entries then entries = { source = mini.worldFaceGroups, bsp = mini.bsp, lightUV = mini.worldLightUV, settings = mini.settings } mini.worldVisibilityCache = entries end
	local frame = FrameNumber()
	local key = PocketMap.Visibility.PVSKey( mini, pvs )
	for _, entry in ipairs( entries ) do
		if entry.key == key then
			entry.used = frame
			return entry.ready and entry.parts or nil
		end
	end
	if #entries >= LIMIT then
		local oldest = 1
		for i = 2, #entries do if entries[i].used < entries[oldest].used then oldest = i end end
		free( table.remove( entries, oldest ) )
	end
	local entry = { key = key, pvs = pvs, used = frame, objects = {}, parts = {} }
	entry.co = coroutine.create( function() compile( mini, entry ) end )
	entries[#entries + 1] = entry
end

local function canCompile( mini, now )
	if not PocketMap.Settings then return true end
	if not PocketMap.Settings.Enabled( mini, "world_cache" ) then return false end
	if not PocketMap.Settings.Enabled( mini, "defer_world_cache" ) then return true end
	-- A frozen set cannot become transient as its camera moves around.
	if PocketMap.PVSFreeze and PocketMap.PVSFreeze.Get( mini ) then return true end
	local walk = PocketMap.Walk and PocketMap.Walk.session
	if not walk or walk.mini ~= mini or not walk.move then return false end
	local origin = walk.move.origin
	if not mini.worldCacheOrigin or origin:DistToSqr( mini.worldCacheOrigin ) > 0.0625 then
		mini.worldCacheOrigin = Vector( origin.x, origin.y, origin.z )
		mini.worldCacheReadyAt = now + 0.15
	end
	return now >= ( mini.worldCacheReadyAt or 0 )
end

PocketMap.Hooks.Register( "Think", "PocketMap_WorldCache", function()
	local deadline = SysTime() + 0.001
	local frame = FrameNumber()
	for mini in pairs( PocketMap.Active or {} ) do
		if canCompile( mini, SysTime() ) then
		for _, entry in ipairs( mini.worldVisibilityCache or {} ) do
			-- Do not spend the frame budget on visibility sets no view requests.
			if entry.co and not entry.failed and ( entry.used or 0 ) >= frame - 1 then
				repeat
					local ok, err = coroutine.resume( entry.co )
					if not ok then
						free( entry )
						entry.failed = true
						ErrorNoHalt( "[PocketMap] World visibility cache: " .. tostring( err ) .. "\n" )
						break
					end
					if coroutine.status( entry.co ) == "dead" then entry.co = nil break end
				until SysTime() >= deadline
			end
			if SysTime() >= deadline then return end
		end
		end
	end
end )
