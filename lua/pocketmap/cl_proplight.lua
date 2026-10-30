-- The light of a prop, the way the engine lights a model: the ambient light cube of the leaf it stands in. Each side is
-- { r, g, b } in linear light, in the order of render.SetModelLighting: +X, -X, +Y, -Y, +Z, -Z.

if not PocketMap.Mini then return end

PocketMap.PropLight = {}
local PropLight = PocketMap.PropLight
PropLight.__index = PropLight

local SIDES = 6
local MIN_SIDE_LIGHT = 0.1
local SUN_REACH = 32768
local SUN_START_OFFSET = 4
local FLOOR_PROBE_UP, FLOOR_PROBE_DOWN = 4, 512
local FIRST_SWITCHABLE_STYLE = 32

local CUBE_NORMALS = { Vector( 1, 0, 0 ), Vector( -1, 0, 0 ), Vector( 0, 1, 0 ), Vector( 0, -1, 0 ), Vector( 0, 0, 1 ), Vector( 0, 0, -1 ) }
local FLOOR_SIDES = { 0.5, 0.5, 0.5, 0.5, 1, 0.25 }

local GRAY_CUBE = {}
for side = 1, SIDES do GRAY_CUBE[side] = { 0.5, 0.5, 0.5 } end

local function isAnimatedStyle( style )
	return style > 0 and style < FIRST_SWITCHABLE_STYLE
end

---A light_environment becomes two world lights: the sky ambient, which is in the cubes, and the sun, which is not.
---A named one (gm_construct's sun_light) has a style of 32 or more and can be switched off.
---@return table? sun
---@return number weight
local function findSun( bsp, hdr, weights )
	local lights = hdr and bsp:GetWorldLightsHDR() or bsp:GetWorldLights()
	if next( lights ) == nil then lights = bsp:GetWorldLights() end

	for _, worldLight in pairs( lights ) do
		if worldLight:IsSkyLight() and not isAnimatedStyle( worldLight.style ) then
			local weight = weights[worldLight.style] or 1
			if weight > 0 then return worldLight, weight end
		end
	end
	return nil, 1
end

---Reads the lumps the lookups need, so that does not happen in the middle of a loader step.
function PropLight.Prepare( bsp, hdr )
	if hdr then
		bsp:GetLeafAmbientIndexHDR()
		bsp:GetLeafAmbientLightingHDR()
	else
		bsp:GetLeafAmbientIndex()
		bsp:GetLeafAmbientLighting()
	end
end

---@param mini table
---@param bsp BSPObject
---@param lightToggle boolean # false: no sun, the cube only
function PropLight.New( mini, bsp, lightToggle )
	local light = setmetatable( {
		bsp = bsp,
		hdr = mini.lighting == "HDR",
		weights = mini.lightStyleWeights,
		leafCubes = {},
		faceLights = {},
		sunWeight = 1,
	}, PropLight )

	if lightToggle then light.sun, light.sunWeight = findSun( bsp, light.hdr, light.weights ) end
	if light.sun then light.toSun = -Vector( light.sun.normal ) end
	return light
end

local function lightPosition( prop )
	return prop.LightOrigin or prop.Origin
end

---Leaves with one sample have the same light everywhere, so their cube is kept.
function PropLight:AmbientCube( prop )
	local at = lightPosition( prop )
	local leaf = self.bsp:PointInLeaf( 0, at )
	if not leaf then return GRAY_CUBE end

	local samples = leaf:GetAmbientLighting( self.hdr )
	if #samples == 0 then return GRAY_CUBE end

	local single = #samples == 1
	local id = leaf:GetIndex()
	if single and self.leafCubes[id] then return self.leafCubes[id] end

	local colors = leaf:CalculateAmbientCube( at, self.hdr )
	if not colors then return GRAY_CUBE end

	local cube = {}
	for side = 1, SIDES do
		local c = colors[side]
		cube[side] = { math.max( c.r, MIN_SIDE_LIGHT ), math.max( c.g, MIN_SIDE_LIGHT ), math.max( c.b, MIN_SIDE_LIGHT ) }
	end

	if single then self.leafCubes[id] = cube end
	return cube
end

---The sun reaches a prop when a line towards it meets the sky before a wall or a roof.
function PropLight:SunReaches( prop )
	if not self.sun then return false end

	local start = lightPosition( prop ) + self.toSun * SUN_START_OFFSET
	local trace = self.bsp:SurfaceTraceLine( start, start + self.toSun * SUN_REACH )
	return not trace.Hit or trace.HitSky == true
end

---Each side gets the sun times how much it faces it.
function PropLight:WithSun( cube )
	local intensity = self.sun.intensity
	local lit = {}

	for side = 1, SIDES do
		local facing = math.max( CUBE_NORMALS[side]:Dot( self.toSun ), 0 ) * self.sunWeight
		local c = cube[side]
		lit[side] = { c[1] + intensity.x * facing, c[2] + intensity.y * facing, c[3] + intensity.z * facing }
	end
	return lit
end

---The average light of a face, all its styles added: { r, g, b }, or nil if it has no lightmap.
function PropLight:FaceLight( face )
	local cached = self.faceLights[face.__id]
	if cached ~= nil then return cached or nil end

	local r, g, b, found = 0, 0, 0, false
	local samples = face:GetLightmapSamples( self.hdr )

	if samples and samples.styles then
		for i, style in ipairs( samples.styles ) do
			local average = samples.average[i]
			if average then
				found = true
				local weight = self.weights[style] or ( isAnimatedStyle( style ) and 0.5 or 1 )
				r = r + weight * ( average.color.r * 2 / 255 ) ^ 2.2
				g = g + weight * ( average.color.g * 2 / 255 ) ^ 2.2
				b = b + weight * ( average.color.b * 2 / 255 ) ^ 2.2
			end
		end
	end

	self.faceLights[face.__id] = found and { r, g, b } or false
	return found and self.faceLights[face.__id] or nil
end

function PropLight:FloorLight( prop )
	local from = lightPosition( prop ) + Vector( 0, 0, FLOOR_PROBE_UP )
	local trace = self.bsp:SurfaceTraceLine( from, from - Vector( 0, 0, FLOOR_PROBE_DOWN ) )
	if trace.Hit and trace.Face then return self:FaceLight( trace.Face ) end
end

---The cubes only hold light style 0, so a prop in the shade of a switchable sun would be almost black next to the floor it
---stands on. The floor's lightmap has every style, so it is the least ambient the prop gets.
local function withFloor( cube, floor )
	local lit = {}
	for side = 1, SIDES do
		local c, factor = cube[side], FLOOR_SIDES[side]
		lit[side] = { math.max( c[1], floor[1] * factor ), math.max( c[2], floor[2] * factor ), math.max( c[3], floor[3] * factor ) }
	end
	return lit
end

---The ambient cube, plus the sun if it reaches the prop, else at least the light of the floor under it.
---@param prop table # { Origin, LightOrigin }
---@return table[] cube
function PropLight:Of( prop )
	local cube = self:AmbientCube( prop )
	if self:SunReaches( prop ) then return self:WithSun( cube ) end

	local floor = self:FloorLight( prop )
	return floor and withFloor( cube, floor ) or cube
end
