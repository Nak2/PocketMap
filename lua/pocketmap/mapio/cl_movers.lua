-- Linear movers and trains follow Hammer paths in source-map coordinates.
local IO = PocketMap.MapIO
local MOVERS = { "func_movelinear", "func_tracktrain", "func_train" }
local NOT_SOLID = 8
local MAX_PATH_NODES_PER_STEP = 64

local function path( world, name )
	if type( name ) ~= "string" then return nil end
	for _, record in ipairs( world.names[name:lower()] or {} ) do
		if record.class == "path_track" or record.class == "path_corner" then return record end
	end
end

local function previousPaths( world )
	if world.previousPaths then return world.previousPaths end
	local previous = {}
	for _, record in ipairs( world.entities ) do
		if record.class == "path_track" or record.class == "path_corner" then
			local nextPath = path( world, IO.Value( record.entity, "target" ) )
			if nextPath and not previous[nextPath] then previous[nextPath] = record end
		end
	end
	world.previousPaths = previous
	return previous
end

local function initialize( state, record, current )
	local linear = record.class == "func_movelinear"
	local initial = linear and math.Clamp( IO.Number( record.entity, "StartPosition", 0 ), 0, 1 ) or 0
	local distance = IO.Number( record.entity, "movedistance", 100 )
	local direction = IO.Direction( record )
	current.mover = {
		linear = linear, speed = math.abs( IO.Number( record.entity, "speed", linear and 100 or 64 ) ),
		active = not linear and IO.Number( record.entity, "speed", 0 ) > 0,
		goal = initial, position = initial, direction = direction, distance = distance,
		-- Source treats the authored origin as StartPosition, rather than as the closed endpoint.
		closed = record.origin - direction * ( distance * initial ),
		path = not linear and path( state.world, IO.Value( record.entity, "target" ) ) or nil,
		forward = true,
	}
end

local function setup( state, record )
	local current = IO.State( state, record )
	if not current.mover or not current.mover.closed then
		local previous = current.mover
		initialize( state, record, current )
		if previous then
			for _, key in ipairs( { "position", "goal", "active", "speed", "path", "activator" } ) do
				if previous[key] ~= nil then current.mover[key] = previous[key] end
			end
		end
	end
	return current.mover
end

local function setGoal( state, record, goal, activator )
	if not IO.Enabled( state, record ) then return end
	local mover = setup( state, record )
	if not mover.linear then return end
	mover.goal, mover.active, mover.activator = goal, true, activator
end

local function setDirection( state, record, forward )
	local mover = setup( state, record )
	if mover.linear then mover.goal = forward and 1 or 0
	elseif mover.forward ~= forward then
		-- Reversing between nodes must return along the current segment.
		if mover.from then mover.path, mover.from = mover.from, mover.path
		elseif mover.path then mover.path = previousPaths( state.world )[mover.path] end
	end
	mover.forward, mover.active = forward, true
end

for _, class in ipairs( MOVERS ) do
	IO.DynamicClass( class )
	IO.Register( class, {
		initialize = initialize,
		solid = function( _, record ) return bit.band( IO.Number( record.entity, "spawnflags", 0 ), NOT_SOLID ) == 0 end,
		open = function( state, record, _, activator ) setGoal( state, record, 1, activator ) end,
		close = function( state, record, _, activator ) setGoal( state, record, 0, activator ) end,
		toggle = function( state, record, _, activator )
			local mover = setup( state, record )
			if mover.linear then setGoal( state, record, mover.goal == 1 and 0 or 1, activator )
			else mover.active = not mover.active end
		end,
		setposition = function( state, record, value, activator )
			local fraction = tonumber( value )
			if fraction then setGoal( state, record, math.Clamp( fraction, 0, 1 ), activator ) end
		end,
		setspeed = function( state, record, value )
			local speed = tonumber( value )
			if speed then setup( state, record ).speed = math.max( 0, speed ) end
		end,
		startforward = function( state, record ) setDirection( state, record, true ) end,
		startbackward = function( state, record ) setDirection( state, record, false ) end,
		reverse = function( state, record ) setDirection( state, record, not setup( state, record ).forward ) end,
		stop = function( state, record ) setup( state, record ).active = false end,
		resume = function( state, record ) setup( state, record ).active = true end,
		teleporttopathtrack = function( state, record, value )
			local target = path( state.world, value )
			if not target then return end
			local mover = setup( state, record )
			mover.from = target
			mover.path = mover.forward and path( state.world, IO.Value( target.entity, "target" ) ) or previousPaths( state.world )[target]
			local origin = IO.Position( state, target )
			IO.State( state, record ).origin = Vector( origin.x, origin.y, origin.z )
			IO.PoseChanged( state, record )
		end,
	} )
end

local function moveTrain( state, record, mover, current, dt )
	if mover.waitUntil and state.time < mover.waitUntil then return end
	local remaining = dt * mover.speed
	for _ = 1, MAX_PATH_NODES_PER_STEP do
		local target = mover.path
		if not target then mover.active = false return end
		local origin = IO.Position( state, target )
		local difference = origin - current.origin
		local distance = difference:Length()
		if distance > remaining then
			current.origin = current.origin + difference * ( remaining / distance )
			return
		end
		current.origin = Vector( origin.x, origin.y, origin.z )
		remaining = remaining - distance
		IO.Fire( state, target, "OnPass", mover.activator, record )
		IO.Fire( state, target, "OnTrigger", mover.activator, record )
		mover.from = target
		mover.path = mover.forward and path( state.world, IO.Value( target.entity, "target" ) ) or previousPaths( state.world )[target]
		if not mover.path then
			mover.active = false
			IO.Fire( state, record, "OnStop", mover.activator, record )
			return
		end
		local wait = record.class == "func_train" and IO.Number( target.entity, "wait", 0 ) or 0
		if wait < 0 then mover.active = false return end
		if wait > 0 then mover.waitUntil = state.time + wait return end
		if remaining <= 0 then return end
	end
end

IO.OnStep( "Movers", function( session, state, dt )
	for _, class in ipairs( MOVERS ) do
		for _, record in ipairs( IO.OfClass( state.world, class ) ) do
			local mover = setup( state, record )
			if mover.active and IO.Enabled( state, record ) and mover.speed > 0 then
				local current = IO.State( state, record )
				local before = current.origin
				if mover.linear then
					local step = dt * mover.speed / math.max( math.abs( mover.distance ), 0.01 )
					mover.position = math.Approach( mover.position, mover.goal, step )
					current.origin = mover.closed + mover.direction * ( mover.distance * mover.position )
					if mover.position == mover.goal then
						mover.active = false
						if mover.goal == 0 or mover.goal == 1 then
							IO.Fire( state, record, mover.goal == 1 and "OnFullyOpen" or "OnFullyClosed", mover.activator, record )
						end
					end
				else
					moveTrain( state, record, mover, current, dt )
				end
				if before ~= current.origin then
					IO.PoseChanged( state, record )
					IO.Carry( session, record, current.origin - before )
				end
			end
		end
	end
end )
