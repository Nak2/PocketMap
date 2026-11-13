-- Push buttons share the session's poses, collision and Hammer output queue.
local IO = PocketMap.MapIO
local BUTTONS = { "func_button", "func_rot_button", "momentary_rot_button" }
local DONT_MOVE, TOGGLE, TOUCH_ACTIVATES, USE_ACTIVATES, START_LOCKED = 1, 32, 256, 1024, 2048

local function pose( state, record, button )
	local current = IO.State( state, record )
	if button.rotating then
		current.angles = button.closed + button.axis * ( button.position * button.distance )
	else
		current.origin = record.origin + button.direction * ( button.position * button.distance )
	end
	IO.PoseChanged( state, record )
end

local function initialize( state, record, current )
	local direction = IO.Direction( record )
	local rotating = record.class ~= "func_button"
	local momentary = record.class == "momentary_rot_button"
	local flags = IO.Number( record.entity, "spawnflags", 0 )
	local initial = momentary and math.Clamp( IO.Number( record.entity, "StartPosition", 0 ), 0, 1 ) or 0
	local distance = rotating and IO.Number( record.entity, "distance", 90 )
		or math.max( 0, IO.Travel( record, direction ) - IO.Number( record.entity, "lip", 4 ) )
	if not rotating and bit.band( flags, DONT_MOVE ) ~= 0 then distance = 0 end
	local axis = IO.AngularDirection( record )
	local button = {
		position = initial, goal = initial, direction = direction, rotating = rotating,
		axis = axis, closed = record.angles - axis * ( initial * distance ), distance = distance,
		speed = math.max( 1, IO.Number( record.entity, "speed", 40 ) ),
		wait = IO.Number( record.entity, "wait", 1 ), toggle = bit.band( flags, TOGGLE ) ~= 0,
		locked = bit.band( flags, START_LOCKED ) ~= 0 or IO.Number( record.entity, "locked", 0 ) == 1,
		touchActivates = bit.band( flags, TOUCH_ACTIVATES ) ~= 0,
		useActivates = momentary or bit.band( flags, USE_ACTIVATES ) ~= 0,
	}
	current.button = button
end

local function setup( state, record )
	local current = IO.State( state, record )
	if not current.button or not current.button.closed then
		local previous = current.button
		initialize( state, record, current )
		if previous then
			for _, key in ipairs( { "position", "goal", "returnAt", "activator", "locked" } ) do
				if previous[key] ~= nil then current.button[key] = previous[key] end
			end
			pose( state, record, current.button )
		end
	end
	return current.button
end

local function press( state, record, _, activator )
	local button = setup( state, record )
	if not IO.Enabled( state, record ) then return end
	if button.locked then IO.Fire( state, record, "OnUseLocked", activator, record ) return end
	if button.position ~= button.goal then return end
	if button.position == 1 and not button.toggle then return end
	button.goal, button.returnAt, button.activator = button.position == 1 and 0 or 1, nil, activator
	if button.goal == 1 then IO.Fire( state, record, "OnPressed", activator, record ) end
end

for _, class in ipairs( BUTTONS ) do
	IO.DynamicClass( class )
	IO.Register( class, {
		initialize = initialize,
		solid = function( _, record )
			return record.class == "func_button" or bit.band( IO.Number( record.entity, "spawnflags", 0 ), DONT_MOVE ) == 0
		end,
		canUse = function( state, record ) return setup( state, record ).useActivates end,
		use = function( state, record, value, activator )
			if setup( state, record ).useActivates then press( state, record, value, activator ) end
		end,
		press = press,
		lock = function( state, record ) setup( state, record ).locked = true end,
		unlock = function( state, record ) setup( state, record ).locked = false end,
		setposition = function( state, record, value )
			local fraction = tonumber( value )
			if not fraction then return end
			local button = setup( state, record )
			button.position, button.goal = math.Clamp( fraction, 0, 1 ), math.Clamp( fraction, 0, 1 )
			pose( state, record, button )
		end,
	} )
end

IO.OnStep( "Buttons", function( session, state, dt )
	local mins, maxs = IO.PlayerHull( session )
	for _, class in ipairs( BUTTONS ) do
		for _, record in ipairs( IO.OfClass( state.world, class ) ) do
			local button = setup( state, record )
			if button.position ~= button.goal then
				local step = dt * button.speed / math.max( math.abs( button.distance ), 0.01 )
				button.position = math.Approach( button.position, button.goal, step )
				pose( state, record, button )
				if button.position == button.goal then
					IO.Fire( state, record, button.goal == 1 and "OnIn" or "OnOut", button.activator, record )
					if button.goal == 1 and button.wait >= 0 and not button.toggle then button.returnAt = state.time + button.wait end
				end
			elseif button.returnAt and state.time >= button.returnAt then
				button.goal, button.returnAt = 0, nil
			end
			if button.touchActivates then
				local touching = not session.noclip and IO.Overlaps( session, record, mins, maxs )
				if touching and not button.touching then press( state, record, nil, state.activator ) end
				button.touching = touching
			end
		end
	end
end )
