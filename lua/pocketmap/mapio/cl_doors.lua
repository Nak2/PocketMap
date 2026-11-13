-- Door motion belongs to the walking session; meshes retain the authored BSP pose.
local IO = PocketMap.MapIO
local DOORS = { "func_door", "func_door_rotating", "prop_door_rotating" }
local START_OPEN, PASSABLE, NO_AUTO_RETURN = 1, 12, 32
local USE_ACTIVATES, TOUCH_ACTIVATES, START_LOCKED = 256, 1024, 2048
local IGNORE_USE = 32768

local function updatePose( state, record, door )
	local current = IO.State( state, record )
	if door.rotating then
		current.angles = record.angles + door.axis * ( door.position * door.distance )
	else
		current.origin = record.origin + door.direction * ( door.position * door.distance )
	end
	IO.PoseChanged( state, record )
end

local function initialize( state, record, current )
	local flags = IO.Number( record.entity, "spawnflags", 0 )
	local prop = record.class == "prop_door_rotating"
	local rotating = record.class ~= "func_door"
	local direction = IO.Direction( record )
	local spawn = IO.Number( record.entity, "spawnpos", 0 )
	local opened = spawn ~= 0 or not prop and bit.band( flags, START_OPEN ) ~= 0
	local door = {
		position = opened and 1 or 0, goal = opened and 1 or 0,
		rotating = rotating, direction = direction,
		axis = prop and Angle( 0, spawn == 2 and -1 or 1, 0 ) or IO.AngularDirection( record ),
		distance = rotating and IO.Number( record.entity, "distance", 90 )
			or math.max( 0, IO.Travel( record, direction ) - IO.Number( record.entity, "lip", 8 ) ),
		speed = math.max( 1, IO.Number( record.entity, "speed", 100 ) ),
		wait = IO.Number( record.entity, prop and "returndelay" or "wait", prop and -1 or 4 ),
		toggle = not prop and bit.band( flags, NO_AUTO_RETURN ) ~= 0,
		locked = IO.Number( record.entity, "locked", 0 ) == 1 or not prop and bit.band( flags, START_LOCKED ) ~= 0,
		touchActivates = not prop and bit.band( flags, TOUCH_ACTIVATES ) ~= 0,
	}
	current.door = door
	if opened then updatePose( state, record, door ) end
end

local function setup( state, record )
	local current = IO.State( state, record )
	if not current.door or not current.door.axis then
		local previous = current.door
		initialize( state, record, current )
		if previous then
			for _, key in ipairs( { "position", "goal", "moving", "closeAt", "activator", "locked" } ) do
				if previous[key] ~= nil then current.door[key] = previous[key] end
			end
			updatePose( state, record, current.door )
		end
	end
	return current.door
end

local function setGoal( state, record, goal, activator )
	if not IO.Enabled( state, record ) then return end
	local door = setup( state, record )
	if door.position == goal or door.moving and door.goal == goal then return end
	door.goal, door.moving, door.closeAt, door.activator = goal, true, nil, activator
	IO.Fire( state, record, goal == 1 and "OnOpen" or "OnClose", activator, record )
end

local function canUse( state, record )
	local flags = IO.Number( record.entity, "spawnflags", 0 )
	return bit.band( flags, IGNORE_USE ) == 0
		and ( record.class == "prop_door_rotating" or bit.band( flags, USE_ACTIVATES ) ~= 0 )
end

local function toggle( state, record, _, activator )
	setGoal( state, record, setup( state, record ).goal == 1 and 0 or 1, activator )
end

for _, class in ipairs( DOORS ) do
	IO.Register( class, {
		initialize = initialize,
		solid = function( _, record )
			return record.class == "prop_door_rotating" or bit.band( IO.Number( record.entity, "spawnflags", 0 ), PASSABLE ) == 0
		end,
		canUse = canUse,
		use = function( state, record, value, activator )
			if not canUse( state, record ) then return end
			if setup( state, record ).locked then IO.Fire( state, record, "OnLockedUse", activator, record ) return end
			toggle( state, record, value, activator )
		end,
		open = function( state, record, _, activator ) setGoal( state, record, 1, activator ) end,
		close = function( state, record, _, activator ) setGoal( state, record, 0, activator ) end,
		toggle = toggle,
		lock = function( state, record ) setup( state, record ).locked = true end,
		unlock = function( state, record ) setup( state, record ).locked = false end,
		setspeed = function( state, record, value )
			local speed = tonumber( value )
			if speed then setup( state, record ).speed = math.max( 0, speed ) end
		end,
		setposition = function( state, record, value )
			local amount = tonumber( value )
			if not amount then return end
			local door = setup( state, record )
			door.position, door.goal, door.moving = math.Clamp( amount, 0, 1 ), math.Clamp( amount, 0, 1 ), false
			updatePose( state, record, door )
		end,
	} )
	if class ~= "prop_door_rotating" then IO.DynamicClass( class ) end
end

IO.OnStep( "Doors", function( session, state, dt )
	local mins, maxs = IO.PlayerHull( session )
	for _, class in ipairs( DOORS ) do
		for _, record in ipairs( IO.OfClass( state.world, class ) ) do
			local door = setup( state, record )
			if door.moving then
				local delta = dt * door.speed / math.max( math.abs( door.distance ), 0.01 )
				door.position = math.Approach( door.position, door.goal, delta )
				updatePose( state, record, door )
				if door.position == door.goal then
					door.moving = false
					IO.Fire( state, record, door.goal == 1 and "OnFullyOpen" or "OnFullyClosed", door.activator, record )
					if door.goal == 1 and door.wait >= 0 and not door.toggle then door.closeAt = state.time + door.wait end
				end
			elseif door.closeAt and state.time >= door.closeAt then
				setGoal( state, record, 0, door.activator )
			end
			if door.touchActivates and not door.locked and not door.moving and door.goal == 0 then
				local touching = not session.noclip and IO.Overlaps( session, record, mins, maxs )
				if touching and not door.touching then setGoal( state, record, 1, state.activator ) end
				door.touching = touching
			end
		end
	end
end )
