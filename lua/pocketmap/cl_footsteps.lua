-- The footsteps of a walk (cl_walk.lua), made the way the engine does: CBasePlayer::UpdateStepSound and PlayStepSound
-- (game/shared/baseplayer_shared.cpp) for when and how loud, CGameMovement::CheckFalling for a landing and CheckJumpButton for a jump.
-- What is heard comes from the surface under the feet: the texture of the face has a material, the material a $surfaceprop,
-- and the surface property the names of its step sounds.

PocketMap.Footsteps = {}
local Footsteps = PocketMap.Footsteps

local STAND_MINS, STAND_MAXS = Vector( -16, -16, 0 ), Vector( 16, 16, 72 )
local DUCK_MAXS = Vector( 16, 16, 36 )
local GROUND_PROBE = 2
local WALKABLE_NORMAL = 0.7
local SOUND_LEVEL = 75

-- shareddefs.h, HL2_DLL
local MAX_SAFE_FALL_SPEED = 526.5
local FALL_PUNCH_THRESHOLD = 303

local MAT_DIRT_L, MAT_VENT_L = MAT_DIRT or 68, MAT_VENT or 86

-- Texture name -> surface data, or false when the engine has nothing for it
local surfaces = {}

---@return table? surface
local function surfaceOfTexinfo( bsp, index )
	local texinfo = index and bsp:GetTexInfo()[index]
	local texdata = texinfo and bsp:GetTexData()[texinfo.texdata]
	local name = texdata and texdata.nameStringTableID
	if not name then return end

	local surface = surfaces[name]
	if surface == nil then
		local material = PocketMap.Materials.Load( name )
		local property = material and not material:IsError() and material:GetString( "$surfaceprop" ) or "default"

		local found = util.GetSurfaceIndex( property )
		if found < 0 then found = util.GetSurfaceIndex( "default" ) end
		surface = util.GetSurfaceData( found ) or false
		surfaces[name] = surface
	end

	return surface or nil
end

local function namedSurface( name )
	return util.GetSurfaceData( util.GetSurfaceIndex( name ) )
end

-- A static prop says what it is made of (the surfaceprop in its .phy file); anything else has a texture
local named = {}

---@return table? surface
local function surfaceOfHit( bsp, texinfo, name )
	if not name then return surfaceOfTexinfo( bsp, texinfo ) end

	local surface = named[name]
	if surface == nil then
		surface = namedSurface( name ) or false
		named[name] = surface
	end
	return surface or nil
end

---How loud a step is for the material of the surface, walking or running (UpdateStepSound).
local function stepVolume( material, walking )
	if material == MAT_DIRT_L then return walking and 0.25 or 0.55 end
	if material == MAT_VENT_L then return walking and 0.4 or 0.7 end
	return walking and 0.2 or 0.5
end

---Left, right, left ... CBasePlayer::PlayStepSound. A surface without a name for that foot is silent and doesn't switch feet.
local function playStep( session, state, surface, volume )
	if not surface then return end

	local name = state.left and surface.stepLeftSound or surface.stepRightSound
	if not name or name == "" then return end
	state.left = not state.left

	local mini = session.mini
	local position = mini.ent:LocalToWorld( ( session.move.origin - mini.mapCenter ) * mini.scale + mini.boxCenter )
	sound.Play( name, position, SOUND_LEVEL, 100, volume )
end

---Once for every movement command, after the movement of it. UpdateStepSound counts down in the time of a tick.
---The water level and the ducking come from the walk (movement.lua sets them before every move).
---@param session table # PocketMap.Walk's session
---@param dt number # seconds
function Footsteps.Update( session, dt )
	local mv = session.move
	local state = session.steps
	if not state then
		state = { time = 0, left = false, wasOnGround = false, fall = 0, skip = 0, trace = {} }
		session.steps = state
	end

	if session.noclip then
		state.wasOnGround, state.fall = false, 0
		return
	end

	local origin, velocity = mv.origin, mv.velocity
	local ducking = session.ducking == true
	local level = session.waterLevel or 0

	-- Is there ground under the feet, and what is it?
	local trace = session:TraceHull( origin, { x = origin.x, y = origin.y, z = origin.z - GROUND_PROBE }, STAND_MINS, ducking and DUCK_MAXS or STAND_MAXS, MASK_PLAYERSOLID, state.trace )
	local onGround = trace.Hit and not trace.StartSolid and trace.HitNormal.z >= WALKABLE_NORMAL
	local ground = onGround and surfaceOfHit( session.bsp, trace.Texinfo, trace.SurfaceName ) or nil

	-- m_flFallVelocity: how fast the last moment in the air was going down
	if not onGround then state.fall = -velocity.z end

	local landed = onGround and not state.wasOnGround and state.fall > 0
	local jumped = state.wasOnGround and not onGround and velocity.z > 0 and bit.band( mv.buttons, IN_JUMP ) ~= 0
	local fall = state.fall
	state.wasOnGround = onGround
	if landed then state.fall = 0 end

	-- CheckFalling: a landing from a high enough fall makes a step sound that cannot be missed
	if landed and fall >= FALL_PUNCH_THRESHOLD then
		local volume = 0.5
		if level == 0 then volume = fall > MAX_SAFE_FALL_SPEED and 1 or 0.85 end

		state.time = 400
		playStep( session, state, ground, volume )
		return
	end

	-- CheckJumpButton: the sound of the surface that was left
	if jumped then
		playStep( session, state, surfaceOfHit( session.bsp, state.groundTexinfo, state.groundName ), 1 )
	end
	if onGround then state.groundTexinfo, state.groundName = trace.Texinfo, trace.SurfaceName end

	-- UpdateStepSound
	if state.time > 0 then state.time = math.max( 0, state.time - 1000 * dt ) end
	if state.time > 0 then return end

	local speed = velocity:Length()
	local groundSpeed = math.sqrt( velocity.x * velocity.x + velocity.y * velocity.y )
	local walkSpeed, runSpeed = 90, 220
	if ducking then walkSpeed, runSpeed = 60, 80 end

	if speed < walkSpeed or not ( onGround and groundSpeed > 0.0001 ) then return end

	local walking = speed < runSpeed
	local surface, volume
	local time = walking and 400 or 300

	if level == 2 then
		-- Wading: only every fourth step is heard
		if state.skip == 0 then
			state.skip = 1
			return
		end
		state.skip = state.skip == 3 and 0 or state.skip + 1

		surface, volume, time = namedSurface( "wade" ), 0.65, 600
	elseif level == 1 then
		surface, volume = namedSurface( "water" ), walking and 0.2 or 0.5
	else
		if not ground then return end
		surface, volume = ground, stepVolume( ground.material, walking )
	end

	state.time = ducking and time + 100 or time
	if ducking then volume = volume * 0.65 end

	playStep( session, state, surface, volume )
end
