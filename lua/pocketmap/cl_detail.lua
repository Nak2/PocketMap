-- Detail props: the grass and plants on the ground. bsp:GetDetailPropInfo() has the sprite sheet rectangles and the model list,
-- bsp:GetDetailProp( i ) one object at a time. Sprites are baked into a few meshes, models are added to the props.

if not PocketMap.Mini then return end

PocketMap.Detail = {}
local Detail = PocketMap.Detail

local DETAIL = NikNaks.DETAIL_PROP_TYPE
local SPRITES_PER_MESH = 400
local MAX_DETAIL_PROPS = 30000
local CUTOUT_REFERENCE = 0.5
local SPRITE_ORIENTATION_FIXED = 0
local STATUS_BASE = 0.64
local STATUS_RANGE = 0.01

local function newSpriteBuffer()
	return { n = 0, x = {}, y = {}, z = {}, u = {}, v = {}, r = {}, g = {}, b = {} }
end

local function loadSheet( name )
	name = name:lower():gsub( "\\", "/" ):gsub( "%.vmt$", "" )

	local material = Material( name )
	return not material:IsError() and material or nil
end

---Overlapping sprites of a translucent sheet need sorting. An alpha tested copy writes depth and needs no order.
local function cutoutCopy( sheet )
	local texture = sheet:GetTexture( "$basetexture" )
	if not texture then return sheet end

	local id = ( sheet:GetName():lower() .. "_" .. CUTOUT_REFERENCE ):gsub( "[^%w]", "_" )
	return CreateMaterial( "PocketMap_DetailCutout_" .. id, "UnlitGeneric", {
		["$basetexture"] = texture:GetName(),
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
		["$alphatest"] = 1,
		["$alphatestreference"] = CUTOUT_REFERENCE,
		["$allowalphatocoverage"] = 1,
		["$nocull"] = 1,
	} )
end

local function lightToDisplay( channel, exponent )
	return math.min( 255 * ( channel * 2 ^ exponent / 255 ) ^ ( 1 / 2.2 ), 255 )
end

---A sprite that turns to face the player can't be baked, so it is drawn as a cross.
local function planeCount( object )
	if object.Type == DETAIL.SHAPE_TRI then return 3 end
	if object.Type == DETAIL.SPRITE and object.Orientation == SPRITE_ORIENTATION_FIXED then return 1 end
	return 2
end

local QUAD_TRIANGLES = { 1, 2, 3, 1, 3, 4 }

local function appendQuad( buffer, corners, light )
	local n = buffer.n
	for _, corner in ipairs( QUAD_TRIANGLES ) do
		n = n + 1
		buffer.x[n], buffer.y[n], buffer.z[n] = corners.x[corner], corners.y[corner], corners.z[corner]
		buffer.u[n], buffer.v[n] = corners.u[corner], corners.v[corner]
		buffer.r[n], buffer.g[n], buffer.b[n] = light.r, light.g, light.b
	end
	buffer.n = n
end

local function appendSprite( buffer, object, sprite )
	local scale = object.Scale > 0 and object.Scale or 1
	local left, right = sprite.ul[1] * scale, sprite.lr[1] * scale
	local ulY, lrY = sprite.ul[2] * scale, sprite.lr[2] * scale
	local top, bottom = math.max( ulY, lrY ), math.min( ulY, lrY )
	local u0, v0, u1, v1 = sprite.texUL[1], sprite.texUL[2], sprite.texLR[1], sprite.texLR[2]

	local lighting = object.Lighting
	local light = {
		r = lightToDisplay( lighting.r, lighting.exponent ),
		g = lightToDisplay( lighting.g, lighting.exponent ),
		b = lightToDisplay( lighting.b, lighting.exponent ),
	}

	local origin = object.Origin
	local planes = planeCount( object )
	local yaw = math.rad( object.Angles.y )

	for plane = 0, planes - 1 do
		local angle = yaw + plane * math.pi / planes
		local rx, ry = math.cos( angle ), math.sin( angle )

		appendQuad( buffer, {
			x = { origin.x + rx * left, origin.x + rx * right, origin.x + rx * right, origin.x + rx * left },
			y = { origin.y + ry * left, origin.y + ry * right, origin.y + ry * right, origin.y + ry * left },
			z = { origin.z + top, origin.z + top, origin.z + bottom, origin.z + bottom },
			u = { u0, u1, u1, u0 },
			v = { v0, v0, v1, v1 },
		}, light )
	end
end

local function buildMesh( material, buffer )
	local meshObject = Mesh( material )
	local position = Vector()

	mesh.Begin( meshObject, MATERIAL_TRIANGLES, buffer.n / 3 )
	for i = 1, buffer.n do
		position:SetUnpacked( buffer.x[i], buffer.y[i], buffer.z[i] )
		mesh.Position( position )
		mesh.TexCoord( 0, buffer.u[i], buffer.v[i] )
		mesh.Color( buffer.r[i], buffer.g[i], buffer.b[i], 255 )
		mesh.AdvanceVertex()
	end
	mesh.End()

	return meshObject
end

local function flushMesh( mini, material, buffer )
	mini.detailMeshes[#mini.detailMeshes + 1] = buildMesh( material, buffer )
	mini.detailMaterial = material
end

---@param job table # the loader's job: bsp, addProp
function Detail.Build( mini, job )
	local bsp = job.bsp
	local info = bsp:GetDetailPropInfo()
	if not info or info.count == 0 then return end

	local sheet = loadSheet( bsp:GetDetailMaterial() )
	local material = sheet and cutoutCopy( sheet )
	local step = math.max( 1, math.ceil( info.count / MAX_DETAIL_PROPS ) )
	local buffer, inBuffer = newSpriteBuffer(), 0

	for index = 0, info.count - 1, step do
		local object = bsp:GetDetailProp( index )

		if object.Type == DETAIL.MODEL then
			local path = info.models[object.Index]
			if path then
				job.addProp( path, object.Origin, object.Angles, 0, nil )
				mini.detailModels = mini.detailModels + 1
			end
		elseif material and info.sprites[object.Index] then
			appendSprite( buffer, object, info.sprites[object.Index] )
			inBuffer = inBuffer + 1
			mini.detailSprites = mini.detailSprites + 1
		end

		if inBuffer >= SPRITES_PER_MESH then
			mini:SetStatus( "Detail props", STATUS_BASE + STATUS_RANGE * index / info.count )
			flushMesh( mini, material, buffer )
			buffer, inBuffer = newSpriteBuffer(), 0
			coroutine.yield()
		end
	end

	if inBuffer > 0 then flushMesh( mini, material, buffer ) end
	coroutine.yield()
end

---A translucent sheet is drawn in the translucent half. The meshes are built while the map loads, so this only answers once the sheet is there.
---@return boolean
function Detail.Blends( mini )
	if #mini.detailMeshes == 0 or not mini.detailMaterial then return false end

	if mini.detailBlends == nil then
		mini.detailBlends = NikNaks.MeshBuilder.BlendsWithBackground( mini.detailMaterial )
	end
	return mini.detailBlends
end

function Detail.Draw( mini )
	local meshes = mini.detailMeshes
	if #meshes == 0 then return end

	cam.PushModelMatrix( mini.matrix )
	render.SetMaterial( mini.detailMaterial )
	for i = 1, #meshes do meshes[i]:Draw() end
	cam.PopModelMatrix()
end
