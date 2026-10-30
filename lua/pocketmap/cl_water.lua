-- The Water shader reads $reflecttexture and $refracttexture, which the engine only fills for the world it draws.
-- The water of a block is a mesh, so PreRender fills them here, mirroring what the engine does (viewrender.cpp):
-- refraction is the map below the water with the scene depth in alpha, reflection is the map above it seen from a mirrored eye.

PocketMap = PocketMap or {}
PocketMap.Water = PocketMap.Water or {}
local Water = PocketMap.Water

local RT_SCALE = 0.5
local SPREAD = 2
local MAX_PLANES = 32
local MAX_RENDERED_HEIGHTS = 4
local RELEASE_AFTER_FRAMES = 60
local FLAT_SIZE = 16
local MAX_MESH_VERTS = 30000
local REFLECTION_TONE_SCALE = 0.25
local ENGINE_REFLECTION, ENGINE_REFRACTION = "_rt_WaterReflection", "_rt_WaterRefraction"

local cvWater = CreateClientConVar( "pocketmap_water", "0", true, false,
	"1 = water with a reflection and a refraction of the tiny map (draws the map two more times a frame while the eye is inside a block with water).", 0, 1 )

Water.pass = nil
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
	name = string.lower( name )
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

local DEFAULT_PARAMS = {
	["$abovewater"] = "1", ["$normalmap"] = "dev/water_normal", ["$bumpmap"] = "dev/water_dudv", ["$scale"] = "[1 1]",
	["$refractamount"] = "1", ["$reflectamount"] = "0.4", ["$fogenable"] = "1", ["$fogcolor"] = "{7 58 66}",
	["$fogstart"] = "0", ["$fogend"] = "1024", ["$surfaceprop"] = "water",
}

---"{7 58 66}" or "[0.03 0.2 0.25]" -> 0-255 numbers
local function parseColor( text )
	local a, b, c = string.match( tostring( text or "" ), "([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)" )
	a, b, c = tonumber( a ), tonumber( b ), tonumber( c )
	if not ( a and b and c ) then return 7, 58, 66 end
	if string.find( text, "[", 1, true ) and math.max( a, b, c ) <= 1 then return a * 255, b * 255, c * 255 end
	return a, b, c
end

-- Targets: a plane starts on tiny flat-color targets (shared per fog color) and gets full size ones, shared per height,
-- only while its height is being drawn.

local function useFlatTargets( plane )
	plane.reflectRT, plane.refractRT = plane.flat.reflect, plane.flat.refract
	plane.w, plane.h = FLAT_SIZE, FLAT_SIZE
	plane.cleared = false
end

local sharedFlats = {} -- fog color -> { reflect, refract, users }, for every block

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
		flat.users = flat.users - 1

		if flat.users == 0 then
			PocketMap.RT.Release( flat.reflect )
			PocketMap.RT.Release( flat.refract )
			sharedFlats[id] = nil
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
local heldHeights, heldCount = {}, 0

local function releaseHeightTargets( rec )
	if not rec.reflect then return end

	PocketMap.RT.Release( rec.reflect )
	PocketMap.RT.Release( rec.refract )
	rec.reflect, rec.refract = nil, nil

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
local function acquireHeightTargets( rec )
	local w, h = math.max( math.floor( ScrW() * RT_SCALE ), 256 ), math.max( math.floor( ScrH() * RT_SCALE ), 256 )
	if rec.reflect and rec.w == w and rec.h == h then return true end

	releaseHeightTargets( rec )
	if heldCount >= MAX_RENDERED_HEIGHTS and not evictStalest() then return false end

	local reflect = PocketMap.RT.Acquire( w, h, { depth = true } )
	local refract = PocketMap.RT.Acquire( w, h, { depth = true } )
	if not reflect or not refract then
		PocketMap.RT.Release( reflect )
		PocketMap.RT.Release( refract )
		return false
	end

	rec.reflect, rec.refract, rec.w, rec.h = reflect, refract, w, h
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

---@param key string # the material name of the faces
---@param z number # the height in the map
---@param source table? # the parameters of the .vmt
---@return table? plane # nil if the flat targets can't be made
local function makePlane( mini, key, z, source, material )
	local params = source or DEFAULT_PARAMS
	local fogStart, fogEnd = tonumber( params["$fogstart"] ) or 0, tonumber( params["$fogend"] ) or 1024
	local r, g, b = parseColor( params["$fogcolor"] )

	local plane = {
		key = key, z = z, material = material,
		fog = { r = math.floor( r ), g = math.floor( g ), b = math.floor( b ) }, fogRange = math.max( fogEnd - fogStart, 1024 ),
		fogStart = 0, fogEnd = 1024,
		meshes = {}, faces = 0, vmt = source ~= nil,
		mins = Vector( math.huge, math.huge, z ), maxs = Vector( -math.huge, -math.huge, z ),
	}

	plane.flat = acquireFlat( mini, plane.fog )
	if not plane.flat then return nil end

	useFlatTargets( plane )
	plane.cleared = true
	return plane
end

---The material is shared by every plane and block that uses it, so it gets its targets right before each draw and gives them back after.
local function bind( plane )
	local material = plane.material
	local saved = {
		reflect = material:GetTexture( "$reflecttexture" ), refract = material:GetTexture( "$refracttexture" ),
		expensive = material:GetInt( "$forceexpensive" ), fogStart = material:GetFloat( "$fogstart" ), fogEnd = material:GetFloat( "$fogend" ),
	}
	material:SetTexture( "$reflecttexture", plane.reflectRT )
	material:SetTexture( "$refracttexture", plane.refractRT )
	material:SetInt( "$forceexpensive", 1 ) -- the cheap water needs a cubemap the meshes don't have
	material:SetFloat( "$fogstart", plane.fogStart )
	material:SetFloat( "$fogend", plane.fogEnd )
	return saved
end

local function unbind( plane, saved )
	local material = plane.material
	material:SetTexture( "$reflecttexture", saved.reflect or ENGINE_REFLECTION )
	material:SetTexture( "$refracttexture", saved.refract or ENGINE_REFRACTION )
	material:SetInt( "$forceexpensive", saved.expensive or 0 )
	material:SetFloat( "$fogstart", saved.fogStart or 0 )
	material:SetFloat( "$fogend", saved.fogEnd or 0 )
end

---A target that was never drawn into holds garbage, so planes with no effects are filled with their fog color.
local function clearPlane( plane )
	local hasDepth = plane.reflectRT ~= plane.flat.reflect
	PocketMap.RT.Clear( plane.reflectRT, plane.fog.r, plane.fog.g, plane.fog.b, 255, hasDepth )
	PocketMap.RT.Clear( plane.refractRT, plane.fog.r, plane.fog.g, plane.fog.b, 255, hasDepth )
	plane.cleared = true
end

local TANGENT_S, TANGENT_T = Vector( 1, 0, 0 ), Vector( 0, 1, 0 )

---The Water shader needs a tangent space, which the NikNaks MeshBuilder doesn't write. The surface is flat: S along x, T along y.
local function buildMeshes( plane, faces )
	local yield = coroutine.yield
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
				if p.x > plane.maxs.x then plane.maxs.x = p.x end
				if p.y > plane.maxs.y then plane.maxs.y = p.y end
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
			mesh.TexCoord( 0, v.u, v.v )
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
			plane.faces = #byHeight[z]
			planes[#planes + 1] = plane
			local rec = heightRecord( mini, z )
			rec.planes[#rec.planes + 1] = plane
			buildMeshes( plane, byHeight[z] )
		else
			table.Add( rest, byHeight[z] )
		end
	end

	-- Sloped water and displacements get the tangent space but no effects
	if #rest == 0 then return {} end

	local loose = makePlane( mini, key, 0, source, material )
	if not loose then return rest end

	loose.loose, loose.faces = true, #rest
	mini.waterLoose = mini.waterLoose or {}
	mini.waterLoose[#mini.waterLoose + 1] = loose
	buildMeshes( loose, rest )
	return {}
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

---Not drawn inside its own reflection and refraction.
function Water.Draw( mini )
	local planes, loose = mini.waterPlanes, mini.waterLoose
	if Water.pass or not planes or ( #planes == 0 and not loose ) then return end

	cam.PushModelMatrix( mini.matrix )
	for _, list in ipairs( { planes, loose or {} } ) do
		for _, plane in ipairs( list ) do
			local saved = bind( plane )
			render.SetMaterial( plane.material )
			for _, m in ipairs( plane.meshes ) do m:Draw() end
			unbind( plane, saved )
		end
	end
	cam.PopModelMatrix()
end

---The shader looks the reflection up with the projection of the main view, so nested views need the same one. A point is projected
---by both, and since screen position scales with 1 / tan( fov / 2 ) the ratio gives the fov that makes them match.
function Water.Calibrate()
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

---Conservative: false only when all 8 corners are behind the eye or past the same side of the view.
local function boxVisible( mins, maxs, pad, view )
	local forward, right, up = view.angles:Forward(), view.angles:Right(), view.angles:Up()
	local aspect = view.aspect
	local halfH = math.tan( math.rad( view.fov ) / 2 ) * math.max( 1, aspect / ( 4 / 3 ) ) * 1.3
	local halfV = halfH / aspect

	local outside = { 0, 0, 0, 0, 0 } -- behind, left, right, below, above
	local zs = { mins.z - pad, maxs.z + pad }
	for _, x in ipairs( { mins.x, maxs.x } ) do
		for _, y in ipairs( { mins.y, maxs.y } ) do
			for _, z in ipairs( zs ) do
				local rel = Vector( x, y, z ) - view.origin
				local depth = rel:Dot( forward )
				if depth <= 0 then
					outside[1] = outside[1] + 1
				else
					local sx, sy = rel:Dot( right ), rel:Dot( up )
					if sx < -halfH * depth then outside[2] = outside[2] + 1 end
					if sx > halfH * depth then outside[3] = outside[3] + 1 end
					if sy < -halfV * depth then outside[4] = outside[4] + 1 end
					if sy > halfV * depth then outside[5] = outside[5] + 1 end
				end
			end
		end
	end
	for i = 1, 5 do
		if outside[i] >= 8 then return false end
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

local function drawSceneClipped( mini, normal, distance )
	local oldClipping = render.EnableClipping( true )
	render.PushCustomClipPlane( normal, distance )
	local ok, err = pcall( mini.DrawScene, mini, mini:WaterDrawOptions() )
	render.PopCustomClipPlane()
	render.EnableClipping( oldClipping )
	if not ok then error( err, 0 ) end
end

local function renderRefraction( mini, plane, zWorld, spread, view )
	Water.pass = "refraction"

	withTarget( plane.refractRT, function()
		render.Clear( plane.fog.r, plane.fog.g, plane.fog.b, 255, true, true )

		local znear, zfar = depthRange( mini, view.origin, view )
		in3D( plane, view.origin, view.angles, view, znear, zfar, function()
			render.SetWriteDepthToDestAlpha( true )
			local ok, err = pcall( drawSceneClipped, mini, Vector( 0, 0, -1 ), -( zWorld + spread ) )
			render.SetWriteDepthToDestAlpha( false )
			if not ok then error( err, 0 ) end
		end )
	end )
end

local function drawMirroredSky( mini, plane, origin, angles, view, znear, zfar )
	render.Clear( 0, 0, 0, 255, true, true )
	in3D( plane, origin, angles, view, znear, zfar, function()
		PocketMap.Sky.DrawCube( mini, origin, { angles = angles, fov = view.fov, w = plane.w, h = plane.h } )
	end )
	render.ClearDepth()
end

---Pitch and roll are negated and the eye is mirrored in the water, as in CAboveWaterView::CReflectionView.
local function renderReflection( mini, plane, zWorld, spread, view )
	Water.pass = "reflection"

	withTarget( plane.reflectRT, function()
		render.Clear( plane.fog.r, plane.fog.g, plane.fog.b, 255, true, true )

		local angles = Angle( -view.angles.p, view.angles.y, -view.angles.r )
		local origin = Vector( view.origin.x, view.origin.y, 2 * zWorld - view.origin.z )
		local znear, zfar = depthRange( mini, origin, view )

		if mini.skyBackdrop then drawMirroredSky( mini, plane, origin, angles, view, znear, zfar ) end

		in3D( plane, origin, angles, view, znear, zfar, function()
			drawSceneClipped( mini, Vector( 0, 0, 1 ), zWorld - spread )
		end )
	end )
end

local function renderPlane( mini, plane, zWorld, spread, view )
	local toneScale = render.GetToneMappingScaleLinear and render.GetToneMappingScaleLinear()
	local hdr = toneScale and render.GetHDREnabled and render.GetHDREnabled()

	renderRefraction( mini, plane, zWorld, spread, view )

	if hdr then render.SetToneMappingScaleLinear( toneScale * REFLECTION_TONE_SCALE ) end
	renderReflection( mini, plane, zWorld, spread, view )
	if toneScale then render.SetToneMappingScaleLinear( toneScale ) end

	Water.pass = nil
end

local WATER_MAX_TILT = 0.5
local BOX_PAD_SCALE = 64
local FOG_RANGE_SCALE = 4

local function engineView()
	local setup = render.GetViewSetup and render.GetViewSetup()
	return setup and setup.origin and setup or nil
end

---The view of this frame for the effects, or nil when they are off.
local function currentEffectsView()
	if Water.broken or not cvWater:GetBool() then return nil end

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
	local planes = mini.waterPlanes
	if not view or not planes or #planes == 0 then return false end

	return mini.state == "ready" and IsValid( mini.ent ) and mini.scaleVec ~= nil and mini.lightmapTexture ~= nil and mini:EyeInside()
end

local function isBlockLevel( ent )
	local ang = ent:GetAngles()
	return math.abs( math.NormalizeAngle( ang.p ) ) < WATER_MAX_TILT and math.abs( math.NormalizeAngle( ang.r ) ) < WATER_MAX_TILT
end

---The box of the water of a plane in the world, and its height.
local function planeWorldBounds( mini, plane )
	local m = mini.matrix
	local wmins = Vector( math.huge, math.huge, math.huge )
	local wmaxs = Vector( -math.huge, -math.huge, -math.huge )
	local height

	for _, x in ipairs( { plane.mins.x, plane.maxs.x } ) do
		for _, y in ipairs( { plane.mins.y, plane.maxs.y } ) do
			local corner = m * Vector( x, y, plane.z )
			height = height or corner.z
			wmins.x, wmins.y, wmins.z = math.min( wmins.x, corner.x ), math.min( wmins.y, corner.y ), math.min( wmins.z, corner.z )
			wmaxs.x, wmaxs.y, wmaxs.z = math.max( wmaxs.x, corner.x ), math.max( wmaxs.y, corner.y ), math.max( wmaxs.z, corner.z )
		end
	end

	return wmins, wmaxs, height
end

---The eye distance fog of the water: the range of the material is for a first person view, here it is the size of the block.
local function updatePlaneFog( plane, distance, radius, scale )
	local fogStart = math.max( distance - radius, 0 )
	plane.fogStart, plane.fogEnd = fogStart, fogStart + plane.fogRange * scale * FOG_RANGE_SCALE
end

local function turnOffEffects( err )
	Water.pass = nil
	Water.broken, Water.error = true, tostring( err )
	ErrorNoHalt( "[PocketMap] The water reflection / refraction failed and is turned off: " .. Water.error .. "\n" )
end

local function isNearer( a, b )
	return a.distanceSqr < b.distanceSqr
end

---The heights of water that are in view, nearest first. One plane stands for its height: its box decides if it is in view, its fog is the one drawn.
local function visibleHeights( mini, view, scale )
	local found = {}

	for _, rec in pairs( mini.waterHeights or {} ) do
		for _, plane in ipairs( rec.planes ) do
			local wmins, wmaxs, zWorld = planeWorldBounds( mini, plane )
			if view.origin.z > zWorld and boxVisible( wmins, wmaxs, BOX_PAD_SCALE * scale, view ) then
				found[#found + 1] = { rec = rec, plane = plane, zWorld = zWorld, distanceSqr = view.origin:DistToSqr( ( wmins + wmaxs ) * 0.5 ) }
				break
			end
		end
	end

	table.sort( found, isNearer )
	return found
end

---Draws the reflection and refraction of a height. All the planes at that height show it.
---@return boolean ok # false if the effects failed and were turned off
local function renderHeight( mini, entry, view, scale )
	local rec = entry.rec
	if not acquireHeightTargets( rec ) then return true end

	local ok, err = pcall( renderPlane, mini, entry.plane, entry.zWorld, SPREAD * scale, view )
	if not ok then
		turnOffEffects( err )
		return false
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
	local center = ent:LocalToWorld( ( ent.BoxMins + ent.BoxMaxs ) * 0.5 )
	local radius = ( ent.BoxMaxs - ent.BoxMins ):Length() * 0.5
	local distance = view.origin:Distance( center )

	for _, plane in ipairs( mini.waterPlanes ) do updatePlaneFog( plane, distance, radius, scale ) end
	if not isBlockLevel( ent ) then return true end

	local found = visibleHeights( mini, view, scale )
	for i = 1, math.min( #found, MAX_RENDERED_HEIGHTS ) do
		if not renderHeight( mini, found[i], view, scale ) then return false end
	end
	return true
end

---A plane with no effects this frame holds its fog color (once), not whatever the target had.
local function clearIdlePlanes( mini )
	for _, plane in ipairs( mini.waterPlanes or {} ) do
		if not plane.rendered and not plane.cleared then clearPlane( plane ) end
	end
	for _, plane in ipairs( mini.waterLoose or {} ) do
		if not plane.cleared then clearPlane( plane ) end
	end
end

PocketMap.Hooks.Register( "PreRender", "PocketMap_Water", function()
	if not PocketMap.Active then return end

	local view = currentEffectsView()

	for mini in pairs( PocketMap.Active ) do
		markPlanesNotRendered( mini )

		if wantsEffects( mini, view ) and not renderEffects( mini, view ) then return end

		releaseIdleTargets( mini )
		clearIdlePlanes( mini )
	end
end )