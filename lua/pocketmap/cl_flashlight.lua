-- Source's projected flashlight, positioned and traced in the source BSP.
-- The miniature supplies both the receiving meshes and its shadow-depth mesh.
PocketMap.Flashlight = PocketMap.Flashlight or {}
local Flashlight = PocketMap.Flashlight
if Flashlight.Stop then Flashlight.Stop() end
Flashlight.depthMaterials = {}
Flashlight.opaqueDepthMaterials = {}

local HULL_MINS, HULL_MAXS = Vector( -4, -4, -4 ), Vector( 4, 4, 4 )
local function setting( name, default )
	local cv = GetConVar( name )
	return cv and cv:GetFloat() or default
end

function Flashlight.Stop()
	if IsValid( Flashlight.projector ) then Flashlight.projector:Remove() end
	Flashlight.projector, Flashlight.mini, Flashlight.pullback = nil, nil, nil
	Flashlight.poseTraces = nil
end

function Flashlight.IsOn()
	local ply = LocalPlayer()
	return IsValid( ply ) and ply:GetNWBool( "PocketMap_FlashlightActive", false )
		and ply:GetNWBool( "PocketMap_FlashlightOn", false )
end

-- Source's flashlight traces use unscaled units. Scaling attenuation by the
-- same factor as distance preserves the shader's constant + linear/d + quad/d².
function Flashlight.Configure( lamp, scale, near )
	lamp:SetFOV( setting( "r_flashlightfov", 60 ) )
	lamp:SetNearZ( math.max( 0.001, near * scale ) )
	lamp:SetFarZ( setting( "r_flashlightfar", 750 ) * scale )
	lamp:SetConstantAttenuation( setting( "r_flashlightconstant", 0 ) )
	lamp:SetLinearAttenuation( setting( "r_flashlightlinear", 100 ) * scale )
	lamp:SetQuadraticAttenuation( setting( "r_flashlightquadratic", 0 ) * scale * scale )
	lamp:SetEnableShadows( setting( "r_flashlightdepthtexture", 1 ) ~= 0 )
	lamp:SetShadowDepthBias( setting( "mat_depthbias_shadowmap", 0.001 ) )
	lamp:SetShadowSlopeScaleDepthBias( setting( "mat_slopescaledepthbias_shadowmap", 2 ) )
end

-- The stock flashlight hangs below the eye and pulls back at nearby walls.
-- Query the miniature's collision, including props and moving brushes, rather
-- than tracing the real body and the unrelated outer map.
local function poseTrace( session, slot, start, finish, mask )
	local revision = session.io and session.io.drawRevision
	local world = session.io and session.io.world
	local cache = Flashlight.poseTraces
	if not cache or cache.session ~= session or cache.command ~= session.command or cache.revision ~= revision
		or cache.io ~= session.io or cache.world ~= world
		or cache.physics ~= session.physics or cache.displacements ~= session.displacements then
		cache = { session = session, command = session.command, revision = revision,
			io = session.io, world = world, physics = session.physics, displacements = session.displacements }
		Flashlight.poseTraces = cache
	end
	local entry = cache[slot]
	if entry and entry.start == start and entry.finish == finish and entry.mask == mask then return entry.result end
	local result = session:TraceHull( start, finish, HULL_MINS, HULL_MAXS, mask )
	cache[slot] = { start = start, finish = finish, mask = mask, result = result }
	return result
end

function Flashlight.Pose( session )
	local eye = session.move.origin + PocketMap.Walk.EyeOffset( session )
	local angles = session.move.angles
	local forward, up = angles:Forward(), angles:Up()
	local offset = setting( "r_flashlightoffsety", -20 )
	if setting( "r_swingflashlight", 1 ) ~= 0 then offset = offset + math.max( 0, -12 * forward.z ) end
	local origin = eye + up * offset
	local ladder = session.onladder == true
	local mask = bit.band( MASK_SOLID, bit.bnot( CONTENTS_HITBOX ) )
	if ladder or poseTrace( session, 1, eye, origin, mask ).Hit then origin = eye end
	local target = eye + forward * setting( "r_flashlightfar", 750 )
	local direction = ( target - origin ):GetNormalized()
	-- Keep the view's roll while orthogonalizing the projection basis.
	local lightUp = ( up - direction * up:Dot( direction ) ):GetNormalized()
	local lightAngles = direction:AngleEx( lightUp )
	mask = bit.bor( bit.band( MASK_OPAQUE_AND_NPCS, bit.bnot( CONTENTS_HITBOX ) ), CONTENTS_WINDOW )
	local trace = poseTrace( session, 2, origin, target, mask )
	local distance = origin:Distance( Vector( trace.HitPos.x, trace.HitPos.y, trace.HitPos.z ) )
	local pullback = Flashlight.pullback or 1
	if distance < 128 then
		local desired = ladder and setting( "r_flashlightladderdist", 40 ) or 128 - distance
		pullback = Lerp( 0.2, pullback, desired )
		if not ladder then
			local back = poseTrace( session, 3, origin, origin - direction * ( desired - 0.1 ), mask )
			if back.Hit then
				pullback = math.min( pullback, math.max( 0, origin:Distance( Vector( back.HitPos.x, back.HitPos.y, back.HitPos.z ) ) - 0.1 ) )
			end
		end
	else
		pullback = Lerp( 0.2, pullback, 0 )
	end
	Flashlight.pullback = pullback
	return origin - direction * pullback, lightAngles, setting( "r_flashlightnear", 4 ) + pullback
end

function Flashlight.Update()
	local session = PocketMap.Walk and PocketMap.Walk.session
	local mini = session and session.mini
	if mini and PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "flashlight" ) then return Flashlight.Stop() end
	if not mini or mini.state ~= "ready" or not IsValid( mini.ent ) or not LocalPlayer():Alive()
		or not Flashlight.IsOn() then return Flashlight.Stop() end
	if Flashlight.mini ~= mini then Flashlight.Stop() end
	local lamp = Flashlight.projector
	if not IsValid( lamp ) then
		lamp = ProjectedTexture()
		if not IsValid( lamp ) then return end
		lamp:SetTexture( "effects/flashlight001" )
		lamp:SetColor( color_white )
		lamp:SetBrightness( 1 )
		lamp:SetLightWorld( true )
		lamp:SetNoCull( true )
		Flashlight.projector, Flashlight.mini = lamp, mini
		mini.ent:CreateShadow()
	end
	local origin, angles, near = Flashlight.Pose( session )
	lamp:SetPos( mini.ent:LocalToWorld( mini:BlockPosition( origin ) ) )
	lamp:SetAngles( mini.ent:LocalToWorldAngles( angles ) )
	Flashlight.Configure( lamp, mini.scale, near )
	if PocketMap.Settings then
		lamp:SetEnableShadows( setting( "r_flashlightdepthtexture", 1 ) ~= 0
			and ( PocketMap.Settings.Enabled( mini, "world_shadows" ) or PocketMap.Settings.Enabled( mini, "prop_shadows" ) ) )
	end
	lamp:Update()
	mini.ent:MarkShadowAsDirty()
end

-- DepthWrite is essential: ordinary surface shaders omit Source's shadow
-- polygon offset and cause severe self-shadow stripes at miniature scales.
-- Alpha-tested fences and leaves retain their texture mask and UV transform.
function Flashlight.DepthMaterial( material )
	local cache = Flashlight.depthMaterials
	local depth = cache[material]
	if depth then return depth end
	local flags = material:GetInt( "$flags" ) or 0
	local alpha = ( material:GetInt( "$alphatest" ) or 0 ) ~= 0 or bit.band( flags, 256 ) ~= 0
	local texture = alpha and material:GetTexture( "$basetexture" )
	local values = { ["$model"] = 1, ["$nocull"] = ( material:GetInt( "$nocull" ) or 0 ) ~= 0 and 1 or 0 }
	if bit.band( flags, 8192 ) ~= 0 then values["$nocull"] = 1 end
	-- Opaque depth does not depend on the surface's color, normal map or lightmap.
	-- Sharing these materials also lets the loader batch across surface materials.
	local opaqueKey = not alpha and values["$nocull"]
	if opaqueKey and Flashlight.opaqueDepthMaterials[opaqueKey] then
		cache[material] = Flashlight.opaqueDepthMaterials[opaqueKey]
		return cache[material]
	end
	if texture then
		values["$basetexture"] = texture:GetName()
		values["$alphatest"] = 1
		values["$alphatestreference"] = material:GetFloat( "$alphatestreference" ) or 0.5
	end
	depth = CreateMaterial( "PocketMap_Depth_" .. util.CRC( material:GetName() ), "DepthWrite", values )
	if texture then
		depth:SetTexture( "$basetexture", texture )
		local transform = material:GetMatrix( "$basetexturetransform" )
		if transform then depth:SetMatrix( "$basetexturetransform", transform ) end
	end
	cache[material] = depth
	if opaqueKey then Flashlight.opaqueDepthMaterials[opaqueKey] = depth end
	return depth
end

-- Color meshes are split by material, spatial cell and PVS. Shadow depth needs
-- none of those splits: every caster is retained, including offscreen geometry.
-- Limit each upload so building a large map still cooperates with the loader.
local SHADOW_BATCH_VERTICES = 12000
function Flashlight.FlushWorldShadows( mini )
	local builder = mini.worldShadowBuilder
	if not builder then return end
	local object = builder:Build()
	mini.worldShadowObjects = mini.worldShadowObjects or {}
	mini.worldShadowObjects[#mini.worldShadowObjects + 1] = object
	mini.worldShadowMeshes = mini.worldShadowMeshes or {}
	for _, part in ipairs( object:GetMeshes() ) do
		mini.worldShadowMeshes[#mini.worldShadowMeshes + 1] = part
	end
	mini.worldShadowBuilder, mini.worldShadowVertices = nil, nil
end

function Flashlight.AddWorldShadowFace( mini, face, material )
	if PocketMap.Settings and ( not PocketMap.Settings.Enabled( mini, "world_shadows" ) or not PocketMap.Settings.Enabled( mini, "flashlight" ) ) then return end
	material = material or face:GetMaterial()
	if NikNaks.MeshBuilder.BlendsWithBackground( material ) then return end
	local vertices = face:GenerateVertexTriangleData()
	if not vertices or #vertices < 3 then return end
	if mini.worldShadowBuilder and ( mini.worldShadowVertices or 0 ) + #vertices > SHADOW_BATCH_VERTICES then
		Flashlight.FlushWorldShadows( mini )
		coroutine.yield()
	end
	mini.worldShadowBuilder = mini.worldShadowBuilder or NikNaks.MeshBuilder()
	mini.worldShadowBuilder:AddFace( face, { material = Flashlight.DepthMaterial( material ) } )
	mini.worldShadowVertices = ( mini.worldShadowVertices or 0 ) + #vertices
end

function Flashlight.FreeWorldShadows( mini )
	for _, object in ipairs( mini.worldShadowObjects or {} ) do object:Destroy() end
	mini.worldShadowObjects, mini.worldShadowMeshes = nil, nil
	mini.worldShadowBuilder, mini.worldShadowVertices = nil, nil
end

local depthOptions = { light = false, fullbright = false, material = Flashlight.DepthMaterial }

function Flashlight.DrawDepth( mini, flags )
	if not mini or mini.state ~= "ready" or not mini.scaleVec then return end
	if PocketMap.Settings and PocketMap.Settings.MinimalPreview( mini ) then return end
	if PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "flashlight" ) then return end
	local world = not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "world_shadows" )
	if world then
	mini:UpdateMatrix()
	cam.PushModelMatrix( mini.matrix )
	local ok, err = pcall( function()
		local batched = mini.worldShadowMeshes
		local parts = batched or mini.objects.opaqueMeshes
		if parts then
			local lastMaterial
			for _, part in ipairs( parts ) do
				local material = batched and part.material or Flashlight.DepthMaterial( part.material )
				if material ~= lastMaterial then
					render.SetMaterial( material )
					lastMaterial = material
				end
				part.mesh:Draw()
			end
		else
			for _, object in ipairs( mini.objects ) do object:DrawOpaque( nil, depthOptions ) end
		end
	end )
	cam.PopModelMatrix()
	if not ok then error( err, 0 ) end
	end
	-- Shadow casters must not use the main camera's PVS, occlusion or frustum:
	-- an offscreen prop can cast a visible shadow onto an onscreen wall.
	if world then PocketMap.MapIO.DrawDepth( mini, depthOptions, flags ) end
	if not PocketMap.Settings or PocketMap.Settings.Enabled( mini, "prop_shadows" ) then PocketMap.Props.DrawDepth( mini, flags ) end
end

PocketMap.Hooks.Register( "PreRender", "PocketMap_Flashlight", Flashlight.Update )
hook.Add( "ShutDown", "PocketMap_Flashlight", Flashlight.Stop )
