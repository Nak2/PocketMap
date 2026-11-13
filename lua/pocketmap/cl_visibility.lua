-- Visibility belongs to the receiver surface, not its material or a map-wide
-- batch. Keep this metadata in memory alongside the immutable render meshes.
PocketMap.Visibility = PocketMap.Visibility or {}
local Visibility = PocketMap.Visibility

---Returns a validated camera in block space. Pass-specific culling stays with each renderer.
function Visibility.View( mini, pad, allowWater )
	if not mini.scale or mini.scale <= 0 then return end
	local water = PocketMap.Water
	local waterView = water and water.pass and allowWater ~= false and water.sceneView
	if water and water.pass and not waterView then return end
	if not waterView and render.GetRenderTarget() then return end
	local sceneView = PocketMap.Scene and PocketMap.Scene.View( mini )
	local view = waterView or sceneView or render.GetViewSetup()
	if not view or not view.origin or not view.angles or view.ortho or view.offcenter or view.subrect then return end
	if not waterView and not sceneView then
		local angles = EyeAngles()
		if EyePos():DistToSqr( view.origin ) > 1 or angles:Forward():Dot( view.angles:Forward() ) < 0.999
			or angles:Up():Dot( view.angles:Up() ) < 0.999 then return end
	end
	local fov, width, height = view.fov, view.width, view.height
	if not fov or fov <= 1 or fov * 0.5 + pad >= 90 or not width or not height or width <= 0 or height <= 0 then return end
	local stamp = mini:UpdateMatrix()
	local clip = waterView and water.ClipPlane and water.ClipPlane( mini )
	local cache = mini.visibilityViews
	if not cache then cache = {} mini.visibilityViews = cache end
	local previous = cache[pad]
	if previous and previous.frame == FrameNumber() and previous.stamp == stamp
		and previous.worldOrigin == view.origin and previous.worldAngles == view.angles
		and previous.fov == fov and previous.width == width and previous.height == height and previous.aspect == view.aspect
		and ( not clip and not previous.clip or clip and previous.clip
			and clip.normal == previous.clip.normal and clip.distance == previous.clip.distance ) then return previous end
	local aspect = width / height
	if view.aspect and view.aspect > 0 then aspect = math.min( aspect, view.aspect ) end
	local tangent = math.tan( math.rad( fov * 0.5 + pad ) )
	local halfWidth = tangent * math.max( 1, ( width / height ) / ( 4 / 3 ) )
	local halfHeight = math.max( tangent, halfWidth / aspect )
	local angles = mini.ent:WorldToLocalAngles( view.angles )
	local forward, right, up = angles:Forward(), angles:Right(), angles:Up()
	local origin = mini.ent:WorldToLocal( view.origin )
	local normals = { forward, forward * halfWidth + right, forward * halfWidth - right,
		forward * halfHeight + up, forward * halfHeight - up }
	for _, normal in ipairs( normals ) do normal:Normalize() end
	local result = {
		frame = FrameNumber(), stamp = stamp, clip = clip, origin = origin, angles = angles,
		mapOrigin = ( origin - mini.boxCenter ) / mini.scale + mini.mapCenter,
		worldOrigin = Vector( view.origin.x, view.origin.y, view.origin.z ),
		worldAngles = Angle( view.angles.p, view.angles.y, view.angles.r ),
		fov = fov, width = width, height = height, aspect = view.aspect,
		forward = forward, right = right, up = up, normals = normals,
		halfWidth = halfWidth, halfHeight = halfHeight,
		widthRadius = math.sqrt( 1 + halfWidth * halfWidth ), heightRadius = math.sqrt( 1 + halfHeight * halfHeight ),
	}
	cache[pad] = result
	return result
end

---Shares ordinary-camera PVS decoding. Reflections retain their own union-of-receivers policy.
function Visibility.PVS( mini, view, reflection )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "pvs" ) then return end
	local water = PocketMap.Water
	if water and water.pass == "reflection" then
		return reflection and water.ReflectionPVS and water.ReflectionPVS( mini ) or nil
	end
	if not view or not mini.bsp then return end
	local frozen = PocketMap.PVSFreeze and PocketMap.PVSFreeze.Get( mini )
	if frozen then return frozen end
	if not mini:EyeInside() then return end
	local bsp, eye = mini.bsp, view.mapOrigin
	local cluster = bsp:ClusterFromPoint( eye )
	if not cluster or cluster < 0 then return end
	local vis = bsp:GetVisibility()
	if not vis or not vis.VisData or not vis.VisData[cluster] or bsp:IsVisibilityCorrupted() then return end
	if mini.worldPVSBSP ~= bsp or mini.worldPVSCluster ~= cluster then
		mini.worldPVSBSP, mini.worldPVSCluster = bsp, cluster
		mini.worldPVS = bsp:PVSForOrigin( eye )
	end
	return mini.worldPVS
end

function Visibility.PVSKey( mini, pvs )
	local frozen = PocketMap.PVSFreeze and PocketMap.PVSFreeze.state
	if frozen and frozen.mini == mini and frozen.bsp == mini.bsp and frozen.pvs == pvs then return frozen.cluster end
	if mini.worldPVSBSP == mini.bsp and mini.worldPVS == pvs then return mini.worldPVSCluster end
	return pvs
end

function Visibility.BoxCorners( mins, maxs, origin, angles, pad )
	local corners = {}
	pad = pad or 0
	for x = 0, 1 do for y = 0, 1 do for z = 0, 1 do
		local point = Vector( x == 0 and mins.x - pad or maxs.x + pad,
			y == 0 and mins.y - pad or maxs.y + pad, z == 0 and mins.z - pad or maxs.z + pad )
		corners[#corners + 1] = origin and LocalToWorld( point, angle_zero, origin, angles ) or point
	end end end
	return corners
end

local opaqueFaces = setmetatable( {}, { __mode = "k" } )
local OPAQUE_SHADERS = { LightmappedGeneric = true, WorldVertexTransition = true }
local UNSAFE_MATERIAL_FLAGS = 0x200180 -- translucent, alpha test, additive

local function opaqueFace( face )
	local known = opaqueFaces[face]
	if known ~= nil then return known end
	local safe = face:IsWorld() and not face:IsDisplacement() and face:ShouldRender()
	if safe then
		local material = face:GetMaterial()
		local shader = ( material:GetShader() or "" ):gsub( "_DX%d+$", "" )
		safe = OPAQUE_SHADERS[shader] == true and not material:IsError()
			and bit.band( material:GetInt( "$flags" ) or 0, UNSAFE_MATERIAL_FLAGS ) == 0
			and ( material:GetFloat( "$alpha" ) or 1 ) >= 1
		for _, key in ipairs( { "$translucent", "$alphatest", "$additive", "$vertexalpha", "$nodraw", "$wireframe" } ) do
			if ( material:GetInt( key ) or 0 ) ~= 0 then safe = false break end
		end
		local keys = material:GetKeyValues()
		if keys.Proxies or keys.proxies then safe = false end
	end
	opaqueFaces[face] = safe
	return safe
end

---A convex opaque BSP face's shadow is convex. If every corner lies behind that
---same face, the enclosed object is hidden too. Hits on unrelated faces prove nothing.
function Visibility.Occluded( bsp, eye, center, corners )
	local trace = bsp:SurfaceTraceLine( eye, center )
	local face = trace and trace.Face
	if not trace or not trace.Hit or trace.HitSky or not face or not opaqueFace( face ) then return false end
	for _, corner in ipairs( corners ) do
		local hit = face:LineSegmentIntersection( eye, corner )
		if not hit or eye:DistToSqr( hit ) >= eye:DistToSqr( corner ) * 0.9025 then return false end
	end
	return #corners == 8
end

function Visibility.Visible( clusters, pvs )
	if not pvs or not clusters or #clusters == 0 then return true end
	for i = 1, #clusters do if pvs[clusters[i]] then return true end end
	return false
end

function Visibility.Key( clusters )
	if not clusters or #clusters == 0 then return "?" end
	-- Leaf enumeration and leaf-face lists need not have the same order.
	local ordered = {}
	for i = 1, #clusters do ordered[i] = clusters[i] end
	table.sort( ordered )
	return table.concat( ordered, "," )
end

-- Unlike per-frame bounds tests, this runs once while loading. Large static
-- faces can legitimately touch hundreds of leaves; size alone is not unknown.
function Visibility.BoundsClusters( bsp, mins, maxs )
	if not mins or not maxs then return end
	local clusters, seen = {}, {}
	for _, leaf in pairs( bsp:AABBInLeafs( 0, mins, maxs, 8 ) ) do
		local cluster = leaf and leaf.cluster
		if not cluster then return end
		if cluster < 0 then
			if bit.band( leaf.contents or 0, CONTENTS_SOLID ) == 0 then return end
		elseif not seen[cluster] then
			seen[cluster], clusters[#clusters + 1] = true, cluster
		end
	end
	if #clusters > 0 then return clusters end
end

-- Ordinary world faces use the BSP leaf-face links. Displacements are stored
-- separately, and static brush models have transformed vertices, so link their
-- actual triangles to leaves instead. Never use an entity's authored origin.
function Visibility.FaceClusters( mini, face )
	local links = mini.worldFaceClusters
	if not links then return end
	local linked = links[face.__id]
	if linked ~= nil then return linked or nil end
	local data = face:GenerateVertexTriangleData()
	local mins, maxs
	for _, vertex in ipairs( data or {} ) do
		local p = vertex.pos
		if p then
			if p.x ~= p.x or p.y ~= p.y or p.z ~= p.z
				or math.abs( p.x ) == math.huge or math.abs( p.y ) == math.huge or math.abs( p.z ) == math.huge then
				face:ClearMeshData()
				links[face.__id] = false
				return
			end
			if not mins then mins, maxs = Vector( p.x, p.y, p.z ), Vector( p.x, p.y, p.z )
			else
				mins.x, mins.y, mins.z = math.min( mins.x, p.x ), math.min( mins.y, p.y ), math.min( mins.z, p.z )
				maxs.x, maxs.y, maxs.z = math.max( maxs.x, p.x ), math.max( maxs.y, p.y ), math.max( maxs.z, p.z )
			end
		end
	end
	face:ClearMeshData()
	linked = Visibility.BoundsClusters( mini.bsp, mins, maxs )
	links[face.__id] = linked or false
	return linked
end

-- Split only where visibility changes, retaining the input face order for
-- translucent blending. A visible window must not retain distant windows.
function Visibility.FaceBatches( mini, faces )
	local batches, previous, batch = {}, nil, nil
	for _, face in ipairs( faces ) do
		local key = Visibility.Key( Visibility.FaceClusters( mini, face ) )
		if key ~= previous then
			batch, previous = {}, key
			batches[#batches + 1] = batch
		end
		batch[#batch + 1] = face
	end
	return batches
end
