-- Project map decals and overlays onto the BSP's actual triangles. Clipping
-- interpolates the receiver's lightmap UVs, including displacement triangles.
if not PocketMap.Mini then return end
PocketMap.Decals = {}
local Decals, IO = PocketMap.Decals, PocketMap.MapIO
local AXES = { Vector( 1, 0, 0 ), Vector( 0, 1, 0 ), Vector( 0, 0, 1 ) }
local MAX_VERTS = 30000

local function interpolate( a, b, t )
	local v = { pos = a.pos + ( b.pos - a.pos ) * t, normal = a.normal }
	for _, key in ipairs( { "u", "v", "u1", "v1", "x", "y", "z" } ) do
		v[key] = ( a[key] or 0 ) + ( ( b[key] or 0 ) - ( a[key] or 0 ) ) * t
	end
	return v
end

-- Sutherland-Hodgman: retain the positive side of an arbitrary plane.
function Decals.Clip( polygon, distance )
	local out = {}
	if #polygon == 0 then return out end
	local a = polygon[#polygon]
	local da = distance( a )
	for _, b in ipairs( polygon ) do
		local db = distance( b )
		if ( da >= 0 ) ~= ( db >= 0 ) then out[#out + 1] = interpolate( a, b, da / ( da - db ) ) end
		if db >= 0 then out[#out + 1] = b end
		a, da = b, db
	end
	return out
end

local function projectFace( group, face, project, clips, lightUV, mini )
	if not face:ShouldRender() or face:IsSkyBox() or face:IsSkyBox3D() then return end
	local data = face:GenerateVertexTriangleData()
	if not data then return end
	local batch
	for first = 1, #data, 3 do
		local polygon = {}
		for i = first, first + 2 do
			local source = data[i]
			local v = { pos = source.pos, normal = source.normal, u1 = source.u1 or 0, v1 = source.v1 or 0 }
			project( v )
			polygon[#polygon + 1] = v
		end
		for _, clip in ipairs( clips ) do polygon = Decals.Clip( polygon, clip ) end
		if #polygon >= 3 then
			if not batch then
				local clusters = PocketMap.Visibility.FaceClusters( mini, face )
				local key = PocketMap.Visibility.Key( clusters )
				batch = group.byVisibility[key]
				if not batch then
					batch = { verts = {}, clusters = clusters }
					group.byVisibility[key] = batch
					group.batches[#group.batches + 1] = batch
				end
			end
			local us, vs
			if lightUV then us, vs = lightUV( face, polygon ) end
			for i, v in ipairs( polygon ) do
				v.lu, v.lv = us and us[i] or 0, vs and vs[i] or 0
			end
			for i = 2, #polygon - 1 do
				for _, v in ipairs( { polygon[1], polygon[i], polygon[i + 1] } ) do batch.verts[#batch.verts + 1] = v end
			end
		end
	end
	face:ClearMeshData()
end

local function receiver( bsp, origin )
	local closest, distance
	for _, axis in ipairs( AXES ) do
		for sign = -1, 1, 2 do
			local trace = bsp:SurfaceTraceLine( origin + axis * ( 8 * sign ), origin - axis * ( 8 * sign ) )
			if trace.Hit and trace.Face and not trace.HitSky then
				local d = trace.HitPos:DistToSqr( origin )
				if not distance or d < distance then closest, distance = trace, d end
			end
		end
	end
	return closest
end

local function decalFaces( bsp, origin, radius )
	local out, seen = {}, {}
	local extent = Vector( radius, radius, radius )
	for _, leaf in pairs( bsp:AABBInLeafs( 0, origin - extent, origin + extent ) ) do
		for _, face in pairs( leaf:GetFaces() ) do
			if not seen[face] then seen[face], out[#out + 1] = true, face end
		end
	end
	return out
end

local function buildDecal( bsp, entity, group, lightUV, mini )
	local origin = IO.Vector( IO.Value( entity, "origin" ) )
	if not origin then return end
	local hit = receiver( bsp, origin )
	if not hit then return end
	local normal = hit.Face:GetNormal()
	local s = math.abs( normal.z ) > 0.9 and Vector( 1, 0, 0 ) or Vector( 0, 0, 1 ):Cross( normal ):GetNormalized()
	local t = s:Cross( normal ):GetNormalized()
	local scale = group.material:GetFloat( "$decalscale" ) or 1
	if scale <= 0 then scale = 1 end
	local width, height = group.material:Width() * scale, group.material:Height() * scale
	if width <= 0 or height <= 0 then return end
	local clips = { function( v ) return v.u end, function( v ) return 1 - v.u end,
		function( v ) return v.v end, function( v ) return 1 - v.v end,
		function( v ) return 4 - v.z end, function( v ) return 4 + v.z end }
	for _, face in ipairs( decalFaces( bsp, hit.HitPos, math.max( width, height ) * 0.5 + 8 ) ) do
		if face.plane and math.abs( face.plane.normal:Dot( normal ) ) > 0.5 then
			projectFace( group, face, function( v )
				local delta = v.pos - hit.HitPos
				v.u, v.v, v.z = delta:Dot( s ) / width + 0.5, delta:Dot( t ) / height + 0.5, delta:Dot( normal )
			end, clips, lightUV, mini )
		end
	end
end

-- BSP overlay UV points store planar coordinates; their Z channels encode U
-- and the handedness of V. Project each half of the quad independently so
-- skewed overlays clip correctly, as do overlays spanning displacements.
local function buildOverlay( overlay, group, lightUV, mini )
	local points, normal = overlay.uvPoints, overlay.basisNormal
	local s = Vector( points[1].z, points[2].z, points[3].z )
	local t = normal:Cross( s ) * ( points[4].z == 1 and -1 or 1 )
	local uv = { { overlay.uMin, overlay.vMin }, { overlay.uMin, overlay.vMax },
		{ overlay.uMax, overlay.vMax }, { overlay.uMax, overlay.vMin } }
	for _, indices in ipairs( { { 1, 2, 3 }, { 1, 3, 4 } } ) do
		local a, b, c = points[indices[1]], points[indices[2]], points[indices[3]]
		local bx, by, cx, cy = b.x - a.x, b.y - a.y, c.x - a.x, c.y - a.y
		local determinant = bx * cy - by * cx
		if math.abs( determinant ) > 0.000001 then
			for _, face in ipairs( overlay:GetFaces() ) do
				projectFace( group, face, function( v )
					local delta = v.pos - overlay.origin
					local x, y = delta:Dot( s ) - a.x, delta:Dot( t ) - a.y
					v.y, v.z = ( x * cy - y * cx ) / determinant, ( bx * y - by * x ) / determinant
					v.x = 1 - v.y - v.z
					v.u = uv[indices[1]][1] * v.x + uv[indices[2]][1] * v.y + uv[indices[3]][1] * v.z
					v.v = uv[indices[1]][2] * v.x + uv[indices[2]][2] * v.y + uv[indices[3]][2] * v.z
				end, { function( v ) return v.x end, function( v ) return v.y end, function( v ) return v.z end }, lightUV, mini )
			end
		end
	end
end

function Decals.Destroy( mini )
	for _, group in ipairs( mini.decals or {} ) do for _, m in ipairs( group.meshes or {} ) do m:Destroy() end end
	mini.decals = nil
end

function Decals.Build( mini, job )
	Decals.Destroy( mini )
	local lightUV = mini.worldLightUV
	local groups, byKey = {}, {}
	local function groupFor( name, origin, order, entity )
		local material = PocketMap.Materials.Load( name )
		if material:IsError() then return end
		local leaf = origin and job.bsp:PointInLeaf( 0, origin )
		local sky = leaf and leaf.area == job.skyArea or false
		local key = material:GetName() .. ":" .. tostring( sky ) .. ":" .. order
		if entity then key = key .. ":" .. tostring( entity ) end
		if not byKey[key] then
			byKey[key] = { material = material, batches = {}, byVisibility = {}, meshes = {}, parts = {},
				sky = sky, order = order, entity = entity }
			groups[#groups + 1] = byKey[key]
		end
		return byKey[key]
	end
	for _, entity in pairs( job.entities ) do
		if PocketMap.Entities.Class( entity ) == "infodecal" and ( not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "decals" ) ) then
			local named = PocketMap.Entities.Name( entity )
			local group = groupFor( IO.Value( entity, "texture" ), IO.Vector( IO.Value( entity, "origin" ) ), 0, named and entity )
			if group then buildDecal( job.bsp, entity, group, lightUV, mini ) end
			coroutine.yield()
		end
	end
	for _, overlay in ipairs( job.bsp:GetOverlays() ) do
		if not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "overlays" ) then
		local texinfo = overlay:GetTexInfo()
		local texdata = texinfo and job.bsp:GetTexData()[texinfo.texdata]
		local group = texdata and groupFor( texdata.nameStringTableID, overlay.origin, overlay.renderOrder + 1 )
		if group then buildOverlay( overlay, group, lightUV, mini ) end
		end
		coroutine.yield()
	end

	table.sort( groups, function( a, b ) return a.order < b.order end )
	mini.decals = groups
	for _, group in ipairs( groups ) do
		for _, batch in ipairs( group.batches ) do
			for first = 1, #batch.verts, MAX_VERTS do
				local last = math.min( first + MAX_VERTS - 1, #batch.verts )
				local m = Mesh( group.material )
				mesh.Begin( m, MATERIAL_TRIANGLES, ( last - first + 1 ) / 3 )
				for i = first, last do
					local v = batch.verts[i]
					mesh.Position( v.pos + v.normal * 0.05 )
					mesh.Normal( v.normal )
					mesh.TexCoord( 0, v.u, v.v ) mesh.TexCoord( 1, v.lu, v.lv )
					mesh.Color( 255, 255, 255, 255 ) mesh.AdvanceVertex()
				end
				mesh.End()
				group.meshes[#group.meshes + 1] = m
				group.parts[#group.parts + 1] = { mesh = m, clusters = batch.clusters }
				coroutine.yield()
			end
		end
		group.batches, group.byVisibility = nil, nil
	end
end

IO.Register( "infodecal", { activate = function( state, record ) IO.State( state, record ).decalActive = true end } )

local function visibleMeshes( group, pvs )
	if not pvs or not group.parts then return group.meshes end
	if group.checkedPVS ~= pvs then
		local meshes = {}
		for _, part in ipairs( group.parts ) do
			if PocketMap.Visibility.Visible( part.clusters, pvs ) then meshes[#meshes + 1] = part.mesh end
		end
		group.checkedPVS, group.visibleMeshes = pvs, meshes
	end
	return group.visibleMeshes
end

function Decals.Draw( mini, skyMatrix, pvs )
	if not mini.decals or not mini.lightmapTexture then return end
	if skyMatrix and PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "sky_decals" ) then return end
	local walk = PocketMap.Walk and PocketMap.Walk.session
	local state = walk and walk.mini == mini and walk.io
	cam.PushModelMatrix( skyMatrix or mini.matrix )
	render.SetLightmapTexture( mini.lightmapTexture )
	render.OverrideDepthEnable( true, false )
	for _, group in ipairs( mini.decals ) do
		local record = group.entity and mini.mapIO.byEntity[group.entity]
		local current = state and record and state.records[record]
		if group.sky == ( skyMatrix ~= nil ) and ( not group.entity or current and current.decalActive ) then
			render.SetMaterial( group.material )
			for _, m in ipairs( visibleMeshes( group, not skyMatrix and pvs ) ) do m:Draw() end
		end
	end
	render.OverrideDepthEnable( true, true )
	cam.PopModelMatrix()
end
