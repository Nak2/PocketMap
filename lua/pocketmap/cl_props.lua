-- Props: the static props of the map (bsp:GetStaticProps) and every entity with a .mdl model, grouped by model.
-- A group is drawn as baked meshes (cl_propmesh.lua) or, when that isn't possible, as a hidden clientside model.

if not PocketMap.Mini then return end

PocketMap.Props = {}
local Props = PocketMap.Props
local Entities = PocketMap.Entities

local STATIC_PROP_USE_LIGHTING_ORIGIN = 2
local RENDERMODE_DONT_RENDER = 10
local EF_NODRAW = 32
local MISSING_NAMES_KEPT = 8
local SIDES = 6

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

			job.addProp( prop.PropType, prop.Origin, prop.Angles, prop.Skin, prop.UniformScale, usesLightingOrigin and prop.LightingOrigin or nil, sky )
			countProp( mini, sky, "staticCount" )
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

		if model and not class:find( "^trigger_" ) then
			if isHiddenByMap( entity ) then
				mini.hiddenEntities = mini.hiddenEntities + 1
			else
				local sky = job.inSkyRoomAt( entity.origin )
				local lightName = Entities.First( entity.lightingorigin or entity.LightingOrigin )
				local lightOrigin = type( lightName ) == "string" and lightingOrigins[lightName:lower()] or nil
				local kind = class:find( "^prop_dynamic" ) and "dynamic" or true

				job.addProp( model, entity.origin, anglesOf( entity ), tonumber( entity.skin ) or 0, tonumber( entity.modelscale ), lightOrigin, sky, animOf( entity ), kind )
				countProp( mini, sky, "entityCount" )
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

---Props are placed relative to the block, so each frame only needs the block's transform.
local function newPlacer( mini, job, light )
	local scale = job.scale

	return {
		inBlock = function( prop )
			return {
				lpos = ( prop.Origin - mini.mapCenter ) * scale + mini.boxCenter,
				langles = prop.Angles,
				skin = prop.Skin or 0,
				lscale = ( prop.UniformScale or 1 ) * scale,
				light = light:Of( prop ),
			}
		end,

		---A prop of the sky room stays where it is in the sky room: it moves with the skybox.
		inSkyRoom = function( prop )
			return { origin = prop.Origin, angles = prop.Angles, skin = prop.Skin or 0, uscale = prop.UniformScale or 1, light = light:Of( prop ) }
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

	for _, prop in ipairs( props ) do
		if prop.Sky then
			skyKept[#skyKept + 1] = placer.inSkyRoom( prop )
		else
			local list = ( posed and prop.EntityProp ) and keptPosed or kept
			list[#list + 1] = placer.inBlock( prop )
		end
	end

	if #keptPosed > 0 then addGroup( mini, { model = path, anim = 0, props = keptPosed } ) end
	if #kept == 0 and #skyKept == 0 then return end

	local meshes = not anim and bakeMeshes and PocketMap.PropMesh.Build( path ) or nil
	if #kept > 0 then addGroup( mini, { model = path, anim = anim, props = kept, meshes = meshes } ) end
	if #skyKept > 0 then addGroup( mini, { model = path, anim = anim, props = skyKept, meshes = meshes, sky = true } ) end
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

	mini:SetStatus( "Reading the ambient light", 0.645 )
	PocketMap.PropLight.Prepare( bsp, hdr )
	coroutine.yield()

	local placer = newPlacer( mini, job, PocketMap.PropLight.New( mini, bsp, lightToggle ) )
	local errorProps = {}

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
				if not prop.Sky then errorProps[#errorProps + 1] = placer.inBlock( prop ) end
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

local function setModelLight( state, light )
	if light == state.light then return end

	state.light = light
	for side = 1, SIDES do
		local color = light[side]
		render.SetModelLighting( side - 1, color[1], color[2], color[3] )
	end
end

local function drawParts( parts, translucent )
	for i = 1, #parts do
		local part = parts[i]
		if part.translucent == translucent then
			render.SetMaterial( part.material )
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

local function drawGroup( mini, group, translucent, entity, state, stamp, entPos, entAng )
	local parts = group.meshes
	if parts and not hasHalf( parts, translucent ) then return 0 end
	if not parts and translucent and group.entTranslucent == false then return 0 end

	local flags = DRAW_FLAGS
	if not parts then
		flags = prepareEntityGroup( entity, group, translucent )
		if not flags then return 0 end
		state.scale, state.skin = nil, nil
	end

	local matrix, scaleVec = mini.propMatrix, mini.propScaleVec
	local props = group.props

	for i = 1, #props do
		local p = props[i]
		if p.stamp ~= stamp then
			p.wpos, p.wang = LocalToWorld( p.lpos, p.langles, entPos, entAng )
			p.stamp = stamp
		end

		setModelLight( state, p.light )

		if parts then
			scaleVec:SetUnpacked( p.lscale, p.lscale, p.lscale )
			matrix:Identity()
			matrix:SetTranslation( p.wpos )
			matrix:SetAngles( p.wang )
			matrix:SetScale( scaleVec )

			cam.PushModelMatrix( matrix )
			drawParts( parts, translucent )
			cam.PopModelMatrix()
		else
			drawEntityProp( entity, state, group, p.lscale, p.skin, p.wpos, p.wang, flags )
		end
	end

	return #props
end

local function drawPass( mini, translucent )
	if #mini.propGroups == 0 then return end

	local entity = propEntity( mini )
	local stamp, entPos, entAng = updateStamp( mini )
	local state = {}
	local drawn = 0

	render.SuppressEngineLighting( true )
	if translucent then render.OverrideDepthEnable( true, false ) end

	for _, group in ipairs( mini.propGroups ) do
		if not group.sky then drawn = drawn + drawGroup( mini, group, translucent, entity, state, stamp, entPos, entAng ) end
	end

	if translucent then render.OverrideDepthEnable( true, true ) end
	render.SetColorModulation( 1, 1, 1 )
	render.SuppressEngineLighting( false )

	if not translucent then mini.propsDrawn = drawn end
end

---@param pass "opaque"|"translucent"|nil # nil draws both halves
function Props.Draw( mini, pass )
	if pass ~= "translucent" then drawPass( mini, false ) end
	if pass ~= "opaque" then drawPass( mini, true ) end
end

-- The props of the 3D skybox room are drawn with the skybox: each is moved with the matrix of the sky room ------------

local function skyGroupWantsDrawing( group, translucent )
	if group.meshes then return hasHalf( group.meshes, translucent ) end
	return not translucent or group.entTranslucent ~= false
end

local function anySkyGroupWantsDrawing( groups, translucent )
	for _, group in ipairs( groups ) do
		if group.sky and skyGroupWantsDrawing( group, translucent ) then return true end
	end
	return false
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
		setModelLight( state, p.light )
		local matrix = skyPropMatrix( mini, skyMatrix, p )

		if parts then
			cam.PushModelMatrix( matrix )
			drawParts( parts, translucent )
			cam.PopModelMatrix()
		else
			drawEntityProp( entity, state, group, matrix:GetScale().x, p.skin, matrix:GetTranslation(), matrix:GetAngles(), flags )
		end
	end
end

local function drawSkyPass( mini, skyMatrix, translucent )
	if not anySkyGroupWantsDrawing( mini.propGroups, translucent ) then return end

	local state = {}
	if translucent then render.OverrideDepthEnable( true, false ) end
	render.SuppressEngineLighting( true )

	for _, group in ipairs( mini.propGroups ) do
		if group.sky then drawSkyGroup( mini, group, translucent, skyMatrix, state ) end
	end

	if translucent then render.OverrideDepthEnable( true, true ) end
	render.SetColorModulation( 1, 1, 1 )
	render.SuppressEngineLighting( false )
end

---@param skyMatrix VMatrix # sky room -> world
---@param pass "opaque"|"translucent"|nil
function Props.DrawSky( mini, skyMatrix, pass )
	if pass ~= "translucent" then drawSkyPass( mini, skyMatrix, false ) end
	if pass ~= "opaque" then drawSkyPass( mini, skyMatrix, true ) end
end
