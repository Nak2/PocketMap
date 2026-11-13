-- Props: the static props of the map (bsp:GetStaticProps) and every entity with a .mdl model, grouped by model.
-- A group is drawn as baked meshes (cl_propmesh.lua) or, when that isn't possible, as a hidden clientside model.

if not PocketMap.Mini then return end

PocketMap.Props = PocketMap.Props or {}
local Props = PocketMap.Props
local Entities = PocketMap.Entities

local STATIC_PROP_USE_LIGHTING_ORIGIN = 2
local RENDERMODE_DONT_RENDER = 10
local EF_NODRAW = 32
local MISSING_NAMES_KEPT = 8
local SIDES = 6
local PVS_BOUNDS_PAD = 4
local PVS_MAX_BOUNDS_SPAN = 1024
local PVS_MAX_LEAFS = 128
local CONTENTS_SOLID = 1
local FRUSTUM_PAD = 4
local FRUSTUM_FOV_PAD = 3
local OCCLUSION_PAD = 5
local OCCLUSION_MAX_RADIUS = 350
local ZERO_ANGLE = Angle()

local cvPropOcclusion = CreateClientConVar( "pocketmap_prop_occlusion", "1", true, false,
	"Cull miniature props behind solid BSP surfaces while the viewer is stationary" )
local cvPropFrustumCache = CreateClientConVar( "pocketmap_prop_frustum_cache", "1", true, false,
	"Reuse prop frustum visibility while the camera and miniature stay still" )

local cvWaterClipBounds = CreateClientConVar( "pocketmap_water_clip_bounds", "1", true, false,
	"Cache conservative world candidates on each side of a water plane" )

local DRAW_FLAGS = bit.bor( STUDIO_RENDER or 1, STUDIO_DRAWTRANSLUCENTSUBMODELS or 4 )
local OPAQUE_FLAGS = STUDIO_RENDER or 1

-- Collecting ----------------------------------------------------------------------------------------------------------

local function newModelIndex( bsp, skyArea )
	local index = { byModel = {}, models = {}, animOf = {} }

	---A prop with an animation is a group of its own: the meshes are the reference pose, so it is drawn as an entity posed by the sequence.
	index.addProp = function( path, origin, angles, skin, propScale, lightOrigin, sky, anim, entityProp )
		if anim then
			local key = path .. "\0" .. anim
			index.animOf[key] = { path, anim }
			path = key
		end

		if not index.byModel[path] then
			index.byModel[path] = {}
			index.models[#index.models + 1] = path
		end

		table.insert( index.byModel[path], {
			Origin = origin, Angles = angles, Skin = skin, UniformScale = propScale,
			LightOrigin = lightOrigin, Sky = sky, EntityProp = entityProp,
		} )
	end

	---Props in the room of the 3D skybox are drawn with it, not in the block.
	index.inSkyRoomAt = function( origin )
		if not skyArea or not origin then return false end

		local leaf = bsp:PointInLeaf( 0, origin )
		return leaf ~= nil and leaf.area == skyArea
	end

	return index
end

local function countProp( mini, sky, counter )
	if sky then mini.skyProps = ( mini.skyProps or 0 ) + 1 else mini[counter] = mini[counter] + 1 end
end

local function readStaticProps( mini, job )
	mini:SetStatus( "Reading the static props", 0.6 )
	local staticProps = job.bsp:GetStaticProps()
	coroutine.yield()

	for _, prop in pairs( staticProps ) do
		if prop.PropType then
			local usesLightingOrigin = prop.Flags and bit.band( prop.Flags, STATIC_PROP_USE_LIGHTING_ORIGIN ) ~= 0
			local sky = job.inSkyRoomAt( prop.Origin )
			if not PocketMap.Settings or PocketMap.Settings.Enabled( mini, sky and "sky_props" or "static_props" ) then
			job.addProp( prop.PropType, prop.Origin, prop.Angles, prop.Skin, prop.UniformScale, usesLightingOrigin and prop.LightingOrigin or nil, sky )
			countProp( mini, sky, "staticCount" )
			end
		end
	end
	coroutine.yield()
end

---An entity's "LightingOrigin" names an info_lighting entity, and the light is taken at its origin.
local function readLightingOrigins( entities )
	local origins = {}
	for _, entity in pairs( entities ) do
		local name = Entities.Name( entity )
		if Entities.Class( entity ) == "info_lighting" and name and entity.origin then origins[name] = entity.origin end
	end
	return origins
end

local function modelPathOf( entity )
	local model = Entities.First( entity.model )
	if type( model ) == "string" and model:lower():find( "%.mdl$" ) then return model end
end

local function isHiddenByMap( entity )
	local renderMode = tonumber( entity.rendermode ) or 0
	local renderAmount = tonumber( entity.renderamt )
	local effects = tonumber( entity.effects ) or 0

	return renderMode == RENDERMODE_DONT_RENDER or ( renderMode ~= 0 and renderAmount == 0 ) or bit.band( effects, EF_NODRAW ) ~= 0
end

---Some entities only have the old "angle" key: a yaw, with -1 for up and -2 for down.
local function anglesOf( entity )
	local angles = entity.angles
	local oldAngle = tonumber( Entities.First( entity.angle ) )
	local unset = not angles or ( angles.p == 0 and angles.y == 0 and angles.r == 0 )

	if oldAngle and unset then
		if oldAngle == -1 then return Angle( -90, 0, 0 ) end
		if oldAngle == -2 then return Angle( 90, 0, 0 ) end
		return Angle( 0, oldAngle, 0 )
	end
	return angles or Angle()
end

local function animOf( entity )
	local anim = Entities.First( entity.DefaultAnim or entity.defaultanim )
	return type( anim ) == "string" and anim ~= "" and anim or nil
end

local function readEntityProps( mini, job )
	local lightingOrigins = readLightingOrigins( job.entities )

	for _, entity in pairs( job.entities ) do
		local model = modelPathOf( entity )
		local class = Entities.Class( entity )

		if model and class ~= "prop_door_rotating" and not class:find( "^trigger_" ) then
			if isHiddenByMap( entity ) then
				mini.hiddenEntities = mini.hiddenEntities + 1
			else
				local sky = job.inSkyRoomAt( entity.origin )
				if not PocketMap.Settings or PocketMap.Settings.Enabled( mini, sky and "sky_props" or "entity_props" ) then
				local lightName = Entities.First( entity.lightingorigin or entity.LightingOrigin )
				local lightOrigin = type( lightName ) == "string" and lightingOrigins[lightName:lower()] or nil
				local kind = class:find( "^prop_dynamic" ) and "dynamic" or true

				job.addProp( model, entity.origin, anglesOf( entity ), tonumber( entity.skin ) or 0, tonumber( entity.modelscale ), lightOrigin, sky, animOf( entity ), kind )
				countProp( mini, sky, "entityCount" )
				end
			end
		end
	end
	coroutine.yield()
end

function Props.Collect( mini, job )
	local index = newModelIndex( job.bsp, job.skyArea )
	job.byModel, job.models, job.animOf, job.addProp, job.inSkyRoomAt = index.byModel, index.models, index.animOf, index.addProp, index.inSkyRoomAt

	readStaticProps( mini, job )
	readEntityProps( mini, job )
end

-- The hidden clientside model every prop group is drawn with ----------------------------------------------------------

local function propEntity( mini )
	if not IsValid( mini.propEnt ) then
		mini.propEnt = ClientsideModel( "models/error.mdl", RENDERGROUP_OTHER )
		mini.propEnt:SetNoDraw( true )
	end
	return mini.propEnt
end

function Props.Destroy( mini )
	if IsValid( mini.propEnt ) then mini.propEnt:Remove() end
	mini.propEnt = nil
	mini.propPassGroups, mini.skyPassGroups = nil, nil
end

---Does the model have a material that blends with the background? Cached on the group: a model never changes.
local function hasTranslucentMaterial( group, entity )
	if group.entTranslucent == nil then
		group.entTranslucent = false

		for _, name in ipairs( entity:GetMaterials() or {} ) do
			local material = Material( name )
			if not material:IsError() and NikNaks.MeshBuilder.BlendsWithBackground( material ) then
				group.entTranslucent = true
				break
			end
		end
	end
	return group.entTranslucent
end

-- Placing -------------------------------------------------------------------------------------------------------------

---A model with a skeleton (a bridge, a gate) is in the pose of its first sequence in the game even without a DefaultAnim.
---A prop_dynamic is always treated that way: its model can move a single bone.
local function needsSequencePose( mini, props, path )
	local skeleton

	for _, prop in ipairs( props ) do
		if prop.EntityProp == "dynamic" then return true end

		if prop.EntityProp then
			if skeleton == nil then
				local probe = propEntity( mini )
				probe:SetModel( path )
				skeleton = probe:GetBoneCount() > 1
			end
			if skeleton then return true end
		end
	end
	return false
end

-- Keep every cluster touched by the model's padded, rotated bounds in map space.
-- A leaf without visibility information makes the prop ineligible for PVS culling.
local function propClusters( bsp, prop, mins, maxs )
	if not mins or not maxs then return nil end
	local scale = prop.UniformScale or 1
	if scale <= 0 or scale >= math.huge or scale ~= scale then return nil end

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for x = 0, 1 do for y = 0, 1 do for z = 0, 1 do
		local corner = Vector(
			( x == 0 and mins.x or maxs.x ) * scale,
			( y == 0 and mins.y or maxs.y ) * scale,
			( z == 0 and mins.z or maxs.z ) * scale
		)
		local point = LocalToWorld( corner, ZERO_ANGLE, prop.Origin, prop.Angles )
		minX, minY, minZ = math.min( minX, point.x ), math.min( minY, point.y ), math.min( minZ, point.z )
		maxX, maxY, maxZ = math.max( maxX, point.x ), math.max( maxY, point.y ), math.max( maxZ, point.z )
	end end end

	-- Large bounds can touch thousands of BSP leaves; leave such models visible.
	if minX <= -math.huge or maxX >= math.huge or
		minY <= -math.huge or maxY >= math.huge or minZ <= -math.huge or maxZ >= math.huge or
		maxX - minX > PVS_MAX_BOUNDS_SPAN or maxY - minY > PVS_MAX_BOUNDS_SPAN or
		maxZ - minZ > PVS_MAX_BOUNDS_SPAN then return nil end

	local leaves = bsp:AABBInLeafs( 0, Vector( minX, minY, minZ ), Vector( maxX, maxY, maxZ ), PVS_BOUNDS_PAD )
	if #leaves == 0 or #leaves > PVS_MAX_LEAFS then return nil end

	local clusters, seen = {}, {}
	for _, leaf in ipairs( leaves ) do
		if not leaf or not leaf.cluster then return nil end
		if leaf.cluster < 0 then
			-- Solid BSP space cannot be viewed; any other unknown leaf must fail open.
			if not leaf.contents or bit.band( leaf.contents, CONTENTS_SOLID ) == 0 then return nil end
		elseif not seen[leaf.cluster] then
			seen[leaf.cluster] = true
			clusters[#clusters + 1] = leaf.cluster
		end
	end

	if #clusters == 1 then return clusters[1] end
	if #clusters > 1 then return nil, clusters end
end

local function modelBounds( mini, path )
	local entity = propEntity( mini )
	entity:SetModel( path )
	local mins, maxs = entity:GetModelRenderBounds()
	return mins, maxs
end

-- A sphere enclosing the model in block space. Animated props have no reliable fixed bounds.
local function propSphere( mini, prop, mins, maxs, blockScale )
	if not mins or not maxs then return nil end
	local scale = ( prop.UniformScale or 1 ) * blockScale
	if scale <= 0 or scale >= math.huge or scale ~= scale then return nil end

	local center = ( mins + maxs ) * ( ( prop.UniformScale or 1 ) * 0.5 )
	local mapCenter = LocalToWorld( center, ZERO_ANGLE, prop.Origin, prop.Angles )
	local radius = ( maxs - mins ):Length() * scale * 0.5 + FRUSTUM_PAD * blockScale
	if radius >= math.huge or radius ~= radius then return nil end
	local half = ( maxs - mins ) * ( scale * 0.5 )
	local forward, right, up = prop.Angles:Forward(), prop.Angles:Right(), prop.Angles:Up()
	local pad = FRUSTUM_PAD * blockScale
	local extents = Vector(
		math.abs( forward.x ) * half.x + math.abs( right.x ) * half.y + math.abs( up.x ) * half.z + pad,
		math.abs( forward.y ) * half.x + math.abs( right.y ) * half.y + math.abs( up.y ) * half.z + pad,
		math.abs( forward.z ) * half.x + math.abs( right.z ) * half.y + math.abs( up.z ) * half.z + pad )
	return ( mapCenter - mini.mapCenter ) * blockScale + mini.boxCenter, radius, extents
end

---Props are placed relative to the block, so each frame only needs the block's transform.
local function newPlacer( mini, job, light )
	local scale = job.scale

	return {
		inBlock = function( prop, mins, maxs, model )
			local pvsCluster, pvsClusters = propClusters( job.bsp, prop, mins, maxs )
			local sphereCenter, sphereRadius, boxExtents = propSphere( mini, prop, mins, maxs, scale )
			return {
				lpos = ( prop.Origin - mini.mapCenter ) * scale + mini.boxCenter,
				langles = prop.Angles,
				skin = prop.Skin or 0,
				lscale = ( prop.UniformScale or 1 ) * scale,
				light = light:Of( prop, model, coroutine.yield ),
				pvsCluster = pvsCluster, pvsClusters = pvsClusters,
				lcenter = sphereCenter, sphereRadius = sphereRadius, boxExtents = boxExtents,
			}
		end,

		---A prop of the sky room stays where it is in the sky room: it moves with the skybox.
		inSkyRoom = function( prop, model )
			return { origin = prop.Origin, angles = prop.Angles, skin = prop.Skin or 0, uscale = prop.UniformScale or 1, light = light:Of( prop, model, coroutine.yield ) }
		end,
	}
end

local function addGroup( mini, group )
	mini.propGroups[#mini.propGroups + 1] = group
end

---@param props table[] # the props of one model
local function placeModel( mini, placer, props, path, anim, bakeMeshes )
	local kept, skyKept, keptPosed = {}, {}, {}
	local posed = not anim and needsSequencePose( mini, props, path )
	local mins, maxs = modelBounds( mini, path )

	for index, prop in ipairs( props ) do
		if prop.Sky then
			skyKept[#skyKept + 1] = placer.inSkyRoom( prop, path )
		else
			local list = ( posed and prop.EntityProp ) and keptPosed or kept
			list[#list + 1] = placer.inBlock( prop, ( anim or ( posed and prop.EntityProp ) ) and nil or mins, maxs, path )
		end
		if index % 8 == 0 then coroutine.yield() end
	end

	if #keptPosed > 0 then addGroup( mini, { model = path, anim = 0, props = keptPosed } ) end
	if #kept == 0 and #skyKept == 0 then return end

	local meshesBySkin = {}
	local function placeGroups( list, sky )
		if #list == 0 then return end
		if anim or not bakeMeshes then
			addGroup( mini, { model = path, anim = anim, props = list, sky = sky } )
			return
		end
		-- Baked geometry carries its materials: SetSkin on the reusable entity
		-- cannot change it. Resolve each skin family when extracting the mesh.
		local bySkin = {}
		for _, prop in ipairs( list ) do
			bySkin[prop.skin] = bySkin[prop.skin] or {}
			table.insert( bySkin[prop.skin], prop )
		end
		for skin, propsForSkin in pairs( bySkin ) do
			if meshesBySkin[skin] == nil then meshesBySkin[skin] = PocketMap.PropMesh.Build( path, skin ) or false end
			addGroup( mini, { model = path, props = propsForSkin, meshes = meshesBySkin[skin] or nil, sky = sky } )
		end
	end
	placeGroups( kept, false )
	placeGroups( skyKept, true )
end

local function noteMissingModel( mini, path, count )
	mini.missingModels = mini.missingModels + count
	if #mini.missingNames < MISSING_NAMES_KEPT then mini.missingNames[#mini.missingNames + 1] = path end
end

---One model per step. A model that isn't installed is drawn as the error model, so it can be seen.
---@param lightToggle boolean
---@param bakeMeshes boolean # the "Baked Models" option
function Props.Place( mini, job, lightToggle, bakeMeshes )
	local bsp = job.bsp
	local hdr = mini.lighting == "HDR"
	mini.propPVSCluster, mini.propPVS, mini.propPVSBSP = nil, nil, nil
	mini.propPassGroups, mini.skyPassGroups = nil, nil
	mini.propOcclusion = nil

	mini:SetStatus( "Reading the ambient light", 0.645 )
	PocketMap.PropLight.Prepare( bsp, hdr )
	coroutine.yield()

	mini.propLightSampler = PocketMap.PropLight.New( mini, bsp, lightToggle )
	local placer = newPlacer( mini, job, mini.propLightSampler )
	local errorProps = {}
	local errorMins, errorMaxs = modelBounds( mini, "models/error.mdl" )

	for index, key in ipairs( job.models ) do
		local path, anim = key, nil
		if job.animOf[key] then path, anim = job.animOf[key][1], job.animOf[key][2] end
		mini:SetStatus( "Model " .. path, 0.65 + 0.33 * ( index - 1 ) / #job.models )

		local props = job.byModel[key]
		if file.Exists( path, "GAME" ) then
			util.PrecacheModel( path )
			placeModel( mini, placer, props, path, anim, bakeMeshes or PocketMap.PropMesh.IsStaticOnly( path ) )
		else
			for _, prop in ipairs( props ) do
				if not prop.Sky then errorProps[#errorProps + 1] = placer.inBlock( prop, errorMins, errorMaxs ) end
			end
			noteMissingModel( mini, path, #props )
		end

		job.byModel[key] = nil
		coroutine.yield()
	end

	if #errorProps > 0 then addGroup( mini, { model = "models/error.mdl", props = errorProps } ) end
	coroutine.yield()
end

-- Drawing -------------------------------------------------------------------------------------------------------------

local function setModelLight( state, light, transform )
	local rendered = PocketMap.PropLight.ForRender( light, transform )
	if state.direct ~= rendered.direct then
		render.SetLocalModelLights( rendered.direct )
		state.direct = rendered.direct
	end
	if rendered.uniform then
		local color, previous = rendered.uniform, state.uniform
		if not previous or previous[1] ~= color[1] or previous[2] ~= color[2] or previous[3] ~= color[3] then
			render.ResetModelLighting( color[1], color[2], color[3] )
		end
		state.light, state.uniform = rendered.cube, color
		return
	end
	state.uniform = nil
	light = rendered.cube
	if light == state.light then return end
	-- Many static props have separately allocated but identical ambient cubes.
	-- Avoid six render-state changes when the already bound colors match.
	local previous = state.light
	if previous then
		local same = true
		for side = 1, SIDES do
			local a, b = previous[side], light[side]
			if a[1] ~= b[1] or a[2] ~= b[2] or a[3] ~= b[3] then
				same = false
				break
			end
		end
		if same then state.light = light return end
	end

	state.light = light
	for side = 1, SIDES do
		local color = light[side]
		render.SetModelLighting( side - 1, color[1], color[2], color[3] )
	end
end

-- Moving entity models use the same BSP lighting as static and sky props.
Props.SetModelLight = setModelLight

local function drawParts( parts, translucent, state )
	for i = 1, #parts do
		local part = parts[i]
		if part.translucent == translucent then
			local material = state.depth and PocketMap.Flashlight.DepthMaterial( part.material ) or part.material
			if state.material ~= material then
				render.SetMaterial( material )
				state.material = material
			end
			part.mesh:Draw()
		end
	end
end

local function hasHalf( parts, translucent )
	if translucent then return parts.hasTranslucent end
	return parts.hasOpaque
end

---The model is posed by its animation (a bridge, a gate), not the reference pose. Models with translucent materials are drawn
---in both halves: the opaque parts first, the translucent submodels after.
---@return number? flags # nil: nothing of this model in this half
local function prepareEntityGroup( entity, group, translucent )
	entity:SetModel( group.model )

	if group.anim then
		local sequence = isnumber( group.anim ) and group.anim or entity:LookupSequence( group.anim )
		if sequence and sequence >= 0 then
			entity:ResetSequence( sequence )
			entity:SetCycle( 0 )
			entity:SetPlaybackRate( 0 )
		end
	end

	if hasTranslucentMaterial( group, entity ) then return translucent and DRAW_FLAGS or OPAQUE_FLAGS end
	if translucent then return nil end
	return DRAW_FLAGS
end

local function drawEntityProp( entity, state, group, scale, skin, pos, ang, flags )
	if scale ~= state.scale then
		entity:SetModelScale( scale, 0 )
		state.scale = scale
	end
	if skin ~= state.skin then
		entity:SetSkin( skin )
		state.skin = skin
	end

	entity:SetPos( pos )
	entity:SetAngles( ang )
	-- The same ClientsideModel is reused at multiple prop positions in one frame.
	-- Rebuild its bones after each move or Source draws later props at the first pose.
	entity:SetupBones()
	entity:DrawModel( flags )
end

---The props are placed in the world, not drawn under a model matrix: the engine decides if a model is on screen from its real
---position, so props left in map space would all be culled. A prop's world position only changes when the block moves.
local function updateStamp( mini )
	local pos, ang = mini.ent:GetPos(), mini.ent:GetAngles()
	if pos ~= mini.stampPos or ang ~= mini.stampAng then
		mini.stampPos, mini.stampAng = pos, ang
		mini.stamp = ( mini.stamp or 0 ) + 1
	end
	return mini.stamp, pos, ang
end

local function visibleInPVS( prop, pvs )
	if not pvs then return true end
	if prop.pvsCluster then return pvs[prop.pvsCluster] end
	local clusters = prop.pvsClusters
	if not clusters then return true end

	-- The same PVS is used every frame until the walker's view cluster changes.
	if prop.checkedPVS ~= pvs then
		prop.checkedPVS, prop.pvsVisible = pvs, false
		for i = 1, #clusters do
			if pvs[clusters[i]] then
				prop.pvsVisible = true
				break
			end
		end
	end
	return prop.pvsVisible
end

-- The prop geometry is static while walking a miniature. BSP visibility only
-- changes when the eye changes cluster, so keep the visible portion of each
-- model group and perform just the camera frustum test on subsequent frames.
local function pvsCandidates( group, pvs )
	local props = group.props
	if not pvs then return props, #props end
	if group.pvsSource == props and group.pvsData == pvs then
		return group.pvsProps, group.pvsCount
	end

	local candidates = group.pvsProps or {}
	local count = 0
	for i = 1, #props do
		local prop = props[i]
		if visibleInPVS( prop, pvs ) then
			count = count + 1
			candidates[count] = prop
		end
	end
	for i = count + 1, #candidates do candidates[i] = nil end
	group.pvsSource, group.pvsData = props, pvs
	group.pvsProps, group.pvsCount = candidates, count
	return candidates, count
end

-- Model groups are fixed after placement. Build pass-specific lists once per
-- PVS instead of visiting hidden or wrong-pass groups every render frame.
local function passGroups( mini, pvs )
	local groups = mini.propGroups
	local cached = mini.propPassGroups
	if cached and cached.source == groups and cached.count == #groups and cached.pvs == pvs then
		return cached
	end

	local opaque, translucent = {}, {}
	for i = 1, #groups do
		local group = groups[i]
		if not group.sky then
			local _, count = pvsCandidates( group, pvs )
			if count > 0 then
				local parts = group.meshes
				if not parts or parts.hasOpaque then opaque[#opaque + 1] = group end
				if parts and parts.hasTranslucent or not parts and group.entTranslucent ~= false then
					translucent[#translucent + 1] = group
				end
			end
		end
	end

	cached = { source = groups, count = #groups, pvs = pvs, opaque = opaque, translucent = translucent }
	mini.propPassGroups = cached
	return cached
end

-- Use the active render view: the player's actual eye may be outside the miniature.
-- Unknown projection modes fail open, including off-center and orthographic cameras.
local function viewFrustum( mini )
	local view = PocketMap.Visibility.View( mini, FRUSTUM_FOV_PAD )
	if view then
		view.boxClip = not PocketMap.Settings and cvWaterClipBounds:GetBool()
			or PocketMap.Settings and PocketMap.Settings.Compat( mini, "water_clip_bounds", cvWaterClipBounds )
	end
	return view
end

-- An opaque and translucent pass can share their visible props only when the
-- camera, PVS and block transform are unchanged. Nested/unknown views fail open.
local function sameCullView( context, stamp, pvs, frustum, mini )
	local cache = cvPropFrustumCache:GetBool()
	if PocketMap.Settings then cache = PocketMap.Settings.Compat( mini, "prop_frustum_cache", cvPropFrustumCache ) end
	if not context or not frustum or ( not cache and context.frame ~= FrameNumber() )
		or context.stamp ~= stamp or context.pvs ~= pvs then return false end
	local old = context.frustum
	local a, b = old.origin, frustum.origin
	local oldAngles, newAngles = old.angles, frustum.angles
	return a.x == b.x and a.y == b.y and a.z == b.z
		and oldAngles.p == newAngles.p and oldAngles.y == newAngles.y and oldAngles.r == newAngles.r
		and old.halfWidth == frustum.halfWidth and old.halfHeight == frustum.halfHeight
		and old.boxClip == frustum.boxClip
		and ( not old.clip and not frustum.clip or old.clip and frustum.clip
			and old.clip.normal == frustum.clip.normal and old.clip.distance == frustum.clip.distance )
end

local function visibleInFrustum( prop, frustum )
	if not frustum or not prop.lcenter or not prop.sphereRadius then return true end
	local center, origin = prop.lcenter, frustum.origin
	local dx, dy, dz = center.x - origin.x, center.y - origin.y, center.z - origin.z
	local forward, right, up = frustum.forward, frustum.right, frustum.up
	local depth = dx * forward.x + dy * forward.y + dz * forward.z
	local radius = prop.sphereRadius
	local clip = frustum.clip
	if clip then
		local extent, n = frustum.boxClip and prop.boxExtents, clip.normal
		local support = extent and ( math.abs( n.x ) * extent.x + math.abs( n.y ) * extent.y + math.abs( n.z ) * extent.z ) or radius
		if center:Dot( n ) + support < clip.distance then return false end
	end
	if depth + radius < 0 then return false end
	if math.abs( dx * right.x + dy * right.y + dz * right.z ) > depth * frustum.halfWidth + radius * frustum.widthRadius then return false end
	if math.abs( dx * up.x + dy * up.y + dz * up.z ) > depth * frustum.halfHeight + radius * frustum.heightRadius then return false end
	return true
end

-- Only a single opaque convex face can prove this enclosing box is hidden.
local function propBehindWorld( mini, prop, eye )
	if not prop.lcenter or not prop.sphereRadius then return false end
	local radius = prop.sphereRadius / mini.scale
	if radius <= 0 or radius > OCCLUSION_MAX_RADIUS then return false end
	local center = ( prop.lcenter - mini.boxCenter ) / mini.scale + mini.mapCenter
	local extent = Vector( radius + OCCLUSION_PAD, radius + OCCLUSION_PAD, radius + OCCLUSION_PAD )
	return PocketMap.Visibility.Occluded( mini.bsp, eye, center, PocketMap.Visibility.BoxCorners( center - extent, center + extent ) )
end

-- A moving eye invalidates its old occlusion results. The queue is populated
-- by props actually encountered in the frustum, and one is traced per frame.
-- Unknown views and BSPs without visibility information draw every prop.
local function propOcclusion( mini, pvs, frustum )
	if PocketMap.Water and PocketMap.Water.pass then return nil end
	local enabled = cvPropOcclusion:GetBool()
	if PocketMap.Settings then enabled = PocketMap.Settings.Compat( mini, "prop_occlusion", cvPropOcclusion ) end
	if not enabled or not pvs or not frustum or not mini.bsp.SurfaceTraceLine then return nil end
	local eye = ( frustum.origin - mini.boxCenter ) / mini.scale + mini.mapCenter
	local cache = mini.propOcclusion
	if not cache or cache.groups ~= mini.propGroups or cache.bsp ~= mini.bsp then
		cache = { groups = mini.propGroups, bsp = mini.bsp, generation = 0 }
		mini.propOcclusion = cache
	end
	if not cache.eye or cache.pvs ~= pvs or cache.eye ~= eye then
		cache.eye, cache.pvs = eye, pvs
		cache.generation = cache.generation + 1
		cache.queue, cache.nextIndex, cache.count = {}, 1, 0
		cache.nextAt = CurTime() + 0.2
	end
	return cache
end

local function propKnownHidden( prop, cache )
	if not cache or not prop.lcenter then return false end
	if prop.occlusionCache == cache and prop.occlusionGeneration == cache.generation then
		return prop.occludedByWorld
	end
	if prop.occlusionQueuedCache ~= cache or prop.occlusionQueuedGeneration ~= cache.generation then
		cache.count = cache.count + 1
		cache.queue[cache.count] = prop
		prop.occlusionQueuedCache, prop.occlusionQueuedGeneration = cache, cache.generation
	end
	return false
end

local function traceNextProp( mini, cache )
	if not cache or cache.frame == FrameNumber() or CurTime() < cache.nextAt then return end
	local index = cache.nextIndex
	if index > cache.count then return end
	cache.frame = FrameNumber()
	cache.nextIndex = index + 1
	local prop = cache.queue[index]
	cache.queue[index] = nil
	prop.occludedByWorld = propBehindWorld( mini, prop, cache.eye )
	prop.occlusionCache, prop.occlusionGeneration = cache, cache.generation
end

local function drawGroup( mini, group, translucent, entity, state, stamp, entPos, entAng, pvs, frustum, context, reuse, occlusion, shadowFlags )
	local parts = group.meshes
	if parts and not hasHalf( parts, translucent ) then return 0 end
	if not parts and translucent and group.entTranslucent == false then return 0 end

	local flags = DRAW_FLAGS
	local prepared = parts ~= nil

	local props = group.props
	local drawn = 0
	local cached = reuse and group.visibilityContext == context
	local candidates, count
	if cached then
		candidates, count = group.visibleProps, group.visibleCount
	else
		candidates, count = pvsCandidates( group, pvs )
	end
	local record = not translucent and context ~= nil
	local visible = record and ( group.visibleProps or {} )
	local visibleCount = 0

	for i = 1, count do
		local p = candidates[i]
		if cached or visibleInFrustum( p, frustum ) then
			if record then
				visibleCount = visibleCount + 1
				visible[visibleCount] = p
			end
			if not propKnownHidden( p, occlusion ) then
			-- Skip expensive model and material setup when the entire group is culled.
			if not prepared then
				flags = prepareEntityGroup( entity, group, translucent )
				if not flags then return 0 end
				flags = shadowFlags or flags
				state.scale, state.skin = nil, nil
				prepared = true
			end
			if p.stamp ~= stamp then
				p.wpos, p.wang = LocalToWorld( p.lpos, p.langles, entPos, entAng )
				p.stamp = stamp
			end

			drawn = drawn + 1
			if not shadowFlags then setModelLight( state, p.light, mini.propLightTransform ) end

			if parts then
				-- The block's transform is unchanged on most frames. Reuse each
				-- baked prop's matrix until the block moves instead of assembling
				-- it before every draw in both passes.
				if p.matrixStamp ~= stamp then
					local matrix = p.drawMatrix or Matrix()
					matrix:Identity()
					matrix:SetTranslation( p.wpos )
					matrix:SetAngles( p.wang )
					matrix:SetScale( Vector( p.lscale, p.lscale, p.lscale ) )
					p.drawMatrix, p.matrixStamp = matrix, stamp
				end

				cam.PushModelMatrix( p.drawMatrix )
				drawParts( parts, translucent, state )
				cam.PopModelMatrix()
			else
				drawEntityProp( entity, state, group, p.lscale, p.skin, p.wpos, p.wang, flags )
				state.material = nil
			end
			end
		end
	end
	if record then
		group.visibleProps, group.visibleCount, group.visibilityContext = visible, visibleCount, context
	end

	return drawn
end

local function drawPass( mini, translucent )
	if translucent and PocketMap.Settings and not PocketMap.Settings.Enabled( mini, "translucent_props" ) then return end
	if #mini.propGroups == 0 then return end

	local walk = PocketMap.Walk and PocketMap.Walk.session
	local frustum = viewFrustum( mini )
	local pvs = walk and walk.mini == mini and PocketMap.Visibility.PVS( mini, frustum ) or nil
	local groups = passGroups( mini, pvs )
	local occlusion = propOcclusion( mini, pvs, frustum )
	local selected = translucent and groups.translucent or groups.opaque
	if #selected == 0 then
		if not translucent then mini.propsDrawn = 0 end
		return
	end

	local entity = propEntity( mini )
	local stamp, entPos, entAng = updateStamp( mini )
	mini.propLightTransform = PocketMap.PropLight.Transform( mini.matrix, mini.propLightTransform )
	local state = {}
	local drawn = 0
	local context
	local reuse = sameCullView( mini.propCullContext, stamp, pvs, frustum, mini )
	if reuse then
		context = mini.propCullContext
		context.frame = FrameNumber()
	elseif not translucent then
		context = frustum and { frame = FrameNumber(), stamp = stamp, pvs = pvs, frustum = frustum } or nil
		mini.propCullContext = context
	end

	render.SuppressEngineLighting( true )
	if translucent then render.OverrideDepthEnable( true, false ) end

	for i = 1, #selected do
		drawn = drawn + drawGroup( mini, selected[i], translucent, entity, state, stamp, entPos, entAng, pvs, frustum, context, reuse, occlusion )
	end

	if translucent then render.OverrideDepthEnable( true, true ) end
	render.SetLocalModelLights()
	render.SetColorModulation( 1, 1, 1 )
	render.SuppressEngineLighting( false )
	traceNextProp( mini, occlusion )

	if not translucent then mini.propsDrawn = drawn end
end

---@param pass "opaque"|"translucent"|nil # nil draws both halves
function Props.Draw( mini, pass )
	if pass ~= "translucent" then drawPass( mini, false ) end
	if pass ~= "opaque" then drawPass( mini, true ) end
end

-- Use every opaque caster, independently of the viewer's visibility caches.
function Props.DrawDepth( mini, flags )
	if #mini.propGroups == 0 then return end
	local entity = propEntity( mini )
	local stamp, pos, ang = updateStamp( mini )
	local state = { depth = true }
	for _, group in ipairs( mini.propGroups ) do
		if not group.sky then
			drawGroup( mini, group, false, entity, state, stamp, pos, ang, nil, nil, nil, false, nil, flags )
		end
	end
end

-- The props of the 3D skybox room are drawn with the skybox: each is moved with the matrix of the sky room ------------

local function skyGroupWantsDrawing( group, translucent )
	if group.meshes then return hasHalf( group.meshes, translucent ) end
	return not translucent or group.entTranslucent ~= false
end

local function skyPassGroups( mini )
	local groups = mini.propGroups
	local cached = mini.skyPassGroups
	if cached and cached.source == groups and cached.count == #groups then return cached end

	local opaque, translucent = {}, {}
	for i = 1, #groups do
		local group = groups[i]
		if group.sky then
			if skyGroupWantsDrawing( group, false ) then opaque[#opaque + 1] = group end
			if skyGroupWantsDrawing( group, true ) then translucent[#translucent + 1] = group end
		end
	end
	cached = { source = groups, count = #groups, opaque = opaque, translucent = translucent }
	mini.skyPassGroups = cached
	return cached
end

local function skyPropMatrix( mini, skyMatrix, p )
	local matrix = mini.skyPropMatrix or Matrix()
	mini.skyPropMatrix = matrix

	matrix:Set( skyMatrix )
	matrix:Translate( p.origin )
	matrix:Rotate( p.angles )
	mini.propScaleVec:SetUnpacked( p.uscale, p.uscale, p.uscale )
	matrix:Scale( mini.propScaleVec )
	return matrix
end

local function drawSkyGroup( mini, group, translucent, skyMatrix, state )
	local parts = group.meshes
	local flags = DRAW_FLAGS
	local entity

	if parts then
		if not hasHalf( parts, translucent ) then return end
	else
		entity = propEntity( mini )
		flags = prepareEntityGroup( entity, group, translucent )
		if not flags then return end
		state.scale, state.skin = nil, nil
	end

	for _, p in ipairs( group.props ) do
		setModelLight( state, p.light, mini.skyLightTransform )
		local matrix = skyPropMatrix( mini, skyMatrix, p )

		if parts then
			cam.PushModelMatrix( matrix )
			drawParts( parts, translucent, state )
			cam.PopModelMatrix()
		else
			drawEntityProp( entity, state, group, matrix:GetScale().x, p.skin, matrix:GetTranslation(), matrix:GetAngles(), flags )
			state.material = nil
		end
	end
end

local function drawSkyPass( mini, skyMatrix, translucent )
	if PocketMap.Settings and ( not PocketMap.Settings.Enabled( mini, "sky_props" )
		or translucent and not PocketMap.Settings.Enabled( mini, "translucent_props" ) ) then return end
	local groups = skyPassGroups( mini )
	local selected = translucent and groups.translucent or groups.opaque
	if #selected == 0 then return end

	local state = {}
	mini.skyLightTransform = PocketMap.PropLight.Transform( skyMatrix, mini.skyLightTransform )
	if translucent then render.OverrideDepthEnable( true, false ) end
	render.SuppressEngineLighting( true )

	for i = 1, #selected do
		drawSkyGroup( mini, selected[i], translucent, skyMatrix, state )
	end

	if translucent then render.OverrideDepthEnable( true, true ) end
	render.SetLocalModelLights()
	render.SetColorModulation( 1, 1, 1 )
	render.SuppressEngineLighting( false )
end

---@param skyMatrix VMatrix # sky room -> world
---@param pass "opaque"|"translucent"|nil
function Props.DrawSky( mini, skyMatrix, pass )
	if pass ~= "translucent" then drawSkyPass( mini, skyMatrix, false ) end
	if pass ~= "opaque" then drawSkyPass( mini, skyMatrix, true ) end
end
