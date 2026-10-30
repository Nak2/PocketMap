-- Which faces of the map are drawn, grouped by material. A face can tell a lot about itself (IsWorld, IsSkyBox, ShouldRender,
-- HasTexInfoFlag, GetTexture, GetEntity ...), which is all this needs.

if not PocketMap.Mini then return end

PocketMap.Faces = {}
local Faces = PocketMap.Faces
local Entities = PocketMap.Entities

Faces.SLICE_SIZE = 200

local SURF_TRIGGER = 0x40
local RENDERMODE_DONT_RENDER = 10
local FACES_PER_YIELD = 2000
local DUPLICATE_CHECKS_PER_YIELD = 1500

local HIDDEN_BRUSH_CLASSES = {
	func_areaportal = true, func_areaportalwindow = true, func_occluder = true, func_clip_vphysics = true,
	func_viscluster = true, func_precipitation = true, func_smokevolume = true, func_dustmotes = true,
	func_dustcloud = true, func_proprespawnzone = true, func_nogrenades = true, func_buyzone = true,
	func_bomb_target = true, func_hostage_rescue = true, func_no_defuse = true, func_nav_avoid = true,
	func_nav_prefer = true, func_nav_prerequisite = true, func_fish_pool = true,
	func_illusionary = true,
}

---An instruction to the compiler (clip, trigger, invisible, fog ...), not something to look at. The sky and the black one are drawn in game.
local function isToolFace( face )
	local name = face:GetTexture()
	if not name then return false end

	name = name:lower()
	if name:find( "areaportal", 1, true ) then return true end

	return name:find( "^tools/" ) ~= nil and not name:find( "toolsskybox", 1, true ) and not name:find( "toolsblack", 1, true )
end

local function isSkyFace( face )
	return face:IsSkyBox() or face:IsSkyBox3D() or PocketMap.Materials.IsSkyName( face:GetTexture() )
end

local function isDrawable( face )
	return face:ShouldRender() and not face:HasTexInfoFlag( SURF_TRIGGER ) and not isSkyFace( face ) and not isToolFace( face )
end

-- Brush entities (fences, glass, windows) -----------------------------------------------------------------------------

---The brushes a func_areaportalwindow points at ("target" and "BackgroundBModel") are ordinary func_brush entities, so only the name tells.
---@return table<string, true> # lower case targetname -> true
local function areaportalWindowBrushes( bsp )
	local names = {}

	for _, entity in pairs( bsp:GetEntities() ) do
		if Entities.Class( entity ) == "func_areaportalwindow" then
			for key, value in pairs( entity ) do
				key = type( key ) == "string" and key:lower() or ""
				value = Entities.First( value )
				if ( key == "target" or key == "backgroundbmodel" ) and type( value ) == "string" and value ~= "" then
					names[value:lower()] = true
				end
			end
		end
	end

	return names
end

local function isHiddenBrushClass( class )
	return class:find( "^trigger_" ) ~= nil or class:find( "areaportal", 1, true ) ~= nil or HIDDEN_BRUSH_CLASSES[class] == true
end

local function isInvisible( entity )
	local renderMode = tonumber( entity.rendermode ) or 0
	return renderMode == RENDERMODE_DONT_RENDER or ( tonumber( entity.renderamt ) == 0 and renderMode ~= 0 )
end

---Triggers, hidden brushes and brushes that start disabled are left out.
---@param face BSPFaceObject # a face that is not part of the world
local function brushEntityShown( face, windowBrushes )
	local entity = face:GetEntity()
	if not entity then return false end

	local name = Entities.Name( entity )
	if name and windowBrushes[name] then return false end

	if isHiddenBrushClass( Entities.Class( entity ) ) or isInvisible( entity ) then return false end
	return tonumber( entity.StartDisabled or entity.startdisabled ) ~= 1
end

-- Faces that are the same polygon ------------------------------------------------------------------------------------

---A key shared by faces with the same corners (in any order), plane and facing. A translucent face is never the same as an
---opaque one: both are drawn (the glass over the wall behind it).
---@return string?
function Faces.PolygonKey( face )
	local corners = face:GetVertexs()
	if not corners or #corners < 3 then return nil end

	local floor = math.floor
	local sx, sy, sz, squares = 0, 0, 0, 0
	for _, corner in ipairs( corners ) do
		local x, y, z = floor( corner.x + 0.5 ), floor( corner.y + 0.5 ), floor( corner.z + 0.5 )
		sx, sy, sz = sx + x, sy + y, sz + z
		squares = squares + x * x + y * y + z * z
	end
	face:ClearMeshData()

	local normal = face.plane and face.plane.normal
	if not normal then return nil end

	return ( "%d|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%.0f|%d|%s" ):format( #corners, sx, sy, sz, squares,
		floor( normal.x * 100 + 0.5 ), floor( normal.y * 100 + 0.5 ), floor( normal.z * 100 + 0.5 ), face.side,
		face:IsTranslucent() and "t" or "o" )
end

---A displacement and the flat face it was made from are the same polygon: the one with a displacement and a lightmap wins.
local function faceScore( face )
	return ( face.dispinfo > -1 and 2 or 0 ) + ( face.lightofs >= 0 and 1 or 0 )
end

---Drawn together they fight over the same pixels. Only the world: brush entities with the same shape are copies with an origin.
local function withoutDuplicatePolygons( mini, faces )
	mini:SetStatus( "Looking for faces on top of each other", 0.045 )

	local keyOf, best = {}, {}
	for i, face in ipairs( faces ) do
		local key = face:IsWorld() and Faces.PolygonKey( face ) or nil
		if key then
			keyOf[face] = key
			if not best[key] or faceScore( face ) > faceScore( best[key] ) then best[key] = face end
		end

		if i % DUPLICATE_CHECKS_PER_YIELD == 0 then coroutine.yield() end
	end

	local kept = {}
	for i, face in ipairs( faces ) do
		local key = keyOf[face]
		if key and best[key] ~= face then
			mini.skippedFaces = mini.skippedFaces + 1
		else
			kept[#kept + 1] = face
		end

		if i % FACES_PER_YIELD == 0 then coroutine.yield() end
	end
	return kept
end

-- The room of the 3D skybox ------------------------------------------------------------------------------------------

---The faces in the leaves of the sky area. Displacements that touch it are not listed by the leaves.
local function readSkyRoom( bsp, skyArea )
	if not skyArea then return nil end

	local ids = {}
	for _, leaf in ipairs( bsp:GetSkyboxLeafs() ) do
		for _, face in pairs( leaf:GetFaces() ) do ids[face.__id] = true end
	end
	coroutine.yield()

	return { ids = ids, area = skyArea }
end

local function displacementTouchesSkyRoom( bsp, face, area )
	local corners = face:GetVertexs()
	if not corners or #corners ~= 4 then return false end

	for _, leaf in pairs( bsp:AABBInLeafs( 0, corners[1], corners[3] ) ) do
		if leaf.area == area then return true end
	end
	return false
end

local function isInSkyRoom( bsp, skyRoom, face )
	if not skyRoom then return false end
	if skyRoom.ids[face.__id] then return true end
	return face:IsDisplacement() and displacementTouchesSkyRoom( bsp, face, skyRoom.area )
end

---@return table[] world # faces of the map and of brush entities
---@return table[] sky # faces of the 3D skybox room, drawn around the map
local function splitDrawable( mini, bsp, skyRoom )
	local windowBrushes = areaportalWindowBrushes( bsp )
	local world, sky, seen = {}, {}, 0

	for _, face in pairs( bsp:GetFaces() ) do
		if isDrawable( face ) then
			if face:IsWorld() and isInSkyRoom( bsp, skyRoom, face ) then
				sky[#sky + 1] = face
			elseif face:IsWorld() then
				world[#world + 1] = face
			elseif brushEntityShown( face, windowBrushes ) then
				world[#world + 1] = face
				mini.brushFaces = mini.brushFaces + 1
			end
		end

		seen = seen + 1
		if seen % FACES_PER_YIELD == 0 then coroutine.yield() end
	end

	return world, sky
end

---@return table<string, table[]> groups # texture name -> faces
---@return string[] order # the texture names, the biggest group first so the shape shows up early
local function groupByMaterial( faces )
	local groups, order = {}, {}

	for _, face in ipairs( faces ) do
		local key = face:GetTexture() or "?"
		if not groups[key] then
			groups[key] = {}
			order[#order + 1] = key
		end
		table.insert( groups[key], face )
	end

	table.sort( order, function( a, b ) return #groups[a] > #groups[b] end )
	return groups, order
end

local function countSlices( groups, order )
	local slices = 0
	for _, key in ipairs( order ) do slices = slices + math.ceil( #groups[key] / Faces.SLICE_SIZE ) end
	return slices
end

---Every material the world and the skybox use, once.
local function uniqueMaterials( order, skyOrder )
	local list, seen = {}, {}
	for _, orderList in ipairs( { order, skyOrder } ) do
		for _, key in ipairs( orderList ) do
			if not seen[key] then
				seen[key] = true
				list[#list + 1] = key
			end
		end
	end
	return list
end

---Fills job.groups / order (the world), job.skyGroups / skyOrder (the 3D skybox room), job.slicesTotal and job.materialOrder.
function Faces.Sort( mini, job )
	mini:SetStatus( "Sorting the faces", 0.04 )

	local skyRoom = readSkyRoom( job.bsp, job.skyArea )
	local world, sky = splitDrawable( mini, job.bsp, skyRoom )
	world = withoutDuplicatePolygons( mini, world )

	job.groups, job.order = groupByMaterial( world )
	job.skyGroups, job.skyOrder = groupByMaterial( sky )
	mini.skyFaceCount = #sky

	job.slicesTotal = math.max( countSlices( job.groups, job.order ) + countSlices( job.skyGroups, job.skyOrder ), 1 )
	job.materialOrder = uniqueMaterials( job.order, job.skyOrder )
	coroutine.yield()
end
