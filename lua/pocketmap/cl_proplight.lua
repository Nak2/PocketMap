-- Model lighting in source-map coordinates: indirect ambient cubes and the
-- strongest visible world lights. The renderer rebases both with the miniature.
if not PocketMap.Mini then return end

PocketMap.PropLight = PocketMap.PropLight or {}
local PropLight = PocketMap.PropLight
PropLight.__index = PropLight

local NORMALS = { Vector( 1, 0, 0 ), Vector( -1, 0, 0 ), Vector( 0, 1, 0 ), Vector( 0, -1, 0 ), Vector( 0, 0, 1 ), Vector( 0, 0, -1 ) }
local GRAY_CUBE = {}
local EMPTY_DIRECT = {}
for side = 1, 6 do GRAY_CUBE[side] = { 0.5, 0.5, 0.5 } end
local SUN_REACH, MAX_LIGHTS = 32768, 4
local ZERO_ANGLE = Angle()

local function worldLights( bsp, hdr )
	local lights = hdr and bsp:GetWorldLightsHDR() or bsp:GetWorldLights()
	if next( lights ) == nil then lights = bsp:GetWorldLights() end
	return lights
end

function PropLight.Prepare( bsp, hdr )
	if hdr then
		bsp:GetLeafAmbientIndexHDR()
		bsp:GetLeafAmbientLightingHDR()
	else
		bsp:GetLeafAmbientIndex()
		bsp:GetLeafAmbientLighting()
	end
	worldLights( bsp, hdr )
end

function PropLight.New( mini, bsp, lightToggle )
	local lights = {}
	for _, light in pairs( worldLights( bsp, mini.lighting == "HDR" ) ) do
		-- Small surface emitters are already included in the ambient cube by VRAD.
		if light.type <= 3 and bit.band( light.flags or 0, 1 ) == 0
			and ( lightToggle or light.style == 0 ) then lights[#lights + 1] = light end
	end
	return setmetatable( { bsp = bsp, mini = mini, hdr = mini.lighting == "HDR",
		lights = lights, leafCubes = {}, modelInfo = {} }, PropLight )
end

function PropLight:Position( prop, model )
	if prop.LightOrigin then return prop.LightOrigin end
	if not model then return prop.Origin end
	local info = self.modelInfo[model]
	if info == nil then
		info = util.GetModelInfo( model ) or false
		self.modelInfo[model] = info
	end
	if not info or not info.IllumPosition then return prop.Origin end
	return LocalToWorld( info.IllumPosition * ( prop.UniformScale or 1 ), ZERO_ANGLE, prop.Origin, prop.Angles or ZERO_ANGLE )
end

function PropLight:AmbientCube( at )
	local leaf = self.bsp:PointInLeaf( 0, at )
	if not leaf then return GRAY_CUBE end
	local samples = leaf:GetAmbientLighting( self.hdr )
	if #samples == 0 then return GRAY_CUBE end
	local single, id = #samples == 1, leaf:GetIndex()
	if single and self.leafCubes[id] then return self.leafCubes[id] end
	local colors = leaf:CalculateAmbientCube( at, self.hdr )
	if not colors then return GRAY_CUBE end
	local cube = {}
	for side = 1, 6 do
		local c = colors[side]
		-- Black is valid baked lighting, including in a brightly lit room whose
		-- light comes almost entirely from nearby direct lights.
		cube[side] = { math.max( c.r, 0 ), math.max( c.g, 0 ), math.max( c.b, 0 ) }
	end
	if single then self.leafCubes[id] = cube end
	return cube
end

local function angularScale( light, direction )
	if light.type == 0 then return math.max( 0, light.normal:Dot( direction ) ) end
	if light.type ~= 2 then return 1 end
	local dot = light.normal:Dot( direction )
	if dot <= light.stopdot2 then return 0 end
	if dot >= light.stopdot then return 1 end
	return ( ( dot - light.stopdot2 ) / ( light.stopdot - light.stopdot2 ) ) ^ light.exponent
end

local function lightStrength( light, at )
	if light.type == 3 then return 1 end
	local delta = at - light.origin
	local distance = delta:Length()
	if light.radius > 0 and distance > light.radius then return 0 end
	local direction = distance > 0 and delta / distance or Vector()
	local angle = angularScale( light, direction )
	local denominator = light.type == 0 and distance * distance or
		light.constant_attn + light.linear_attn * distance + light.quadratic_attn * distance * distance
	return angle / math.max( denominator, 0.000001 )
end

function PropLight:DirectLights( at, pause )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( self.mini, "prop_direct" ) then return EMPTY_DIRECT end
	local candidates = {}
	for i, light in ipairs( self.lights ) do
		if pause and i % 64 == 0 then pause() end
		local strength = lightStrength( light, at )
		local intensity = light.intensity
		local weight = self.mini.lightStyleWeights and self.mini.lightStyleWeights[light.style] or 1
		local animated = self.mini.lightStyles and self.mini.lightStyles.animated[light.style]
		local score = strength * math.max( intensity.x, intensity.y, intensity.z ) * ( animated and 2 or weight )
		if score > 0 then candidates[#candidates + 1] = { light = light, score = score } end
	end
	table.sort( candidates, function( a, b ) return a.score > b.score end )
	local visible = {}
	for i, candidate in ipairs( candidates ) do
		if pause and i % 8 == 0 then pause() end
		local light = candidate.light
		local target = light.type == 3 and at - light.normal * SUN_REACH or light.origin
		local blocked
		if light.type ~= 3 and self.bsp.SurfaceTraceBlocked then
			blocked = self.bsp:SurfaceTraceBlocked( at, target )
		else
			-- Sunlight needs the nearest surface's sky flag. Older NikNaks
			-- installations retain the full trace for every light as well.
			local trace = self.bsp:SurfaceTraceLine( at, target )
			blocked = trace.Hit and not ( light.type == 3 and trace.HitSky )
		end
		if not blocked then
			visible[#visible + 1] = light
			if #visible == MAX_LIGHTS then break end
		end
	end
	return visible
end

function PropLight:Of( prop, model, pause )
	local at = self:Position( prop, model )
	if PocketMap.Settings and not PocketMap.Settings.Enabled( self.mini, "prop_lighting" ) then
		local light = { at = at, direct = EMPTY_DIRECT, mini = self.mini, fullbright = true }
		for side = 1, 6 do light[side] = Vector( 1, 1, 1 ) end
		return light
	end
	local ambient = self:AmbientCube( at )
	local light = { at = at, direct = self:DirectLights( at, pause ), mini = self.mini }
	for side = 1, 6 do light[side] = ambient[side] end
	return light
end

-- Build once per render pass, and retain it while the source-to-world transform
-- is unchanged. Cubes use world axes, independent of a particular prop's angle.
function PropLight.Transform( matrix, previous )
	local pos, angles, scale = matrix:GetTranslation(), matrix:GetAngles(), matrix:GetScale().x
	if previous and previous.pos == pos and previous.angles == angles and previous.scale == scale then return previous end
	local inverse = Matrix()
	inverse:SetAngles( angles )
	inverse:Invert()
	local normals = {}
	for side = 1, 6 do normals[side] = inverse * NORMALS[side] end
	local copy = Matrix()
	copy:Set( matrix )
	return { matrix = copy, pos = pos, angles = angles, scale = scale, normals = normals }
end

local function rotateCube( cube, normals )
	local rotated = {}
	for side = 1, 6 do
		local n = normals[side]
		local x, y, z = cube[n.x >= 0 and 1 or 2], cube[n.y >= 0 and 3 or 4], cube[n.z >= 0 and 5 or 6]
		rotated[side] = {}
		for channel = 1, 3 do rotated[side][channel] = x[channel] * n.x^2 + y[channel] * n.y^2 + z[channel] * n.z^2 end
	end
	return rotated
end

function PropLight.ForRender( light, transform )
	local styles = light.mini and light.mini.lightStyles
	local sources = light.direct or EMPTY_DIRECT
	local animated = false
	if styles then
		for _, source in ipairs( sources ) do
			if styles.animated[source.style] then animated = true break end
		end
	end
	local tick = animated and PocketMap.LightStyles.CurrentTick() or 0
	local uniform = light.fullbright or light.mini and PocketMap.Settings and not PocketMap.Settings.Enabled( light.mini, "directional_prop_ambient" ) or false
	local cached = light.rendered
	if cached and cached.system == PropLight and cached.transform == transform and cached.tick == tick and ( cached.uniform ~= nil ) == uniform then return cached end
	local cube, average
	if uniform then
		if not light.uniformCube then
			average = { 0, 0, 0 }
			for side = 1, 6 do for channel = 1, 3 do average[channel] = average[channel] + light[side][channel] / 6 end end
			light.uniformCube = {}
			for side = 1, 6 do light.uniformCube[side] = average end
		end
		cube, average = light.uniformCube, light.uniformCube[1]
	else
		cube = cached and not cached.uniform and cached.transform == transform and cached.cube or rotateCube( light, transform.normals )
	end
	local direct = #sources > 0 and {} or EMPTY_DIRECT
	local scale = transform.scale
	for _, source in ipairs( sources ) do
		local weight = styles and PocketMap.LightStyles.WeightAtTick( styles, source.style, tick )
			or ( light.mini and light.mini.lightStyleWeights and light.mini.lightStyleWeights[source.style] ) or 1
		local color = source.intensity * weight
		if source.type == 0 then color = color * angularScale( source, ( light.at - source.origin ):GetNormalized() ) end
		-- BSP skylights and LightDesc_t both store the direction light travels.
		-- The model shader negates it for N dot L; negating here as well lights
		-- the undersides of props and leaves their sun-facing surfaces dark.
		local dir = Vector( source.normal )
		dir:Rotate( transform.angles )
		local constant = source.type == 3 and 1 or source.type == 0 and 0 or source.constant_attn
		local linear = source.type == 0 and 0 or source.linear_attn / scale
		local quadratic = ( source.type == 0 and 1 or source.quadratic_attn ) / ( scale * scale )
		-- SetLocalModelLights uses LightDesc_t::SetupOldStyleAttenuation,
		-- which multiplies color by the denominator at 100 world units. BSP
		-- intensities already include that normalization; undo it at this scale.
		local normalization = constant + linear * 100 + quadratic * 10000
		if normalization > 0 then color = color / normalization end
		direct[#direct + 1] = {
			type = source.type == 3 and 2 or source.type == 2 and 3 or 1,
			color = color, pos = transform.matrix * source.origin, dir = dir,
			range = source.radius * scale,
			constantFalloff = constant, linearFalloff = linear, quadraticFalloff = quadratic,
			innerAngle = math.deg( math.acos( math.Clamp( source.stopdot, -1, 1 ) ) ),
			outerAngle = math.deg( math.acos( math.Clamp( source.stopdot2, -1, 1 ) ) ),
			angularFalloff = source.exponent,
		}
	end
	cached = { system = PropLight, transform = transform, tick = tick, cube = cube, direct = direct, uniform = average }
	light.rendered = cached
	return cached
end
