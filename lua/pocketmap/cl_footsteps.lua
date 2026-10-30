PocketMap.Footsteps = {}
local Footsteps = PocketMap.Footsteps

local STAND_MINS, STAND_MAXS, DUCK_MAXS = Vector( -16, -16, 0 ), Vector( 16, 16, 72 ), Vector( 16, 16, 36 )
local GROUND_PROBE = 2
local WALKABLE_NORMAL = 0.7
local SOUND_LEVEL = 75
local MAX_SAFE_FALL_SPEED = 526.5
local FALL_PUNCH_THRESHOLD = 303
local LANDING_DELAY = 400
local WALK_SPEED, RUN_SPEED = 90, 220
local DUCK_WALK_SPEED, DUCK_RUN_SPEED = 60, 80
local DUCK_VOLUME = 0.65
local DUCK_DELAY = 100
local WADE_DELAY = 600
local WADE_VOLUME = 0.65
local WADE_STEPS_PER_SOUND = 4
local LADDER_VOLUME = 0.5
local LADDER_DELAY = 350
local WATER_FEET, WATER_WAIST = 1, 2

local MATERIAL_DIRT, MATERIAL_VENT = MAT_DIRT or 68, MAT_VENT or 86

local surfacesByTexture, surfacesByName = {}, {}

local function surfaceNamed( name )
	local surface = surfacesByName[name]
	if surface == nil then
		surface = util.GetSurfaceData( util.GetSurfaceIndex( name ) ) or false
		surfacesByName[name] = surface
	end
	return surface or nil
end

local function surfacePropertyOf( textureName )
	local material = PocketMap.Materials.Load( textureName )
	return not material:IsError() and material:GetString( "$surfaceprop" ) or "default"
end

local function loadTextureSurface( textureName )
	local index = util.GetSurfaceIndex( surfacePropertyOf( textureName ) )
	if index < 0 then index = util.GetSurfaceIndex( "default" ) end
	return util.GetSurfaceData( index ) or false
end

local function textureNameOf( bsp, texinfoIndex )
	local texinfo = texinfoIndex and bsp:GetTexInfo()[texinfoIndex]
	local texdata = texinfo and bsp:GetTexData()[texinfo.texdata]
	return texdata and texdata.nameStringTableID
end

local function surfaceOfTexture( bsp, texinfoIndex )
	local textureName = textureNameOf( bsp, texinfoIndex )
	if not textureName then return end

	local surface = surfacesByTexture[textureName]
	if surface == nil then
		surface = loadTextureSurface( textureName )
		surfacesByTexture[textureName] = surface
	end
	return surface or nil
end

local function surfaceOfHit( bsp, texinfo, surfaceName )
	if surfaceName then return surfaceNamed( surfaceName ) end
	return surfaceOfTexture( bsp, texinfo )
end

local function stepVolume( material, walking )
	if material == MATERIAL_DIRT then return walking and 0.25 or 0.55 end
	if material == MATERIAL_VENT then return walking and 0.4 or 0.7 end
	return walking and 0.2 or 0.5
end

local function landingVolume( fall, waterLevel )
	if waterLevel > 0 then return 0.5 end
	return fall > MAX_SAFE_FALL_SPEED and 1 or 0.85
end

local function speedLimits( ducking )
	if ducking then return DUCK_WALK_SPEED, DUCK_RUN_SPEED end
	return WALK_SPEED, RUN_SPEED
end

local function feetWorldPosition( session )
	local mini = session.mini
	return mini.ent:LocalToWorld( ( session.move.origin - mini.mapCenter ) * mini.scale + mini.boxCenter )
end

local function playStep( session, state, surface, volume )
	if not surface then return end

	local name = state.left and surface.stepLeftSound or surface.stepRightSound
	if not name or name == "" then return end

	state.left = not state.left
	sound.Play( name, feetWorldPosition( session ), SOUND_LEVEL, 100, volume )
end

local function newState()
	return { time = 0, left = false, wasOnGround = false, fall = 0, wadeSteps = 0, trace = {}, probeEnd = {} }
end

local function probeGround( session, state, ducking )
	local origin, probeEnd = session.move.origin, state.probeEnd
	probeEnd.x, probeEnd.y, probeEnd.z = origin.x, origin.y, origin.z - GROUND_PROBE

	local trace = session:TraceHull( origin, probeEnd, STAND_MINS, ducking and DUCK_MAXS or STAND_MAXS, MASK_PLAYERSOLID, state.trace )
	return trace.Hit and not trace.StartSolid and trace.HitNormal.z >= WALKABLE_NORMAL, trace
end

local function isWadeStepSilent( state )
	if state.wadeSteps == 0 then
		state.wadeSteps = 1
		return true
	end

	state.wadeSteps = state.wadeSteps == WADE_STEPS_PER_SOUND - 1 and 0 or state.wadeSteps + 1
	return false
end

local function stepFor( state, waterLevel, walking, ground, onLadder )
	if onLadder then return surfaceNamed( "ladder" ), LADDER_VOLUME, LADDER_DELAY end

	if waterLevel == WATER_WAIST then
		if isWadeStepSilent( state ) then return end
		return surfaceNamed( "wade" ), WADE_VOLUME, WADE_DELAY
	end

	local delay = walking and 400 or 300
	if waterLevel == WATER_FEET then return surfaceNamed( "water" ), walking and 0.2 or 0.5, delay end
	if not ground then return end
	return ground, stepVolume( ground.material, walking ), delay
end

local function playLandingIfHard( session, state, ground, fall, waterLevel )
	if fall < FALL_PUNCH_THRESHOLD then return false end

	state.time = LANDING_DELAY
	playStep( session, state, ground, landingVolume( fall, waterLevel ) )
	return true
end

local function playJump( session, state )
	playStep( session, state, surfaceOfHit( session.bsp, state.groundTexinfo, state.groundName ), 1 )
end

local function countDown( state, dt )
	if state.time > 0 then state.time = math.max( 0, state.time - 1000 * dt ) end
	return state.time <= 0
end

local function playMovementStep( session, state, ground, onGround, ducking, waterLevel, onLadder )
	local velocity = session.move.velocity
	local speed = velocity:Length()
	local groundSpeed = math.sqrt( velocity.x * velocity.x + velocity.y * velocity.y )
	local slowed = ducking or onLadder
	local walkSpeed, runSpeed = speedLimits( slowed )
	local movingAlongGround = onGround and groundSpeed > 0.0001
	if speed < walkSpeed or not ( onLadder or movingAlongGround ) then return end

	local surface, volume, delay = stepFor( state, waterLevel, speed < runSpeed, ground, onLadder )
	if not surface then return end

	state.time = slowed and delay + DUCK_DELAY or delay
	playStep( session, state, surface, ducking and volume * DUCK_VOLUME or volume )
end

function Footsteps.Update( session, dt )
	local state = session.steps
	if not state then
		state = newState()
		session.steps = state
	end

	if session.noclip then
		state.wasOnGround, state.fall = false, 0
		return
	end

	local mv = session.move
	local ducking, waterLevel = session.ducking == true, session.waterLevel or 0
	local onGround, trace = probeGround( session, state, ducking )
	local ground = onGround and surfaceOfHit( session.bsp, trace.Texinfo, trace.SurfaceName ) or nil

	if not onGround then state.fall = -mv.velocity.z end

	local landed = onGround and not state.wasOnGround and state.fall > 0
	local jumped = state.wasOnGround and not onGround and mv.velocity.z > 0 and bit.band( mv.buttons, IN_JUMP ) ~= 0
	local fall = state.fall
	state.wasOnGround = onGround
	if landed then state.fall = 0 end

	if landed and playLandingIfHard( session, state, ground, fall, waterLevel ) then return end

	if jumped then playJump( session, state ) end
	if onGround then state.groundTexinfo, state.groundName = trace.Texinfo, trace.SurfaceName end

	if countDown( state, dt ) then playMovementStep( session, state, ground, onGround, ducking, waterLevel, session.onladder == true ) end
end
