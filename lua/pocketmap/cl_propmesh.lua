-- Models as meshes. util.GetModelMeshes reads a model's triangles; they are built into meshes once per model and drawn
-- once per prop with a matrix. This does not depend on how the engine draws entities, so static-only models and models
-- with translucent materials draw like any other.

if not PocketMap.Mini then return end

PocketMap.PropMesh = {}
local PropMesh = PocketMap.PropMesh

local LODS = { 2, 1, 0 }
local MAX_VERTICES = 30000
local CUTOUT_REFERENCE = 0.5
local MATERIAL_VAR_NOCULL = 0x2000
local MATERIAL_VAR_ADDITIVE = 0x80
local STUDIOHDR_FLAGS_OFFSET = 152
local STUDIOHDR_FLAGS_STATIC_PROP = 0x10

local staticOnly = {}

---Models compiled with $staticprop can't be drawn as entities, so they are always baked.
---@param path string
---@return boolean
function PropMesh.IsStaticOnly( path )
	if staticOnly[path] ~= nil then return staticOnly[path] end

	local result = false
	local mdl = file.Open( path, "rb", "GAME" )
	if mdl then
		mdl:Seek( STUDIOHDR_FLAGS_OFFSET )
		result = bit.band( mdl:ReadLong() or 0, STUDIOHDR_FLAGS_STATIC_PROP ) ~= 0
		mdl:Close()
	end

	staticOnly[path] = result
	return result
end

---Tree cards and leaves are translucent and two sided with many overlapping cards, which can't be sorted. An alpha tested copy
---writes depth and needs no order. Glass is translucent but one sided, and is left alone: an alpha test would make it vanish.
---@param material IMaterial
---@return IMaterial
local function cutoutCopy( material )
	local flags = material:GetInt( "$flags" ) or 0
	local twoSided = bit.band( flags, MATERIAL_VAR_NOCULL ) ~= 0
	local additive = ( material:GetInt( "$additive" ) or 0 ) ~= 0 or bit.band( flags, MATERIAL_VAR_ADDITIVE ) ~= 0

	if not twoSided or additive or not NikNaks.MeshBuilder.BlendsWithBackground( material ) then return material end

	local texture = material:GetTexture( "$basetexture" )
	if not texture then return material end

	local id = ( material:GetName():lower() .. "_" .. CUTOUT_REFERENCE ):gsub( "[^%w]", "_" )
	local shader = material:GetShader():gsub( "_DX%d+$", "" )
	return CreateMaterial( "PocketMap_PropCutout_" .. id, shader, {
		["$basetexture"] = texture:GetName(),
		["$model"] = 1,
		["$vertexcolor"] = 1,
		["$alphatest"] = 1,
		["$alphatestreference"] = CUTOUT_REFERENCE,
		["$allowalphatocoverage"] = 1,
		["$nocull"] = 1,
	} )
end

---The finest level of detail isn't needed: the first of these that the model has.
local function readTriangles( path )
	for _, lod in ipairs( LODS ) do
		local data = util.GetModelMeshes( path, lod )
		if data and #data > 0 then return data end
	end
end

local function buildMesh( material, triangles, first, last )
	local meshObject = Mesh( material )

	mesh.Begin( meshObject, MATERIAL_TRIANGLES, ( last - first + 1 ) / 3 )
	for i = first, last do
		local vertex = triangles[i]
		mesh.Position( vertex.pos )
		mesh.Normal( vertex.normal )
		mesh.TexCoord( 0, vertex.u, vertex.v )
		mesh.Color( 255, 255, 255, 255 )
		mesh.AdvanceVertex()
	end
	mesh.End()

	return meshObject
end

---@param parts table # collects { material, mesh, translucent }, and the flags hasOpaque / hasTranslucent
local function addPart( parts, material, triangles )
	local translucent = NikNaks.MeshBuilder.BlendsWithBackground( material )

	for first = 1, #triangles, MAX_VERTICES do
		local last = math.min( first + MAX_VERTICES - 1, #triangles )
		parts[#parts + 1] = { material = material, mesh = buildMesh( material, triangles, first, last ), translucent = translucent }
	end

	if translucent then parts.hasTranslucent = true else parts.hasOpaque = true end
end

---@param path string
---@return table? parts # nil if the model has no mesh data
function PropMesh.Build( path )
	local data = readTriangles( path )
	if not data then return nil end

	local parts = {}
	for _, part in ipairs( data ) do
		if part.triangles and #part.triangles >= 3 and part.material then
			addPart( parts, cutoutCopy( Material( part.material ) ), part.triangles )
		end
	end

	return #parts > 0 and parts or nil
end

function PropMesh.Destroy( parts )
	for _, part in ipairs( parts or {} ) do part.mesh:Destroy() end
end
