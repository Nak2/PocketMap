-- The sky of a map. worldspawn names six textures (skybox/<skyname><side>), drawn as a cube around the eye so the sky is infinitely
-- far, and seen only through the block. A map with a 3D skybox (sky_camera) also has scenery in a room of its own, drawn around the map.

if not PocketMap.Mini then return end

PocketMap.Sky = {}
local Sky = PocketMap.Sky
local Entities = PocketMap.Entities

local SIDES = { "ft", "bk", "lf", "rt", "up", "dn" }
local CUBE_SIZE = 1024
local DEFAULT_SKYBOX_SCALE = 16
local STENCIL_MAP = 1
local STENCIL_BLOCK = 2

local function vectorOf( value, default )
	value = Entities.First( value )
	if isvector( value ) then return value end

	if isstring( value ) then
		local x, y, z = value:match( "^%s*([%d%.%-eE%+]+)%s+([%d%.%-eE%+]+)%s+([%d%.%-eE%+]+)" )
		x, y, z = tonumber( x ), tonumber( y ), tonumber( z )
		if x and y and z then return Vector( x, y, z ) end
	end
	return default
end

local function numberOf( value, default )
	return tonumber( Entities.First( value ) ) or default
end

local function lowerCaseKeys( entity )
	local keys = {}
	for key, value in pairs( entity ) do
		if isstring( key ) then keys[key:lower()] = value end
	end
	return keys
end

local function defaultPaint()
	return {
		top = Vector( 0.2, 0.5, 1 ), bottom = Vector( 0.8, 1, 1 ), fadeBias = 1, hdrScale = 0.66,
		duskColor = Vector( 1, 0.2, 0 ), duskScale = 1, duskIntensity = 1,
		sunNormal = Vector( 0.4, 0, 0.01 ), sunColor = Vector( 0.2, 0.1, 0 ), sunSize = 2,
		drawStars = true, starLayers = 1, starTexture = "skybox/starfield", starScale = 0.5, starFade = 1.5, starSpeed = 0.01,
	}
end

local function readPaintKeys( paint, keys )
	paint.top = vectorOf( keys.topcolor, paint.top )
	paint.bottom = vectorOf( keys.bottomcolor, paint.bottom )
	paint.fadeBias = numberOf( keys.fadebias, paint.fadeBias )
	paint.hdrScale = numberOf( keys.hdrscale, paint.hdrScale )
	paint.duskColor = vectorOf( keys.duskcolor, paint.duskColor )
	paint.duskScale = numberOf( keys.duskscale, paint.duskScale )
	paint.duskIntensity = numberOf( keys.duskintensity, paint.duskIntensity )
	paint.sunNormal = vectorOf( keys.sunnormal, paint.sunNormal )
	paint.sunColor = vectorOf( keys.suncolor, paint.sunColor )
	paint.sunSize = numberOf( keys.sunsize, paint.sunSize )
	paint.drawStars = numberOf( keys.drawstars, 1 ) ~= 0
	paint.starLayers = math.floor( numberOf( keys.starlayers, paint.starLayers ) )
	paint.starScale = numberOf( keys.starscale, paint.starScale )
	paint.starFade = numberOf( keys.starfade, paint.starFade )
	paint.starSpeed = numberOf( keys.starspeed, paint.starSpeed )

	local texture = Entities.First( keys.startexture )
	if isstring( texture ) and texture ~= "" then paint.starTexture = texture end
end

local function readPaint( entities )
	local paint = defaultPaint()

	for _, entity in pairs( entities ) do
		if Entities.Class( entity ) == "env_skypaint" then
			readPaintKeys( paint, lowerCaseKeys( entity ) )
			break
		end
	end
	return paint
end

local function applyPaint( material, paint )
	material:SetVector( "$TOPCOLOR", paint.top )
	material:SetVector( "$BOTTOMCOLOR", paint.bottom )
	material:SetVector( "$DUSKCOLOR", paint.duskColor )
	material:SetFloat( "$DUSKSCALE", paint.duskScale )
	material:SetFloat( "$DUSKINTENSITY", paint.duskIntensity )
	material:SetFloat( "$FADEBIAS", paint.fadeBias )
	material:SetFloat( "$HDRSCALE", paint.hdrScale )

	material:SetVector( "$SUNNORMAL", paint.sunNormal )
	material:SetVector( "$SUNCOLOR", paint.sunColor )
	material:SetFloat( "$SUNSIZE", paint.sunSize )

	if not paint.drawStars then return material:SetInt( "$STARLAYERS", 0 ) end

	material:SetInt( "$STARLAYERS", paint.starLayers )
	material:SetFloat( "$STARSCALE", paint.starScale )
	material:SetFloat( "$STARFADE", paint.starFade )
	material:SetFloat( "$STARPOS", paint.starSpeed * RealTime() )
	material:SetTexture( "$STARTEXTURE", paint.starTexture )
end

-- Loading -------------------------------------------------------------------------------------------------------------

---Sets mini.skyBackdrop (side -> material, nil if a side is missing), mini.skyPaint and mini.skyName.
function Sky.Read( mini, entities )
	local skyName = Entities.First( entities[0] and entities[0].skyname )
	if type( skyName ) ~= "string" or skyName == "" then return end

	mini:SetStatus( "Reading the sky", 0.035 )

	local backdrop = {}
	for _, side in ipairs( SIDES ) do
		local material = PocketMap.Materials.Load( "skybox/" .. skyName .. side )
		if material:IsError() then backdrop = nil break end
		backdrop[side] = material
	end

	mini.skyBackdrop = backdrop
	mini.skyName = skyName
	if backdrop and skyName:lower() == "painted" then mini.skyPaint = readPaint( entities ) end
	coroutine.yield()
end

-- The cube --------------------------------------------------------------------------------------------------------------
-- right is the way the right edge of the picture points when you look at that side from the inside, top the way its top edge points.
-- If a side shows turned or mirrored, this table is where to fix it.

local SIDE_AXES = {
	ft = { center = Vector( 1, 0, 0 ),  right = Vector( 0, -1, 0 ), top = Vector( 0, 0, 1 ) },
	bk = { center = Vector( -1, 0, 0 ), right = Vector( 0, 1, 0 ),  top = Vector( 0, 0, 1 ) },
	lf = { center = Vector( 0, 1, 0 ),  right = Vector( 1, 0, 0 ),  top = Vector( 0, 0, 1 ) },
	rt = { center = Vector( 0, -1, 0 ), right = Vector( -1, 0, 0 ), top = Vector( 0, 0, 1 ) },
	up = { center = Vector( 0, 0, 1 ),  right = Vector( 0, -1, 0 ), top = Vector( -1, 0, 0 ) },
	dn = { center = Vector( 0, 0, -1 ), right = Vector( 0, -1, 0 ), top = Vector( 1, 0, 0 ) },
}

local RING = { "tl", "tr", "br", "bl" }
local BASE_UV = { tl = { 1, 0 }, tr = { 0, 0 }, br = { 0, 1 }, bl = { 1, 1 } }
local TOP_SIDE_TURNS = 1

---The top picture is turned a quarter, found by testing.
local function cornerUVs( side )
	local turns = side == "up" and TOP_SIDE_TURNS or 0
	local uv = {}
	for i, corner in ipairs( RING ) do uv[corner] = BASE_UV[RING[( i - 1 + turns ) % 4 + 1]] end
	return uv
end

local function buildQuads()
	local quads = {}

	for side, axes in pairs( SIDE_AXES ) do
		local center, right, top = axes.center * CUBE_SIZE, axes.right * CUBE_SIZE, axes.top * CUBE_SIZE
		quads[side] = {
			position = { tl = center - right + top, tr = center + right + top, br = center + right - top, bl = center - right - top },
			uv = cornerUVs( side ),
		}
	end
	return quads
end

local QUADS = buildQuads()
local WINDINGS = { { "tl", "tr", "br", "bl" }, { "bl", "br", "tr", "tl" } }

---Both windings, so it shows whichever way the material culls.
local function drawSide( side, material )
	render.SetMaterial( material )
	local quad = QUADS[side]

	for _, winding in ipairs( WINDINGS ) do
		mesh.Begin( MATERIAL_QUADS, 1 )
		for _, corner in ipairs( winding ) do
			mesh.Position( quad.position[corner] )
			mesh.TexCoord( 0, quad.uv[corner][1], quad.uv[corner][2] )
			mesh.Color( 255, 255, 255, 255 )
			mesh.AdvanceVertex()
		end
		mesh.End()
	end
end

---A painted sky expects the cube at the origin seen by a camera at the origin, which is how the engine draws the 2D sky.
local function startPaintedCamera( override )
	local view = render.GetViewSetup()

	if override then
		cam.Start3D( vector_origin, override.angles, override.fov, 0, 0, override.w, override.h, view.znear, view.zfar )
	else
		cam.Start3D( vector_origin, view.angles, view.fov, view.x, view.y, view.width, view.height, view.znear, view.zfar )
	end
	cam.IgnoreZ( true )
end

local function pushCubeMatrix( mini, eye )
	mini.skyCubeMatrix = mini.skyCubeMatrix or Matrix()

	local matrix = mini.skyCubeMatrix
	matrix:Identity()
	matrix:Translate( eye )
	matrix:Rotate( mini.ent:GetAngles() )
	cam.PushModelMatrix( matrix )
end

---The six sides as a cube around a point, turned the way the map is.
---@param eye Vector
---@param override table? # { angles, fov, w, h }: a view that is not the main one (the water draws the sky in the mirrored view)
function Sky.DrawCube( mini, eye, override )
	local backdrop = mini.skyBackdrop
	if not backdrop then return end

	local paint = mini.skyPaint
	if paint then startPaintedCamera( override ) else pushCubeMatrix( mini, eye ) end

	-- The sky materials have $ignorez, so they are painted over whatever is there. What is in the block is not in the mask and is not painted over.
	render.OverrideDepthEnable( true, false )

	-- The SkyPaint proxy sets the values of the map the player is on every time one of these materials is drawn: hide it while ours are drawn.
	local hostSkyPaint = g_SkyPaint
	if paint then g_SkyPaint = nil end

	for _, side in ipairs( SIDES ) do
		if paint then applyPaint( backdrop[side], paint ) end
		drawSide( side, backdrop[side] )
	end

	if paint then g_SkyPaint = hostSkyPaint end
	render.OverrideDepthEnable( false )

	if paint then
		cam.IgnoreZ( false )
		cam.End3D()
	else
		cam.PopModelMatrix()
	end
end

-- The stencil -----------------------------------------------------------------------------------------------------------

---Only the depth, not the color, and not outside the mask.
local function clearDepthInMask()
	render.OverrideColorWriteEnable( true, false )
	render.ClearBuffersObeyStencil( 0, 0, 0, 0, true )
	render.OverrideColorWriteEnable( false, false )
end

---The map marks every pixel it draws with 1.
local function stencilForTheMap()
	render.SetStencilReferenceValue( STENCIL_MAP )
	render.SetStencilCompareFunction( STENCIL_ALWAYS )
	render.SetStencilPassOperation( STENCIL_REPLACE )
end

---The pixels where the block is seen, not hidden by a wall or by anything in the block. The far faces of the block are drawn into the
---stencil only (culling reversed): they are behind what is in the block, so the depth test fails where something is and it stays
---unmarked. Inside the mask the depth is forgotten, so the room around the block can't hide the sky or the map.
---The stencil must be on, cleared and have its masks set (see Mini:Draw in cl_draw.lua).
local function maskBlock( mini )
	render.SetStencilReferenceValue( STENCIL_BLOCK )
	render.SetStencilCompareFunction( STENCIL_ALWAYS )
	render.SetStencilPassOperation( STENCIL_REPLACE )
	render.OverrideColorWriteEnable( true, false )
	render.OverrideDepthEnable( true, false )
	render.CullMode( MATERIAL_CULLMODE_CW )
	mini.ent:DrawModel()
	render.CullMode( MATERIAL_CULLMODE_CCW )
	render.OverrideDepthEnable( false )
	render.OverrideColorWriteEnable( false, false )

	render.SetStencilCompareFunction( STENCIL_EQUAL )
	render.SetStencilPassOperation( STENCIL_KEEP )

	clearDepthInMask()
end

function Sky.DrawBackdrop( mini )
	if not mini.skyBackdrop then return end

	maskBlock( mini )
	Sky.DrawCube( mini, EyePos() )
	stencilForTheMap()
end

local function updateSkyMatrix( mini )
	local scale = mini.skyScale or DEFAULT_SKYBOX_SCALE
	mini.skyInsideMatrix = mini.skyInsideMatrix or Matrix()
	mini.skyInsideScale = mini.skyInsideScale or Vector()
	mini.skyInsideOrigin = mini.skyInsideOrigin or -mini.skyOrigin

	local matrix = mini.skyInsideMatrix
	matrix:Set( mini.matrix )
	mini.skyInsideScale:SetUnpacked( scale, scale, scale )
	matrix:Scale( mini.skyInsideScale )
	matrix:Translate( mini.skyInsideOrigin )
	return matrix
end

---The 3D skybox, for an eye inside the block. A point S of the sky room is at skyScale * ( S - sky origin ) from the origin of the map,
---as the engine draws it for someone standing in the map. It is drawn after the 2D sky and before the map, which is always in front of it.
---@param options table # the draw options of the world meshes
function Sky.Draw3D( mini, options )
	local objects = mini.skyObjects
	if #objects == 0 or not mini.skyOrigin then return end

	local matrix = updateSkyMatrix( mini )

	maskBlock( mini )
	render.OverrideDepthEnable( true, true )
	for i = 1, #objects do objects[i]:DrawOpaque( matrix, options ) end
	PocketMap.Props.DrawSky( mini, matrix, "opaque" )
	for i = 1, #objects do objects[i]:DrawTranslucent( matrix, options ) end
	render.OverrideDepthEnable( true, true )
	PocketMap.Props.DrawSky( mini, matrix, "translucent" )

	clearDepthInMask()
	render.OverrideDepthEnable( false )
	stencilForTheMap()
end
